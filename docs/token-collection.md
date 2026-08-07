# Token 统计途径说明

本文档说明 ToastMonitor 如何统计 token：**按工具**（数据从哪里来、怎么解析）和**按来源**（本机直接读取 vs 远程 VPS feed）两条线。

## 总览

| 工具 | 本机数据源 | 行语义 | 远程 feed 行语义 |
|---|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | 逐条事件（assistant 的 usage） | 同结构逐条事件 |
| Codex | `~/.codex/sessions/.../rollout-*.jsonl` + `state_5.sqlite` | 逐条事件（token_count 的 last_token_usage） | 同结构逐条事件 |
| OpenCode | `~/.local/share/opencode/opencode.db` | session 累计值 → 本地 delta | 累计值 → session_totals delta |
| Hermes | `~/.hermes/state.db`（列自省） | (session, model) 累计行 → delta | 聚合行 → 基线 delta |
| OpenRouter | 云端 API（不产生 token 行） | — | — |

每个工具可在「来源与设置」里独立选择本机 / 远程（设置键 `src_<tool>`）。

---

## 按工具

### Claude Code

- **本机路径**：`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`，扫描器递归列目录（跳过隐藏项），只取 `.jsonl`。
- **解析**：只处理 `type == "assistant"` 的事件。usage 字段兼容两种结构：事件顶层 `usage`，或 `message.usage`（新版 SDK）。
- **token 字段**：`input_tokens`、`output_tokens`、`cache_read_input_tokens`（缓存命中）、`cache_creation_input_tokens`（缓存写入）。
- **增量**：按 (size, 纳秒 mtime, inode) 判断文件变化；游标是**字节偏移**（`readNewJSONLines`），只解析追加的新行；未写完的尾部行不消费。文件被截断/替换时从偏移 0 重放（重放事件用旧 mtime 生成 ID 以去重）。
- **去重**：事件 ID = 上游 `uuid`，缺失时 `claude:<文件名>:<inode>:<mtime>:<绝对字节偏移>`。全库唯一索引 (tool, event_id) 兜底（INSERT OR IGNORE）。
- **远程 feed**：tm-export.py 在 VPS 上按同结构导出逐条事件，App 直接插入（按 feed 的 event_id 或内容哈希去重）。

### Codex

- **本机路径**：`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`，加 `~/.codex/state_5.sqlite` 的 `threads` 表（model/title/cwd 元数据）。
- **解析**：`event_msg` 类型且 `payload.type == "token_count"` 的事件，取 `payload.info.last_token_usage`（per-turn delta）：`input_tokens`、`output_tokens`、`cached_input_tokens`、`cache_write_input_tokens`。
- **模型关联**：优先 `turn_context` 事件里的 model；其次本 chunk 预扫得到的 model；再退到 `threads` 表的 model/provider；最后才是 NULL（成本按未知处理）。
- **增量**：与 Claude 相同的 (size, mtime, inode) + 字节偏移游标；scan_state 持久化解析上下文（session id/model 跨扫描存活）。
- **去重**：事件 ID = `codex:<文件名>:<inode>:<mtime>:<偏移>`（无上游 uuid）。
- **远程 feed**：逐条事件直接插入。

### OpenCode

- **本机路径**：`~/.local/share/opencode/opencode.db` 的 `session` 表（SQLite，只读打开）。
- **行语义**：每 session 一行**累计值**：`tokens_input`、`tokens_output`、`tokens_reasoning`、`tokens_cache_read`、`tokens_cache_write`、`cost`（官方实际价）。
- **Delta 机制**：本地维护 `session_totals` 表（key `opencode|<id>`）。每次扫描：新累计值 − 上次记录值 = 本批增量；字段变小（上游重置）按 0 处理。首次见到某 session 时把全量累计作为一条回填记录，归到真实最后更新时间（不归到今天）。
- **时间**：上游毫秒时间戳归一化为秒。
- **model**：上游 `model` 列可能是 JSON 对象（`{"id":...,"providerID":...}`），parser 归一化为纯 id；存量数据在启动时一次性 SQL 修复。
- **远程 feed**：同样按累计值走 `session_totals` delta（与本地共用同一 key，切换来源不重复计数）。

### Hermes

- **本机路径**：`~/.hermes/state.db`（SQLite，列名自省——不同版本表结构不同，按存在的列适配）。
- **行语义**：按 (session, model) 的累计行。
- **Delta 机制**：基线键 `hm_d|<session>|<model>|<provider>|<base_url>` 存上次累计值；增量 = 当前 − 上次（负值归 0，防计数器重置）。输出-only 的消息保留（input=0 也记）。时间戳 ms/s 归一化。
- **成本**：Hermes 流量在 OpenCode Go / OpenRouter / Codex 订阅套餐内计费，token 照记、**成本永远为 0**（`cost_quality = 'unknown'`）。
- **远程 feed**：`session_model_usage` 聚合行，按 (session, model, provider, base_url) 做基线 delta——同一把 key 让 route 变化不会重复计数。

### OMP（Oh My Pi）

- **本机路径**：`~/.omp/agent/sessions/**/*.jsonl`（顶层会话 `<cwd>/<session>.jsonl`，子代理会话 `<session>/<agent>.jsonl`）。
- **解析**：事件流里的 `message` 事件（`role == "assistant"`）携带 `message.usage`：`input`、`output`、`cacheRead`、`cacheWrite`、`cost`（按请求的成本分解）。结构与 Claude Code 的 JSONL 类似，因此复用同一套增量机制（size/mtime/inode + 字节偏移游标）。
- **口径**：`input` 是不含缓存命中的部分；`cacheRead` 是命中部分（来自 opencode-go 上游，按 8-token 块粒度报告——与 Hermes 同源，值为真实 tokens）。`cost` 由 provider 计算，OMP 计费在 opencode-go 套餐内，标 `estimated`。
- **去重**：事件 ID = `omp:<文件名>:<消息 id>`（文件名含会话 UUID，全局唯一；消息 id 稳定，重放可去重）。
- **远程 feed**：无（OMP 只在本机运行）。

### OpenRouter

- 不产生 token 行。前台每 60 秒调 `/api/v1/key` + `/api/v1/credits` 快照额度/余额/用量（美元口径；后台停止轮询），只进入「实际花费」，不参与 token 统计。

---

## 按来源

### 本机（默认）

直接读取上述本地文件/SQLite，纯轮询（1 秒一次，仅前台——popover/面板可见时；后台完全停止）：

1. 列出文件 → stat (size, 纳秒 mtime, inode) 对比 `scan_state` → 有变化才读
2. 字节偏移游标只解析新行（追加场景）；截断/替换场景从 0 重放
3. 解析出的 turns/sessions 与**游标/基线在同一 SQLite 事务**提交——任何一步失败整体回滚，游标不前进
4. 稳态空闲扫描约 20ms

### 远程 VPS feed（可选，每工具可切换）

- VPS 上 cron 每 3 分钟跑 `tm-export.py`，产出 `usage.json`（Tailscale 私有网段 HTTP(S)，App 校验 scheme/host/MIME/schema/大小）。
- App 前台每 15 秒增量拉取（后台停止），游标是**每工具水位线**（`remote_watermark_<tool>` = `ts:eventID`，同秒事件靠 eventID 排序）。
- 行语义按工具区分（见上表）：claude/codex 逐条事件直接插入；opencode/hermes 累计行走 delta——delta 工具的基线幂等，因此不受水位线误伤。
- 未知工具的行拒绝导入；水位线、turns、基线同一事务提交，失败不前进。
- **切换来源**：设置 `src_<tool> = local/remote` 即时生效。opencode 的 delta key 本机/远程共用，切换不重复计数；hermes 的基线键与本地不同（本地 `session_totals`、远程 `hm_d|...`），切换时首次远程行会把全量作为一条回填——在源切换后可能多记一次历史（已知边界）。

---

## 主口径与去重保障

- **总 token = 输入 + 输出 + 缓存命中（cacheRead）**；唯一例外是 Codex——其 input 已含缓存，不重复加。`cacheWrite`（缓存写入）只记录、不计入总量。
- **去重链**：上游事件 ID（uuid / 内容哈希）→ 派生 ID（文件+inode+mtime+字节偏移）→ 全库唯一索引 (tool, event_id) `INSERT OR IGNORE`。同一事件重复扫描/重放不会重复计数。
- **成本相关**（与 token 分开）：`actual` = 工具自带实际价（OpenCode cost 字段）；`estimated` = 按内置模型价格表估算；Hermes = unknown（0）。「API 价值」= 全部工具（含 Hermes）每行按模型官方单价重估。
