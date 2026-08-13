#!/bin/zsh
# 编译 FanControl 菜单栏应用并打包为 FanControl.app
# 图标资产: assets/fan-icon-cropped.png (App 图标)
#          assets/menubar_icon*.png      (菜单栏图标, 由 MenuBarIconGen 渲染原生 fan.fill)
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$SRC/FanControl.app"
BUILD="$SRC/.build"
CACHE="$SRC/.build-cache"
DIST="$SRC/fancontrol-dist"
ICON_SRC="$SRC/assets/fan-icon-cropped.png"
ICON_ICNS="$SRC/assets/AppIcon.icns"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

if [[ "$SIGNING_IDENTITY" != "-" ]] &&
   ! /usr/bin/security find-identity -v -p codesigning |
   /usr/bin/grep -Fq "$SIGNING_IDENTITY"; then
  echo "错误: 未找到签名身份: $SIGNING_IDENTITY" >&2
  echo "请先安装 Developer ID Application 证书，或使用 SIGNING_IDENTITY=- 生成临时签名构建。" >&2
  exit 1
fi

sign_target() {
  local target="$1"
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$target"
  else
    # Apple notarization requires a Developer ID signature, a secure
    # timestamp, and the Hardened Runtime on every executable we distribute.
    /usr/bin/codesign --force --options runtime --timestamp \
      --sign "$SIGNING_IDENTITY" "$target"
  fi
}

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$CACHE/ModuleCache" "$CACHE/cache"
export CLANG_MODULE_CACHE_PATH="$CACHE/ModuleCache"
export SWIFT_MODULECACHE_PATH="$CACHE/ModuleCache"
export XDG_CACHE_HOME="$CACHE/cache"

echo "==> [1/5] 编译受限的 SMC 工具 (通用二进制)"
clang -O2 -Wall -Wextra -arch x86_64 -arch arm64 \
  "$SRC/smc.c" -framework IOKit -framework CoreFoundation \
  -o "$BUILD/smc"
sign_target "$BUILD/smc"
cp "$BUILD/smc" "$APP/Contents/Resources/smc"
cp "$BUILD/smc" "$SRC/smc"
chmod 755 "$APP/Contents/Resources/smc"
chmod 755 "$SRC/smc"

echo "==> [2/5] 生成 App 图标 (iconset -> icns)"
if [ -f "$ICON_ICNS" ]; then
  cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
else
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  # 源图 512px, 1024 由 sips 放大
  for spec in "16 16" "32 16" "32 32" "64 32" "128 128" "256 128" "256 256" "512 256" "512 512" "1024 512"; do
    px=$(echo $spec | cut -d' ' -f1)
    base=$(echo $spec | cut -d' ' -f2)
    if [ "$px" = "$base" ]; then
      name="icon_${base}x${base}.png"
    else
      name="icon_${base}x${base}@2x.png"
    fi
    sips -z $px $px "$ICON_SRC" --out "$ICONSET/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> [3/5] 渲染菜单栏图标"
swiftc -O -parse-as-library -o "$BUILD/MenuBarIconGen" "$SRC/MenuBarIconGen.swift" -framework Cocoa
"$BUILD/MenuBarIconGen" "$BUILD/menubar" >/dev/null
cp "$BUILD/menubar/"menubar_icon*.png "$APP/Contents/Resources/"
# Generated previews stay in the build directory. Do not rewrite versioned
# design assets merely because a maintainer creates a release artifact.
# 首次启动预设的 bundle 级保底资源；新机器无需先运行 CLI。
cp "$SRC/DefaultPresets.json" "$APP/Contents/Resources/DefaultPresets.json"

echo "==> [4/5] 编译应用 (通用二进制 x86_64 + arm64)"
swiftc -O -target x86_64-apple-macos13.0 -o "$BUILD/FanControl-x86_64" \
    "$SRC/FanControl.swift" "$SRC/SettingsView.swift" \
    -framework Cocoa -framework SwiftUI
swiftc -O -target arm64-apple-macos13.0 -o "$BUILD/FanControl-arm64" \
    "$SRC/FanControl.swift" "$SRC/SettingsView.swift" \
    -framework Cocoa -framework SwiftUI
lipo -create -output "$APP/Contents/MacOS/FanControl" \
    "$BUILD/FanControl-x86_64" "$BUILD/FanControl-arm64"

echo "==> [5/5] 打包 App 与完整分发包"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FanControl</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.gmaxio.fancontrol</string>
    <key>CFBundleName</key>
    <string>FanControl</string>
    <key>CFBundleDisplayName</key>
    <string>FanControl</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
</dict>
</plist>
EOF

sign_target "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

# 两种下载都必须可用：
# - FanControl.app.zip 可直接打开，并能从 App 内安装控制组件；
# - fancontrol-dist.zip 额外包含 CLI 与安装脚本。
rm -rf "$DIST" "$SRC/FanControl.app.zip" "$SRC/fancontrol-dist.zip"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/FanControl.app"
cp "$BUILD/smc" "$DIST/smc"
cp "$SRC/fancontrol.py" "$SRC/install.sh" "$SRC/uninstall.sh" "$SRC/README.md" "$DIST/"
# Release archives intentionally exclude extended attributes and AppleDouble
# sidecars. This keeps builds reproducible and avoids shipping local Finder
# metadata such as __MACOSX/ entries.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP" "$SRC/FanControl.app.zip"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$DIST" "$SRC/fancontrol-dist.zip"

rm -rf "$BUILD"
echo "==> 完成:"
echo "    $APP"
echo "    $SRC/FanControl.app.zip"
echo "    $SRC/fancontrol-dist.zip"
