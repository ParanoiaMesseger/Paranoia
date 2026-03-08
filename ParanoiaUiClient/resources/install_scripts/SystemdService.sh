echo "Регистрация systemd-сервиса"
sudo -n true

cat > /opt/Paranoia/start.sh << 'EOF'
#!/usr/bin/env bash
sudo systemctl start paranoia
EOF

cat > /opt/Paranoia/stop.sh << 'EOF'
#!/usr/bin/env bash
sudo systemctl stop paranoia
EOF

cat > /opt/Paranoia/restart.sh << 'EOF'
#!/usr/bin/env bash
sudo systemctl restart paranoia
EOF

chmod +x start.sh
chmod +x stop.sh
chmod +x restart.sh

cat > "/etc/systemd/system/paranoia.service" << SERVICE_EOF
[Unit]
Description=Paranoia by paranoia-dev
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/Paranoia/
ExecStart=/opt/Paranoia/paranoia
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF