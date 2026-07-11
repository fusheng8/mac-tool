#!/bin/zsh
set -euo pipefail

DMG_PATH="${DMG_PATH:-${1:-}}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
    echo "请通过 DMG_PATH 或第一个参数指定待公证的 DMG。" >&2
    exit 1
fi

if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
    echo "缺少 NOTARYTOOL_PROFILE。请先使用 xcrun notarytool store-credentials 创建钥匙串配置。" >&2
    exit 1
fi

signature_info="$(codesign -d --verbose=4 "$DMG_PATH" 2>&1)"
if [[ "$signature_info" != *"Authority=Developer ID Application:"* ]]; then
    echo "DMG 未使用 Developer ID Application 签名，拒绝提交公证。" >&2
    exit 1
fi

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type install --verbose=2 "$DMG_PATH"

echo "公证与 Gatekeeper 验证完成：$DMG_PATH"
