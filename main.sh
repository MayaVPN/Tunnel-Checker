#!/bin/bash
set -e

echo "[1/6] Installing prerequisites..."
apt update
apt install -y python3 python3-pip python3-venv nginx

echo "[2/6] Removing default nginx site (avoid port 80 conflicts)..."
rm -f /etc/nginx/sites-enabled/default || true
rm -f /etc/nginx/sites-available/default || true

echo "[3/6] Writing /opt/health-tunnel.py ..."
cat >/opt/health-tunnel.py <<'EOF'
#!/usr/bin/env python3
from flask import Flask, jsonify
import subprocess

app = Flask(__name__)

TARGET_IPV6 = "2a01:4f8:1c1b:219b:b1::1"

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
    app.run(host="127.0.0.1", port=8887)
EOF

chmod +x /opt/health-tunnel.py

echo "[4/6] Creating/refreshing systemd service health-tunnel.service ..."
# If an old service existed with a different name, disable it
if systemctl list-unit-files | grep -q "^health-server.service"; then
    systemctl stop health-server.service || true
    systemctl disable health-server.service || true
    rm -f /etc/systemd/system/health-server.service || true
fi

cat >/etc/systemd/system/health-tunnel.service <<'EOF'
[Unit]
Description=IPv6 tunnel health probe for uptime monitor
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/health-tunnel.py
WorkingDirectory=/opt
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable health-tunnel.service
systemctl restart health-tunnel.service

echo "[5/6] Writing nginx site /etc/nginx/sites-available/health ..."

cat >/etc/nginx/sites-available/health <<'EOF'
server {
    listen 8888;
    server_name _;

    location /health {
        # Allowed callers
        allow 127.0.0.1;
        allow 38.180.44.179;
        allow 38.180.62.165;
        deny all;

        proxy_pass http://127.0.0.1:8887;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/health /etc/nginx/sites-enabled/health

echo "[6/6] Reloading nginx ..."
nginx -t
systemctl reload nginx

echo
echo "=== Status checks ==="
echo
echo "[*] systemd service:"
systemctl --no-pager --full status health-tunnel.service || true

echo
echo "[*] Listening sockets:"
ss -tlnp | grep -E '8887|8888' || true

echo
echo "[*] Local curl test:"
curl -s -v http://127.0.0.1:8888/health || true

echo
echo "DONE ✅"
echo "If you see status \"ok\" or \"fail\" above (NOT 403), you're good."
echo "Now you can add this monitor in your dashboard as http://YOUR_SERVER_IP:8888/health"
