#!/bin/bash
set -euo pipefail
# GOST V3 主控+被控一体化轻量脚本 | 正常VPS版 | 仅保留核心必要功能
# 日志优化：时间戳+INFO/ERROR分级+自动归档 | 联动核心：gRPC+16位密钥认证

# 全局基础配置（极简版，仅保留必要项）
MASTER_SERVICE="gost-master"
NODE_SERVICE="gost-node"
MASTER_DIR="/usr/local/gost-master"
NODE_DIR="/usr/local/gost-node"
MASTER_GRPC=""
AUTH_KEY=""
GRPC_PORT=${GRPC_PORT:-50051}
HTTP_PORT=${HTTP_PORT:-8080}
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
MAX_OPEN_FILES=8192
LOG_MAX_SIZE=100
LOG_MAX_AGE=7
MASTER_LOG="${MASTER_DIR}/gost-master.log"
NODE_LOG="${NODE_DIR}/gost-node.log"

# 颜色与日志函数（极简版，保留核心区分）
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"
log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1${RESET}"; }
err() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1${RESET}"; }
ok() { echo -e "${GREEN}✅ $1${RESET}"; }
tip() { echo -e "${YELLOW}💡 $1${RESET}"; }

# 工具函数（极简，仅保留必要检测）
check_master_installed() { [ -f "${MASTER_DIR}/gost" ] && [ -f "/etc/systemd/system/${MASTER_SERVICE}.service" ]; }
check_node_installed() { [ -f "${NODE_DIR}/gost" ] && [ -f "/etc/systemd/system/${NODE_SERVICE}.service" ]; }
check_running() { systemctl is-active --quiet $1; }
get_latest_gost() { curl -s --connect-timeout 10 https://api.github.com/repos/go-gost/gost/releases/latest | grep 'tag_name' | cut -d'"' -f4 | sed 's/v//g'; }
get_ip() { ip addr | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "未知IP"; }
check_key() { [[ "${AUTH_KEY:-}" =~ ^[a-zA-Z0-9]{16}$ ]]; }

# ==================== 主控端核心功能（仅保留必要）====================
install_master() {
    check_master_installed && { tip "主控已安装"; read -p "是否重装(y/n)：" c; [ "$c" != "y" ] && return 0; }
    log "开始安装GOST主控端 | 端口：gRPC${GRPC_PORT} / 面板${HTTP_PORT}"
    [ $(netstat -tulnp 2>/dev/null | grep -c ":${GRPC_PORT}\|:${HTTP_PORT}") -gt 0 ] && { err "端口被占用"; return 1; }

    # 安装依赖+下载GOST
    [ -f /etc/redhat-release ] && yum install -y -q nginx wget tar net-tools >/dev/null 2>&1
    [ -f /etc/debian_version ] && apt update -y -qq >/dev/null 2>&1 && apt install -y -qq nginx wget tar net-tools >/dev/null 2>&1
    VER=$(get_latest_gost) || { err "获取GOST版本失败"; return 1; }
    wget -q --timeout=30 https://github.com/go-gost/gost/releases/download/v${VER}/gost_${VER}_linux_${ARCH}.tar.gz -O /tmp/gost.tar.gz
    mkdir -p ${MASTER_DIR} && tar zxf /tmp/gost.tar.gz -C ${MASTER_DIR} gost >/dev/null 2>&1 && chmod +x ${MASTER_DIR}/gost && rm -f /tmp/gost.tar.gz

    # 生成密钥+配置
    AUTH_KEY=$(head -c 16 /dev/urandom | xxd -p | head -c 16)
    ${MASTER_DIR}/gost cert -gen -out ${MASTER_DIR}/cert.pem -key ${MASTER_DIR}/key.pem >/dev/null 2>&1
    cat > ${MASTER_DIR}/config.yaml <<EOF
log: {level: info, file: ${MASTER_LOG}, max-size: ${LOG_MAX_SIZE}, max-age: ${LOG_MAX_AGE}, format: "[%Y-%m-%d %H:%M:%S] [%L] %m"}
db: {type: sqlite, dsn: ${MASTER_DIR}/gost.db}
server: {grpc: {addr: :${GRPC_PORT}, tls: true, cert: ${MASTER_DIR}/cert.pem, key: ${MASTER_DIR}/key.pem}, http: {addr: :8000}}
control: {enabled: true, auth: true}
EOF

    # Systemd+Nginx配置
    cat > /etc/systemd/system/${MASTER_SERVICE}.service <<EOF
[Unit] Description=GOST Master After=network.target nginx.service
[Service] Type=simple ExecStart=${MASTER_DIR}/gost -C ${MASTER_DIR}/config.yaml Restart=on-failure RestartSec=3 LimitNOFILE=${MAX_OPEN_FILES}
[Install] WantedBy=multi-user.target
EOF
    cat > /etc/nginx/nginx.conf <<EOF
user root; worker_processes auto; events { worker_connections 1024; }
http { include mime.types; default_type application/octet-stream; sendfile on;
server { listen ${HTTP_PORT}; root ${MASTER_DIR}; index index.html;
wget -q --timeout=20 https://gost.run/static/panel/index.html -O ${MASTER_DIR}/index.html 2>/dev/null
location /api/ { proxy_pass http://127.0.0.1:8000/api/; proxy_set_header X-Real-IP \$remote_addr; }}}
EOF

    # 启动+开放端口
    systemctl daemon-reload && systemctl enable --now ${MASTER_SERVICE} nginx >/dev/null 2>&1
    [ -f /etc/redhat-release ] && firewall-cmd --permanent --add-port={${GRPC_PORT},${HTTP_PORT}}/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1
    [ -f /etc/debian_version ] && command -v ufw >/dev/null 2>&1 && ufw allow ${GRPC_PORT}/tcp ${HTTP_PORT}/tcp >/dev/null 2>&1

    sleep 2 && check_running ${MASTER_SERVICE} && {
        ok "主控安装完成！核心信息如下："
        echo -e "外网IP：$(curl -s ip.sb) | 内网IP：$(get_ip)"
        echo -e "面板地址：http://<主控IP>:${HTTP_PORT}"
        echo -e "gRPC地址：$(curl -s ip.sb):${GRPC_PORT} | 认证密钥：${AUTH_KEY}"
        echo -e "日志路径：${MASTER_LOG}"
    } || err "主控启动失败"
}

# 主控基础操作
start_master() { check_master_installed || { err "主控未安装"; return 1; }; systemctl start ${MASTER_SERVICE} nginx && ok "主控启动成功" || err "启动失败"; }
stop_master() { check_master_installed || { err "主控未安装"; return 1; }; systemctl stop ${MASTER_SERVICE} nginx && ok "主控停止成功" || err "停止失败"; }
restart_master() { check_master_installed || { err "主控未安装"; return 1; }; systemctl restart ${MASTER_SERVICE} nginx && ok "主控重启成功" || err "重启失败"; }
status_master() {
    check_master_installed || { err "主控未安装"; return 1; }
    echo -e "\nGOST主控状态：$(check_running ${MASTER_SERVICE} && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}已停止${RESET}")"
    echo -e "核心配置：gRPC${GRPC_PORT} | 面板${HTTP_PORT} | 密钥${AUTH_KEY:-未配置}"
    echo -e "日志路径：${MASTER_LOG} | 安装路径：${MASTER_DIR}"
    systemctl status ${MASTER_SERVICE} --no-pager -l | grep -E 'Active|Main PID' || true
}
log_master() { check_master_installed || { err "主控未安装"; return 1; }; echo -e "${PURPLE}主控实时日志（Ctrl+C退出）${RESET}"; tail -f ${MASTER_LOG} | awk '{if($0~/\[ERROR\]/)print "\033[31m"$0"\033[0m";else print $0}'; }
uninstall_master() {
    check_master_installed || { err "主控未安装"; return 1; }
    read -p "确认卸载主控(输入uninstall)：" c; [ "$c" != "uninstall" ] && return 0
    systemctl stop ${MASTER_SERVICE} nginx >/dev/null 2>&1
    systemctl disable ${MASTER_SERVICE} >/dev/null 2>&1
    rm -rf ${MASTER_DIR} /etc/systemd/system/${MASTER_SERVICE}.service
    systemctl daemon-reload && ok "主控已完全卸载"
}

# ==================== 被控端核心功能（仅保留必要）====================
install_node() {
    check_node_installed && { tip "被控已安装"; read -p "是否重装(y/n)：" c; [ "$c" != "y" ] && return 0; }
    log "开始安装GOST被控端 | 需输入主控gRPC地址+密钥"
    read -p "主控gRPC地址(例：1.2.3.4:50051)：" MASTER_GRPC
    read -p "主控认证密钥(16位)：" AUTH_KEY
    [[ ! "${MASTER_GRPC}" =~ ^[0-9.]+:[0-9]{1,5}$ ]] || ! check_key && { err "gRPC地址/密钥格式错误"; return 1; }

    # 安装依赖+下载GOST
    [ -f /etc/redhat-release ] && yum install -y -q wget tar net-tools >/dev/null 2>&1
    [ -f /etc/debian_version ] && apt update -y -qq >/dev/null 2>&1 && apt install -y -qq wget tar net-tools >/dev/null 2>&1
    VER=$(get_latest_gost) || { err "获取GOST版本失败"; return 1; }
    wget -q --timeout=30 https://github.com/go-gost/gost/releases/download/v${VER}/gost_${VER}_linux_${ARCH}.tar.gz -O /tmp/gost.tar.gz
    mkdir -p ${NODE_DIR} && tar zxf /tmp/gost.tar.gz -C ${NODE_DIR} gost >/dev/null 2>&1 && chmod +x ${NODE_DIR}/gost && rm -f /tmp/gost.tar.gz

    # 生成配置+Systemd
    cat > ${NODE_DIR}/config.yaml <<EOF
log: {level: info, file: ${NODE_LOG}, max-size: ${LOG_MAX_SIZE}, max-age: ${LOG_MAX_AGE}, format: "[%Y-%m-%d %H:%M:%S] [%L] %m"}
node: {grpc: {addr: ${MASTER_GRPC}, tls: true, auth: {key: ${AUTH_KEY}}}}
control: {enabled: true}
EOF
    cat > /etc/systemd/system/${NODE_SERVICE}.service <<EOF
[Unit] Description=GOST Node After=network.target
[Service] Type=simple ExecStart=${NODE_DIR}/gost -C ${NODE_DIR}/config.yaml Restart=on-failure RestartSec=3 LimitNOFILE=${MAX_OPEN_FILES}
[Install] WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload && systemctl enable --now ${NODE_SERVICE} >/dev/null 2>&1
    sleep 2 && check_running ${NODE_SERVICE} && {
        ok "被控安装完成！"
        echo -e "本机IP：$(get_ip) | 关联主控：${MASTER_GRPC}"
        echo -e "日志路径：${NODE_LOG}"
    } || { err "被控启动失败"; log "请检查主控连通性/密钥是否正确"; }
}

# 被控基础操作
start_node() { check_node_installed || { err "被控未安装"; return 1; }; systemctl start ${NODE_SERVICE} && ok "被控启动成功" || err "启动失败"; }
stop_node() { check_node_installed || { err "被控未安装"; return 1; }; systemctl stop ${NODE_SERVICE} && ok "被控停止成功" || err "停止失败"; }
restart_node() { check_node_installed || { err "被控未安装"; return 1; }; systemctl restart ${NODE_SERVICE} && ok "被控重启成功" || err "重启失败"; }
status_node() {
    check_node_installed || { err "被控未安装"; return 1; }
    echo -e "\nGOST被控状态：$(check_running ${NODE_SERVICE} && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}已停止${RESET}")"
    echo -e "本机IP：$(get_ip) | 关联主控：${MASTER_GRPC:-未配置}"
    echo -e "日志路径：${NODE_LOG} | 安装路径：${NODE_DIR}"
    systemctl status ${NODE_SERVICE} --no-pager -l | grep -E 'Active|Main PID' || true
}
log_node() { check_node_installed || { err "被控未安装"; return 1; }; echo -e "${PURPLE}被控实时日志（Ctrl+C退出）${RESET}"; tail -f ${NODE_LOG} | awk '{if($0~/\[ERROR\]/)print "\033[31m"$0"\033[0m";else print $0}'; }
uninstall_node() {
    check_node_installed || { err "被控未安装"; return 1; }
    read -p "确认卸载被控(输入uninstall)：" c; [ "$c" != "uninstall" ] && return 0
    systemctl stop ${NODE_SERVICE} >/dev/null 2>&1
    systemctl disable ${NODE_SERVICE} >/dev/null 2>&1
    rm -rf ${NODE_DIR} /etc/systemd/system/${NODE_SERVICE}.service
    systemctl daemon-reload && ok "被控已完全卸载"
}

# ==================== 交互式菜单（极简）====================
main_menu() {
    clear
    echo -e "${BLUE}==================== GOST V3 主控+被控一体化脚本（正常VPS轻量版）====================${RESET}"
    echo -e "适配系统：CentOS7+/Ubuntu18+/Debian10+ | 架构：x86_64/arm64"
    echo -e "核心功能：仅保留安装/启停/状态/日志/卸载，无冗余功能"
    echo -e "${BLUE}====================================================================================${RESET}"
    echo -e "【主控端操作】"
    echo -e "1. 安装主控端    2. 启动主控    3. 停止主控    4. 重启主控"
    echo -e "5. 主控状态      6. 主控日志    7. 卸载主控"
    echo -e "\n【被控端操作】"
    echo -e "8. 安装被控端    9. 启动被控    10. 停止被控   11. 重启被控"
    echo -e "12. 被控状态     13. 被控日志   14. 卸载被控"
    echo -e "\n0. 退出脚本"
    echo -e "${BLUE}====================================================================================${RESET}"
    read -p "请输入操作编号：" num
    case $num in
        1) install_master ;;
        2) start_master ;;
        3) stop_master ;;
        4) restart_master ;;
        5) status_master ;;
        6) log_master ;;
        7) uninstall_master ;;
        8) install_node ;;
        9) start_node ;;
        10) stop_node ;;
        11) restart_node ;;
        12) status_node ;;
        13) log_node ;;
        14) uninstall_node ;;
        0) echo -e "${GREEN}退出脚本${RESET}"; exit 0 ;;
        *) tip "无效编号，请重新输入" ;;
    esac
    read -p "按任意键返回菜单..." -n1 -s
    main_menu
}

# 启动交互式菜单
main_menu
