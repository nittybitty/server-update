#!/bin/bash

# Set restrictive umask to prevent world-readable temp files (Fix: Issue #42)
umask 077

# To update the local server, add a line like "local localhost" to your server_list.txt file.

# Server Update Dashboard
# Version: 1.4 (Refactored)

# Terminal detection: colors and the live dashboard only make sense on a real
# terminal. When stdout is a pipe or cron job, escape codes just pollute logs.
if [[ -t 1 ]]; then
    IS_TTY=true
else
    IS_TTY=false
fi

# Color definitions for output (honors NO_COLOR, per https://no-color.org)
if [[ "$IS_TTY" == true && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    REVERSE='\033[7m' # Selected row in the review screen
    NC='\033[0m' # No Color
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; REVERSE=''; NC=''
fi

# Status glyphs: UTF-8 symbols only when the locale can render them. Old-distro
# consoles and LANG=C sessions (common on CentOS 6/7) show mojibake otherwise.
if [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]]; then
    GLYPH_OK="✓"
    GLYPH_FAIL="✗"
    GLYPH_WARN="⚠"
    GLYPH_BULLET="•"
else
    GLYPH_OK="[OK]"
    GLYPH_FAIL="[X]"
    GLYPH_WARN="[!]"
    GLYPH_BULLET="*"
fi

# Configuration
SERVER_LIST="server_list.txt"
LOG_FILE="server_update.log"
LOCK_FILE="/tmp/server_update.lock"

# Constants for disk space requirements (Issue #10)
readonly MIN_ROOT_SPACE_GB=2
readonly MIN_BOOT_SPACE_MB=300

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
# DASHBOARD_WIDTH: Force the dashboard table width in columns (40-1000).
# Empty means auto-detect. Set it when the terminal reports the wrong size,
# for example an old `tput` that always answers 80.
DASHBOARD_WIDTH="${DASHBOARD_WIDTH:-}"
# APPLY_TIMEOUT: Maximum time (seconds) for the actual update run in Phase 3/4
# (default: 3600 = 1 hour). Separate from DNF_TIMEOUT (the check phase): big
# updates on old/slow hardware routinely exceed 10 minutes, and killing a
# package transaction mid-flight risks rpmdb/dpkg corruption.
APPLY_TIMEOUT=3600

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
    local allowed_vars=("DNF_TIMEOUT" "APPLY_TIMEOUT" "KERNEL_PACKAGE_REGEX" "KERNEL_UPDATE_REGEX" "REBOOT_MAX_WAIT" "REBOOT_WAIT_INTERVAL" "DASHBOARD_REFRESH" "DASHBOARD_WIDTH")

    # Parse config file safely - only allow whitelisted variable assignments.
    # The `|| [[ -n "$key" ]]` guard still processes a final line that lacks a
    # trailing newline (read returns nonzero but has filled the variables).
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
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

                # Validate the dashboard width separately: it is a column
                # count, not a duration, so the seconds range does not apply
                if [[ "$key" == "DASHBOARD_WIDTH" ]]; then
                    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 40 ]] || [[ "$value" -gt 1000 ]]; then
                        echo -e "${YELLOW}[WARNING]${NC} Invalid value for $key in config file (must be 40-1000). Using auto-detection."
                        continue
                    fi
                fi

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
                    # Reject zero: REBOOT_WAIT_INTERVAL=0 would divide by zero
                    # and DASHBOARD_REFRESH=0 would busy-loop
                    if [[ "$value" -lt 1 ]]; then
                        echo -e "${YELLOW}[WARNING]${NC} Value for $key must be at least 1. Using default."
                        continue
                    fi
                fi

                # Validate regex patterns with ReDoS protection
                if [[ "$key" =~ REGEX ]]; then
                    # Reject an empty pattern BEFORE the syntax check: an empty
                    # regex is syntactically valid and matches EVERY input in
                    # both engines this script uses ([[ =~ ]] and grep -E), so
                    # the syntax check waves it through. An empty
                    # KERNEL_UPDATE_REGEX would classify every dnf/yum run as a
                    # kernel update and reboot every server in the list. A bare
                    # `KEY=` is the obvious way to get here; an unquoted value
                    # containing an apostrophe is the subtle one (the xargs
                    # round-trip above fails on the unmatched quote and yields
                    # an empty string).
                    if [[ -z "${value//[[:space:]]/}" ]]; then
                        echo -e "${YELLOW}[WARNING]${NC} Empty regex pattern for $key in config file (an empty pattern matches everything). Using default."
                        continue
                    fi
                    # Test regex with timeout to prevent catastrophic backtracking.
                    # The pattern is passed as an argument (never interpolated into
                    # a shell string), so config values cannot inject commands here.
                    # Capture $? directly: the old `if ! cmd; then regex_exit=$?`
                    # form read the NEGATED status (always 0), so broken regexes
                    # were never actually rejected.
                    timeout 1s grep -E -- "$value" >/dev/null 2>&1 <<< "kernel-core-5.14.0"
                    regex_exit=$?
                    # Exit codes: 0=match, 1=no match, 2+=error, 124=timeout
                    if [[ $regex_exit -ge 2 || $regex_exit -eq 124 ]]; then
                        echo -e "${YELLOW}[WARNING]${NC} Invalid or dangerous regex pattern for $key in config file. Using default."
                        continue
                    fi
                fi

                # Assign the validated value. printf -v cannot execute the
                # value -- unlike eval, which ran $(...) embedded in config values
                printf -v "$key" '%s' "$value"
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
# Atomic lock acquisition: noclobber turns the redirection into O_CREAT|O_EXCL,
# so two instances racing here can't both win (the old check-then-create had a
# window), and a pre-planted symlink at the lock path is not followed.
acquire_lock() {
    (set -o noclobber; echo "$$" > "$LOCK_FILE") 2>/dev/null
}

if ! acquire_lock; then
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null)

    # Check if that PID is still running
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} Another instance of this script is already running (PID: $existing_pid)"
        echo -e "${RED}[ERROR]${NC} Lock file: $LOCK_FILE"
        echo -e "${YELLOW}[INFO]${NC} If you're sure no other instance is running, remove the lock file:"
        echo -e "${YELLOW}[INFO]${NC}   rm $LOCK_FILE"
        exit 1
    fi

    # Stale lock file (process no longer exists, or unreadable/empty file)
    echo -e "${YELLOW}[WARNING]${NC} Removing stale lock file from PID ${existing_pid:-unknown}"
    rm -f "$LOCK_FILE"
    if ! acquire_lock; then
        echo -e "${RED}[ERROR]${NC} Failed to create lock file: $LOCK_FILE"
        echo -e "${YELLOW}[INFO]${NC} Check permissions on /tmp directory"
        exit 1
    fi
fi

# Create temporary directory with secure permissions (700 - owner only)
TEMP_DIR=$(mktemp -d /tmp/server_update.XXXXXX)
if [[ ! -d "$TEMP_DIR" ]]; then
    echo -e "${RED}[ERROR]${NC} Failed to create temporary directory"
    exit 1
fi
chmod 700 "$TEMP_DIR"

# SSH connection multiplexing socket directory. Lives inside TEMP_DIR so it's
# wiped by the same cleanup path. %C in ControlPath hashes user@host:port into
# a fixed-length token, keeping socket paths well under sun_path's 108-byte cap
# no matter how long the hostnames get.
SSH_CONTROL_DIR="$TEMP_DIR/ssh-cm"
mkdir "$SSH_CONTROL_DIR"
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

# Function to check whether a server entry refers to this machine.
# Phase 2/3 must skip every local alias -- not just the literal "localhost" --
# or a kernel update on a "127.0.0.1" entry would reboot the control host
# mid-run while other servers are still being monitored. Phase 4 handles the
# local machine last, after all remotes are done.
# Parameters: $1 = server address
# Returns: 0 if local, 1 otherwise
is_localhost() {
    [[ "$1" == "localhost" || "$1" == "127.0.0.1" || "$1" == "::1" ]]
}

# ============================================================================
# ATOMIC TEMP FILE UTILITIES - Prevent torn reads of shared state
# ============================================================================
# Background jobs write per-server state files that the dashboard reads
# concurrently. We rely on rename(2) being atomic on a single filesystem: a
# writer stages content in a unique temp file and renames it into place, so a
# concurrent reader always sees either the previous file or the fully-written
# new one -- never an empty or half-written file. This is cheaper than flock
# (no lock file, no extra fork per read) and gives the same safety here, since
# writes are whole-file and last-writer-wins is the desired semantics.

# Function to atomically write content to a file
# Parameters: $1 = file path, $2 = content to write
# Returns: 0 on success, 1 on failure
safe_write_file() {
    local file_path="$1"
    local content="$2"

    # Unique temp name so concurrent writers never collide on the staging file;
    # the final rename is the only externally visible state change. $BASHPID (not
    # $$) is the *real* PID of this process -- background jobs run in subshells
    # where $$ still holds the parent's PID, so $BASHPID is what makes the name
    # unique per writer. Requires bash 4.0+, which this script already mandates
    # (associative arrays).
    local tmp="${file_path}.$BASHPID.tmp"
    echo "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$file_path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Function to read a single-line state file written by safe_write_file.
# Parameters: $1 = file path, $2 = default value if file is missing (optional)
# Returns: result in the global SRF_RESULT (NOT stdout).
#
# Why a global instead of echoing through stdout: the dashboard reads 3 files per
# server on every refresh, and `var=$(safe_read_file ...)` forks a subshell for
# the command substitution each time. Writing into a global lets hot callers skip
# that fork entirely. Combined with the `read` builtin (no `cat` exec), this is
# ~40x cheaper per read than the old `cat` + `$()` form. A plain global is used
# rather than a `declare -n` nameref so this still runs on the bash 4.0-4.2
# controllers (CentOS/RHEL 6/7) that v1.4 restored support for.
#
# Correctness: state files are single-line and safe_write_file always appends a
# trailing newline (echo), so `read` returns 0 and captures the whole value.
# Atomic-rename writes mean we never observe a partial/torn file, so a missing
# file is the only failure mode -- the input redirection fails and we fall back
# to the default. stderr is redirected *before* the input redirection so the
# shell's "No such file" message is swallowed.
SRF_RESULT=""
safe_read_file() {
    local file_path="$1"
    local default_value="${2:-}"

    IFS= read -r SRF_RESULT 2>/dev/null < "$file_path" || SRF_RESULT="$default_value"
}

# ============================================================================
# Helper Functions for Output and Caching (Refactoring - Issue #11, #2)
# ============================================================================

# Color output helper functions
print_header() {
    echo -e "${BOLD}${BLUE}$1${NC}"
}

print_separator() {
    local width="${1:-69}"
    local char="${2:-=}"
    printf "${BLUE}%${width}s${NC}\n" | tr ' ' "$char"
}

print_error() {
    echo -e "${RED}${BOLD}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_info() {
    echo -e "${CYAN}$1${NC}"
}

# Caching wrapper for package manager reads (Issue #2)
get_pkg_manager() {
    local server="$1"
    if [[ -z "${PKG_MANAGER_CACHE[$server]}" ]]; then
        safe_read_file "$TEMP_DIR/${server}.pkg_manager" "unknown"
        PKG_MANAGER_CACHE[$server]="$SRF_RESULT"
    fi
    echo "${PKG_MANAGER_CACHE[$server]}"
}

# Caching wrapper for display name (Issue #13)
get_display_name() {
    local server="$1"
    if [[ -z "${DISPLAY_NAME_CACHE[$server]}" ]]; then
        DISPLAY_NAME_CACHE[$server]="$server (${SERVER_NICKNAMES[$server]})"
    fi
    echo "${DISPLAY_NAME_CACHE[$server]}"
}

# Filter apt output header (Issue #12)
# Unanchored at the end: with a tty apt prints "Listing... Done", without one
# just "Listing...". Package lines can't false-match (they start with "name/").
filter_apt_header() {
    grep -v "^Listing\.\.\." "$@"
}

# ============================================================================

# Function to display usage information
show_help() {
    echo "Server Update Dashboard - Version 1.4 (Refactored)"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run          Check for updates but don't apply them"
    echo "  --check-only       Display available updates without prompting"
    echo "  --assume-yes       Automatically approve all updates (use with caution)"
    echo "  --non-interactive  Skip all interactive prompts (for automation/testing)"
    echo "  --classic-review   Review servers one at a time instead of the"
    echo "                     interactive review screen"
    echo "  --version          Display version information"
    echo "  --help             Display this help message"
    echo ""
    echo "Configuration:"
    echo "  Server list: $SERVER_LIST"
    echo "  Log file:    $LOG_FILE"
    echo "  Config file: server_update.conf (optional)"
    echo ""
    echo "Environment:"
    echo "  NO_COLOR           Disable colored output (also disabled when stdout"
    echo "                     is not a terminal)"
    echo ""
    echo "For more information, see CLAUDE.md"
    exit 0
}

# Function to display version information
show_version() {
    echo "Server Update Dashboard"
    echo "Version: 1.4 (Refactored)"
    exit 0
}

# Parse command-line options
DRY_RUN=false
CHECK_ONLY=false
ASSUME_YES=false
NON_INTERACTIVE=false
CLASSIC_REVIEW=false

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
        --classic-review)
            CLASSIC_REVIEW=true
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
CLEANUP_DONE=false
cleanup() {
    # Run once. The INT/TERM handler calls cleanup and then exits, which fires
    # the EXIT trap and would otherwise run the whole body a second time.
    [[ "$CLEANUP_DONE" == true ]] && return 0
    CLEANUP_DONE=true

    # Restore the cursor and clear any leftover attribute (the review screen
    # draws the selected row in reverse video, so Ctrl-C mid-frame would
    # otherwise leave the terminal inverted).
    [[ "${IS_TTY:-false}" == true ]] && printf '\033[?25h\033[0m'

    # Close the review screen's keyboard descriptor if it is still open
    exec 3<&- 2>/dev/null

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

    # Close any open SSH ControlMaster sessions so master processes exit
    # promptly instead of lingering until ControlPersist expires.
    if [[ -n "${SSH_CONTROL_DIR:-}" && -d "$SSH_CONTROL_DIR" ]]; then
        local sock
        for sock in "$SSH_CONTROL_DIR"/cm-*; do
            [[ -S "$sock" ]] || continue
            ssh -S "$sock" -O exit _ 2>/dev/null || true
        done
    fi

    # Remove temporary directory
    rm -rf "$TEMP_DIR"

    # Remove instance lock file
    rm -f "$LOCK_FILE"
}

# Cleanup on exit - kill background jobs and remove temporary directory.
#
# INT/TERM must exit, not just clean up. A bash trap handler returns to the
# point of interruption, so a single `trap cleanup EXIT INT TERM` let Ctrl-C
# run cleanup() and then CONTINUE into the following phases: the run printed
# "Update check complete" and a results summary for a job the user cancelled,
# and -- worse -- cleanup() had already removed $LOCK_FILE, so a second
# instance could start while this one was still working.
# 130 = 128 + SIGINT, the conventional shell status for an interrupted run.
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

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

# Caching arrays for performance (Issue #2)
declare -A PKG_MANAGER_CACHE
declare -A DISPLAY_NAME_CACHE

line_number=0

# The `|| [[ ${#parts[@]} -gt 0 ]]` guard still processes a final line that
# lacks a trailing newline (read returns nonzero but has filled the array) --
# previously the last server in such a file was silently dropped.
while read -r -a parts || [[ ${#parts[@]} -gt 0 ]]; do
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

    # Reject duplicate server addresses - the keyed arrays would silently
    # merge them (last nickname/port wins) and the host would be updated
    # twice in parallel
    if [[ -n "${SERVER_NICKNAMES[$server]}" ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Line $line_number: Duplicate entry for '$server', skipping"
        continue
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

    # Probe in a single shell invocation so remote detection costs one SSH
    # round-trip instead of up to three. Order matters: apt first (Debian/Ubuntu),
    # then dnf (RHEL 8+/Fedora), then yum (RHEL 7).
    local probe='if command -v apt-get >/dev/null 2>&1; then echo apt
elif command -v dnf >/dev/null 2>&1; then echo dnf
elif command -v yum >/dev/null 2>&1; then echo yum
else echo unknown
fi'
    local result
    if [[ -n "$ssh_cmd" ]]; then
        # shellcheck disable=SC2086
        result=$($ssh_cmd "$server" "$probe" 2>/dev/null)
    else
        result=$(bash -c "$probe" 2>/dev/null)
    fi
    echo "${result:-unknown}"
}

# Function to discover a server in a single SSH round-trip: package manager,
# OS release, and kernel version all at once. This replaces what used to be a
# separate connection test + detect_package_manager + 2-4 gather_system_info
# round-trips (the discovery "N+1"). Because the remote snippet always prints a
# "PM=" line, its presence in the output doubles as the connection test -- if the
# connection or remote shell failed, there is no "PM=" to find.
#
# Parameters: $1 = server address
# Side effects: writes ${server}.pkg_manager, ${server}.os_release, ${server}.kernel
# Returns: 0 on success, 124 on timeout, 1 on connection/other failure
probe_server_info() {
    local server="$1"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")

    # POSIX-sh remote snippet (a remote /bin/sh may be dash, not bash). It is
    # written with NO single quotes so the whole thing can be passed as one
    # single-quoted bash argument. Package manager order matches the old
    # detect_package_manager: apt (Debian/Ubuntu), then dnf (RHEL 8+/Fedora),
    # then yum (RHEL 7). OS name uses the same fallback chain as before --
    # /etc/os-release PRETTY_NAME -> lsb_release -d -> /etc/redhat-release -- so
    # pre-systemd hosts (CentOS/RHEL 6) still populate the column. The PRETTY_NAME
    # value is unwrapped with prefix/suffix stripping rather than `cut -d'"'`,
    # which also handles unquoted values (e.g. PRETTY_NAME=Fedora).
    local probe='pm=unknown
if command -v apt-get >/dev/null 2>&1; then pm=apt
elif command -v dnf >/dev/null 2>&1; then pm=dnf
elif command -v yum >/dev/null 2>&1; then pm=yum
fi
os=$(grep "^PRETTY_NAME=" /etc/os-release 2>/dev/null | head -n 1)
os=${os#PRETTY_NAME=}
os=${os#\"}
os=${os%\"}
[ -z "$os" ] && os=$(lsb_release -d 2>/dev/null | cut -f2)
[ -z "$os" ] && os=$(cat /etc/redhat-release 2>/dev/null)
[ -z "$os" ] && os=Unknown
kn=$(uname -r 2>/dev/null || echo Unknown)
printf "PM=%s\n" "$pm"
printf "OS=%s\n" "$os"
printf "KERNEL=%s\n" "$kn"'

    # 15s overall cap matches the old connection test. ssh's own ConnectTimeout=10
    # fires first on an unreachable host (exit 255); a hang past 15s yields 124.
    # ssh stderr is kept (not discarded) so connection failures can be classified
    # and logged -- "Cannot connect" alone is useless when the real problem is an
    # auth failure or a legacy-algorithm mismatch with an old sshd.
    local output rc
    if [[ -n "$ssh_cmd" ]]; then
        # shellcheck disable=SC2086
        output=$(timeout 15s $ssh_cmd "$server" "$probe" 2>"$TEMP_DIR/${server}.ssh_err")
        rc=$?
    else
        output=$(timeout 15s bash -c "$probe" 2>/dev/null)
        rc=$?
    fi

    if [[ $rc -eq 124 ]]; then
        return 124
    fi
    # The PM= sentinel proves the remote shell actually ran. Without it the
    # connection (or remote shell) failed, whatever the exit code.
    if [[ "$output" != *"PM="* ]]; then
        return 1
    fi

    # Split on the FIRST '=' only, so OS names containing '=', spaces, or parens
    # survive intact.
    local pm="unknown" os_info="Unknown" kernel_ver="Unknown" line
    while IFS= read -r line; do
        case "$line" in
            PM=*)     pm="${line#PM=}" ;;
            OS=*)     os_info="${line#OS=}" ;;
            KERNEL=*) kernel_ver="${line#KERNEL=}" ;;
        esac
    done <<< "$output"

    # Normalize empties so the dashboard shows "--"/"unknown" rather than blanks.
    [[ -z "$pm" ]] && pm="unknown"
    [[ -z "$os_info" ]] && os_info="Unknown"
    [[ -z "$kernel_ver" ]] && kernel_ver="Unknown"

    safe_write_file "$TEMP_DIR/${server}.pkg_manager" "$pm"
    safe_write_file "$TEMP_DIR/${server}.os_release" "$os_info"
    safe_write_file "$TEMP_DIR/${server}.kernel" "$kernel_ver"
    return 0
}

# Function to map ssh stderr to a short human-readable reason for the dashboard.
# Old targets are a common trip-wire here: OpenSSH 8.8+ controllers disable
# ssh-rsa/SHA-1 by default, so a CentOS 6 sshd fails algorithm negotiation --
# without this the user just sees a generic "Cannot connect".
# Parameters: $1 = path to captured ssh stderr file
# Returns: reason in the global SSH_ERROR_REASON ("" if unrecognized)
SSH_ERROR_REASON=""
classify_ssh_error() {
    local err=""
    [[ -f "$1" ]] && err=$(<"$1")

    SSH_ERROR_REASON=""
    case "$err" in
        *"Permission denied"*)                  SSH_ERROR_REASON="auth failed" ;;
        *"no matching"*)                        SSH_ERROR_REASON="SSH algorithm mismatch (legacy host?)" ;;
        *"IDENTIFICATION HAS CHANGED"*)         SSH_ERROR_REASON="host key changed" ;;
        *"Host key verification failed"*)       SSH_ERROR_REASON="host key verification failed" ;;
        *"Could not resolve"*)                  SSH_ERROR_REASON="DNS lookup failed" ;;
        *"Connection refused"*)                 SSH_ERROR_REASON="connection refused" ;;
        *"Connection timed out"*|*"timed out"*) SSH_ERROR_REASON="connection timed out" ;;
        *"Network is unreachable"*)             SSH_ERROR_REASON="network unreachable" ;;
    esac
}

# Controller-side SSH option fragments, filled in by detect_ssh_capabilities().
# These gate on the *local* client's OpenSSH version because they are all
# client-side options; remote targets only need to speak SSH-2 (every OpenSSH
# since 2.x does), so an ancient target like CentOS 6 is always fine to manage.
# Defaults are the lowest-common-denominator (works back to OpenSSH 5.x) and are
# upgraded in place once we know the client supports more.
SSH_HOSTKEY_OPT="-o StrictHostKeyChecking=no"
SSH_MUX_OPTS=""

# Function to detect what the *local* ssh client supports, run once at startup.
# Side effects: sets SSH_HOSTKEY_OPT and SSH_MUX_OPTS globals.
detect_ssh_capabilities() {
    # `ssh -V` prints to stderr, e.g. "OpenSSH_8.0p1, OpenSSL ...".
    local ver_line major=0 minor=0
    ver_line=$(ssh -V 2>&1)
    if [[ "$ver_line" =~ OpenSSH_([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
    fi
    local ver=$((major * 100 + minor))  # encode as M*100+m: 7.6 -> 706, 6.7 -> 607

    # Host key policy: accept-new (TOFU without prompting) needs OpenSSH 7.6.
    # Older clients only understand yes/no/ask, so fall back to no (the script's
    # historical behavior) rather than erroring out on an unknown value.
    if (( ver >= 706 )); then
        SSH_HOSTKEY_OPT="-o StrictHostKeyChecking=accept-new"
    else
        SSH_HOSTKEY_OPT="-o StrictHostKeyChecking=no"
    fi

    # Connection multiplexing needs the ControlPath %C token (OpenSSH 6.7) and
    # ControlPersist (5.6). %C is the binding constraint. If the client is older
    # (e.g. CentOS 6's 5.3), skip multiplexing entirely: correct, just one
    # handshake per command like before pooling existed.
    if (( ver >= 607 )); then
        SSH_MUX_OPTS="-o ControlMaster=auto -o ControlPath=$SSH_CONTROL_DIR/cm-%C -o ControlPersist=600"
    else
        SSH_MUX_OPTS=""
    fi
}

# Function to get SSH command with port and options
# Parameters: $1 = server address
# Returns: SSH command string with appropriate options, or empty string for localhost
get_ssh_cmd() {
    local server="$1"

    # For localhost, don't use SSH (Fix: Issue #28 - better localhost detection)
    if is_localhost "$server"; then
        echo ""
        return
    fi

    # Option set is chosen by detect_ssh_capabilities() based on the local ssh
    # version. SSH_MUX_OPTS is empty on pre-6.7 clients (multiplexing disabled),
    # and SSH_HOSTKEY_OPT degrades accept-new -> no on pre-7.6 clients. When mux
    # is enabled it reuses one session per (user,host,port) for the script's
    # lifetime; if a master can't open, auto-mode degrades to a direct connection.
    local base_ssh="ssh $SSH_HOSTKEY_OPT -o ConnectTimeout=10 $SSH_MUX_OPTS"
    if [[ -n "${SERVER_PORTS[$server]}" ]]; then
        echo "$base_ssh -p ${SERVER_PORTS[$server]}"
    else
        echo "$base_ssh"
    fi
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

    # Force C locale so package manager output stays English-parseable
    # (we grep for "Nothing to do", "Transaction Summary", etc).
    local lc_command="export LC_ALL=C; $command"

    if [[ -n "$ssh_cmd" ]]; then
        # shellcheck disable=SC2086
        timeout "${timeout}s" $ssh_cmd "$server" "$lc_command" 2>&1
    else
        # For localhost, test if sudo works first (only if command contains sudo)
        if [[ "$command" == *"sudo"* ]]; then
            if ! test_localhost_sudo; then
                echo "ERROR: Passwordless sudo is not configured for localhost"
                return 1
            fi
        fi
        timeout "${timeout}s" bash -c "$lc_command" 2>&1
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
        # Separate calls so a missing /boot partition doesn't poison the / result
        # shellcheck disable=SC2086
        root_avail=$($ssh_cmd "$server" "df -BG / 2>/dev/null | tail -1 | awk '{print \$4}' | sed 's/G//'" 2>/dev/null)
        # shellcheck disable=SC2086
        boot_avail=$($ssh_cmd "$server" "df -BM /boot 2>/dev/null | tail -1 | awk '{print \$4}' | sed 's/M//'" 2>/dev/null)
    else
        # Localhost: direct commands
        root_avail=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
        boot_avail=$(df -BM /boot 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/M//' 2>/dev/null)
    fi

    # Check if we got valid numbers
    if [[ ! "$root_avail" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Could not determine disk space for / on $(get_display_name "$server")"
        return 0  # Allow to proceed if we can't check (non-fatal)
    fi

    # Require minimum free space on / (using constant)
    if [[ "$root_avail" -lt "$MIN_ROOT_SPACE_GB" ]]; then
        print_error "Insufficient disk space on / for $(get_display_name "$server")"
        print_error "Available: ${root_avail}GB, Required: ${MIN_ROOT_SPACE_GB}GB minimum"
        return 1
    fi

    # Check /boot if it exists as a separate partition (non-fatal if it doesn't exist)
    if [[ -n "$boot_avail" && "$boot_avail" =~ ^[0-9]+$ ]]; then
        # Require minimum free space on /boot (using constant)
        if [[ "$boot_avail" -lt "$MIN_BOOT_SPACE_MB" ]]; then
            print_error "Insufficient disk space on /boot for $(get_display_name "$server")"
            print_error "Available: ${boot_avail}MB, Required: ${MIN_BOOT_SPACE_MB}MB minimum"
            return 1
        fi
    fi

    return 0
}

# Function to check if output contains kernel package references
# Parameters: $1 = text to search, $2 = package manager type (optional)
# Returns: 0 if kernel package found, 1 otherwise
has_kernel_package() {
    local text="$1"
    local pkg_manager="${2:-dnf}"

    # Select the kernel pattern: apt uses fixed package prefixes; dnf/yum use the
    # configurable KERNEL_PACKAGE_REGEX.
    local regex
    case "$pkg_manager" in
        apt) regex="(linux-image|linux-headers|linux-modules)" ;;
        *)   regex="$KERNEL_PACKAGE_REGEX" ;;
    esac

    # The Phase 2 review loops call this once per package line. For a single-line
    # subject, match with the bash regex engine instead of forking grep per line
    # (~200x cheaper per call). ^/$ anchors behave the same as grep's per-line
    # match when the subject is one line. Multi-line blobs (whole-output scans)
    # still go through grep, where ^/$ must anchor at each embedded newline --
    # bash =~ would only anchor at the ends of the whole string.
    if [[ "$text" == *$'\n'* ]]; then
        # Strip leading indentation first: dnf/yum transaction tables indent
        # package rows by one space, which defeated the ^kernel anchor in
        # KERNEL_PACKAGE_REGEX (the Phase 2 kernel warning never fired for
        # dnf/yum whole-output scans).
        echo "$text" | sed 's/^[[:space:]]*//' | grep -qiE "$regex"
        return $?
    fi

    # Single line: strip the same leading indentation the multi-line path
    # strips, so both paths answer the same for the same package row. Callers
    # that keep the indentation for display (the review screen reads package
    # lines with mapfile) depend on this.
    local subject="${text#"${text%%[![:space:]]*}"}"

    # Replicate grep -i case-insensitivity via nocasematch, then restore the
    # prior shell state (shopt -q is a builtin, so no fork).
    local rc restore=0
    shopt -q nocasematch || { shopt -s nocasematch; restore=1; }
    [[ "$subject" =~ $regex ]]; rc=$?
    (( restore )) && shopt -u nocasematch
    return $rc
}

# Function to parse DNF/YUM output and extract package counts
# Transaction Summary lines vary by generation: dnf and RHEL 7 yum say
# "Install/Upgrade N Package(s)", but RHEL 6 yum says "Update N Package(s)" --
# the old Install/Upgrade-only grep undercounted there. One awk pass sums all
# three ("+0" guarantees a numeric result even with no matches).
# Parameters: $1 = dnf/yum output text
# Returns: Total count of packages to install/upgrade (echoed to stdout)
parse_dnf_package_count() {
    local dnf_output="$1"
    echo "$dnf_output" | awk '/^(Install|Upgrade|Update)[[:space:]]/ {s+=$2} END {print s+0}'
}

# Terminal width detection. Result in the global TERM_WIDTH.
#
# Detection order matters. `tput cols` reads the terminfo entry for $TERM and
# asks the kernel for the real window size only on newer ncurses builds. Older
# builds (CentOS/RHEL 6 and 7), an unknown $TERM, and a $TERM whose entry has a
# hardcoded width all return 80 in a 200-column window. `stty size` asks the
# kernel directly (TIOCGWINSZ) and does not use terminfo, so it goes first.
# Order: DASHBOARD_WIDTH override, stty on /dev/tty, stty on stderr, tput cols,
# COLUMNS, then 80.
get_term_width() {
    local w=""

    # Explicit override from server_update.conf or the environment
    if [[ "${DASHBOARD_WIDTH:-}" =~ ^[0-9]+$ ]] && (( DASHBOARD_WIDTH >= 40 && DASHBOARD_WIDTH <= 1000 )); then
        TERM_WIDTH=$DASHBOARD_WIDTH
        return
    fi

    # stty prints "rows cols"; keep the last field. /dev/tty is the controlling
    # terminal even when stdout is a pipe (which is what happens inside every
    # command substitution, and is why tput can miss the size).
    w=$(stty size 2>/dev/null </dev/tty); w="${w##* }"
    if ! [[ "$w" =~ ^[0-9]+$ ]] || (( w < 40 )); then
        w=$(stty size 2>/dev/null <&2); w="${w##* }"
    fi
    if ! [[ "$w" =~ ^[0-9]+$ ]] || (( w < 40 )); then
        w=$(tput cols 2>/dev/null)
    fi
    if ! [[ "$w" =~ ^[0-9]+$ ]] || (( w < 40 )); then
        w="${COLUMNS:-}"
    fi

    if [[ "$w" =~ ^[0-9]+$ ]] && (( w >= 40 )); then
        TERM_WIDTH=$w
    else
        TERM_WIDTH=80
    fi
}

# Terminal height detection. Result in the global TERM_HEIGHT.
#
# Same source order and same reasoning as get_term_width: `tput lines` answers
# from terminfo and reports 24 for an unknown $TERM, so `stty size` (which asks
# the kernel) goes first. Only the review screen needs this -- the dashboard
# prints one line per server and lets the terminal scroll.
# Order: stty on /dev/tty, stty on stderr, tput lines, LINES, then 24.
get_term_height() {
    local h=""

    # stty prints "rows cols"; keep the first field
    h=$(stty size 2>/dev/null </dev/tty); h="${h%% *}"
    if ! [[ "$h" =~ ^[0-9]+$ ]] || (( h < 10 )); then
        h=$(stty size 2>/dev/null <&2); h="${h%% *}"
    fi
    if ! [[ "$h" =~ ^[0-9]+$ ]] || (( h < 10 )); then
        h=$(tput lines 2>/dev/null)
    fi
    if ! [[ "$h" =~ ^[0-9]+$ ]] || (( h < 10 )); then
        h="${LINES:-}"
    fi

    if [[ "$h" =~ ^[0-9]+$ ]] && (( h >= 10 )); then
        TERM_HEIGHT=$h
    else
        TERM_HEIGHT=24
    fi
}

# Read one keystroke from file descriptor 3 and name it in the global KEY.
#
# Returns via a global for the same reason safe_read_file and truncate_field do:
# a command substitution would fork a subshell on every keypress.
#
# Arrow and navigation keys arrive as an escape sequence of two or three more
# bytes. The short -t timeout separates a real Escape key (nothing follows)
# from the start of a sequence. Terminals disagree on the last group: xterm
# sends ESC [ H for Home, while others send ESC O H, so both are mapped.
#
# `read -n1` strips the delimiter, so pressing Enter yields an empty string.
#
# The first read has a one second timeout and reports KEY="TIMEOUT" when it
# expires. That is how the screen notices a resize: bash defers a trapped
# signal until the running builtin returns, so a SIGWINCH trap does NOT
# interrupt a blocking read, and the screen would keep the old width until the
# next keypress. Polling costs one wakeup per second and needs no trap.
#
# Returns 1 only at real end of input.
KEY=""
KEY_POLL=1
read_key() {
    local k="" rest="" rc=0

    IFS= read -rsn1 -t "$KEY_POLL" -u 3 k
    rc=$?
    if (( rc != 0 )); then
        # Bash returns a status above 128 when the read times out, and 1 at
        # end of input
        if (( rc > 128 )); then
            KEY="TIMEOUT"
            return 0
        fi
        KEY="EOF"
        return 1
    fi

    if [[ "$k" == $'\033' ]]; then
        IFS= read -rsn2 -t 0.05 -u 3 rest 2>/dev/null
        case "$rest" in
            '[A'|'OA') KEY="UP" ;;
            '[B'|'OB') KEY="DOWN" ;;
            '[C'|'OC') KEY="RIGHT" ;;
            '[D'|'OD') KEY="LEFT" ;;
            '[H'|'OH'|'[1') KEY="HOME" ;;
            '[F'|'OF'|'[4') KEY="END" ;;
            '[5') KEY="PGUP" ;;
            '[6') KEY="PGDN" ;;
            '') KEY="ESC" ;;
            *) KEY="OTHER" ;;
        esac
        # Sequences of the form ESC [ N ~ have one more byte to discard
        case "$rest" in
            '[1'|'[4'|'[5'|'[6') IFS= read -rsn1 -t 0.05 -u 3 rest 2>/dev/null ;;
        esac
        return 0
    fi

    if [[ -z "$k" ]]; then
        KEY="ENTER"
    else
        KEY="$k"
    fi
    return 0
}

# Column headers, the smallest width each column can drop to, and the widest
# it can grow to once the table has to compete for room.
readonly HDR_SRV="SERVER" HDR_OS="OS DISTRIBUTION" HDR_KRN="KERNEL VERSION" HDR_STS="STATUS"
readonly MIN_COL_SRV=16 MIN_COL_OS=8 MIN_COL_KRN=8 MIN_COL_STS=16
readonly MAX_COL_SRV=44 MAX_COL_STS=60
# How much wider than the OS and kernel columns the status column stays when
# the table has to give up room.
readonly STS_BONUS=8

# Size the columns from the data instead of from a fixed table. Every column
# starts at its natural width (the longest value it must show). If the row fits
# the terminal, nothing is cut and the spare room goes to the status column.
# Parameters: $1 = terminal width, $2-$5 = natural width of each column
# Side effects: sets COL_SRV, COL_OS, COL_KRN, COL_STS globals
compute_dashboard_layout() {
    local w="$1"
    COL_SRV="$2"; COL_OS="$3"; COL_KRN="$4"; COL_STS="$5"

    local avail=$((w - 3))   # three single-space column separators
    local over=$(( COL_SRV + COL_OS + COL_KRN + COL_STS - avail ))

    if (( over <= 0 )); then
        # Spare room goes to the status column, so long messages stay whole
        COL_STS=$(( COL_STS - over ))
        return
    fi

    # The row does not fit. Cap the two columns that can run very long, so a
    # single huge value cannot take the whole row.
    (( COL_SRV > MAX_COL_SRV )) && COL_SRV=$MAX_COL_SRV
    (( COL_STS > MAX_COL_STS )) && COL_STS=$MAX_COL_STS
    over=$(( COL_SRV + COL_OS + COL_KRN + COL_STS - avail ))
    if (( over <= 0 )); then
        COL_STS=$(( COL_STS - over ))
        return
    fi

    # Take the rest one character at a time from whichever secondary column is
    # currently the widest, which keeps the three balanced. Status counts as
    # STS_BONUS narrower than it is, so it stays the widest of the three. The
    # server column is the last to give up room: its "address (nickname)"
    # label is what identifies the row.
    local sts_eff
    while (( over > 0 )); do
        sts_eff=$(( COL_STS - STS_BONUS ))
        if (( COL_STS > MIN_COL_STS && sts_eff >= COL_OS && sts_eff >= COL_KRN )); then
            (( COL_STS-- ))
        elif (( COL_OS > MIN_COL_OS && COL_OS >= COL_KRN )); then
            (( COL_OS-- ))
        elif (( COL_KRN > MIN_COL_KRN )); then
            (( COL_KRN-- ))
        elif (( COL_OS > MIN_COL_OS )); then
            (( COL_OS-- ))
        elif (( COL_STS > MIN_COL_STS )); then
            (( COL_STS-- ))
        elif (( COL_SRV > MIN_COL_SRV )); then
            (( COL_SRV-- ))
        else
            break   # narrower than the table can go; rows wrap from here
        fi
        (( over-- ))
    done
}

# Truncate $1 to $2 characters with a "..." marker. Result in the global
# TRUNC_RESULT (same fork-free return pattern as safe_read_file).
truncate_field() {
    local s="$1" w="$2"
    if (( ${#s} > w )); then
        TRUNC_RESULT="${s:0:w-3}..."
    else
        TRUNC_RESULT="$s"
    fi
}

# Function to draw the live-updating dashboard showing all server statuses
# Repaints in place: cursor-home plus erase-to-end-of-line per row (\033[K)
# instead of a full-screen clear, so the 1s refresh doesn't flicker on slow
# terminals. The table sizes itself to the data and to the terminal: it reads
# every row first, measures the longest value per column, then gives each
# column the width it needs. When stdout is not a tty (cron/pipes) it prints a
# plain table, no escape codes.
# Status is read from temporary status files written by update_status()
# No parameters required - reads from global SERVERS array
draw_dashboard() {
    local eol=""
    if [[ "$IS_TTY" == true ]]; then
        printf '\033[H'
        eol=$'\033[K'
    fi

    get_term_width

    # Pass 1: read the state of every server and measure the columns.
    local row_srv=() row_os=() row_krn=() row_sts=() row_color=()
    local nat_srv=${#HDR_SRV} nat_os=${#HDR_OS} nat_krn=${#HDR_KRN} nat_sts=${#HDR_STS}
    local n_active=0 n_updates=0 n_done=0 n_err=0
    local server status display_name os_info kernel_info color

    for server in "${SERVERS[@]}"; do
        safe_read_file "$TEMP_DIR/${server}.status" "Pending"
        status="$SRF_RESULT"

        # Color code status based on keywords, and tally for the footer
        case "$status" in
            *"ERROR"*|*"Error"*) color="${RED}"; ((n_err++)) ;;
            *"updates available"*) color="${YELLOW}"; ((n_updates++)) ;;
            *"No updates"*) color="${GREEN}"; ((n_done++)) ;;
            *"Reboot complete"*|*"Successfully rebooted"*) color="${GREEN}"; ((n_done++)) ;;
            # apply_updates() sets "Updates complete - kernel updated -
            # initiating reboot...". That is a reboot in progress, not a
            # finished server, so it belongs with the yellow reboot states; it
            # reached the default cyan bucket instead.
            # Keep this branch above *"Complete"* even though that pattern
            # cannot match the status as written: the two differ only in the
            # case of one letter, so capitalising the status string would
            # otherwise start colouring an in-progress reboot as "done".
            *"initiating reboot"*) color="${YELLOW}"; ((n_active++)) ;;
            *"Complete"*) color="${GREEN}"; ((n_done++)) ;;
            *"Skipped"*|*"Displayed"*) color="${YELLOW}"; ((n_done++)) ;;
            *"Updating"*|*"Applying"*) color="${MAGENTA}"; ((n_active++)) ;;
            *"Rebooting"*) color="${YELLOW}"; ((n_active++)) ;;
            *"Connected"*) color="${GREEN}"; ((n_active++)) ;;
            *) color="${CYAN}"; ((n_active++)) ;;
        esac

        display_name=$(get_display_name "$server")

        # Get OS and kernel info from temp files
        safe_read_file "$TEMP_DIR/${server}.os_release" "--"
        os_info="$SRF_RESULT"
        safe_read_file "$TEMP_DIR/${server}.kernel" "--"
        kernel_info="$SRF_RESULT"

        # Don't show "Unknown"
        [[ "$os_info" == "Unknown" ]] && os_info="--"
        [[ "$kernel_info" == "Unknown" ]] && kernel_info="--"

        row_srv+=("$display_name")
        row_os+=("$os_info")
        row_krn+=("$kernel_info")
        row_sts+=("$status")
        row_color+=("$color")

        (( ${#display_name} > nat_srv )) && nat_srv=${#display_name}
        (( ${#os_info}     > nat_os  )) && nat_os=${#os_info}
        (( ${#kernel_info} > nat_krn )) && nat_krn=${#kernel_info}
        (( ${#status}      > nat_sts )) && nat_sts=${#status}
    done

    compute_dashboard_layout "$TERM_WIDTH" "$nat_srv" "$nat_os" "$nat_krn" "$nat_sts"

    # Header banner sized to the terminal
    local box sep title pad
    printf -v box '%*s' "$TERM_WIDTH" ''
    sep=${box// /-}
    box=${box// /=}
    title="SERVER UPDATE DASHBOARD"
    pad=$(( (TERM_WIDTH - ${#title}) / 2 ))
    (( pad < 0 )) && pad=0

    echo -e "${BOLD}${BLUE}${box}${NC}${eol}"
    printf "${BOLD}${BLUE}%*s%s${NC}%s\n" "$pad" '' "$title" "$eol"
    echo -e "${BOLD}${BLUE}${box}${NC}${eol}"

    # Column headers. Narrow columns get the short label instead of a
    # truncated one.
    local h_srv="$HDR_SRV" h_os="$HDR_OS" h_krn="$HDR_KRN" h_sts="$HDR_STS"
    (( COL_OS  < ${#HDR_OS}  )) && h_os="OS"
    (( COL_KRN < ${#HDR_KRN} )) && h_krn="KERNEL"
    truncate_field "$h_os" "$COL_OS"; h_os="$TRUNC_RESULT"
    truncate_field "$h_krn" "$COL_KRN"; h_krn="$TRUNC_RESULT"

    printf "%s\n" "$eol"
    printf "${BOLD}%-*s %-*s %-*s %s${NC}%s\n" \
        "$COL_SRV" "$h_srv" "$COL_OS" "$h_os" "$COL_KRN" "$h_krn" "$h_sts" "$eol"
    echo -e "${BLUE}${sep}${NC}${eol}"

    # Pass 2: print one line per server
    local i
    for i in "${!row_srv[@]}"; do
        truncate_field "${row_srv[$i]}" "$COL_SRV"; display_name="$TRUNC_RESULT"
        truncate_field "${row_os[$i]}" "$COL_OS"; os_info="$TRUNC_RESULT"
        truncate_field "${row_krn[$i]}" "$COL_KRN"; kernel_info="$TRUNC_RESULT"
        truncate_field "${row_sts[$i]}" "$COL_STS"; status="$TRUNC_RESULT"

        # The status column is last, so it is printed unpadded
        printf "%-*s %-*s %-*s ${row_color[$i]}%s${NC}%s\n" \
            "$COL_SRV" "$display_name" "$COL_OS" "$os_info" "$COL_KRN" "$kernel_info" "$status" "$eol"
    done

    echo -e "${BLUE}${sep}${NC}${eol}"

    # Summary footer with elapsed time for the current phase
    local elapsed_s=$(( SECONDS - ${DASH_START:-0} )) elapsed
    printf -v elapsed '%02d:%02d' $((elapsed_s / 60)) $((elapsed_s % 60))
    printf "${BOLD}Active: %d | Updates: %d | Done: %d | Errors: %d | Elapsed: %s${NC}%s\n" \
        "$n_active" "$n_updates" "$n_done" "$n_err" "$elapsed" "$eol"

    # Erase any leftover lines from a previous, taller frame
    [[ "$IS_TTY" == true ]] && printf '\033[0J'
}

# Function to update server status in temporary file (read by draw_dashboard)
# Parameters: $1 = server address, $2 = status message
update_status() {
    local server="$1"
    local status="$2"
    safe_write_file "$TEMP_DIR/${server}.status" "$status"
}

# ============================================================================
# PHASE 2 REVIEW
# ============================================================================
# Phase 2 has two front ends over one set of rules:
#   - run_review_screen(): a split-screen picker (server list on top with the
#     decision on the right, packages for the highlighted server below)
#   - the classic loop: one server at a time, prompt under the package list
# Both read the same candidate arrays, render packages with the same function,
# and record decisions through the same function, so the rules cannot drift.
# ============================================================================

# Parallel arrays. Index i describes one server that has updates to review.
RV_SERVER=()     # address, exactly as written in server_list.txt
RV_NAME=()       # "address (nickname)"
RV_OSREL=()      # OS release, "--" when unknown
RV_KVER=()       # running kernel version, "--" when unknown
RV_PM=()         # apt / dnf / yum
RV_COUNT=()      # pending update count, "?" when the status cannot be parsed
RV_KUPD=()       # true when the update includes a kernel (reboot follows)
RV_DECISION=()   # yes / no / ask

# Collect every server that Phase 2 must review.
# Applies the same four gates the review has always applied, in the same order:
# local alias, output file present, status usable, and output in a format that
# proves updates exist.
collect_review_candidates() {
    RV_SERVER=(); RV_NAME=(); RV_OSREL=(); RV_KVER=(); RV_PM=()
    RV_COUNT=(); RV_KUPD=(); RV_DECISION=()

    local server status output_file pm count os_release kernel output_content

    for server in "${SERVERS[@]}"; do
        # Local aliases (localhost/127.0.0.1/::1) are handled in Phase 4
        is_localhost "$server" && continue

        output_file="$TEMP_DIR/${server}.output"
        [[ -f "$output_file" ]] || continue

        safe_read_file "$TEMP_DIR/${server}.status" "Unknown"
        status="$SRF_RESULT"

        # Skip servers with errors or nothing to do
        [[ "$status" == *"ERROR"* || "$status" == *"No updates"* ]] && continue

        # Verify updates are actually available. dnf/yum previews contain
        # "Transaction Summary"; apt output starts with "Listing..." -- this
        # gate previously only knew the dnf format, which silently dropped
        # every apt server from review (they could never be approved).
        grep -q -e "Transaction Summary" -e "^Listing" "$output_file" || continue

        pm=$(get_pkg_manager "$server")

        # check_server_updates writes the status as "N updates available"
        count="${status%% *}"
        [[ "$count" =~ ^[0-9]+$ ]] || count="?"

        safe_read_file "$TEMP_DIR/${server}.os_release" "--"
        os_release="$SRF_RESULT"
        [[ -z "$os_release" || "$os_release" == "Unknown" ]] && os_release="--"

        safe_read_file "$TEMP_DIR/${server}.kernel" "--"
        kernel="$SRF_RESULT"
        [[ -z "$kernel" || "$kernel" == "Unknown" ]] && kernel="--"

        output_content=$(cat "$output_file")

        RV_SERVER+=("$server")
        RV_NAME+=("$(get_display_name "$server")")
        RV_OSREL+=("$os_release")
        RV_KVER+=("$kernel")
        RV_PM+=("$pm")
        RV_COUNT+=("$count")
        if has_kernel_package "$output_content" "$pm"; then
            RV_KUPD+=("true")
        else
            RV_KUPD+=("false")
        fi
        RV_DECISION+=("ask")
    done
}

# Print the package list for one server as plain text, one package per line.
# Callers add color. Both Phase 2 front ends use this, so the package manager
# quirks live in one place.
# Parameters: $1 = server address, $2 = package manager
render_package_lines() {
    local server="$1"
    local pkg_manager="$2"
    local output_file="$TEMP_DIR/${server}.output"

    case "$pkg_manager" in
        apt)
            filter_apt_header "$output_file"
            ;;
        dnf|yum)
            # One pass over the whole package table: from the first section
            # header to the Transaction Summary. The header alternation matters
            # for old distros -- dnf says "Upgrading:" but yum (CentOS 6/7) says
            # "Updating:", so an Upgrading-only range shows an EMPTY package
            # list on yum hosts. A single range also avoids the duplicate
            # output that per-section ranges produce when both Installing: and
            # Upgrading: sections are present.
            sed -n '/^\(Installing\|Upgrading\|Updating\|Removing\|Downgrading\|Reinstalling\)[^:]*:[[:space:]]*$/,/^Transaction Summary/p' "$output_file" | head -n -1

            # Transaction summary (total packages, download size)
            echo ""
            sed -n '/^Transaction Summary/,/^Total download size/p' "$output_file"
            ;;
    esac
}

# Record one review decision. This is the only writer of approved_servers.txt.
# Parameters: $1 = server address, $2 = decision (yes = approve, else skip)
apply_review_decision() {
    local server="$1"
    local decision="$2"

    if [[ "$decision" == "yes" ]]; then
        echo "$server" >> "$TEMP_DIR/approved_servers.txt"
        echo "$(date) - Review: updates approved for $server" >> "$LOG_FILE"
    else
        update_status "$server" "Skipped by user"
        echo "$(date) - Review: updates skipped for $server" >> "$LOG_FILE"
    fi
}

# ----------------------------------------------------------------------------
# Review screen
# ----------------------------------------------------------------------------
# Fixed-width decision tokens. All three are the same length, so the column
# never changes width as you change your mind.
readonly DEC_YES="[  YES  ]" DEC_NO="[  SKIP ]" DEC_ASK="[   ?   ]"
readonly REVIEW_MIN_WIDTH=60 REVIEW_MIN_HEIGHT=14

RV_CUR=0          # highlighted row
RV_TOP=0          # first row visible in the server list
PKG_TOP=0         # first line visible in the package pane
PKG_PAGE=5        # package pane height, set by draw_review for PgUp/PgDn
PKG_CACHE_IDX=-1  # which row PKG_LINES currently holds
PKG_LINES=()

# Load the package list for one row into PKG_LINES, rendering it once per
# server into a temp file. Only one list is held in memory at a time.
# Parameters: $1 = row index
load_pkg_lines() {
    local idx="$1"
    [[ "$PKG_CACHE_IDX" == "$idx" ]] && return

    local file="$TEMP_DIR/${RV_SERVER[$idx]}.review"
    if [[ ! -f "$file" ]]; then
        render_package_lines "${RV_SERVER[$idx]}" "${RV_PM[$idx]}" > "$file" 2>/dev/null
    fi

    PKG_LINES=()
    mapfile -t PKG_LINES < "$file" 2>/dev/null
    PKG_CACHE_IDX="$idx"
}

# Render one full frame of the review screen.
#
# Repaints in place exactly like draw_dashboard: cursor home, erase to end of
# line on every row, erase to end of screen at the finish. No full clear, so
# there is no flicker.
draw_review() {
    local eol=$'\033[K'
    printf '\033[H'

    get_term_width
    get_term_height

    local n=${#RV_SERVER[@]}
    local i

    # --- column widths ------------------------------------------------------
    # UPD, the kernel flag, and DECISION are fixed. SERVER, OS, and KERNEL
    # share what is left, using the dashboard's own shrink rules.
    local col_upd=3 col_flag=${#GLYPH_WARN} col_dec=${#DEC_ASK}
    local nat_srv=${#HDR_SRV} nat_os=${#HDR_OS} nat_krn=${#HDR_KRN}
    local n_yes=0 n_no=0

    for i in "${!RV_SERVER[@]}"; do
        (( ${#RV_NAME[$i]} > nat_srv ))  && nat_srv=${#RV_NAME[$i]}
        (( ${#RV_OSREL[$i]} > nat_os ))  && nat_os=${#RV_OSREL[$i]}
        (( ${#RV_KVER[$i]} > nat_krn ))  && nat_krn=${#RV_KVER[$i]}
        (( ${#RV_COUNT[$i]} > col_upd )) && col_upd=${#RV_COUNT[$i]}
        [[ "${RV_DECISION[$i]}" == "yes" ]] && (( n_yes++ ))
        [[ "${RV_DECISION[$i]}" == "no" ]]  && (( n_no++ ))
    done

    # Two columns for the cursor, then one separator before each fixed column.
    local avail=$(( TERM_WIDTH - 2 - col_upd - col_flag - col_dec - 3 ))
    compute_dashboard_layout "$avail" "$nat_srv" "$nat_os" "$nat_krn" 0

    # --- pane heights -------------------------------------------------------
    # Nine lines of chrome, plus one spare so the frame never scrolls.
    local body=$(( TERM_HEIGHT - 10 ))
    (( body < 4 )) && body=4

    local list_h=$(( body / 2 ))
    (( list_h < 2 )) && list_h=2
    (( list_h > n )) && list_h=$n
    local pkg_h=$(( body - list_h ))
    (( pkg_h < 2 )) && pkg_h=2
    PKG_PAGE=$pkg_h

    # --- viewports ----------------------------------------------------------
    # Clamp to the last row first, then to the first, so an empty list cannot
    # leave a negative index behind (bash 4.0 and 4.1 have no negative indices)
    (( RV_CUR > n - 1 )) && RV_CUR=$(( n - 1 ))
    (( RV_CUR < 0 )) && RV_CUR=0
    (( RV_CUR < RV_TOP )) && RV_TOP=$RV_CUR
    (( RV_CUR >= RV_TOP + list_h )) && RV_TOP=$(( RV_CUR - list_h + 1 ))
    local max_top=$(( n - list_h ))
    (( max_top < 0 )) && max_top=0
    (( RV_TOP > max_top )) && RV_TOP=$max_top
    (( RV_TOP < 0 )) && RV_TOP=0

    load_pkg_lines "$RV_CUR"
    local pkg_n=${#PKG_LINES[@]}
    local pkg_max=$(( pkg_n - pkg_h ))
    (( pkg_max < 0 )) && pkg_max=0
    (( PKG_TOP > pkg_max )) && PKG_TOP=$pkg_max
    (( PKG_TOP < 0 )) && PKG_TOP=0

    # --- title --------------------------------------------------------------
    local box sep
    printf -v box '%*s' "$TERM_WIDTH" ''
    sep=${box// /-}

    # Two title forms, because the long one does not fit a 60-column window
    if (( TERM_WIDTH >= 84 )); then
        printf "${BOLD}${BLUE}REVIEW PENDING UPDATES${NC}  ${BOLD}%d of %d servers have updates  %d approved, %d skipped, %d undecided${NC}%s\n" \
            "$n" "${#SERVERS[@]}" "$n_yes" "$n_no" "$(( n - n_yes - n_no ))" "$eol"
    else
        printf "${BOLD}${BLUE}REVIEW UPDATES${NC}  ${BOLD}%d/%d servers  %d yes  %d skip  %d ?${NC}%s\n" \
            "$n" "${#SERVERS[@]}" "$n_yes" "$n_no" "$(( n - n_yes - n_no ))" "$eol"
    fi
    printf "%s\n" "$eol"

    # --- server list --------------------------------------------------------
    local h_os="$HDR_OS" h_krn="$HDR_KRN"
    (( COL_OS  < ${#HDR_OS}  )) && h_os="OS"
    (( COL_KRN < ${#HDR_KRN} )) && h_krn="KERNEL"
    truncate_field "$h_os" "$COL_OS"; h_os="$TRUNC_RESULT"
    truncate_field "$h_krn" "$COL_KRN"; h_krn="$TRUNC_RESULT"

    printf "${BOLD}  %-*s %-*s %-*s %*s %-*s %s${NC}%s\n" \
        "$COL_SRV" "$HDR_SRV" "$COL_OS" "$h_os" "$COL_KRN" "$h_krn" \
        "$col_upd" "UPD" "$col_flag" "" "DECISION" "$eol"
    printf "${BLUE}%s${NC}%s\n" "$sep" "$eol"

    local srv os krn flag dec row rowlen
    rowlen=$(( TERM_WIDTH - 3 ))
    (( rowlen < 20 )) && rowlen=20

    for (( i = RV_TOP; i < RV_TOP + list_h && i < n; i++ )); do
        truncate_field "${RV_NAME[$i]}" "$COL_SRV";  srv="$TRUNC_RESULT"
        truncate_field "${RV_OSREL[$i]}" "$COL_OS";  os="$TRUNC_RESULT"
        truncate_field "${RV_KVER[$i]}" "$COL_KRN";  krn="$TRUNC_RESULT"

        flag=""
        [[ "${RV_KUPD[$i]}" == "true" ]] && flag="$GLYPH_WARN"

        case "${RV_DECISION[$i]}" in
            yes) dec="$DEC_YES" ;;
            no)  dec="$DEC_NO" ;;
            *)   dec="$DEC_ASK" ;;
        esac

        printf -v row "%-*s %-*s %-*s %*s %-*s %s" \
            "$COL_SRV" "$srv" "$COL_OS" "$os" "$COL_KRN" "$krn" \
            "$col_upd" "${RV_COUNT[$i]}" "$col_flag" "$flag" "$dec"

        if (( i == RV_CUR )); then
            # Pad the whole row so the highlight spans the table, and close the
            # attribute before the erase so it does not paint the rest inverted
            printf -v row "%-*s" "$rowlen" "$row"
            printf "${BOLD}${REVERSE}> %s${NC}%s\n" "$row" "$eol"
        elif [[ "${RV_DECISION[$i]}" == "yes" ]]; then
            printf "  ${GREEN}%s${NC}%s\n" "$row" "$eol"
        elif [[ "${RV_DECISION[$i]}" == "no" ]]; then
            printf "  ${YELLOW}%s${NC}%s\n" "$row" "$eol"
        else
            printf "  %s%s\n" "$row" "$eol"
        fi
    done

    # --- package pane -------------------------------------------------------
    printf "${BLUE}%s${NC}%s\n" "$sep" "$eol"

    local hdr
    printf -v hdr " PACKAGES - %s" "${RV_NAME[$RV_CUR]}"
    truncate_field "$hdr" "$(( TERM_WIDTH - 34 ))"; hdr="$TRUNC_RESULT"
    if [[ "${RV_KUPD[$RV_CUR]}" == "true" ]]; then
        printf "${BOLD}%-*s${NC}${YELLOW}${BOLD}%s KERNEL UPDATE - WILL REBOOT${NC}%s\n" \
            "$(( TERM_WIDTH - 32 ))" "$hdr" "$GLYPH_WARN" "$eol"
    else
        printf "${BOLD}%s${NC}%s\n" "$hdr" "$eol"
    fi

    local line shown=0
    for (( i = PKG_TOP; i < PKG_TOP + pkg_h && i < pkg_n; i++ )); do
        truncate_field "${PKG_LINES[$i]}" "$(( TERM_WIDTH - 2 ))"; line="$TRUNC_RESULT"
        if has_kernel_package "$line" "${RV_PM[$RV_CUR]}"; then
            printf "  ${RED}${BOLD}%s${NC}%s\n" "$line" "$eol"
        else
            printf "  %s%s\n" "$line" "$eol"
        fi
        (( shown++ ))
    done
    for (( i = shown; i < pkg_h; i++ )); do
        printf "%s\n" "$eol"
    done

    # --- footers ------------------------------------------------------------
    local range
    if (( pkg_n == 0 )); then
        range="no package detail available"
    else
        printf -v range "lines %d-%d of %d" \
            "$(( PKG_TOP + 1 ))" "$(( PKG_TOP + shown ))" "$pkg_n"
        (( PKG_TOP + shown < pkg_n )) && range="$range  (more below)"
        (( PKG_TOP > 0 )) && range="(more above)  $range"
    fi
    printf "${CYAN}  %s${NC}%s\n" "$range" "$eol"
    printf "${BLUE}%s${NC}%s\n" "$sep" "$eol"

    if (( TERM_WIDTH >= 96 )); then
        printf "${BOLD} up/dn${NC} server  ${BOLD}PgUp/PgDn${NC} packages  ${BOLD}y${NC} approve  ${BOLD}n${NC} skip  ${BOLD}a${NC} all  ${BOLD}ENTER${NC} apply  ${BOLD}q${NC} cancel%s\n" "$eol"
    else
        printf "${BOLD} up/dn${NC} srv ${BOLD}PgUp/Dn${NC} pkgs ${BOLD}y${NC}es ${BOLD}n${NC}o ${BOLD}a${NC}ll ${BOLD}ENTER${NC} apply ${BOLD}q${NC} cancel%s\n" "$eol"
    fi

    # Erase anything left over from a taller previous frame
    printf '\033[0J'
}

# True when the terminal can carry the review screen.
review_screen_supported() {
    [[ "$IS_TTY" == true ]] || return 1
    [[ "$CLASSIC_REVIEW" == false ]] || return 1
    [[ "$DRY_RUN" == false && "$CHECK_ONLY" == false ]] || return 1
    [[ "$ASSUME_YES" == false && "$NON_INTERACTIVE" == false ]] || return 1
    [[ -r /dev/tty ]] || return 1

    get_term_width
    get_term_height
    (( TERM_WIDTH >= REVIEW_MIN_WIDTH && TERM_HEIGHT >= REVIEW_MIN_HEIGHT )) || return 1

    return 0
}

# Run the review screen until the user commits or cancels.
# Sets REVIEW_RESULT to "commit" or "cancel".
# Returns 0 when the screen ran, 1 when the keyboard could not be opened
# (the caller then falls back to the classic prompts).
run_review_screen() {
    # Read the keyboard from the controlling terminal, not stdin, so a
    # redirected stdin cannot answer the review. The brace group keeps bash
    # from printing its own redirection error; the caller falls back to the
    # classic prompts.
    { exec 3</dev/tty; } 2>/dev/null || return 1

    RV_CUR=0; RV_TOP=0; PKG_TOP=0; PKG_CACHE_IDX=-1
    REVIEW_RESULT="cancel"

    local n=${#RV_SERVER[@]}
    local i need_draw=1 last_w=0 last_h=0

    printf '\033[?25l\033[2J'

    while true; do
        (( need_draw )) && draw_review
        need_draw=1

        if ! read_key; then
            break   # end of input, treat as cancel
        fi

        case "$KEY" in
            TIMEOUT)
                # Nothing was typed. Repaint only if the window changed size,
                # so an idle screen costs nothing.
                last_w=$TERM_WIDTH; last_h=$TERM_HEIGHT
                get_term_width
                get_term_height
                (( TERM_WIDTH == last_w && TERM_HEIGHT == last_h )) && need_draw=0
                ;;
            UP|k|K)
                (( RV_CUR > 0 )) && { (( RV_CUR-- )); PKG_TOP=0; }
                ;;
            DOWN|j|J)
                (( RV_CUR < n - 1 )) && { (( RV_CUR++ )); PKG_TOP=0; }
                ;;
            PGUP|LEFT)
                PKG_TOP=$(( PKG_TOP - PKG_PAGE ))
                ;;
            PGDN|RIGHT)
                PKG_TOP=$(( PKG_TOP + PKG_PAGE ))
                ;;
            HOME)
                PKG_TOP=0
                ;;
            END)
                PKG_TOP=${#PKG_LINES[@]}
                ;;
            y|Y)
                RV_DECISION[$RV_CUR]="yes"
                (( RV_CUR < n - 1 )) && { (( RV_CUR++ )); PKG_TOP=0; }
                ;;
            n|N)
                RV_DECISION[$RV_CUR]="no"
                (( RV_CUR < n - 1 )) && { (( RV_CUR++ )); PKG_TOP=0; }
                ;;
            ' ')
                if [[ "${RV_DECISION[$RV_CUR]}" == "yes" ]]; then
                    RV_DECISION[$RV_CUR]="no"
                else
                    RV_DECISION[$RV_CUR]="yes"
                fi
                ;;
            a|A)
                for i in "${!RV_DECISION[@]}"; do
                    RV_DECISION[$i]="yes"
                done
                ;;
            ENTER)
                REVIEW_RESULT="commit"
                break
                ;;
            q|Q|ESC)
                REVIEW_RESULT="cancel"
                break
                ;;
        esac
    done

    exec 3<&-
    printf '\033[?25h\033[0m\033[2J\033[H'
    return 0
}

# Print what the review decided. The screen repaints in place, so without this
# the scrollback keeps no record of the choices.
print_review_summary() {
    local i dec label

    echo ""
    if [[ "$REVIEW_RESULT" == "commit" ]]; then
        echo -e "${BOLD}${GREEN}Review complete${NC}"
    else
        echo -e "${BOLD}${YELLOW}Review cancelled - no updates approved${NC}"
    fi
    echo ""

    for i in "${!RV_SERVER[@]}"; do
        dec="${RV_DECISION[$i]}"
        [[ "$REVIEW_RESULT" == "commit" && "$dec" == "yes" ]] || dec="no"

        if [[ "$dec" == "yes" ]]; then
            label="${GREEN}${DEC_YES}${NC}"
        else
            label="${YELLOW}${DEC_NO}${NC}"
        fi

        if [[ "${RV_KUPD[$i]}" == "true" ]]; then
            echo -e "  ${label} ${RV_NAME[$i]} (${RV_COUNT[$i]} updates, ${YELLOW}kernel - reboot${NC})"
        else
            echo -e "  ${label} ${RV_NAME[$i]} (${RV_COUNT[$i]} updates)"
        fi
    done
    echo ""
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

    # Single round-trip: connection test + package-manager detection + OS/kernel.
    # Writes the pkg_manager/os_release/kernel temp files as a side effect.
    probe_server_info "$server"
    local probe_rc=$?
    if [[ $probe_rc -eq 124 ]]; then
        update_status "$server" "ERROR: Connection timeout"
        echo "$(date) - ERROR: Connection timeout to $server (15s)" >> "$LOG_FILE"
        return 1
    elif [[ $probe_rc -ne 0 ]]; then
        classify_ssh_error "$TEMP_DIR/${server}.ssh_err"
        if [[ -n "$SSH_ERROR_REASON" ]]; then
            update_status "$server" "ERROR: Cannot connect ($SSH_ERROR_REASON)"
        else
            update_status "$server" "ERROR: Cannot connect"
        fi
        echo "$(date) - ERROR: Connection failed to $server${SSH_ERROR_REASON:+ ($SSH_ERROR_REASON)}" >> "$LOG_FILE"
        # Keep the raw ssh stderr in the log for troubleshooting
        head -5 "$TEMP_DIR/${server}.ssh_err" 2>/dev/null | sed 's/^/    ssh: /' >> "$LOG_FILE"
        return 1
    fi

    # Read back the package manager the probe just detected (cheap builtin read).
    local pkg_manager
    pkg_manager=$(get_pkg_manager "$server")

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
            # NOT --assumeno: that option needs yum 3.4.3 (RHEL 7), and RHEL 6's
            # yum 3.2.29 dies with "no such option". Piping "n" answers the
            # confirmation prompt on every yum version and produces the same
            # transaction preview.
            check_cmd="echo n | sudo yum update"
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
            # Count only lines in apt's actual listing format:
            #   name/suite version arch [upgradable from: ...]
            # The old count was a bare `grep -c "/"`. The check command is
            # `apt-get update -qq && apt list --upgradable`, and
            # execute_remote_command merges stderr. When apt-get update fails
            # (dead mirror, expired key) the && short-circuits and apt list
            # never runs, but the error chatter still lands in pkg_output --
            # "Err:1 http://...", "E: Failed to fetch http://..." -- and every
            # one of those lines contains a "/". A host with broken apt
            # therefore reported a phantom "N updates available".
            # The anchored pattern requires a "/" inside the FIRST whitespace-
            # delimited field, which no apt error line has ("Err:1", "E:" and
            # "W:" all put their URL in a later field, and continuation lines
            # are indented). It also drops the "Listing..." header on its own,
            # so filter_apt_header is not needed here.
            # No `|| echo 0` here: grep -c already prints 0 on no match, and the
            # fallback produced a second "0" line that broke the -gt comparison
            total_count=$(echo "$pkg_output" | grep -cE '^[^[:space:]/]+/[^[:space:]]+[[:space:]]')
            if [[ $total_count -gt 0 ]]; then
                update_status "$server" "${total_count} updates available"
                return 0
            elif [[ $pkg_exit_code -ne 0 ]]; then
                # Zero packages AND a failed command is a broken cache refresh,
                # not a clean host. Reporting "No updates" here would hide it.
                update_status "$server" "ERROR: Package manager command failed"
                echo "$(date) - ERROR: apt check failed on $server (exit code: $pkg_exit_code, no package listing)" >> "$LOG_FILE"
                echo "$pkg_output" >> "$LOG_FILE"
                return 1
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
            elif echo "$pkg_output" | grep -qiE "nothing to do|no packages marked for update"; then
                # Two wordings, one meaning. dnf prints "Nothing to do."; yum 3.x
                # (the RHEL/CentOS 6-7 hosts this release targets) prints
                # "No Packages marked for Update" and NO Transaction Summary.
                # The yum wording matched neither branch, so a fully patched
                # CentOS 6/7 box reported "ERROR: Failed to check updates",
                # dropped out of review, and inflated the error tally.
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
# Primary strategy: /proc/sys/kernel/random/boot_id comparison. The kernel
# regenerates boot_id on every boot, so a changed value PROVES a reboot
# happened -- even one too fast to observe as "down" (small VMs can cycle
# inside a 5s polling window, which the old down/up watcher misread as
# "did not go down"). procfs has boot_id on any Linux back to RHEL 5, so old
# targets are fine.
# Fallback (no boot_id captured): legacy two-phase down/up polling.
# All SSH probes are wrapped in `timeout` -- ConnectTimeout only covers the TCP
# connect, and a half-up server that accepts and hangs would stall forever.
# Parameters: $1 = server address, $2 = boot_id captured before reboot (may be "")
# Returns: 0 if reboot successful, 1 if timeout or error
# Side effects: Updates status file, writes reboot_status file (success/failed)
verify_reboot() {
    local server="$1"
    local old_boot_id="${2:-}"
    local ssh_cmd
    ssh_cmd=$(get_ssh_cmd "$server")

    # Calculate maximum attempts based on configured wait time and interval
    local max_attempts=$((REBOOT_MAX_WAIT / REBOOT_WAIT_INTERVAL))
    local attempts=0

    echo "$(date) - Waiting for $server to reboot" >> "$LOG_FILE"

    if [[ -z "$ssh_cmd" ]]; then
        # Local machine: we can't probe ourselves over SSH. (Phase 3 skips
        # local aliases and Phase 4 reboots inline, so this is only a safety
        # net.) Give the reboot time to start.
        sleep 30
    elif [[ -z "$old_boot_id" ]]; then
        # ========================================
        # Fallback Phase 1: Wait for server to go down
        # ========================================
        # Without a boot_id we can only infer a reboot by watching the server
        # disappear. Check every 5 seconds for up to 100 seconds (20 attempts).
        update_status "$server" "Rebooting... waiting for server to go down"
        local down_attempts=0
        local max_down_attempts=20  # 20 attempts x 5 seconds = 100 seconds max

        # shellcheck disable=SC2086
        while timeout 15s $ssh_cmd "$server" "echo 'up'" &>/dev/null && [[ $down_attempts -lt $max_down_attempts ]]; do
            sleep 5  # Check every 5 seconds
            ((down_attempts++))
        done

        # If server didn't go down after 100 seconds, the reboot command may have failed
        if [[ $down_attempts -ge $max_down_attempts ]]; then
            update_status "$server" "ERROR: Server did not go down after reboot command"
            echo "$(date) - ERROR: $server did not go down after reboot command" >> "$LOG_FILE"
            safe_write_file "$TEMP_DIR/${server}.reboot_status" "failed"
            return 1
        fi
    fi

    # ========================================
    # Wait for server to come back up
    # ========================================
    update_status "$server" "Rebooting... checking every ${REBOOT_WAIT_INTERVAL}s"

    # In boot_id mode, track whether the server was ever unreachable so a
    # reboot command that silently failed (boot_id never changes, host never
    # drops) is reported as "did not go down" instead of waiting out the
    # full REBOOT_MAX_WAIT.
    local went_unreachable=false

    while [[ $attempts -lt $max_attempts ]]; do
        sleep "$REBOOT_WAIT_INTERVAL"
        ((attempts++))

        if [[ -n "$ssh_cmd" && -n "$old_boot_id" ]]; then
            # boot_id mode: a reachable host with a NEW boot_id has provably
            # rebooted; a reachable host with the SAME boot_id hasn't gone
            # down yet, so keep waiting.
            local new_boot_id
            # shellcheck disable=SC2086
            new_boot_id=$(timeout 20s $ssh_cmd "$server" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null)
            if [[ -n "$new_boot_id" ]]; then
                if [[ "$new_boot_id" != "$old_boot_id" ]]; then
                    update_status "$server" "${GLYPH_OK} Reboot complete"
                    echo "$(date) - $server successfully rebooted after $((attempts * REBOOT_WAIT_INTERVAL)) seconds" >> "$LOG_FILE"
                    safe_write_file "$TEMP_DIR/${server}.reboot_status" "success"
                    return 0
                fi
                # Same boot_id and never seen down after ~2 minutes: the
                # reboot command almost certainly never took effect.
                if [[ "$went_unreachable" == false && $((attempts * REBOOT_WAIT_INTERVAL)) -ge 120 ]]; then
                    update_status "$server" "ERROR: Server did not go down after reboot command"
                    echo "$(date) - ERROR: $server never rebooted (boot_id unchanged after $((attempts * REBOOT_WAIT_INTERVAL))s)" >> "$LOG_FILE"
                    safe_write_file "$TEMP_DIR/${server}.reboot_status" "failed"
                    return 1
                fi
                update_status "$server" "Rebooting... not down yet ($attempts/$max_attempts)"
                continue
            fi
            went_unreachable=true
        else
            # Fallback mode: 'uptime' succeeding means the server is back up
            local responsive=false
            if [[ -n "$ssh_cmd" ]]; then
                # shellcheck disable=SC2086
                if timeout 20s $ssh_cmd "$server" "uptime" &>/dev/null; then
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
                update_status "$server" "${GLYPH_OK} Reboot complete"
                echo "$(date) - $server successfully rebooted after $((attempts * REBOOT_WAIT_INTERVAL)) seconds" >> "$LOG_FILE"
                safe_write_file "$TEMP_DIR/${server}.reboot_status" "success"
                return 0
            fi
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
    # Read package manager from cache (set during check_server_updates)
    local pkg_manager
    pkg_manager=$(get_pkg_manager "$server")

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
            # dist-upgrade, NOT upgrade: new kernels arrive as NEW versioned
            # packages (linux-image-X.Y.Z-generic), which plain upgrade holds
            # back -- kernels were flagged in review but never installed.
            # force-confdef/confold keep dpkg from stalling on conffile
            # prompts, which DEBIAN_FRONTEND=noninteractive alone doesn't fully
            # suppress. Both flags work on every apt back to Debian oldstable.
            update_cmd="sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y"
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

    # Run update command with the apply-phase timeout (larger than the check
    # phase's DNF_TIMEOUT: killing a transaction mid-flight risks rpmdb/dpkg
    # corruption, so err on the side of patience)
    local update_output
    update_output=$(execute_remote_command "$server" "$update_cmd" "$APPLY_TIMEOUT")
    local update_exit_code=$?

    # Check for sudo error on localhost
    if [[ "$update_output" == *"Passwordless sudo is not configured"* ]]; then
        update_status "$server" "ERROR: Passwordless sudo required"
        echo "$(date) - ERROR: Passwordless sudo not configured for $server" >> "$LOG_FILE"
        return 1
    fi

    # Check for timeout. Note: the timeout kills the local ssh, NOT the remote
    # package manager -- it may well still be running on the server.
    if [[ $update_exit_code -eq 124 ]]; then
        update_status "$server" "ERROR: Update timed out (may still be running)"
        echo "$(date) - ERROR: Update timed out on $server after ${APPLY_TIMEOUT}s." >> "$LOG_FILE"
        echo "$(date) - WARNING: The package manager on $server may STILL BE RUNNING. Verify it finished before re-running this script." >> "$LOG_FILE"
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
            # Match packages actually installed ("Unpacking"/"Setting up"
            # lines), NOT any mention of linux-image -- the old unanchored grep
            # also matched the "kept back" list and rebooted servers where no
            # kernel was installed at all. /var/run/reboot-required is the
            # distro's own signal and also catches non-kernel reboot needs
            # (libc, systemd).
            if echo "$update_output" | grep -qiE "^(Setting up|Unpacking) linux-(image|headers|modules)"; then
                kernel_updated=true
            elif [[ "$(execute_remote_command "$server" "test -f /var/run/reboot-required && echo yes" 15)" == *yes* ]]; then
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

        # Capture the pre-reboot boot_id so verify_reboot can prove a reboot
        # happened even if the host cycles faster than the polling interval.
        # The grep keeps only a well-formed UUID line (ssh warnings and sudo
        # noise share the merged output stream); empty means "unavailable"
        # and verify_reboot falls back to down/up polling.
        local old_boot_id
        old_boot_id=$(execute_remote_command "$server" "cat /proc/sys/kernel/random/boot_id" 15 | grep -E '^[0-9a-f-]{36}$' | tail -1)

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
        verify_reboot "$server" "$old_boot_id"
    else
        # No kernel update - mark as complete without reboot
        update_status "$server" "${GLYPH_OK} Complete - No reboot needed"
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
    echo "  ${GLYPH_BULLET} $display_name"
done
echo ""

# Probe the local ssh client once so get_ssh_cmd builds options it actually
# supports (handles old controllers like CentOS 6/7 whose ssh predates
# accept-new / ControlPath %C).
detect_ssh_capabilities

# Skip interactive prompt in automated modes (--dry-run included: it is
# routinely run from cron/CI where nobody can press Enter)
if [[ "$NON_INTERACTIVE" == true || "$CHECK_ONLY" == true || "$ASSUME_YES" == true || "$DRY_RUN" == true ]]; then
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

# Wait for all background checks to complete with live dashboard updates.
# The live loop only runs on a terminal; in cron/pipes we just wait and print
# one final table (no escape codes sprayed into logs).
DASH_START=$SECONDS
if [[ "$IS_TTY" == true ]]; then
    printf '\033[?25l\033[2J'  # hide cursor, clear once; frames repaint in place
    while [[ $(jobs -r | wc -l) -gt 0 ]]; do
        draw_dashboard
        sleep "$DASHBOARD_REFRESH"
    done
fi

# Ensure all background jobs are truly finished (Fix: Issue #30)
wait

# Display final dashboard state
draw_dashboard
[[ "$IS_TTY" == true ]] && printf '\033[?25h'  # restore cursor

echo -e "${BOLD}${GREEN}Update check complete!${NC}\n"
sleep 2

# ============================================================================
# PHASE 2: Review and approve updates for each server
# ============================================================================
# In this phase, we:
#   1. Collect every server that has updates to review
#   2. Show the packages, with kernel packages in red (these force a reboot)
#   3. Let the user approve or skip each server
#   4. Build a list of approved servers for Phase 3
#
# There are two front ends. On a terminal that can carry it, the review screen
# lists the servers with the decision on the right and the packages for the
# highlighted server below. Everywhere else, and with --classic-review, the
# script falls back to one server at a time with the prompt under the packages.
#
# Special modes (classic front end only, the screen never opens in them):
#   --dry-run:         Skip all updates
#   --check-only:      Display updates but don't prompt
#   --assume-yes:      Auto-approve all updates
#   --non-interactive: Skip all prompts, which means skip every server
# ============================================================================
collect_review_candidates

REVIEW_SCREEN_USED=false
if (( ${#RV_SERVER[@]} > 0 )) && review_screen_supported; then
    if run_review_screen; then
        REVIEW_SCREEN_USED=true
    fi
fi

if [[ "$REVIEW_SCREEN_USED" == true ]]; then
    # ------------------------------------------------------------------
    # Review screen: apply the decisions it collected
    # ------------------------------------------------------------------
    print_review_summary

    for review_idx in "${!RV_SERVER[@]}"; do
        review_decision="${RV_DECISION[$review_idx]}"
        [[ "$REVIEW_RESULT" == "commit" ]] || review_decision="no"
        apply_review_decision "${RV_SERVER[$review_idx]}" "$review_decision"
    done
else
    # ------------------------------------------------------------------
    # Classic front end: one server at a time
    # ------------------------------------------------------------------
    # 'a' approves everything remaining, 'q' stops the review
    APPROVE_ALL=false
    REVIEW_QUIT=false

    for review_idx in "${!RV_SERVER[@]}"; do
        server="${RV_SERVER[$review_idx]}"
        display_name="${RV_NAME[$review_idx]}"
        pkg_manager="${RV_PM[$review_idx]}"

        # Display server header
        echo -e "${BOLD}${BLUE}=====================================================================${NC}"
        echo -e "${BOLD}${GREEN}Server: ${CYAN}$display_name${NC}"
        echo -e "${BOLD}${BLUE}=====================================================================${NC}"
        echo ""

        # Package list, with kernel packages in RED BOLD since they force a reboot
        render_package_lines "$server" "$pkg_manager" | while IFS= read -r line; do
            if has_kernel_package "$line" "$pkg_manager"; then
                echo -e "${RED}${BOLD}$line${NC}"
            else
                echo "$line"
            fi
        done
        echo ""

        # Warn if kernel update detected
        if [[ "${RV_KUPD[$review_idx]}" == "true" ]]; then
            echo -e "${YELLOW}${BOLD}${GLYPH_WARN} Kernel update detected - server will be rebooted after updates${NC}"
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
            apply_review_decision "$server" "yes"
        elif [[ "$APPROVE_ALL" == true ]]; then
            echo -e "${GREEN}Auto-approving updates ('a' selected earlier)${NC}\n"
            apply_review_decision "$server" "yes"
        elif [[ "$NON_INTERACTIVE" == true ]]; then
            # --non-interactive promises no prompts. Without --assume-yes there
            # is nobody to approve, so skip. Phase 4 treats the flag the same way.
            echo -e "${YELLOW}Skipping updates (--non-interactive without --assume-yes)${NC}\n"
            apply_review_decision "$server" "no"
        else
            # Interactive mode - prompt user
            echo -e -n "${BOLD}Apply updates to $display_name? [y/N/a=yes to all/q=quit review]: ${NC}"
            read -r response

            case "$response" in
                [Yy])
                    echo -e "${GREEN}Proceeding with updates for $display_name...${NC}\n"
                    apply_review_decision "$server" "yes"
                    ;;
                [Aa])
                    APPROVE_ALL=true
                    echo -e "${GREEN}Proceeding with updates for $display_name (and all remaining servers)...${NC}\n"
                    apply_review_decision "$server" "yes"
                    ;;
                [Qq])
                    echo -e "${YELLOW}Quitting review - skipping this and all remaining servers${NC}\n"
                    apply_review_decision "$server" "no"
                    REVIEW_QUIT=true
                    ;;
                *)
                    echo -e "${YELLOW}Skipping updates for $display_name${NC}\n"
                    apply_review_decision "$server" "no"
                    ;;
            esac
        fi

        echo ""

        if [[ "$REVIEW_QUIT" == true ]]; then
            break
        fi
    done
fi


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
    # Skip local aliases - handled in Phase 4 after all remote servers complete
    while IFS= read -r server; do
        if is_localhost "$server"; then
            continue
        fi
        # < /dev/null is required, not decorative. Without it every background
        # job inherits this loop's stdin -- the SAME open file description on
        # approved_servers.txt. apply_updates() calls ssh (no -n), which reads
        # stdin to forward it, so a child can consume the unread remainder of
        # the list. The parent's next read then hits EOF and the remaining
        # approved servers are silently never updated.
        apply_updates "$server" < /dev/null &
    done < "$TEMP_DIR/approved_servers.txt"

    # Wait for all update processes to complete with live dashboard
    # (terminal only; see Phase 1 loop for rationale)
    DASH_START=$SECONDS
    if [[ "$IS_TTY" == true ]]; then
        printf '\033[?25l\033[2J'  # hide cursor, clear once; frames repaint in place
        while [[ $(jobs -r | wc -l) -gt 0 ]]; do
            draw_dashboard
            sleep "$DASHBOARD_REFRESH"
        done
    fi

    # Ensure all background jobs are truly finished (Fix: Issue #30)
    wait

    # Display final dashboard state
    draw_dashboard
    [[ "$IS_TTY" == true ]] && printf '\033[?25h'  # restore cursor

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
        # Skip local aliases - handled in Phase 4
        if is_localhost "$server"; then
            continue
        fi

        update_type=""
        reboot_status=""
        result_msg=""
        result_color="${GREEN}"

        # Determine what type of update was performed (kernel or regular)
        safe_read_file "$TEMP_DIR/${server}.update_type" ""
        update_type="$SRF_RESULT"

        # For kernel updates, check if reboot was successful
        if [[ "$update_type" == "kernel_update" ]]; then
            safe_read_file "$TEMP_DIR/${server}.reboot_status" ""
            reboot_status="$SRF_RESULT"
            if [[ "$reboot_status" == "success" ]]; then
                result_msg="${GLYPH_OK} Updated and reboot complete"
                result_color="${GREEN}"
                ((servers_rebooted++))
            else
                result_msg="${GLYPH_FAIL} Updated but failed to verify reboot"
                result_color="${RED}"
                ((servers_failed++))
            fi
        elif [[ "$update_type" == "no_reboot" ]]; then
            result_msg="${GLYPH_OK} Successfully updated (no reboot required)"
            result_color="${GREEN}"
            ((servers_updated++))
        else
            # No update type recorded - check status for error messages
            safe_read_file "$TEMP_DIR/${server}.status" "Unknown"
            current_status="$SRF_RESULT"
            if [[ "$current_status" == *"ERROR"* ]]; then
                result_msg="${GLYPH_FAIL} Update failed"
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

# Check if the local machine is in the server list and has updates available.
# It may be listed as localhost, 127.0.0.1, or ::1 -- state files are keyed by
# whatever name was used in the server list.
LOCAL_SERVER=""
localhost_has_updates=false
for server in "${SERVERS[@]}"; do
    if is_localhost "$server"; then
        LOCAL_SERVER="$server"
        # Check if localhost has updates (check the output file exists and has content)
        if [[ -f "$TEMP_DIR/${LOCAL_SERVER}.output" ]]; then
            safe_read_file "$TEMP_DIR/${LOCAL_SERVER}.status" ""
            status="$SRF_RESULT"
            # Only prompt if localhost has updates (not errors or "No updates")
            if [[ "$status" != *"ERROR"* && "$status" != *"No updates"* ]]; then
                # Verify updates are actually available (check for package manager output)
                if grep -q -e "Transaction Summary" -e "^Listing" "$TEMP_DIR/${LOCAL_SERVER}.output" 2>/dev/null; then
                    localhost_has_updates=true
                fi
            fi
        fi
        break
    fi
done

# --dry-run and --check-only promise no changes; never touch the local server
# in those modes (previously Phase 4 ignored both flags and could apply
# updates and even reboot the local machine)
if [[ "$localhost_has_updates" == "true" && ( "$DRY_RUN" == true || "$CHECK_ONLY" == true ) ]]; then
    echo ""
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}Local server has updates pending - skipped (--dry-run mode)${NC}"
    else
        echo -e "${CYAN}Local server has updates pending - skipped (--check-only mode)${NC}"
    fi
    localhost_has_updates=false
fi

if [[ "$localhost_has_updates" == "true" ]]; then
    echo ""
    echo -e "${BOLD}${BLUE}=====================================================================${NC}"
    echo -e "${BOLD}${YELLOW}Local Server Update Pending${NC}"
    echo -e "${BOLD}${BLUE}=====================================================================${NC}"
    echo ""
    echo -e "${YELLOW}All remote servers have completed their updates.${NC}"
    echo -e "${YELLOW}The local server (localhost) is ready to be updated.${NC}"
    echo ""

    # Get package manager for localhost (read from cache set in Phase 1)
    pkg_manager=$(get_pkg_manager "$LOCAL_SERVER")
    if [[ -z "$pkg_manager" || "$pkg_manager" == "unknown" ]]; then
        # Fallback: detect it now if cache doesn't exist
        pkg_manager=$(detect_package_manager "$LOCAL_SERVER")
    fi

    # Show what updates are pending
    if [[ -f "$TEMP_DIR/${LOCAL_SERVER}.output" ]]; then
        echo -e "${BOLD}Updates available for local server:${NC}"
        echo ""

        case "$pkg_manager" in
            apt)
                filter_apt_header "$TEMP_DIR/${LOCAL_SERVER}.output" | head -20
                ;;
            dnf|yum)
                # Same header alternation as Phase 2: dnf says "Upgrading:",
                # yum (CentOS 6/7) says "Updating:"
                sed -n '/^\(Installing\|Upgrading\|Updating\|Removing\|Downgrading\|Reinstalling\)[^:]*:[[:space:]]*$/,/^Transaction Summary/p' "$TEMP_DIR/${LOCAL_SERVER}.output" | head -n -1 | head -20
                sed -n '/^Transaction Summary/,/^Total download size/p' "$TEMP_DIR/${LOCAL_SERVER}.output"
                ;;
        esac

        echo ""

        # Check if kernel update is included
        output_content=$(cat "$TEMP_DIR/${LOCAL_SERVER}.output")
        if has_kernel_package "$output_content" "$pkg_manager"; then
            echo -e "${RED}${BOLD}${GLYPH_WARN}  WARNING: Kernel update detected!${NC}"
            echo -e "${RED}${BOLD}${GLYPH_WARN}  The local server will REBOOT after updates complete.${NC}"
            echo -e "${RED}${BOLD}${GLYPH_WARN}  You will lose your session if running this script locally.${NC}"
            echo ""
        fi
    fi

    # Prompt for confirmation. --assume-yes alone auto-approves, matching the
    # Phase 2 behavior (it previously also required --non-interactive here,
    # which made the two phases inconsistent).
    proceed=false
    if [[ "$ASSUME_YES" == true ]]; then
        echo -e "${GREEN}Auto-approving local server update (--assume-yes mode)${NC}"
        echo ""
        proceed=true
    elif [[ "$NON_INTERACTIVE" == true ]]; then
        echo -e "${YELLOW}Skipping local server update (--non-interactive mode without --assume-yes)${NC}"
        echo ""
        proceed=false
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

        # Determine update command based on package manager (same commands as
        # the remote Phase 3 path -- see apply_updates for the rationale on
        # dist-upgrade and the dpkg conffile options)
        update_cmd=""
        case "$pkg_manager" in
            apt)
                update_cmd="sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y"
                ;;
            dnf)
                update_cmd="sudo dnf update -y"
                ;;
            yum)
                # Plain -y only: --assumeyes is not understood by RHEL 6's yum
                update_cmd="sudo yum update -y"
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

        # Run update, showing output in real-time and also capturing to file.
        # LC_ALL=C keeps output English-parseable (matches execute_remote_command).
        timeout "${APPLY_TIMEOUT}s" bash -c "export LC_ALL=C; $update_cmd" 2>&1 | tee "$update_output_file"
        update_exit_code=${PIPESTATUS[0]}

        if [[ $update_exit_code -eq 124 ]]; then
            echo -e "${RED}[ERROR]${NC} Update command timed out after ${APPLY_TIMEOUT}s"
            echo "$(date) - ERROR: Local server update timed out" >> "$LOG_FILE"
        elif [[ $update_exit_code -ne 0 ]]; then
            echo -e "${RED}[ERROR]${NC} Update failed"
            echo "$(date) - ERROR: Local server update failed" >> "$LOG_FILE"
        else
            echo ""
            echo -e "${GREEN}${GLYPH_OK} Local server updates completed successfully!${NC}"
            echo "$(date) - Local server updated successfully" >> "$LOG_FILE"

            # Check if kernel was updated (read from captured output file).
            # Same detection as apply_updates: match installed packages, not the
            # apt "kept back" list, plus the distro's own reboot-required flag.
            kernel_updated=false
            if [[ -f "$update_output_file" ]]; then
                case "$pkg_manager" in
                    apt)
                        if grep -qiE "^(Setting up|Unpacking) linux-(image|headers|modules)" "$update_output_file"; then
                            kernel_updated=true
                        elif [[ -f /var/run/reboot-required ]]; then
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
                echo -e "${YELLOW}${BOLD}${GLYPH_WARN}  KERNEL UPDATE DETECTED - REBOOT REQUIRED${NC}"
                echo -e "${YELLOW}${BOLD}=====================================================================${NC}"
                echo ""
                echo -e "${YELLOW}The local server kernel has been updated and requires a reboot.${NC}"
                do_reboot=false
                if [[ "$ASSUME_YES" == true ]]; then
                    echo ""
                    echo -e "${GREEN}Auto-approving reboot (--assume-yes mode)${NC}"
                    do_reboot=true
                elif [[ "$NON_INTERACTIVE" == true ]]; then
                    echo ""
                    echo -e "${YELLOW}Skipping reboot (--non-interactive mode without --assume-yes)${NC}"
                    do_reboot=false
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
