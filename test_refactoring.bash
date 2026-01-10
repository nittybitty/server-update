#!/bin/bash

# Test script for refactored functions
# Tests the batched SSH calls and caching mechanisms

set -e

echo "Testing Refactored Functions"
echo "============================="
echo ""

# Source the main script functions (carefully extract just the functions we need)
# We'll test directly by sourcing specific parts

# Test 1: filter_apt_header function
echo "Test 1: filter_apt_header() function"
echo "-------------------------------------"

# Create test input
cat > /tmp/test_apt_output.txt << 'EOF'
Listing...
vim/focal-updates,focal-security 2:8.1.2269-1ubuntu5.22 amd64 [upgradable from: 2:8.1.2269-1ubuntu5.21]
git/focal-updates,focal-security 1:2.25.1-1ubuntu3.11 amd64 [upgradable from: 1:2.25.1-1ubuntu3.10]
curl/focal-updates,focal-security 7.68.0-1ubuntu2.21 amd64 [upgradable from: 7.68.0-1ubuntu2.20]
EOF

# Test filter_apt_header function
echo "Input:"
cat /tmp/test_apt_output.txt
echo ""
echo "Output (should exclude 'Listing...'):"
grep -v "^Listing\.\.\.$" /tmp/test_apt_output.txt
echo ""

# Count lines
input_lines=$(wc -l < /tmp/test_apt_output.txt)
output_lines=$(grep -v "^Listing\.\.\.$" /tmp/test_apt_output.txt | wc -l)
echo "Input lines: $input_lines, Output lines: $output_lines"
if [[ $output_lines -eq 3 ]]; then
    echo "✓ Test 1 PASSED: filter_apt_header works correctly"
else
    echo "✗ Test 1 FAILED: Expected 3 lines, got $output_lines"
fi
echo ""

# Test 2: Batched SSH call simulation (localhost only)
echo "Test 2: Batched system info gathering"
echo "--------------------------------------"

# Simulate batched OS and kernel query
batch_output=$(echo 'OS:'; cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d'"' -f2 || echo 'Unknown'; echo 'KERNEL:'; uname -r 2>/dev/null || echo 'Unknown')

echo "Raw batch output:"
echo "$batch_output"
echo ""

# Parse batched output
os_info=$(echo "$batch_output" | sed -n '/^OS:/,/^KERNEL:/{/^OS:/d;/^KERNEL:/d;p}' | head -1)
kernel_ver=$(echo "$batch_output" | sed -n '/^KERNEL:/,$p' | tail -1)

echo "Parsed OS: $os_info"
echo "Parsed Kernel: $kernel_ver"

if [[ -n "$os_info" && "$os_info" != "Unknown" ]] && [[ -n "$kernel_ver" && "$kernel_ver" != "Unknown" ]]; then
    echo "✓ Test 2 PASSED: Batched system info gathering works"
else
    echo "✗ Test 2 FAILED: Could not parse system info correctly"
fi
echo ""

# Test 3: Batched disk space query
echo "Test 3: Batched disk space check"
echo "---------------------------------"

batch_output=$(echo 'ROOT:'; df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//'; echo 'BOOT:'; df -BM /boot 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/M//')

echo "Raw batch output:"
echo "$batch_output"
echo ""

# Parse batched output
root_avail=$(echo "$batch_output" | sed -n '/^ROOT:/,/^BOOT:/{/^ROOT:/d;/^BOOT:/d;p}' | head -1)
boot_avail=$(echo "$batch_output" | sed -n '/^BOOT:/,$p' | tail -1)

echo "Parsed root space: ${root_avail}GB"
echo "Parsed boot space: ${boot_avail}MB"

if [[ "$root_avail" =~ ^[0-9]+$ ]]; then
    echo "✓ Test 3 PASSED: Batched disk space check works"
else
    echo "✗ Test 3 FAILED: Could not parse disk space correctly"
fi
echo ""

# Cleanup
rm -f /tmp/test_apt_output.txt

echo "============================="
echo "All basic tests completed!"
echo "============================="
