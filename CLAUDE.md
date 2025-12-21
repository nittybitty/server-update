# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a bash-based server update management tool for managing package updates across multiple Linux servers with different distributions. The script (`server_update.bash`) provides an interactive dashboard that:
- Auto-detects package managers (apt/dnf/yum)
- Checks for updates on multiple servers in parallel
- Displays real-time OS info, kernel versions, and update status
- Allows user review and approval of updates
- Applies updates in parallel with automatic reboot handling
- Monitors reboot progress and verifies server availability

**Current Version:** 1.1

## Supported Distributions

- **Debian/Ubuntu** (apt-based): Uses `apt-get update && apt list --upgradable`
- **RHEL/CentOS/Rocky/Alma** (dnf-based): Uses `dnf update --assumeno`
- **CentOS 7/RHEL 7** (yum-based): Falls back to `yum update --assumeno`
- **Fedora** (dnf-based): Uses `dnf update --assumeno`

Package manager is auto-detected on each server during Phase 1.

## Key Architecture

### Global State Variables

```bash
declare -a SERVERS                    # Array of server addresses
declare -A SERVER_NICKNAMES           # server -> nickname mapping
declare -A SERVER_PORTS               # server -> SSH port mapping
declare -A SERVER_PKG_MANAGER         # server -> package manager (apt/dnf/yum)
declare -A SERVER_OS_RELEASE          # server -> OS release string
declare -A SERVER_KERNEL              # server -> kernel version
```

### Execution Flow

The script operates in distinct phases:

#### **Startup (lines ~980-998)**
- Displays list of all servers to be checked
- Shows total server count
- Waits for user to press Enter to begin
- **Exception**: In automated modes (`--non-interactive`, `--check-only`, `--assume-yes`), skips the Enter prompt

#### **Phase 1: Discovery & System Detection (lines ~860-884)**
- Connects to all servers **in parallel** using background jobs
- Each server runs in its own background process
- For each server:
  - Tests SSH connectivity
  - Detects package manager: `detect_package_manager()` (lines 357-388)
  - Gathers system info: `gather_system_info()` (lines 390-419)
    - OS release from `/etc/os-release`
    - Kernel version from `uname -r`
  - Runs appropriate update check command based on package manager
  - Counts available updates
- Dashboard updates in real-time (configurable refresh rate)
- Connection failures are displayed but don't stop execution

#### **Phase 2: Review & Approval (lines ~886-1029)**
- For each server with available updates:
  - Displays server header with nickname
  - Shows package list (format varies by package manager)
  - Highlights kernel packages in **RED BOLD** using `has_kernel_package()`
    - For apt: `linux-image`, `linux-headers`, `linux-modules`
    - For dnf/yum: Uses `KERNEL_PACKAGE_REGEX` config
  - Displays warning if kernel update detected
  - Prompts for user confirmation unless:
    - `--dry-run`: Skip all updates
    - `--check-only`: Display only, don't prompt
    - `--assume-yes`: Auto-approve all
    - `--non-interactive`: Skips all interactive prompts
  - Approved servers written to `$TEMP_DIR/approved_servers.txt`

#### **Phase 3: Parallel Execution (lines ~1031-1056)**
- Reads approved servers list
- Launches `apply_updates()` for each server in background
- Live dashboard shows real-time progress
- For servers with kernel updates:
  - Runs appropriate update command (apt-get upgrade / dnf update / yum update)
  - Detects if kernel was updated (distribution-aware)
  - Initiates reboot with `sudo reboot`
  - Calls `verify_reboot()` to monitor reboot process
- Updates complete simultaneously across all servers

#### **Phase 3.5: Results Summary (lines ~1058-1116)**
- After all background jobs complete
- Displays comprehensive results table
- For each approved server:
  - Reads `${server}.update_type` (kernel_update or no_reboot)
  - Reads `${server}.reboot_status` (success or failed)
  - Displays colored result indicator (✓ or ✗)
- Shows summary statistics:
  - Servers updated (no reboot)
  - Servers updated and rebooted
  - Servers with issues

#### **Phase 4: Local Server Update (lines ~1168-1310)**
**ONLY executes AFTER all remote servers complete**

This phase is specifically designed to safely update the local server (localhost) without interrupting remote server monitoring:

- Checks if `localhost` is in `approved_servers.txt`
- Displays pending updates for localhost
- Shows package list (distribution-aware formatting)
- Detects and warns about kernel updates:
  - ⚠️ Local server will reboot
  - ⚠️ You will lose your session
- **First user confirmation**: "Proceed with local server update? [y/N]"
  - In `--non-interactive` mode: Auto-approves if `--assume-yes` is also set, otherwise skips
- If approved:
  - Runs appropriate update command (apt/dnf/yum)
  - Detects if kernel was updated
  - If kernel updated:
    - **Second user confirmation**: "Reboot local server now? [y/N]"
      - In `--non-interactive` mode: Auto-approves if `--assume-yes` is also set, otherwise skips
    - If approved: 5-second countdown, then `sudo reboot`
    - If declined: Reminds user to reboot manually later
- All decisions logged to `$LOG_FILE`

**Why Phase 4 is separate:**
1. Prevents losing SSH session during remote server monitoring
2. Ensures all remote servers are healthy before local changes
3. Provides multiple safety confirmations
4. Allows postponing local reboot while keeping kernel update

**To activate Phase 4:**
Add `localhost` to your `server_list.txt`:
```
local-server localhost
```

### State Management

The script uses temporary files in `$TEMP_DIR` (created with 700 permissions):

| File | Purpose |
|------|---------|
| `${server}.status` | Current status message (read by `draw_dashboard()`) |
| `${server}.output` | Full package manager output for review |
| `${server}.os_release` | OS distribution name (e.g., "Ubuntu 22.04.3 LTS") |
| `${server}.kernel` | Kernel version (e.g., "5.15.0-91-generic") |
| `${server}.update_type` | Either `kernel_update` or `no_reboot` |
| `${server}.reboot_status` | Either `success` or `failed` |
| `approved_servers.txt` | List of servers approved for updates in Phase 2 |

**Note:** OS and kernel info are written to temp files (not associative arrays) because background processes cannot modify parent process variables.

### Dashboard Rendering

The `draw_dashboard()` function (lines ~510-587) renders the live status display in a **compact table format**:

**Layout:** One line per server (maximizes terminal space)
- Clears screen with ANSI escape codes
- Displays header banner
- Shows column headers: `SERVER | OS DISTRIBUTION | KERNEL VERSION | STATUS`
- For each server:
  - Reads status from `${server}.status` file
  - Reads OS info from `${server}.os_release` file
  - Reads kernel from `${server}.kernel` file
  - Applies color coding based on status keywords
  - Displays single formatted line with all information

**Example Output:**
```
SERVER                         OS DISTRIBUTION                  KERNEL VERSION               STATUS
────────────────────────────────────────────────────────────────────────────────────────────────────────────
192.0.2.10 (web-prod)          Rocky Linux 9.3 (Blue Onyx)      5.14.0-362.24.1.el9_3.x86_64 5 updates available
192.0.2.20 (db-prod)           Ubuntu 22.04.3 LTS               5.15.0-91-generic            Applying updates (apt)...
```

**Column Widths:**
- SERVER: 30 characters
- OS DISTRIBUTION: 32 characters
- KERNEL VERSION: 28 characters
- STATUS: 40 characters (color-coded)

**Smart Truncation:**
- Long values automatically truncated with "..."
- Ensures consistent table alignment

**Color Coding:**
- **Cyan**: Checking/connecting
- **Green**: Connected, no updates, successfully rebooted (✓), or complete
- **Yellow**: Updates available or rebooting
- **Red**: Errors
- **Magenta**: Applying updates

Refresh rate controlled by `$DASHBOARD_REFRESH` variable (default: 1 second).

### Package Manager Detection

The `detect_package_manager()` function (lines 357-388):
1. Checks for `apt-get` first
2. Falls back to `dnf`
3. Falls back to `yum`
4. Returns "unknown" if none found

Works on both remote servers (via SSH) and localhost.

### Kernel Update Detection

Distribution-aware detection via `has_kernel_package()` (lines 469-487):

**For apt (Debian/Ubuntu):**
- Checks for: `linux-image`, `linux-headers`, `linux-modules`

**For dnf/yum (RHEL/CentOS/Fedora):**
- Uses configurable `KERNEL_PACKAGE_REGEX` (default: `^kernel(-core|-modules)?\b`)
- Uses `KERNEL_UPDATE_REGEX` for actual update output

Detection happens in two places:
1. **Phase 2** (lines 991-996): Check package list before approval
2. **Phase 3** (lines 800-815): Check actual update output to trigger reboot

### Reboot Monitoring

The `verify_reboot()` function (lines 657-745) performs two-phase monitoring:

**Phase 1: Wait for Server to Go Down**
- Pings server every 5 seconds
- Maximum wait: 100 seconds (20 attempts × 5s)
- Verifies reboot command was executed
- Writes `failed` to `${server}.reboot_status` if timeout

**Phase 2: Wait for Server to Come Back Up**
- Checks every `REBOOT_WAIT_INTERVAL` seconds (default: 30s)
- Maximum wait: `REBOOT_MAX_WAIT` seconds (default: 900s = 15 minutes)
- Uses `uptime` command to verify server is responsive
- Updates dashboard: "Rebooting... attempt 5/30 (30s intervals)"
- Writes `success` to `${server}.reboot_status` on successful reconnection

Returns:
- **0**: Server successfully rebooted and reconnected
- **1**: Timeout or error

## Configuration

### Command-Line Options

```bash
./server_update.bash [OPTIONS]

--dry-run          # Check for updates but don't apply them
--check-only       # Display updates without prompting
--assume-yes       # Auto-approve all updates (dangerous!)
--non-interactive  # Skip all interactive prompts (for automation/testing)
--help, -h         # Display usage information
--version          # Display version
```

### Configuration File (server_update.conf)

Optional file with whitelisted variables:

```bash
DNF_TIMEOUT=600                    # Package manager command timeout (seconds)
DASHBOARD_REFRESH=1                # Dashboard update interval (seconds)
REBOOT_MAX_WAIT=900                # Maximum reboot wait time (seconds)
REBOOT_WAIT_INTERVAL=30            # Seconds between reboot checks
KERNEL_PACKAGE_REGEX="..."         # Kernel detection (dnf/yum only)
KERNEL_UPDATE_REGEX="..."          # Kernel update detection (dnf/yum only)
```

**Security:** Config file is parsed safely using `load_config()` function (lines 37-99). Only whitelisted variables are accepted, values are validated.

### Server List Format (server_list.txt)

```
# Format: nickname server_address [-p port]
web-prod 192.0.2.10
db-prod 192.0.2.20 -p 2222
localhost localhost
```

- Nickname: First column (required)
- Server: Second column - IP, hostname, or "localhost" (required)
- Port: Optional `-p PORT` flag (defaults to 22)
- Comments: Lines starting with `#`
- Empty lines ignored

Validation performed during parsing (lines 276-352):
- Server names checked for dangerous characters
- Ports validated (1-65535)
- Invalid entries skipped with warnings

## Security Features

### Input Validation (lines 109-177)
- `validate_server_name()`: Prevents command injection in server names
- `validate_port()`: Ensures port is 1-65535
- `validate_ip()`: Validates IPv4 and basic IPv6

### Safe Configuration Loading (lines 37-107)
- Whitelisted variables only
- Numeric value validation with maximum caps (604800 seconds = 1 week)
- **ReDoS protection**: Regex patterns tested with 1-second timeout to prevent catastrophic backtracking
- **Integer overflow protection**: Rejects values exceeding 604800 seconds
- Regex pattern syntax validation
- No arbitrary code execution via `source`

### File Permissions
- Temp directory: 700 (owner-only)
- Log file: 600 (owner read/write only)
- Warnings for world-writable config/server list files

### Proper Quoting
- All variable expansions in SSH commands are quoted
- Prevents word splitting attacks

## Helper Functions

### Core Functions

- `get_ssh_cmd(server)` (lines 421-440): Returns SSH command string with port
- `execute_remote_command(server, cmd, timeout)` (lines 442-456): Executes command locally or via SSH
- `get_display_name(server)` (lines 461-467): Formats "server (nickname)"
- `has_kernel_package(text, pkg_manager)` (lines 469-487): Checks for kernel packages
- `parse_dnf_package_count(output)` (lines 489-501): Extracts update count from dnf/yum output

### Main Functions

- `draw_dashboard()` (lines 495-547): Renders live status display
- `update_status(server, status)` (lines 549-555): Writes status to temp file
- `check_server_updates(server)` (lines 557-655): Phase 1 - check for updates
- `verify_reboot(server)` (lines 657-745): Monitors reboot process
- `apply_updates(server)` (lines 747-843): Phase 3 - apply updates and handle reboots

## SSH Configuration

The script uses: `ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 [-p PORT]`

**Requirements:**
- SSH key-based authentication configured for all servers
- Passwordless sudo recommended for automation
- SSH service must start on boot (for reboot monitoring)

## Modifying Behavior

### Adjusting Dashboard Refresh Rate
Set `DASHBOARD_REFRESH` in `server_update.conf`. Default is 1 second.

### Adjusting Reboot Monitoring
In `server_update.conf`:
- `REBOOT_MAX_WAIT`: Total time to wait (default: 900s = 15 minutes)
- `REBOOT_WAIT_INTERVAL`: Check interval (default: 30s)

### Adding Kernel Package Patterns (dnf/yum only)
Modify in `server_update.conf`:
```bash
KERNEL_PACKAGE_REGEX="^kernel(-core|-modules|-devel|-headers)?\b"
KERNEL_UPDATE_REGEX="(Installing|Upgrading).*(kernel-core|kernel-modules|kernel-devel|kernel)\b"
```

For apt systems, modify `has_kernel_package()` function directly (line 478).

### Custom Package Highlighting
Modify the Phase 2 display sections (lines 947-996) to highlight additional critical packages.

## Logging

All operations logged to `server_update.log` with:
- Timestamps using `$(date)`
- Connection failures
- Update successes/failures
- Reboot monitoring results
- Error messages

Log file created with 600 permissions. Warns if log exceeds 10MB.

## Version History

### Version 1.1 (Current)
- **Multi-distribution support**: apt/dnf/yum auto-detection
- **Enhanced dashboard**: Compact table format showing OS release, kernel version, and status on one line per server
- **Phase 4: Local server updates**: Safely updates localhost AFTER all remote servers with two-stage confirmation
- **Security improvements**: Input validation, safe config parsing, ReDoS protection, integer overflow protection, secure permissions
- **New command-line options**: --check-only, --assume-yes, --non-interactive, --help, --version
- **Code quality**: Comprehensive documentation, helper functions, reduced redundancy
- **Better error handling**: Connection failures don't stop execution
- **Configurable dashboard refresh rate**
- **Log size warnings**
- **State management via temp files**: OS/kernel info shared across background processes

## Important Notes for AI Assistants

1. **Multi-distro support**: Always consider that servers may run different distributions. Use the appropriate package manager for each server.

2. **Parallel execution**: Background jobs (`&`) are used extensively. Always wait for jobs to complete before reading result files.

3. **Security**: Never use `source` for config files. Always validate user input. Quote all variable expansions.

4. **State files**: All inter-process communication uses temporary files in `$TEMP_DIR`. Read these files to get current state.
   - Background processes **cannot modify** parent process variables (arrays)
   - All shared data (status, OS info, kernel) must use temp files

5. **Phase 4 (localhost)**: Special handling for local server updates:
   - Only executes AFTER all remote servers complete (Phases 1-3.5)
   - Requires TWO user confirmations (update + reboot)
   - Prevents losing SSH session during remote monitoring
   - To enable: Add `localhost` to server_list.txt

6. **Dashboard format**: Compact table with ONE line per server:
   - Fixed column widths with automatic truncation
   - Real-time updates from temp files
   - Must handle missing data gracefully (show `--` before OS/kernel detected)

7. **Color codes**: Dashboard uses ANSI escape codes. Test changes in a terminal that supports colors.

8. **Line numbers**: Line numbers in this doc are approximate. Use function names or grep to find specific code sections.

9. **Testing**: Test changes with different distributions (Debian and RHEL-based) to ensure compatibility.
