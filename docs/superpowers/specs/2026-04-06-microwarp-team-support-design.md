# MicroWARP Team 支持设计文档

## 概述

为 MicroWARP 增加 Cloudflare WARP Team (Zero Trust) 支持，通过直接调用 Cloudflare Teams API 注册设备并生成 WireGuard 配置，无需 `warp-cli`，运行时资源占用与原版一致（~800KiB）。

## 动机

- 免费 WARP 的出口 IP 质量一般，访问 Google/OpenAI/Netflix 等服务容易触发风控
- WARP Team (warp=plus) 的 IP 质量更高，风控更少
- 现有方案（`warp-cli` Proxy 模式）需要 ~150MB 内存，与 MicroWARP 轻量化理念冲突

## 方案选型

| 方案 | 运行时内存 | 镜像增量 | 可行性 |
|------|-----------|---------|--------|
| **A: API 直注册 (选定)** | ~800KiB | +250KB (jq) | 已由 wgcf-teams 项目验证 |
| B: Init 阶段 warp-cli 提取 | ~800KiB | +200MB (warp-cli) | 可行但镜像臃肿 |
| C: 完整 warp-cli Proxy | ~150MB | +200MB | 可行但丧失轻量优势 |

## 技术设计

### 1. 用户接口

新增环境变量：

| 变量 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `TEAM_TOKEN` | 否 | 空 | Cloudflare Teams JWT Token。设置后进入 Team 注册模式，不设则走免费 WARP |

用户获取 JWT Token 的步骤：
1. 浏览器访问 `https://{team-name}.cloudflareaccess.com/warp`
2. 完成组织认证
3. 在成功页面按 F12，找到包含 `com.cloudflare.warp://` 的元素
4. 复制 URL 中 `?token=` 后的 JWT 字符串

### 2. 注册流程

#### 分支逻辑（entrypoint.sh 第 1 段）

```
if [ -f "$WG_CONF" ]; then
    → 检测到已有配置，跳过注册（不变）
elif [ -n "$TEAM_TOKEN" ]; then
    → Team API 注册（新增）
else
    → wgcf 免费注册（原有逻辑不变）
fi
```

#### Team API 注册细节

**API 端点：**
```
POST https://zero-trust-client.cloudflareclient.com/v0i2308311933/reg
```

**请求头：**
| Header | Value |
|--------|-------|
| User-Agent | `1.1.1.1/6.23` |
| CF-Client-Version | `i-6.23-2308311933.1` |
| Content-Type | `application/json` |
| Cf-Access-Jwt-Assertion | `$TEAM_TOKEN` |

**请求体：**
```json
{
  "key": "<WireGuard public key, base64>",
  "tos": "<ISO 8601 timestamp>",
  "model": "iPad13,8",
  "fcm_token": "",
  "device_token": ""
}
```

**响应解析（关键字段）：**
- `result.config.peers[0].public_key` → WireGuard Peer 公钥
- `result.config.peers[0].endpoint.host` → Endpoint 地址
- `result.config.interface.addresses.v4` → 分配的 IPv4 地址
- `result.config.client_id` → 路由标识（Reserved 字节，base64 编码的 3 字节）
- `result.account.account_type` → 应为 `"team"`（用于验证）

#### WireGuard 配置生成

```ini
[Interface]
PrivateKey = <本地生成的私钥>
Address = <v4_addr>/32

[Peer]
PublicKey = <peer_pub>
AllowedIPs = 0.0.0.0/0
Endpoint = <endpoint>
```

同时将 `client_id` 解码后保存到 `/etc/wireguard/team_info`，格式：
```
client_id=<base64值>
reserved_hex=<十六进制值>
reserved_dec=<十进制逗号分隔值>
```

### 3. 改动范围

#### entrypoint.sh

- **改动区域：** 仅第 1 段（第 27-55 行），即账号注册逻辑
- **第 2-4 段完全不动：** 配置洗白、内核网卡启动、SOCKS5 启动
- Team 生成的 `wg0.conf` 格式与 `wgcf generate` 输出兼容，后续处理逻辑无需修改

#### Dockerfile

- `apk add` 行增加 `jq`（约 250KB）
- 无其他改动

#### docker-compose.yml

- `environment` 注释块中增加 `TEAM_TOKEN` 示例

### 4. 错误处理

| 错误场景 | 处理方式 |
|---------|---------|
| TEAM_TOKEN 格式无效 | 打印 "JWT Token 格式错误"，exit 1 |
| API 返回 401/403 | 打印 "Token 无效或已过期，请重新获取"，exit 1 |
| API 返回其他错误 | 打印原始错误信息，exit 1 |
| 响应缺少必要字段 | 打印 "API 响应格式异常"，exit 1 |
| curl 超时 | 15 秒超时后打印 "网络连接超时"，exit 1 |

### 5. 持久化

与免费模式完全一致：
- `wg0.conf` 通过 Docker Volume 持久化到 `/etc/wireguard/`
- 容器重启时检测到配置文件存在则跳过注册
- `team_info` 文件也持久化在同一 Volume

## 已知风险

### Reserved 字节兼容性

Cloudflare 在 WireGuard 协议头的 3 个 Reserved 字节中嵌入 `client_id`（路由标识）。Linux 内核 WireGuard 不支持设置 Reserved 字节（固定为 0）。

- **免费 WARP** 在 Reserved=0 时正常工作（wgcf + 内核 WireGuard 已验证）
- **Team WARP** 未确认是否必须 Reserved 字节

**降级方案：** 如果内核 WireGuard 对 Team 不可用：
1. 使用 Cloudflare 的 `boringtun`（用户态 WireGuard，静态二进制 ~3MB）
2. `boringtun` 支持 Reserved 字段
3. 运行时内存仍远低于 warp-cli 的 150MB

### Team 隧道协议要求

Zero Trust Dashboard 的 Device Profile 中，隧道协议必须设为 **WireGuard**（而非默认的 MASQUE）。MASQUE 使用 HTTP/3 协议，与标准 WireGuard 客户端不兼容。

管理员设置路径：Zero Trust Dashboard → Settings → WARP Client → Device Profiles → Tunnel protocol → WireGuard

## 前提条件

1. 用户有 Cloudflare Zero Trust 账户（50 用户免费计划即可）
2. Team 的 Device Profile 隧道协议设为 WireGuard
3. Access Policy 已配置允许用户邮箱注册
4. 用户能通过浏览器完成一次 Team 认证获取 JWT Token
