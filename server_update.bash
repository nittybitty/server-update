#!/bin/bash

# Set restrictive umask to prevent world-readable temp files (Fix: Issue #42)
umask 077

# To update the local server, add a line like "local localhost" to your server_list.txt file.

# Server Update Dashboard
# Version: 1.3

# Color definitions for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
SERVER_LIST="server_list.txt"
LOG_FILE="server_update.log"
LOCK_FILE="/tmp/server_update.lock"

# Default values for configurable variables
# DNF_TIMEOUT: Maximum time (seconds) to wait for dnf commands to complete (default: 600 = 10 minutes)
DNF_TIMEOUT=600
# KERNEL_PACKAGE_REGEX: Pattern to identify kernel packages in dnf output (default: matches kernel, kernel-core, kernel-modules)
KERNEL_PACKAGE_REGEX="^kernel(-core|-modules)?\b"
# KERNEL_UPDATE_REGEX: Pattern to detect kernel installations/upgrades in update output
KERNEL_UPDATE_REGEX="(Installing|Upgrading).*(kernel-core|kernel-modules|kernel)\b"
# REBOOT_MAX_WAIT: Maximum time (seconds) to wait for server reboot (default: 900 = 15 minutes)
REBOOT_MAX_WAIT=900
# REBOOT_WAIT_INTERVAL: Seconds between reboot verification attempts (default: 30 seconds)
REBOOT_WAIT_INTERVAL=30
# DASHBOARD_REFRESH: Seconds between dashboard refreshes (default: 1 second)
DASHBOARD_REFRESH=1

# Function to safely load configuration file
# This prevents arbitrary code execution by only parsing specific variable assignments
load_config() {
    local config_file="server_update.conf"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Check file permissions - warn if world-writable or executable
    if [[ -w "$config_file" ]] && [[ $(stat -c "%a" "$config_file" 2>/dev/null) =~ [0-9][0-9][2367] ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Config file $config_file is world-writable! This is a security risk."
        echo -e "${YELLOW}[WARNING]${NC} Recommended: chmod 644 $config_file"
    fi

    # Whitelist of allowed configuration variables
    local allowed_vars=("DNF_TIMEOUT" "KERNEL_PACKAGE_REGEX" "KERNEL_UPDATE_REGEX" "REBOOT_MAX_WAIT" "REBOOT_WAIT_INTERVAL" "DASHBOARD_REFRESH")

    # Parse config file safely - only allow whitelisted variable assignments
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # Check if variable is in whitelist
        for allowed_var in "${allowed_vars[@]}"; do
            if [[ "$key" == "$allowed_var" ]]; then
                # Remove quotes from value if present
                value="${value%\"}"
                value="${value#\"}"
                value="${value%\'}"
                value="${value#\'}"

                # Validate numeric values
                if [[ "$key" =~ TIMEOUT|WAIT|REFRESH ]]; then
                    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                        echo -e "${YELLOW}[WARNING]${NC} Invalid numeric value for $key in config file. Using default."
                        continue
                    fi
                    # Reject unreasonably large values (1 week = 604800 seconds max)
                    if [[ "$value" -gt 604800 ]]; then
                        echo -e "${YELLOW}[WARNING]${NC} Value for $key is too large (max: 604800 seconds). Using default."
                        continue
                    fi
                fi

                # Validate regex patterns with ReDoS protection
                if [[ "$key" =~ REGEX ]]; then
                    # Test regex with timeout to prevent catastrophic backtracking
                    if ! timeout 1s bash -c "echo 'kernel-core-5.14.0' | grep -E '$value' >/dev/null 2>&1"; then
                        regex_exit=$?
                        # Exit codes: 0=match, 1=no match, 2+=error, 124=timeout
                        if [[ $regex_exit -ge 2 || $regex_exit -eq 124 ]]; then
                            echo -e "${YELLOW}[WARNING]${NC} Invalid or dangerous regex pattern for $key in config file. Using default."
                            continue
                        fi
                    fi
                fi

                # Assign the validated value
                declare -g "$key=$value"
                break
            fi
        done
    done < "$config_file"
}

# Load configuration safely
load_config

# ============================================================================
# INSTANCE LOCKING - Prevent multiple instances from running simultaneously
# ============================================================================
# Check if another instance is already running
if [[ -f "$LOCK_FILE" ]]; then
    # Read PID from lock file
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null)

    # Check if that PID is still running
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} Another instance of this script is already running (PID: $existing_pid)"
        echo -e "${RED}[ERROR]${NC} Lock file: $LOCK_FILE"
        echo -e "${YELLOW}[INFO]${NC} If you're sure no other instance is running, remove the lock file:"
        echo -e "${YELLOW}[INFO]${NC}   rm $LOCK_FILE"
        exit 1
    else
        # Stale lock file (process no longer exists)
        echo -e "${YELLOW}[WARNING]${NC} Removing stale lock file from PID $existing_pid"
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file with our PID
echo $$ > "$LOCK_FILE"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Failed to create lock file: $LOCK_FILE"
    echo -e "${YELLOW}[INFO]${NC} Check permissions on /tmp directory"
    exit 1
fi

# Create temporary directory with secure permissions (700 - owner only)
TEMP_DIR=$(mktemp -d /tmp/server_update.XXXXXX)
if [[ ! -d "$TEMP_DIR" ]]; then
    echo -e "${RED}[ERROR]${NC} Failed to create temporary directory"
    exit 1
fi
chmod 700 "$TEMP_DIR"

# Create SSH control socket directory (Fix: Issue #3 - SSH connection pooling)
SSH_CONTROL_DIR="$TEMP_DIR/ssh_control"
mkdir -p "$SSH_CONTROL_DIR"
chmod 700 "$SSH_CONTROL_DIR"

# Function to validate server name/IP to prevent command injection
# Parameters: $1 = server name or IP address
# Returns: 0 if valid, 1 if invalid
validate_server_name() {
    local server="$1"

    # Check for dangerous characters that could be used for command injection
    # Allow: alphanumeric, dots, hyphens, underscores, colons (for IPv6)
    if [[ ! "$server" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
        return 1
    fi

    # Reject common command injection patterns
    if [[ "$server" =~ [\;\|\&\$\`\(\)\{\}\[\]\<\>] ]]; then
        return 1
    fi

    # Additional check: prevent "../" path traversal
    if [[ "$server" =~ \.\. ]]; then
        return 1
    fi

    return 0
}

# Function to validate port number
# Parameters: $1 = port number
# Returns: 0 if valid (1-65535), 1 if invalid
validate_port() {
    local port="$1"

    # Must be numeric
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Must be in valid range 1-65535
    if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        return 1
    fi

    return 0
}

# Function to validate IP address format
# Parameters: $1 = IP address
# Returns: 0 if valid IPv4 or IPv6, 1 if invalid
validate_ip() {
    local ip="$1"

    # IPv4 validation
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local -a octets
        IFS='.' read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ "$octet" -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi

    # IPv6 validation (basic - allows compressed format)
    if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" =~ : ]]; then
        return 0
    fi

    return 1
}

# ============================================================================
# FILE LOCKING UTILITIES - Prevent race conditions with temp file access
# ============================================================================
# These functions use flock to ensure atomic reads/writes to temp files
# This prevents corruption when multiple background processes access the same files

# Function to safely write to a file with flock protection
# Parameters: $1 = file path, $2 = content to write
# Returns: 0 on success, 1 on failure
safe_write_file() {
    local file_path="$1"
    local content="$2"

    # Use flock to get exclusive lock, then write atomically
    # File descriptor 200 is arbitrary but consistent
    {
        flock -x 200 || return 1
        echo "$content" > "$file_path"
    } 200>"${file_path}.lock" 2>/dev/null

    return $?
}

# Function to safely read from a file with flock protection
# Parameters: $1 = file path, $2 = default value if file doesn't exist (optional)
# Returns: File content via stdout, or default value if file doesn't exist
safe_read_file() {
    local file_path="$1"
    local default_value="${2:-}"

    # If file doesn't exist, return default value
    if [[ ! -f "$file_path" ]]; then
        echo "$default_value"
        return 0
    fi

    # Use flock to get shared lock, then read
    local content
    {
        flock -s 200 || return 1
        content=$(cat "$file_path" 2>/dev/null || echo "$default_value")
    } 200>"${file_path}.lock" 2>/dev/null

    echo "$content"
    return 0
}

# Function to display usage information
show_help() {
    echo "Server Update Dashboard - Version 1.3"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run          Check for updates but don't apply them"
    echo "  --check-only       Display available updates without prompting"
    echo "  --assume-yes       Automatically approve all updates (use with caution)"
    echo "  --non-interactive  Skip all interactive prompts (for automation/testing)"
    echo "  --version          Display version information"
    echo "  --help             Display this help message"
    echo ""
    echo "Configuration:"
    echo "  Server list: $SERVER_LIST"
    echo "  Log file:    $LOG_FILE"
    echo "  Config file: server_update.conf (optional)"
    echo ""
    echo "For more information, see CLAUDE.md"
    exit 0
}

# Function to display version information
show_version() {
    echo "Server Update Dashboard"
    echo "Version: 1.3"
    exit 0
}

# Parse command-line options
DRY_RUN=false
CHECK_ONLY=false
ASSUME_YES=false
NON_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            echo -e "${YELLOW}Running in dry-run mode. No changes will be made.${NC}\n"
            shift
            ;;
        --check-only)
            CHECK_ONLY=true
            echo -e "${CYAN}Running in check-only mode. Will display updates without prompting.${NC}\n"
            shift
            ;;
        --assume-yes)
            ASSUME_YES=true
            echo -e "${YELLOW}Running with --assume-yes. All updates will be auto-approved!${NC}\n"
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --version)
            show_version
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done



# Cleanup function to run on exit
cleanup() {
    # Close all SSH control connections (Fix: Issue #3)
    if [[ -d "$SSH_CONTROL_DIR" ]]; then
        for socket in "$SSH_CONTROL_DIR"/*; do
            if [[ -S "$socket" ]]; then
                ssh -O exit -o ControlPath="$socket" 2>/dev/null || true
            fi
        done
    fi

    # Kill all background jobs spawned by this script
    # This prevents orphaned dnf/yum processes that can hang future runs
    local jobs_list
    jobs_list=$(jobs -p 2>/dev/null)
    if [[ -n "$jobs_list" ]]; then
        # Kill background jobs and their children
        echo "$jobs_list" | xargs -r kill -TERM 2>/dev/null
        sleep 1
        # Force kill any remaining processes
        echo "$jobs_list" | xargs -r kill -KILL 2>/dev/null || true
    fi

    # Remove temporary directory
    rm -rf "$TEMP_DIR"

    # Remove instance lock file
    rm -f "$LOCK_FILE"
}

# Cleanup on exit - kill background jobs and remove temporary directory
trap cleanup EXIT INT TERM

# Initialize log file with restricted permissions (600 - owner read/write only)
touch "$LOG_FILE" 2>/dev/null
chmod 600 "$LOG_FILE" 2>/dev/null

# Check log file size and warn if it's getting large (> 10MB)
if [[ -f "$LOG_FILE" ]]; then
    log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$log_size" -gt 10485760 ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Log file $LOG_FILE is larger than 10MB. Consider rotating logs."
    fi
fi

# Check if server list exists
if [[ ! -f "$SERVER_LIST" ]]; then
    echo -e "${RED}[ERROR]${NC} Server list file '$SERVER_LIST' not found!"
    exit 1
fi

# Check server list file permissions - warn if world-writable
if [[ -w "$SERVER_LIST" ]]; then
    perms=$(stat -c "%a" "$SERVER_LIST" 2>/dev/null || stat -f "%Lp" "$SERVER_LIST" 2>/dev/null)
    if [[ "$perms" =~ [0-9][0-9][2367] ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Server list $SERVER_LIST is world-writable! This is a security risk."
        echo -e "${YELLOW}[WARNING]${NC} Recommended: chmod 644 $SERVER_LIST"
    fi
fi

# Read servers into array with validation
# Format: nickname server_address [-p port]
# Example: web-prod 192.0.2.10 -p 2222
declare -a SERVERS
declare -A SERVER_NICKNAMES
declare -A SERVER_PORTS
line_number=0

while read -r -a parts; do
    ((line_number++))

    # Skip empty lines and lines starting with #
    if [[ ${#parts[@]} -eq 0 || "${parts[0]}" =~ ^# ]]; then
        continue
    fi

    nickname="${parts[0]}"
    server="${parts[1]}"
    port=""

    # Find the port if it exists (format: -p PORT)
    for i in "${!parts[@]}"; do
        if [[ "${parts[$i]}" == "-p" && -n "${parts[$i+1]}" ]]; then
            port="${parts[$i+1]}"
            break
        fi
    done

    # Skip if either nickname or server is missing
    if [[ -z "$nickname" || -z "$server" ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Line $line_number: Missing nickname or server address, skipping"
        continue
    fi

    # Validate server name/IP to prevent command injection
    if ! validate_server_name "$server"; then
        echo -e "${RED}[ERROR]${NC} Line $line_number: Invalid server address '$server' (contains dangerous characters)"
        continue
    fi

    # Validate nickname (should not contain dangerous characters)
    if ! validate_server_name "$nickname"; then
        echo -e "${RED}[ERROR]${NC} Line $line_number: Invalid nickname '$nickname' (contains dangerous characters)"
        continue
    fi

    # If server is not "localhost", validate it as IP or hostname
    if [[ "$server" != "localhost" ]]; then
        # Try to validate as IP first, if that fails, assume it's a hostname
        if ! validate_ip "$server"; then
            # For hostnames, just ensure they don't contain command injection chars (already checked above)
            :
        fi
    fi

    # Validate port if specified
    if [[ -n "$port" ]]; then
        if ! validate_port "$port"; then
            echo -e "${RED}[ERROR]${NC} Line $line_number: Invalid port number '$port' (must be 1-65535)"
            continue
        fi
    fi

    # Add validated server to arrays
    SERVERS+=("$server")
    SERVER_NICKNAMES["$server"]="$nickname"
    if [[ -n "$port" ]]; then
        SERVER_PORTS["$server"]="$port"
    fi
done < "$SERVER_LIST"

# Verify we have at least one valid server
if [[ ${#SERVERS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR]${NC} No valid servers found in server list!"
    echo -e "${RED}[ERROR]${NC} Check $SERVER_LIST for errors"
    exit 1
fi

# Function to detect package manager on a server
# Parameters: $1 = server address
# Returns: Echoes "apt", "dnf", "yum", or "unknown"
detect_package_manager() {
    local server="$1"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")

    # Check for package managers in order of preference: apt, dnf, yum
    if [[ -n "$ssh_cmd" ]]; then
        if $ssh_cmd "$server" "command -v apt-get" &>/dev/null; then
            echo "apt"
        elif $ssh_cmd "$server" "command -v dnf" &>/dev/null; then
            echo "dnf"
        elif $ssh_cmd "$server" "command -v yum" &>/dev/null; then
            echo "yum"
        else
            echo "unknown"
        fi
    else
        # Localhost
        if command -v apt-get &>/dev/null; then
            echo "apt"
        elif command -v dnf &>/dev/null; then
            echo "dnf"
        elif command -v yum &>/dev/null; then
            echo "yum"
        else
            echo "unknown"
        fi
    fi
}

# Function to gather system information (OS release and kernel version)
# Parameters: $1 = server address
# Side effects: Writes OS and kernel info to temp files
gather_system_info() {
    local server="$1"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")

    # Get OS release info
    local os_info
    if [[ -n "$ssh_cmd" ]]; then
        os_info=$($ssh_cmd "$server" "cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d'\"' -f2" 2>/dev/null || echo "Unknown")
        # Fallback to lsb_release or basic info
        if [[ "$os_info" == "Unknown" || -z "$os_info" ]]; then
            os_info=$($ssh_cmd "$server" "lsb_release -d 2>/dev/null | cut -f2" 2>/dev/null || echo "Unknown")
        fi
    else
        os_info=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unknown")
    fi

    # Get kernel version
    local kernel_ver
    if [[ -n "$ssh_cmd" ]]; then
        kernel_ver=$($ssh_cmd "$server" "uname -r" 2>/dev/null || echo "Unknown")
    else
        kernel_ver=$(uname -r 2>/dev/null || echo "Unknown")
    fi

    # Write to temp files so background processes can share this info
    safe_write_file "$TEMP_DIR/${server}.os_release" "$os_info"
    safe_write_file "$TEMP_DIR/${server}.kernel" "$kernel_ver"
}

# Function to get SSH command with port and options
# Parameters: $1 = server address
# Returns: SSH command string with appropriate options, or empty string for localhost
get_ssh_cmd() {
    local server="$1"

    # For localhost, don't use SSH (Fix: Issue #28 - better localhost detection)
    # Check if server is truly localhost (127.0.0.1, ::1, or localhost)
    if [[ "$server" == "localhost" || "$server" == "127.0.0.1" || "$server" == "::1" ]]; then
        echo ""
        return
    fi

    # Build SSH command with connection pooling and better security (Fix: Issues #3, #41)
    # ControlMaster=auto: Reuse existing connections when available
    # ControlPersist=600: Keep connection alive for 10 minutes after last use
    # ControlPath: Socket file for connection sharing
    # StrictHostKeyChecking=accept-new: Accept new hosts but verify known hosts (more secure than 'no')
    local control_socket="$SSH_CONTROL_DIR/${server}_%h_%p_%r"
    local ssh_cmd="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPersist=600 -o ControlPath=\"$control_socket\""

    if [[ -n "${SERVER_PORTS[$server]}" ]]; then
        # Append port with proper quoting
        ssh_cmd="$ssh_cmd -p ${SERVER_PORTS[$server]}"
    fi

    echo "$ssh_cmd"
}

# Function to test if sudo works without password on localhost
# Returns: 0 if passwordless sudo works, 1 otherwise
test_localhost_sudo() {
    # Use a short timeout (5 seconds) to test if sudo requires password
    # sudo -n (non-interactive) will fail immediately if password is required
    if timeout 5s sudo -n true 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to execute command on remote server or locally
# Parameters: $1 = server, $2 = command to execute, $3 = timeout (optional, uses DNF_TIMEOUT if not specified)
# Returns: Command output and exit code
execute_remote_command() {
    local server="$1"
    local command="$2"
    local timeout="${3:-$DNF_TIMEOUT}"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")

    if [[ -n "$ssh_cmd" ]]; then
        # shellcheck disable=SC2086
        timeout "${timeout}s" $ssh_cmd "$server" "$command" 2>&1
    else
        # For localhost, test if sudo works first (only if command contains sudo)
        if [[ "$command" == *"sudo"* ]]; then
            if ! test_localhost_sudo; then
                echo "ERROR: Passwordless sudo is not configured for localhost"
                return 1
            fi
        fi
        timeout "${timeout}s" bash -c "$command" 2>&1
    fi

    return $?
}

# Function to check disk space before updates (Fix: Issue #7)
# Parameters: $1 = server address
# Returns: 0 if sufficient space, 1 if insufficient
check_disk_space() {
    local server="$1"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")

    # Get disk space for / and /boot partitions
    # df output format: Filesystem Size Used Avail Use% Mounted
    local root_avail boot_avail

    if [[ -n "$ssh_cmd" ]]; then
        # shellcheck disable=SC2086
        root_avail=$($ssh_cmd "$server" "df -BG / | tail -1 | awk '{print \$4}' | sed 's/G//'" 2>/dev/null)
        # shellcheck disable=SC2086
        boot_avail=$($ssh_cmd "$server" "df -BM /boot 2>/dev/null | tail -1 | awk '{print \$4}' | sed 's/M//'" 2>/dev/null)
    else
        root_avail=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
        boot_avail=$(df -BM /boot 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/M//' 2>/dev/null)
    fi

    # Check if we got valid numbers
    if [[ ! "$root_avail" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Could not determine disk space for / on $(get_display_name "$server")"
        return 0  # Allow to proceed if we can't check (non-fatal)
    fi

    # Require at least 10GB free on /
    if [[ "$root_avail" -lt 10 ]]; then
        echo -e "${RED}[ERROR]${NC} Insufficient disk space on / for $(get_display_name "$server")"
        echo -e "${RED}[ERROR]${NC} Available: ${root_avail}GB, Required: 10GB"
        return 1
    fi

    # Check /boot if it exists as a separate partition (non-fatal if it doesn't exist)
    if [[ -n "$boot_avail" && "$boot_avail" =~ ^[0-9]+$ ]]; then
        # Require at least 500MB free on /boot
        if [[ "$boot_avail" -lt 500 ]]; then
            echo -e "${RED}[ERROR]${NC} Insufficient disk space on /boot for $(get_display_name "$server")"
            echo -e "${RED}[ERROR]${NC} Available: ${boot_avail}MB, Required: 500MB"
            return 1
        fi
    fi

    return 0
}

# Function to format server display name
# Parameters: $1 = server address
# Returns: Formatted string "server (nickname)"
get_display_name() {
    local server="$1"
    echo "$server (${SERVER_NICKNAMES[$server]})"
}

# Function to check if output contains kernel package references
# Parameters: $1 = text to search, $2 = package manager type (optional)
# Returns: 0 if kernel package found, 1 otherwise
has_kernel_package() {
    local text="$1"
    local pkg_manager="${2:-dnf}"

    case "$pkg_manager" in
        apt)
            # For apt/Debian, check for linux-image, linux-headers, linux-modules
            echo "$text" | grep -qiE "(linux-image|linux-headers|linux-modules)"
            ;;
        *)
            # For dnf/yum, use the configured KERNEL_PACKAGE_REGEX
            echo "$text" | grep -qiE "$KERNEL_PACKAGE_REGEX"
            ;;
    esac
    return $?
}

# Function to parse DNF output and extract package counts
# Parameters: $1 = dnf output text
# Returns: Total count of packages to install/upgrade (echoed to stdout)
parse_dnf_package_count() {
    local dnf_output="$1"
    local install_count upgrade_count total_count

    install_count=$(echo "$dnf_output" | grep "^Install " | awk '{print $2}')
    upgrade_count=$(echo "$dnf_output" | grep "^Upgrade " | awk '{print $2}')

    total_count=0
    [[ -n "$install_count" ]] && total_count=$((total_count + install_count))
    [[ -n "$upgrade_count" ]] && total_count=$((total_count + upgrade_count))

    echo "$total_count"
}

# Function to draw the live-updating dashboard showing all server statuses
# This clears the screen and displays a formatted table of servers and their current status
# Status is read from temporary status files written by update_status()
# No parameters required - reads from global SERVERS array
draw_dashboard() {
    # Clear screen
    printf "\033[H\033[2J"

    # Draw header (Fix: Issue #36 - Use ASCII instead of Unicode)
    echo -e "${BOLD}${BLUE}+==================================================================================================================================+${NC}"
    echo -e "${BOLD}${BLUE}|                                        SERVER UPDATE DASHBOARD                                                                  |${NC}"
    echo -e "${BOLD}${BLUE}+==================================================================================================================================+${NC}"

    # Column headers
    printf "\n${BOLD}%-30s %-32s %-28s %-40s${NC}\n" "SERVER" "OS DISTRIBUTION" "KERNEL VERSION" "STATUS"
    echo -e "${BLUE}----------------------------------------------------------------------------------------------------------------------------------${NC}"

    # Display status for each server
    for server in "${SERVERS[@]}"; do
        local status_file="$TEMP_DIR/${server}.status"

        # Read status file with flock protection
        local status
        status=$(safe_read_file "$status_file" "Pending")

        # Color code status based on keywords
        local color="${CYAN}"
        case "$status" in
            *"Checking"*) color="${CYAN}" ;;
            *"Connected"*) color="${GREEN}" ;;
            *"updates available"*) color="${YELLOW}" ;;
            *"No updates"*) color="${GREEN}" ;;
            *"ERROR"*|*"Error"*) color="${RED}" ;;
            *"Updating"*|*"Applying"*) color="${MAGENTA}" ;;
            *"Rebooting"*) color="${YELLOW}" ;;
            *"Successfully rebooted"*|*"✓"*) color="${GREEN}" ;;
            *"Complete"*) color="${GREEN}" ;;
        esac

        local display_name
        display_name=$(get_display_name "$server")

        # Get OS and kernel info from temp files with flock protection
        local os_info
        local kernel_info

        os_info=$(safe_read_file "$TEMP_DIR/${server}.os_release" "--")
        kernel_info=$(safe_read_file "$TEMP_DIR/${server}.kernel" "--")

        # Don't show "Unknown"
        [[ "$os_info" == "Unknown" ]] && os_info="--"
        [[ "$kernel_info" == "Unknown" ]] && kernel_info="--"

        # Truncate fields if too long
        if [[ ${#display_name} -gt 29 ]]; then
            display_name="${display_name:0:26}..."
        fi
        if [[ ${#os_info} -gt 31 ]]; then
            os_info="${os_info:0:28}..."
        fi
        if [[ ${#kernel_info} -gt 27 ]]; then
            kernel_info="${kernel_info:0:24}..."
        fi
        if [[ ${#status} -gt 39 ]]; then
            status="${status:0:36}..."
        fi

        # Display single line with all info
        printf "%-30s %-32s %-28s ${color}%-40s${NC}\n" "$display_name" "$os_info" "$kernel_info" "$status"
    done

    echo -e "${BLUE}----------------------------------------------------------------------------------------------------------------------------------${NC}"
}

# Function to update server status in temporary file (read by draw_dashboard)
# Parameters: $1 = server address, $2 = status message
update_status() {
    local server="$1"
    local status="$2"
    safe_write_file "$TEMP_DIR/${server}.status" "$status"
}

# Function to check for available updates on a server
# This runs 'apt/dnf/yum update' check to see what packages would be updated
# Parameters: $1 = server address
# Returns: 0 on success, 1 on error
# Side effects: Updates status file, writes package manager output to temp file
check_server_updates() {
    local server="$1"
    local output_file="$TEMP_DIR/${server}.output"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")

    update_status "$server" "Checking connection..."

    # Test SSH connection before proceeding (skip for localhost)
    if [[ -n "$ssh_cmd" ]]; then
        # Use timeout to prevent hanging on connection attempts
        # shellcheck disable=SC2086
        if ! timeout 15s $ssh_cmd "$server" "echo 'Connection successful'" &>/dev/null; then
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                update_status "$server" "ERROR: Connection timeout"
                echo "$(date) - ERROR: Connection timeout to $server (15s)" >> "$LOG_FILE"
            else
                update_status "$server" "ERROR: Cannot connect"
                echo "$(date) - ERROR: Connection failed to $server" >> "$LOG_FILE"
            fi
            return 1
        fi
    fi

    update_status "$server" "Connected - detecting system..."

    # Detect package manager and gather system info
    local pkg_manager
    pkg_manager=$(detect_package_manager "$server")
    # Write to temp file (background processes can't modify parent arrays)
    safe_write_file "$TEMP_DIR/${server}.pkg_manager" "$pkg_manager"
    gather_system_info "$server"

    update_status "$server" "Connected - checking for updates ($pkg_manager)..."

    # Run appropriate package manager command to check for updates
    local pkg_output
    local pkg_exit_code
    local check_cmd

    case "$pkg_manager" in
        apt)
            # For apt: update cache then check for upgradeable packages
            check_cmd="sudo apt-get update -qq && apt list --upgradable 2>/dev/null"
            ;;
        dnf)
            check_cmd="sudo dnf update --assumeno"
            ;;
        yum)
            check_cmd="sudo yum update --assumeno"
            ;;
        *)
            update_status "$server" "ERROR: No supported package manager found"
            echo "$(date) - ERROR: No supported package manager on $server" >> "$LOG_FILE"
            return 1
            ;;
    esac

    pkg_output=$(execute_remote_command "$server" "$check_cmd")
    pkg_exit_code=$?

    # Check for sudo error on localhost
    if [[ "$pkg_output" == *"Passwordless sudo is not configured"* ]]; then
        update_status "$server" "ERROR: Passwordless sudo required"
        echo "$(date) - ERROR: Passwordless sudo not configured for $server" >> "$LOG_FILE"
        echo "$(date) - NOTE: Configure passwordless sudo for package management commands" >> "$LOG_FILE"
        return 1
    fi

    # Check for timeout (exit code 124)
    if [[ $pkg_exit_code -eq 124 ]]; then
        update_status "$server" "ERROR: Package manager command timed out"
        echo "$(date) - ERROR: Package manager timed out on $server" >> "$LOG_FILE"
        return 1
    fi

    # Check for general command failure
    if [[ $pkg_exit_code -ne 0 ]] && [[ "$pkg_manager" == "apt" ]]; then
        # For apt, non-zero exit during update check might still be okay if we get output
        # apt list --upgradable returns non-zero sometimes even when successful
        if [[ -z "$pkg_output" ]]; then
            update_status "$server" "ERROR: Package manager command failed"
            echo "$(date) - ERROR: Package manager failed on $server (exit code: $pkg_exit_code)" >> "$LOG_FILE"
            return 1
        fi
    fi

    # Save full output to file for later review
    echo "$pkg_output" > "$output_file"

    # Parse output based on package manager type
    local total_count=0
    case "$pkg_manager" in
        apt)
            # Count upgradeable packages (excluding the "Listing..." header) (Fix: Issue #29)
            total_count=$(echo "$pkg_output" | grep -v "^Listing\.\.\.$" | grep -c "/" || echo 0)
            if [[ $total_count -gt 0 ]]; then
                update_status "$server" "${total_count} updates available"
                return 0
            else
                update_status "$server" "No updates available - Complete"
                return 0
            fi
            ;;
        dnf|yum)
            # Check for Transaction Summary (dnf/yum format)
            if echo "$pkg_output" | grep -q "Transaction Summary"; then
                total_count=$(parse_dnf_package_count "$pkg_output")
                update_status "$server" "${total_count} updates available"
                return 0
            elif echo "$pkg_output" | grep -q "Nothing to do"; then
                update_status "$server" "No updates available - Complete"
                return 0
            else
                update_status "$server" "ERROR: Failed to check updates"
                echo "$(date) - ERROR: Update check failed on $server" >> "$LOG_FILE"
                return 1
            fi
            ;;
    esac
}

# Function to monitor server reboot process and verify it comes back online
# This function performs a two-phase check:
#   Phase 1: Wait for server to go down (become unreachable)
#   Phase 2: Wait for server to come back up and be fully responsive
# Parameters: $1 = server address
# Returns: 0 if reboot successful, 1 if timeout or error
# Side effects: Updates status file, writes reboot_status file (success/failed)
verify_reboot() {
    local server="$1"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")

    # Calculate maximum attempts based on configured wait time and interval
    local max_attempts=$((REBOOT_MAX_WAIT / REBOOT_WAIT_INTERVAL))
    local attempts=0

    update_status "$server" "Rebooting... waiting for server to go down"
    echo "$(date) - Waiting for $server to reboot" >> "$LOG_FILE"

    # ========================================
    # Phase 1: Wait for server to go down
    # ========================================
    # We check every 5 seconds for up to 100 seconds (20 attempts)
    # This ensures the reboot command was actually executed
    local down_attempts=0
    local max_down_attempts=20  # 20 attempts × 5 seconds = 100 seconds max

    if [[ -n "$ssh_cmd" ]]; then
        # Remote server: use SSH to check if it's still responding
        while $ssh_cmd "$server" "echo 'up'" &>/dev/null && [[ $down_attempts -lt $max_down_attempts ]]; do
            sleep 5  # Check every 5 seconds
            ((down_attempts++))
        done
    else
        # Localhost: We can't SSH to check status
        # Wait 30 seconds and assume the reboot is in progress
        sleep 30
    fi

    # If server didn't go down after 100 seconds, the reboot command may have failed
    if [[ -n "$ssh_cmd" && $down_attempts -ge $max_down_attempts ]]; then
        update_status "$server" "ERROR: Server did not go down after reboot command"
        echo "$(date) - ERROR: $server did not go down after reboot command" >> "$LOG_FILE"
        safe_write_file "$TEMP_DIR/${server}.reboot_status" "failed"
        return 1
    fi

    # ========================================
    # Phase 2: Wait for server to come back up
    # ========================================
    update_status "$server" "Rebooting... checking every ${REBOOT_WAIT_INTERVAL}s for reconnection"

    while [[ $attempts -lt $max_attempts ]]; do
        sleep "$REBOOT_WAIT_INTERVAL"
        ((attempts++))

        # Try to connect and verify server is fully responsive
        # We use 'uptime' command as a simple test that requires server to be fully booted
        local responsive=false
        if [[ -n "$ssh_cmd" ]]; then
            # Remote server: Try SSH connection
            if $ssh_cmd "$server" "uptime" &>/dev/null; then
                responsive=true
            fi
        else
            # Localhost: Check if uptime command works
            if uptime &>/dev/null; then
                responsive=true
            fi
        fi

        if [[ "$responsive" == true ]]; then
            # Server is back online and responsive!
            update_status "$server" "✓ Reboot complete"
            echo "$(date) - $server successfully rebooted after $((attempts * REBOOT_WAIT_INTERVAL)) seconds" >> "$LOG_FILE"
            safe_write_file "$TEMP_DIR/${server}.reboot_status" "success"
            return 0
        fi

        # Update dashboard with current attempt number
        update_status "$server" "Rebooting... attempt $attempts/$max_attempts (${REBOOT_WAIT_INTERVAL}s intervals)"
    done

    # Timeout - server didn't come back within the maximum wait time
    update_status "$server" "ERROR: Server did not come back online after reboot"
    echo "$(date) - ERROR: $server did not come back online after ${REBOOT_MAX_WAIT}s" >> "$LOG_FILE"
    safe_write_file "$TEMP_DIR/${server}.reboot_status" "failed"
    return 1
}

# Function to apply updates on a server and handle reboots if needed
# This runs 'apt/dnf/yum update -y' and monitors for kernel updates that require reboot
# Parameters: $1 = server address
# Returns: 0 on success, 1 on error
# Side effects: Updates status file, writes update_type file, may trigger reboot
apply_updates() {
    local server="$1"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")
    # Read package manager from temp file (set during check_server_updates)
    local pkg_manager
    pkg_manager=$(safe_read_file "$TEMP_DIR/${server}.pkg_manager" "unknown")

    # Check disk space before applying updates (Fix: Issue #7)
    update_status "$server" "Checking disk space..."
    if ! check_disk_space "$server"; then
        update_status "$server" "ERROR: Insufficient disk space"
        echo "$(date) - ERROR: Insufficient disk space on $server" >> "$LOG_FILE"
        return 1
    fi

    update_status "$server" "Applying updates (via $pkg_manager)..."

    # Determine update command based on package manager
    local update_cmd
    case "$pkg_manager" in
        apt)
            # For apt: Use DEBIAN_FRONTEND=noninteractive to avoid prompts
            update_cmd="sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
            ;;
        dnf)
            update_cmd="sudo dnf update -y"
            ;;
        yum)
            update_cmd="sudo yum update -y"
            ;;
        *)
            update_status "$server" "ERROR: Unknown package manager"
            echo "$(date) - ERROR: Unknown package manager on $server" >> "$LOG_FILE"
            return 1
            ;;
    esac

    # Run update command
    local update_output
    update_output=$(execute_remote_command "$server" "$update_cmd")
    local update_exit_code=$?

    # Check for sudo error on localhost
    if [[ "$update_output" == *"Passwordless sudo is not configured"* ]]; then
        update_status "$server" "ERROR: Passwordless sudo required"
        echo "$(date) - ERROR: Passwordless sudo not configured for $server" >> "$LOG_FILE"
        return 1
    fi

    # Check for timeout
    if [[ $update_exit_code -eq 124 ]]; then
        update_status "$server" "ERROR: Update command timed out"
        echo "$(date) - ERROR: Update timed out on $server" >> "$LOG_FILE"
        echo "$update_output" >> "$LOG_FILE"
        return 1
    elif [[ $update_exit_code -ne 0 ]]; then
        update_status "$server" "ERROR: Update failed"
        echo "$(date) - ERROR: Update failed on $server" >> "$LOG_FILE"
        echo "$update_output" >> "$LOG_FILE"
        return 1
    fi

    # Check if kernel was updated by scanning the actual update output
    # Kernel updates require a reboot to take effect
    local kernel_updated=false

    case "$pkg_manager" in
        apt)
            # For apt, look for linux-image, linux-headers, or linux-modules packages
            if echo "$update_output" | grep -qiE "(linux-image|linux-headers|linux-modules)"; then
                kernel_updated=true
            fi
            ;;
        dnf|yum)
            # For dnf/yum, use the configured KERNEL_UPDATE_REGEX
            if echo "$update_output" | grep -qiE "$KERNEL_UPDATE_REGEX"; then
                kernel_updated=true
            fi
            ;;
    esac

    if [[ "$kernel_updated" == "true" ]]; then
        update_status "$server" "Updates complete - kernel updated - initiating reboot..."
        echo "$(date) - Kernel updated on $server - initiating reboot" >> "$LOG_FILE"
        safe_write_file "$TEMP_DIR/${server}.update_type" "kernel_update"

        # Wait 2 seconds before rebooting to ensure everything is flushed
        sleep 2

        # Issue reboot command
        if [[ -n "$ssh_cmd" ]]; then
            $ssh_cmd "$server" "sudo reboot" &>/dev/null
        else
            # Localhost reboot
            sudo reboot &>/dev/null
        fi

        # Monitor the reboot process and wait for server to come back
        verify_reboot "$server"
    else
        # No kernel update - mark as complete without reboot
        update_status "$server" "✓ Complete - No reboot needed"
        echo "$(date) - Updates completed on $server (no kernel update)" >> "$LOG_FILE"
        safe_write_file "$TEMP_DIR/${server}.update_type" "no_reboot"
    fi

    return 0
}

# ============================================================================
# Display server summary and validate SSH connectivity
# ============================================================================
echo ""
echo -e "${BOLD}${BLUE}+==============================================================================+${NC}"
echo -e "${BOLD}${BLUE}|                       SERVER UPDATE DASHBOARD                                |${NC}"
echo -e "${BOLD}${BLUE}+==============================================================================+${NC}"
echo ""
echo -e "${BOLD}Servers to check (${#SERVERS[@]} total):${NC}"
for server in "${SERVERS[@]}"; do
    display_name=$(get_display_name "$server")
    echo "  • $display_name"
done
echo ""

# Skip interactive prompt in automated modes
if [[ "$NON_INTERACTIVE" == true || "$CHECK_ONLY" == true || "$ASSUME_YES" == true ]]; then
    echo -e "${CYAN}Starting update check (automated mode)...${NC}"
else
    echo -e "${CYAN}Press Enter to start checking for updates...${NC}"
    read -r
fi

# ============================================================================
# PHASE 1: Check all servers for updates in parallel
# ============================================================================
# In this phase, we:
#   1. Connect to each server simultaneously using background jobs
#   2. Run 'dnf update --assumeno' to check for available updates
#   3. Display real-time status updates in a live dashboard
#   4. Save update information to temp files for later review
# ============================================================================
echo -e "${BOLD}${GREEN}Starting update check on all servers...${NC}\n"
sleep 1

# Launch update check for each server in the background
for server in "${SERVERS[@]}"; do
    update_status "$server" "Queued..."
    check_server_updates "$server" &
done

# Wait for all background checks to complete with live dashboard updates
while [[ $(jobs -r | wc -l) -gt 0 ]]; do
    draw_dashboard
    sleep "$DASHBOARD_REFRESH"
done

# Ensure all background jobs are truly finished (Fix: Issue #30)
wait

# Display final dashboard state
draw_dashboard

echo -e "${BOLD}${GREEN}Update check complete!${NC}\n"
sleep 2

# ============================================================================
# PHASE 2: Review and approve updates for each server
# ============================================================================
# In this phase, we:
#   1. Display the list of available updates for each server
#   2. Highlight kernel packages in red (these require reboot)
#   3. Prompt user to approve or decline updates for each server
#   4. Build a list of approved servers for Phase 3
# Special modes:
#   --dry-run: Skip all updates
#   --check-only: Display updates but don't prompt
#   --assume-yes: Auto-approve all updates
# ============================================================================
for server in "${SERVERS[@]}"; do
    # Skip localhost - it will be handled separately in Phase 4
    if [[ "$server" == "localhost" ]]; then
        continue
    fi

    output_file="$TEMP_DIR/${server}.output"
    status_file="$TEMP_DIR/${server}.status"

    # Skip if output file doesn't exist
    if [[ ! -f "$output_file" ]]; then
        continue
    fi

    # Read status with flock protection
    status=$(safe_read_file "$status_file" "Unknown")

    # Skip servers with errors or no updates
    if [[ "$status" == *"ERROR"* ]] || [[ "$status" == *"No updates"* ]]; then
        continue
    fi

    # Verify updates are actually available
    if ! grep -q "Transaction Summary" "$output_file"; then
        continue
    fi

    # Display server header
    echo -e "${BOLD}${BLUE}=====================================================================${NC}"
    display_name=$(get_display_name "$server")
    echo -e "${BOLD}${GREEN}Server: ${CYAN}$display_name${NC}"
    echo -e "${BOLD}${BLUE}=====================================================================${NC}"
    echo ""

    # ========================================
    # Extract and display package lists from package manager output
    # Highlight kernel packages in RED BOLD since they require reboot
    # ========================================
    # Read package manager from temp file (set during check_server_updates)
    pkg_manager=$(safe_read_file "$TEMP_DIR/${server}.pkg_manager" "unknown")

    case "$pkg_manager" in
        apt)
            # For apt, display the upgradeable packages list
            grep -v "^Listing\.\.\.$" "$output_file" | while read -r line; do
                if has_kernel_package "$line" "apt"; then
                    echo -e "${RED}${BOLD}$line${NC}"
                else
                    echo "$line"
                fi
            done
            echo ""
            ;;
        dnf|yum)
            # Show packages being upgraded
            sed -n '/^Upgrading:/,/^Transaction Summary/p' "$output_file" | head -n -1 | while read -r line; do
                if has_kernel_package "$line" "$pkg_manager"; then
                    echo -e "${RED}${BOLD}$line${NC}"
                else
                    echo "$line"
                fi
            done

            # Show packages being installed (new packages)
            sed -n '/^Installing:/,/^Transaction Summary/p' "$output_file" | head -n -1 | while read -r line; do
                if has_kernel_package "$line" "$pkg_manager"; then
                    echo -e "${RED}${BOLD}$line${NC}"
                else
                    echo "$line"
                fi
            done

            # Display transaction summary (total packages, download size, etc.)
            echo ""
            sed -n '/^Transaction Summary/,/^Total download size/p' "$output_file"
            echo ""
            ;;
    esac

    # Warn if kernel update detected
    output_content=$(cat "$output_file")
    if has_kernel_package "$output_content" "$pkg_manager"; then
        echo -e "${YELLOW}${BOLD}⚠ Kernel update detected - server will be rebooted after updates${NC}"
        echo ""
    fi

    # ========================================
    # Prompt for confirmation (or auto-approve based on mode)
    # ========================================
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}Skipping updates (dry-run mode)${NC}\n"
        update_status "$server" "Skipped (dry-run)"
    elif [[ "$CHECK_ONLY" == true ]]; then
        echo -e "${CYAN}Check-only mode - not prompting for approval${NC}\n"
        update_status "$server" "Displayed (check-only)"
    elif [[ "$ASSUME_YES" == true ]]; then
        echo -e "${GREEN}Auto-approving updates (--assume-yes mode)${NC}\n"
        echo "$server" >> "$TEMP_DIR/approved_servers.txt"
    else
        # Interactive mode - prompt user
        echo -e -n "${BOLD}Apply updates to $display_name? [y/N]: ${NC}"
        read -r response

        if [[ "$response" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Proceeding with updates for $display_name...${NC}\n"
            echo "$server" >> "$TEMP_DIR/approved_servers.txt"
        else
            echo -e "${YELLOW}Skipping updates for $display_name${NC}\n"
            update_status "$server" "Skipped by user"
        fi
    fi

    echo ""
done

# ============================================================================
# PHASE 3: Apply updates to approved servers in parallel
# ============================================================================
# In this phase, we:
#   1. Launch dnf update on all approved servers simultaneously
#   2. Monitor for kernel updates that require reboot
#   3. Automatically reboot servers with kernel updates
#   4. Wait for rebooted servers to come back online
#   5. Display live status updates in the dashboard
# ============================================================================
if [[ -f "$TEMP_DIR/approved_servers.txt" ]]; then
    echo -e "${BOLD}${GREEN}Applying updates to approved servers...${NC}\n"
    sleep 2

    # Launch update process for each approved server in the background
    # Skip localhost - it will be handled in Phase 4 after all remote servers complete
    while IFS= read -r server; do
        # Skip localhost
        if [[ "$server" == "localhost" ]]; then
            continue
        fi
        apply_updates "$server" &
    done < "$TEMP_DIR/approved_servers.txt"

    # Wait for all update processes to complete with live dashboard
    while [[ $(jobs -r | wc -l) -gt 0 ]]; do
        draw_dashboard
        sleep "$DASHBOARD_REFRESH"
    done

    # Ensure all background jobs are truly finished (Fix: Issue #30)
    wait

    # Display final dashboard state
    draw_dashboard

    # ========================================================================
    # PHASE 3.5: Display comprehensive results summary
    # ========================================================================
    # Show detailed results for each updated server including:
    #   - Successful updates without reboot
    #   - Successful updates with reboot
    #   - Failed updates or reboot verification failures
    # ========================================================================
    echo ""
    echo -e "${BOLD}${BLUE}=====================================================================${NC}"
    echo -e "${BOLD}${GREEN}Remote Server Update Results:${NC}"
    echo -e "${BOLD}${BLUE}=====================================================================${NC}"
    echo ""

    # Initialize counters for summary statistics
    servers_updated=0
    servers_rebooted=0
    servers_failed=0

    # Process each approved server and display results
    while IFS= read -r server; do
        # Skip localhost - it will be handled in Phase 4
        if [[ "$server" == "localhost" ]]; then
            continue
        fi

        update_type=""
        reboot_status=""
        result_msg=""
        result_color="${GREEN}"

        # Determine what type of update was performed (kernel or regular)
        update_type=$(safe_read_file "$TEMP_DIR/${server}.update_type" "")

        # For kernel updates, check if reboot was successful
        if [[ "$update_type" == "kernel_update" ]]; then
            reboot_status=$(safe_read_file "$TEMP_DIR/${server}.reboot_status" "")
            if [[ "$reboot_status" == "success" ]]; then
                result_msg="✓ Updated and reboot complete"
                result_color="${GREEN}"
                ((servers_rebooted++))
            else
                result_msg="✗ Updated but failed to verify reboot"
                result_color="${RED}"
                ((servers_failed++))
            fi
        elif [[ "$update_type" == "no_reboot" ]]; then
            result_msg="✓ Successfully updated (no reboot required)"
            result_color="${GREEN}"
            ((servers_updated++))
        else
            # No update type recorded - check status for error messages
            current_status=$(safe_read_file "$TEMP_DIR/${server}.status" "Unknown")
            if [[ "$current_status" == *"ERROR"* ]]; then
                result_msg="✗ Update failed"
                result_color="${RED}"
                ((servers_failed++))
            else
                result_msg="Status: $current_status"
                result_color="${YELLOW}"
            fi
        fi

        display_name=$(get_display_name "$server")
        printf "  ${BOLD}%-35s${NC} ${result_color}%-60s${NC}\n" "$display_name" "$result_msg"
    done < "$TEMP_DIR/approved_servers.txt"

    # Display summary statistics
    echo ""
    echo -e "${BOLD}Summary:${NC}"
    echo -e "  ${GREEN}Servers updated (no reboot): $servers_updated${NC}"
    echo -e "  ${GREEN}Servers updated and rebooted: $servers_rebooted${NC}"
    if [[ $servers_failed -gt 0 ]]; then
        echo -e "  ${RED}Servers with issues: $servers_failed${NC}"
    fi
    echo ""

    sleep 2
fi

# ============================================================================
# PHASE 4: Local Server Update (if localhost was approved)
# ============================================================================
# This phase ONLY executes after all remote servers are complete
# This prevents losing your SSH session while remote updates are in progress
# If the local server requires a kernel update, it will reboot AFTER
# confirming all remote servers are healthy
# ============================================================================

# Check if localhost is in the server list and has updates available
localhost_has_updates=false
for server in "${SERVERS[@]}"; do
    if [[ "$server" == "localhost" ]]; then
        # Check if localhost has updates (check the output file exists and has content)
        if [[ -f "$TEMP_DIR/localhost.output" ]]; then
            status=$(safe_read_file "$TEMP_DIR/localhost.status" "")
            # Only prompt if localhost has updates (not errors or "No updates")
            if [[ "$status" != *"ERROR"* && "$status" != *"No updates"* ]]; then
                # Verify updates are actually available (check for package manager output)
                if grep -q "Transaction Summary\|Listing..." "$TEMP_DIR/localhost.output" 2>/dev/null; then
                    localhost_has_updates=true
                fi
            fi
        fi
        break
    fi
done

if [[ "$localhost_has_updates" == "true" ]]; then
    echo ""
    echo -e "${BOLD}${BLUE}=====================================================================${NC}"
    echo -e "${BOLD}${YELLOW}Local Server Update Pending${NC}"
    echo -e "${BOLD}${BLUE}=====================================================================${NC}"
    echo ""
    echo -e "${YELLOW}All remote servers have completed their updates.${NC}"
    echo -e "${YELLOW}The local server (localhost) is ready to be updated.${NC}"
    echo ""

    # Get package manager for localhost (read from temp file set in Phase 1)
    pkg_manager=$(safe_read_file "$TEMP_DIR/localhost.pkg_manager" "")
    if [[ -z "$pkg_manager" || "$pkg_manager" == "unknown" ]]; then
        # Fallback: detect it now if temp file doesn't exist
        pkg_manager=$(detect_package_manager "localhost")
    fi

    # Show what updates are pending
    if [[ -f "$TEMP_DIR/localhost.output" ]]; then
        echo -e "${BOLD}Updates available for local server:${NC}"
        echo ""

        case "$pkg_manager" in
            apt)
                grep -v "^Listing\.\.\.$" "$TEMP_DIR/localhost.output" | head -20
                ;;
            dnf|yum)
                sed -n '/^Upgrading:/,/^Transaction Summary/p' "$TEMP_DIR/localhost.output" | head -20
                sed -n '/^Installing:/,/^Transaction Summary/p' "$TEMP_DIR/localhost.output" | head -20
                sed -n '/^Transaction Summary/,/^Total download size/p' "$TEMP_DIR/localhost.output"
                ;;
        esac

        echo ""

        # Check if kernel update is included
        output_content=$(cat "$TEMP_DIR/localhost.output")
        if has_kernel_package "$output_content" "$pkg_manager"; then
            echo -e "${RED}${BOLD}⚠️  WARNING: Kernel update detected!${NC}"
            echo -e "${RED}${BOLD}⚠️  The local server will REBOOT after updates complete.${NC}"
            echo -e "${RED}${BOLD}⚠️  You will lose your session if running this script locally.${NC}"
            echo ""
        fi
    fi

    # Prompt for confirmation (or auto-approve in non-interactive mode with assume-yes)
    proceed=false
    if [[ "$NON_INTERACTIVE" == true ]]; then
        if [[ "$ASSUME_YES" == true ]]; then
            echo -e "${GREEN}Auto-approving local server update (--non-interactive --assume-yes mode)${NC}"
            echo ""
            proceed=true
        else
            echo -e "${YELLOW}Skipping local server update (--non-interactive mode without --assume-yes)${NC}"
            echo ""
            proceed=false
        fi
    else
        echo -e "${BOLD}${YELLOW}=====================================================================${NC}"
        echo -e -n "${BOLD}${YELLOW}Proceed with local server update? [y/N]: ${NC}"
        read -r response
        echo ""
        if [[ "$response" =~ ^[Yy]$ ]]; then
            proceed=true
        fi
    fi

    if [[ "$proceed" == "true" ]]; then
        echo -e "${GREEN}Updating local server...${NC}"
        echo ""

        # Determine update command based on package manager
        update_cmd=""
        case "$pkg_manager" in
            apt)
                update_cmd="sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
                ;;
            dnf)
                # Use --assumeyes to ensure no prompts, and -y for compatibility
                update_cmd="sudo dnf update -y --assumeyes"
                ;;
            yum)
                # Use --assumeyes to ensure no prompts, and -y for compatibility
                update_cmd="sudo yum update -y --assumeyes"
                ;;
            *)
                echo -e "${RED}[ERROR]${NC} Unknown package manager on local server"
                exit 1
                ;;
        esac

        # Run update with output shown in real-time
        echo -e "${CYAN}Running: $update_cmd${NC}"
        echo ""

        # Create temp file for output capture (for kernel detection)
        update_output_file="$TEMP_DIR/localhost_update_output.txt"

        # Run update, showing output in real-time and also capturing to file
        timeout "${DNF_TIMEOUT}s" bash -c "$update_cmd" 2>&1 | tee "$update_output_file"
        update_exit_code=${PIPESTATUS[0]}

        if [[ $update_exit_code -eq 124 ]]; then
            echo -e "${RED}[ERROR]${NC} Update command timed out"
            echo "$(date) - ERROR: Local server update timed out" >> "$LOG_FILE"
        elif [[ $update_exit_code -ne 0 ]]; then
            echo -e "${RED}[ERROR]${NC} Update failed"
            echo "$(date) - ERROR: Local server update failed" >> "$LOG_FILE"
        else
            echo ""
            echo -e "${GREEN}✓ Local server updates completed successfully!${NC}"
            echo "$(date) - Local server updated successfully" >> "$LOG_FILE"

            # Check if kernel was updated (read from captured output file)
            kernel_updated=false
            if [[ -f "$update_output_file" ]]; then
                case "$pkg_manager" in
                    apt)
                        if grep -qiE "(linux-image|linux-headers|linux-modules)" "$update_output_file"; then
                            kernel_updated=true
                        fi
                        ;;
                    dnf|yum)
                        if grep -qiE "$KERNEL_UPDATE_REGEX" "$update_output_file"; then
                            kernel_updated=true
                        fi
                        ;;
                esac
            fi

            if [[ "$kernel_updated" == "true" ]]; then
                echo ""
                echo -e "${YELLOW}${BOLD}=====================================================================${NC}"
                echo -e "${YELLOW}${BOLD}⚠️  KERNEL UPDATE DETECTED - REBOOT REQUIRED${NC}"
                echo -e "${YELLOW}${BOLD}=====================================================================${NC}"
                echo ""
                echo -e "${YELLOW}The local server kernel has been updated and requires a reboot.${NC}"
                do_reboot=false
                if [[ "$NON_INTERACTIVE" == true ]]; then
                    if [[ "$ASSUME_YES" == true ]]; then
                        echo ""
                        echo -e "${GREEN}Auto-approving reboot (--non-interactive --assume-yes mode)${NC}"
                        do_reboot=true
                    else
                        echo ""
                        echo -e "${YELLOW}Skipping reboot (--non-interactive mode without --assume-yes)${NC}"
                        do_reboot=false
                    fi
                else
                    echo ""
                    echo -e -n "${BOLD}${RED}Reboot local server now? [y/N]: ${NC}"
                    read -r reboot_response
                    if [[ "$reboot_response" =~ ^[Yy]$ ]]; then
                        do_reboot=true
                    fi
                fi

                if [[ "$do_reboot" == "true" ]]; then
                    echo ""
                    echo -e "${RED}${BOLD}Rebooting local server in 5 seconds...${NC}"
                    echo -e "${YELLOW}This script will terminate. Remote servers are already updated.${NC}"
                    sleep 5
                    echo "$(date) - Initiating local server reboot" >> "$LOG_FILE"
                    sudo reboot
                else
                    echo ""
                    echo -e "${YELLOW}Local server reboot postponed.${NC}"
                    echo -e "${YELLOW}Remember to reboot manually to activate the new kernel.${NC}"
                    echo "$(date) - Local server reboot postponed by user" >> "$LOG_FILE"
                fi
            fi
        fi
    else
        echo -e "${YELLOW}Local server update skipped.${NC}"
        echo "$(date) - Local server update skipped by user" >> "$LOG_FILE"
    fi

    echo ""
fi

# Final summary
echo ""
echo -e "${BOLD}${BLUE}=====================================================================${NC}"
echo -e "${BOLD}${GREEN}All server operations complete!${NC}"
echo -e "${BOLD}${BLUE}Completed: $(date)${NC}"
echo -e "${BOLD}${BLUE}Check $LOG_FILE for detailed logs${NC}"
echo -e "${BOLD}${BLUE}=====================================================================${NC}"
echo ""
