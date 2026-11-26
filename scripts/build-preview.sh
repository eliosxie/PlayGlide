#!/bin/bash
# Build a local GUI preview with the Swift toolchain, without loading Xcode IDE plugins.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_variant=preview
bundle_identifier=com.eliosxie.PlayGlide
swift_options=(-O -parse-as-library -swift-version 6 -strict-concurrency=complete)

if [[ $# -eq 1 && "${1:-}" == "--development" ]]; then
    build_variant=development
    bundle_identifier=com.eliosxie.PlayGlide.development
    swift_options+=(-D PLAYGLIDE_DEVELOPMENT)
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--development]\n' "$0" >&2
    exit 2
fi

sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
swift_compiler="$(/usr/bin/xcrun --find swiftc)"
build_directory="$repo_root/.build/$build_variant"
preview_app="$build_directory/PlayGlide.app"
preview_info="$preview_app/Contents/Info.plist"

mkdir -p "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources" "$build_directory/ModuleCache"

swift_sources=()
while IFS= read -r -d '' source_path; do
    swift_sources+=("$source_path")
done < <(/usr/bin/find "$repo_root/src/PlayGlide" -type f -name '*.swift' -print0)

"$swift_compiler" \
    "${swift_options[@]}" \
    -target arm64-apple-macos27.0 -sdk "$sdk_path" \
    -module-cache-path "$build_directory/ModuleCache" \
    -o "$preview_app/Contents/MacOS/PlayGlide" "${swift_sources[@]}"

cp "$repo_root/config/Info.plist" "$preview_info"
cp -R "$repo_root/src/PlayGlide/Resources/." "$preview_app/Contents/Resources/"
/usr/bin/plutil -replace CFBundleExecutable -string PlayGlide "$preview_info"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$preview_info"
/usr/bin/plutil -replace CFBundleName -string PlayGlide "$preview_info"
/usr/bin/plutil -replace CFBundleDevelopmentRegion -string en "$preview_info"
/usr/bin/plutil -replace CFBundleShortVersionString -string 0.1.0 "$preview_info"
/usr/bin/plutil -replace CFBundleVersion -string 1 "$preview_info"
/usr/bin/plutil -replace LSMinimumSystemVersion -string 27.0 "$preview_info"

# Ad-hoc signing is for this local preview only, not Developer ID distribution.
/usr/bin/codesign --force --sign - --options runtime \
    --entitlements "$repo_root/config/PlayGlide.entitlements" "$preview_app"
/usr/bin/codesign --verify --strict "$preview_app"
printf 'Built local preview: %s\n' "$preview_app"
