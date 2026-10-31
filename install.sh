#!/bin/bash
# Builds Mirror, installs it in /Applications and starts it at login.
set -euo pipefail
cd "$(dirname "$0")"

ID=com.sebastianturner.mirror
APP=build/Mirror.app
AGENT=~/Library/LaunchAgents/$ID.plist

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" Sources/main.swift -o "$APP/Contents/MacOS/Mirror"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Signed for this Mac only. Camera access is tied to this exact build, so macOS asks again after a rebuild.
codesign --force --sign - "$APP"

launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null || true
if pgrep -x Mirror >/dev/null; then
  osascript -e "tell application id \"$ID\" to quit"
  sleep 1
fi
rm -rf /Applications/Mirror.app
cp -R "$APP" /Applications/

# Starts at login in the background. Going through `open` registers the app with Launch Services,
# so a click on Mirror reaches the running copy instead of starting a second one.
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$ID</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-g</string>
		<string>/Applications/Mirror.app</string>
		<string>--args</string>
		<string>--background</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Mirror is running. Press Command Shift S."
