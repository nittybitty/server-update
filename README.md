# Server Update Dashboard

An interactive bash script for managing system updates across multiple Linux servers with a real-time dashboard. Supports **Debian/Ubuntu (apt)**, **RHEL/CentOS/Rocky/Alma (dnf/yum)**, and **Fedora (dnf)** — including old targets and controllers like CentOS/RHEL 6 and 7.

**Version:** 1.4 (plus unreleased fixes)

## Features

### 🐧 Multi-Distribution Support
- **Auto-detects package manager** on each server (apt, dnf, or yum)
- Works seamlessly across:
  - **Debian/Ubuntu** (apt-based systems) — applies with `dist-upgrade` so kernel updates aren't held back
  - **RHEL/CentOS/Rocky Linux/AlmaLinux** (dnf/yum-based systems)
  - **Fedora** (dnf-based systems)
- Falls back from dnf → yum for older systems — yum checks use `echo n | yum update`, which works on every yum generation back to RHEL 6 (where `--assumeno` doesn't exist)
- Understands yum vs dnf output differences (`Updating:` vs `Upgrading:`, `Update N Package(s)` vs `Upgrade`)
- No manual configuration required

### 🚀 Parallel Execution
- Checks all servers for updates simultaneously in background jobs
- Live dashboard shows real-time status updates for each server
- Connection failures don't stop script execution

### 📊 Enhanced Interactive Dashboard
The dashboard displays:
- Server nickname and IP address
- **OS Release** (e.g., "Ubuntu 22.04.3 LTS", "Rocky Linux 9.3")
- **Kernel Version** (e.g., "5.15.0-91-generic")
- Current status (color-coded):
  - **Cyan**: Checking connection
  - **Green**: Connected, no updates, or complete
  - **Yellow**: Updates available or rebooting
  - **Red**: Errors
  - **Magenta**: Applying updates
- A live summary footer: `Active: N | Updates: N | Done: N | Errors: N | Elapsed: MM:SS`

Rendering details:
- **Flicker-free**: repaints in place instead of clearing the screen each frame
- **Width-aware**: column widths adapt to the terminal, down to 80 columns (serial consoles, default PuTTY windows)
- **Terminal-friendly**: UTF-8 symbols (`✓ ✗ ⚠`) fall back to ASCII (`[OK] [X] [!]`) on non-UTF-8 locales
- **Automation-friendly**: when output is not a terminal (cron, pipes), the live loop is skipped and one plain table is printed; setting `NO_COLOR` disables colors everywhere
- SSH failures show a classified reason (auth failed, DNS lookup failed, connection refused, host key changed, timed out) instead of a bare "connection failed"

### 📋 Update Review
For each server with available updates:
- Shows complete list of packages to be updated
- Highlights kernel packages in **RED** (distribution-aware):
  - apt: `linux-image`, `linux-headers`, `linux-modules`
  - dnf/yum: `kernel`, `kernel-core`, `kernel-modules`
- Prompts for confirmation before applying updates: `[y/N/a=yes to all/q=quit review]`
- Multiple operation modes available (see Command-Line Options)

### 🔄 Smart Reboot Logic with Monitoring
- **Only reboots if kernel packages are updated**
- Distribution-aware kernel detection — for apt, only packages actually installed count (`Setting up`/`Unpacking` lines plus `/var/run/reboot-required`), so "kept back" kernels don't trigger a pointless reboot
- Skips reboot for non-kernel updates
- **Reboots are verified by boot_id**: the script captures `/proc/sys/kernel/random/boot_id` before rebooting and polls until it changes — proof the machine actually rebooted, even a VM that cycles in seconds
- Fails fast (~2 minutes) if the reboot command silently never took effect
- **Monitors reboot progress** checking every 30 seconds (configurable), maximum wait 15 minutes (configurable)
- Verifies server is fully accessible after reboot

### 🔒 Security Enhancements
- **Input validation** prevents command injection attacks
- **Safe config file parsing** with whitelisted variables only
- **ReDoS protection** prevents regex-based denial of service attacks
- **Integer overflow protection** rejects unreasonably large timeout values
- **Secure file permissions**: temp dirs (700), logs (600)
- **Permission warnings** for world-writable config/server list files
- **Atomic instance locking** (`O_CREAT|O_EXCL`) — two racing instances can't both start
- All variable expansions properly quoted
- Config values assigned via `printf -v` — no `eval`, no `source`, no code execution path

### 📈 Results Summary
After all servers are processed:
- Displays comprehensive results for each server
- Shows which servers were updated without reboot (✓)
- Shows which servers were updated and successfully rebooted (✓)
- Highlights any servers with issues (✗)
- Provides summary statistics of all operations

### 📝 Logging
- All operations logged to `server_update.log`
- Includes timestamps and detailed status messages

## Usage

```bash
cd /root/server-update
./server_update.bash [OPTIONS]
```

### Command-Line Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Check for updates but don't apply them |
| `--check-only` | Display available updates without prompting for approval |
| `--assume-yes` | Automatically approve all updates (use with caution!) |
| `--non-interactive` | Skip all interactive prompts (for automation/testing) |
| `--help`, `-h` | Display usage information |
| `--version` | Display version information |

**Environment:** set `NO_COLOR` (any value) to disable colored output, per the [no-color.org](https://no-color.org) convention. Colors are also disabled automatically when output is not a terminal.

### Operation Modes

**Interactive Mode** (default)
```bash
./server_update.bash
```
- Shows all available updates
- Prompts for confirmation before applying each server's updates
- Recommended for production environments

**Check-Only Mode**
```bash
./server_update.bash --check-only
```
- Displays what updates are available
- Does not prompt or apply any updates
- Useful for auditing and reporting

**Automated Mode**
```bash
./server_update.bash --assume-yes
```
- Automatically approves and applies all updates
- No user interaction required
- Useful for automated maintenance windows
- ⚠️ **Use with caution** - will update and reboot servers without confirmation

**Dry-Run Mode**
```bash
./server_update.bash --dry-run
```
- Shows what would be updated
- Does not apply any changes
- Safe for testing

**Non-Interactive Mode**
```bash
./server_update.bash --non-interactive --assume-yes
```
- Skips all interactive prompts (no "Press Enter", no confirmation prompts)
- Useful for automation, CI/CD pipelines, and fuzzing/testing
- Combines with `--assume-yes` to fully automate updates
- Without `--assume-yes`, will check but not apply updates
- Localhost updates require `--assume-yes` to proceed automatically

## Configuration

### Optional Configuration File

Create a `server_update.conf` file in the same directory to customize behavior:

```bash
# Timeout for the update *check* phase (seconds)
DNF_TIMEOUT=600

# Timeout for actually *applying* updates (seconds). Kept separate: big
# updates routinely exceed 10 minutes, and killing a package transaction
# mid-flight risks rpmdb/dpkg corruption.
APPLY_TIMEOUT=3600

# Dashboard refresh rate (seconds)
DASHBOARD_REFRESH=1

# Reboot monitoring settings
REBOOT_MAX_WAIT=900           # Maximum wait time (15 minutes)
REBOOT_WAIT_INTERVAL=30       # Check interval (30 seconds)

# Kernel package detection (dnf/yum only - apt uses hardcoded patterns)
KERNEL_PACKAGE_REGEX="^kernel(-core|-modules)?\b"
KERNEL_UPDATE_REGEX="(Installing|Upgrading).*(kernel-core|kernel-modules|kernel)\b"
```

**Configuration Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `DNF_TIMEOUT` | 600 | Timeout for the update check phase (seconds) |
| `APPLY_TIMEOUT` | 3600 | Timeout for applying updates in Phase 3/4 (seconds) |
| `DASHBOARD_REFRESH` | 1 | Dashboard update interval (seconds) |
| `REBOOT_MAX_WAIT` | 900 | Maximum time to wait for reboot (15 minutes) |
| `REBOOT_WAIT_INTERVAL` | 30 | Seconds between reboot checks |
| `KERNEL_PACKAGE_REGEX` | See above | Pattern to detect kernel packages (dnf/yum) |
| `KERNEL_UPDATE_REGEX` | See above | Pattern to detect kernel installations (dnf/yum) |

**Security Notes:**
- Config file is parsed safely with whitelisted variables only — values are assigned with `printf -v`, never `eval` or `source`
- Values are validated before use (numeric checks with a minimum of 1, regex validation with timeout)
- Script will warn if config file has unsafe permissions
- ReDoS protection: Regex patterns are tested with 1-second timeout
- Integer overflow protection: Values capped at 604800 seconds (1 week)

## Server List Format

Edit `server_list.txt` with the format: `nickname ipaddress [-p port]`

```
# Format: nickname ipaddress [-p port]
# Comments start with #

# Production web server (default port 22)
web-prod 192.0.2.10

# Production database server (custom SSH port)
db-prod 192.0.2.20 -p 2222

# Local server (updates AFTER all remote servers - see Phase 4)
local-server localhost

# Empty lines are ignored
```

**Important notes:**
- The nickname will be displayed in parentheses next to the IP address throughout the dashboard and prompts
- Port specification is optional and defaults to port 22 if not specified
- Use `-p portnumber` to specify a custom SSH port for any server
- **localhost is special**: If included, it updates in Phase 4 (AFTER all remote servers complete)
  - Prevents losing your session while monitoring remote updates
  - Requires explicit user confirmation before updating
  - Requires second confirmation before rebooting (if kernel updated)

## Workflow

### Startup
- Displays list of all servers to be checked
- Shows server count
- Waits for user to press Enter

### Phase 1: Discovery & System Detection
- Connects to all servers **in parallel** using background jobs
- Detects OS release and kernel version on each server
- Auto-detects package manager (apt/dnf/yum)
- Runs appropriate update check command:
  - **apt**: `apt-get update && apt list --upgradable`
  - **dnf**: `dnf update --assumeno`
  - **yum**: `echo n | yum update` (works on every yum generation, including RHEL 6 where `--assumeno` doesn't exist)
- Displays **live dashboard** with real-time status updates
- Shows OS, kernel version, and update count for each server
- Connection failures are displayed with a classified reason (auth, DNS, refused, host key, timeout) but don't stop the script

### Phase 2: Review & Approval
- For each server with available updates:
  - Shows complete list of packages to be updated
  - Highlights kernel packages in **RED** (distribution-aware)
  - Displays warning if kernel update will require reboot
  - Prompts for confirmation: `[y/N/a=yes to all/q=quit review]` (unless in automated mode)
    - `a` approves this server and all remaining ones; `q` stops the review and skips the rest
- Builds list of approved servers for Phase 3

### Phase 3: Parallel Execution
- Applies updates to all approved servers **simultaneously**
- Uses appropriate package manager for each server (`apt-get dist-upgrade` / `dnf update` / `yum update`), with `APPLY_TIMEOUT` (default 1 hour)
- Live dashboard shows real-time progress
- For servers with kernel updates:
  - Captures the server's boot_id, then initiates the reboot
  - Monitors until the boot_id **changes** — proof the reboot actually happened (checks every 30s by default, max 15 minutes)
  - Fails fast if the reboot command never took effect
  - Verifies server is fully accessible after reboot

### Phase 3.5: Results Summary
- Displays comprehensive results table for all updated servers
- Shows success indicators (✓) or failure indicators (✗)
- Categories:
  - Servers updated without reboot (✓)
  - Servers updated and successfully rebooted (✓)
  - Servers with issues (✗)
- Provides summary statistics

### Phase 4: Local Server Update (Optional)
**⚠️ Only executes AFTER all remote servers complete**

If `localhost` is in your server list and has updates:
- Waits until **ALL remote servers** finish updating
- **Skipped entirely** in `--dry-run` and `--check-only` modes (prints a note instead)
- `--assume-yes` auto-approves both confirmations (consistent with remote servers)
- Displays pending updates for the local server
- **Shows clear warnings** if kernel update detected:
  - ⚠️ Local server will reboot
  - ⚠️ You will lose your session
- **First confirmation**: Proceed with local server update? [y/N]
- Applies updates using appropriate package manager
- If kernel was updated:
  - **Second confirmation**: Reboot local server now? [y/N]
  - 5-second countdown before reboot (time to cancel)
  - Option to postpone reboot and reboot manually later

**Why Phase 4 is separate:**
- Prevents losing SSH connection while monitoring remote servers
- Ensures all remote servers are healthy before local changes
- Gives you full control with multiple confirmation steps
- Safest way to automate local server updates

**To enable:** Add `local-server localhost` to your `server_list.txt`

### Final Summary
- Shows completion timestamp
- Directs user to log file for detailed logs
- Clean exit

## Requirements

### SSH Access
- SSH key-based authentication configured for all remote servers
- Passwordless sudo recommended for automation
- For custom SSH ports, specify with `-p PORT` in server list

### Package Managers
The script automatically detects and supports:
- **apt** (Debian, Ubuntu, Linux Mint, etc.)
- **dnf** (Fedora, RHEL 8+, Rocky Linux 8+, AlmaLinux 8+)
- **yum** (CentOS/RHEL 6 and 7, older systems)

### System Requirements (controller)
- Bash 4.0 or higher (CentOS/RHEL 6's bash 4.1 works)
- Standard Unix utilities: `grep`, `sed`, `awk`, `cat`, `uname`
- `timeout` command (part of coreutils)
- Network connectivity to all target servers
- Any OpenSSH client — SSH options are chosen automatically based on the local `ssh -V`: modern clients get `StrictHostKeyChecking=accept-new` and connection multiplexing; old ones (CentOS 6's OpenSSH 5.3, CentOS 7's 7.4) get compatible fallbacks and still work, just without the speedup

## What's New (Unreleased fixes)

### Correctness
- ✅ **apt servers restored to review**: the Phase 2 gate only recognized dnf/yum output, so apt servers were silently dropped and could never be approved — fixed
- ✅ **`--dry-run`/`--check-only` now truly safe**: Phase 4 previously ignored both flags and could update and even reboot the local machine
- ✅ **apt applies with `dist-upgrade`** (plain `upgrade` holds back kernel updates), non-interactively with conffile-prompt protection
- ✅ **boot_id-verified reboots**: a changed `/proc/sys/kernel/random/boot_id` proves the reboot happened — fast-cycling VMs are no longer misread as "did not go down", and a reboot command that silently fails is detected in ~2 minutes
- ✅ **apt kernel detection anchored to installed packages**: "kept back" kernels no longer trigger unnecessary reboots
- ✅ **`127.0.0.1`/`::1` treated as localhost everywhere** — previously only the literal `localhost` was, so an IP-addressed local entry could reboot the control host mid-run
- ✅ **Separate `APPLY_TIMEOUT` (1h default)** — the old 10-minute check timeout could kill a big update mid-transaction
- ✅ **Duplicate server entries rejected**; config/server-list files without a trailing newline parse fully
- ✅ **Config loader hardening**: `printf -v` assignment (no eval), zero values rejected, and a latent bug fixed that made regex validation a no-op

### Older-distro support
- ✅ **yum checks work on RHEL 6** (`echo n | yum update` instead of `--assumeno`)
- ✅ **yum output parsed correctly** (`Updating:`/`Update N Package(s)` variants)
- ✅ **ASCII symbol fallback** on non-UTF-8 locales (no more mojibake on old consoles)
- ✅ **80-column-friendly dashboard** (serial consoles, default PuTTY)

### UI
- ✅ **Flicker-free dashboard** with live summary footer and hidden cursor (restored on exit/Ctrl-C)
- ✅ **Non-tty mode** for cron/pipes: plain single table, no escape codes; `NO_COLOR` honored
- ✅ **Classified SSH errors** (auth failed, DNS lookup failed, connection refused, host key changed, timed out)
- ✅ **Faster review**: `a` = approve all remaining, `q` = quit review

## What's New in Version 1.4

- ✅ **Version-aware SSH options**: options are gated on the local `ssh -V` — old controllers (CentOS 6/7) work again, modern ones keep `accept-new` + connection pooling
- ✅ **Atomic-rename temp writes**: staging file + `mv` replaced flock — no fork per read, no torn reads
- ✅ **OS detection fallback chain**: `/etc/os-release` → `lsb_release -d` → `/etc/redhat-release`, so pre-systemd hosts (CentOS/RHEL 6) populate the OS column
- ✅ **Single-round-trip discovery**: package manager, OS, and kernel gathered in one SSH exchange per server (was ~5-7)
- ✅ **Fork-free dashboard reads**: ~6.8x faster dashboard refresh
- ✅ **CentOS 6 supported as both controller and target again**

## What's New in Version 1.3

### Performance Improvements
- ✅ **SSH connection pooling** with ControlMaster - Massive performance boost!
  - Reuses SSH connections across multiple commands (87% fewer SSH handshakes)
  - ControlPersist keeps connections alive for 10 minutes
  - **2-5x faster execution** on typical workloads
  - Prevents hitting SSH MaxStartups limits on high server counts
  - Automatic cleanup of SSH control sockets on exit

### Pre-Flight Safety Checks
- ✅ **Disk space checking** prevents catastrophic failures
  - Requires minimum 2GB free on `/` partition (realistic for most updates)
  - Requires minimum 300MB free on `/boot` partition (enough for kernels)
  - New `check_disk_space()` function runs before every update
  - Prevents half-installed packages and unbootable systems
  - Clear error messages showing available vs required space

### Security Enhancements
- ✅ **StrictHostKeyChecking=accept-new** instead of 'no'
  - Accepts new host keys automatically (automation-friendly)
  - Verifies known host keys (protects against MITM attacks)
  - Significantly more secure than previous 'no' setting
- ✅ **umask 077** for all temp files
  - Prevents information disclosure (temp files are owner-only)
  - Protects sensitive package lists and server information
- ✅ **Enhanced localhost detection**
  - Checks 127.0.0.1, ::1, and localhost
  - Prevents accidentally updating wrong machine if remote hostname is "localhost"

### Bug Fixes
- ✅ **More specific package filtering**: `grep -v "^Listing\.\.\.$"` instead of `grep -v "Listing..."`
  - Prevents accidentally filtering packages with "listing" in the name
- ✅ **Race condition eliminated**: Added `wait` after background job loops
  - Ensures all temp files are fully written before reading
  - More reliable dashboard display and status reporting
- ✅ **ASCII box characters** replace Unicode
  - Universal terminal compatibility (works in all locales)
  - Displays correctly over SSH to any system
  - No more rendering issues in minimal/embedded environments

### Performance Impact
- **SSH connections reduced by ~87%** (from ~8 per server to ~1 per server)
- **Overall speedup: 2-3x** for typical multi-server workloads
- **Lower resource usage**: Fewer TCP connections, less CPU/memory
- **More reliable**: Disk space checks prevent failures

## What's New in Version 1.2

### Reliability & Concurrency Improvements
- ✅ **Instance locking** prevents multiple script instances from running simultaneously
  - PID-based locking with automatic stale lock detection
  - Prevents package manager conflicts (apt/dnf/yum can't run concurrently)
  - Lock file: `/tmp/server_update.lock`
- ✅ **File locking** eliminates race conditions with temp files
  - New `safe_write_file()` and `safe_read_file()` utility functions
  - flock-based atomic reads/writes for all shared state
  - No more corrupted dashboard displays
  - Shared locks for concurrent reads, exclusive locks for writes

### Testing
- ✅ **test_flock.bash** - Verifies file locking works correctly under concurrent load
- ✅ **test_instance_lock.bash** - Verifies instance locking and stale lock cleanup

### Bug Fixes
- Fixed race conditions when background processes access temp files simultaneously
- Fixed potential dashboard corruption from concurrent reads/writes
- Fixed issues with multiple instances interfering with each other

## What's New in Version 1.1

### Multi-Distribution Support
- ✅ **Auto-detects package manager** (apt/dnf/yum) on each server
- ✅ **Full Debian/Ubuntu support** via apt-get
- ✅ **YUM fallback** for older RHEL/CentOS systems
- ✅ **Distribution-aware kernel detection** (linux-image for Debian, kernel for RHEL)

### Enhanced Dashboard
- ✅ **OS Release display** shows distribution name and version
- ✅ **Kernel version display** for all servers
- ✅ Real-time system information gathering

### Security Improvements
- ✅ **Input validation** prevents command injection attacks
- ✅ **Safe configuration parsing** with whitelisted variables
- ✅ **ReDoS protection** prevents catastrophic backtracking in regex patterns
- ✅ **Integer overflow protection** caps timeout values at 1 week maximum
- ✅ **Secure file permissions** (700 for temp, 600 for logs)
- ✅ **Permission warnings** for insecure config files
- ✅ **No arbitrary code execution** vulnerabilities
- ✅ All variable expansions properly quoted

### New Features
- ✅ **Phase 4: Safe local server updates** - Updates localhost AFTER all remote servers complete
- ✅ **Two-stage confirmation** for local updates and reboots
- ✅ **--check-only mode** for auditing
- ✅ **--assume-yes mode** for automation
- ✅ **--non-interactive mode** for complete automation and testing
- ✅ **--help and --version** flags
- ✅ **Configurable dashboard refresh rate**
- ✅ **Compact table dashboard** - One line per server showing OS, kernel, and status
- ✅ **Log size warnings** (when log > 10MB)
- ✅ **Better error handling** - connection failures don't stop execution

### Code Quality
- ✅ **Comprehensive documentation** with function headers
- ✅ **Helper functions** eliminate code duplication
- ✅ **Phase comments** explain workflow clearly
- ✅ **Magic numbers documented** (all timeouts and retries explained)

## Troubleshooting

### "No supported package manager found"
- Verify the target server has `apt-get`, `dnf`, or `yum` installed
- Check that the package manager is in the system PATH
- Ensure you have sudo privileges to run package manager commands

### "Connection failed" errors
- Verify SSH key-based authentication is configured
- Check network connectivity to the server
- Verify the correct port is specified (default: 22)
- Test manual SSH connection: `ssh -p PORT server_address`

### "Command timed out"
- For check-phase timeouts, increase `DNF_TIMEOUT` in `server_update.conf` (default: 600 seconds)
- For apply-phase timeouts, increase `APPLY_TIMEOUT` (default: 3600 seconds) — note the remote package manager may still be running after a local timeout
- Check network bandwidth to the server
- Verify the package manager repository configuration is correct

### "Server did not come back online after reboot"
- Increase `REBOOT_MAX_WAIT` in configuration (default: 900 seconds)
- Check if the server actually rebooted (may have hung)
- Verify SSH service starts automatically on boot
- Check firewall rules aren't blocking SSH after reboot

### Dashboard not updating
- Adjust `DASHBOARD_REFRESH` if updates seem too fast/slow
- Check that background jobs are running: `jobs -r`
- Ensure terminal supports ANSI escape codes
- Note: when output is piped or run from cron, the live dashboard is intentionally skipped — one plain table is printed at the end

### Garbled symbols (mojibake) in output
- The script auto-detects UTF-8 support via `locale charmap` and falls back to ASCII symbols
- If you still see garbled characters, check that `LANG`/`LC_ALL` reflect your terminal's actual encoding

## License

This project is provided as-is for system administration purposes.

## Contributing

For bugs, feature requests, or contributions, please see the project repository.

---

**Version 1.4** • Supports apt/dnf/yum • Multi-distribution compatible (CentOS 6 → current) • SSH pooling • boot_id-verified reboots • Disk space checks • Enhanced security