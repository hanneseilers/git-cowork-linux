#!/bin/bash
# Prints the app version from Info.plist (the single source of truth).
cd "$(dirname "$0")/.."
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist
