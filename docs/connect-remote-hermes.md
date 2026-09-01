# ToastMonitor 连接远程 Hermes

ToastMonitor **不会通过 SSH 直接连接远程主机**。它需要通过 HTTP(S) 读取远程主机生成的 JSON Feed，再把 Hermes 用量导入本机。

> 本文中的域名、地址、端口和路径均为示例或占位符，不包含任何真实服务器信息。

## 准备条件

开始前，请确认：

- 远程主机上的 Hermes 已正常运行并产生用量数据。
- 服务器管理员已经部署了与 ToastMonitor 兼容的用量 Feed。
- 你拿到的是完整 Feed URL，而不是 SSH 主机名，例如：

```text
https://feed.example.com/usage.json
```

也可以通过 Tailscale 或其他私有网络访问：

```text
http://TAILSCALE_IP:PORT/usage.json
```

当前 ToastMonitor 仓库只包含 Feed 客户端，不包含 README 中提到的远端导出脚本 `tm-export.py`。如果远程服务器尚未部署兼容 Feed，需要先由服务器管理员完成这一部分。

## 连接步骤

1. 打开 ToastMonitor，进入完整面板的 **Settings** 页面。
2. 找到 **Remote Feed**，粘贴完整的 Feed URL，然后点击 **Save**。
3. 在同一页面的 **Data Sources** 中，把 **Hermes** 从 **Local** 切换为 **Remote**。
4. 点击 **Test connection**。
5. 看到 `Scan complete`，并且 **Remote Feed** 显示 `Synced`，即表示连接成功。

`Imported 0 rows` 或 `up to date` 不一定是错误，通常表示这次同步没有发现新的用量记录。

## Feed URL 要求

ToastMonitor 接受：

- `https://` 地址。
- Tailscale、局域网私有地址或本机地址上的 `http://` 地址。

ToastMonitor 会拒绝：

- 公网地址上的明文 `http://`。
- `https://USERNAME:PASSWORD@HOST/...` 这类在 URL 中携带凭据的地址。
- 非 HTTP(S) 地址。
- 跳转到其他地址的请求。

当前 Feed 请求不会附带 API Key 或 HTTP Basic Auth。建议通过 Tailscale、防火墙或其他私有网络限制访问，不要把包含会话或项目信息的 Feed 直接暴露到公网。

## 连接前检查

可以先在 Mac 的终端检查 Feed 是否可达。下面的命令只显示状态码和内容类型，不打印 Feed 内容：

```bash
curl -sS -o /dev/null --max-time 15 \
  -w 'HTTP %{http_code} | %{content_type}\n' \
  'https://feed.example.com/usage.json'
```

正常结果应为 HTTP `200`，内容类型应为 JSON。Feed 顶层需要包含 `rows` 数组；如果带有 `schema` 字段，其版本不能高于 `1`。

## 常见问题

| 提示 | 处理方法 |
|---|---|
| `URL rejected` / `invalid or unsafe` | 使用 HTTPS，或通过 Tailscale/局域网私有地址访问；不要在 URL 中写用户名和密码。 |
| `HTTP 401` / `HTTP 403` | 当前客户端不发送认证头。请让管理员改为仅私有网络可访问的 Feed。 |
| `HTTP 404` | 检查 Feed URL 的路径是否正确。 |
| `Non-JSON response` | 服务器必须返回 JSON，并设置正确的内容类型。 |
| `Feed format invalid` | 确认响应顶层包含 `rows` 数组，且 Feed 格式与 ToastMonitor 兼容。 |
| 请求超时 | 检查 VPN/Tailscale、DNS、防火墙和服务器监听端口。 |

## 停用远程连接

1. 在 **Data Sources** 中把 **Hermes** 改回 **Local**。
2. 如需删除远程地址，清空 **Remote Feed** 输入框并点击 **Save**。

分享截图或错误日志前，请遮盖真实域名、IP、端口、项目名、会话 ID 和 Feed 内容。
