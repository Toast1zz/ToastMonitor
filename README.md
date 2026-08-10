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
| Oh My Pi (OMP) | `~/.omp/agent/sessions/**/*.jsonl`（assistant 消息的 usage 事件） | —（本机专用） |
| OpenRouter | 云端 API（key + credits 快照） | — |

- 远程 feed：仅使用用户在「来源与设置」中明确填写的地址；应用不内置个人 IP 或默认远程主机。地址会按客户端规则校验，凭据请求不跟随重定向。
- 远程轮询由同一采集循环限速到约 15s；本机来源与远程来源都可单独停用。

## 配额（内建，不依赖 opencode-quota）

- **OpenCode Go 套餐**（与 OpenCode 工具是两个独立条目）：抓取 `opencode.ai/workspace/<id>/go` 的 SolidJS SSR/data-slot 数据，5h=$12 / 周=$30 / 月=$60 三条配额条 + 重置倒计时 + 历史。凭据：计划与余额页粘贴或 `--provision-go <workspaceId>` 后从 stdin 输入 cookie（可从 opencode-quota 的 opencode-go.json 取）。
- **OpenRouter**：`/api/v1/key` + `/api/v1/credits` 前台每 60 秒快照（后台停止轮询）。Key：面板粘贴或 `--provision-or-key` 后从 stdin 输入；secret 只存 macOS Keychain。

## 架构

- 单一采集调度：Popover/主页面可见时每 1s 扫描，全部隐藏时每 5s 扫描以持续刷新状态栏 token；按文件 (size, 纳秒 mtime, inode) 增量读取，稳态仅做 stat 检查。远程 feed 由同一循环限速到约 15s；OpenRouter/Go/Codex 配额客户端仅在界面可见时轮询。
- 单 SQLite 库：`~/Library/Application Support/ToastMonitor/toastmonitor.db`（WAL 模式）。
- 成本估算：内置常见模型价格表（Claude/GPT/DeepSeek 等），未知模型只记 token 不记价；`backfillCosts()` 幂等修正历史。

## 构建与运行

```bash
cd ~/Projects/ToastMonitor
swift build -c release
./scripts/build-app.sh          # 使用 artifacts 中的 ToastMonitor.icns 并签名

# 本机首次切换到 Apple Development 签名后，只需运行一次：
./scripts/authorize-local-keychain.sh
open dist/ToastMonitor.app      # 或带面板: open -a dist/ToastMonitor.app --args --show-dashboard
```

版本来源是 `vMAJOR.MINOR` 或 `vMAJOR.MINOR.PATCH` git tag；`TM_VERSION`、`TM_BUILD_NUMBER` 只用于受控 CI/release 注入。未打 tag 的本地构建明确显示 `1.0`（开发构建），不会把 commit hash 当作用户版本。

## 更新、数据与支持

- 更新检查调用方必须提供 HTTPS 元数据地址和随发行物固定的 Ed25519 公钥；`UpdateChecker` 校验元数据签名、版本和下载文件 SHA-256 字段，`verifyArtifact` 在用户确认下载后再校验文件哈希并返回结果，超时后失败。检查不会自动下载、安装或执行更新。
- 数据维护由应用提供 `DataMaintenance.exportDatabase(to:)`、`clearAllData()`、本地清理、受保护备份与恢复前校验；清理前强制生成受保护备份，备份和导出文件写入用户目录并限制为仅当前用户可读。清理或恢复前请先退出采集并保留备份。
- 隐私：日志、用量、项目路径和会话元数据默认仅保存在本机 SQLite；只有用户启用远程 feed 或配额服务时才会向配置的服务发起请求。凭据存储在 macOS Keychain，不写入 URL、plist 或诊断日志。应用不包含分析/广告 SDK。
- 支持：请在仓库提交 issue，并附应用版本（「关于」或 `--version`）、macOS 版本、复现步骤和脱敏日志。不要上传 token、cookie、API key、项目路径或完整会话内容。

## 许可

ToastMonitor 源码按仓库根目录 `LICENSE` 的条款发布；第三方系统组件仍受其各自许可约束。

## 无头 CLI 模式（SSH 场景）

```bash
printf '%s\n' 'sk-or-...' | dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-or-key  # stdin，不进入 argv
printf '%s\n' 'auth_cookie' | dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-go <ws>  # cookie 从 stdin
dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-hermes <feedURL>  # 仅使用明确配置的地址，无个人默认主机
dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --clear-or-key                 # 清除
TM_DEBUG=1 dist/ToastMonitor.app/Contents/MacOS/ToastMonitor                     # 逐文件扫描决策日志
dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --render-dashboard /tmp/dash.png 1000 1120 plans
                                                                                 # 无头渲染 Dashboard 为 PNG（开发验证，无需窗口/钥匙串）
```

开发验证：`--render-dashboard <path> [height] [width] [tab]`，路径含 `dark`/`light` 时按对应外观渲染；tab 取 overview/analysis/plans/sources。

## 已知边界

- 菜单栏只显示「今日 tokens」（用户偏好；估算与固定订阅在 tooltip/面板分开），点击出 popover。完整面板包含四个 Tab：概览、用量分析、计划与余额、来源与设置。弹窗只保留周期摘要与速览。
- 价格表是近似值（按官方价），OpenCode 自带 cost 字段则直接用。
- 分发需 Developer ID 证书；build-app.sh 使用 `artifacts/ToastMonitor-Icon/ToastMonitor.icns`（或同名覆盖路径）并拒绝 ad-hoc 签名。可用 `TM_SIGNING_IDENTITY` 指定受信任身份。
