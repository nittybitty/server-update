#!/bin/bash
# Test script to verify flock-based file locking works

# Create temp directory for testing
TEST_DIR=$(mktemp -d)
echo "Test directory: $TEST_DIR"

# Source the safe file functions from the main script
# Extract just the function definitions
eval "$(sed -n '/^safe_write_file()/,/^}/p' server_update.bash)"
eval "$(sed -n '/^safe_read_file()/,/^}/p' server_update.bash)"

echo ""
echo "Test 1: Basic safe_write_file and safe_read_file"
echo "================================================="

# Write a file
if safe_write_file "$TEST_DIR/test1.txt" "Hello World"; then
    echo "✓ safe_write_file succeeded"
else
    echo "✗ safe_write_file failed"
fi

# Read it back
result=$(safe_read_file "$TEST_DIR/test1.txt" "default")
if [[ "$result" == "Hello World" ]]; then
    echo "✓ safe_read_file returned correct content: '$result'"
else
    echo "✗ safe_read_file returned wrong content: '$result'"
fi

echo ""
echo "Test 2: Read non-existent file with default value"
echo "=================================================="

result=$(safe_read_file "$TEST_DIR/nonexistent.txt" "default_value")
if [[ "$result" == "default_value" ]]; then
    echo "✓ safe_read_file returned default value: '$result'"
else
    echo "✗ safe_read_file didn't return default: '$result'"
fi

echo ""
echo "Test 3: Concurrent writes (race condition test)"
echo "================================================"

# Launch 10 concurrent writers
TEST_FILE="$TEST_DIR/concurrent.txt"
for i in {1..10}; do
    (
        for j in {1..5}; do
            safe_write_file "$TEST_FILE" "Writer_${i}_iteration_${j}"
            usleep 10000  # 10ms delay
        done
    ) &
done

# Wait for all writers to finish
wait

echo "✓ All concurrent writes completed"

# Read the file - it should contain one complete line, not corrupted
result=$(safe_read_file "$TEST_FILE" "")
if [[ "$result" =~ ^Writer_[0-9]+_iteration_[0-9]+$ ]]; then
    echo "✓ File content is valid (not corrupted): '$result'"
else
    echo "✗ File content appears corrupted: '$result'"
fi

# Check if .lock files were created
lock_count=$(find "$TEST_DIR" -name "*.lock" | wc -l)
echo "  Lock files created: $lock_count"

echo ""
echo "Test 4: Multi-line content"
echo "=========================="

multiline_content="Line 1
Line 2
Line 3"

safe_write_file "$TEST_DIR/multiline.txt" "$multiline_content"
result=$(safe_read_file "$TEST_DIR/multiline.txt" "")

if [[ "$result" == "$multiline_content" ]]; then
    echo "✓ Multi-line content preserved correctly"
else
    echo "✗ Multi-line content corrupted"
    echo "  Expected: $multiline_content"
    echo "  Got: $result"
fi

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo "All flock tests complete!"
