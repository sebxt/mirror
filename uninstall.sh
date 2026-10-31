#!/bin/bash
# Removes Mirror, its login item, its saved frame and its camera permission.
ID=com.sebastianturner.mirror

launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null
if pgrep -x Mirror >/dev/null; then osascript -e "tell application id \"$ID\" to quit"; fi
rm -rf /Applications/Mirror.app ~/Library/LaunchAgents/$ID.plist ~/Library/Caches/$ID
tccutil reset Camera "$ID" >/dev/null 2>&1

echo "Mirror is removed."
