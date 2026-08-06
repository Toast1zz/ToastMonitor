# 数据语义（Data Semantics）

版本：2026-08-05 · 状态：规范（阶段 B 起强制执行）

## 1. 金额口径（禁止混加）

| 字段 | 含义 | 来源 | 可相加对象 |
|---|---|---|---|
| `actualVariableSpend` | 上游明确返回的实际现金/credit 支出 | OpenRouter `usage*`、Hermes `actual_cost_usd` | 仅同类 |
| `estimatedVariableCost` | 按价格表估算 | `Pricing.estimate` | 仅同类（需覆盖率） |
| `subscriptionFixedCost` | 用户录入的订阅费用 | `subscriptions.price` | 仅同类（按周期摊销时注明） |
| `quotaValueConsumed` | 套餐美元定价额度消耗 | OCG 官方 `monthlyPct × $60` | 不等于现金支出 |
| `accountBalance` | 可用余额 | OpenRouter `/credits` | 不与其他金额相加 |
| `purchasedCredits` / `usedCredits` | 累计购买/使用 | OpenRouter `/credits` | 相互参照，不参与聚合 |

**规则**：UI 不得无条件把这些值相加。任何加总必须声明口径：
- 「今日总花费」= 订阅当日摊销 + OpenRouter 今日实际 + 直连估算（各分量可展开）。
- 「已用价值」只用于套餐上下文，不得称为「花费」。

## 2. Token 口径

- `inputTokens`：上游定义的总输入（可能含缓存命中）。
- `cachedInputTokens`：若为 input 子集 → 非缓存输入 = input − cached。
- `cacheWriteTokens`：单独记录，不并入 input。
- `outputTokens`：注明是否含 reasoning；`reasoningTokens` 上游提供时单独记录。
- `billableInputTokens`：按 provider 计费规则派生（如 OpenAI 缓存输入按缓存价），不直接存猜测值。

## 3. 数据质量（Quality）

每个聚合结果必须能表达：

```
enum MetricQuality { case actual, estimated, partial, unknown }
覆盖率 = 已覆盖金额 / 总金额（估算时显示）
```

规则：
- 未知模型/未知成本 → `unknown` + `—`，禁止显示 `$0.000`。
- 部分 key 失败 → `partial`，禁止显示为全量成功。
- 数据过期（超过 N 分钟未同步）→ `stale` 显式标注。

## 4. 时间

- 统一存 Unix 秒（Int64）。
- `created` 取最早有效非零时间；`updated` 取最晚时间。
- `0` 表示 unknown，UI 显示 `—`，禁止显示 1970。
- Hermes 无时间列时显式 unknown，不查询不存在的列。
