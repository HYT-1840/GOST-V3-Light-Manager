#!/bin/bash
set -euo pipefail
# GOST V3 轻量被控端 交互式管理脚本【低配VPS优化版】
# 适配：≤50节点集群 | 单节点资源＜5M | CentOS7+/Ubuntu18+/Debian10+ | x86_64/arm64
# 核心优化：极致资源限制+主控联动+卡顿兜底，适配低配VPS，杜绝卡死

# ==================== 基础配置（低配优化，与主控同步）====================
SERVICE_NAME="gost-node"
GOST_NODE_DIR="/usr/local/gost-node"
MASTER_GRPC=""
AUTH_KEY=""
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
# 颜色定义
RED_COLOR="\033[31m"
GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
RESET_COLOR="\033[0m"
# 🔥 低配核心资源限制（低于主控，避免抢占资源）
CPU_QUOTA="3%"
MEMORY_LIMIT="8M"
IO_LIMIT="128K"
MAX_OPEN_FILES=1024

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

# ==================== 工具函数（低配精简，与主控同步）====================
print_ok() { echo -e "${GREEN_COLOR}✅ $1${RESET_COLOR}"; }
print_err() { echo -e "${RED_COLOR}❌ $1${RESET_COLOR}"; }
print_tip() { echo -e "${YELLOW_COLOR}💡 $1${RESET_COLOR}"; }
check_installed() { [ -f "${GOST_NODE_DIR}/bin/gost" ] && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && return 0 || return 1; }
check_running() { systemctl is-active --quiet ${SERVICE_NAME} && return 0 || return 1; }
check_port() { netstat -tulnp 2>/dev/null | grep -q ":$1 " && return 0 || return 1; }
get_inner_ip() {
    INNER_IP=$(ip addr | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
    echo "${INNER_IP:-未获取到IP}"
}
check_key() { [[ "${AUTH_KEY}" =~ ^[a-zA-Z0-9]{16}$ ]] && return 0 || return 1; }

# ==================== 低配专属：防卡死+主控联动检测 ====================
kill_stuck_process() {
    print_tip "检查并清理被控端卡死进程..."
    pkill -f "${GOST_NODE_DIR}/bin/gost" -9 2>/dev/null || true
    print_ok "被控端卡死进程清理完成"
}
monitor_resource() {
    print_tip "当前被控节点资源占用（低配VPS重点关注）："
    echo -e "CPU占用：$(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - $1 "%"}\')"
    echo -e "内存占用：$(free -h | grep Mem | awk '{print $3 "/" $2}')"
    echo -e "被控进程：$(ps -ef | grep gost | grep -v grep || echo "未运行")"
    echo -e "本机IP：$(get_inner_ip)"
}
check_master_connect() {
    [ -z "${MASTER_GRPC}" ] && { print_err "未配置主控端gRPC地址！"; return 0; }
    print_tip "检测与主控端（${MASTER_GRPC}）连通性..."
    MASTER_IP=$(echo "${MASTER_GRPC}" | cut -d: -f1)
    MASTER_PORT=$(echo "${MASTER_GRPC}" | cut -d: -f2)
    # PING检测
    ping -c 1 -W 2 "${MASTER_IP}" >/dev/null 2>&1
    PING_STATUS=$?
    # 端口检测
    check_port "${MASTER_PORT}"
    PORT_STATUS=$?
    # 密钥检测
    check_key
    KEY_STATUS=$?
    # 结果输出
    echo -e "PING主控IP（${MASTER_IP}）：$( [ ${PING_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}正常${RESET_COLOR}" || echo -e "${RED_COLOR}失败${RESET_COLOR}" )"
    echo -e "检测gRPC端口（${MASTER_PORT}）：$( [ ${PORT_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}可达${RESET_COLOR}" || echo -e "${RED_COLOR}不可达${RESET_COLOR}" )"
    echo -e "认证密钥校验：$( [ ${KEY_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}合法${RESET_COLOR}" || echo -e "${RED_COLOR}非法（需16位字母数字）${RESET_COLOR}" )"
    # 解决方案提示
    if [ ${PING_STATUS} -ne 0 ]; then
        print_tip "解决方案：检查主控与被控网络连通性，低配VPS建议关闭防火墙冗余规则"
    elif [ ${PORT_STATUS} -ne 0 ]; then
        print_tip "解决方案：检查主控端gRPC端口是否开放，或主控服务是否运行"
    elif [ ${KEY_STATUS} -ne 0 ]; then
        print_tip "解决方案：重新配置主控密钥（需与主控端16位字母数字密钥一致）"
    else
        print_ok "与主控端连通性正常，可正常联动！"
    fi
}

# ==================== 核心功能：安装被控端 ====================
install_node() {
    if check_installed; then
        print_tip "检测到已安装被控端！"
        read -p "是否重新安装（覆盖配置，y/n）：" CHOICE
        [ "${CHOICE}" != "y" ] && [ "${CHOICE}" != "Y" ] && { print_ok "取消重新安装"; return 0; }
        kill_stuck_process
        systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
    fi

    echo -e "\n===== 安装GOST V3轻量被控端【低配VPS优化版】===="
    # 输入主控信息
    print_tip "请输入主控端核心信息（需与主控端一致）"
    read -p "主控端gRPC地址（格式：IP:50051）：" MASTER_GRPC
    read -p "主控端认证密钥（16位字母数字）：" AUTH_KEY
    # 校验配置
    if [[ ! "${MASTER_GRPC}" =~ ^[0-9.]{7,15}:[0-9]{1,5}$ ]]; then
        print_err "gRPC地址格式错误！正确格式：IP:端口（例：192.168.1.1:50051）"
        exit 1
    fi
    if ! check_key; then
        print_err "认证密钥格式错误！需16位字母数字（与主控端一致）"
        exit 1
    fi
    # 安装依赖（极致精简）
    print_tip "安装基础依赖（被控端精简版，仅必需组件）..."
    if [ -f /etc/redhat-release ]; then
        yum install -y -q wget tar net-tools --setopt=tsflags=nodocs >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    elif [ -f /etc/debian_version ]; then
        apt update -y -qq >/dev/null 2>&1 && apt install -y -qq wget tar net-tools >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    else
        print_err "仅支持CentOS/Ubuntu/Debian！"; exit 1;
    fi
    # 下载GOST
    GOST_VERSION=$(get_latest_gost)
    GOST_TAR="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${GOST_TAR}"
    print_tip "下载GOST v${GOST_VERSION}（${ARCH}架构，断点续传）..."
    mkdir -p ${GOST_NODE_DIR}/bin
    wget -q -c --timeout=30 ${GOST_URL} -O /tmp/${GOST_TAR} || { print_err "GOST下载失败！配置代理后重试"; exit 1; }
    tar zxf /tmp/${GOST_TAR} -C ${GOST_NODE_DIR}/bin gost >/dev/null 2>&1
    chmod +x ${GOST_NODE_DIR}/bin/gost && rm -rf /tmp/${GOST_TAR}
    # 验证安装
    if ! ${GOST_NODE_DIR}/bin/gost -V >/dev/null 2>&1; then
        print_err "GOST安装验证失败！可能是架构不匹配"
        exit 1
    fi
    print_ok "GOST v${GOST_VERSION} 安装验证成功！"
    # 生成配置
    print_tip "生成被控端配置（精简版，仅保留主控联动功能）..."
    mkdir -p ${GOST_NODE_DIR}/{conf,log}
    cat > ${GOST_NODE_DIR}/conf/config.yaml <<EOF
log:
  level: fatal
  file: ${GOST_NODE_DIR}/log/gost-node.log
  max-size: 10
  max-age: 1
node:
  grpc:
    addr: ${MASTER_GRPC}
    tls: true
    insecure: false
    auth:
      key: ${AUTH_KEY}
control:
  enabled: true
EOF
    # 配置Systemd（资源限制，低于主控）
    print_tip "配置Systemd服务（防卡死+开机自启，适配低配VPS）..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=GOST V3 Light Node [Low-VPS Optimized]
After=network.target
Wants=network.target
ExecStartPre=/bin/sleep 8
ExecStartPre=/bin/bash -c "ulimit -n ${MAX_OPEN_FILES}"

[Service]
Type=simple
User=root
WorkingDirectory=${GOST_NODE_DIR}
ExecStart=${GOST_NODE_DIR}/bin/gost -C ${GOST_NODE_DIR}/conf/config.yaml
Restart=on-failure
RestartSec=15s
LimitNOFILE=${MAX_OPEN_FILES}
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
CPUQuota=${CPU_QUOTA}
MemoryLimit=${MEMORY_LIMIT}
MemorySwapLimit=0
IOReadBandwidthMax=/dev/sda ${IO_LIMIT}
IOWriteBandwidthMax=/dev/sda ${IO_LIMIT}
Nice=20
IOSchedulingClass=2
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF
    # 启动服务
    systemctl daemon-reload >/dev/null 2>&1
    kill_stuck_process
    systemctl enable --now ${SERVICE_NAME} >/dev/null 2>&1
    print_tip "被控端服务启动中（低配VPS启动可能较慢，请耐心等待）..."
    sleep 3
    # 验证结果
    if check_installed && check_running; then
        print_ok "GOST V3轻量被控端【低配VPS优化版】安装成功！"
        echo -e "\n${GREEN_COLOR}===== 被控端核心信息（务必保存）=====${RESET_COLOR}"
        echo -e "本机IP：$(get_inner_ip)"
        echo -e "关联主控：${MASTER_GRPC}"
        echo -e "认证密钥：${AUTH_KEY}（与主控一致）"
        echo -e "资源限制：CPU≤${CPU_QUOTA} | 内存≤${MEMORY_LIMIT}"
        echo -e "${GREEN_COLOR}==============================${RESET_COLOR}"
        print_tip "建议执行选项9（检测主控连通性），确认联动正常"
    else
        print_err "安装成功但服务启动失败！执行选项10生成排错日志"
        kill_stuck_process
        systemctl restart ${SERVICE_NAME} >/dev/null 2>&1
    fi
}

# ==================== 基础功能：启停/状态/日志等 ====================
start_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，请先安装！"; return 0; }
    check_running && { print_ok "被控端已在运行！"; return 0; }
    kill_stuck_process
    print_tip "启动被控端（低配VPS启动可能较慢，请耐心等待）..."
    systemctl start ${SERVICE_NAME} && print_ok "被控端启动成功！" || { print_err "启动失败！"; kill_stuck_process; }
}
stop_node() {
    [ ! check_installed ] && { print_err "未检测到被控端！"; return 0; }
    [ ! check_running ] && { print_ok "被控端已停止！"; return 0; }
    systemctl stop ${SERVICE_NAME} && print_ok "被控端已停止！"
    kill_stuck_process
}
restart_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，请先安装！"; return 0; }
    kill_stuck_process
    print_tip "重启被控端（低配VPS重启可能较慢）..."
    systemctl restart ${SERVICE_NAME} && print_ok "被控端重启成功！" || { print_err "重启失败！"; kill_stuck_process; }
}
status_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，请先安装！"; return 0; }
    echo -e "\n===== GOST V3轻量被控端 运行状态（低配优化版） ======"
    echo -e "服务状态：$(check_running && echo -e "${GREEN_COLOR}运行中${RESET_COLOR}" || echo -e "${RED_COLOR}已停止${RESET_COLOR}")"
    echo -e "本机IP：$(get_inner_ip)"
    echo -e "关联主控：${MASTER_GRPC:-未配置}"
    echo -e "配置信息：CPU≤${CPU_QUOTA} | 内存≤${MEMORY_LIMIT}"
    echo -e "核心路径：安装=${GOST_NODE_DIR}/bin/gost | 配置=${GOST_NODE_DIR}/conf"
    echo -e "====================================================="
    systemctl status ${SERVICE_NAME} --no-pager -l | grep -E 'Active|Main PID|Status' || true
}
log_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，请先安装！"; return 0; }
    echo -e "\n===== 被控端实时日志（仅致命错误，按Ctrl+C退出）=====\n"
    journalctl -u ${SERVICE_NAME} -f -p fatal
}
reconfig_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，请先安装！"; return 0; }
    echo -e "\n===== 重新配置主控端信息（与主控端保持一致）====="
    echo -e "当前配置：主控gRPC=${MASTER_GRPC:-未配置} | 密钥=${AUTH_KEY:-未配置}"
    read -p "新主控端gRPC地址（格式：IP:50051）：" NEW_MASTER
    read -p "新主控端认证密钥（16位字母数字）：" NEW_KEY
    MASTER_GRPC=${NEW_MASTER:-${MASTER_GRPC}}
    AUTH_KEY=${NEW_KEY:-${AUTH_KEY}}
    # 校验
    if [[ ! "${MASTER_GRPC}" =~ ^[0-9.]{7,15}:[0-9]{1,5}$ ]]; then
        print_err "gRPC地址格式错误！正确格式：IP:端口"; return 0;
    fi
    if ! check_key; then
        print_err "认证密钥格式错误！需16位字母数字（与主控端一致）"; return 0;
    fi
    # 重新生成配置
    cat > ${GOST_NODE_DIR}/conf/config.yaml <<EOF
log:
  level:
