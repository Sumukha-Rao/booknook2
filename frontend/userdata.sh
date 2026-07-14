#!/bin/bash
apt update -y
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs git
git clone https://github.com/Sumukha-Rao/booknook2.git /opt/booknook
cd /opt/booknook/backend
cat > .env <<EOF
PORT=3000
CORS_ORIGIN=*
JWT_SECRET=one-long-random-string-shared-by-all-instances
DB_HOST=booknook.c1qumeos0tka.ap-south-1.rds.amazonaws.com
DB_PORT=3306
DB_USER=admin
DB_PASSWORD=database
DB_NAME=booknook
EOF
npm install
# run as a service so it restarts automatically
cat > /etc/systemd/system/booknook.service <<UNIT
[Unit]
After=network.target
[Service]
WorkingDirectory=/opt/booknook/backend
ExecStart=/usr/bin/node server.js
Restart=always
EnvironmentFile=/opt/booknook/backend/.env
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now booknook