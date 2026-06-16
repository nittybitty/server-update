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

**Current Version:** 1.4

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

### Instance Locking

To prevent multiple instances from running simultaneously (which could cause package manager conflicts and corrupted state), the script implements **PID-based instance locking**:

**Lock File:** `/tmp/server_update.lock`

**Startup Checks (lines 115-139):**
- If lock file exists:
  - Reads PID from lock file
  - Uses `kill -0 $PID` to check if process is still running
  - **Active instance**: Exits with error message showing PID
  - **Stale lock**: Automatically removes and continues
- Creates new lock file with current PID (`$$`)
- Fails if unable to create lock file

**Lock Cleanup (line 310):**
- `cleanup()` function removes lock file on exit
- Triggered by trap on EXIT, INT, TERM signals
- Ensures clean removal even if script is interrupted

**Error Handling:**
- Clear error messages when another instance is detected
- Instructions for manual lock removal if needed
- Permission errors reported if lock file creation fails

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
  - Gathers system info: `gather_system_info()`
    - OS release via fallback chain: `/etc/os-release` PRETTY_NAME →
      `lsb_release -d` → `/etc/redhat-release` (so pre-systemd hosts like
      CentOS/RHEL 6 still populate the OS column instead of showing `--`)
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

### Instance Locking (lines 115-139)
- **PID-based locking** prevents multiple simultaneous executions
- Lock file: `/tmp/server_update.lock` contains running process PID
- Detects and rejects active instances
- Automatically removes stale locks (when PID no longer exists)
- Prevents package manager conflicts and state corruption
- Lock cleanup on exit (via trap on EXIT, INT, TERM)

### Atomic Temp File Writes
- **Atomic-rename writes** prevent torn reads of shared state
- Writers stage content in a unique `${file}.$BASHPID.tmp` file, then `mv` it
  into place; `rename(2)` is atomic on a single filesystem
- A concurrent reader always sees the previous file or the fully-written new
  one — never an empty or half-written file
- Reads are plain `cat` (no lock needed), which removes the per-read `flock`
  fork that the old implementation paid on every dashboard refresh
- Semantics are whole-file, last-writer-wins — which is exactly what the
  per-server state model needs (only one writer ever targets a given file)
- All temp file operations use `safe_write_file()` and `safe_read_file()`

## Helper Functions

### Atomic Temp File Utilities

**Purpose:** Prevent torn reads when background processes write per-server state files that the dashboard reads concurrently.

- `safe_write_file(file_path, content)`: Atomic write via staging file + rename
  - Writes to `${file_path}.$BASHPID.tmp`, then `mv -f` into place
  - `$BASHPID` (not `$$`) is the real PID of the writing process — background
    jobs run in subshells where `$$` still holds the parent's PID, so `$BASHPID`
    is what keeps the staging name unique per writer
  - Cleans up the staging file and returns 1 on any failure
  - **Usage:** All temp file writes use this function

- `safe_read_file(file_path, default_value)`: Plain read, no lock
  - Atomic-rename writes guarantee a reader never observes a partial file
  - Returns the default value if the file is missing (or vanishes mid-read)
  - **Usage:** All temp file reads use this function

**Implementation Details:**
- Atomicity relies on `rename(2)` being atomic on a single filesystem; staging
  file and target both live inside `$TEMP_DIR`, so the move is a rename
- Staging files: `${original_file}.$BASHPID.tmp` (removed by the `mv`)
- Requires bash 4.0+ for `$BASHPID` — already mandated by the script's use of
  associative arrays (`declare -A`)
- Cheaper than the previous flock approach: no lock file, no fork per read

**Files Protected:**
- `${server}.status` - Server status messages
- `${server}.os_release` - OS distribution info
- `${server}.kernel` - Kernel version
- `${server}.pkg_manager` - Package manager type
- `${server}.update_type` - Update type (kernel_update/no_reboot)
- `${server}.reboot_status` - Reboot result (success/failed)

### Core Functions

- `get_ssh_cmd(server)` (lines 454-473): Returns SSH command string with port
- `execute_remote_command(server, cmd, timeout)` (lines 475-489): Executes command locally or via SSH
- `get_display_name(server)` (lines 494-500): Formats "server (nickname)"
- `has_kernel_package(text, pkg_manager)` (lines 502-520): Checks for kernel packages
- `parse_dnf_package_count(output)` (lines 522-534): Extracts update count from dnf/yum output

### Main Functions

- `draw_dashboard()` (lines 536-620): Renders live status display
- `update_status(server, status)` (lines 715-721): Writes status to temp file using `safe_write_file()`
- `check_server_updates(server)` (lines 723-821): Phase 1 - check for updates
- `verify_reboot(server)` (lines 823-1009): Monitors reboot process
- `apply_updates(server)` (lines 1011-1110): Phase 3 - apply updates and handle reboots

## SSH Configuration

SSH options are **version-aware**, chosen once at startup by
`detect_ssh_capabilities()` based on the **local** client's OpenSSH version
(`ssh -V`). All of these are client-side options, so they gate on the controller
host, not the targets — remote servers only need to speak SSH-2 (every OpenSSH
since 2.x), which is why even an ancient target like CentOS 6 is fine to manage.

`detect_ssh_capabilities()` sets two globals consumed by `get_ssh_cmd()`:

| Capability | Option | OpenSSH floor | Fallback below floor |
|------------|--------|---------------|----------------------|
| Host key policy | `StrictHostKeyChecking=accept-new` | 7.6 | `StrictHostKeyChecking=no` |
| Connection multiplexing | `ControlMaster=auto` + `ControlPath=$TEMP_DIR/ssh-cm/cm-%C` + `ControlPersist=600` | 6.7 (`%C` token) | multiplexing disabled (one handshake per command) |

`ConnectTimeout=10` is always present. The resulting command for a modern
controller is:
`ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=$TEMP_DIR/ssh-cm/cm-%C -o ControlPersist=600 [-p PORT]`

Effective controller matrix:
- **RHEL/Rocky/Alma 8+, Debian 10+, Ubuntu 18.04+** (≥7.6): accept-new + pooling
- **CentOS 7, Debian 9** (7.4): host key falls back to `no`, pooling on
- **CentOS 6** (5.3): host key `no`, pooling disabled — works, just no speedup
- Unparseable `ssh -V`: lowest-common-denominator (`no`, no pooling)

**Requirements:**
- SSH key-based authentication configured for all servers
- Passwordless sudo recommended for automation
- SSH service must start on boot (for reboot monitoring)
- Bash 4.0+ on the controller (already required by associative arrays)

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

### Version 1.4 (Current - 2026-06-03)
- **Version-aware SSH options**: `detect_ssh_capabilities()` probes the local
  `ssh -V` once at startup and builds only the options the client supports
  - Restores compatibility with old controllers (CentOS 6's OpenSSH 5.3,
    CentOS 7's 7.4) that choke on `StrictHostKeyChecking=accept-new` (needs 7.6)
    and `ControlPath %C` (needs 6.7)
  - Modern controllers keep accept-new + connection pooling; older ones fall
    back to `StrictHostKeyChecking=no` and/or disabled multiplexing
  - See the SSH Configuration section for the full controller matrix
- **Atomic-rename temp writes**: `safe_write_file()`/`safe_read_file()` replaced
  flock with staging-file + `mv` (atomic `rename(2)`)
  - Removes a per-read `flock` fork on every dashboard refresh (CPU win on long
    runs); reads are now plain `cat`
  - Uses `$BASHPID` so each background writer's staging file is unique
- **OS detection fallback chain**: `gather_system_info()` now tries
  `/etc/os-release` → `lsb_release -d` → `/etc/redhat-release`, so pre-systemd
  hosts (CentOS/RHEL 6) populate the OS column instead of showing `--`
- **Compatibility**: CentOS 6 supported as both controller and target again

### Version 1.3 (2026-01-07)
- **SSH connection pooling**: Massive performance improvement with ControlMaster
  - Reuses SSH connections across multiple commands (87% reduction in SSH handshakes)
  - ControlPersist=600: Connections stay alive for 10 minutes
  - Reduces execution time by 2-5x on typical workloads
  - Prevents hitting SSH MaxStartups limits
- **Disk space checking**: Pre-flight checks prevent catastrophic failures
  - Requires 2GB free on `/` partition (realistic for most updates)
  - Requires 300MB free on `/boot` partition (enough for kernel updates)
  - New `check_disk_space()` function runs before every update
  - Prevents half-installed packages and unbootable systems
- **Enhanced security**: Multiple security improvements
  - StrictHostKeyChecking=accept-new: Protects against MITM attacks (was: no)
  - umask 077: All temp files are owner-only (prevents information disclosure)
  - Better localhost detection: Checks 127.0.0.1 and ::1 (prevents updating wrong machine)
- **Bug fixes**: 7 critical/high-priority issues resolved
  - Fixed package filter specificity: `grep -v "^Listing\.\.\.$"` (prevents false positives)
  - Fixed race condition: Added `wait` after background jobs complete
  - Replaced Unicode box characters with ASCII (universal terminal compatibility)
- **Performance**: Overall 2-3x speedup with SSH connection pooling
- **Compatibility**: Works in all terminals, locales, and SSH environments

### Version 1.2 (2026-01-07)
- **Instance locking**: PID-based locking prevents multiple script instances from running simultaneously
  - Prevents package manager conflicts (apt/dnf/yum can't run concurrently)
  - Detects and removes stale locks automatically
  - Lock file: `/tmp/server_update.lock`
- **File locking**: flock-based locking prevents race conditions with temp files
  - New `safe_write_file()` and `safe_read_file()` utility functions
  - Atomic reads/writes for all shared state
  - Shared locks for reads, exclusive locks for writes
  - Eliminates file corruption from concurrent background processes
- **Reliability improvements**: No more corrupted dashboards or duplicate executions
- **Testing**: Added `test_flock.bash` and `test_instance_lock.bash` for verification

### Version 1.1
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
   - **CRITICAL**: Always use `safe_write_file()` and `safe_read_file()` for temp file operations
   - Never use direct `cat`, `echo >`, or `>` for temp files - this causes race conditions
   - File locking prevents corruption from concurrent access

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
