echo GetCert
sudo -n true
sudo mkdir -p /var/www/certbot
sudo cat > /etc/nginx/conf.d/paranoia.conf << 'EOF'
server {
    listen 80;
    server_name {DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 444;
    }
}
EOF

sudo service nginx restart

if sudo certbot certificates 2>/dev/null | grep -q "Certificate Name: {DOMAIN}"; then
    echo "Certificate for {DOMAIN} already exists, skipping"
else
    sudo certbot certonly --noninteractive --agree-tos --register-unsafely-without-email \
        --webroot -w /var/www/certbot -d {DOMAIN}
fi
