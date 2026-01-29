#!/bin/bash
set -euo pipefail
# GOST V3 轻量被控节点 交互式管理脚本【最新版自动下载+全优化】
# 核心特性：自动拉取GitHub最新GOST版本+主控连通性测试+一键排错+极致资源限制
# 适配：CentOS7+/Ubuntu18+/Debian10+ | x86_64/arm64 | 单节点资源＜5M
# 无需手动修改版本号，脚本自动获取最新release版本

# ==================== 基础配置（无需改版本号）====================
SERVICE_NAME="gost-node"
GOST_INSTALL_DIR="/usr/local/bin"
GOST_CONFIG_DIR="/etc/gost"
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
NODE_NAME="GOST-Node-$(hostname)"
# 颜色定义
RED_COLOR="\033[31m"
GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
BLUE_COLOR="\033[34m"
RESET_COLOR="\033[0m"
# 极致资源限制
CPU_QUOTA="5%"
MEMORY_LIMIT="16M"
IO_LIMIT="512K"

# ==================== 核心新增：自动获取GitHub最新GOST版本 ====================
get_latest_gost() {
    print_tip "正在从GitHub获取GOST最新release版本..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | grep -E 'tag_name' | cut -d'"' -f4 | sed 's/v//g')
    if [ -z "${LATEST_VERSION}" ]; then
        print_err "获取最新版本失败！请检查网络连通性（需访问GitHub）"
        exit 1
    fi
    print_ok "成功获取GOST最新版本：v${LATEST_VERSION}"
    echo "${LATEST_VERSION}"
}

# ==================== 工具函数 ====================
print_ok() { echo -e "${GREEN_COLOR}✅ $1${RESET_COLOR}"; }
print_err() { echo -e "${RED_COLOR}❌ $1${RESET_COLOR}"; }
print_tip() { echo -e "${YELLOW_COLOR}💡 $1${RESET_COLOR}"; }
print_info() { echo -e "${BLUE_COLOR}ℹ️  $1${RESET_COLOR}"; }
check_installed() { [ -f "${GOST_INSTALL_DIR}/gost" ] && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && return 0 || return 1; }
check_running() { systemctl is-active --quiet ${SERVICE_NAME} && return 0 || return 1; }
check_port() { netstat -tulnp 2>/dev/null | grep -q ":$1 " && return 0 || return 1; }
get_ip() {
    INNER_IP=$(ip addr | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
    OUTER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "未获取到")
    echo "内网：$INNER_IP | 外网：$OUTER_IP"
}
get_grpc_addr() { [ -f "${GOST_CONFIG_DIR}/config.yaml" ] && grep -E 'addr: ' ${GOST_CONFIG_DIR}/config.yaml | awk '{print $2}' | sed 's/ //g' || echo "未配置"; }
get_grpc_port() { get_grpc_addr | awk -F: '{print $2}'; }

# ==================== 新增功能：配置备份/主控连通性/一键排错 ====================
backup_config() {
    if ! check_installed; then print_err "未检测到被控节点，无需备份！"; return 0; fi
    print_tip "开始备份节点配置..."
    BACKUP_NAME="gost-node-backup-$(date +%Y%m%d%H%M%S).tar.gz"
    BACKUP_PATH="/root/${BACKUP_NAME}"
    tar -zcf ${BACKUP_PATH} ${GOST_CONFIG_DIR}/ >/dev/null 2>&1
    [ -f "${BACKUP_PATH}" ] && print_ok "备份成功！${BACKUP_PATH}（$(du -sh ${BACKUP_PATH} | awk '{print $1}')）" || print_err "备份失败！"
}
check_master_connect() {
    if ! check_installed; then print_err "未检测到被控节点，请先安装！"; return 0; fi
    GRPC_ADDR=$(get_grpc_addr)
    [ "${GRPC_ADDR}" = "未配置" ] && { print_err "未配置主控gRPC地址！"; return 0; }
    GRPC_IP=$(echo ${GRPC_ADDR} | awk -F: '{print $1}')
    GRPC_PORT=$(echo ${GRPC_ADDR} | awk -F: '{print $2}')
    
    print_info "开始测试与主控端【${GRPC_ADDR}】的连通性..."
    print_info "节点本机IP：$(get_ip)"
    # PING测试
    print_tip "1. PING主控IP ${GRPC_IP}..."
    ping -c 3 ${GRPC_IP} >/dev/null 2>&1 && print_ok "PING测试：通" || print_err "PING测试：不通（网络层故障）"
    # TCP端口测试
    print_tip "2. 测试gRPC端口 ${GRPC_PORT}..."
    (echo >/dev/tcp/${GRPC_IP}/${GRPC_PORT}) 2>/dev/null && print_ok "端口测试：通" || print_err "端口测试：不通（端口未开放/主控未运行）"
    # 服务状态验证
    print_tip "3. 节点服务状态..."
    check_running && print_ok "节点状态：运行中" || print_err "节点状态：已停止"
    print_info "连通性测试完成！失败请检查主控状态/防火墙/节点配置"
}
debug_log() {
    if ! check_installed; then print_err "未检测到被控节点，请先安装！"; return 0; fi
    print_tip "生成节点一键排错日志..."
    DEBUG_NAME="gost-node-debug-$(date +%Y%m%d%H%M%S).tar.gz"
    DEBUG_PATH="/root/${DEBUG_NAME}"
    mkdir -p /tmp/gost-debug/
    echo "=== 节点信息 ===" >/tmp/gost-debug/node.info && echo "名称：${NODE_NAME} | IP：$(get_ip) | 主控：$(get_grpc_addr)" >>/tmp/gost-debug/node.info
    echo "=== 系统信息 ===" >/tmp/gost-debug/system.info && uname -a >>/tmp/gost-debug/system.info && free -h >>/tmp/gost-debug/system.info
    echo "=== 端口占用 ===" >/tmp/gost-debug/port.info && netstat -tulnp 2>/dev/null >>/tmp/gost-debug/port.info
    echo "=== 服务状态 ===" >/tmp/gost-debug/status.info && systemctl status ${SERVICE_NAME} --no-pager >>/tmp/gost-debug/status.info
    echo "=== 实时日志 ===" >/tmp/gost-debug/log.info && journalctl -u ${SERVICE_NAME} -n 50 --no-pager >>/tmp/gost-debug/log.info
    echo "=== 配置文件 ===" >/tmp/gost-debug/config.yaml && cp ${GOST_CONFIG_DIR}/config.yaml /tmp/gost-debug/
    echo "=== 防火墙 ===" >/tmp/gost-debug/firewall.info && (firewall-cmd --list-ports 2>/dev/null || ufw status 2>/dev/null) >>/tmp/gost-debug/firewall.info
    echo "=== 主控连通性 ===" >/tmp/gost-debug/connect.info && check_master_connect 2>&1 >>/tmp/gost-debug/connect.info
    tar -zcf ${DEBUG_PATH} /tmp/gost-debug/ >/dev/null 2>&1 && rm -rf /tmp/gost-debug/
    print_ok "排错日志生成完成！${DEBUG_PATH}"
}

# ==================== 核心功能：安装被控节点（自动下载最新版）====================
install_node() {
    if check_installed; then
        print_tip "检测到GOST被控节点已安装！"
        read -p "是否重新安装（覆盖配置，y/n）：" CHOICE
        [ "${CHOICE}" != "y" ] && [ "${CHOICE}" != "Y" ] && { print_ok "取消重新安装"; return 0; }
        systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
    fi

    echo -e "\n===== 开始安装GOST V3轻量被控节点【自动获取最新版】===="
    # 安装基础依赖
    print_tip "安装基础依赖（wget/tar/net-tools）..."
    if [ -f /etc/redhat-release ]; then
        yum install -y wget tar net-tools >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    elif [ -f /etc/debian_version ]; then
        apt update -y >/dev/null 2>&1 && apt install -y wget tar net-tools >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    else
        print_err "仅支持CentOS/Ubuntu/Debian！"; exit 1;
    fi

    # 自动获取最新版本并下载
    GOST_VERSION=$(get_latest_gost)
    GOST_TAR="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${GOST_TAR}"
    print_tip "开始下载GOST v${GOST_VERSION}（${ARCH}架构）..."
    wget -q --show-progress ${GOST_URL} -O /tmp/${GOST_TAR} || { print_err "GOST下载失败！请检查GitHub网络访问"; exit 1; }
    tar zxf /tmp/${GOST_TAR} -C ${GOST_INSTALL_DIR} gost >/dev/null 2>&1
    chmod +x ${GOST_INSTALL_DIR}/gost && rm -rf /tmp/${GOST_TAR}
    # 验证安装
    if ! ${GOST_INSTALL_DIR}/gost -V >/dev/null 2>&1; then
        print_err "GOST安装验证失败！可能是架构不匹配"
        exit 1
    fi
    print_ok "GOST v${GOST_VERSION} 安装验证成功！"

    # 交互式输入主控信息（密钥格式校验）
    print_tip "请输入主控端核心配置（与主控端保持一致）..."
    read -p "主控端gRPC地址（格式：IP:端口，例：192.168.1.100:50051）：" GRPC_SERVER
    if ! echo "${GRPC_SERVER}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]{1,5}$'; then
        print_err "gRPC地址格式无效！必须为【IP:端口】"; exit 1;
    fi
    # 密钥≥8位字母数字校验
    while true; do
        read -s -p "节点认证密钥（≥8位字母+数字，输入不回显）：" NODE_AUTH_KEY
        echo -e ""
        if [ -z "${NODE_AUTH_KEY}" ]; then
            print_err "密钥不能为空！"; continue;
        elif [[ ${#NODE_AUTH_KEY} -lt 8 || ! "${NODE_AUTH_KEY}" =~ [A-Za-z] || ! "${NODE_AUTH_KEY}" =~ [0-9] ]]; then
            print_err "密钥不满足要求！需≥8位，包含字母+数字"; continue;
        fi
        break;
    done

    # 生成轻量配置文件
    print_tip "生成节点轻量配置文件..."
    mkdir -p ${GOST_CONFIG_DIR}
    cat > ${GOST_CONFIG_DIR}/config.yaml <<EOF
# GOST V3 轻量被控节点配置【最新版】- 节点名称：${NODE_NAME}
log:
  level: warn  # 仅输出警告/错误，降低资源占用
server:
  grpc:
    addr: ${GRPC_SERVER}
    tls: true   # 与主控端加密通信，保持一致
node:
  name: ${NODE_NAME}
  auth-key: ${NODE_AUTH_KEY}
  heartbeat-interval: 10s # 延长心跳，降低主控压力
EOF

    # 配置Systemd服务（资源限制+启动延迟）
    print_tip "配置Systemd服务（极致资源限制+开机自启）..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=GOST V3 Light Node [Latest]
After=network.target
Wants=network.target
ExecStartPre=/bin/sleep 3

[Service]
Type=simple
User=root
ExecStart=${GOST_INSTALL_DIR}/gost -C ${GOST_CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=10240
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
CPUQuota=${CPU_QUOTA}
MemoryLimit=${MEMORY_LIMIT}
IOReadBandwidthMax=/dev/sda ${IO_LIMIT}
IOWriteBandwidthMax=/dev/sda ${IO_LIMIT}

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务+开放防火墙
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now ${SERVICE_NAME} >/dev/null 2>&1
    GRPC_PORT=$(echo ${GRPC_SERVER} | awk -F: '{print $2}')
    print_tip "开放防火墙gRPC端口${GRPC_PORT}..."
    if [ -f /etc/redhat-release ]; then
        firewall-cmd --permanent --add-port=${GRPC_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif [ -f /etc/debian_version ] && command -v ufw >/dev/null 2>&1; then
        ufw allow ${GRPC_PORT}/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
    fi

    # 验证安装结果
    if check_installed && check_running; then
        print_ok "GOST V3轻量被控节点【最新版】安装成功！"
        echo -e "\n${GREEN_COLOR}===== 节点核心信息 =====${RESET_COLOR}"
        echo -e "节点名称：${NODE_NAME}"
        echo -e "本机IP：$(get_ip)"
        echo -e "主控配置：${GRPC_SERVER}"
        echo -e "GOST版本：v${GOST_VERSION}（${ARCH}架构）"
        echo -e "资源限制：CPU=${CPU_QUOTA} | 内存=${MEMORY_LIMIT}"
        echo -e "配置路径：${GOST_CONFIG_DIR}/config.yaml"
        echo -e "服务状态：${GREEN_COLOR}已上线${RESET_COLOR}（可前往主控端面板查看）"
        echo -e "${GREEN_COLOR}=======================${RESET_COLOR}"
    else
        print_err "安装成功但服务启动失败！执行 选项9 测试主控连通性"
    fi
}

# ==================== 原有功能：启动/停止/重启/状态/日志/重配置/卸载 ====================
start_node() {
    [ ! check_installed ] && { print_err "未检测到被控节点，请先安装！"; return 0; }
    check_running && { print_ok "节点已在运行！"; return 0; }
    systemctl start ${SERVICE_NAME} && print_ok "节点启动成功！" || print_err "启动失败！"
}
stop_node() {
    [ ! check_installed ] && { print_err "未检测到被控节点！"; return 0; }
    [ ! check_running ] && { print_ok "节点已停止！"; return 0; }
    systemctl stop ${SERVICE_NAME} && print_ok "节点已停止！"
}
restart_node() {
    [ ! check_installed ] && { print_err "未检测到被控节点，请先安装！"; return 0; }
    systemctl restart ${SERVICE_NAME} && print_ok "节点重启成功！" || print_err "重启失败！"
}
status_node() {
    [ ! check_installed ] && { print_err "未检测到被控节点，请先安装！"; return 0; }
    echo -e "\n===== GOST V3轻量被控节点 运行状态 ====="
    echo -e "服务状态：$(check_running && echo -e "${GREEN_COLOR}运行中${RESET_COLOR}" || echo -e "${RED_COLOR}已停止${RESET_COLOR}")"
    echo -e "节点信息：名称=${NODE_NAME} | IP=$(get_ip)"
    echo -e "主控配置：$(get_grpc_addr)（端口：$(get_grpc_port)）"
    echo -e "资源限制：CPU=${CPU_QUOTA} | 内存=${MEMORY_LIMIT} | IO=${IO_LIMIT}"
    echo -e "核心路径：安装=${GOST_INSTALL_DIR}/gost | 配置=${GOST_CONFIG_DIR}/config.yaml"
    echo -e "======================================="
    systemctl status ${SERVICE_NAME} --no-pager
}
log_node() {
    [ ! check_installed ] && { print_err "未检测到被控节点，请先安装！"; return 0; }
    echo -e "\n===== 被控节点实时日志（按Ctrl+C退出）=====\n"
    journalctl -u ${SERVICE_NAME} -f
}
reconfig_node() {
    [ ! check_installed ] && { print_err "未检测到被控节点，请先安装！"; return 0; }
    echo -e "\n===== 重新配置主控端信息 ====="
    echo -e "当前主控gRPC地址：$(get_grpc_addr)"
    # 输入新gRPC地址
    read -p "新主控gRPC地址（IP:端口）：" GRPC_SERVER
    if ! echo "${GRPC_SERVER}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]{1,5}$'; then
        print_err "gRPC地址格式无效！"; return 0;
    fi
    # 输入新密钥（校验规则不变）
    while true; do
        read -s -p "新节点认证密钥（≥8位字母+数字，输入不回显）：" NODE_AUTH_KEY
        echo -e ""
        if [ -z "${NODE_AUTH_KEY}" ]; then
            print_err "密钥不能为空！"; continue;
        elif [[ ${#NODE_AUTH_KEY} -lt 8 || ! "${NODE_AUTH_KEY}" =~ [A-Za-z] || ! "${NODE_AUTH_KEY}" =~ [0-9] ]]; then
            print_err "密钥不满足要求！需≥8位，包含字母+数字"; continue;
        fi
        break;
    done
    # 覆盖配置
    cat > ${GOST_CONFIG_DIR}/config.yaml <<EOF
log: level: warn
server: grpc: addr: ${GRPC_SERVER}; tls: true
node: name: ${NODE_NAME}; auth-key: ${NODE_AUTH_KEY}; heartbeat-interval: 10s
EOF
    sed -i 's/;/\n  /g' ${GOST_CONFIG_DIR}/config.yaml
    # 开放新端口+重启
    GRPC_PORT=$(echo ${GRPC_SERVER} | awk -F: '{print $2}')
    if [ -f /etc/redhat-release ]; then
        firewall-cmd --permanent --add-port=${GRPC_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif [ -f /etc/debian_version ] && command -v ufw >/dev/null 2>&1; then
        ufw allow ${GRPC_PORT}/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
    fi
    systemctl restart ${SERVICE_NAME} >/dev/null 2>&1
    print_ok "主控信息配置成功！新地址：${GRPC_SERVER}"
    print_tip "执行 选项9 测试与新主控的连通性"
}
uninstall_node() {
    [ ! check_installed ] && { print_err "未检测到被控节点，无需卸载！"; return 0; }
    echo -e "\n${RED_COLOR}⚠️  警告：卸载将删除节点所有配置，无法恢复！${RESET_COLOR}"
    read -p "请输入 uninstall 确认卸载：" CHOICE
    [ "${CHOICE}" != "uninstall" ] && { print_ok "取消卸载"; return 0; }
    # 停止服务+删除文件
    systemctl stop ${SERVICE_NAME} >/dev/null 2>&1
    systemctl disable ${SERVICE_NAME} >/dev/null 2>&1
    rm -rf ${GOST_INSTALL_DIR}/gost ${GOST_CONFIG_DIR} /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload >/dev/null 2>&1
    # 可选卸载依赖
    read -p "是否卸载基础依赖（wget/tar等，y/n）：" DEP_CHOICE
    if [ "${DEP_CHOICE}" = "y" ] || [ "${DEP_CHOICE}" = "Y" ]; then
        [ -f /etc/redhat-release ] && yum remove -y wget tar net-tools >/dev/null 2>&1
        [ -f /etc/debian_version ] && apt remove -y wget tar net-tools >/dev/null 2>&1
        print_tip "基础依赖已卸载"
    fi
    print_ok "GOST被控节点已完全卸载，无残留！"
}

# ==================== 主菜单 ====================
main() {
    clear
    echo -e "======================================"
    echo -e "  GOST V3 轻量被控节点 交互式管理【最新版】"
    echo -e "  特性：自动下载GitHub最新版 | 一键排错 | 极致轻量"
    echo -e "  适配：单节点＜5M | CentOS/Ubuntu/Debian | x86_64/arm64"
    echo -e "======================================"
    echo -e "  1. 安装被控节点（自动最新版+主控配置+密钥校验）"
    echo -e "  2. 启动被控节点"
    echo -e "  3. 停止被控节点"
    echo -e "  4. 重启被控节点"
    echo -e "  5. 查看节点状态"
    echo -e "  6. 查看实时日志（排错用）"
    echo -e "  7. 重新配置主控信息"
    echo -e "  8. 卸载被控节点（需验证+彻底清理）"
    echo -e "  9. 测试主控连通性（PING+端口+状态）"
    echo -e "  10. 一键生成排错日志（快速定位问题）"
    echo -e "  11. 备份节点配置（防配置丢失）"
    echo -e "  0. 退出脚本"
    echo -e "======================================"
    read -p "请输入操作选项（0-11）：" OPTION
    case ${OPTION} in
        1) install_node ;;
        2) start_node ;;
        3) stop_node ;;
