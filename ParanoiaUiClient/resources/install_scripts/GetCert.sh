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
sudo certbot certonly --noninteractive --agree-tos --register-unsafely-without-email --webroot -w /var/www/certbot -d {DOMAIN}
