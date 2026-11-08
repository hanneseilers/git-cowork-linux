#!/bin/bash
# Prints the app version from Resources/Info.plist (the single source of truth,
# shared with the macOS build). No PlistBuddy on Linux, so read the one line.
cd "$(dirname "$0")/../.."
sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Resources/Info.plist
