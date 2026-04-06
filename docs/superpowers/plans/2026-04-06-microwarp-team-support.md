# MicroWARP Team 支持实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 MicroWARP 支持 Cloudflare WARP Team (Zero Trust)，通过环境变量 `TEAM_TOKEN` 切换模式，直接调用 Teams API 注册设备并生成 WireGuard 配置。

**Architecture:** 在 `entrypoint.sh` 第 1 段（账号注册）中增加 `TEAM_TOKEN` 分支。当 `TEAM_TOKEN` 非空时，用 `wg genkey` 生成密钥对，调用 `zero-trust-client.cloudflareclient.com` API 注册设备，解析 JSON 响应构建 `wg0.conf`。第 2-4 段（配置洗白、内核网卡、SOCKS5）完全不动。

**Tech Stack:** Shell (POSIX sh), curl, jq, wireguard-tools (wg genkey/pubkey), Docker/Alpine

**Spec:** `docs/superpowers/specs/2026-04-06-microwarp-team-support-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Dockerfile` | Modify line 17 | 在 `apk add` 中增加 `jq` |
| `entrypoint.sh` | Modify lines 24-55 | 增加 Team 注册函数和分支逻辑 |
| `docker-compose.yml` | Modify lines 15-23 | 在注释块中增加 `TEAM_TOKEN` 示例 |

---

### Task 1: Dockerfile 增加 jq 依赖

**Files:**
- Modify: `Dockerfile:17`

- [ ] **Step 1: 修改 apk add 行**

将 `Dockerfile` 第 17 行：

```dockerfile
RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl
```

改为：

```dockerfile
RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl jq
```

- [ ] **Step 2: 验证 Docker 构建**

```bash
cd /root/warp && docker build -t microwarp-test:local .
```

Expected: 构建成功，最后一行类似 `Successfully tagged microwarp-test:local`

- [ ] **Step 3: 验证 jq 可用**

```bash
docker run --rm microwarp-test:local sh -c "jq --version"
```

Expected: 输出 `jq-1.7.1` 或类似版本号

- [ ] **Step 4: 提交**

```bash
git add Dockerfile
git commit -m "feat: add jq dependency for Team API JSON parsing"
```

---

### Task 2: entrypoint.sh 增加 Team 注册函数

**Files:**
- Modify: `entrypoint.sh:4-55`

- [ ] **Step 1: 在 `build_wgcf_download_url` 函数后添加 `register_team` 函数**

在 `entrypoint.sh` 第 15 行（`build_wgcf_download_url` 函数的结束 `}` 之后）和第 17 行（`MICROWARP_TEST_MODE` 检查之前）之间插入以下函数：

```sh
register_team() {
    TEAM_JWT=$1
    WG_CONF_PATH=$2

    echo "==> [MicroWARP] [Team] 正在通过 Zero Trust API 注册设备..."

    # 生成 WireGuard 密钥对
    PRIVKEY=$(wg genkey)
    PUBKEY=$(echo "$PRIVKEY" | wg pubkey)

    # 调用 Cloudflare Teams 注册 API
    RESPONSE=$(curl -s -m 15 -w "\n%{http_code}" -X POST \
        "https://zero-trust-client.cloudflareclient.com/v0i2308311933/reg" \
        -H "User-Agent: 1.1.1.1/6.23" \
        -H "CF-Client-Version: i-6.23-2308311933.1" \
        -H "Content-Type: application/json" \
        -H "Cf-Access-Jwt-Assertion: $TEAM_JWT" \
        -d "{
            \"key\": \"$PUBKEY\",
            \"tos\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
            \"model\": \"iPad13,8\",
            \"fcm_token\": \"\",
            \"device_token\": \"\"
        }")

    # 分离 HTTP body 和状态码
    HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
    HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

    # 检查 HTTP 状态码
    case "$HTTP_CODE" in
        200) ;;
        401|403)
            echo "==> [ERROR] Team Token 无效或已过期 (HTTP $HTTP_CODE)，请重新获取"
            echo "==> [ERROR] 获取方式: 浏览器访问 https://{team-name}.cloudflareaccess.com/warp"
            exit 1
            ;;
        000)
            echo "==> [ERROR] 网络连接超时，无法访问 Cloudflare Teams API"
            exit 1
            ;;
        *)
            echo "==> [ERROR] Teams API 返回错误 (HTTP $HTTP_CODE):"
            echo "$HTTP_BODY"
            exit 1
            ;;
    esac

    # 检查 API 是否返回成功
    API_SUCCESS=$(echo "$HTTP_BODY" | jq -r '.success // empty')
    if [ "$API_SUCCESS" != "true" ]; then
        echo "==> [ERROR] Teams API 返回失败:"
        echo "$HTTP_BODY" | jq -r '.errors[]? // empty'
        exit 1
    fi

    # 解析响应中的关键字段
    PEER_PUB=$(echo "$HTTP_BODY" | jq -r '.result.config.peers[0].public_key // empty')
    ENDPOINT=$(echo "$HTTP_BODY" | jq -r '.result.config.peers[0].endpoint.host // empty')
    V4_ADDR=$(echo "$HTTP_BODY" | jq -r '.result.config.interface.addresses.v4 // empty')
    CLIENT_ID=$(echo "$HTTP_BODY" | jq -r '.result.config.client_id // empty')
    ACCT_TYPE=$(echo "$HTTP_BODY" | jq -r '.result.account.account_type // empty')

    # 验证必要字段
    if [ -z "$PEER_PUB" ] || [ -z "$ENDPOINT" ] || [ -z "$V4_ADDR" ]; then
        echo "==> [ERROR] API 响应格式异常，缺少必要的 WireGuard 配置字段"
        echo "==> [DEBUG] peer_pub=$PEER_PUB endpoint=$ENDPOINT v4=$V4_ADDR"
        exit 1
    fi

    echo "==> [MicroWARP] [Team] 设备注册成功! (account_type=$ACCT_TYPE)"

    # 生成 wg0.conf
    cat > "$WG_CONF_PATH" <<WGEOF
[Interface]
PrivateKey = $PRIVKEY
Address = ${V4_ADDR}/32

[Peer]
PublicKey = $PEER_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = $ENDPOINT
WGEOF

    # 保存 Team 信息 (client_id 用于 Reserved 字节，备用)
    if [ -n "$CLIENT_ID" ]; then
        RESERVED_HEX=$(echo -n "$CLIENT_ID" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')
        RESERVED_DEC=$(echo -n "$CLIENT_ID" | base64 -d 2>/dev/null | od -An -tu1 | tr -s ' ' ',' | sed 's/^,//;s/,$//')
        TEAM_INFO_PATH="$(dirname "$WG_CONF_PATH")/team_info"
        cat > "$TEAM_INFO_PATH" <<TIEOF
client_id=$CLIENT_ID
reserved_hex=$RESERVED_HEX
reserved_dec=$RESERVED_DEC
TIEOF
        echo "==> [MicroWARP] [Team] Reserved 字节: hex=0x${RESERVED_HEX} dec=${RESERVED_DEC}"
    fi

    echo "==> [MicroWARP] [Team] WireGuard 配置生成完毕!"
}
```

- [ ] **Step 2: 修改第 1 段的分支逻辑**

将 `entrypoint.sh` 第 24-55 行的注册段落：

```sh
# ==========================================
# 1. 账号全自动申请与配置生成 (阅后即焚)
# ==========================================
if [ ! -f "$WG_CONF" ]; then
    echo "==> [MicroWARP] 未检测到配置，正在全自动初始化 Cloudflare WARP..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) echo "==> [ERROR] 不支持的架构: $ARCH"; exit 1 ;;
    esac

    WGCF_VER=$(curl -sL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    echo "==> [MicroWARP] 检测到最新 wgcf 版本: v${WGCF_VER}"
    wget --timeout=15 -qO wgcf "$(build_wgcf_download_url "$WGCF_VER" "$WGCF_ARCH")"
    chmod +x wgcf

    echo "==> [MicroWARP] 正在向 CF 注册设备..."
    ./wgcf register --accept-tos > /dev/null

    echo "==> [MicroWARP] 正在生成 WireGuard 配置文件..."
    ./wgcf generate > /dev/null

    mv wgcf-profile.conf "$WG_CONF"

    # 【核心安全】阅后即焚：删除注册工具和生成的账号明文文件
    rm -f wgcf wgcf-account.toml
    echo "==> [MicroWARP] 节点配置生成成功！"
else
    echo "==> [MicroWARP] 检测到已有持久化配置，跳过注册。"
fi
```

替换为：

```sh
# ==========================================
# 1. 账号全自动申请与配置生成 (阅后即焚)
# ==========================================
if [ -f "$WG_CONF" ]; then
    echo "==> [MicroWARP] 检测到已有持久化配置，跳过注册。"
elif [ -n "${TEAM_TOKEN:-}" ]; then
    # ---- Team (Zero Trust) 模式 ----
    echo "==> [MicroWARP] 检测到 TEAM_TOKEN，进入 Zero Trust 注册模式..."
    register_team "$TEAM_TOKEN" "$WG_CONF"
else
    # ---- 免费 WARP 模式 (原有逻辑) ----
    echo "==> [MicroWARP] 未检测到配置，正在全自动初始化 Cloudflare WARP..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) echo "==> [ERROR] 不支持的架构: $ARCH"; exit 1 ;;
    esac

    WGCF_VER=$(curl -sL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    echo "==> [MicroWARP] 检测到最新 wgcf 版本: v${WGCF_VER}"
    wget --timeout=15 -qO wgcf "$(build_wgcf_download_url "$WGCF_VER" "$WGCF_ARCH")"
    chmod +x wgcf

    echo "==> [MicroWARP] 正在向 CF 注册设备..."
    ./wgcf register --accept-tos > /dev/null

    echo "==> [MicroWARP] 正在生成 WireGuard 配置文件..."
    ./wgcf generate > /dev/null

    mv wgcf-profile.conf "$WG_CONF"

    # 【核心安全】阅后即焚：删除注册工具和生成的账号明文文件
    rm -f wgcf wgcf-account.toml
    echo "==> [MicroWARP] 节点配置生成成功！"
fi
```

注意关键变化：
- `if` 条件从 `if [ ! -f "$WG_CONF" ]` 翻转为 `if [ -f "$WG_CONF" ]`（先检查配置存在）
- 新增 `elif [ -n "${TEAM_TOKEN:-}" ]` 分支调用 `register_team`
- `else` 分支保留原有免费 WARP 注册逻辑，一字不改

- [ ] **Step 3: 验证脚本语法**

```bash
sh -n /root/warp/entrypoint.sh
```

Expected: 无输出（语法正确）

- [ ] **Step 4: 提交**

```bash
git add entrypoint.sh
git commit -m "feat: add WARP Team registration via Zero Trust API"
```

---

### Task 3: docker-compose.yml 增加 TEAM_TOKEN 注释

**Files:**
- Modify: `docker-compose.yml:15-23`

- [ ] **Step 1: 在 environment 注释块中增加 TEAM_TOKEN**

将 `docker-compose.yml` 第 15-23 行：

```yaml
    # environment:
    #   - BIND_ADDR=0.0.0.0           # SOCKS5 监听地址，默认 0.0.0.0
    #   - BIND_PORT=1080              # SOCKS5 监听端口，默认 1080
    #   - SOCKS_USER=admin            # SOCKS5 认证用户名，留空则为无密码模式
    #   - SOCKS_PASS=123456           # SOCKS5 认证密码，需与 SOCKS_USER 同时设置
    #   - ENDPOINT_IP=162.159.192.1:4500  # 自定义 WARP 节点 IP，用于绕过 HK/US 机房的 CF reserved 字节阻断
    #   - GH_PROXY=https://github.ednovas.xyz  # GitHub 代理前缀，仅用于加速 wgcf 二进制下载
    #   - TAILSCALE_CIDR=100.64.0.0/10     # Tailscale 回程路由 CIDR，默认 100.64.0.0/10，非 Tailscale 场景无需设置
    #   - MICROWARP_TEST_MODE=0       # 测试模式，设为 1 时跳过所有初始化逻辑，用于 CI/调试
```

替换为：

```yaml
    # environment:
    #   # ---- WARP Team (Zero Trust) 模式 ----
    #   # 设置 TEAM_TOKEN 后自动切换为 Team 模式，获取更高质量的出口 IP
    #   # 获取方式: 浏览器访问 https://{team-name}.cloudflareaccess.com/warp 完成认证后提取 JWT
    #   # 前提: Zero Trust Dashboard 的 Device Profile 隧道协议需设为 WireGuard (非 MASQUE)
    #   - TEAM_TOKEN=eyJhbGciOi...    # Cloudflare Teams JWT Token，留空则走免费 WARP
    #
    #   # ---- 通用配置 ----
    #   - BIND_ADDR=0.0.0.0           # SOCKS5 监听地址，默认 0.0.0.0
    #   - BIND_PORT=1080              # SOCKS5 监听端口，默认 1080
    #   - SOCKS_USER=admin            # SOCKS5 认证用户名，留空则为无密码模式
    #   - SOCKS_PASS=123456           # SOCKS5 认证密码，需与 SOCKS_USER 同时设置
    #   - ENDPOINT_IP=162.159.192.1:4500  # 自定义 WARP 节点 IP，用于绕过 HK/US 机房的 CF reserved 字节阻断
    #   - GH_PROXY=https://github.ednovas.xyz  # GitHub 代理前缀，仅用于加速 wgcf 二进制下载
    #   - TAILSCALE_CIDR=100.64.0.0/10     # Tailscale 回程路由 CIDR，默认 100.64.0.0/10，非 Tailscale 场景无需设置
    #   - MICROWARP_TEST_MODE=0       # 测试模式，设为 1 时跳过所有初始化逻辑，用于 CI/调试
```

- [ ] **Step 2: 验证 YAML 语法**

```bash
docker compose -f /root/warp/docker-compose.yml config > /dev/null 2>&1 && echo "YAML OK" || echo "YAML ERROR"
```

Expected: `YAML OK`

- [ ] **Step 3: 提交**

```bash
git add docker-compose.yml
git commit -m "docs: add TEAM_TOKEN example to docker-compose.yml"
```

---

### Task 4: Docker 构建验证

**Files:**
- No file changes (verification only)

- [ ] **Step 1: 完整 Docker 构建**

```bash
cd /root/warp && docker build -t microwarp-test:local .
```

Expected: 构建成功

- [ ] **Step 2: 验证免费模式不受影响**

```bash
docker run -d \
    --name microwarp-free-test \
    --cap-add NET_ADMIN \
    --cap-add SYS_MODULE \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -p 1080:1080 \
    microwarp-test:local
sleep 15
curl -s -m 10 -x socks5://127.0.0.1:1080 https://1.1.1.1/cdn-cgi/trace
docker logs microwarp-free-test
docker rm -f microwarp-free-test
```

Expected:
- 容器日志显示 `未检测到配置，正在全自动初始化 Cloudflare WARP...`
- curl 返回包含 `warp=on` 的 trace 信息
- 整个免费模式流程无报错

- [ ] **Step 3: 验证 Team 模式错误处理（无效 Token）**

```bash
docker run --rm \
    --cap-add NET_ADMIN \
    --cap-add SYS_MODULE \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e TEAM_TOKEN=invalid_token_for_testing \
    microwarp-test:local 2>&1 || true
```

Expected:
- 容器日志显示 `检测到 TEAM_TOKEN，进入 Zero Trust 注册模式...`
- 容器以错误退出，显示 `Token 无效或已过期` 或 API 错误信息
- 不应出现未处理的异常或空指针错误

- [ ] **Step 4: 提交验证通过的标签**

无需提交，这是纯验证步骤。

---

### Task 5: 更新 README 文档

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 在中文的「进阶配置」段落后添加 Team 模式说明**

在 `README.md` 第 173 行（`- ENDPOINT_IP=162.159.192.1:4500` 那行的 ` ``` ` 之后）插入：

```markdown

### 🔐 WARP Team (Zero Trust) 模式

MicroWARP 支持 Cloudflare WARP Team，获取更高质量的出口 IP（warp=plus），同时保持 800KB 的极低内存占用。

**前提条件：**
1. 拥有 Cloudflare Zero Trust 账户（50 用户免费）
2. Device Profile 隧道协议设为 **WireGuard**（非 MASQUE）
   - 路径：Zero Trust Dashboard → Settings → WARP Client → Device Profiles → Tunnel protocol

**获取 Token：**
1. 浏览器访问 `https://{team-name}.cloudflareaccess.com/warp`
2. 完成组织认证
3. 在成功页面按 F12，找到包含 `com.cloudflare.warp://` 的元素
4. 复制 URL 中 `?token=` 后的 JWT 字符串

**配置示例：**
```yaml
    environment:
      - TEAM_TOKEN=eyJhbGciOi...你的JWT Token...
      - BIND_PORT=1080
      - SOCKS_USER=admin
      - SOCKS_PASS=123456
```

> Token 仅在首次注册时使用一次。注册成功后配置持久化到 Docker Volume，后续重启无需 Token。
```

- [ ] **Step 2: 在英文的「Advanced Configurations」段落后添加对应英文说明**

在 `README.md` 第 101 行（英文 ENDPOINT_IP 配置块的 ` ``` ` 之后）插入：

```markdown

### 🔐 WARP Team (Zero Trust) Mode

MicroWARP supports Cloudflare WARP Team for higher-quality egress IPs (warp=plus) while maintaining the ~800KB memory footprint.

**Prerequisites:**
1. A Cloudflare Zero Trust account (50-user free plan works)
2. Device Profile tunnel protocol set to **WireGuard** (not MASQUE)
   - Path: Zero Trust Dashboard → Settings → WARP Client → Device Profiles → Tunnel protocol

**Getting your Token:**
1. Visit `https://{team-name}.cloudflareaccess.com/warp` in a browser
2. Complete org authentication
3. Press F12, find the element containing `com.cloudflare.warp://`
4. Copy the JWT string after `?token=`

**Configuration:**
```yaml
    environment:
      - TEAM_TOKEN=eyJhbGciOi...your JWT Token...
      - BIND_PORT=1080
      - SOCKS_USER=admin
      - SOCKS_PASS=123456
```

> The token is only used once during initial registration. After successful registration, the config is persisted to the Docker Volume and the token is no longer needed.
```

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "docs: add WARP Team mode documentation"
```
