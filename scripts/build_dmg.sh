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
NOTARIZE="${NOTARIZE:-0}"
if [[ "${ALLOW_ADHOC:-0}" == "1" ]]; then
    CODESIGN_IDENTITY="-"
    CODESIGN_TIMESTAMP_ARGS=(--timestamp=none)
elif [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" == "Apple Development:"* ]]; then
    CODESIGN_TIMESTAMP_ARGS=(--timestamp=none)
elif [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    CODESIGN_TIMESTAMP_ARGS=(--timestamp)
else
    echo "DMG 构建需要 Apple Development 或 Developer ID Application 身份；仅开发验证可显式设置 ALLOW_ADHOC=1。" >&2
    exit 1
fi

if [[ "$NOTARIZE" == "1" ]]; then
    if [[ "$CODESIGN_IDENTITY" != "Developer ID Application:"* ]]; then
        echo "NOTARIZE=1 要求 Developer ID Application 签名身份。" >&2
        exit 1
    fi
    if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
        echo "NOTARIZE=1 要求设置 NOTARYTOOL_PROFILE。" >&2
        exit 1
    fi
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

codesign --force --options runtime "${CODESIGN_TIMESTAMP_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
codesign --verify --deep --strict "$APP_DIR"
codesign --verify "$DMG_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
    DMG_PATH="$DMG_PATH" NOTARYTOOL_PROFILE="$NOTARYTOOL_PROFILE" "$ROOT_DIR/scripts/notarize_dmg.sh"
fi

echo "已创建 DMG：$DMG_PATH"
echo "签名身份：$CODESIGN_IDENTITY"
