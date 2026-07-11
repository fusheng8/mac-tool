#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/Mac助手.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
EXTENSION_DIR="$PLUGINS_DIR/mac-tool-finder-sync.appex"
EXTENSION_CONTENTS_DIR="$EXTENSION_DIR/Contents"
EXTENSION_MACOS_DIR="$EXTENSION_CONTENTS_DIR/MacOS"
ALLOW_ADHOC="${ALLOW_ADHOC:-0}"
SWIFT_PACKAGE_ARGS=()
if [[ "${DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    SWIFT_PACKAGE_ARGS+=(--disable-sandbox)
fi
APP_VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-$(git -C "$ROOT_DIR" rev-list --count HEAD)}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-eyi+nHTzTn99VVto7AhjOAjXE908zK36XXjKLWRRxSU=}"

if [[ "$ALLOW_ADHOC" == "1" ]]; then
    CODESIGN_IDENTITY="-"
elif [[ -z "${CODESIGN_IDENTITY:-}" || "$CODESIGN_IDENTITY" != "Apple Development:"* ]]; then
    echo "正式构建必须设置固定的 Apple Development 签名身份。开发构建可显式使用 ALLOW_ADHOC=1。" >&2
    exit 1
fi

if [[ ! "$APP_VERSION" =~ '^[0-9]+(\.[0-9]+){2}$' ]]; then
    echo "APP_VERSION 必须是 x.y.z 格式，例如 0.2.0" >&2
    exit 1
fi

if [[ ! "$APP_BUILD_VERSION" =~ '^[0-9]+$' ]]; then
    echo "APP_BUILD_VERSION 必须是正整数，默认取 Git 提交计数" >&2
    exit 1
fi

cd "$ROOT_DIR"
swift build "${SWIFT_PACKAGE_ARGS[@]}" -c release --arch arm64 --product mac-tool -Xswiftc -gnone -Xswiftc -warnings-as-errors
swift build "${SWIFT_PACKAGE_ARGS[@]}" -c release --arch arm64 --product mac-tool-finder-sync -Xswiftc -gnone -Xswiftc -warnings-as-errors
BIN_DIR="$(swift build "${SWIFT_PACKAGE_ARGS[@]}" -c release --arch arm64 --show-bin-path)"

SPARKLE_FRAMEWORK_SOURCE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
    SPARKLE_FRAMEWORK_SOURCE="$(find "$ROOT_DIR/.build/artifacts" -path "*/Sparkle.xcframework/*/Sparkle.framework" -type d -print -quit 2>/dev/null || true)"
fi
if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
    echo "未找到 Sparkle.framework，请先确认 SwiftPM 已解析 Sparkle 依赖。" >&2
    exit 1
fi
MAC_TOOL_RESOURCE_BUNDLE="$(find "$ROOT_DIR/.build/arm64-apple-macosx/release" "$ROOT_DIR/.build/release" -maxdepth 1 -name "mac-tool_MacToolApp.bundle" -type d -print -quit 2>/dev/null || true)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$HELPERS_DIR" "$EXTENSION_MACOS_DIR"
cp "$BIN_DIR/mac-tool" "$MACOS_DIR/mac-tool"
cp "$BIN_DIR/mac-tool-finder-sync" "$EXTENSION_MACOS_DIR/mac-tool-finder-sync"
strip -S "$MACOS_DIR/mac-tool"
strip -S "$EXTENSION_MACOS_DIR/mac-tool-finder-sync"
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"
SPARKLE_RESOURCES_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Resources"
SPARKLE_ZH_CN_STRINGS="$SPARKLE_RESOURCES_DIR/zh_CN.lproj/Sparkle.strings"
if [[ -f "$SPARKLE_ZH_CN_STRINGS" ]]; then
    for sparkle_strings in "$SPARKLE_RESOURCES_DIR"/*.lproj/Sparkle.strings; do
        [[ "$sparkle_strings" == "$SPARKLE_ZH_CN_STRINGS" ]] && continue
        cp "$SPARKLE_ZH_CN_STRINGS" "$sparkle_strings"
    done
else
    echo "Sparkle.framework 缺少 zh_CN 本地化资源，无法统一更新弹窗语言。" >&2
    exit 1
fi
if [[ -n "$MAC_TOOL_RESOURCE_BUNDLE" ]]; then
    ditto "$MAC_TOOL_RESOURCE_BUNDLE" "$RESOURCES_DIR/$(basename "$MAC_TOOL_RESOURCE_BUNDLE")"
fi
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/mac-tool" 2>/dev/null || true
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/Resources/StatusIconRingTemplate.png" "$RESOURCES_DIR/StatusIconRingTemplate.png"
cp "$ROOT_DIR/Resources/StatusIconRingGray.png" "$RESOURCES_DIR/StatusIconRingGray.png"
cp "$ROOT_DIR/Vendor/7zip/7zz" "$HELPERS_DIR/7zz"
chmod 755 "$HELPERS_DIR/7zz"
mkdir -p "$RESOURCES_DIR/ThirdPartyLicenses"
cp "$ROOT_DIR/Vendor/7zip/LICENSE.txt" "$RESOURCES_DIR/ThirdPartyLicenses/7-Zip.txt"

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
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh_CN</string>
    </array>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0</string>
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
            <key>LSItemContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>org.gnu.gnu-tar-archive</string>
                <string>org.bzip.bzip2-archive</string>
                <string>org.bzip.bzip2-tar-archive</string>
                <string>org.tukaani.xz-archive</string>
                <string>org.tukaani.xz-tar-archive</string>
                <string>org.7-zip.7-zip-archive</string>
                <string>com.rarlab.rar-archive</string>
                <string>com.rarlab.rar-archive-v4</string>
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
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>mac-tool-finder-sync</string>
    <key>CFBundleIdentifier</key>
    <string>com.fusheng.mac-tool.FinderSyncExtension</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>mac-tool-finder-sync</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh_CN</string>
    </array>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0</string>
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

codesign --force --deep --options runtime --timestamp=none --sign "$CODESIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign --force --options runtime --timestamp=none --sign "$CODESIGN_IDENTITY" "$HELPERS_DIR/7zz"
codesign --force --options runtime --timestamp=none --sign "$CODESIGN_IDENTITY" --entitlements "$ROOT_DIR/scripts/finder_sync_extension.entitlements" "$EXTENSION_DIR"
codesign --force --options runtime --timestamp=none --sign "$CODESIGN_IDENTITY" "$APP_DIR"

if [[ "$(lipo -archs "$MACOS_DIR/mac-tool")" != "arm64" || "$(lipo -archs "$EXTENSION_MACOS_DIR/mac-tool-finder-sync")" != "arm64" || "$(lipo -archs "$HELPERS_DIR/7zz")" != "arm64" ]]; then
    echo "构建失败：主程序、Finder 扩展或内置 7zz 不是纯 arm64。" >&2
    exit 1
fi

echo "已创建 $APP_DIR"
echo "版本号：$APP_VERSION ($APP_BUILD_VERSION)"
echo "签名身份：$CODESIGN_IDENTITY"
echo "Sparkle：$SPARKLE_FRAMEWORK_SOURCE"
echo "资源包：${MAC_TOOL_RESOURCE_BUNDLE:-未找到，已使用直接复制资源}"
