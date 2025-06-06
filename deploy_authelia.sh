#!/bin/bash
set -e  # 遇到错误立即退出
# 配置变量 (按需修改)
DOMAIN="auth.yourdomain.com"
EMAIL="admin@yourdomain.com"
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)
MYSQL_PASSWORD=$(openssl rand -hex 16)

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 此脚本需要 root 权限运行"
  exit 1
fi

echo "=== 开始部署 Authelia ==="

# 安装依赖
echo "安装必要依赖..."
apt-get update
apt-get install -y docker.io docker-compose nginx certbot openssl

# 启动 Docker
echo "启动 Docker 服务..."
systemctl enable --now docker

# 创建目录结构
echo "创建 Authelia 目录结构..."
mkdir -p /opt/authelia/{config,mysql,logs}
cd /opt/authelia

# 生成配置文件
echo "生成 Authelia 配置文件..."

cat > config/configuration.yml <<EOF
theme: light
jwt_secret: $JWT_SECRET
default_redirection_url: https://$DOMAIN

server:
  host: 0.0.0.0
  port: 9091

log:
  level: info
  file_path: /config/logs/authelia.log

authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2id
      iterations: 1
      salt_length: 16
      parallelism: 8
      memory: 128

access_control:
  default_policy: deny
  rules:
    - domain: "$DOMAIN"
      policy: two_factor
    - domain: "*.yourdomain.com"
      policy: two_factor

session:
  name: authelia_session
  secret: $SESSION_SECRET
  expiration: 1h
  inactivity: 5m
  domain: yourdomain.com

regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

storage:
  mysql:
    host: authelia-db
    port: 3306
    database: authelia
    username: authelia
    password: $MYSQL_PASSWORD

notifier:
  smtp:
    host: smtp.example.com
    port: 587
    username: no-reply@yourdomain.com
    password: your_smtp_password
    sender: no-reply@yourdomain.com
    subject: "[Authelia] {title}"
EOF

# 生成初始用户数据库
echo "生成用户数据库文件..."

cat > config/users_database.yml <<EOF
users:
  admin:
    displayname: "Admin User"
    password: "\$argon2id\$v=19\$m=65536,t=3,p=4\$WXpHc2dzRCQ\$kCSs...YOUR_HASHED_PASSWORD"
    email: $EMAIL
    groups:
      - admins
EOF

echo "请手动生成密码哈希并更新 config/users_database.yml:"
echo "运行: docker run --rm authelia/authelia:latest authelia crypto hash generate argon2id --password '你的密码'"

# 创建 docker-compose.yml
echo "创建 docker-compose.yml..."

cat > docker-compose.yml <<EOF
version: '3.8'

services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    volumes:
      - ./config:/config
      - ./logs:/config/logs
    ports:
      - "9091:9091"
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
    depends_on:
      - authelia-db
    networks:
      - authelia-net

  authelia-db:
    image: mariadb:10.6
    container_name: authelia-db
    volumes:
      - ./mysql:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: $(openssl rand -hex 16)
      MYSQL_DATABASE: authelia
      MYSQL_USER: authelia
      MYSQL_PASSWORD: $MYSQL_PASSWORD
    restart: unless-stopped
    networks:
      - authelia-net

networks:
  authelia-net:
    driver: bridge
EOF

# 启动 Authelia
echo "启动 Authelia 容器..."
docker-compose up -d

# 配置 Nginx 反向代理
echo "配置 Nginx 反向代理..."

# 获取 SSL 证书
if ! certbot certificates | grep -q "$DOMAIN"; then
  echo "申请 Let's Encrypt SSL 证书..."
  certbot certonly --standalone --agree-tos --noninteractive -d $DOMAIN -m $EMAIL
fi

# 创建 Nginx 配置
cat > /etc/nginx/sites-available/authelia <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:9091;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# 启用 Nginx 配置
ln -sf /etc/nginx/sites-available/authelia /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# 设置自动续期证书
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -

echo "=== Authelia 部署完成 ==="
echo "访问地址: https://$DOMAIN"
echo "初始管理员账号: admin"
echo "请确保已更新 config/users_database.yml 中的密码哈希"
echo "如需保护其他服务，参考 Authelia 文档配置 Nginx auth_request"
