#!/bin/zsh
# xcodegen recreates the .xcodeproj INCLUDING its workspace, wiping this file — which is what
# let Xcode builds land in ~/Library/Developer DerivedData again and resurrect the duplicate-app
# TCC poisoning (2026-09-01). Re-pin Xcode's DerivedData to the canonical build path after every
# generate. Wired via project.yml → options.postGenCommand.
mkdir -p Reel.xcodeproj/project.xcworkspace/xcshareddata
cat > Reel.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings << 'PLIST'
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
