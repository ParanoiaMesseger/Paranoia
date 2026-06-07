echo "Регистрация systemd-сервиса"
sudo -n true

sudo cat > /opt/Paranoia/start.sh << 'EOF'
#!/usr/bin/env bash
sudo systemctl start paranoia
EOF

sudo cat > /opt/Paranoia/stop.sh << 'EOF'
#!/usr/bin/env bash
sudo systemctl stop paranoia
EOF

sudo cat > /opt/Paranoia/restart.sh << 'EOF'
#!/usr/bin/env bash
sudo systemctl restart paranoia
EOF

sudo cat > /opt/Paranoia/unistall.sh << 'EOF'
#!/usr/bin/env bash
sudo systemctl stop paranoia
sudo systemctl disable paranoia
sudo rm /etc/nginx/conf.d/paranoia.conf 
sudo rm /etc/systemd/system/paranoia.service
sudo rm -rf /opt/Paranoia
sudo systemctl restart nginx
sudo certbot revoke --cert-name {DOMAIN} --non-interactive
sudo certbot delete --cert-name {DOMAIN} --non-interactive
sudo systemctl daemon-reload
pkill -9 paranoia
EOF

sudo chmod +x /opt/Paranoia/start.sh
sudo chmod +x /opt/Paranoia/stop.sh
sudo chmod +x /opt/Paranoia/restart.sh
sudo chmod +x /opt/Paranoia/unistall.sh

sudo cat > "/etc/systemd/system/paranoia.service" << SERVICE_EOF
[Unit]
Description=Paranoia secure messenger server
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

sudo systemctl daemon-reload