# 数据库备份与迁移策略

版本：2026-08-05

## 1. 现状

- 真实 DB：`~/Library/Application Support/ToastMonitor/toastmonitor.db`（WAL）。
- 含：turns / sessions / scan_state / session_totals / openrouter_snapshots / opencodego_snapshots / subscriptions / settings。
- **规则：任何阶段不得删除或重置用户数据库。**

## 2. 备份（每次 schema 变更前）

```bash
# Mac 端
DB=~/Library/Application\ Support/ToastMonitor/toastmonitor.db
mkdir -p ~/Projects/ToastMonitor/backups
sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);"
cp "$DB" ~/Projects/ToastMonitor/backups/toastmonitor-$(date +%Y%m%d-%H%M%S).db
```

保留最近 7 份；恢复 = 停 App → 替换 db + 删除 -wal/-shm → 启动。

## 3. 迁移机制（阶段 C 落地）

- `PRAGMA user_version` 版本化迁移，所有迁移在事务内执行。
- 新增列用幂等 `ensureColumn`；数据库使用递归锁，迁移/采集事务可安全调用。`turns` 的 legacy 唯一约束重建和事件索引创建也在同一 `BEGIN IMMEDIATE` 事务内，失败会回滚并保持 `user_version=0` 以便重试。
- 每个历史版本有一份迁移测试（从该版本 schema 升级到最新）。

## 4. 备份导出（阶段 F）

- 导出 = 完整 `VACUUM INTO` 快照，自动脱敏（key/cookie 已在 Keychain，不随 DB）。
- 诊断导出自动脱敏：不记录 prompt、key、cookie 或敏感路径全文。
