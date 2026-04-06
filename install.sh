#!/bin/sh
set -e

# ==========================================
# MicroWARP 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/zhifu1996/MicroWARP/main/install.sh | sh
# ==========================================

INSTALL_DIR="${INSTALL_DIR:-/opt/microwarp}"
IMAGE="ghcr.io/zhifu1996/microwarp:latest"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
WARP_SH="$INSTALL_DIR/warp.sh"

info()  { echo "==> [MicroWARP] $1"; }
error() { echo "==> [ERROR] $1" >&2; exit 1; }

# 检测 Docker
command -v docker >/dev/null 2>&1 || error "未检测到 Docker，请先安装: https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1 || error "未检测到 Docker Compose"

# 检测已有安装
if [ -f "$COMPOSE_FILE" ]; then
    info "检测到已有安装 ($INSTALL_DIR)"
    info "更新镜像..."
    cd "$INSTALL_DIR"
    docker compose pull 2>/dev/null || docker-compose pull
    docker compose up -d 2>/dev/null || docker-compose up -d
    info "更新完成!"
    exit 0
fi

info "安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 生成 docker-compose.yml
cat > "$COMPOSE_FILE" <<'COMPEOF'
services:
  microwarp:
    image: ghcr.io/zhifu1996/microwarp:latest
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    # environment:
    #   # ---- WARP Team (Zero Trust) 模式 ----
    #   # 设置 TEAM_TOKEN 后自动切换为 Team 模式，获取更高质量的出口 IP
    #   # 获取方式: 浏览器访问 https://{team-name}.cloudflareaccess.com/warp 完成认证后提取 JWT
    #   - TEAM_TOKEN=eyJhbGciOi...
    #
    #   # ---- 通用配置 ----
    #   - BIND_ADDR=0.0.0.0           # SOCKS5 监听地址
    #   - BIND_PORT=1080              # SOCKS5 监听端口
    #   - SOCKS_USER=admin            # SOCKS5 认证用户名
    #   - SOCKS_PASS=123456           # SOCKS5 认证密码
    #   - ENDPOINT_IP=162.159.192.1:4500  # 自定义 WARP 节点 IP
    volumes:
      - warp-data:/etc/wireguard

volumes:
  warp-data:
COMPEOF

info "docker-compose.yml 已生成"

# 下载管理脚本
WARP_SH_URL="https://raw.githubusercontent.com/zhifu1996/MicroWARP/main/warp.sh"
if curl -fsSL -o "$WARP_SH" "$WARP_SH_URL" 2>/dev/null || wget -qO "$WARP_SH" "$WARP_SH_URL" 2>/dev/null; then
    chmod +x "$WARP_SH"
    # 安装到 PATH
    ln -sf "$WARP_SH" /usr/local/bin/warp 2>/dev/null || true
    info "管理脚本已安装: warp {on|off|v4|v6|dual|status}"
else
    info "管理脚本下载失败 (非必需，可稍后手动下载)"
fi

# 启动容器
cd "$INSTALL_DIR"
info "正在拉取镜像并启动..."
docker compose pull 2>/dev/null || docker-compose pull
docker compose up -d 2>/dev/null || docker-compose up -d

info "安装完成!"
echo ""
echo "  SOCKS5 代理: 127.0.0.1:1080"
echo "  管理命令:    warp status"
echo "  配置文件:    $COMPOSE_FILE"
echo ""
echo "  如需 Team 模式: 编辑 $COMPOSE_FILE 取消 TEAM_TOKEN 注释"
echo "  然后运行: cd $INSTALL_DIR && docker compose down -v && docker compose up -d"
