#!/usr/bin/env bash
# 为 IP 证书环境新增一个应用 HTTPS 入口（按端口区分应用）
#
# 用法：
#   add-app-entry.sh <应用名> <端口> <后端地址:端口> [证书] [私钥]
#
# 示例：
#   ./add-app-entry.sh my-app 10443 10.42.0.15:8080
#   ./add-app-entry.sh my-app 10443 127.0.0.1:9001 /app/certs/console.crt /app/certs/console.key
#
# 说明：
#   - 本项目使用 IP 证书（无域名），因此每个应用占用独立端口（443/8443/9443/...）
#   - 所有应用默认共用 /app/certs/console.crt + console.key
#   - 生成的文件：/etc/nginx/apps.d/<应用名>-<端口>.conf

set -euo pipefail

NAME=${1:-}
PORT=${2:-}
BACKEND=${3:-}
CERT=${4:-/app/certs/console.crt}
KEY=${5:-/app/certs/console.key}

if [ -z "$NAME" ] || [ -z "$PORT" ] || [ -z "$BACKEND" ]; then
    echo "用法: $0 <应用名> <端口> <后端地址:端口> [证书] [私钥]" >&2
    exit 1
fi

case "$NAME" in
    *[!a-zA-Z0-9_-]*) echo "应用名只能包含字母、数字、下划线和短横线" >&2; exit 1 ;;
esac

if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT$"; then
    echo "端口 $PORT 已被监听，请换一个端口" >&2
    exit 1
fi

CONF="/etc/nginx/apps.d/${NAME}-${PORT}.conf"
if [ -f "$CONF" ]; then
    echo "配置已存在：$CONF" >&2
    exit 1
fi

mkdir -p /etc/nginx/apps.d
cat >"$CONF" <<EOF
# ${NAME} -> ${BACKEND}
server {
    listen ${PORT} ssl http2;
    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL_${PORT}:5m;
    server_name _;
    client_max_body_size 2g;
    location / {
        proxy_pass http://${BACKEND};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
}
EOF

if ! nginx -t >/dev/null 2>&1; then
    echo "Nginx 配置校验失败，已回滚" >&2
    rm -f "$CONF"
    nginx -t
    exit 1
fi

systemctl reload nginx
echo "已新增应用入口：https://<本机IP>:${PORT}/  ->  ${BACKEND}"
echo "配置文件：${CONF}"
echo "提醒：安全组需要放行 ${PORT} 端口"
