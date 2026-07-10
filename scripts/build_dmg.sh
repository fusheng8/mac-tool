#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mac助手"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
DMG_ROOT="$ROOT_DIR/.build/dmg-root"
DMG_DIR="$ROOT_DIR/.build"

APP_VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-$(git -C "$ROOT_DIR" rev-list --count HEAD)}"
DMG_NAME="${DMG_NAME:-}"
if [[ "${ALLOW_ADHOC:-0}" == "1" ]]; then
    CODESIGN_IDENTITY="-"
elif [[ -z "${CODESIGN_IDENTITY:-}" || "$CODESIGN_IDENTITY" != "Apple Development:"* ]]; then
    echo "DMG 构建需要固定 Apple Development 身份；仅开发验证可显式设置 ALLOW_ADHOC=1。" >&2
    exit 1
fi

cd "$ROOT_DIR"

APP_VERSION="$APP_VERSION" APP_BUILD_VERSION="$APP_BUILD_VERSION" "$ROOT_DIR/scripts/build_app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
if [[ -n "$DMG_NAME" ]]; then
    DMG_PATH="$DMG_DIR/$DMG_NAME"
else
    DMG_PATH="$DMG_DIR/$APP_NAME-$VERSION.dmg"
fi

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP_DIR" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

codesign --force --options runtime --timestamp=none --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
codesign --verify --deep --strict "$APP_DIR"
codesign --verify "$DMG_PATH"

echo "已创建 DMG：$DMG_PATH"
echo "签名身份：$CODESIGN_IDENTITY"
