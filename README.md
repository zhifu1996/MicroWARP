# MicroWARP

[![Build](https://github.com/zhifu1996/MicroWARP/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/zhifu1996/MicroWARP/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> *请严格遵守您所在国家和地区的法律法规。任何因违法违规使用本项目而引发的法律纠纷或后果，均与本项目及作者无关。*

极简、高性能的 Cloudflare WARP SOCKS5 Docker 代理，支持免费模式与 Team (Zero Trust) 模式。

---

## 性能对比

在 1C1G (1 vCPU / 1GB RAM) 服务器上的真实运行数据，对比市面常用的 `caomingjun/warp`：

| 指标 | `caomingjun/warp` | MicroWARP | 提升 |
| :--- | :--- | :--- | :--- |
| Docker 镜像体积 | 201 MB | **9 MB** | **-95%** |
| 日常内存占用 | ~150 MB | **800 KiB** (< 1MB) | **-99.4%** |
| 高并发 CPU 损耗 | 高 (用户态) | **~0.25%** (内核态) | 近乎为零 |
| 底层引擎 | Cloudflare `warp-cli` (Rust) | Linux `wg0` + 纯 C `microsocks` | 极简架构 |

> 实测 `docker stats` 输出：
> ```
> CONTAINER ID   NAME       CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O
> 2fa58f84c517   warp       0.25%     800KiB / 967.4MiB     0.08%     48.8MB / 39.1MB   238kB / 36.9kB
> ```
> 仅使用 **800 KB** 内存就处理了约 90 MB 的流量。

---

## 为什么选择 MicroWARP

市面上大多数 WARP 镜像依赖 Cloudflare 官方的 `warp-cli` 守护进程，内存占用约 150MB+，高并发下存在性能瓶颈。

MicroWARP 采用完全不同的底层架构：

- **内核级 WireGuard** — 使用 Linux 原生 `wg0` 内核网卡接管流量，CPU 损耗近乎为零
- **MicroSOCKS 引擎** — 纯 C 语言编写的 SOCKS5 代理，极低资源消耗
- **极低内存占用** — 高并发下仍然 < 5MB（常驻 ~800KB），专为低配 VPS 设计
- **原生兼容 Tailscale** — 智能保留回程路由，解决 WARP 全局接管导致的非对称路由黑洞
- **多架构支持** — 原生 `amd64` + `arm64`，GitHub Actions 自动构建
- **Team 模式** — 支持 Cloudflare Zero Trust，获取更高质量的出口 IP (`warp=plus`)

---

## 典型应用场景

> 本项目专为服务端 (Server-side) 设计，并非个人电脑本地代理软件。

- **API 网络路由** — 为爬虫或大模型 API 网关（Grok / ChatGPT）提供稳定的 Cloudflare 出口 IP
- **服务端出口隐私** — 隐藏 VPS 真实 IP，降低溯源扫描风险
- **微服务 Sidecar** — 极低资源占用，适合作为 Docker Sidecar 提供独立网络出口

---

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/zhifu1996/MicroWARP/main/install.sh | sh
```

自动完成：检测 Docker 环境 -> 生成配置 -> 拉取镜像 -> 启动容器 -> 安装管理脚本

默认安装到 `/opt/microwarp/`，SOCKS5 代理监听 `127.0.0.1:1080`。

重复执行时自动更新镜像，不覆盖已有配置。

---

## 手动部署

新建 `docker-compose.yml`：

```yaml
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
    volumes:
      - warp-data:/etc/wireguard    # 持久化保存账号凭证

volumes:
  warp-data:
```

```bash
docker compose up -d
```

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TEAM_TOKEN` | 空 | Cloudflare Teams JWT Token，设置后自动切换为 Team 模式 |
| `BIND_ADDR` | `0.0.0.0` | SOCKS5 监听地址 |
| `BIND_PORT` | `1080` | SOCKS5 监听端口 |
| `SOCKS_USER` | 空 | SOCKS5 认证用户名，留空则为无密码模式 |
| `SOCKS_PASS` | 空 | SOCKS5 认证密码，需与 `SOCKS_USER` 同时设置 |
| `ENDPOINT_IP` | 自动 | 自定义 WARP 节点 IP:Port，用于绕过部分机房的 UDP 限制 |
| `GH_PROXY` | 空 | GitHub 代理前缀，加速 `wgcf` 二进制下载 |
| `TAILSCALE_CIDR` | `100.64.0.0/10` | Tailscale 回程路由 CIDR，非 Tailscale 场景无需设置 |

配置示例：

```yaml
    environment:
      - BIND_PORT=1080
      - SOCKS_USER=admin
      - SOCKS_PASS=123456
      # 针对 UDP 2408 被 QoS 限制的机房，使用 4500 端口绕过
      - ENDPOINT_IP=162.159.192.1:4500
```

---

## WARP Team (Zero Trust) 模式

Team 模式使用 Cloudflare Zero Trust 注册设备，获取更高质量的出口 IP 池 (`warp=plus`)。

底层通过定制的 `wireguard-go` 注入 Reserved 字节实现 Team 设备标识，内存占用与免费模式一致。

### 前提条件

1. 拥有 Cloudflare Zero Trust 账户（50 用户免费计划即可）
2. Device Profile 隧道协议设为 **WireGuard**（非 MASQUE）
   - 路径：Zero Trust Dashboard -> Settings -> WARP Client -> Device Profiles -> Tunnel protocol

### 获取 Token

1. 浏览器访问 `https://{team-name}.cloudflareaccess.com/warp`
2. 完成组织认证
3. 在成功页面按 F12 打开开发者工具
4. 搜索包含 `com.cloudflare.warp://` 的元素
5. 复制 URL 中 `?token=` 后面的 JWT 字符串

### 配置

```yaml
    environment:
      - TEAM_TOKEN=eyJhbGciOi...你的JWT...
      - SOCKS_USER=admin
      - SOCKS_PASS=123456
```

> Token 仅在首次注册时使用一次。注册成功后 WireGuard 配置持久化到 Docker Volume，后续重启无需 Token。

### 验证

```bash
# 通过 SOCKS5 代理检查 CF Trace
curl -x socks5h://admin:123456@127.0.0.1:1080 https://1.1.1.1/cdn-cgi/trace | grep warp=
# 期望输出: warp=plus
```

---

## 管理脚本

安装脚本会自动下载管理脚本到 `/usr/local/bin/warp`，也可手动下载：

```bash
curl -fsSL -o /usr/local/bin/warp https://raw.githubusercontent.com/zhifu1996/MicroWARP/main/warp.sh
chmod +x /usr/local/bin/warp
```

### 用法

```bash
warp status          # 查看 WARP 状态、出口 IP、当前模式
warp on              # 启用 WARP
warp off             # 关闭 WARP
warp v4              # 切换为纯 IPv4 出口
warp v6              # 切换为纯 IPv6 出口
warp dual            # 双栈模式 (IPv4 优先)
warp dual v6         # 双栈模式 (IPv6 优先)
```

---

## 扩展用法：转换为 HTTP 代理

底层镜像未内置 HTTP 解析引擎以维持极限轻量化。如需 HTTP 代理，推荐使用 `gost` 进行本地协议转换：

```bash
nohup gost -F=socks5://admin:123456@127.0.0.1:1080 -L=http://127.0.0.1:8081 > /dev/null 2>&1 &
```

> 请使用 `socks5://`（而非 `socks5h://`）以由宿主机处理 DNS 解析，避免启动时的解析超时。

---

## 技术架构

```
容器启动
  |
  +-- 检测 TEAM_TOKEN ?
  |     +-- 否 -> wgcf 注册免费 WARP 账号
  |     +-- 是 -> Zero Trust API 注册设备
  |               +-- 生成 WireGuard 密钥对
  |               +-- 调用 CF Teams API
  |               +-- 解析 Reserved 字节 (client_id)
  |               +-- 生成 wg0.conf + team_info
  |
  +-- 配置清洗 (IPv4/IPv6、AllowedIPs、PersistentKeepalive)
  |
  +-- 检测 team_info ?
  |     +-- 否 -> 内核 WireGuard (wg-quick up wg0)
  |     +-- 是 -> wireguard-go 用户态 + Reserved 字节注入
  |
  +-- 启动 microsocks SOCKS5 代理
```

详细技术文档参见 [docs/WARP-Team-Implementation.md](docs/WARP-Team-Implementation.md)。

---

## 构建

项目使用多阶段 Dockerfile 自动编译所有依赖：

1. **阶段 1** — 编译 MicroSOCKS (纯 C)
2. **阶段 2** — 编译 wireguard-go (Go, 含 Reserved 字节补丁)
3. **阶段 3** — 极净运行环境 (Alpine)

```bash
# 本地构建
docker build -t microwarp .

# GitHub Actions 自动构建多架构镜像 (amd64+arm64)
# 推送到 main 分支或发布 Release 时自动触发
```

---

*特别鸣谢 LinuxDo 社区*
