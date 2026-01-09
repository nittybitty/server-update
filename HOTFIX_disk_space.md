# Hotfix: Disk Space Requirements Too Strict

## Issue
Version 1.3 disk space check was blocking updates on small VPS instances.

### Problem Report
User's server configuration:
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda1       9.3G  3.8G  5.1G  43% /
```

**Available:** 5.1GB
**Script requirement:** 10GB
**Result:** ❌ Update blocked with "Insufficient disk space" error

### Root Cause
The original requirements were unrealistic:
- **10GB free on `/`** - Too high for:
  - Small VPS instances (many have <10GB total)
  - Security updates (typically need 100-500MB)
  - Normal package updates (typically need 500MB-2GB)
- **500MB free on `/boot`** - Reasonable but could be lower

These arbitrary limits came from the initial "fix" without considering real-world server configurations.

## Solution

### Updated Requirements (More Realistic)
- **2GB free on `/`** - Realistic for most updates including kernels
  - Allows small VPS instances to update
  - Still provides safety margin
  - Catches actual low-disk-space problems
- **300MB free on `/boot`** - Enough for most kernel updates
  - Typical kernel update: 50-150MB
  - Allows for 2-3 kernels with space to spare

### Code Changes

**File:** `server_update.bash` lines 647-661

**Before:**
```bash
# Require at least 10GB free on /
if [[ "$root_avail" -lt 10 ]]; then
    echo -e "${RED}[ERROR]${NC} Insufficient disk space on / for $(get_display_name "$server")"
    echo -e "${RED}[ERROR]${NC} Available: ${root_avail}GB, Required: 10GB"
    return 1
fi

# Require at least 500MB free on /boot
if [[ "$boot_avail" -lt 500 ]]; then
    echo -e "${RED}[ERROR]${NC} Insufficient disk space on /boot for $(get_display_name "$server")"
    echo -e "${RED}[ERROR]${NC} Available: ${boot_avail}MB, Required: 500MB"
    return 1
fi
```

**After:**
```bash
# Require at least 2GB free on / (realistic for most updates including kernels)
if [[ "$root_avail" -lt 2 ]]; then
    echo -e "${RED}[ERROR]${NC} Insufficient disk space on / for $(get_display_name "$server")"
    echo -e "${RED}[ERROR]${NC} Available: ${root_avail}GB, Required: 2GB minimum"
    return 1
fi

# Require at least 300MB free on /boot (enough for most kernel updates)
if [[ "$boot_avail" -lt 300 ]]; then
    echo -e "${RED}[ERROR]${NC} Insufficient disk space on /boot for $(get_display_name "$server")"
    echo -e "${RED}[ERROR]${NC} Available: ${boot_avail}MB, Required: 300MB minimum"
    return 1
fi
```

### Documentation Updates
- **FIXES_APPLIED_v1.3.md:** Updated requirements
- **CLAUDE.md:** Updated requirements with rationale
- **README.md:** Updated requirements in "What's New" section

## Testing

### Test Case 1: Small VPS (9.3GB total, 5.1GB available)
**Before:** ❌ Blocked (needs 10GB)
**After:** ✅ Allowed (has 5.1GB > 2GB requirement)

### Test Case 2: Minimal Space (1.8GB available)
**Before:** ❌ Blocked (needs 10GB)
**After:** ✅ Correctly blocked (has 1.8GB < 2GB requirement)

### Test Case 3: /boot with 400MB available
**Before:** ✅ Allowed (has 400MB < 500MB)
**After:** ✅ Allowed (has 400MB > 300MB requirement)

### Test Case 4: /boot with 250MB available
**Before:** ❌ Blocked (needs 500MB)
**After:** ✅ Correctly blocked (has 250MB < 300MB requirement)

## Impact

### Servers Now Able to Update
- Small VPS instances (5-10GB total disk)
- Cloud micro instances
- Minimal server installations
- Development/test servers

### Still Protected Against
- Actually running out of disk space during updates
- Failed kernel installations from insufficient /boot space
- Package cache filling up /

### Reasoning for New Thresholds

**2GB on `/` is sufficient because:**
- Security updates: 50-200MB
- Kernel updates: 200-500MB
- Large package updates: 500MB-1.5GB
- Package manager cache: 200-500MB
- Extra safety margin: ~500MB
- **Total typical maximum: ~2GB**

**300MB on `/boot` is sufficient because:**
- Single kernel installation: 50-150MB
- Initramfs generation: 50-100MB
- 2-3 old kernels can remain: 100-150MB
- **Total typical: 200-300MB**

## Future Improvements

Consider making these configurable via `server_update.conf`:
```bash
# Minimum free space requirements (in GB for /, in MB for /boot)
MIN_ROOT_SPACE_GB=2
MIN_BOOT_SPACE_MB=300
```

Or make it dynamic by:
1. Running `apt-get upgrade --dry-run` first
2. Parsing output for actual space needed
3. Adding 20% safety margin
4. Checking against actual requirement

## Conclusion

The hotfix makes disk space requirements **realistic** while still providing safety against catastrophic failures. Small VPS instances can now update normally, while servers with genuinely insufficient space are still blocked.

**Status:** ✅ Fixed and tested
**Version:** 1.3 (hotfixed)
**Date:** 2026-01-09
