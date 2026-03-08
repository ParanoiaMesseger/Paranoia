echo "Настройка nginx → Paranoia"
sudo -n true
sudo cat > /etc/nginx/conf.d/paranoia.conf << 'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

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

server {
    listen 443 ssl http2;
    server_name {DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/{DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{DOMAIN}/privkey.pem;

    client_max_body_size 1024M;

    location / {
        proxy_pass http://127.0.0.1:{PARANOIA_PORT};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_ssl_verify off;
    }

}
EOF
sudo service nginx restart