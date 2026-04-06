# ==========================================
# 阶段 1：编译 MicroSOCKS (纯 C)
# ==========================================
FROM alpine:latest AS microsocks-builder
RUN apk add --no-cache build-base git
RUN git clone https://github.com/rofl0r/microsocks.git /src && \
    cd /src && make

# ==========================================
# 阶段 2：编译 wireguard-go (Go, 含 Reserved 字节补丁)
# ==========================================
FROM golang:1.24-alpine AS wireguard-go-builder
RUN apk add --no-cache git patch

# 克隆上游 wireguard-go 并定位到已验证的 commit
RUN git clone https://git.zx2c4.com/wireguard-go /wg && \
    cd /wg && git checkout f333402

# 应用 Reserved 字节补丁 (Team 模式支持)
COPY wireguard-go-reserved.patch /wg/
RUN cd /wg && git apply wireguard-go-reserved.patch

# 编译 (自动适配目标架构 amd64/arm64)
RUN cd /wg && CGO_ENABLED=0 go build -ldflags="-s -w" -o /wireguard-go .

# ==========================================
# 阶段 3：极净运行环境
# ==========================================
FROM alpine:latest

# 仅安装必要的内核级 WireGuard 和网络控制工具
RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl jq

# 打包 microsocks
COPY --from=microsocks-builder /src/microsocks /usr/local/bin/microsocks

# 打包 wireguard-go (patched)
COPY --from=wireguard-go-builder /wireguard-go /usr/local/bin/wireguard-go

WORKDIR /app
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# 启动引擎
CMD ["./entrypoint.sh"]
