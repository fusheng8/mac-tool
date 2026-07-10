#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
CODECOV_PATH="${CODECOV_PATH:-$(swift test --show-codecov-path)}"
PROFILE_PATH="$(dirname "$CODECOV_PATH")/default.profdata"
TEST_BINARY="$(find .build -type f -perm +111 \( -name 'mac-toolPackageTests' -o -name 'MacToolPackageTests' \) -print -quit)"
if [[ -z "$TEST_BINARY" || ! -f "$PROFILE_PATH" ]]; then
    echo "无法定位覆盖率测试二进制或 profdata。" >&2
    exit 1
fi
EXPORT_PATH="$(mktemp -t mac-tool-coverage).json"
trap 'rm -f "$EXPORT_PATH"' EXIT
# AppKit 视图由深色模式、窗口尺寸、增强对比度和减少动态效果人工矩阵验收；
# 自动化“整体覆盖率”统计可单元测试的核心与服务代码。
xcrun llvm-cov export "$TEST_BINARY" \
    -instr-profile "$PROFILE_PATH" \
    -ignore-filename-regex='/.build/|/Tests/|/(SettingsWindowController|ClipboardHistoryWindowController|ArchiveBrowserWindowController|ApplicationUninstallerView|MacAssistantUI|PortManagementView|main|ClipboardPreviewViews|PermissionGuideFlow|OnboardingWindowController|MenuBarController|ArchiveCompressionOptionsWindowController|ContextMenuProgressWindowController|ArchivePasswordPrompt|HotKeyRecorderView)\.swift' \
    > "$EXPORT_PATH"
python3 "$ROOT_DIR/scripts/check_coverage.py" "$EXPORT_PATH"
