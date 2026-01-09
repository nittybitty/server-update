#!/bin/bash
# Test script to verify instance locking works

echo "Test 1: Verify lock file is created and removed"
echo "=============================================="

# Start the script in background (it will wait for Enter, so it stays running)
echo "" | timeout 3s ./server_update.bash --dry-run 2>&1 | head -20 &
PID1=$!

# Give it a moment to create the lock file
sleep 1

# Check if lock file exists
if [[ -f /tmp/server_update.lock ]]; then
    echo "✓ Lock file created: /tmp/server_update.lock"
    echo "  Lock file contains PID: $(cat /tmp/server_update.lock)"
else
    echo "✗ Lock file NOT created"
fi

# Try to run a second instance while first is running
echo ""
echo "Test 2: Try to run second instance (should fail)"
echo "================================================"
./server_update.bash --help 2>&1 | head -5

# Wait for first instance to finish
wait $PID1

# Check if lock file was cleaned up
sleep 1
if [[ ! -f /tmp/server_update.lock ]]; then
    echo ""
    echo "✓ Lock file properly removed after exit"
else
    echo ""
    echo "✗ Lock file still exists after exit"
    echo "  Cleaning up manually..."
    rm -f /tmp/server_update.lock
fi

echo ""
echo "Test 3: Verify stale lock detection"
echo "===================================="
# Create a stale lock file with a PID that doesn't exist
echo "99999" > /tmp/server_update.lock

# This should detect stale lock and remove it
./server_update.bash --version 2>&1 | head -5

# Check if it was removed
if [[ ! -f /tmp/server_update.lock ]]; then
    echo "✓ Stale lock file was detected and removed"
else
    echo "✗ Stale lock file was not removed"
    rm -f /tmp/server_update.lock
fi

echo ""
echo "All tests complete!"
