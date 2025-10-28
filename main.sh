#!/bin/bash
set -euo pipefail

# make sure root fs is writable (some boxes boot read-only after crash)
mount -o remount,rw /

### CONFIG ###
TUNNEL_IPV6="2a01:4f8:1c1b:219b:b1::1"   # مقصدی که با ping6 می‌سنجیم
ALLOWED_IP_1="38.180.44.179"            # سرور مانیتور خارج (اصلی)
ALLOWED_IP_2="38.180.62.165"            # سرور مانیتور بکاپ / دوم
LISTEN_PORT_PUBLIC=8888                 # پورتی که nginx به بیرون اکسپوز می‌کنه
LISTEN_PORT_LOCAL=8887                  # پورتی که Flask روی لوکال گوش می‌ده
SERVICE_NAME="health-tunnel.service"    # اسم سرویس systemd
PY_PATH="/opt/health-tunnel.py"         # اسکریپت پایتون
NGINX_SITE_PATH="/etc/nginx/sites-available/health"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/health"
########################################

echo "[1/7] apt update & install prereqs (python3, pip, nginx, iputils-ping)..."
apt update -y
apt install -y python3 python3-pip nginx iputils-ping

echo "[2/7] install Flask (global is fine here)..."
pip3 install flask

echo "[3/7] disable default nginx site so it doesn't grab :80 and conflict later..."
if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
fi
if [ -f /etc/nginx/sites-available/default ]; then
    :
fi

echo "[4/7] write Flask health server to $PY_PATH ..."
cat > "$PY_PATH" <<EOF
#!/usr/bin/env python3
from flask import Flask, jsonify
import subprocess

app = Flask(__name__)

TARGET_IPV6 = "${TUNNEL_IPV6}"

@app.route("/health")
def health():
    try:
        result = subprocess.run(
            ["ping6", "-c", "1", "-W", "2", TARGET_IPV6],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        if result.returncode == 0:
            return jsonify({"status": "ok", "message": "Tunnel is active"}), 200
        else:
            return jsonify({"status": "fail", "message": "Tunnel down"}), 503
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

if __name__ == "__main__":
    # dev run (not used in production because systemd runs it)
    app.run(host="127.0.0.1", port=${LISTEN_PORT_LOCAL})
EOF

chmod +x "$PY_PATH"

echo "[5/7] create/refresh systemd service /etc/systemd/system/$SERVICE_NAME ..."
cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=IPv6 tunnel health probe for uptime monitor
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${PY_PATH}
Restart=always
RestartSec=3
User=root
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=/opt

[Install]
WantedBy=multi-user.target
EOF

echo "[6/7] write nginx site to $NGINX_SITE_PATH ..."
cat > "$NGINX_SITE_PATH" <<EOF
server {
    listen ${LISTEN_PORT_PUBLIC};
    server_name _;

    location /health {
        # allow only monitoring servers + localhost
        allow 127.0.0.1;
        allow ${ALLOWED_IP_1};
        allow ${ALLOWED_IP_2};
        deny all;

        proxy_pass http://127.0.0.1:${LISTEN_PORT_LOCAL}/health;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf "$NGINX_SITE_PATH" "$NGINX_SITE_LINK"

echo "[7/7] reload services (systemd + nginx)..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

systemctl enable nginx
if systemctl is-active --quiet nginx; then
    nginx -t && systemctl reload nginx
else
    systemctl start nginx
fi

echo
echo "=== POST-CHECKS ==="
echo "1) Service status:"
systemctl status "$SERVICE_NAME" --no-pager || true
echo
echo "2) Listening sockets:"
ss -tlnp | grep -E "${LISTEN_PORT_LOCAL}|${LISTEN_PORT_PUBLIC}" || true
echo
echo "3) Local curl tests:"
curl -v "http://127.0.0.1:${LISTEN_PORT_LOCAL}/health" || true
curl -v "http://127.0.0.1:${LISTEN_PORT_PUBLIC}/health" || true
echo
echo "Setup complete ✅"
echo "From central server, monitor this URL:"
echo "  http://<THIS_SERVER_PUBLIC_IP>:${LISTEN_PORT_PUBLIC}/health"
echo
echo "In your uptime panel:"
echo "  Type: http"
echo "  Target: http://<THIS_SERVER_PUBLIC_IP>:${LISTEN_PORT_PUBLIC}/health"
echo '  Keyword: status":"ok'
echo "  Timeout: 5000ms (or higher if link is slow)"
echo "  Agent: central"
echo
echo "Done 🎉"
