#!/bin/zsh
# Build SonoSeal.app (release, ad-hoc signed) next to this script.
set -e
cd "${0:A:h}"
swift build -c release
APP=SonoSeal.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp .build/release/SonoSeal $APP/Contents/MacOS/
mkdir -p $APP/Contents/Resources AppIcon.iconset
for n in 16 32 128 256 512; do
  sips -z $n $n appicon.png --out AppIcon.iconset/icon_${n}x${n}.png >/dev/null
  sips -z $((n*2)) $((n*2)) appicon.png --out AppIcon.iconset/icon_${n}x${n}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o $APP/Contents/Resources/AppIcon.icns
rm -rf AppIcon.iconset
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SonoSeal</string>
  <key>CFBundleIdentifier</key><string>com.pierowemyss.SonoSeal</string>
  <key>CFBundleName</key><string>SonoSeal</string>
  <key>CFBundleDisplayName</key><string>SonoSeal</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP
echo "Built $PWD/$APP"
