#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
package_path="$repo_root/macos"
temporary_root="$(mktemp -d /private/tmp/macropad-status-test-XXXXXX)"
socket_path="$temporary_root/status.sock"
output_path="$temporary_root/output.json"
listener_pid=""
watchdog_pid=""

cleanup() {
    [[ -z "$listener_pid" ]] || kill "$listener_pid" 2>/dev/null || true
    [[ -z "$watchdog_pid" ]] || kill "$watchdog_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$temporary_root"
}
trap cleanup EXIT

if [[ $# == 1 ]]; then
    binary_path="$1"
    [[ -x "$binary_path" ]] || { echo "Hook executable not found: $binary_path" >&2; exit 1; }
else
    swift build --package-path "$package_path" --configuration debug --product macropad-status-hook
    binary_path="$(swift build --package-path "$package_path" --configuration debug --show-bin-path)/macropad-status-hook"
fi

nc -lU "$socket_path" > "$output_path" &
listener_pid=$!
(sleep 10; kill "$listener_pid" 2>/dev/null || true) &
watchdog_pid=$!
for _ in {1..50}; do
    [[ -S "$socket_path" ]] && break
    sleep 0.02
done
[[ -S "$socket_path" ]] || { echo "Test listener did not start" >&2; exit 1; }

printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"session-1","turn_id":"turn-1","failed":true,"prompt":"must-not-leave-helper"}' |
    MACROPAD_TEST_STATUS_SOCKET="$socket_path" CODEX_KEYBOARD_INSTANCE_ID="mac-test-instance" "$binary_path"
if ! wait "$listener_pid"; then
    echo "Hook transport failed or timed out" >&2
    exit 1
fi
listener_pid=""
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""

grep -q '"eventName":"UserPromptSubmit"' "$output_path"
grep -q '"sessionID":"session-1"' "$output_path"
grep -q '"turnID":"turn-1"' "$output_path"
grep -q '"instanceID":"mac-test-instance"' "$output_path"
grep -q '"isError":true' "$output_path"
if grep -q 'must-not-leave-helper' "$output_path"; then
    echo "hook privacy test failed" >&2
    exit 1
fi

echo "macOS hook transport test passed"
