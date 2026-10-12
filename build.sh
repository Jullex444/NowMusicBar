#!/bin/zsh
# Builds NowMusicBar.app and installs it in /Applications.
set -e
cd "${0:a:h}"
APP=build/NowMusicBar.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O main.swift -o $APP/Contents/MacOS/NowMusicBar -target arm64-apple-macos13 -framework AppKit -framework ServiceManagement
clang -O2 -dynamiclib -fobjc-arc -framework Foundation -arch arm64 -arch x86_64 helper.m -o $APP/Contents/Resources/libhelper.dylib
cp helper.pl $APP/Contents/Resources/
cp Info.plist $APP/Contents/
[[ -f AppIcon.icns ]] && cp AppIcon.icns $APP/Contents/Resources/
codesign --force --deep --sign - $APP
pkill -x NowMusicBar || true
rm -rf /Applications/NowMusicBar.app && cp -R $APP /Applications/
open /Applications/NowMusicBar.app
