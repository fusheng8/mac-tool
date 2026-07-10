#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/Mac助手.app"
DESTINATION_ROOT="${1:-$HOME/Applications}"

if [[ "$DESTINATION_ROOT" != "$HOME/Applications" && "$DESTINATION_ROOT" != "/Applications" ]]; then
    echo "安装位置仅支持 ~/Applications 或 /Applications。" >&2
    exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
    "$ROOT_DIR/scripts/build_app.sh"
fi

mkdir -p "$DESTINATION_ROOT"
ditto "$APP_DIR" "$DESTINATION_ROOT/Mac助手.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DESTINATION_ROOT/Mac助手.app"
pluginkit -a "$DESTINATION_ROOT/Mac助手.app/Contents/PlugIns/mac-tool-finder-sync.appex"
pluginkit -e use -i com.fusheng.mac-tool.FinderSyncExtension

echo "已安装到 $DESTINATION_ROOT/Mac助手.app"
