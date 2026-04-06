# MicroWARP Team (Zero Trust) 实现文档

## 概述

本文档详细记录了 MicroWARP 项目支持 Cloudflare WARP Team (Zero Trust) 模式的完整实现过程，
包括技术架构、核心挑战、调试过程和最终解决方案。

---

## 1. 技术背景

### 1.1 WARP 免费模式 vs Team 模式

| 对比项 | 免费 WARP | Team (Zero Trust) |
|--------|----------|-------------------|
| 注册方式 | `wgcf register` | Zero Trust API + JWT |
| 出口 IP 质量 | 普通（共享池） | 更高质量（Team 池） |
| CF Trace 标识 | `warp=on` | `warp=plus` |
| Reserved 字节 | 不需要 | **必须注入** |
| WireGuard 实现 | 内核模块即可 | 需要 wireguard-go（用户态） |

### 1.2 Reserved 字节是什么？

WireGuard 协议的每个数据包前 4 个字节结构为：

```
Byte 0: 消息类型 (1=握手发起, 2=握手响应, 3=Cookie回复, 4=传输数据)
Byte 1-3: Reserved（标准 WireGuard 固定为 0x000000）
```

Cloudflare 将 **字节 1-3** 复用为设备标识符（`client_id`），用于：
- 识别该连接属于哪个 Team 账户
- 将流量路由到正确的 Team 策略引擎
- 区分免费 WARP 和 Team 流量

### 1.3 client_id 与 Reserved 字节的关系

Team API 注册设备后返回 `client_id`（Base64 编码，解码后恰好 3 字节）：

```
client_id = "SaBN"
Base64 解码 → 0x49 0xA0 0x4D → 十进制 73, 160, 77
Reserved 字节 = [73, 160, 77]
```

---

## 2. 整体架构

### 2.1 改动文件清单

| 文件 | 改动内容 |
|------|---------|
| `Dockerfile` | 增加 `jq` 依赖；打包 `wireguard-go-reserved` 二进制 |
| `entrypoint.sh` | 新增 `register_team()` 函数；wg-quick 补丁逻辑 |
| `wireguard-go-reserved` | 基于上游 wireguard-go 的定制 fork（ARM64 交叉编译） |

### 2.2 数据流

```
容器启动
  │
  ├─ 检测 TEAM_TOKEN 环境变量？
  │   ├─ 否 → 走免费 WARP 流程 (wgcf register)
  │   └─ 是 → register_team()
  │           │
  │           ├─ 1. 生成 WireGuard 密钥对 (wg genkey/pubkey)
  │           ├─ 2. 调用 CF Zero Trust API 注册设备
  │           ├─ 3. 解析响应: peer公钥, endpoint, 地址, client_id
  │           ├─ 4. 提取 endpoint.v4 IP (非 DNS hostname)
  │           ├─ 5. 写入 wg0.conf + team_info
  │           └─ 6. 清理私钥变量
  │
  ├─ 配置清洗 (IPv4/IPv6 地址、AllowedIPs、PersistentKeepalive)
  │
  ├─ 检测 team_info 文件？
  │   ├─ 否 → 内核 WireGuard (wg-quick up wg0)
  │   └─ 是 → wireguard-go 用户态实现
  │           ├─ export WG_RESERVED="73,160,77"
  │           ├─ sed 补丁 wg-quick 的 add_if() 函数
  │           └─ wg-quick up wg0 (调用 wireguard-go)
  │
  └─ 启动 microsocks SOCKS5 代理
```

---

## 3. wireguard-go 定制改动

基于上游 `golang.zx2c4.com/wireguard` 的 4 个文件修改：

### 3.1 device/device.go — 增加 DefaultReserved 字段

```go
type Device struct {
    // ... 原有字段 ...
    DefaultReserved [3]byte  // 新增：设备级别的默认 Reserved 字节
}
```

### 3.2 device/peer.go — Peer 创建时继承 + SendBuffers 注入

```go
// NewPeer() 中复制设备默认值到 peer
peer.reserved = device.DefaultReserved

// SendBuffers() 中在发送前注入 Reserved 字节（所有消息类型 1-4）
func (peer *Peer) SendBuffers(buffers [][]byte) error {
    // ... endpoint 处理 ...

    // 在网络发送前注入 Reserved 字节
    for i := range buffers {
        if len(buffers[i]) > 3 && buffers[i][0] > 0 && buffers[i][0] < 5 {
            copy(buffers[i][1:4], peer.reserved[:])
        }
    }

    err := peer.device.net.bind.Send(buffers, endpoint)
    // ...
}
```

### 3.3 device/receive.go — 接收端 MAC 验证前清零

```go
case MessageInitiationType, MessageResponseType:
    // 清零 Reserved 字节后再验证 MAC（MAC 是基于标准零值计算的）
    var savedReserved [3]byte
    copy(savedReserved[:], elem.packet[1:4])
    elem.packet[1] = 0
    elem.packet[2] = 0
    elem.packet[3] = 0

    if !device.cookieChecker.CheckMAC1(elem.packet) {
        device.log.Verbosef("Received packet with invalid mac1")
        goto skip
    }
```

### 3.4 main.go — WG_RESERVED 环境变量解析

```go
device := device.NewDevice(tdev, conn.NewDefaultBind(), logger)

if reservedStr := os.Getenv("WG_RESERVED"); reservedStr != "" {
    parts := strings.Split(reservedStr, ",")
    if len(parts) == 3 {
        var reserved [3]byte
        for i, p := range parts {
            v, _ := strconv.ParseUint(strings.TrimSpace(p), 10, 8)
            reserved[i] = byte(v)
        }
        device.DefaultReserved = reserved
    }
}
```

---

## 4. 调试过程（核心踩坑记录）

整个 Team 模式的调试经历了 **4 个关键问题**，耗时数小时，以下按发现顺序记录。

### 4.1 问题一：wg-quick 忽略 WG_QUICK_USERSPACE_IMPLEMENTATION

**现象：** 设置 `export WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go` 后，wg-quick 仍然使用内核 WireGuard 模块，完全不调用 wireguard-go。

**根因：** wg-quick 的该环境变量仅作为 **FALLBACK** 机制 — 只有在 `ip link add type wireguard` 失败（即内核模块不存在）时才会触发。ARM64 服务器的内核已加载 wireguard 模块，`ip link add` 成功，wireguard-go 永远不会被调用。

**解决方案：** 用 sed 在 wg-quick 的 `add_if()` 函数开头注入一行，强制检查环境变量：

```bash
sed -i '/^add_if() {$/a\\t[[ -n $WG_QUICK_USERSPACE_IMPLEMENTATION ]] \&\& { cmd "$WG_QUICK_USERSPACE_IMPLEMENTATION" "$INTERFACE"; return; }' /usr/bin/wg-quick
```

### 4.2 问题二：Endpoint IP 不匹配

**现象：** 使用 `engage.cloudflareclient.com` DNS 解析的 IP 进行握手时，内核 WireGuard（无 Reserved 字节）可以连接，但 wireguard-go + Reserved 字节无法完成握手。

**根因：** Team API 返回的 endpoint 结构包含多个字段：

```json
{
  "v4": "162.159.193.3:0",        // API 分配的特定 IP
  "v6": "[2606:4700:100::a29f:c103]:0",
  "host": "engage.cloudflareclient.com:2408",  // 通用 DNS 名
  "ports": [2408, 500, 1701, 4500]
}
```

DNS 解析 `engage.cloudflareclient.com` → `162.159.192.1`（通用入口），但 Team 设备被绑定到 `162.159.193.3`（特定入口）。**必须使用 `endpoint.v4` 的 IP，不能用 DNS hostname。**

**解决方案：** `register_team()` 中提取 `endpoint.v4` 的 IP 和 `endpoint.host` 的端口组合：

```bash
TEAM_EP_PORT=$(echo "$ENDPOINT_HOST" | sed 's/.*://')
TEAM_EP_IP=$(echo "$ENDPOINT_V4" | sed 's/:0$//')
ENDPOINT="${TEAM_EP_IP}:${TEAM_EP_PORT}"
```

### 4.3 问题三：Reserved 字节注入导致握手失败（核心难题）

**现象：** wireguard-go + `WG_RESERVED=0,0,0` → 握手成功，正常连接；
wireguard-go + `WG_RESERVED=73,160,77` → 0 B received，握手超时。

**验证矩阵：**

| WireGuard 实现 | Reserved 字节 | 结果 |
|---------------|-------------|------|
| 内核模块 | 无 | 握手成功，`warp=plus` |
| wireguard-go | 0,0,0 | 握手成功，`warp=plus` |
| wireguard-go | 73,160,77 | **握手失败，0 B received** |

**调试手段：**

1. **tcpdump 抓包验证**：确认 Reserved 字节在线路上格式正确
   ```
   UDP payload: 01 49 A0 4D ...
   Byte 0 = 0x01 (握手发起)
   Bytes 1-3 = 0x49 0xA0 0x4D (Reserved = 73,160,77) ✓
   ```

2. **启用 wireguard-go 的 verbose 日志**：`export LOG_LEVEL=verbose`

3. **关键日志发现**：
   ```
   Reserved inject: type=1 bytes=73,160,77
   Received packet with invalid mac1          ← 关键线索！
   ```

**这行日志彻底揭示了 bug：** Cloudflare 服务器 **确实回复了** 握手响应，但客户端在验证响应的 MAC1 时失败了。

**根因分析：**

WireGuard 的 MAC1 计算流程：
```
MAC1 = BLAKE2s(HASH("mac1----" || server_public_key), packet_without_macs)
```

关键：`packet_without_macs` 包含字节 0-3（消息类型 + Reserved）。

- **发送端**：客户端在字节 1-3 为 0 时计算 MAC1，然后覆写为 Reserved 字节
- **接收端 (Cloudflare)**：收到包后，将字节 1-3 清零，验证 MAC1 → 通过
- **接收端 (我们的客户端)**：收到 Cloudflare 的响应后...
  - 响应包的字节 1-3 也包含 Reserved 字节
  - 我们的 `CheckMAC1()` 直接用包含 Reserved 字节的 packet 计算 MAC
  - 计算结果 ≠ 服务器用 0 值计算的 MAC → **验证失败！**

**最终修复：** 在 `receive.go` 的 `CheckMAC1()` 调用前，将接收包的字节 1-3 清零：

```go
// 清零 Reserved 字节（因为 MAC 是基于标准零值计算的）
elem.packet[1] = 0
elem.packet[2] = 0
elem.packet[3] = 0

if !device.cookieChecker.CheckMAC1(elem.packet) { ... }
```

### 4.4 问题四：变量名冲突导致容器崩溃循环

**现象：** 全新注册流程可以成功注册设备，但容器随即进入 crash loop。

**根因：** `register_team()` 函数中定义了变量 `ENDPOINT_IP`（用于提取 API 返回的 v4 IP），但 shell 函数中的变量默认是全局作用域。后续 entrypoint.sh 主流程中有这段代码：

```bash
# 行 209: 如果用户设置了自定义 Endpoint IP
if [ -n "$ENDPOINT_IP" ]; then
    sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP/g" "$WG_CONF"
fi
```

函数内泄漏的 `ENDPOINT_IP=162.159.193.7`（不含端口号）触发了这个覆盖逻辑，把 wg0.conf 中的 Endpoint 改成了无端口的纯 IP，导致 wg-quick 连接失败。

**修复：** 将变量重命名为 `TEAM_EP_IP`，避免与用户级环境变量冲突。

---

## 5. 注入时序图解

### 5.1 发送路径（正确的时序）

```
握手发起包 (Type 1):
  1. marshal(msg) → packet[0:4] = [0x01, 0x00, 0x00, 0x00]
  2. AddMacs(packet) → 基于 0x00 计算 MAC1/MAC2
  3. SendBuffers() → copy(packet[1:4], reserved) → [0x01, 0x49, 0xA0, 0x4D]
  4. bind.Send() → 发送到 Cloudflare

传输数据包 (Type 4):
  1. PutUint32(fieldType, 4) → [0x04, 0x00, 0x00, 0x00]
  2. AEAD 加密 payload（不涉及头部认证）
  3. SendBuffers() → copy(packet[1:4], reserved) → [0x04, 0x49, 0xA0, 0x4D]
  4. bind.Send() → 发送到 Cloudflare
```

### 5.2 接收路径（正确的时序）

```
收到 Cloudflare 响应 (Type 2):
  1. 读取 packet[:4] & 0xFF → msgType = 2 (忽略 Reserved 字节)
  2. 清零 packet[1:3] → [0x02, 0x00, 0x00, 0x00]
  3. CheckMAC1(packet) → 基于 0x00 验证 → 通过
  4. unmarshal(packet) → 处理握手响应
```

### 5.3 错误的实现 vs 正确的实现

```
❌ 错误 (注入在 MAC 之前):
  marshal → inject Reserved → AddMacs(含 Reserved) → Send
  接收时: CheckMAC1(含 Reserved) → ❌ 不匹配

❌ 错误 (只修发送端，不修接收端):
  marshal → AddMacs(不含 Reserved) → inject → Send
  接收时: CheckMAC1(含 Reserved) → ❌ 不匹配

✅ 正确 (发送端 MAC 后注入 + 接收端 MAC 前清零):
  发送: marshal → AddMacs(不含) → inject → Send
  接收: 清零 → CheckMAC1(不含) → ✅ 匹配
```

---

## 6. 参考实现对比

本实现参考了 [bepass-org/warp-plus](https://github.com/bepass-org/warp-plus) 的 wireguard-go fork：

| 对比维度 | warp-plus | MicroWARP |
|---------|-----------|-----------|
| Reserved 注入位置 | `SendBuffers()` | `SendBuffers()`（相同） |
| Reserved 来源 | UAPI `reserved=X,Y,Z` | 环境变量 `WG_RESERVED=X,Y,Z` |
| 接收端处理 | 未明确文档化 | 在 `CheckMAC1()` 前清零 |
| client_id 解码 | `base64.StdEncoding.DecodeString` | shell: `echo -n $ID \| base64 -d` |

---

## 7. 编译命令

```bash
# 交叉编译 ARM64 (在 x86_64 主机上)
cd /tmp/wireguard-go
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o wireguard-go-reserved .

# 编译 AMD64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w" -o wireguard-go-reserved .
```

`-ldflags="-s -w"` 去除符号表和调试信息，二进制约 3.1MB。

---

## 8. 验证方法

### 8.1 确认 WARP 连通性

```bash
# 在容器内或通过 SOCKS5 代理
curl -s https://1.1.1.1/cdn-cgi/trace | grep -E "warp=|gateway="

# 期望输出
warp=plus       # Team 模式
gateway=off     # 需在 CF Dashboard 启用 Gateway 策略才会变为 on
```

### 8.2 确认 Reserved 字节注入

```bash
# 在宿主机上抓包
tcpdump -i any -c 3 'udp dst port 2408' -xx -n

# 查看 UDP payload 的前 4 字节
# 握手发起: 01 XX YY ZZ (XX YY ZZ = Reserved 字节)
# 传输数据: 04 XX YY ZZ
```

### 8.3 确认 wg 隧道状态

```bash
docker exec microwarp wg show

# 关键指标:
# latest handshake: N seconds ago  (< 120s 说明正常)
# transfer: X KiB received, Y KiB sent  (received > 0 说明双向通信正常)
```

---

## 9. 已知限制

1. **gateway=off**：CF Trace 中 `gateway=off` 并非 bug — 需要在 Cloudflare Zero Trust Dashboard 中配置 Gateway 策略（DNS/HTTP 过滤规则）才会变为 `on`。这是账户配置，不是客户端问题。

2. **JWT Token 有效期**：Team Token (JWT) 有 24 小时有效期，但仅用于首次注册。注册成功后 WireGuard 密钥对持久化，Token 过期不影响已有连接。

3. **设备注册限制**：每次使用 Token 注册会创建一个新设备。Cloudflare 免费 Team 计划限制 50 个设备。如需清理，可在 Zero Trust Dashboard → My Team → Devices 中管理。

4. **多架构支持**：`wireguard-go-reserved` 二进制需要按目标架构编译。当前仓库中包含 ARM64 版本，AMD64 环境需要重新编译。
