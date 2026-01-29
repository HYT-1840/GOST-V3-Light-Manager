#!/bin/bash
set -euo pipefail
# GOST V3 主控+被控一体化轻量脚本 | 正常VPS版 | 带详细安装日志输出
# 核心特性：实时显示安装步骤/保留命令回显/无静默执行/快速定位问题

# 全局基础配置
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

# 颜色与日志函数（分级显示，日志更清晰）
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
PURPLE="\033[35m"
RESET="\033[0m"

# 详细日志：步骤信息（蓝色）
log_step() { echo -e "\n${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] [STEP] $1${RESET}"; }
# 详细日志：执行信息（紫色）
log_exec() { echo -e "${PURPLE}[$(date +'%Y-%m-%d %H:%M:%S')] [EXEC] $1${RESET}"; }
# 错误日志：红色高亮，便于定位
log_err() { echo -e "\n${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1${RESET}"; }
# 成功提示：绿色高亮
log_ok() { echo -e "${GREEN}✅ $1${RESET}"; }
# 注意提示：黄色高亮
log_tip() { echo -e "${YELLOW}💡 $1${RESET}"; }

# 工具函数（保留必要检测，无静默）
check_master_installed() { [ -f "${MASTER_DIR}/gost" ] && [ -f "/etc/systemd/system/${MASTER_SERVICE}.service" ]; }
check_node_installed() { [ -f "${NODE_DIR}/gost" ] && [ -f "/etc/systemd/system/${NODE_SERVICE}.service" ]; }
check_running() { systemctl is-active --quiet $1; }
get_latest_gost() { curl -s --connect-timeout 10 https://api.github.com/repos/go-gost/gost/releases/latest | grep 'tag_name' | cut -d'"' -f4 | sed 's/v//g'; }
get_ip() { ip addr | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "未知IP"; }
check_key() { [[ "${AUTH_KEY:-}" =~ ^[a-zA-Z0-9]{16}$ ]]; }
check_port() { netstat -tulnp 2>/dev/null | grep -c ":$1 " || true; }

# ==================== 主控端核心功能（带详细安装日志）====================
install_master() {
    if check_master_installed; then
        log_tip "检测到主控端已安装（路径：${MASTER_DIR}）"
        read -p "是否重新安装？(y/n)：" c
        [ "$c" != "y" ] && { log_step "取消重装，退出安装流程"; return 0; }
        log_step "开始卸载原有主控端，准备重装"
        systemctl stop ${MASTER_SERVICE} nginx 2>/dev/null || true
        rm -rf ${MASTER_DIR} /etc/systemd/system/${MASTER_SERVICE}.service 2>/dev/null || true
        log_ok "原有主控端卸载完成"
    fi

    log_step "========== 开始安装GOST主控端 =========="
    log_tip "核心配置：gRPC端口${GRPC_PORT} | 面板端口${HTTP_PORT} | 架构${ARCH}"

    # 步骤1：检测核心端口是否被占用
    log_step "步骤1/7：检测核心端口（${GRPC_PORT}/${HTTP_PORT}）占用情况"
    grpc_used=$(check_port ${GRPC_PORT})
    http_used=$(check_port ${HTTP_PORT})
    if [ $grpc_used -gt 0 ] || [ $http_used -gt 0 ]; then
        log_err "端口占用检测失败！"
        [ $grpc_used -gt 0 ] && log_err "gRPC端口${GRPC_PORT}已被占用，占用进程：$(netstat -tulnp 2>/dev/null | grep :${GRPC_PORT})"
        [ $http_used -gt 0 ] && log_err "面板端口${HTTP_PORT}已被占用，占用进程：$(netstat -tulnp 2>/dev/null | grep :${HTTP_PORT})"
        log_tip "解决方案：关闭占用进程，或修改脚本开头GRPC_PORT/HTTP_PORT配置"
        return 1
    fi
    log_ok "端口检测通过，无占用"

    # 步骤2：安装系统基础依赖
    log_step "步骤2/7：安装系统基础依赖（nginx/wget/tar/net-tools）"
    if [ -f /etc/redhat-release ]; then
        log_exec "执行命令：yum install -y nginx wget tar net-tools"
        yum install -y nginx wget tar net-tools
    elif [ -f /etc/debian_version ]; then
        log_exec "执行命令：apt update && apt install -y nginx wget tar net-tools"
        apt update
        apt install -y nginx wget tar net-tools
    else
        log_err "不支持当前系统！仅支持CentOS7+/Ubuntu18+/Debian10+"
        return 1
    fi
    log_ok "系统依赖安装完成"

    # 步骤3：获取最新GOST版本并下载
    log_step "步骤3/7：获取最新GOST版本并下载二进制文件"
    log_exec "执行命令：获取GitHub最新GOST版本"
    VER=$(get_latest_gost)
    if [ -z "${VER}" ]; then
        log_err "获取GOST最新版本失败！"
        log_tip "解决方案：检查VPS到GitHub的网络连通性，或手动配置代理"
        return 1
    fi
    log_ok "成功获取GOST最新版本：v${VER}"
    
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${VER}/gost_${VER}_linux_${ARCH}.tar.gz"
    log_exec "执行命令：wget ${GOST_URL} -O /tmp/gost.tar.gz"
    wget --timeout=30 ${GOST_URL} -O /tmp/gost.tar.gz
    if [ ! -f /tmp/gost.tar.gz ] || [ ! -s /tmp/gost.tar.gz ]; then
        log_err "GOST二进制文件下载失败！文件不存在或为空"
        return 1
    fi
    log_ok "GOST v${VER} 二进制文件下载完成（路径：/tmp/gost.tar.gz）"

    # 步骤4：解压并安装GOST
    log_step "步骤4/7：解压GOST并创建安装目录（${MASTER_DIR}）"
    log_exec "执行命令：mkdir -p ${MASTER_DIR} && tar zxf /tmp/gost.tar.gz -C ${MASTER_DIR} gost"
    mkdir -p ${MASTER_DIR}
    tar zxf /tmp/gost.tar.gz -C ${MASTER_DIR} gost
    log_exec "执行命令：chmod +x ${MASTER_DIR}/gost && rm -f /tmp/gost.tar.gz"
    chmod +x ${MASTER_DIR}/gost
    rm -f /tmp/gost.tar.gz
    
    if [ ! -f "${MASTER_DIR}/gost" ]; then
        log_err "GOST解压安装失败！可执行文件不存在"
        return 1
    fi
    log_ok "GOST解压安装完成，可执行文件：${MASTER_DIR}/gost"

    # 步骤5：生成认证密钥和TLS加密证书
    log_step "步骤5/7：生成16位认证密钥和TLS加密证书"
    log_exec "执行命令：生成16位随机认证密钥"
    AUTH_KEY=$(head -c 16 /dev/urandom | xxd -p | head -c 16)
    log_ok "成功生成认证密钥：${AUTH_KEY}（请妥善保存，被控端需使用）"
    
    log_exec "执行命令：用OpenSSL生成TLS证书（替代GOST原生命令，无兼容问题）"
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout ${MASTER_DIR}/key.pem -out ${MASTER_DIR}/cert.pem -subj "/CN=gost.local"
    if [ ! -f "${MASTER_DIR}/cert.pem" ] || [ ! -f "${MASTER_DIR}/key.pem" ]; then
        log_err "TLS证书生成失败！"
        return 1
    fi
    log_ok "TLS加密证书生成完成（cert.pem/key.pem）"

    # 步骤6：生成GOST配置文件和Systemd服务
    log_step "步骤6/7：生成GOST配置文件和Systemd服务配置"
    log_exec "生成GOST主配置文件：${MASTER_DIR}/config.yaml"
    cat > ${MASTER_DIR}/config.yaml <<EOF
log: {level: info, file: ${MASTER_LOG}, max-size: ${LOG_MAX_SIZE}, max-age: ${LOG_MAX_AGE}, format: "[%Y-%m-%d %H:%M:%S] [%L] %m"}
db: {type: sqlite, dsn: ${MASTER_DIR}/gost.db}
server: {grpc: {addr: :${GRPC_PORT}, tls: true, cert: ${MASTER_DIR}/cert.pem, key: ${MASTER_DIR}/key.pem}, http: {addr: :8000}}
control: {enabled: true, auth: true}
EOF
    log_ok "GOST配置文件生成完成"

log_exec "生成Systemd服务文件：/etc/systemd/system/${MASTER_SERVICE}.service（终极版，防Bad message）"
# 第一步：清理残留文件+不可见字符，避免缓存干扰
rm -rf /etc/systemd/system/${MASTER_SERVICE}.service 2>/dev/null || true
# 第二步：生成绝对标准的systemd服务文件（分段分行，无任何格式问题）
cat > /etc/systemd/system/${MASTER_SERVICE}.service <<EOF
[Unit]
Description=GOST Master Service
After=network.target nginx.service
Wants=network.target

[Service]
Type=simple
ExecStart=${MASTER_DIR}/gost -C ${MASTER_DIR}/config.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=${MAX_OPEN_FILES}
User=root
Group=root
WorkingDirectory=${MASTER_DIR}/
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
# 第三步：修复systemd标准权限（强制644，root:root，不可修改）
chmod 644 /etc/systemd/system/${MASTER_SERVICE}.service
chown root:root /etc/systemd/system/${MASTER_SERVICE}.service
# 第四步：提前刷新systemd缓存，避免后续启用失败
systemctl daemon-reload
log_ok "Systemd服务配置生成完成（已清理残留+修复权限+刷新缓存）"

    log_step "步骤7/7：配置Nginx反向代理（面板端口8080）- 代理官方新UI https://ui.gost.run/"
log_exec "生成Nginx配置文件：/etc/nginx/nginx.conf（反向代理官方UI，无需本地下载）"
# 配置Nginx反向代理官方最新UI，彻底解决面板404问题
cat > /etc/nginx/nginx.conf <<EOF
user root;
worker_processes auto;
events {
    worker_connections 1024;
}
http {
    include mime.types;
    default_type application/octet-stream;
    sendfile on;
    server {
        listen ${HTTP_PORT};
        server_name _;
        # 反向代理GOST官方最新UI地址
        location / {
            proxy_pass https://ui.gost.run/;
            proxy_set_header Host ui.gost.run;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_redirect off;
            proxy_buffering off;
        }
        # 反向代理GOST主控内置API
        location /api/ {
            proxy_pass http://127.0.0.1:8000/api/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }
}
EOF
# 重启Nginx使配置生效
systemctl restart nginx
log_ok "Nginx配置完成（反向代理官方新UI），无需本地下载面板文件"

    # 启动服务并开放端口
    log_step "========== 启动GOST主控端并配置开机自启 =========="
    log_exec "执行命令：systemctl daemon-reload && systemctl enable --now ${MASTER_SERVICE} nginx"
    systemctl daemon-reload
    systemctl enable --now ${MASTER_SERVICE} nginx

    # 开放防火墙端口
    if [ -f /etc/redhat-release ]; then
        log_exec "执行命令：firewall-cmd --permanent --add-port={${GRPC_PORT},${HTTP_PORT}}/tcp && firewall-cmd --reload"
        firewall-cmd --permanent --add-port={${GRPC_PORT},${HTTP_PORT}}/tcp
        firewall-cmd --reload
    elif [ -f /etc/debian_version ] && command -v ufw >/dev/null 2>&1; then
        log_exec "执行命令：ufw allow ${GRPC_PORT}/tcp ${HTTP_PORT}/tcp"
        ufw allow ${GRPC_PORT}/tcp ${HTTP_PORT}/tcp
    fi
    log_ok "防火墙端口开放完成"

    # 验证启动状态
    log_step "========== 验证主控端启动状态 =========="
    log_exec "等待3秒，检测服务运行状态"
    sleep 3
    if check_running ${MASTER_SERVICE} && check_running nginx; then
        log_ok "==================== GOST主控端安装成功！===================="
        echo -e "${GREEN}外网IP：$(curl -s ip.sb) | 内网IP：$(get_ip)${RESET}"
        echo -e "${GREEN}面板地址：http://<你的VPS公网IP>:${HTTP_PORT}${RESET}"
        echo -e "${GREEN}gRPC地址：$(curl -s ip.sb):${GRPC_PORT} | 认证密钥：${AUTH_KEY}${RESET}"
        echo -e "${GREEN}日志路径：${MASTER_LOG} | 安装路径：${MASTER_DIR}${RESET}"
        echo -e "${GREEN}===========================================================${RESET}"
    else
        log_err "GOST主控端启动失败！"
        log_exec "执行以下命令查看详细错误："
        echo -e "${YELLOW}1. 查看GOST启动日志：tail -50 ${MASTER_LOG}${RESET}"
        echo -e "${YELLOW}2. 查看Systemd服务状态：systemctl status ${MASTER_SERVICE}${RESET}"
        echo -e "${YELLOW}3. 直接启动查看错误：${MASTER_DIR}/gost -C ${MASTER_DIR}/config.yaml${RESET}"
    fi
}

# 主控基础操作（保留原功能）
start_master() { check_master_installed || { log_err "主控端未安装！"; return 1; }; log_exec "启动主控端：systemctl start ${MASTER_SERVICE} nginx"; systemctl start ${MASTER_SERVICE} nginx && log_ok "主控端启动成功" || log_err "主控端启动失败"; }
stop_master() { check_master_installed || { log_err "主控端未安装！"; return 1; }; log_exec "停止主控端：systemctl stop ${MASTER_SERVICE} nginx"; systemctl stop ${MASTER_SERVICE} nginx && log_ok "主控端停止成功" || log_err "主控端停止失败"; }
restart_master() { check_master_installed || { log_err "主控端未安装！"; return 1; }; log_exec "重启主控端：systemctl restart ${MASTER_SERVICE} nginx"; systemctl restart ${MASTER_SERVICE} nginx && log_ok "主控端重启成功" || log_err "主控端重启失败"; }
status_master() {
    check_master_installed || { log_err "主控端未安装！"; return 1; }
    echo -e "\n${BLUE}==================== GOST主控端状态 ====================${RESET}"
    echo -e "服务状态：$(check_running ${MASTER_SERVICE} && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}已停止${RESET}")"
    echo -e "核心配置：gRPC${GRPC_PORT} | 面板${HTTP_PORT} | 密钥${AUTH_KEY:-未配置}"
    echo -e "本机IP：$(get_ip) | 日志路径：${MASTER_LOG} | 安装路径：${MASTER_DIR}"
    echo -e "${BLUE}=======================================================${RESET}"
    systemctl status ${MASTER_SERVICE} --no-pager -l | grep -E 'Active|Main PID|Result' || true
}
log_master() { check_master_installed || { log_err "主控端未安装！"; return 1; }; log_tip "主控端实时日志（按Ctrl+C退出）"; tail -f ${MASTER_LOG} | awk '{if($0~/\[ERROR\]/)print "\033[31m"$0"\033[0m";else print $0}'; }
uninstall_master() {
    check_master_installed || { log_err "主控端未安装！"; return 1; }
    read -p "确认彻底卸载主控端？(输入uninstall)：" c; [ "$c" != "uninstall" ] && { log_step "取消卸载"; return 0; }
    log_exec "停止服务：systemctl stop ${MASTER_SERVICE} nginx"
    systemctl stop ${MASTER_SERVICE} nginx 2>/dev/null || true
    log_exec "禁用服务：systemctl disable ${MASTER_SERVICE}"
    systemctl disable ${MASTER_SERVICE} 2>/dev/null || true
    log_exec "删除文件：rm -rf ${MASTER_DIR} /etc/systemd/system/${MASTER_SERVICE}.service"
    rm -rf ${MASTER_DIR} /etc/systemd/system/${MASTER_SERVICE}.service 2>/dev/null || true
    systemctl daemon-reload
    log_ok "主控端已彻底卸载完成"
}

# ==================== 被控端核心功能（带详细安装日志）====================
install_node() {
    if check_node_installed; then
        log_tip "检测到被控端已安装（路径：${NODE_DIR}）"
        read -p "是否重新安装？(y/n)：" c
        [ "$c" != "y" ] && { log_step "取消重装，退出安装流程"; return 0; }
        log_step "开始卸载原有被控端，准备重装"
        systemctl stop ${NODE_SERVICE} 2>/dev/null || true
        rm -rf ${NODE_DIR} /etc/systemd/system/${NODE_SERVICE}.service 2>/dev/null || true
        log_ok "原有被控端卸载完成"
    fi

    log_step "========== 开始安装GOST被控端 =========="
    log_tip "被控端需关联主控端，请准备好「主控gRPC地址」和「16位认证密钥」"

    # 输入并校验主控信息
    read -p "请输入主控端gRPC地址（例：1.2.3.4:50051）：" MASTER_GRPC
    read -p "请输入主控端16位认证密钥：" AUTH_KEY
    log_step "校验主控gRPC地址和认证密钥格式"
    if [[ ! "${MASTER_GRPC}" =~ ^[0-9.]+:[0-9]{1,5}$ ]]; then
        log_err "gRPC地址格式错误！正确格式：IP:端口（例：1.2.3.4:50051）"
        return 1
    fi
    if ! check_key; then
        log_err "认证密钥格式错误！必须是16位字母/数字组合"
        return 1
    fi
    log_ok "主控信息格式校验通过 | 关联主控：${MASTER_GRPC}"

    # 步骤1：安装系统基础依赖
    log_step "步骤1/5：安装系统基础依赖（wget/tar/net-tools）"
    if [ -f /etc/redhat-release ]; then
        log_exec "执行命令：yum install -y wget tar net-tools"
        yum install -y wget tar net-tools
    elif [ -f /etc/debian_version ]; then
        log_exec "执行命令：apt update && apt install -y wget tar net-tools"
        apt update
        apt install -y wget tar net-tools
    else
        log_err "不支持当前系统！仅支持CentOS7+/Ubuntu18+/Debian10+"
        return 1
    fi
    log_ok "系统依赖安装完成"

    # 步骤2：获取最新GOST版本并下载
    log_step "步骤2/5：获取最新GOST版本并下载二进制文件"
    log_exec "执行命令：获取GitHub最新GOST版本"
    VER=$(get_latest_gost)
    if [ -z "${VER}" ]; then
        log_err "获取GOST最新版本失败！"
        log_tip "解决方案：检查VPS到GitHub的网络连通性，或手动配置代理"
        return 1
    fi
    log_ok "成功获取GOST最新版本：v${VER}"
    
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${VER}/gost_${VER}_linux_${ARCH}.tar.gz"
    log_exec "执行命令：wget ${GOST_URL} -O /tmp/gost.tar.gz"
    wget --timeout=30 ${GOST_URL} -O /tmp/gost.tar.gz
    if [ ! -f /tmp/gost.tar.gz ] || [ ! -s /tmp/gost.tar.gz ]; then
        log_err "GOST二进制文件下载失败！文件不存在或为空"
        return 1
    fi
    log_ok "GOST v${VER} 二进制文件下载完成（路径：/tmp/gost.tar.gz）"

    # 步骤3：解压并安装GOST
    log_step "步骤3/5：解压GOST并创建安装目录（${NODE_DIR}）"
    log_exec "执行命令：mkdir -p ${NODE_DIR} && tar zxf /tmp/gost.tar.gz -C ${NODE_DIR} gost"
    mkdir -p ${NODE_DIR}
    tar zxf /tmp/gost.tar.gz -C ${NODE_DIR} gost
    log_exec "执行命令：chmod +x ${NODE_DIR}/gost && rm -f /tmp/gost.tar.gz"
    chmod +x ${NODE_DIR}/gost
    rm -f /tmp/gost.tar.gz
    
    if [ ! -f "${NODE_DIR}/gost" ]; then
        log_err "GOST解压安装失败！可执行文件不存在"
        return 1
    fi
    log_ok "GOST解压安装完成，可执行文件：${NODE_DIR}/gost"

    # 步骤4：生成GOST配置文件和Systemd服务
    log_step "步骤4/5：生成GOST配置文件和Systemd服务配置"
    log_exec "生成GOST被控配置文件：${NODE_DIR}/config.yaml"
    cat > ${NODE_DIR}/config.yaml <<EOF
log: {level: info, file: ${NODE_LOG}, max-size: ${LOG_MAX_SIZE}, max-age: ${LOG_MAX_AGE}, format: "[%Y-%m-%d %H:%M:%S] [%L] %m"}
node: {grpc: {addr: ${MASTER_GRPC}, tls: true, auth: {key: ${AUTH_KEY}}}}
control: {enabled: true}
EOF
    log_ok "GOST被控配置文件生成完成"

    log_exec "生成Systemd服务文件：/etc/systemd/system/${NODE_SERVICE}.service"
    cat > /etc/systemd/system/${NODE_SERVICE}.service <<EOF
[Unit] Description=GOST Node After=network.target
[Service] Type=simple ExecStart=${NODE_DIR}/gost -C ${NODE_DIR}/config.yaml Restart=on-failure RestartSec=3 LimitNOFILE=${MAX_OPEN_FILES}
[Install] WantedBy=multi-user.target
EOF
    log_ok "Systemd服务配置生成完成"

    # 步骤5：启动服务并配置开机自启
    log_step "步骤5/5：启动GOST被控端并配置开机自启"
    log_exec "执行命令：systemctl daemon-reload && systemctl enable --now ${NODE_SERVICE}"
    systemctl daemon-reload
    systemctl enable --now ${NODE_SERVICE}

    # 验证启动状态
    log_step "========== 验证被控端启动状态 =========="
    log_exec "等待3秒，检测服务运行状态"
    sleep 3
    if check_running ${NODE_SERVICE}; then
        log_ok "==================== GOST被控端安装成功！===================="
        echo -e "${GREEN}本机IP：$(get_ip) | 成功关联主控：${MASTER_GRPC}${RESET}"
        echo -e "${GREEN}日志路径：${NODE_LOG} | 安装路径：${NODE_DIR}${RESET}"
        echo -e "${GREEN}提示：可在主控端面板查看被控端在线状态${RESET}"
        echo -e "${GREEN}===========================================================${RESET}"
    else
        log_err "GOST被控端启动失败！"
        log_exec "执行以下命令查看详细错误："
        echo -e "${YELLOW}1. 查看被控启动日志：tail -50 ${NODE_LOG}${RESET}"
        echo -e "${YELLOW}2. 查看Systemd服务状态：systemctl status ${NODE_SERVICE}${RESET}"
        echo -e "${YELLOW}3. 直接启动查看错误：${NODE_DIR}/gost -C ${NODE_DIR}/config.yaml${RESET}"
        log_tip "常见失败原因：主控端未启动/主控gRPC地址错误/认证密钥不匹配/网络不通"
    fi
}

# 被控基础操作（保留原功能）
start_node() { check_node_installed || { log_err "被控端未安装！"; return 1; }; log_exec "启动被控端：systemctl start ${NODE_SERVICE}"; systemctl start ${NODE_SERVICE} && log_ok "被控端启动成功" || log_err "被控端启动失败"; }
stop_node() { check_node_installed || { log_err "被控端未安装！"; return 1; }; log_exec "停止被控端：systemctl stop ${NODE_SERVICE}"; systemctl stop ${NODE_SERVICE} && log_ok "被控端停止成功" || log_err "被控端停止失败"; }
restart_node() { check_node_installed || { log_err "被控端未安装！"; return 1; }; log_exec "重启被控端：systemctl restart ${NODE_SERVICE}"; systemctl restart ${NODE_SERVICE} && log_ok "被控端重启成功" || log_err "被控端重启失败"; }
status_node() {
    check_node_installed || { log_err "被控端未安装！"; return 1; }
    echo -e "\n${BLUE}==================== GOST被控端状态 ====================${RESET}"
    echo -e "服务状态：$(check_running ${NODE_SERVICE} && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}已停止${RESET}")"
    echo -e "本机IP：$(get_ip) | 关联主控：${MASTER_GRPC:-未配置}"
    echo -e "日志路径：${NODE_LOG} | 安装路径：${NODE_DIR}"
    echo -e "${BLUE}=======================================================${RESET}"
    systemctl status ${NODE_SERVICE} --no-pager -l | grep -E 'Active|Main PID|Result' || true
}
log_node() { check_node_installed || { log_err "被控端未安装！"; return 1; }; log_tip "被控端实时日志（按Ctrl+C退出）"; tail -f ${NODE_LOG} | awk '{if($0~/\[ERROR\]/)print "\033[31m"$0"\033[0m";else print $0}'; }
uninstall_node() {
    check_node_installed || { log_err "被控端未安装！"; return 1; }
    read -p "确认彻底卸载被控端？(输入uninstall)：" c; [ "$c" != "uninstall" ] && { log_step "取消卸载"; return 0; }
    log_exec "停止服务：systemctl stop ${NODE_SERVICE}"
    systemctl stop ${NODE_SERVICE} 2>/dev/null || true
    log_exec "禁用服务：systemctl disable ${NODE_SERVICE}"
    systemctl disable ${NODE_SERVICE} 2>/dev/null || true
    log_exec "删除文件：rm -rf ${NODE_DIR} /etc/systemd/system/${NODE_SERVICE}.service"
    rm -rf ${NODE_DIR} /etc/systemd/system/${NODE_SERVICE}.service 2>/dev/null || true
    systemctl daemon-reload
    log_ok "被控端已彻底卸载完成"
}

# ==================== 交互式菜单（极简清晰）====================
main_menu() {
    clear
    echo -e "${BLUE}==================== GOST V3 主控+被控一体化脚本（带详细日志）====================${RESET}"
    echo -e "适配系统：CentOS7+/Ubuntu18+/Debian10+ | 架构：x86_64/arm64"
    echo -e "核心特性：安装步骤实时显示/保留命令回显/错误高亮定位/无静默执行"
    echo -e "${BLUE}=================================================================================${RESET}"
    echo -e "【主控端操作】"
    echo -e "1. 安装主控端    2. 启动主控    3. 停止主控    4. 重启主控"
    echo -e "5. 主控状态      6. 主控日志    7. 卸载主控"
    echo -e "\n【被控端操作】"
    echo -e "8. 安装被控端    9. 启动被控    10. 停止被控   11. 重启被控"
    echo -e "12. 被控状态     13. 被控日志   14. 卸载被控"
    echo -e "\n0. 退出脚本"
    echo -e "${BLUE}=================================================================================${RESET}"
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
        0) echo -e "\n${GREEN}退出脚本，感谢使用！${RESET}"; exit 0 ;;
        *) log_tip "无效操作编号，请重新输入！" ;;
    esac
    read -p "按任意键返回主菜单..." -n1 -s
    main_menu
}

# 启动交互式菜单（必须root权限）
if [ $EUID -ne 0 ]; then
    log_err "脚本必须以root权限运行！请执行：sudo ./本脚本名.sh"
    exit 1
fi
main_menu
