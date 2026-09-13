#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
package_path="$repo_root/macos"
test_log="$(mktemp /private/tmp/keynob-xctest.XXXXXX)"
trap 'rm -f "$test_log"' EXIT

swift build --package-path "$package_path"
swift run --package-path "$package_path" keynob-probe self-test
zsh "$repo_root/scripts/test-macos-hook.sh"
if swift test --package-path "$package_path" > "$test_log" 2>&1; then
    cat "$test_log"
elif [[ "${KEYNOB_REQUIRE_XCTEST:-0}" != 1 ]] && grep -q "error: no such module 'XCTest'" "$test_log"; then
    echo "Skipping XCTest: this Swift toolchain does not provide the XCTest module."
    echo "Use full Xcode and KEYNOB_REQUIRE_XCTEST=1 to require the complete test suite."
else
    cat "$test_log" >&2
    exit 1
fi
