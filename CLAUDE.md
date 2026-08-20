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

- **Debian/Ubuntu** (apt-based): Checks with `apt-get update && apt list --upgradable`, applies with `apt-get dist-upgrade` (NOT plain `upgrade` — new kernels arrive as new versioned packages that `upgrade` holds back)
- **RHEL/CentOS/Rocky/Alma** (dnf-based): Uses `dnf update --assumeno`
- **CentOS 6/7, RHEL 6/7** (yum-based): Checks with `echo n | yum update` — NOT `--assumeno`, which needs yum 3.4.3 (RHEL 7) and dies with "no such option" on RHEL 6's yum 3.2.29. Piping "n" produces the same transaction preview on every yum version
- **Fedora** (dnf-based): Uses `dnf update --assumeno`

Package manager is auto-detected on each server during Phase 1. yum output
parsing is generation-aware: yum says `Updating:` where dnf says `Upgrading:`,
and RHEL 6's Transaction Summary says `Update N Package(s)` where newer tools
say `Upgrade` — both the Phase 2 display sed range and
`parse_dnf_package_count()` accept all variants.

## Key Architecture

### Global State Variables

```bash
declare -a SERVERS                    # Array of server addresses
declare -A SERVER_NICKNAMES          # server -> nickname mapping
declare -A SERVER_PORTS              # server -> SSH port mapping
declare -A PKG_MANAGER_CACHE         # server -> pkg manager (lazy cache over ${server}.pkg_manager file)
declare -A DISPLAY_NAME_CACHE        # server -> "server (nickname)" display string
```

Per-server OS release, kernel, and package manager live in **temp files**, not
associative arrays — background jobs cannot modify parent-process variables
(see State Management). Duplicate server addresses are rejected at parse time
(the keyed arrays would silently merge them and the host would be updated
twice in parallel).

Local aliases: `is_localhost()` treats `localhost`, `127.0.0.1`, and `::1` as
this machine. Every phase-skip check uses it — a `127.0.0.1` entry previously
slipped past the literal `"localhost"` comparisons and could reboot the
control host in Phase 3.

### Instance Locking

To prevent multiple instances from running simultaneously (which could cause package manager conflicts and corrupted state), the script implements **PID-based instance locking**:

**Lock File:** `/tmp/server_update.lock`

**Startup Checks (`acquire_lock()`):**
- **Atomic acquisition**: `(set -o noclobber; echo "$$" > "$LOCK_FILE")` — the
  redirection uses `O_CREAT|O_EXCL`, so two racing instances can't both win
  (the old check-then-create had a window) and a pre-planted symlink at the
  lock path is not followed
- If acquisition fails:
  - Reads PID from the existing lock file
  - Uses `kill -0 $PID` to check if process is still running
  - **Active instance**: Exits with error message showing PID
  - **Stale lock**: Removes it and retries the atomic acquire once
- Fails with a permissions hint if the lock still can't be created

**Lock Cleanup (`cleanup()`, ~line 483):**
- `cleanup()` function removes lock file on exit
- Triggered by trap on EXIT, INT, TERM signals
- Ensures clean removal even if script is interrupted
- Also restores the terminal cursor (`\033[?25h`) and resets the SGR
  attributes (`\033[0m`) if a live dashboard or the review screen was
  drawing, and closes the review screen's keyboard descriptor

**Error Handling:**
- Clear error messages when another instance is detected
- Instructions for manual lock removal if needed
- Permission errors reported if lock file creation fails

### Execution Flow

The script operates in distinct phases:

#### **Startup (lines ~1550-1568)**
- Displays list of all servers to be checked
- Shows total server count
- Waits for user to press Enter to begin
- **Exception**: In automated modes (`--non-interactive`, `--check-only`, `--assume-yes`, `--dry-run`), skips the Enter prompt

#### **Phase 1: Discovery & System Detection (lines ~1570-1608)**
- Connects to all servers **in parallel** using background jobs
- Each server runs in its own background process
- For each server:
  - Discovers the server in **one SSH round-trip** via `probe_server_info()`,
    which also serves as the connection test (its output always contains a
    `PM=` sentinel; absence means the connection/remote shell failed). In a
    single remote snippet it returns:
    - Package manager (apt → dnf → yum order, same as `detect_package_manager()`)
    - OS release via fallback chain: `/etc/os-release` PRETTY_NAME →
      `lsb_release -d` → `/etc/redhat-release` (so pre-systemd hosts like
      CentOS/RHEL 6 still populate the OS column instead of showing `--`)
    - Kernel version from `uname -r`
  - This replaced the old per-attribute sequence (separate connection test +
    `detect_package_manager` + 2-4 `gather_system_info` calls), cutting Phase 1
    discovery from ~5 round-trips per server (up to 7 on pre-systemd hosts) to 2
    (the probe + the update check)
  - Runs appropriate update check command based on package manager
  - Counts available updates
- Dashboard updates in real-time (configurable refresh rate)
- Connection failures are displayed but don't stop execution

#### **Phase 2: Review & Approval**

Phase 2 has **two front ends over one set of rules**. `collect_review_candidates()`
builds the candidate list, `render_package_lines()` prints the packages, and
`apply_review_decision()` records the answer. Both front ends call all three, so
the rules cannot drift apart.

**Candidate gates** (`collect_review_candidates()`, in this order):
1. Skip local aliases (`is_localhost()`) — Phase 4 handles them
2. Skip servers with no `${server}.output` file
3. Skip servers whose status contains `ERROR` or `No updates`
4. Skip servers whose output matches neither format: dnf/yum "Transaction
   Summary" or apt "Listing..." (the gate previously only knew the dnf format
   and silently dropped every apt server from review)

Each survivor fills one index of the parallel arrays `RV_SERVER`, `RV_NAME`,
`RV_OSREL`, `RV_KVER`, `RV_PM`, `RV_COUNT`, `RV_KUPD`, `RV_DECISION`.

**Front end 1: the review screen** (`run_review_screen()` + `draw_review()`)

Used when `review_screen_supported()` returns true: stdout is a tty,
`--classic-review` is off, no automated mode is active, `/dev/tty` is readable,
and the window is at least 60x14. Otherwise the classic front end runs.

Layout: a server list where each row carries its own DECISION column, and a
package pane for the highlighted server.

```
REVIEW PENDING UPDATES  3 of 5 servers have updates  1 approved, 0 skipped, 2 undecided

  SERVER                  OS DISTRIBUTION              KERNEL VERSION       UPD   DECISION
------------------------------------------------------------------------------------------
> 192.0.2.10 (web-prod)   Rocky Linux 9.3 (Blue Onyx)  5.14.0-362.24.1.el9   26 ⚠ [  YES  ]
  192.0.2.20 (db-prod)    Ubuntu 22.04.3 LTS           5.15.0-91-generic      4 ⚠ [   ?   ]
  192.0.2.30 (mail)       AlmaLinux 8.9                4.18.0-513.9.1.el8     3   [   ?   ]
------------------------------------------------------------------------------------------
 PACKAGES - 192.0.2.10 (web-prod)                            ⚠ KERNEL UPDATE - WILL REBOOT
  Installing:
   kernel           x86_64   5.14.0-362.24.1.el9_3   baseos   3.1 M     <- RED BOLD
   ...
  lines 1-9 of 36  (more below)
------------------------------------------------------------------------------------------
 up/dn server  PgUp/PgDn packages  y approve  n skip  a all  ENTER apply  q cancel
```

Keys:

| Key | Action |
|-----|--------|
| Up / Down, k / j | Move the selection. The package pane follows and resets to line 1. |
| PgUp / PgDn, Left / Right | Scroll the package pane. |
| Home / End | Jump the package pane to the first or last line. |
| y | Set the row to YES and move down. |
| n | Set the row to SKIP and move down. |
| Space | Toggle the row between YES and SKIP. |
| a | Set every row to YES. |
| ENTER | Commit. Every YES row goes to Phase 3, everything else is skipped. |
| q, Esc | Cancel. Nothing is approved. |

Implementation notes:
- **Repaints in place**, the same technique as `draw_dashboard()`: cursor-home
  (`\033[H`), `\033[K` per row, `\033[0J` at the end. No full clear per frame,
  so no flicker. The cursor is hidden during the loop
- **Keyboard comes from `/dev/tty` on file descriptor 3**, not stdin, so a
  redirected stdin cannot answer the review. `cleanup()` closes the descriptor
- **`read_key()` polls with a one second timeout** and reports `KEY=TIMEOUT`.
  This is how a resize is noticed: **bash defers a trapped signal until the
  running builtin returns**, so a `SIGWINCH` trap does NOT interrupt a blocking
  `read`, and the screen would keep the old width until the next keypress. On
  timeout the loop re-reads the terminal size and repaints **only if it
  changed**, so an idle screen emits zero bytes
- **Columns are measured from the data**, then sized by the dashboard's own
  `compute_dashboard_layout()`. UPD, the kernel flag, and DECISION are fixed
  width. The kernel flag column is `${#GLYPH_WARN}` wide, so the ASCII fallback
  (`[!]`) fits as well as `⚠`
- **The selected row is drawn in reverse video** (`REVERSE='\033[7m'`, empty
  under `NO_COLOR`), padded to the table width
- **Package lines load lazily** through `load_pkg_lines()`, which renders each
  server once into `$TEMP_DIR/${server}.review` and reads it with `mapfile`.
  Only one package list is in memory at a time
- **Decisions are logged** to `$LOG_FILE` and echoed as a plain table by
  `print_review_summary()` after the screen closes

**Front end 2: the classic loop** (fallback, and `--classic-review`)

One server at a time, prompt under the package list. Unchanged except that it
now iterates the `RV_*` arrays and records decisions through
`apply_review_decision()`:
  - Displays server header with nickname
  - Shows the package list (dnf/yum uses one sed range over all section
    headers, including `Upgrading:`, `Updating:`, and `Installing:` — so yum hosts show
    their packages and nothing is printed twice)
  - Highlights kernel packages in **RED BOLD** using `has_kernel_package()`
    - For apt: `linux-image`, `linux-headers`, `linux-modules`
    - For dnf/yum: Uses the `KERNEL_PACKAGE_REGEX` configuration value
  - Displays warning if kernel update detected
  - Prompts `[y/N/a=yes to all/q=quit review]`:
    - `y`: approve this server
    - `a`: approve this server and every remaining one without prompting
    - `q`: skip this server and stop the review (remaining servers skipped)
    - anything else: skip this server
  - Prompting is bypassed entirely in:
    - `--dry-run`: Skip all updates
    - `--check-only`: Display only, don't prompt
    - `--assume-yes`: Auto-approve all
    - `--non-interactive`: Skip every server. Without `--assume-yes` nobody can
      approve, and the flag promises no prompts. Phase 2 previously ignored the
      flag and blocked on the prompt

Approved servers are written to `$TEMP_DIR/approved_servers.txt` by
`apply_review_decision()`, the only writer of that file in Phase 2.

#### **Phase 3: Parallel Execution (lines ~1762-1800)**
- Reads approved servers list
- Launches `apply_updates()` for each server in background
- Live dashboard shows real-time progress
- Update command runs with `APPLY_TIMEOUT` (default 3600s), not the check
  phase's `DNF_TIMEOUT` — on timeout the status warns the remote package
  manager may still be running (the local kill can't stop it)
- For servers with kernel updates:
  - Runs appropriate update command (apt-get dist-upgrade / dnf update / yum update)
  - Detects if kernel was updated (distribution-aware; see Kernel Update Detection)
  - Captures `/proc/sys/kernel/random/boot_id` before rebooting
  - Initiates reboot with `sudo reboot`
  - Calls `verify_reboot()` with the pre-reboot boot_id (see Reboot Monitoring)
- Updates complete simultaneously across all servers

#### **Phase 3.5: Results Summary (lines ~1803-1884)**
- After all background jobs complete
- Displays comprehensive results table
- For each approved server:
  - Reads `${server}.update_type` (kernel_update or no_reboot)
  - Reads `${server}.reboot_status` (success or failed)
  - Displays colored result indicator (`GLYPH_OK`/`GLYPH_FAIL`)
- Shows summary statistics:
  - Servers updated (no reboot)
  - Servers updated and rebooted
  - Servers with issues

#### **Phase 4: Local Server Update (lines ~1886-2120)**
**ONLY executes AFTER all remote servers complete**

This phase is specifically designed to safely update the local server (localhost) without interrupting remote server monitoring:

- Finds the local entry in `SERVERS` via `is_localhost()` (localhost,
  127.0.0.1, or ::1 — state files are keyed by whatever name was used) and
  checks its Phase 1 status/output for pending updates. Note: localhost is
  never written to `approved_servers.txt`; Phase 2 skips it entirely
- **Skipped entirely in `--dry-run` and `--check-only` modes** (prints an
  informational note instead — these modes previously fell through and could
  update and even reboot the local machine)
- Displays pending updates for localhost
- Shows package list (distribution-aware formatting, same yum/dnf section
  handling as Phase 2)
- Detects and warns about kernel updates:
  - Local server will reboot
  - You will lose your session
- **First user confirmation**: "Proceed with local server update? [y/N]"
  - `--assume-yes` alone auto-approves (consistent with Phase 2)
  - `--non-interactive` without `--assume-yes`: skips
- If approved:
  - Runs appropriate update command (apt dist-upgrade / dnf / yum) with `APPLY_TIMEOUT`
  - Detects if kernel was updated
  - If kernel updated:
    - **Second user confirmation**: "Reboot local server now? [y/N]"
      - Same mode rules as the first confirmation
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
| `${server}.pkg_manager` | Detected package manager (`apt`/`dnf`/`yum`) |
| `${server}.update_type` | Either `kernel_update` or `no_reboot` |
| `${server}.reboot_status` | Either `success` or `failed` |
| `${server}.ssh_err` | Captured ssh stderr from the Phase 1 probe, fed to `classify_ssh_error()` on connection failure |
| `${server}.review` | Package list rendered as plain text for the review screen's package pane (written once, on first selection) |
| `approved_servers.txt` | List of servers approved for updates in Phase 2 |

**Note:** OS and kernel info are written to temp files (not associative arrays) because background processes cannot modify parent process variables.

### Dashboard Rendering

The `draw_dashboard()` function renders the live status display in a **compact table format**:

**Rendering (flicker-free):**
- Repaints **in place**: cursor-home (`\033[H`) plus erase-to-end-of-line
  (`\033[K`) per row and `\033[0J` at the end — no full-screen clear per frame
- Cursor is hidden (`\033[?25l`) during the live loop and restored after it
  and in `cleanup()` (so Ctrl-C can't leave the terminal cursorless)
- **Non-tty mode** (cron, pipes): the live refresh loop is skipped entirely;
  the script just `wait`s and prints one final plain table with no escape
  codes. Colors are also disabled when stdout isn't a tty or `NO_COLOR` is set

**Width detection** (`get_term_width()`, result in `TERM_WIDTH`):
- Order: `DASHBOARD_WIDTH` override → `stty size </dev/tty` → `stty size <&2`
  → `tput cols` → `COLUMNS` → 80
- `stty` comes first because it asks the kernel (TIOCGWINSZ) and does not read
  terminfo. `tput cols` returns the terminfo default (80) for an unknown
  `TERM`, for a `TERM` entry with a fixed width, and on old ncurses builds
  when stdout is a pipe — which is what a command substitution gives it. That
  is the "stuck at 80 columns in a 200-column window" report
- `/dev/tty` is the controlling terminal, so detection also survives a
  redirected stdin or stderr. Without a controlling terminal (cron) every
  source fails and the fallback 80 applies
- `DASHBOARD_WIDTH` (configuration file or environment, 40–1000) forces a
  width when the terminal cannot report one

**Data-driven layout** (`compute_dashboard_layout()`):
- `draw_dashboard()` reads every row first, measures the longest value per
  column, then sizes the columns. There are no fixed width tiers
- If the row fits, no value is cut and the spare room goes to STATUS
- If the row does not fit, SERVER is capped at `MAX_COL_SRV` (44) and STATUS
  at `MAX_COL_STS` (60), then the overflow is taken one character at a time
  from whichever of OS/KERNEL/STATUS is the widest. STATUS counts as
  `STS_BONUS` (8) narrower than it is, so it stays the widest of the three
- SERVER shrinks last, and only after OS/KERNEL/STATUS reach `MIN_COL_*`
  (16/8/8/16). The `address (nickname)` label is what identifies the row, so
  it keeps its full width as long as the terminal allows
- Narrow columns get short headers (`OS`, `KERNEL`) instead of truncated ones
- STATUS is the last column, so it is printed unpadded
- Long values truncated with "..." via `truncate_field()` (global-return,
  fork-free, same pattern as `safe_read_file`)

**Layout:** One line per server, columns `SERVER | OS DISTRIBUTION | KERNEL VERSION | STATUS`
- For each server:
  - Reads status from `${server}.status` file
  - Reads OS info from `${server}.os_release` file
  - Reads kernel from `${server}.kernel` file
  - Applies color coding based on status keywords

**Summary footer:** one line under the table —
`Active: N | Updates: N | Done: N | Errors: N | Elapsed: MM:SS`
(elapsed is per phase; `DASH_START` is reset before each dashboard loop).

**Example Output:**
```
SERVER                         OS DISTRIBUTION                  KERNEL VERSION               STATUS
------------------------------------------------------------------------------------------------------------
192.0.2.10 (web-prod)          Rocky Linux 9.3 (Blue Onyx)      5.14.0-362.24.1.el9_3.x86_64 5 updates available
192.0.2.20 (db-prod)           Ubuntu 22.04.3 LTS               5.15.0-91-generic            Applying updates (apt)...
------------------------------------------------------------------------------------------------------------
Active: 1 | Updates: 1 | Done: 0 | Errors: 0 | Elapsed: 00:12
```

**Color Coding:**
- **Cyan**: Checking/connecting
- **Green**: Connected, no updates, successfully rebooted, or complete
- **Yellow**: Updates available, rebooting, or skipped
- **Red**: Errors
- **Magenta**: Applying updates

**Glyphs:** status symbols come from `GLYPH_OK`/`GLYPH_FAIL`/`GLYPH_WARN`/
`GLYPH_BULLET` globals — UTF-8 (`✓ ✗ ⚠ •`) only when `locale charmap` reports
UTF-8, ASCII fallbacks (`[OK] [X] [!] *`) otherwise. Old-distro consoles and
`LANG=C` sessions rendered the raw UTF-8 as mojibake. Never hardcode these
symbols in status strings; use the globals.

Refresh rate controlled by `$DASHBOARD_REFRESH` variable (default: 1 second).

### Package Manager Detection

Detection order is always: `apt-get` → `dnf` → `yum` → "unknown".

- **Phase 1 (all servers):** detection is folded into `probe_server_info()`, which
  determines the package manager, OS, and kernel in a single SSH round-trip.
- **`detect_package_manager()`** remains as a standalone helper used only by the
  Phase 4 localhost fallback (when the cached value is missing). It runs the same
  apt/dnf/yum probe in one shell invocation and works on both remote servers
  (via SSH) and localhost.

### Kernel Update Detection

Distribution-aware detection via `has_kernel_package()`:

**For apt (Debian/Ubuntu):**
- Checks for: `linux-image`, `linux-headers`, `linux-modules`

**For dnf/yum (RHEL/CentOS/Fedora):**
- Uses configurable `KERNEL_PACKAGE_REGEX` (default: `^kernel(-core|-modules)?\b`)
- Uses `KERNEL_UPDATE_REGEX` for actual update output
- **Both scan paths strip leading indentation** before matching — dnf/yum
  transaction tables indent package rows by one space, which defeats the
  `^kernel` anchor. The multi-line path always did this. The single-line path
  used to depend on its callers: the old Phase 2 loop read lines with `read`
  (no `IFS=`), which strips leading whitespace as a side effect. The review
  screen keeps the indentation so the dnf table stays aligned, so the stripping
  now happens inside `has_kernel_package()` and both paths answer the same

Detection happens in two places:
1. **Phase 2**: Check package list before approval (warns the user)
2. **Phase 3/4**: Check actual update output to trigger reboot. For apt this
   matches only packages actually installed — `^(Setting up|Unpacking)
   linux-(image|headers|modules)` — NOT any mention of linux-image; the old
   unanchored grep also matched apt's "kept back" list and rebooted servers
   where no kernel was installed. `/var/run/reboot-required` (the distro's own
   signal) is checked as a supplement.

### Reboot Monitoring

`verify_reboot(server, old_boot_id)` — **boot_id comparison is the primary
strategy**: `apply_updates()` captures `/proc/sys/kernel/random/boot_id`
before issuing the reboot, and `verify_reboot()` polls until the value read
over SSH **changes**. A changed boot_id *proves* a reboot happened — even one
too fast to observe as "down" (small VMs can cycle inside a 5s polling window,
which the old down/up watcher misread as "did not go down"). boot_id exists on
any Linux with procfs (RHEL 5+), so old targets are fine.

**boot_id mode:**
- Polls every `REBOOT_WAIT_INTERVAL` seconds (default: 30s), up to
  `REBOOT_MAX_WAIT` seconds (default: 900s = 15 minutes)
- Reachable + new boot_id → `success`
- Reachable + same boot_id → "not down yet", keep waiting; if the host was
  *never* unreachable and the boot_id is still unchanged after ~120s, fail
  fast with "did not go down" (the reboot command never took effect)
- Unreachable → keep waiting (rebooting)

**Fallback mode** (boot_id could not be captured): the legacy two-phase watch —
wait for the server to go down (5s polls, 100s max), then poll `uptime` until
it responds.

All SSH probes are wrapped in `timeout` (15–20s) — `ConnectTimeout` only
covers the TCP connect, and a half-up server that accepts and hangs would
stall the monitor forever.

Writes `success`/`failed` to `${server}.reboot_status`. Returns:
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
--classic-review   # Review servers one at a time instead of the review screen
--help, -h         # Display usage information
--version          # Display version
```

Environment: setting `NO_COLOR` (any value) disables all ANSI colors, per the
no-color.org convention. Colors are also auto-disabled when stdout is not a
tty (cron, pipes), and the live dashboard loop is skipped entirely in that
case — the final table prints once, plain.

### Configuration File (server_update.conf)

Optional file with whitelisted variables:

```bash
DNF_TIMEOUT=600                    # Update *check* command timeout (seconds)
APPLY_TIMEOUT=3600                 # Update *apply* timeout, Phase 3/4 (seconds)
DASHBOARD_REFRESH=1                # Dashboard update interval (seconds)
DASHBOARD_WIDTH=160                # Force dashboard width, 40-1000 (default: auto)
REBOOT_MAX_WAIT=900                # Maximum reboot wait time (seconds)
REBOOT_WAIT_INTERVAL=30            # Seconds between reboot checks
KERNEL_PACKAGE_REGEX="..."         # Kernel detection (dnf/yum only)
KERNEL_UPDATE_REGEX="..."          # Kernel update detection (dnf/yum only)
```

`APPLY_TIMEOUT` is deliberately separate from `DNF_TIMEOUT`: big updates on
slow hardware routinely exceed 10 minutes, and killing a package transaction
mid-flight risks rpmdb/dpkg corruption.

**Security:** Config file is parsed safely using `load_config()` (lines ~77-166). Only whitelisted variables are accepted, values are validated, and assignment uses `printf -v` (no `eval`, no `source`).

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

Validation performed during parsing (loop at ~line 562):
- Server names checked for dangerous characters
- Ports validated (1-65535)
- Duplicate server addresses rejected (would silently merge in the keyed arrays)
- A final line without a trailing newline is still parsed (`read ... || [[ ${#parts[@]} -gt 0 ]]`)
- Invalid entries skipped with warnings

## Security Features

### Input Validation (lines ~213-303)
- `validate_server_name()`: Prevents command injection in server names
- `validate_port()`: Ensures port is 1-65535
- `validate_ip()`: Validates IPv4 and basic IPv6
- `is_localhost()`: Canonical local-alias check (localhost/127.0.0.1/::1)

### Safe Configuration Loading (`load_config()`, lines ~77-166)
- Whitelisted variables only (`DNF_TIMEOUT`, `APPLY_TIMEOUT`, `DASHBOARD_REFRESH`,
  `DASHBOARD_WIDTH`,
  `REBOOT_MAX_WAIT`, `REBOOT_WAIT_INTERVAL`, `KERNEL_PACKAGE_REGEX`,
  `KERNEL_UPDATE_REGEX`)
- Numeric values validated: digits only, minimum 1 (0 would busy-loop the
  dashboard / defeat timeouts), maximum 604800 seconds (1 week)
- **No code execution path**: values are assigned with `printf -v "$key"`,
  never `eval` or `source` — a value like `$(reboot)` is stored as a literal
  string
- **Regex validation without injection**: candidate patterns are passed to
  `grep -E -- "$value"` as an *argument* (never interpolated into a shell
  string) with a 1-second `timeout` for ReDoS protection; the exit status is
  captured directly (`regex_exit=$?` — the old negated capture made the check
  a no-op, so broken patterns like `kernel[(` were accepted)
- Syntactically invalid or dangerous values are rejected with a warning; the
  built-in default is kept
- Handles a final line without a trailing newline

### File Permissions
- Temp directory: 700 (owner-only)
- Log file: 600 (owner read/write only)
- Warnings for world-writable config/server list files

### Proper Quoting
- All variable expansions in SSH commands are quoted
- Prevents word splitting attacks

### Instance Locking (`acquire_lock()`, lines ~168-211)
- **PID-based locking** prevents multiple simultaneous executions
- Acquisition is atomic (`noclobber` redirection = `O_CREAT|O_EXCL`)
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
- Reads use the `read` builtin into a global (`SRF_RESULT`), no lock needed —
  this removes the per-read `flock` fork the old implementation paid on every
  dashboard refresh, and also avoids both the `cat` exec and the
  command-substitution subshell a `var=$(...)` reader would fork (~40x cheaper
  per read; the full dashboard render measures ~6.8x faster)
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

- `safe_read_file(file_path, default_value)`: fork-free single-line read
  - **Returns its result in the global `SRF_RESULT`, not on stdout.** Callers do
    `safe_read_file "$f" "$default"; var="$SRF_RESULT"` (never `var=$(...)`).
    The global is what lets hot callers skip the command-substitution subshell.
  - Uses the `read` builtin (no `cat` exec). State files are single-line and
    `safe_write_file` always appends a trailing newline, so `read` captures the
    whole value and returns 0
  - Atomic-rename writes guarantee a reader never observes a partial file, so a
    missing file is the only failure mode → falls back to the default value
    (stderr is redirected before the input redirection to swallow the
    "No such file" message)
  - A plain global is used instead of a `declare -n` nameref so this still runs
    on bash 4.0–4.2 controllers (CentOS/RHEL 6/7) — see Implementation Details
  - **Usage:** All temp file reads use this function

**Implementation Details:**
- Atomicity relies on `rename(2)` being atomic on a single filesystem; staging
  file and target both live inside `$TEMP_DIR`, so the move is a rename
- Staging files: `${original_file}.$BASHPID.tmp` (removed by the `mv`)
- Requires bash 4.0+ for `$BASHPID` — already mandated by the script's use of
  associative arrays (`declare -A`). The reader deliberately avoids `declare -n`
  (bash 4.3+) so it keeps working on the bash 4.0–4.2 controllers (CentOS/RHEL
  6/7) that v1.4 restored support for; it returns via a global instead.
- Cheaper than the previous flock approach: no lock file, no fork per read. The
  reader goes further — `read` builtin + global return means no `cat` exec and
  no command-substitution subshell on the dashboard hot path

**Files Protected:**
- `${server}.status` - Server status messages
- `${server}.os_release` - OS distribution info
- `${server}.kernel` - Kernel version
- `${server}.pkg_manager` - Package manager type
- `${server}.update_type` - Update type (kernel_update/no_reboot)
- `${server}.reboot_status` - Reboot result (success/failed)

### Core Functions

- `is_localhost(server)` (~line 287): True for localhost/127.0.0.1/::1
- `read_key()`: Reads one keystroke from fd 3 into the global `KEY`. Decodes arrow/Home/End/PgUp/PgDn escape sequences. Polls with a one second timeout and reports `KEY=TIMEOUT`
- `get_display_name(server)` (~line 388): Formats "server (nickname)" (cached)
- `filter_apt_header()` (~line 399): Strips apt's "Listing..." header line (unanchored — matches "Listing..." and "Listing... Done")
- `detect_package_manager(server)` (~line 643): Standalone apt/dnf/yum probe (Phase 4 localhost fallback only)
- `probe_server_info(server)` (~line 676): One-round-trip Phase 1 discovery (pkg manager + OS + kernel), doubles as connection test
- `classify_ssh_error(stderr_file)` (~line 760): Maps ssh stderr to a human-readable reason (auth failed, DNS lookup failed, connection refused, host key changed, ...) via `SSH_ERROR_REASON`
- `detect_ssh_capabilities()` (~line 788): Version-gates SSH options from local `ssh -V`
- `get_ssh_cmd(server)` (~line 821): Returns SSH command string with port
- `execute_remote_command(server, cmd, timeout)` (~line 858): Executes command locally or via SSH
- `check_disk_space(server)` (~line 889): Pre-flight free-space check (/ and /boot)
- `has_kernel_package(text, pkg_manager)` (~line 939): Checks for kernel packages
- `parse_dnf_package_count(output)` (~line 983): Sums Install/Upgrade/Update counts from the dnf/yum Transaction Summary

### Main Functions

- `get_term_width()` / `get_term_height()` / `compute_dashboard_layout()` / `truncate_field()`: Size detection (results in `TERM_WIDTH` / `TERM_HEIGHT`) and data-driven column layout. Only the review screen needs the height
- `draw_dashboard()` (~line 1039): Renders live status display
- `update_status(server, status)` (~line 1131): Writes status to temp file using `safe_write_file()`
- `collect_review_candidates()`: Phase 2 - fills the `RV_*` arrays with every server that has updates to review
- `render_package_lines(server, pkg_manager)`: Phase 2 - prints one server's package list as plain text (both front ends use it)
- `apply_review_decision(server, decision)`: Phase 2 - the only writer of `approved_servers.txt`; logs the decision
- `review_screen_supported()`: True when the terminal can carry the review screen
- `draw_review()` / `run_review_screen()` / `load_pkg_lines()` / `print_review_summary()`: The review screen
- `check_server_updates(server)` (~line 1142): Phase 1 - check for updates
- `verify_reboot(server, old_boot_id)` (~line 1283): Monitors reboot process (boot_id primary, down/up fallback)
- `apply_updates(server)` (~line 1406): Phase 3 - apply updates and handle reboots

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

### Forcing the Dashboard Width
Set `DASHBOARD_WIDTH` (40–1000) in `server_update.conf`, or pass it in the
environment: `DASHBOARD_WIDTH=180 ./server_update.bash`. Use it when the
terminal reports the wrong width. Default is auto-detection.

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

For apt systems, modify `has_kernel_package()` function directly (~line 939).

### Custom Package Highlighting
Modify the Phase 2 display sections (lines ~1660-1720) to highlight additional critical packages.

## Logging

All operations logged to `server_update.log` with:
- Timestamps using `$(date)`
- Connection failures
- Update successes/failures
- Reboot monitoring results
- Error messages

Log file created with 600 permissions. Warns if log exceeds 10MB.

## Version History

### Unreleased (post-1.4)

**Interactive review screen (2026-08):**
- **Phase 2 is now a split screen** on any terminal that can carry it: a server
  list where each row carries its own DECISION column, plus a scrolling package
  pane for the highlighted server. Arrow keys move between servers,
  `y`/`n`/Space set a decision, `a` approves everything, ENTER commits, `q`
  cancels. The old behavior — one server at a time, a prompt after each package
  list, and no way back — remains as the fallback
- **One set of rules, two front ends**: `collect_review_candidates()`,
  `render_package_lines()`, and `apply_review_decision()` are shared, so the
  screen and the classic loop cannot drift apart. `apply_review_decision()` is
  the only writer of `approved_servers.txt` and logs every decision
- **Automatic fallback**: the screen opens only on a tty, with a readable
  `/dev/tty`, in a window of at least 60x14, and outside every automated mode.
  `--classic-review` forces the old path
- **Resize works without a signal trap**: `read_key()` polls with a one second
  timeout, because bash defers a trapped signal until the running builtin
  returns — a `SIGWINCH` trap does NOT interrupt a blocking `read`. An idle
  screen still emits zero bytes: it repaints only when the size changed
- **`get_term_height()`** added, mirroring `get_term_width()`'s source order
  (`stty` before `tput`, for the same terminfo reason)
- **`has_kernel_package()` strips leading indentation on single-line input**
  too. It used to rely on the caller's `read` doing it, which broke the red
  kernel highlight as soon as a caller preserved the dnf table's indentation
- **`--non-interactive` no longer blocks in Phase 2**: the flag promises no
  prompts, but the review loop still stopped at `read -r response` on a
  terminal. Without `--assume-yes` it now skips every server, which is how
  Phase 4 already treated it
- **`cleanup()` resets the SGR attributes** (`\033[0m`) as well as restoring
  the cursor, so Ctrl-C on a reverse-video row cannot leave the terminal
  inverted, and closes the review keyboard descriptor

**Dashboard width and column fixes (2026-08 review):**
- **Width detection no longer trusts `tput` alone**: `get_term_width()` now
  tries `stty size` on `/dev/tty` first, then `stty size` on stderr, then
  `tput cols`, then `COLUMNS`, then 80. `tput cols` reads terminfo and answers
  80 for an unknown `TERM`, for entries with a fixed width, and on old ncurses
  builds when stdout is a pipe (every command substitution), which pinned the
  dashboard to 80 columns in much wider windows
- **`DASHBOARD_WIDTH` override**: config file or environment variable, 40–1000,
  for terminals that cannot report a width at all
- **Columns are measured from the data**: the fixed 30/32/28 width tiers are
  gone. `draw_dashboard()` reads all rows first, then sizes each column to its
  longest value. The full `address (nickname)` label now stays visible instead
  of being cut at 30 characters, and spare room goes to STATUS
- **Balanced shrinking when the row does not fit**: overflow comes off
  OS/KERNEL/STATUS one character at a time, widest first, and SERVER shrinks
  last. Narrow columns get short headers (`OS`, `KERNEL`)

**Correctness fixes (2026-07 review):**
- **apt servers restored to Phase 2**: the review gate only recognized the
  dnf/yum "Transaction Summary" format, so every apt server was silently
  dropped from review and could never be approved. Gate now accepts apt's
  "Listing..." format too
- **Phase 4 honors `--dry-run`/`--check-only`**: previously fell through and
  could apply updates and even reboot the local machine in "safe" modes; now
  skipped entirely with an informational note
- **Local-alias safety**: `is_localhost()` (localhost/127.0.0.1/::1) used by
  every phase-skip check — a `127.0.0.1` entry previously slipped past the
  literal `"localhost"` comparisons and could reboot the control host in
  Phase 3
- **apt applies with `dist-upgrade`** (was plain `upgrade`, which holds back
  kernels arriving as new versioned packages), under
  `DEBIAN_FRONTEND=noninteractive` with `--force-confdef/--force-confold` so
  conffile prompts can't hang an unattended run
- **apt kernel-reboot detection anchored**: only `^(Setting up|Unpacking)
  linux-(image|headers|modules)` counts (plus `/var/run/reboot-required`) —
  the old unanchored grep also matched apt's "kept back" list and rebooted
  servers where no kernel was installed
- **boot_id-verified reboots**: `apply_updates()` captures
  `/proc/sys/kernel/random/boot_id` before rebooting; `verify_reboot()` polls
  for a *changed* id (proves the reboot even when a fast VM cycles inside one
  polling window), fails fast (~120s) when the reboot command never took
  effect, and falls back to the legacy down/up watch when boot_id wasn't
  captured. All SSH probes wrapped in `timeout` so a half-up server can't
  stall the monitor
- **`APPLY_TIMEOUT` (default 3600s)**: the apply phase no longer reuses the
  600s check timeout — killing a package transaction mid-flight risks
  rpmdb/dpkg corruption; on timeout the status warns the remote package
  manager may still be running
- **`parse_dnf_package_count()` rewritten** as an awk sum over
  `Install`/`Upgrade`/`Update` Transaction Summary lines (RHEL 6 yum included)
- **`load_config()` hardening**: `printf -v` assignment (no `eval`), zero
  values rejected, `APPLY_TIMEOUT` whitelisted, and a latent bug fixed where
  the regex-validation exit status was captured negated — the check was a
  no-op and accepted broken patterns like `kernel[(`
- **Atomic lock acquisition**: `acquire_lock()` uses `noclobber`
  (`O_CREAT|O_EXCL`) instead of check-then-create; stale locks removed and
  retried once
- **Parse robustness**: duplicate server addresses rejected; config and
  server-list files parse a final line without a trailing newline

**Older-distro compatibility (2026-07 review):**
- **yum check via `echo n | yum update`** — `--assumeno` needs yum 3.4.3 and
  dies on RHEL 6's yum 3.2.29
- **Generation-aware yum parsing**: `Updating:` vs `Upgrading:` section
  headers and `Update N Package(s)` vs `Upgrade` summary lines all accepted
  (Phase 2 display + package counting)
- **Glyph fallback**: `GLYPH_OK/FAIL/WARN/BULLET` globals — UTF-8 `✓ ✗ ⚠ •`
  only when `locale charmap` is UTF-8, ASCII `[OK] [X] [!] *` otherwise
  (LANG=C consoles rendered mojibake)
- **80-column dashboards**: width-aware tiered layout replaces the fixed
  133-wide table that wrapped every row on serial consoles and default PuTTY

**UI improvements (2026-07 review):**
- **Flicker-free dashboard**: in-place repaint (cursor-home + `\033[K` per
  row + `\033[0J`), cursor hidden during live loops and restored in
  `cleanup()`; summary footer (`Active/Updates/Done/Errors/Elapsed`)
- **Non-tty mode**: live loop skipped under cron/pipes; one plain final table,
  no escape codes; `NO_COLOR` honored
- **SSH error classification**: probe stderr captured and mapped to a
  human-readable reason (auth failed, DNS lookup failed, connection refused,
  host key changed, timed out, ...) instead of a bare "connection failed"
- **Phase 2 review controls**: `a` = approve all remaining, `q` = quit review
- **Phase 4 consistency**: `--assume-yes` alone auto-approves (previously
  also required `--non-interactive`)

**Earlier unreleased work:**
- **Single-round-trip discovery**: new `probe_server_info()` detects the package
  manager and gathers OS/kernel in one remote shell snippet, doubling as the
  connection test (a `PM=` sentinel in the output proves the remote shell ran).
  Replaces the old per-attribute sequence (connection test + `detect_package_manager`
  + 2-4 `gather_system_info` round-trips), cutting Phase 1 discovery from ~5
  round-trips per server (up to 7 on pre-systemd hosts) to 2. The dead
  `gather_system_info()` was removed; `detect_package_manager()` is kept for the
  Phase 4 localhost fallback. Remote snippet is POSIX-sh (works under dash) and
  parses `PRETTY_NAME` by prefix/suffix stripping, which also handles unquoted
  values. Verified on RHEL/Alma localhost, an apt-get stub (apt-first ordering),
  and faked Debian/Ubuntu/Fedora os-release formats; timeout→124 and
  connect-failure→1 paths exercised with stub ssh.
- **Fork-free dashboard reads**: `safe_read_file()` now uses the `read` builtin
  and returns via the global `SRF_RESULT` instead of `cat` + stdout. Hot callers
  (`draw_dashboard`) skip both the `cat` exec and the command-substitution
  subshell — ~40x cheaper per read; the full dashboard render measures ~6.8x
  faster (≈50ms → ≈7ms per refresh at 10 servers). All 9 call sites updated to
  `safe_read_file f default; var="$SRF_RESULT"`. A global (not a `declare -n`
  nameref) is used so it still runs on bash 4.0–4.2 (CentOS/RHEL 6/7).
- **Fork-free kernel-line check**: `has_kernel_package()` matches single-line
  input with the bash regex engine (`[[ =~ ]]` + `nocasematch`) instead of
  forking `grep` per package line in the Phase 2 review loops (~200x cheaper per
  line). Multi-line whole-output scans still use `grep` so `^/$` anchor per line.
  Behavior verified identical to the old grep against single/multi-line, case,
  `\b`-boundary, and leading-whitespace inputs.

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
   - Atomic-rename writes prevent corruption from concurrent access (no flock needed)

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
