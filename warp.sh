#!/bin/sh
set -e

CONTAINER="${MICROWARP_CONTAINER:-microwarp}"
WG_CONF="/etc/wireguard/wg0.conf"
MODE_CONF="/etc/wireguard/warp-mode.conf"

die() { echo "ERROR: $1" >&2; exit 1; }

docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
    || die "容器 $CONTAINER 未运行"

run() { docker exec "$CONTAINER" sh -c "$1"; }

show_ip() { run "curl -s -m 5 https://1.1.1.1/cdn-cgi/trace | grep ip=" || true; }

case "${1:-status}" in
    status)
        echo "=== MicroWARP ==="
        WG_OUT=$(run "wg show wg0 2>/dev/null" || true)
        if [ -n "$WG_OUT" ]; then
            echo "wg0: UP"
            echo "$WG_OUT" | grep -iE "endpoint|transfer|allowed" || true
        else
            echo "wg0: DOWN"
        fi
        echo ""
        run "cat $MODE_CONF 2>/dev/null" || echo "MODE=v4 (default)"
        echo ""
        show_ip
        ;;
    on)
        run "wg-quick up wg0 2>/dev/null || true"
        echo "wg0: ON"
        show_ip
        ;;
    off)
        run "wg-quick down wg0 2>/dev/null || true"
        echo "wg0: OFF"
        ;;
    v4)
        run "
            wg-quick down wg0 2>/dev/null || true
            sed -i '/^AllowedIPs/d' $WG_CONF
            sed -i '/\[Peer\]/a AllowedIPs = 0.0.0.0\/0' $WG_CONF
            printf 'MODE=v4\nPRIORITY=v4\n' > $MODE_CONF
            wg-quick up wg0
        "
        echo "Mode: IPv4"
        show_ip
        ;;
    v6)
        run "
            wg-quick down wg0 2>/dev/null || true
            sed -i '/^AllowedIPs/d' $WG_CONF
            sed -i '/\[Peer\]/a AllowedIPs = ::\/0' $WG_CONF
            printf 'MODE=v6\nPRIORITY=v4\n' > $MODE_CONF
            wg-quick up wg0
        "
        echo "Mode: IPv6"
        show_ip
        ;;
    dual)
        PRIO="${2:-v4}"
        case "$PRIO" in v4|v6) ;; *) die "优先级只能是 v4 或 v6" ;; esac
        run "
            wg-quick down wg0 2>/dev/null || true
            sed -i '/^AllowedIPs/d' $WG_CONF
            sed -i '/\[Peer\]/a AllowedIPs = 0.0.0.0\/0, ::\/0' $WG_CONF
            printf 'MODE=dual\nPRIORITY=$PRIO\n' > $MODE_CONF
            wg-quick up wg0
        "
        if [ "$PRIO" = "v6" ]; then
            run "ip -4 route replace default dev wg0 metric 20 2>/dev/null || true; ip -6 route replace default dev wg0 metric 10 2>/dev/null || true"
        else
            run "ip -4 route replace default dev wg0 metric 10 2>/dev/null || true; ip -6 route replace default dev wg0 metric 20 2>/dev/null || true"
        fi
        echo "Mode: dual ($PRIO priority)"
        show_ip
        ;;
    *)
        echo "Usage: $0 {on|off|v4|v6|dual [v4|v6]}"
        exit 1
        ;;
esac
