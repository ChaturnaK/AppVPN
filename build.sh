#!/bin/sh
# Builds build/AppVPN.app (ad-hoc signed; no entitlements needed) with OpenVPN bundled inside.
# VERSION=1.2.3 sets the bundle version.
# "./build.sh dmg" also packages build/AppVPN-<version>.dmg for installation.
set -eu
cd "$(dirname "$0")"

swift build -c release
app=build/AppVPN.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/AppVPN "$app/Contents/MacOS/"
cp vpn.sh AppIcon.icns "$app/Contents/Resources/"
chmod +x "$app/Contents/Resources/vpn.sh"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AppVPN</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>local.appvpn</string>
	<key>CFBundleName</key><string>AppVPN</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION:-0.1}</string>
	<key>CFBundleVersion</key><string>${VERSION:-0.1}</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF

# Bundle OpenVPN so users need not install it: Homebrew's binary plus its libraries, relinked to load
# from inside the app, with their licence texts. Without Homebrew's OpenVPN at build time the app is
# built without it and falls back to an installed one at run time.
for ovpn in /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn; do [ -x "$ovpn" ] && break; done
if [ -x "$ovpn" ]; then
    fw=$app/Contents/Frameworks
    mkdir -p "$app/Contents/Helpers" "$fw" "$app/Contents/Resources/licenses"
    cp -L "$ovpn" "$app/Contents/Helpers/openvpn"
    chmod u+w "$app/Contents/Helpers/openvpn"
    licences() {  # copy the licence files of the Homebrew package a file belongs to
        keg=$(realpath "$1"); keg=${keg%/*/*}
        for f in "$keg"/COPYING* "$keg"/COPYRIGHT* "$keg"/LICENSE* "$keg"/LICENCE*; do
            [ -f "$f" ] && cp "$f" "$app/Contents/Resources/licenses/$(basename "${keg%/*}")-$(basename "$f")"
        done
        return 0
    }
    relink() {  # point a file's Homebrew library references into the bundle, copying each library in
        for dep in $(otool -L "$1" | awk 'NR > 1 && $1 ~ /^\/(opt|usr\/local)\// { print $1 }'); do
            [ -e "$fw/${dep##*/}" ] || { cp -L "$dep" "$fw/"; chmod u+w "$fw/${dep##*/}"; licences "$dep"; }
            install_name_tool -change "$dep" "@executable_path/../Frameworks/${dep##*/}" "$1" 2>/dev/null
        done
    }
    licences "$ovpn"
    relink "$app/Contents/Helpers/openvpn"
    n=0
    until [ "$n" = "$(ls "$fw" | wc -l)" ]; do  # until relinking libraries brings in no new ones
        n=$(ls "$fw" | wc -l)
        for lib in "$fw"/*.dylib; do
            install_name_tool -id "@executable_path/../Frameworks/${lib##*/}" "$lib" 2>/dev/null
            relink "$lib"
        done
    done
    codesign --force --sign - "$fw"/*.dylib "$app/Contents/Helpers/openvpn"  # relinking invalidated their signatures
else
    echo "warning: OpenVPN not found (brew install openvpn); building without a bundled copy" >&2
fi

codesign --force --sign - "$app"
echo "Built $app"

if [ "${1:-}" = dmg ]; then
    # The usual installer layout: the app next to a shortcut to Applications.
    stage=$(mktemp -d)
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"
    dmg=build/AppVPN-${VERSION:-0.1}.dmg
    hdiutil create -quiet -ov -volname AppVPN -srcfolder "$stage" -format UDZO "$dmg"
    rm -rf "$stage"
    echo "Built $dmg"
fi
