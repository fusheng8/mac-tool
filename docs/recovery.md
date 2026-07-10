# 故障恢复与数据位置

## 配置损坏

无法解码的 `config.json` 或 `state.json` 会先复制为同目录下带时间戳的 `.corrupt-*` 文件，再加载安全默认值。应用不会静默覆盖唯一副本。确认恢复完成后，可手动删除损坏副本。

## 剪贴板密钥不可用

密钥缺失、损坏或钥匙串暂时不可访问时，剪贴板记录会暂停，原密文库保持不变。先在剪贴板设置中选择“重试访问”；只有确认旧历史不再需要时，才选择“清空无法解密的历史”。应用不会自动生成替代密钥覆盖旧历史。

旧版明文 SQLite 迁移按 50 条一批执行，并核对总数、收藏状态和内容 HMAC。失败或中断时保留旧库以便重试；全部校验成功后删除明文数据库、blob 和缩略图。

## 显示器恢复

应用只记录并恢复由自身实际软断开的显示器 ID。退出和看门狗不会遍历打开所有历史显示器。操作连续失败后会暂停 5 分钟，避免私有后端不可用时持续重试。

## 主要路径

- 配置与状态：`~/Library/Application Support/mac-tool/`
- 剪贴板密文：`~/Library/Application Support/mac-tool/Clipboard/`
- 本地日志：`~/Library/Logs/mac-tool/`
- Finder 配置与桥接凭据：`~/Library/Containers/com.fusheng.mac-tool.FinderSyncExtension/Data/Library/Application Support/mac-tool/`
- iCloud 配置备份：iCloud Drive 的 `Mac助手/config-backup.json`

删除整个应用数据前请先退出 Mac助手。配置导出与 iCloud 备份都不包含剪贴板密钥或 Finder 桥接密钥。
