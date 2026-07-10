# macOS 兼容矩阵

| 项目 | 0.2.0 支持情况 |
| --- | --- |
| 架构 | Apple Silicon arm64 |
| 最低系统 | macOS 13 Ventura |
| macOS 14 Sonoma | 支持 |
| macOS 15 Sequoia | 支持 |
| Intel / Rosetta | 不作为验收目标 |
| Mac App Store | 不支持；显示器软断开依赖非公开系统能力 |
| 签名 | 固定 Apple Development + Hardened Runtime |
| Developer ID 公证 | 0.2.0 个人稳定版不包含 |

DDC/CI 和显示器软断开还取决于显示器、连接线、扩展坞与系统版本。能力检测失败时，相应控件应禁用并展示原因，不会持续重试或导致应用退出。
