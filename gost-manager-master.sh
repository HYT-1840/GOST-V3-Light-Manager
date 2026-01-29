#!/bin/bash
set -euo pipefail
# GOST V3 轻量主控端 交互式管理脚本【优化版】
# 新增：端口占用检测/连通性测试/配置备份恢复/一键排错/极致资源限制/SQLite优化
# 适配：CentOS7+/Ubuntu18+/Debian10+ | x86_64/arm64 | 资源＜50M | ≤50节点
# 配套：与优化版被控节点脚本无缝对接

# ==================== 核心配置（可直接修改）====================
GRPC_PORT="50051"
HTTP_PORT="8080"  # 优化：默认改8080，避免80端口被占用
GOST_MASTER_DIR="/usr/local/gost-master"
NGINX_HTML_DIR="/usr/share/nginx/html/gost-panel"
SERVICE_NAME="gost-master"
GOST_VERSION="3.0.0"
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
# 颜色定义
RED_COLOR="\033[31m"
GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
BLUE_COLOR="\033[34m"
RESET_COLOR="\033[0m"
# 资源限制（优化：极致压榨）
CPU_QUOTA="10%"
MEMORY_LIMIT="32M"
IO_LIMIT="1M"

# ==================== 工具函数（优化增强）====================
print_ok() { echo -e "${GREEN_COLOR}✅ $1${RESET_COLOR}"; }
print_err() { echo -e "${RED_COLOR}❌ $1${RESET_COLOR}"; }
print_tip() { echo -e "${YELLOW_COLOR}💡 $1${RESET_COLOR}"; }
print_info() { echo -e "${BLUE_COLOR}ℹ️  $1${RESET_COLOR}"; }

# 检查是否已安装
check_installed() { [ -f "${GOST_MASTER_DIR}/bin/gost" ] && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && return 0 || return 1; }
# 检查服务是否运行
check_running() { systemctl is-active --quiet ${SERVICE_NAME} && return 0 || return 1; }
# 优化：端口占用检测
check_port() { netstat -tulnp 2>/dev/null | grep -q ":$1 " && return 0 || return 1; }
# 优化：获取内外网IP
get_ip() {
    INNER_IP=$(ip addr | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
    OUTER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "未获取到")
    echo "内网：$INNER_IP | 外网：$OUTER_IP"
}
# 生成随机密钥（优化：统一密钥规则，≥8位字母数字）
gen_rand_key() { tr -dc A-Za-z0-9 </dev/urandom | head -c 16; echo; }

# ==================== 新增核心功能 - 配置备份 ====================
backup_config() {
    if ! check_installed; then print_err "未检测到主控端，无需备份！"; return 0; fi
    print_tip "开始备份核心配置（配置文件+数据库）..."
    BACKUP_NAME="gost-master-backup-$(date +%Y%m%d%H%M%S).tar.gz"
    BACKUP_PATH="/root/${BACKUP_NAME}"
    tar -zcf ${BACKUP_PATH} ${GOST_MASTER_DIR}/conf/ ${GOST_MASTER_DIR}/data/ >/dev/null 2>&1
    if [ -f "${BACKUP_PATH}" ]; then
        print_ok "备份成功！备份文件：${BACKUP_PATH}（大小：$(du -sh ${BACKUP_PATH} | awk '{print $1}')）"
    else
        print_err "备份失败！"
    fi
}

# ==================== 新增核心功能 - 配置恢复 ====================
restore_config() {
    if ! check_installed; then print_err "未检测到主控端，请先安装！"; return 0; fi
    print_tip "请输入备份文件路径（例：/root/gost-master-backup-20260129100000.tar.gz）："
    read -p "备份文件路径：" BACKUP_PATH
    if [ ! -f "${BACKUP_PATH}" ]; then print_err "备份文件不存在！"; return 0; fi
    print_tip "恢复中，将停止主控服务..."
    systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
    tar -zxf ${BACKUP_PATH} -C / >/dev/null 2>&1
    systemctl start ${SERVICE_NAME} >/dev/null 2>&1
    print_ok "配置恢复完成！已重启主控服务"
}

# ==================== 新增核心功能 - 连通性测试 ====================
check_connect() {
    if ! check_installed; then print_err "未检测到主控端，请先安装！"; return 0; fi
    print_info "主控端核心端口连通性测试（gRPC：${GRPC_PORT} | 面板：${HTTP_PORT}）"
    print_info "本机IP：$(get_ip)"
    for PORT in ${GRPC_PORT} ${HTTP_PORT}; do
        if check_port ${PORT}; then
            print_ok "端口${PORT}：已监听（进程：$(netstat -tulnp 2>/dev/null | grep ":$PORT " | awk '{print $7}' | cut -d/ -f2)）"
        else
            print_err "端口${PORT}：未监听/未开放！"
        fi
    done
    print_tip "被控节点可执行 telnet 主控IP ${GRPC_PORT} 测试连通性"
}

# ==================== 新增核心功能 - 一键排错 ====================
debug_log() {
    if ! check_installed; then print_err "未检测到主控端，请先安装！"; return 0; fi
    print_tip "生成一键排错日志，请勿中断..."
    DEBUG_NAME="gost-master-debug-$(date +%Y%m%d%H%M%S).tar.gz"
    DEBUG_PATH="/root/${DEBUG_NAME}"
    mkdir -p /tmp/gost-debug/
    # 收集核心信息
    echo "=== 系统信息 ===" >/tmp/gost-debug/system.info && uname -a >>/tmp/gost-debug/system.info && free -h >>/tmp/gost-debug/system.info
    echo "=== 端口占用 ===" >/tmp/gost-debug/port.info && netstat -tulnp 2>/dev/null >>/tmp/gost-debug/port.info
    echo "=== 服务状态 ===" >/tmp/gost-debug/status.info && systemctl status ${SERVICE_NAME} nginx --no-pager >>/tmp/gost-debug/status.info
    echo "=== 实时日志 ===" >/tmp/gost-debug/log.info && journalctl -u ${SERVICE_NAME} -n 50 --no-pager >>/tmp/gost-debug/log.info
    echo "=== 配置文件 ===" >/tmp/gost-debug/config.yaml && cp ${GOST_MASTER_DIR}/conf/config.yaml /tmp/gost-debug/
    echo "=== 防火墙配置 ===" >/tmp/gost-debug/firewall.info && (firewall-cmd --list-ports 2>/dev/null || ufw status 2>/dev/null) >>/tmp/gost-debug/firewall.info
    # 打包
    tar -zcf ${DEBUG_PATH} /tmp/gost-debug/ >/dev/null 2>&1
    rm -rf /tmp/gost-debug/
    print_ok "排错日志生成完成！文件路径：${DEBUG_PATH}（发送此文件即可快速排错）"
}

# ==================== 新增核心功能 - SQLite优化 ====================
sqlite_optimize() {
    if ! check_installed; then print_err "未检测到主控端，请先安装！"; return 0; fi
    if [ ! -f "${GOST_MASTER_DIR}/data/gost-master.db" ]; then print_err "SQLite数据库文件不存在！"; return 0; fi
    print_tip "开始优化SQLite数据库（碎片清理+体积压缩）..."
    sqlite3 ${GOST_MASTER_DIR}/data/gost-master.db "VACUUM;" >/dev/null 2>&1
    sqlite3 ${GOST_MASTER_DIR}/data/gost-master.db "ANALYZE;" >/dev/null 2>&1
    print_ok "数据库优化完成！当前数据库大小：$(du -sh ${GOST_MASTER_DIR}/data/gost-master.db | awk '{print $1}')"
}

# ==================== 核心功能 - 1. 安装主控端（优化增强）====================
install_master() {
    if check_installed; then
        print_tip "检测到GOST主控端已安装！"
        read -p "是否重新安装（覆盖配置，y/n）：" CHOICE
        [ "${CHOICE}" != "y" ] && [ "${CHOICE}" != "Y" ] && { print_ok "取消重新安装"; return 0; }
        systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
    fi

    # 优化：端口占用预检测
    print_tip "端口预检测（gRPC：${GRPC_PORT} | 面板：${HTTP_PORT}）..."
    if check_port ${GRPC_PORT}; then print_err "gRPC端口${GRPC_PORT}已被占用！请修改脚本开头配置"; exit 1; fi
    if check_port ${HTTP_PORT}; then print_err "面板端口${HTTP_PORT}已被占用！请修改脚本开头配置"; exit 1; fi

    echo -e "\n===== 开始安装GOST V3轻量主控端【优化版】===="
    print_tip "安装基础依赖（nginx/wget/tar/sqlite3）..."
    if [ -f /etc/redhat-release ]; then
        yum install -y nginx wget tar sqlite3 net-tools >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    elif [ -f /etc/debian_version ]; then
        apt update -y >/dev/null 2>&1 && apt install -y nginx wget tar sqlite3 net-tools >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    else
        print_err "仅支持CentOS/Ubuntu/Debian！"; exit 1;
    fi
    systemctl enable --now nginx >/dev/null 2>&1

    # 下载GOST
    print_tip "下载GOST V${GOST_VERSION}（架构：${ARCH}）..."
    mkdir -p ${GOST_MASTER_DIR}/{bin,conf,data,log}
    GOST_TAR="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${GOST_TAR}"
    wget -q -O /tmp/${GOST_TAR} ${GOST_URL} || { print_err "GOST下载失败"; exit 1; }
    tar zxf /tmp/${GOST_TAR} -C ${GOST_MASTER_DIR}/bin gost >/dev/null 2>&1
    chmod +x ${GOST_MASTER_DIR}/bin/gost && rm -rf /tmp/${GOST_TAR}
    ${GOST_MASTER_DIR}/bin/gost -V >/dev/null 2>&1 || { print_err "安装验证失败"; exit 1; }

    # 生成配置+TLS证书
    print_tip "生成主控配置+TLS加密证书..."
    RAND_KEY=$(gen_rand_key)
    cat > ${GOST_MASTER_DIR}/conf/config.yaml <<EOF
log: level: warn; file: ${GOST_MASTER_DIR}/log/gost-master.log; max-size: 50; max-age: 3
db: type: sqlite; dsn: ${GOST_MASTER_DIR}/data/gost-master.db
server: grpc: addr: :${GRPC_PORT}; tls: true; cert: ${GOST_MASTER_DIR}/conf/cert.pem; key: ${GOST_MASTER_DIR}/conf/key.pem
control: enabled: true; auth: true
EOF
    sed -i 's/;/\n  /g' ${GOST_MASTER_DIR}/conf/config.yaml
    ${GOST_MASTER_DIR}/bin/gost cert -gen -out ${GOST_MASTER_DIR}/conf/cert.pem -key ${GOST_MASTER_DIR}/conf/key.pem >/dev/null 2>&1

    # 优化：Systemd服务（严格资源限制+启动延迟）
    print_tip "配置Systemd服务（资源限制+开机自启）..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=GOST V3 Light Master [Optimized]
After=network.target nginx.service
Wants=network.target
ExecStartPre=/bin/sleep 3  # 优化：延迟3秒，等网络就绪

[Service]
Type=simple
User=root
WorkingDirectory=${GOST_MASTER_DIR}
ExecStart=${GOST_MASTER_DIR}/bin/gost -C ${GOST_MASTER_DIR}/conf/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=10240
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
# 优化：极致资源限制
CPUQuota=${CPU_QUOTA}
MemoryLimit=${MEMORY_LIMIT}
IOReadBandwidthMax=/dev/sda ${IO_LIMIT}
IOWriteBandwidthMax=/dev/sda ${IO_LIMIT}

[Install]
WantedBy=multi-user.target
EOF

    # 优化：Nginx极致轻量配置
    print_tip "配置Nginx轻量版（关闭冗余模块）..."
    mkdir -p ${NGINX_HTML_DIR}
    wget -q -O ${NGINX_HTML_DIR}/index.html https://gost.run/static/panel/index.html || print_tip "面板文件下载失败，可手动放入"
    cat > /etc/nginx/nginx.conf <<EOF
user root;
worker_processes 1;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
worker_rlimit_nofile 1024;  # 优化：降低资源
events { worker_connections 1024; use epoll; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    access_log off; gzip off; tcp_nopush on; tcp_nodelay on;  # 优化：关闭冗余
    server {
        listen       ${HTTP_PORT};
        server_name  _;
        root         ${NGINX_HTML_DIR};
        index        index.html index.htm;
        location / { try_files \$uri \$uri/ /index.html; }
        location /api/ { proxy_pass http://127.0.0.1:8000/api/; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
    }
}
EOF

    # 启动服务+开放防火墙
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now ${SERVICE_NAME} >/dev/null 2>&1
    systemctl restart nginx >/dev/null 2>&1
    print_tip "开放防火墙端口（${GRPC_PORT}/tcp、${HTTP_PORT}/tcp）..."
    if [ -f /etc/redhat-release ]; then
        firewall-cmd --permanent --add-port={${GRPC_PORT},${HTTP_PORT}}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif [ -f /etc/debian_version ] && command -v ufw >/dev/null 2>&1; then
        ufw allow ${GRPC_PORT}/tcp >/dev/null 2>&1
        ufw allow ${HTTP_PORT}/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
    fi

    # 验证安装
    if check_installed && check_running; then
        print_ok "GOST V3轻量主控端安装成功！"
        echo -e "\n${GREEN_COLOR}===== 主控端核心信息 =====${RESET_COLOR}"
        echo -e "本机IP：$(get_ip)"
        echo -e "面板地址：http://<主控IP>:${HTTP_PORT}"
        echo -e "gRPC端口：${GRPC_PORT}（被控节点连接用）"
        echo -e "默认随机密钥：${RAND_KEY}（建议保存，被控节点使用）"
        echo -e "数据库路径：${GOST_MASTER_DIR}/data/gost-master.db"
        echo -e "${GREEN_COLOR}=========================${RESET_COLOR}"
    else
        print_err "安装成功但服务启动失败！执行 选项10 生成排错日志"
    fi
}

# ==================== 核心功能 - 2-8 保留原逻辑（略作优化）====================
start_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    check_running && { print_ok "主控端已在运行！"; return 0; }
    systemctl start ${SERVICE_NAME} nginx && print_ok "主控端启动成功！" || print_err "启动失败！"
}
stop_master() {
    [ ! check_installed ] && { print_err "未检测到主控端！"; return 0; }
    [ ! check_running ] && { print_ok "主控端已停止！"; return 0; }
    systemctl stop ${SERVICE_NAME} nginx && print_ok "主控端已停止！"
}
restart_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    systemctl restart ${SERVICE_NAME} nginx && print_ok "主控端重启成功！" || print_err "重启失败！"
}
status_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    echo -e "\n===== GOST V3轻量主控端 运行状态 ====="
    echo -e "服务状态：$(check_running && echo -e "${GREEN_COLOR}运行中${RESET_COLOR}" || echo -e "${RED_COLOR}已停止${RESET_COLOR}")"
    echo -e "本机IP：$(get_ip)"
    echo -e "配置信息：gRPC=${GRPC_PORT} | 面板=${HTTP_PORT} | CPU=${CPU_QUOTA} | 内存=${MEMORY_LIMIT}"
    echo -e "核心路径：安装=${GOST_MASTER_DIR}/bin/gost | 配置=${GOST_MASTER_DIR}/conf | 数据库=${GOST_MASTER_DIR}/data"
    echo -e "======================================="
    systemctl status ${SERVICE_NAME} nginx --no-pager
}
log_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    echo -e "\n===== 主控端实时日志（按Ctrl+C退出）=====\n"
    journalctl -u ${SERVICE_NAME} -f
}
config_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，请先安装！"; return 0; }
    echo -e "\n===== 修改主控端核心配置 ====="
    echo -e "当前配置：gRPC=${GRPC_PORT} | 面板=${HTTP_PORT}"
    read -p "新gRPC端口（默认${GRPC_PORT}）：" NEW_GRPC
    read -p "新面板端口（默认${HTTP_PORT}）：" NEW_HTTP
    GRPC_PORT=${NEW_GRPC:-${GRPC_PORT}}
    HTTP_PORT=${NEW_HTTP:-${HTTP_PORT}}
    # 优化：端口格式+占用检测
    if ! [[ "${GRPC_PORT}" =~ ^[0-9]{1,5}$ && "${HTTP_PORT}" =~ ^[0-9]{1,5}$ ]]; then
        print_err "端口格式错误！必须是1-65535的数字"; return 0;
    fi
    if check_port ${GRPC_PORT} || check_port ${HTTP_PORT}; then
        print_err "新端口已被占用！请更换"; return 0;
    fi
    # 重新生成配置
    cat > ${GOST_MASTER_DIR}/conf/config.yaml <<EOF
log: level: warn; file: ${GOST_MASTER_DIR}/log/gost-master.log; max-size: 50; max-age: 3
db: type: sqlite; dsn: ${GOST_MASTER_DIR}/data/gost-master.db
server: grpc: addr: :${GRPC_PORT}; tls: true; cert: ${GOST_MASTER_DIR}/conf/cert.pem; key: ${GOST_MASTER_DIR}/conf/key.pem
control: enabled: true; auth: true
EOF
    sed -i 's/;/\n  /g' ${GOST_MASTER_DIR}/conf/config.yaml
    # 重新生成Nginx配置
    cat > /etc/nginx/nginx.conf <<EOF
user root; worker_processes 1; error_log /var/log/nginx/error.log warn; pid /var/run/nginx.pid;
events { worker_connections 1024; use epoll; }
http { include /etc/nginx/mime.types; default_type application/octet-stream; sendfile on; keepalive_timeout 65; access_log off; gzip off;
    server { listen ${HTTP_PORT}; server_name _; root ${NGINX_HTML_DIR}; index index.html;
        location / { try_files \$uri \$uri/ /index.html; }
        location /api/ { proxy_pass http://127.0.0.1:8000/api/; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
    }
}
EOF
    # 开放新端口+重启
    if [ -f /etc/redhat-release ]; then
        firewall-cmd --permanent --add-port={${GRPC_PORT},${HTTP_PORT}}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif [ -f /etc/debian_version ] && command -v ufw >/dev/null 2>&1; then
        ufw allow ${GRPC_PORT}/tcp >/dev/null 2>&1
        ufw allow ${HTTP_PORT}/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
    fi
    systemctl daemon-reload >/dev/null 2>&1
    systemctl restart ${SERVICE_NAME} nginx >/dev/null 2>&1
    print_ok "配置修改成功！新配置：gRPC=${GRPC_PORT} | 面板=${HTTP_PORT}，已重启服务"
}
uninstall_master() {
    [ ! check_installed ] && { print_err "未检测到主控端，无需卸载！"; return 0; }
    echo -e "\n${RED_COLOR}⚠️  警告：卸载将删除所有数据（配置/数据库/日志），且无法恢复！${RESET_COLOR}"
    read -p "请输入 uninstall 确认卸载：" CHOICE
    [ "${CHOICE}" != "uninstall" ] && { print_ok "取消卸载"; return 0; }
    # 停止服务+删除文件
    systemctl stop ${SERVICE_NAME} nginx >/dev/null 2>&1
    systemctl disable ${SERVICE_NAME} nginx >/dev/null 2>&1
    rm -rf ${GOST_MASTER_DIR} ${NGINX_HTML_DIR} /etc/systemd/system/${SERVICE_NAME}.service /etc/nginx/nginx.conf
    systemctl daemon-reload >/dev/null 2>&1
    # 可选卸载依赖
    read -p "是否卸载基础依赖（nginx/wget等，y/n）：" DEP_CHOICE
    if [ "${DEP_CHOICE}" = "y" ] || [ "${DEP_CHOICE}" = "Y" ]; then
        [ -f /etc/redhat-release ] && yum remove -y nginx wget tar sqlite3 net-tools >/dev/null 2>&1
        [ -f /etc/debian_version ] && apt remove -y nginx wget tar sqlite3 net-tools >/dev/null 2>&1
        print_tip "基础依赖已卸载"
    fi
    print_ok "GOST主控端已完全卸载，无残留！"
}

# ==================== 主菜单（新增优化功能选项）====================
main() {
    clear
    echo -e "======================================"
    echo -e "  GOST V3 轻量主控端 交互式管理【优化版】"
    echo -e "  适配：≤50节点 | 整体资源＜50M | 极致优化"
    echo -e "======================================"
    echo -e "  1. 安装主控端（一键部署+端口检测+随机密钥）"
    echo -e "  2. 启动主控端"
    echo -e "  3. 停止主控端"
    echo -e "  4. 重启主控端"
    echo -e "  5. 查看运行状态"
    echo -e "  6. 查看实时日志（排错用）"
    echo -e "  7. 修改核心配置（gRPC/面板端口）"
    echo -e "  8. 卸载主控端（需验证+彻底清理）"
    echo -e "  9. 配置备份恢复（配置+数据库）"
    echo -e "10. 一键生成排错日志（快速定位问题）"
    echo -e "11. 检测端口连通性（本机+核心端口）"
    echo -e "12. 优化SQLite数据库（碎片清理）"
    echo -e "  0. 退出脚本"
    echo -e "======================================"
    read -p "请输入操作选项（0-12）：" OPTION
    case ${OPTION} in
        1) install_master ;;
        2) start_master ;;
        3) stop_master ;;
        4) restart_master ;;
        5) status_master ;;
        6) log_master ;;
        7) config_master ;;
        8) uninstall_master ;;
        9) echo -e "\n1. 备份配置\n2. 恢复配置"; read -p "选1/2：" b; [ $b -eq 1 ] && backup_config || restore_config ;;
        10) debug_log ;;
        11) check_connect ;;
        12) sqlite_optimize ;;
        0) print_ok "退出脚本，再见！"; exit 0 ;;
        *) print_err "无效选项，请输入0-12之间的数字！" ;;
    esac
    # 操作完成后停留
    echo -e "\n${YELLOW_COLOR}按任意键返回主菜单...${RESET_COLOR}"
    read -n 1 -s
    main
}

# 启动主菜单
main
