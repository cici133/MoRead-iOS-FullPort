#!/usr/bin/env bash
set -euo pipefail
command -v xcodegen >/dev/null || { echo "请先安装 XcodeGen: brew install xcodegen"; exit 1; }
xcodegen generate
rm -rf build
xcodebuild -project MoRead.xcodeproj -scheme MoRead -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build 2>&1 | tee build/xcodebuild.log
APP=$(find build/DerivedData/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' -print -quit)
test -n "$APP"
test -f "$APP/Info.plist"
./scripts/verify_built_app.sh "$APP"
rm -rf build/Payload
mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && /usr/bin/zip -qry MoRead-unsigned.ipa Payload)
unzip -tq build/MoRead-unsigned.ipa
echo "完成: build/MoRead-unsigned.ipa"
