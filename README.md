# ToastMonitor

纯原生 macOS 菜单栏 AI 用量监视器（SwiftUI + 系统 SQLite，零第三方依赖）。

跟踪 **Claude Code / Codex / OpenCode / Hermes** 的本地日志，外加 **OpenRouter** 云端配额面板。

## 数据源（每工具可配置：本机 / 远程 VPS）

| 工具 | 本机 (Mac) 来源 | 远程 (VPS) 来源 |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl`（兼容顶层与 `message.usage`） | VPS feed（tm-export.py 解析 VPS 上的同结构日志） |
| Codex | `~/.codex/sessions/.../rollout-*.jsonl` + `state_5.sqlite` | VPS feed（同结构） |
| OpenCode | `~/.local/share/opencode/opencode.db` | VPS feed（opencode.db session 累计值） |
| Hermes | `~/.hermes/state.db`（列自省） | VPS feed（`session_model_usage` 聚合） |
| OpenRouter | 云端 API（key + credits 快照） | — |

- 默认来源：Hermes=远程（用户实际部署），其余=本机；「来源与设置」Tab 里每个工具可切换。
- 远程 feed：VPS cron 每 3 分钟跑 `tm-export.py` → `http://100.116.140.74/tm/usage.json`（Tailscale-only），App 每 60s 增量拉取（按工具的时间戳 + 事件 ID 游标，支持同秒事件）。

## 配额（内建，不依赖 opencode-quota）

- **OpenCode Go 套餐**（与 OpenCode 工具是两个独立条目）：抓取 `opencode.ai/workspace/<id>/go` 的 SolidJS SSR/data-slot 数据，5h=$12 / 周=$30 / 月=$60 三条配额条 + 重置倒计时 + 历史。凭据：计划与余额/设置入口粘贴或 `--provision-go <workspaceId>` 后从 stdin 输入 cookie（可从 opencode-quota 的 opencode-go.json 取）。
- **OpenRouter**：`/api/v1/key` + `/api/v1/credits` 每 5 分钟快照。Key：面板粘贴或 `--provision-or-key` 后从 stdin 输入；secret 只存 macOS Keychain。

## 架构

- **纯轮询**（5s）：按文件 (size, 纳秒 mtime, inode) 增量读取，稳态扫描 ~20ms。不用 FSEvents —— 只读打开 WAL 库会写 `-shm` 触发自激循环。
- 单 SQLite 库：`~/Library/Application Support/ToastMonitor/toastmonitor.db`（WAL 模式）。
- 成本估算：内置常见模型价格表（Claude/GPT/DeepSeek 等），未知模型只记 token 不记价；`backfillCosts()` 幂等修正历史。

## 构建与运行

```bash
cd ~/Projects/ToastMonitor
swift build -c release
./scripts/build-app.sh          # 组装 .app + 生成图标 + ad-hoc 签名
open dist/ToastMonitor.app      # 或带面板: open -a dist/ToastMonitor.app --args --show-dashboard
```

## 无头 CLI 模式（SSH 场景）

```bash
printf '%s\n' 'sk-or-...' | dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-or-key  # stdin，不进入 argv
printf '%s\n' 'auth_cookie' | dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-go <ws>  # cookie 从 stdin
dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-hermes <feedURL>  # 远程 feed URL（默认 Tailscale）
dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --clear-or-key                 # 清除
TM_DEBUG=1 dist/ToastMonitor.app/Contents/MacOS/ToastMonitor                     # 逐文件扫描决策日志
```

## 已知边界

- 菜单栏显示「今日 tokens · 已确认变量支出」，估算与固定订阅在 tooltip/面板分开；点击出 popover。完整面板包含四个 Tab：概览、用量分析、计划与余额、来源与设置。弹窗只保留周期摘要、工具/会话/额度速览。
- 价格表是近似值（按官方价），OpenCode 自带 cost 字段则直接用。
- 分发需 Developer ID 证书；当前 ad-hoc 签名仅供本机。
