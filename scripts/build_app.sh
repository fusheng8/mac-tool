#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/Mac助手.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP_DIR="$INSTALL_DIR/Mac助手.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
EXTENSION_DIR="$PLUGINS_DIR/mac-tool-finder-sync.appex"
EXTENSION_CONTENTS_DIR="$EXTENSION_DIR/Contents"
EXTENSION_MACOS_DIR="$EXTENSION_CONTENTS_DIR/MacOS"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
PACKAGE_ONLY="${PACKAGE_ONLY:-0}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-$APP_VERSION}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-flJcsKYBq5Bqqw5S/h3r9CatV/LhrhY/rke2zOhL9E4=}"

if [[ ! "$APP_VERSION" =~ '^[0-9]+(\.[0-9]+){2}$' ]]; then
    echo "APP_VERSION 必须是 x.y.z 格式，例如 0.1.0" >&2
    exit 1
fi

if [[ ! "$APP_BUILD_VERSION" =~ '^[0-9]+(\.[0-9]+){2}$' ]]; then
    echo "APP_BUILD_VERSION 必须是 x.y.z 格式，例如 0.1.0" >&2
    exit 1
fi

cd "$ROOT_DIR"
swift build -c release --product mac-tool
swift build -c release --product mac-tool-finder-sync

SPARKLE_FRAMEWORK_SOURCE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
    SPARKLE_FRAMEWORK_SOURCE="$(find "$ROOT_DIR/.build/artifacts" -path "*/Sparkle.xcframework/*/Sparkle.framework" -type d -print -quit 2>/dev/null || true)"
fi
if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
    echo "未找到 Sparkle.framework，请先确认 SwiftPM 已解析 Sparkle 依赖。" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$EXTENSION_MACOS_DIR"
cp "$ROOT_DIR/.build/release/mac-tool" "$MACOS_DIR/mac-tool"
cp "$ROOT_DIR/.build/release/mac-tool-finder-sync" "$EXTENSION_MACOS_DIR/mac-tool-finder-sync"
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/mac-tool" 2>/dev/null || true
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/Resources/StatusIconRingTemplate.png" "$RESOURCES_DIR/StatusIconRingTemplate.png"
cp "$ROOT_DIR/Resources/StatusIconRingGray.png" "$RESOURCES_DIR/StatusIconRingGray.png"
mkdir -p "$RESOURCES_DIR/Templates"
if [[ -f "$HOME/Desktop/演示文稿1.pptx" ]]; then
    cp "$HOME/Desktop/演示文稿1.pptx" "$RESOURCES_DIR/Templates/BlankPowerPoint.pptx"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>mac-tool</string>
    <key>CFBundleIdentifier</key>
    <string>com.fusheng.mac-tool</string>
    <key>CFBundleName</key>
    <string>Mac助手</string>
    <key>CFBundleDisplayName</key>
    <string>Mac助手</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://fusheng8.github.io/mac-tool/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>__SPARKLE_PUBLIC_ED_KEY__</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Mac助手需要读取和写入桌面中的压缩包及解压目标目录。</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Mac助手需要读取和写入文稿中的压缩包及解压目标目录。</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Mac助手需要读取和写入下载中的压缩包及解压目标目录。</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>Mac助手需要读取和写入网络磁盘中的压缩包及解压目标目录。</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Mac助手需要读取和写入外置磁盘中的压缩包及解压目标目录。</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Archive</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>zip</string>
                <string>tar</string>
                <string>gz</string>
                <string>tgz</string>
                <string>bz2</string>
                <string>tbz</string>
                <string>tbz2</string>
                <string>xz</string>
                <string>txz</string>
                <string>7z</string>
                <string>rar</string>
            </array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.fusheng.mac-tool.contextMenu</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>macassistant</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

cat > "$EXTENSION_CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Mac助手右键菜单</string>
    <key>CFBundleExecutable</key>
    <string>mac-tool-finder-sync</string>
    <key>CFBundleIdentifier</key>
    <string>com.fusheng.mac-tool.FinderSyncExtension</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>mac-tool-finder-sync</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict/>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.FinderSync</string>
        <key>NSExtensionPrincipalClass</key>
        <string>MacToolFinderSync.FinderSyncExtension</string>
    </dict>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$EXTENSION_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_VERSION" "$EXTENSION_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign "$CODESIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$ROOT_DIR/scripts/finder_sync_extension.entitlements" "$EXTENSION_DIR"
codesign --force --sign "$CODESIGN_IDENTITY" "$APP_DIR"

echo "已创建 $APP_DIR"
echo "版本号：$APP_VERSION ($APP_BUILD_VERSION)"
echo "签名身份：$CODESIGN_IDENTITY"
echo "Sparkle：$SPARKLE_FRAMEWORK_SOURCE"

if [[ "$PACKAGE_ONLY" == "1" ]]; then
    echo "已跳过安装和 Finder Sync 注册"
else
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALLED_APP_DIR"
    cp -R "$APP_DIR" "$INSTALLED_APP_DIR"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED_APP_DIR"
    pluginkit -a "$INSTALLED_APP_DIR/Contents/PlugIns/mac-tool-finder-sync.appex"
    pluginkit -e use -i com.fusheng.mac-tool.FinderSyncExtension

    echo "已安装 $INSTALLED_APP_DIR"
    echo "如右键菜单未出现，请运行：killall Finder"
fi
