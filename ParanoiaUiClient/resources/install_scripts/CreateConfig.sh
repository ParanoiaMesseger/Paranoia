echo "Создание /opt/Paranoia и конфигурации"
sudo -n true
sudo mkdir -p /opt/Paranoia/configs
sudo cat > /opt/Paranoia/configs/Paranoia.json << 'EOF'
{
  "port": 1455,
  "store_path": "store",
  "admin_key": "{ADMIN_KEY}",
  "users": {}
}
EOF