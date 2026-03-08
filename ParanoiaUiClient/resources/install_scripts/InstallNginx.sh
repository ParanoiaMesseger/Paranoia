echo "Установка nginx"
sudo -n true
sudo apt update
sudo apt install -y nginx certbot
sudo service nginx restart
