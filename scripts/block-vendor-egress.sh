#!/usr/bin/env bash
# Block Rainbond vendor endpoints (telemetry / market / update check).
#
# Two independent layers:
#   hosts   - host processes resolve the domains to 127.0.0.1 (fast fail)
#   iptables- resolve the real IPs via public DNS and REJECT them on OUTPUT
#             (covers names resolved before the hosts entry existed, and
#              processes that bypass /etc/hosts, e.g. with a custom resolver)
#
# Containers keep their own resolver, so for in-cluster blocking use the
# iptables layer (it applies to forwarded traffic from pods as well when the
# FORWARD chain is filtered by the same rules - enable with --with-forward).
#
# Usage:
#   ./block-vendor-egress.sh enable    # apply hosts + iptables
#   ./block-vendor-egress.sh disable   # revert both
#   ./block-vendor-egress.sh status    # show current state
#
# Idempotent: running enable twice will not duplicate entries/rules.

set -uo pipefail

DOMAINS=(
    "get.rainbond.com"        # update check (console/views/upgrade.py)
    "hub.grapps.cn"           # cloud component market / app store metadata
    "posthog.goodrain.com"    # PostHog telemetry
    "sentry.goodrain.com"     # Sentry error reporting
    "domain.grapps.cn"        # grctl domain suffix service
)

HOSTS_MARK="# rainbond-vendor-egress-block"
DNS_SERVER="${DNS_SERVER:-223.5.5.5}"
CHAIN="RBD_VENDOR_BLOCK"

log()  { echo "[block-egress] $*"; }
warn() { echo "[block-egress] WARN: $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

resolve_ips() {
    local domain="$1"
    if have dig; then
        dig +short +time=2 +tries=1 "@${DNS_SERVER}" A "$domain" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    elif have nslookup; then
        nslookup "$domain" "$DNS_SERVER" 2>/dev/null \
            | awk '/^Address: /{print $2}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    fi
}

# Drop any 127.0.0.1 line whose hostname column equals $1 (with or without
# the marker). awk is used instead of sed so the match stays exact and no
# delimiter/alternation escaping can silently fail.
remove_host_entry() {
    local domain="$1"
    awk -v d="$domain" '!($1=="127.0.0.1" && $2==d)' /etc/hosts > /etc/hosts.rbd-tmp \
        && cat /etc/hosts.rbd-tmp > /etc/hosts \
        && rm -f /etc/hosts.rbd-tmp
}

apply_hosts() {
    local added=0
    for d in "${DOMAINS[@]}"; do
        remove_host_entry "$d"
        printf '127.0.0.1 %s %s\n' "$d" "$HOSTS_MARK" >> /etc/hosts
        added=$((added + 1))
    done
    log "hosts: 写入 ${added} 条（原同名条目已归一化）"
}

revert_hosts() {
    local before after
    before=$(wc -l < /etc/hosts)
    for d in "${DOMAINS[@]}"; do
        remove_host_entry "$d"
    done
    after=$(wc -l < /etc/hosts)
    log "hosts: 移除 $((before - after)) 行（无论是否带标记）"
}

apply_iptables() {
    if ! have iptables; then
        warn "未安装 iptables，跳过 IP 层封禁"
        return 0
    fi
    iptables -N "$CHAIN" 2>/dev/null || true
    iptables -C OUTPUT -j "$CHAIN" 2>/dev/null || iptables -I OUTPUT 1 -j "$CHAIN"
    if [ "${1:-}" = "--with-forward" ]; then
        iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD 1 -j "$CHAIN"
    fi

    local total=0
    for d in "${DOMAINS[@]}"; do
        while read -r ip; do
            [ -z "$ip" ] && continue
            if iptables -C "$CHAIN" -d "$ip" -j REJECT 2>/dev/null; then
                continue
            fi
            iptables -A "$CHAIN" -d "$ip" -j REJECT 2>/dev/null && total=$((total + 1))
        done < <(resolve_ips "$d")
    done
    log "iptables: 新增 ${total} 条 REJECT 规则（链 ${CHAIN}）"
}

revert_iptables() {
    have iptables || return 0
    iptables -D OUTPUT -j "$CHAIN" 2>/dev/null || true
    iptables -D FORWARD -j "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    iptables -X "$CHAIN" 2>/dev/null || true
    log "iptables: 已清理链 ${CHAIN}"
}

show_status() {
    echo "=== hosts ==="
    if grep -qF "$HOSTS_MARK" /etc/hosts 2>/dev/null; then
        grep -F "$HOSTS_MARK" /etc/hosts
    else
        echo "  （未启用）"
    fi

    echo "=== iptables ==="
    if have iptables && iptables -S "$CHAIN" >/dev/null 2>&1; then
        iptables -S "$CHAIN" | sed 's/^/  /'
    else
        echo "  （未启用）"
    fi

    echo "=== 连通性 ==="
    for d in "${DOMAINS[@]}"; do
        local ip state
        ip=$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)
        if [ -z "$ip" ]; then
            state="BLOCKED (DNS 无结果)"
        elif [ "$ip" = "127.0.0.1" ]; then
            state="BLOCKED (hosts)"
        elif timeout 5 bash -c "</dev/tcp/${ip}/443" 2>/dev/null; then
            state="REACHABLE (${ip})"
        else
            state="BLOCKED (iptables ${ip})"
        fi
        printf "  %-24s %s\n" "$d" "$state"
    done
}

case "${1:-}" in
    enable)
        apply_hosts
        apply_iptables "${2:-}"
        log "完成。容器内如需生效，请用 --with-forward 或额外配置集群侧策略。"
        ;;
    disable)
        revert_hosts
        revert_iptables
        log "已回滚"
        ;;
    status)
        show_status
        ;;
    *)
        echo "用法: $0 {enable [--with-forward]|disable|status}"
        exit 1
        ;;
esac
