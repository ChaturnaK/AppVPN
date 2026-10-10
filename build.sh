#!/bin/sh
# Builds build/AppVPN.app (ad-hoc signed; no entitlements needed).
set -eu
cd "$(dirname "$0")"

swift build -c release
app=build/AppVPN.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/AppVPN "$app/Contents/MacOS/"
cp vpn.sh AppIcon.icns "$app/Contents/Resources/"
chmod +x "$app/Contents/Resources/vpn.sh"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AppVPN</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>local.appvpn</string>
	<key>CFBundleName</key><string>AppVPN</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF
codesign --force --sign - "$app"
echo "Built $app"
