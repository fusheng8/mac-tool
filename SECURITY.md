# 安全策略

## 支持版本

当前维护 `0.2.x`，目标平台为 Apple Silicon、macOS 13+。

## 报告漏洞

请通过 GitHub 仓库的 Private vulnerability reporting 提交安全问题，不要在公开 Issue 中附带剪贴板内容、密钥、完整日志、用户名或绝对路径。报告应包含受影响版本、复现步骤、预期影响和已经尝试的缓解方式。

项目不会要求用户上传钥匙串条目、`bridge.key` 或 Apple 代码签名私钥。正式发布默认在受控本机完成 Apple Development 签名，GitHub Actions 只下载并重新验证预签名 DMG，再使用受保护的 Sparkle Secret 生成 appcast。产物必须通过固定 Team Identifier、Hardened Runtime、Bundle/扩展签名和 Sparkle EdDSA 校验。
