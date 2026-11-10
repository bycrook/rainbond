#!/usr/bin/env bash
# Rainbond 本地调试栈统一启停脚本
#
# 组成：k3s + MariaDB + node_exporter + Prometheus + rbd-mq + rbd-api + console
# 端口：rbd-api 8888/8889，rbd-mq 6300，Prometheus 9999，node_exporter 9100，console 37070
#
# 用法：
#   ./scripts/local-stack.sh start      启动全部组件（幂等）
#   ./scripts/local-stack.sh stop       停止 api/mq/console/prometheus（保留 k3s、MariaDB）
#   ./scripts/local-stack.sh stop --all 连同 k3s、MariaDB、node_exporter 一起停
#   ./scripts/local-stack.sh restart
#   ./scripts/local-stack.sh status     查看端口、进程与遥测开关
#
# 说明：console 启动时强制注入 RAINBOND_TELEMETRY_DISABLED=true 与 POSTHOG_DISABLED=true，
# 避免向 posthog.goodrain.com 上报实例信息。

set -uo pipefail

ROOT_DIR=${ROOT_DIR:-/home/project}
GO_REPO=${GO_REPO:-$ROOT_DIR/rainbond}
CONSOLE_REPO=${CONSOLE_REPO:-$ROOT_DIR/rainbond-console}
CONSOLE_PY=${CONSOLE_PY:-$CONSOLE_REPO/.venv/bin/python}

DATA_DIR=${DATA_DIR:-/app/data}
KUBECONFIG_FILE=${KUBECONFIG_FILE:-/etc/rancher/k3s/k3s.yaml}
LOG_DIR=${LOG_DIR:-/tmp/rbd-local}
PID_DIR="$LOG_DIR/pids"

API_ADDR=${API_ADDR:-0.0.0.0:8888}
API_HEALTHZ=${API_HEALTHZ:-0.0.0.0:8889}
API_PORT=${API_PORT:-${API_ADDR##*:}}
MQ_PORT=${MQ_PORT:-6300}
PROM_PORT=${PROM_PORT:-9999}
CONSOLE_PORT=${CONSOLE_PORT:-8000}
# 控制台只监听本机，对外统一由 Nginx 提供 HTTPS（443）
CONSOLE_BIND=${CONSOLE_BIND:-127.0.0.1}
MYSQL_DSN=${MYSQL_DSN:-admin:admin@tcp(127.0.0.1:3306)/region}

mkdir -p "$LOG_DIR" "$PID_DIR"

log() { printf '[local-stack] %s\n' "$*"; }
warn() { printf '[local-stack][warn] %s\n' "$*" >&2; }

port_open() {
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

wait_port() {
    local port=$1 tries=${2:-30}
    for _ in $(seq 1 "$tries"); do
        port_open "$port" && return 0
        sleep 1
    done
    return 1
}

api_bin() {
    if [ -x "$GO_REPO/_output/bin/rainbond-api" ]; then
        echo "$GO_REPO/_output/bin/rainbond-api"
    else
        echo "/usr/local/bin/rainbond-api"
    fi
}

mq_bin() {
    if [ -x "$GO_REPO/_output/bin/rainbond-mq" ]; then
        echo "$GO_REPO/_output/bin/rainbond-mq"
    else
        echo "/usr/local/bin/rainbond-mq"
    fi
}

start_k3s() {
    if pgrep -f "k3s server" >/dev/null 2>&1; then
        log "k3s 已在运行"
        return 0
    fi
    log "启动 k3s"
    nohup k3s server --disable traefik --disable servicelb --disable metrics-server \
        --write-kubeconfig-mode 644 >"$LOG_DIR/k3s.log" 2>&1 &
    for _ in $(seq 1 60); do
        [ -f "$KUBECONFIG_FILE" ] && k3s kubectl get nodes >/dev/null 2>&1 && break
        sleep 2
    done
}

start_mariadb() {
    if systemctl is-active --quiet mariadb; then
        log "MariaDB 已在运行"
        return 0
    fi
    log "启动 MariaDB"
    systemctl start mariadb
    sleep 3
}

start_metrics() {
    if ! systemctl is-active --quiet prometheus-node-exporter; then
        log "启动 node_exporter"
        systemctl start prometheus-node-exporter
    else
        log "node_exporter 已在运行"
    fi

    if port_open "$PROM_PORT"; then
        log "Prometheus 已在运行"
        return 0
    fi
    log "启动 Prometheus (:$PROM_PORT)"
    mkdir -p /var/lib/prometheus-rbd
    nohup prometheus \
        --config.file=/etc/prometheus/rbd-local.yml \
        --storage.tsdb.path=/var/lib/prometheus-rbd \
        --web.listen-address="0.0.0.0:$PROM_PORT" >"$LOG_DIR/prometheus.log" 2>&1 &
    wait_port "$PROM_PORT" 20 || warn "Prometheus 未在 $PROM_PORT 监听"
}

start_mq() {
    if port_open "$MQ_PORT"; then
        log "rbd-mq 已在运行"
        return 0
    fi
    log "启动 rbd-mq (:$MQ_PORT)"
    nohup "$(mq_bin)" --api-port "$MQ_PORT" >"$LOG_DIR/mq.log" 2>&1 &
    wait_port "$MQ_PORT" 20 || warn "rbd-mq 未在 $MQ_PORT 监听"
}

start_api() {
    if port_open "$API_PORT"; then
        log "rbd-api 已在运行"
        return 0
    fi
    log "启动 rbd-api (:$API_PORT)"
    KUBECONFIG="$KUBECONFIG_FILE" nohup "$(api_bin)" \
        --kube-config "$KUBECONFIG_FILE" \
        --mysql "$MYSQL_DSN" \
        --event-servers "127.0.0.1:6366" \
        --mq-api "127.0.0.1:$MQ_PORT" \
        --worker-api "127.0.0.1:6535" \
        --prom-api "127.0.0.1:$PROM_PORT" \
        --hub-api "http://127.0.0.1:5000" \
        --builder-api "127.0.0.1:3228" \
        --storage-type local \
        --api-addr "$API_ADDR" \
        --api-healthz-addr "$API_HEALTHZ" >"$LOG_DIR/api.log" 2>&1 &
    wait_port "$API_PORT" 40 || warn "rbd-api 未在 $API_PORT 监听"
}

worker_bin() {
    if [ -x "$GO_REPO/_output/bin/rainbond-worker" ]; then
        echo "$GO_REPO/_output/bin/rainbond-worker"
    else
        echo "/usr/local/bin/rainbond-worker"
    fi
}

start_worker() {
    if port_open 6535; then
        log "rbd-worker 已在运行"
        return 0
    fi
    log "启动 rbd-worker (:6535，node-name=$(hostname))"
    KUBECONFIG="$KUBECONFIG_FILE" nohup "$(worker_bin)" \
        --kube-config "$KUBECONFIG_FILE" \
        --mysql "$MYSQL_DSN" \
        --event-servers "127.0.0.1:6366" \
        --mq-api "127.0.0.1:$MQ_PORT" \
        --worker-api "127.0.0.1:6535" \
        --prom-api "127.0.0.1:$PROM_PORT" \
        --hub-api "http://127.0.0.1:5000" \
        --node-name "$(hostname)" >"$LOG_DIR/worker.log" 2>&1 &
    wait_port 6535 40 || warn "rbd-worker 未在 6535 监听"
}

start_hub() {
    if port_open 5000; then
        log "rbd-hub 已在运行"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        warn "未安装 docker，跳过 rbd-hub"
        return 1
    fi
    log "启动 rbd-hub (registry:2, :5000)"
    mkdir -p /grdata/registry
    docker rm -f rbd-hub >/dev/null 2>&1
    docker run -d --name rbd-hub --restart=always -p 5000:5000 \
        -v /grdata/registry:/var/lib/registry registry:2 >/dev/null
    wait_port 5000 20 || warn "rbd-hub 未在 5000 监听"
}

chaos_bin() {
    if [ -x "$GO_REPO/_output/bin/rainbond-chaos" ]; then
        echo "$GO_REPO/_output/bin/rainbond-chaos"
    else
        echo "/usr/local/bin/rainbond-chaos"
    fi
}

start_chaos() {
    if port_open 3228; then
        log "rbd-chaos 已在运行"
        return 0
    fi
    log "启动 rbd-chaos (构建服务 :3228)"
    KUBECONFIG="$KUBECONFIG_FILE" BUILD_IMAGE_REPOSTORY_DOMAIN="127.0.0.1:5000" nohup "$(chaos_bin)" \
        --container-runtime docker \
        --dockerd "127.0.0.1:2376" \
        --hub-api "http://127.0.0.1:5000" \
        --mysql "$MYSQL_DSN" \
        --event-servers "127.0.0.1:6366" \
        --mq-api "127.0.0.1:$MQ_PORT" \
        --worker-api "127.0.0.1:6535" \
        --prom-api "127.0.0.1:$PROM_PORT" \
        --kube-config "$KUBECONFIG_FILE" \
        --storage-type local \
        --hostIP "$(hostname -I | awk '{print $1}')" \
        --hostName "$(hostname)" \
        --api-port 3228 \
        --ws-addr "0.0.0.0:6061" \
        --registry-mirrors "https://docker.m.daocloud.io" >"$LOG_DIR/chaos.log" 2>&1 &
    wait_port 3228 30 || warn "rbd-chaos 未在 3228 监听"
}

start_console() {
    if port_open "$CONSOLE_PORT"; then
        log "console 已在运行"
        return 0
    fi
    if [ ! -x "$CONSOLE_PY" ]; then
        warn "未找到 console 虚拟环境：$CONSOLE_PY"
        return 1
    fi
    log "启动 console ($CONSOLE_BIND:$CONSOLE_PORT，遥测/云市场已禁用)"
    cd "$CONSOLE_REPO" || return 1
    # DISABLE_CLOUD_MARKET also short-circuits the update check that would
    # otherwise call https://get.rainbond.com/upgrade-versions.json.
    DATA_DIR="$DATA_DIR" ALLOWED_HOSTS='*' DEBUG=True \
        RAINBOND_TELEMETRY_DISABLED=true POSTHOG_DISABLED=true \
        DISABLE_CLOUD_MARKET=true \
        nohup "$CONSOLE_PY" manage.py runserver "$CONSOLE_BIND:$CONSOLE_PORT" --noreload \
        >"$LOG_DIR/console.log" 2>&1 &
    wait_port "$CONSOLE_PORT" 40 || warn "console 未在 $CONSOLE_PORT 监听"
}

stop_process() {
    local pattern=$1 name=$2
    if pgrep -f "$pattern" >/dev/null 2>&1; then
        log "停止 $name"
        pkill -f "$pattern"
        for _ in $(seq 1 15); do
            pgrep -f "$pattern" >/dev/null 2>&1 || return 0
            sleep 1
        done
        warn "$name 未在 15 秒内退出"
    else
        log "$name 未运行"
    fi
}

start_nginx() {
    if systemctl is-active --quiet nginx; then
        log "Nginx 已在运行（HTTPS 入口）"
        return 0
    fi
    log "启动 Nginx（HTTPS 入口，4443）"
    systemctl start nginx
}

cmd_start() {
    start_mariadb
    start_k3s
    start_metrics
    start_hub
    start_mq
    start_api
    start_worker
    start_chaos
    start_console
    start_nginx
    log "启动完成，控制台：https://<本机IP>:4443/"
}

cmd_stop() {
    stop_process "manage.py runserver" "console"
    stop_process "rainbond-api" "rbd-api"
    stop_process "rainbond-mq" "rbd-mq"
    stop_process "prometheus --config.file=/etc/prometheus/rbd-local.yml" "Prometheus"
    if systemctl is-active --quiet nginx; then
        log "停止 Nginx"
        systemctl stop nginx
    fi
    if [ "${1:-}" = "--all" ]; then
        log "停止 node_exporter / k3s / MariaDB"
        systemctl stop prometheus-node-exporter 2>/dev/null
        stop_process "k3s server" "k3s"
        systemctl stop mariadb 2>/dev/null
    fi
}

cmd_status() {
    printf '%-26s %-8s %s\n' "组件" "端口" "状态"
    local pairs=(
        "console:$CONSOLE_PORT"
        "console-https:4443"
        "rbd-api:$API_PORT"
        "rbd-api-healthz:${API_HEALTHZ##*:}"
        "rbd-mq:$MQ_PORT"
        "rbd-hub:5000"
        "rbd-worker:6535"
        "rbd-chaos:3228"
        "Prometheus:$PROM_PORT"
        "node_exporter:9100"
    )
    for item in "${pairs[@]}"; do
        local name=${item%%:*} port=${item##*:}
        if port_open "$port"; then
            printf '%-26s %-8s %s\n' "$name" "$port" "运行中"
        else
            printf '%-26s %-8s %s\n' "$name" "$port" "未运行"
        fi
    done

    echo
    if pgrep -f "k3s server" >/dev/null 2>&1; then echo "k3s: 运行中"; else echo "k3s: 未运行"; fi
    if systemctl is-active --quiet mariadb; then echo "MariaDB: 运行中"; else echo "MariaDB: 未运行"; fi

    echo
    if [ -f "$DATA_DIR/db.sqlite3" ]; then
        python3 - "$DATA_DIR/db.sqlite3" <<'PY'
import sqlite3, sys
try:
    conn = sqlite3.connect(sys.argv[1])
    rows = conn.execute(
        "select key, enable from console_sys_config "
        "where key='EXTERNAL_TELEMETRY_ENABLED' or key like 'RBD_TEL%'"
    ).fetchall()
    print("控制台遥测开关记录:", rows or "无")
except Exception as exc:  # noqa: BLE001
    print("读取遥测开关失败:", exc)
PY
    fi
}

case "${1:-}" in
    start)   cmd_start ;;
    stop)    shift; cmd_stop "${1:-}" ;;
    restart) cmd_stop; sleep 2; cmd_start ;;
    status)  cmd_status ;;
    *)
        echo "用法: $0 {start|stop [--all]|restart|status}"
        exit 1
        ;;
esac
