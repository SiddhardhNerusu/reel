#!/bin/zsh
# gen.sh — regenerate Reel.xcodeproj from project.yml, then RESTORE the workspace settings.
#
# Why this wrapper exists: `xcodegen generate` recreates Reel.xcodeproj including
# project.xcworkspace, which wipes WorkspaceSettings.xcsettings. Without that file Xcode
# builds into its OWN ~/Library/Developer/Xcode/DerivedData/Reel-*, producing a SECOND
# Reel.app with the same bundle id. macOS then ties Screen Recording / Accessibility grants
# to whichever copy it saw last, and the permission card starts reappearing forever
# (cost us hours on 2026-08-31). One bundle on disk = grants that stick.
#
# Always run this instead of bare `xcodegen generate`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ xcodegen generate…"
xcodegen generate

SHARED="$ROOT/Reel.xcodeproj/project.xcworkspace/xcshareddata"
mkdir -p "$SHARED"
cat > "$SHARED/WorkspaceSettings.xcsettings" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DerivedDataLocationStyle</key>
	<string>WorkspaceRelativePath</string>
	<key>DerivedDataCustomLocation</key>
	<string>build/DerivedData</string>
</dict>
</plist>
PLIST
echo "✓ Restored workspace DerivedData → build/DerivedData"

# Any stray Xcode-owned build of Reel is a duplicate bundle id; remove it so TCC can't bind to it.
STRAY=(~/Library/Developer/Xcode/DerivedData/Reel-*(N))
if (( ${#STRAY} )); then
  rm -rf "${STRAY[@]}"
  echo "✓ Removed stray Xcode DerivedData: ${#STRAY} dir(s)"
fi

COPIES=$(mdfind "kMDItemCFBundleIdentifier == 'com.neeklabs.Reel'" 2>/dev/null | wc -l | tr -d ' ')
echo "▸ Reel.app copies on disk: $COPIES (expected 1)"
