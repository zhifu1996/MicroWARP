#!/bin/sh
set -e

build_wgcf_download_url() {
    WGCF_VER=$1
    WGCF_ARCH=$2
    RAW_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WGCF_ARCH}"

    if [ -n "${GH_PROXY:-}" ]; then
        echo "${GH_PROXY%/}/${RAW_URL}"
        return 0
    fi

    echo "$RAW_URL"
}

register_team() {
    TEAM_JWT=$1
    WG_CONF_PATH=$2

    echo "==> [MicroWARP] [Team] 正在通过 Zero Trust API 注册设备..."

    # JWT 格式预校验
    case "$TEAM_JWT" in *.*.*) ;; *) echo "==> [ERROR] TEAM_TOKEN 格式错误，需要有效的 JWT Token"; exit 1 ;; esac

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
        }") || true

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

    # 提取 IPv6 地址 (Team API 可能返回)
    V6_ADDR=$(echo "$HTTP_BODY" | jq -r '.result.config.interface.addresses.v6 // empty')

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
    if [ -n "$V6_ADDR" ]; then
        sed -i "/^Address/a Address = ${V6_ADDR}/128" "$WG_CONF_PATH"
    fi

    # 安全清理：私钥已写入配置文件，从内存中清除
    unset PRIVKEY

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

if [ "${MICROWARP_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

WG_CONF="/etc/wireguard/wg0.conf"
mkdir -p /etc/wireguard

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

# ==========================================
# 2. 强力洗白与内核兼容性处理 (防正则误杀版)
# ==========================================

# 1. 智能提取出纯 IPv4 地址 (防止 wgcf v2.2.30 将双栈 IP 写在同一行导致误杀)
IPV4_ADDR=$(grep '^Address' "$WG_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)

# 1b. 提取 IPv6 地址 (如果存在)
IPV6_ADDR=$(grep '^Address' "$WG_CONF" | tr ',' '\n' | grep ':' | sed 's/.*= *//' | tr -d ' ' | head -n 1)

# 2. 物理删除所有原始的 Address, AllowedIPs, DNS，防止 RTNETLINK 崩溃或 DNS 死锁
sed -i '/^Address/d' "$WG_CONF"
sed -i '/^AllowedIPs/d' "$WG_CONF"
sed -i '/^DNS.*/d' "$WG_CONF"

# 3. 重建最纯净的 IPv4 路由规则
if [ -n "$IPV4_ADDR" ]; then
    sed -i "/\[Interface\]/a Address = $IPV4_ADDR" "$WG_CONF"
fi
if [ -n "$IPV6_ADDR" ]; then
    sed -i "/^Address/a Address = $IPV6_ADDR" "$WG_CONF"
fi
sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"

# 删除 Alpine 系统自带 wg-quick 中不兼容的路由标记
sed -i '/src_valid_mark/d' /usr/bin/wg-quick

# 【新增：抗断流绝杀】强制注入 15 秒 UDP 心跳保活，对抗运营商 QoS 丢包
if ! grep -q "PersistentKeepalive" "$WG_CONF"; then
    sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$WG_CONF"
else
    sed -i 's/PersistentKeepalive.*/PersistentKeepalive = 15/g' "$WG_CONF"
fi

# 【新增：防阻断绝杀】针对 HK/US 强校验机房，注入自定义优选 Endpoint IP
if [ -n "$ENDPOINT_IP" ]; then
    echo "==> [MicroWARP] 检测到自定义 Endpoint IP，正在覆盖默认节点: $ENDPOINT_IP"
    sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP/g" "$WG_CONF"
fi

# 应用用户持久化的出口模式偏好 (由 warp.sh 写入)
WARP_MODE_CONF="/etc/wireguard/warp-mode.conf"
if [ -f "$WARP_MODE_CONF" ]; then
    . "$WARP_MODE_CONF"
    case "${MODE:-v4}" in
        v6)
            sed -i '/^AllowedIPs/d' "$WG_CONF"
            sed -i "/\[Peer\]/a AllowedIPs = ::\/0" "$WG_CONF"
            echo "==> [MicroWARP] 出口模式: 纯 IPv6"
            ;;
        dual)
            sed -i '/^AllowedIPs/d' "$WG_CONF"
            sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0, ::\/0" "$WG_CONF"
            echo "==> [MicroWARP] 出口模式: 双栈 (${PRIORITY:-v4} 优先)"
            ;;
        *)
            echo "==> [MicroWARP] 出口模式: 纯 IPv4"
            ;;
    esac
fi

# ==========================================
# 3. 拉起内核网卡
# ==========================================
# 在启用 WARP 前记录 100.64.0.0/10 的原始回程路径，避免发布端口后 Tailscale 客户端握手卡死
PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

echo "==> [MicroWARP] 正在启动 Linux 内核级 wg0 网卡..."

# Team 模式：使用 wireguard-go 注入 Reserved 字节
TEAM_INFO="/etc/wireguard/team_info"
if [ -f "$TEAM_INFO" ]; then
    . "$TEAM_INFO"
    if [ -n "${reserved_dec:-}" ]; then
        echo "==> [MicroWARP] [Team] 检测到 Reserved 字节，切换至 wireguard-go 用户态实现"
        export WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go
        export WG_RESERVED="$reserved_dec"
    fi
fi

wg-quick up wg0 > /dev/null 2>&1

# 双栈模式下应用路由优先级
if [ -f "$WARP_MODE_CONF" ] && [ "${MODE:-}" = "dual" ]; then
    if [ "${PRIORITY:-v4}" = "v6" ]; then
        ip -4 route replace default dev wg0 metric 20 2>/dev/null || true
        ip -6 route replace default dev wg0 metric 10 2>/dev/null || true
    else
        ip -4 route replace default dev wg0 metric 10 2>/dev/null || true
        ip -6 route replace default dev wg0 metric 20 2>/dev/null || true
    fi
fi

# 仅在 WARP 启动前确实存在原始回程路径时恢复 100.64.0.0/10，减少对非 Tailscale 场景的影响
TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
    if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
        echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由: via ${PRE_WARP_GW} dev ${PRE_WARP_DEV}"
    fi
fi

echo "==> [MicroWARP] 当前出口 IP 已成功变更为："
# 获取最新的 CF 溯源 IP (加入 5 秒强制超时，完美替代有缺陷的 & 后台执行)
curl -s -m 5 https://1.1.1.1/cdn-cgi/trace | grep ip= || echo "⚠️ 获取超时 (可能是底层握手延迟或节点被强阻断)"

# ==========================================
# 4. 启动 C 语言 SOCKS5 代理服务 (带高级参数绑定)
# ==========================================
# 读取环境变量，如果未设置则使用默认值 0.0.0.0 和 1080
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    echo "==> [MicroWARP] 🔒 身份认证已开启 (User: $SOCKS_USER)"
    echo "==> [MicroWARP] 🚀 MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    # 使用 exec 接管进程，实现 Zero-Overhead 的底层进程控制
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
else
    echo "==> [MicroWARP] ⚠️ 未设置密码，当前为公开访问模式"
    echo "==>[MicroWARP] 🚀 MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
fi
