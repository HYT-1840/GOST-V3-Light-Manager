#!/bin/bash
set -euo pipefail
# GOST V3 轻量主控端 交互式管理脚本【低配VPS优化版】
# 适配：≤50节点 | 整体资源＜30M | CentOS7+/Ubuntu18+/Debian10+ | x86_64/arm64
# 核心优化：极致资源限制+进程轻量化+卡顿兜底，杜绝低配VPS卡死

# ==================== 基础配置（低配优化）====================
SERVICE_NAME="gost-master"
GOST_MASTER_DIR="/usr/local/gost-master"
NGINX_HTML_DIR="${GOST_MASTER_DIR}/nginx/html"
GRPC_PORT=${GRPC_PORT:-50051}
HTTP_PORT=${HTTP_PORT:-8080}
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
# 颜色定义
RED_COLOR="\033[31m"
GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
RESET_COLOR="\033[0m"
# 🔥 低配核心资源限制
CPU_QUOTA="5%"
MEMORY_LIMIT="16M"
IO_LIMIT="256K"
MAX_OPEN_FILES=4096

# ==================== 核心函数：获取最新GOST版本 ====================
get_latest_gost() {
    print_tip "获取GOST最新版本..."
    LATEST_VERSION=$(curl -s --connect-timeout 10 https://api.github.com/repos/go-gost/gost/releases/latest | grep -E 'tag_name' | cut -d'"' -f4 | sed 's/v//g')
    if [ -z "${LATEST_VERSION}" ]; then
        print_err "获取版本失败！检查GitHub网络（建议配置代理）"
        exit 1
    fi
    print_ok "最新版本：v${LATEST_VERSION}"
    echo "${LATEST_VERSION}"
}

# ==================== 工具函数（低配精简）====================
print_ok() { echo -e "${GREEN_COLOR}✅ $1${RESET_COLOR}"; }
print_err() { echo -e "${RED_COLOR}❌ $1${RESET_COLOR}"; }
print_tip() { echo -e "${YELLOW_COLOR}💡 $1${RESET_COLOR}"; }
check_installed() { [ -f "${GOST_MASTER_DIR}/bin/gost" ] && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && return 0 || return 1; }
check_running() { systemctl is-active --quiet ${SERVICE_NAME} && return 0 || return 1; }
check_port() { netstat -tulnp 2>/dev/null | grep -q ":$1 " && return 0 || return 1; }
get_ip() {
    INNER_IP=$(ip addr | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
    echo "内网：$INNER_IP"
}
gen_rand_key() { head -c 16 /dev/urandom | xxd -p | head -c 16; }

# ==================== 低配专属：防卡死功能 ====================
kill_stuck_process() {
    print_tip "检查并清理卡死进程..."
    pkill -f gost -9 2>/dev/null || true
    pkill -f nginx -9 2>/dev/null || true
    print_ok "卡死进程清理完成"
}
monitor_resource() {
    print_tip "当前系统资源占用（低配VPS重点关注）："
    echo -e "CPU占用：$(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - $1 "%"}\')"
    echo -e "内存占用：$(free -h | grep Mem | awk '{print $3 "/" $2}')"
    echo -e "GOST进程：$(ps -ef | grep gost | grep -v grep || echo "未运行")"
    echo -e "Nginx进程：$(ps -ef | grep nginx | grep -v grep || echo "未运行")"
}

# ==================== 核心功能：安装主控端 ====================
install_master() {
    if check_installed; then
        print_tip "检测到已安装主控端！"
        read -p "是否重新安装（覆盖配置，y/n）：" CHOICE
        [ "${CHOICE}" != "y" ] && [ "${CHOICE}" != "Y" ] && { print_ok "取消重新安装"; return 0; }
        kill_stuck_process
        systemctl stop ${SERVICE_NAME} nginx >/dev/null 2>&1 || true
    fi

    echo -e "\n===== 安装GOST V3轻量主控端【低配VPS优化版】===="
    # 端口检测
    print_tip "端口预检测（gRPC：${GRPC_PORT} | 面板：${HTTP_PORT}）..."
    if check_port ${GRPC_PORT} || check_port ${HTTP_PORT}; then
        print_err "端口已被占用！请先执行选项7修改端口"
        exit 1
    fi
    # 安装依赖（精简版）
    print_tip "安装基础依赖（精简版）..."
    if [ -f /etc/redhat-release ]; then
        yum install -y -q nginx wget tar sqlite3 net-tools --setopt=tsflags=nodocs >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    elif [ -f /etc/debian_version ]; then
        apt update -y -qq >/dev/null 2>&1 && apt install -y -qq nginx wget tar sqlite3 net-tools >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    else
        print_err "仅支持CentOS/Ubuntu/Debian！"; exit 1;
    fi
    # 下载GOST
    GOST_VERSION=$(get_latest_gost)
    GOST_TAR="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${GOST_TAR}"
    print_tip "下载GOST v${GOST_VERSION}（${ARCH}架构，断点续传）..."
    mkdir -p ${GOST_MASTER_DIR}/bin
    wget -q -c --timeout=30 ${GOST_URL} -O /tmp/${GOST_TAR} || { print_err "GOST下载失败！配置代理后重试"; exit 1; }
    tar zxf /tmp/${GOST_TAR} -C ${GOST_MASTER_DIR}/bin gost >/dev/null 2>&1
    chmod +x ${GOST_MASTER_DIR}/bin/gost && rm -rf /tmp/${GOST_TAR}
    # 验证安装
    if ! ${GOST_MASTER_DIR}/bin/gost -V >/dev/null 2>&1; then
        print_err "GOST安装验证失败！可能是架构不匹配"
        exit 1
    fi
    print_ok "GOST v${GOST_VERSION} 安装验证成功！"
    # 生成配置+证书
    print_tip "生成主控配置+TLS加密证书..."
    RAND_KEY=$(gen_rand_key)
    mkdir -p ${GOST_MASTER_DIR}/{conf,log,data}
    cat > ${GOST_MASTER_DIR}/conf/config.yaml <<EOF
log:
  level: error
  file: ${GOST_MASTER_DIR}/log/gost-master.log
  max-size: 20
  max-age: 2
db:
  type: sqlite
  dsn: ${GOST_MASTER_DIR}/data/gost-master.db
server:
  grpc:
    addr: :${GRPC_PORT}
    tls: true
    cert: ${GOST_MASTER_DIR}/conf/cert.pem
    key: ${GOST_MASTER_DIR}/conf/key.pem
control:
  enabled: true
  auth: true
EOF
    ${GOST_MASTER_DIR}/bin/gost cert -gen -out ${GOST_MASTER_DIR}/conf/cert.pem -key ${GOST_MASTER_DIR}/conf/key.pem >/dev/null 2>&1
    # 配置Systemd（资源限制）
    print_tip "配置Systemd服务（防卡死+开机自启）..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=GOST V3 Light Master [Low-VPS Optimized]
After=network.target nginx.service
Wants=network.target
ExecStartPre=/bin/sleep 5
ExecStartPre=/bin/bash -c "ulimit -n ${MAX_OPEN_FILES}"

[Service]
Type=simple
User=root
WorkingDirectory=${GOST_MASTER_DIR}
ExecStart=${GOST_MASTER_DIR}/bin/gost -C ${GOST_MASTER_DIR}/conf/config.yaml
Restart=on-failure
RestartSec=10s
LimitNOFILE=${MAX_OPEN_FILES}
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
CPUQuota=${CPU_QUOTA}
MemoryLimit=${MEMORY_LIMIT}
MemorySwapLimit=0
IOReadBandwidthMax=/dev/sda ${IO_LIMIT}
IOWriteBandwidthMax=/dev/sda ${IO_LIMIT}
Nice=19
IOSchedulingClass=2
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF
    # 配置Nginx（极简版）
    print_tip "配置Nginx轻量版（关闭所有冗余模块）..."
    mkdir -p ${NGINX_HTML_DIR}
    wget -q -c --timeout=20 -O ${NGINX_HTML_DIR}/index.html https://gost.run/static/panel/index.html || print_tip "面板文件下载失败，可手动放入"
    cat > /etc/nginx/nginx.conf <<EOF
user root;
worker_processes 1;
error_log /var/log/nginx/error.log error;
pid /var/run/nginx.pid;
worker_rlimit_nofile ${MAX_OPEN_FILES};
events { 
    worker_connections 512; 
    use epoll; 
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  30;
    access_log off; 
    gzip off; 
    tcp_nopush on; 
    tcp_nodelay on;
    server_tokens off;
    server {
        listen       ${HTTP_PORT};
        server_name  _;
        root         ${NGINX_HTML_DIR};
        index        index.html;
        location / { try_files \$uri \$uri/ /index.html; }
        location /api/ { 
            proxy_pass http://127.0.0.1:8000/api/; 
            proxy_set_header Host \$host; 
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_connect_timeout 10s;
        }
    }
}
EOF
    # 启动服务+开放防火墙
    systemctl daemon-reload >/dev/null 2>&1
    systemctl restart nginx >/dev/null 2>&1
    systemctl enable --now ${SERVICE_NAME} >/dev/null 2>&1
    print_tip "开放防火墙端口（${GRPC_PORT}/tcp、${HTTP_PORT}/tcp）..."
    if [ -f /etc/redhat-release ]; then
        firewall-cmd --permanent --add-port={${GRPC_PORT},${HTTP_PORT}}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif [ -f /etc/debian_version ] && command -v ufw >/dev/null 2>&1; then
        ufw allow ${GRPC_PORT}/tcp >/dev/null 2>&1
        ufw allow ${HTTP_PORT}/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
    fi
    # 验证结果
    if check_installed && check_running; then
        print_ok "GOST V3轻量主控端【低配VPS优化版】安装成功！"
        echo -e "\n${GREEN_COLOR}===== 核心信息（务必保存）=====${RESET_COLOR}"
        echo -e "本机IP：$(get_ip)"
        echo -e "面板地址：http://<主控IP>:${HTTP_PORT}"
        echo -e "gRPC端口：${GRPC_PORT}（被控连接用）"
        echo -e "默认密钥：${RAND_KEY}（建议保存！）"
        echo -e "资源限制：CPU≤${CPU_QUOTA} | 内存≤${MEMORY_LIMIT}"
        echo -e "${GREEN_COLOR}==============================${RESET_COLOR}"
    else
        print_err "安装成功但服务启动失败！执行选项10生成排错日志"
        kill_stuck_process
        systemctl restart ${SERVICE_NAME} nginx >/dev/null 2>&1
    fi
}

# ==================== 基础功能：启停/状态/日志等 ====================
start_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    check_running && { print_ok "主控端已在运行！"; return 0; }
    kill_stuck_process
    print_tip "启动主控端（低配VPS启动可能较慢，请耐心等待）..."
    systemctl start ${SERVICE_NAME} nginx && print_ok "主控端启动成功！" || { print_err "启动失败！"; kill_stuck_process; }
}
stop_master() {
    [ ! check_installed ] && { print_err "未检测到主控端！"; return 0; }
    [ ! check_running ] && { print_ok "主控端已停止！"; return 0; }
    systemctl stop ${SERVICE_NAME} nginx && print_ok "主控端已停止！"
    kill_stuck_process
}
restart_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    kill_stuck_process
    print_tip "重启主控端（低配VPS重启可能较慢）..."
    systemctl restart ${SERVICE_NAME} nginx && print_ok "主控端重启成功！" || { print_err "重启失败！"; kill_stuck_process; }
}
status_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    echo -e "\n===== GOST V3轻量主控端 运行状态（低配优化版） ====="
    echo -e "服务状态：$(check_running && echo -e "${GREEN_COLOR}运行中${RESET_COLOR}" || echo -e "${RED_COLOR}已停止${RESET_COLOR}")"
    echo -e "本机IP：$(get_ip)"
    echo -e "配置信息：gRPC=${GRPC_PORT} | 面板=${HTTP_PORT} | CPU≤${CPU_QUOTA} | 内存≤${MEMORY_LIMIT}"
    echo -e "核心路径：安装=${GOST_MASTER_DIR}/bin/gost | 配置=${GOST_MASTER_DIR}/conf"
    echo -e "======================================="
    systemctl status ${SERVICE_NAME} nginx --no-pager -l | grep -E 'Active|Main PID|Status' || true
}
log_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    echo -e "\n===== 主控端实时日志（仅错误日志，按Ctrl+C退出）=====\n"
    journalctl -u ${SERVICE_NAME} -f -p err
}
config_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    echo -e "\n===== 修改主控端核心配置（低配VPS建议默认端口） ==
