#!/bin/sh
# builds build/SoundRouter.app (with the driver inside Resources). Needs only Xcode Command Line Tools.
set -e
cd "$(dirname "$0")/.."
A=build/SoundRouter.app; R=$A/Contents/Resources; DRV=$R/SoundRouter.driver
rm -rf build; mkdir -p $A/Contents/MacOS $R $DRV/Contents/MacOS
# driver
clang -bundle -O2 -Wall -Wno-unused-parameter driver/SoundRouterDriver.c -o $DRV/Contents/MacOS/SoundRouterDriver -framework CoreAudio -framework CoreFoundation
cp driver/Info.plist $DRV/Contents/Info.plist
codesign -s - --force $DRV
# app
swiftc -O -parse-as-library -target arm64-apple-macos14.2 app/*.swift -o $A/Contents/MacOS/SoundRouter
cp app/Info.plist $A/Contents/Info.plist
cp scripts/install.sh $R/install.sh
cp app/AppIcon.icns $R/AppIcon.icns
codesign -s - --force --deep $A
echo "built $A"
