#!/bin/sh
# Monta o NiriOS.app assinado e o zip da release em .build/dist: ./scripts/app.sh 0.1.0
# Compila em .build/app, não em .build/release: lá pode estar o niri-os de uso rodando.
# Assina com o certificado autoassinado "NiriOS" (docs/NOTES.md, "Distribuição"); NIRI_SIGN troca (nome ou SHA-1).
set -eu
VERSION=${1:?"uso: scripts/app.sh <versão, ex.: 0.1.0>"}
IDENTITY=${NIRI_SIGN:-NiriOS}
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --build-path .build/app
BIN=$(swift build -c release --arch arm64 --build-path .build/app --show-bin-path)/niri-os
OUT=.build/dist
APP=$OUT/NiriOS.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/niri-os"

ICONS=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONS"
swift scripts/icon.swift "$ICONS/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONS/icon_512x512@2x.png" --out "$ICONS/icon_${s}x${s}.png" >/dev/null
    [ $s = 512 ] || sips -z $((s * 2)) $((s * 2)) "$ICONS/icon_512x512@2x.png" --out "$ICONS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONS" -o "$APP/Contents/Resources/AppIcon.icns"

# LSUIElement: sem Dock e sem menu (o tour se põe no Dock enquanto está aberto). macOS 15: as APIs privadas foram
# medidas no 26; as que faltarem no 15 viram log e o recurso fica sem elas (PrivateAPI.swift).
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
    <key>CFBundleExecutable</key><string>niri-os</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.kingdeanprod.niri-os</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>NiriOS</string>
    <key>CFBundleDisplayName</key><string>NiriOS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Runtime endurecido: ignora DYLD_INSERT_LIBRARIES, senão qualquer processo do usuário abriria o app com código seu e
# herdaria a Acessibilidade dele.
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
ditto -c -k --keepParent "$APP" "$OUT/NiriOS-$VERSION.zip"
echo "$OUT/NiriOS-$VERSION.zip  sha256 $(shasum -a 256 "$OUT/NiriOS-$VERSION.zip" | cut -d' ' -f1)"
