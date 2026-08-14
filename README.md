# ToastMonitor

纯原生 macOS 菜单栏 AI 用量监视器（SwiftUI + 系统 SQLite，零第三方依赖）。

统一跟踪 **Claude Code、Codex、OpenCode、Hermes、Oh My Pi、DeepSeek Harness** 的本地日志，外加 **OpenRouter** 云端配额——所有 token 汇总成一份今日用量，常驻状态栏。

## 功能一览

- **状态栏实时 token**：只显示今日总量，点开是完整面板
- **完整面板（4 个 Tab）**：概览 / 用量分析 / 计划与余额 / 来源与设置
- **多源汇总**：一个 SQLite 库汇总所有工具的 token、成本与项目分布，按日/周/月查看
- **配额内建**：OpenCode Go 套餐三条配额条 + 重置倒计时，OpenRouter 余额快照（不依赖 opencode-quota）
- **成本估算**：内置常见模型价格表，未知模型只记 token 不记价
- **隐私优先**：数据只存本机，凭据只进 macOS Keychain，无分析/广告 SDK

## 数据源

| 工具 | 本地 (Mac) 来源 | 远程 |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | VPS feed |
| Codex | `~/.codex/sessions/.../rollout-*.jsonl` + `state_5.sqlite` | VPS feed |
| OpenCode | `~/.local/share/opencode/opencode.db` | VPS feed |
| Hermes | `~/.hermes/state.db`（列自省） | VPS feed |
| Oh My Pi | `~/.omp/agent/sessions/**/*.jsonl` | —（本机专用） |
| DeepSeek Harness | `$DSH_HOME`（默认 `~/.dsh`）的会话日志 + 投影缓存 | —（本机专用） |
| OpenRouter | 云端 API（key + credits 快照） | — |

### 远程 feed

- 仅使用你在「来源与设置」中**明确填写**的地址；应用不内置任何个人 IP 或默认远程主机
- 地址按客户端规则校验，凭据请求不跟随重定向
- 远程轮询由同一采集循环限速到约 15s；本机/远程来源可单独停用

### DeepSeek Harness（DSH）说明

DSH 的 token 口径与 ToastMonitor 一致，四桶一一对应：

| DSH 桶 | ToastMonitor 字段 |
|---|---|
| uncached input | `input_tokens` |
| output（reasoning 已含在内，不单列） | `output_tokens` |
| cache read | `cache_read` |
| cache write | `cache_write` |

解析采用双模式，**互斥且粘性**（`dsh_parse_mode`，首次选定后不因 zstd 装/卸而切换，避免重复计数）：

- **日志模式（主）**：按 step 增量读取 `sessions/**/session.jsonl.zstd`（zstd 独立帧 + 字节游标），含精确时间戳与 model，成本按价格表估算
- **缓存模式（降级）**：对 `storages/session_projcache.json` 的会话累计值做差值；无 model/精确时间，web 会话可见、headless 会话不可见

macOS 无内置 zstd（Compression.framework 只支持 LZ4/ZLIB/LZMA/LZFSE/BROTLI），应用自动在 `PATH` 与常见安装位置（`/opt/homebrew/bin`、`/usr/local/bin`、`/opt/local/bin`）查找 `zstd`；缺失时自动降级为缓存模式，不报错不丢数据。

## 配额（内建，不依赖 opencode-quota）

- **OpenCode Go 套餐**（与 OpenCode 工具是两个独立条目）：抓取 `opencode.ai/workspace/<id>/go` 的 SolidJS SSR/data-slot 数据，显示 5h=$12 / 周=$30 / 月=$60 三条配额条 + 重置倒计时 + 历史。凭据：计划与余额页粘贴，或 `--provision-go <workspaceId>` 后从 stdin 输入 cookie（可从 opencode-quota 的 opencode-go.json 取）
- **OpenRouter**：`/api/v1/key` + `/api/v1/credits` 前台每 60 秒快照（后台停止轮询）。Key：面板粘贴或 `--provision-or-key` 后从 stdin 输入；secret 只存 macOS Keychain

## 安装与构建

```bash
cd ~/Projects/ToastMonitor
./scripts/build-app.sh        # 构建（release）→ 签名 → 安装到 /Applications（CI 环境自动跳过安装）
```

- 本机首次使用 Apple Development 签名后，运行一次 `./scripts/authorize-local-keychain.sh` 授权钥匙串条目，之后同一 Team ID 的新构建不再逐次询问
- 版本号来自 `vMAJOR.MINOR[.PATCH]` git tag；`TM_VERSION`、`TM_BUILD_NUMBER` 仅用于受控 CI/release 注入。未打 tag 的本地构建固定显示 `1.0`（开发构建），不会把 commit hash 当作用户版本
- 分发需要 Developer ID 证书；`build-app.sh` 拒绝 ad-hoc 签名，可用 `TM_SIGNING_IDENTITY` 指定身份
- 也可以直接 `open dist/ToastMonitor.app` 运行构建产物

## 命令行（无头场景 / 开发验证）

```bash
# 凭据注入：一律从 stdin 读取，不进入 argv
printf '%s\n' 'sk-or-...' | dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-or-key
printf '%s\n' 'auth_cookie' | dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-go <workspaceId>
dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --provision-hermes <feedURL>   # 仅用明确配置的地址
dist/ToastMonitor.app/Contents/MacOS/ToastMonitor --clear-or-key                 # 清除
```

- `TM_DEBUG=1`：逐文件扫描决策日志
- `--render-dashboard <path> [height] [width] [tab]`：无头渲染 Dashboard 为 PNG（开发验证，无需窗口/钥匙串）；路径含 `dark`/`light` 时按对应外观渲染；tab 取 `overview / analysis / plans / sources`
- `--show-dashboard`：启动即带面板
- `--verify-status-toggle`：自动验证状态栏按钮开关（CI/自检用）

## 架构

- **单一采集调度**：面板/主页可见时每 1s 扫描，全部隐藏时每 5s 扫描（持续刷新状态栏）；按文件 (size, 纳秒 mtime, inode) 增量读取，稳态只做 stat 检查
- **单 SQLite 库**：`~/Library/Application Support/ToastMonitor/toastmonitor.db`（WAL 模式）
- **成本估算**：内置常见模型价格表（Claude/GPT/DeepSeek 等），未知模型只记 token；`backfillCosts()` 幂等修正历史

## 数据、隐私与安全

- **更新检查**：调用方必须提供 HTTPS 元数据地址 + 随发行物固定的 Ed25519 公钥；`UpdateChecker` 校验元数据签名、版本与下载文件 SHA-256，用户确认后才下载并二次校验哈希。绝不自动下载、安装或执行更新
- **数据维护**：`DataMaintenance.exportDatabase(to:)`、`clearAllData()`、本地清理、受保护备份与恢复前校验；清理前强制生成受保护备份，备份/导出写入用户目录并限制仅当前用户可读。清理或恢复前先退出采集并保留备份
- **隐私**：日志、用量、项目路径与会话元数据默认只存本机 SQLite；只有启用远程 feed 或配额服务时才向配置的服务发起请求。凭据存 macOS Keychain，不写入 URL、plist 或诊断日志；无分析/广告 SDK

## 已知边界

- 菜单栏只显示「今日 tokens」（用户偏好），成本与固定订阅在 tooltip/面板内查看
- 价格表为近似值（按官方价）；OpenCode 自带 cost 字段时直接使用
- DSH 日志模式依赖 `zstd` CLI（见上文查找逻辑）；缓存模式无 model，成本记 0

## 支持

在仓库提交 issue，附：应用版本（「关于」或 `--version`）、macOS 版本、复现步骤、脱敏日志。**不要**上传 token、cookie、API key、项目路径或完整会话内容。

## 许可

源码按仓库根目录 `LICENSE` 发布；第三方系统组件仍受各自许可约束。
