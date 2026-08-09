# 数据库备份与迁移策略

版本：2026-08-09

## 1. 现状

- 真实 DB：`~/Library/Application Support/ToastMonitor/toastmonitor.db`（WAL）。
- 含：turns / sessions / scan_state / session_totals / openrouter_snapshots / opencodego_snapshots / subscriptions / settings。
- 迁移过程不得删除或重置用户数据库；用户主动调用清理/重建 API 时，必须先生成受保护备份并在失败时回滚。

## 2. 备份与恢复

- 应用备份目录为 `~/Library/Application Support/ToastMonitor/Backups/`，目录权限 0700，数据库备份文件权限 0600。
- `DataMaintenance.createBackup(label:)` 使用 SQLite 在线备份快照并保留最近 7 份；`exportDatabase(to:)` 导出完整快照并将目标文件设为 0600。
- `DataMaintenance.clearAllData()` 清理 turns、sessions、scan_state、session_totals、配额快照和 subscriptions，但保留 settings 与 Keychain 凭据；执行前强制创建 `pre-clear` 备份，失败时回滚。
- 修复/清理前会先创建受保护备份，失败时不继续破坏原库。

## 3. 手动诊断

导出/诊断文件应存放在用户选择的路径，权限保持 0600；导出不包含 Keychain 中的 key/cookie，也不记录 prompt。

## 4. 迁移机制

- `PRAGMA user_version` 版本化迁移在 `BEGIN IMMEDIATE` 事务内执行。幂等的 `ensureColumn` ALTER（如 `subscriptions.end_date`、`scan_state.context`）在事务外直接执行——失败可安全重试，不属于版本化迁移。
- 新增列用幂等 `ensureColumn`；数据库使用递归锁，迁移/采集事务可安全调用。`turns` 的 legacy 唯一约束重建和事件索引创建也在同一 `BEGIN IMMEDIATE` 事务内，失败会回滚并保持 `user_version=0` 以便重试。
- 每个历史版本的回放应从旧 schema 副本启动应用并核对 `user_version`、关键表和重复事件数；CI 的 migration replay gate 覆盖代表性旧版本。
