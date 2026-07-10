# 安全策略

## 支持版本

当前维护 `0.2.x`，目标平台为 Apple Silicon、macOS 13+。

## 报告漏洞

请通过 GitHub 仓库的 Private vulnerability reporting 提交安全问题，不要在公开 Issue 中附带剪贴板内容、密钥、完整日志、用户名或绝对路径。报告应包含受影响版本、复现步骤、预期影响和已经尝试的缓解方式。

项目不会要求用户上传钥匙串条目、`bridge.key`、Sparkle 私钥或签名 keychain。正式发布产物必须通过固定 Apple Development 身份、Hardened Runtime、Bundle/扩展签名和 Sparkle EdDSA 校验。
