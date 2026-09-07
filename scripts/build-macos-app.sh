#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
configuration="${1:-release}"
package_path="$repo_root/macos"
output_root="$repo_root/artifacts/macos"
app_path="$output_root/MacroPad Studio.app"
mkdir -p "$output_root"
staging_root="$(mktemp -d "$output_root/.macropad-staging.XXXXXX")"
staged_app="$staging_root/MacroPad Studio.app"

cleanup() {
    rm -rf "$staging_root"
}
trap cleanup EXIT

arm_build="$staging_root/build-arm64"
x86_build="$staging_root/build-x86_64"
swift build --package-path "$package_path" --configuration "$configuration" \
    --triple arm64-apple-macosx13.0 --scratch-path "$arm_build"
swift build --package-path "$package_path" --configuration "$configuration" \
    --triple x86_64-apple-macosx13.0 --scratch-path "$x86_build"
arm_bin="$(swift build --package-path "$package_path" --configuration "$configuration" \
    --triple arm64-apple-macosx13.0 --scratch-path "$arm_build" --show-bin-path)"
x86_bin="$(swift build --package-path "$package_path" --configuration "$configuration" \
    --triple x86_64-apple-macosx13.0 --scratch-path "$x86_build" --show-bin-path)"

mkdir -p "$staged_app/Contents/MacOS"
lipo -create "$arm_bin/MacroPadStudioMac" "$x86_bin/MacroPadStudioMac" \
    -output "$staged_app/Contents/MacOS/MacroPadStudioMac"
lipo -create "$arm_bin/macropad-status-hook" "$x86_bin/macropad-status-hook" \
    -output "$staged_app/Contents/MacOS/macropad-status-hook"
chmod 755 "$staged_app/Contents/MacOS/macropad-status-hook"
cp "$package_path/App/Info.plist" "$staged_app/Contents/Info.plist"

codesign --force --sign - "$staged_app/Contents/MacOS/macropad-status-hook"
codesign --force --sign - "$staged_app"
rm -rf "$app_path"
mv "$staged_app" "$app_path"
echo "Built: $app_path"
