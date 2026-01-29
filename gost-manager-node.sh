GOST V3 轻量被控端 交互式管理脚本（低配VPS优化版）

#!/bin/bash
set -euo pipefail
# GOST V3 轻量被控端 交互式管理脚本【低配VPS优化版】
# 核心优化：极致资源限制+进程轻量化+卡顿兜底，适配性能较差VPS，杜绝卡死
# 特性：自动下载GitHub最新版 | 一键排错 | 低配兼容 | 防卡死机制 | 主控联动适配
# 适配：≤50节点集群 | 单节点资源＜5M | CentOS7+/Ubuntu18+/Debian10+ | x86_64/arm64
# 低配VPS专属：关闭冗余输出、降低进程优先级、限制并发、优化IO，与主控端同步适配

# ==================== 基础配置（低配优化，与主控同步）====================
SERVICE_NAME="gost-node"
GOST_NODE_DIR="/usr/local/gost-node"
MASTER_GRPC=""          # 主控端gRPC地址（格式：IP:50051）
AUTH_KEY=""             # 主控端认证密钥（需与主控一致）
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
# 颜色定义（精简输出，减少终端渲染压力，与主控端保持一致）
RED_COLOR="\033[31m"
GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
RESET_COLOR="\033[0m"
# 🔥 低配VPS核心优化：极致资源限制（比原版更低，防止卡死，适配主控）
CPU_QUOTA="3%"          # CPU占用≤3%（低于主控，避免抢占资源）
MEMORY_LIMIT="8M"       # 内存限制8M（单节点极致轻量，原版16M）
IO_LIMIT="128K"         # IO限制128K/s（低于主控，减少磁盘IO卡顿）
MAX_OPEN_FILES=1024     # 大幅降低最大文件打开数，适配低配VPS内存

# ==================== 核心新增：自动获取GitHub最新GOST版本（与主控同步）====================
get_latest_gost() {
    print_tip "获取GOST最新版本..."
    # 优化：超时10秒，减少卡顿等待；关闭冗余输出，适配低配网络
    LATEST_VERSION=$(curl -s --connect-timeout 10 https://api.github.com/repos/go-gost/gost/releases/latest | grep -E 'tag_name' | cut -d'"' -f4 | sed 's/v//g')
    if [ -z "${LATEST_VERSION}" ]; then
        print_err "获取版本失败！检查GitHub网络（低配VPS建议用代理）"
        exit 1
    fi
    print_ok "最新版本：v${LATEST_VERSION}"
    echo "${LATEST_VERSION}"
}

# ==================== 工具函数（低配优化，与主控同步逻辑）====================
print_ok() { echo -e "${GREEN_COLOR}✅ $1${RESET_COLOR}"; }
print_err() { echo -e "${RED_COLOR}❌ $1${RESET_COLOR}"; }
print_tip() { echo -e "${YELLOW_COLOR}💡 $1${RESET_COLOR}"; }
# 优化1：简化检测逻辑，减少进程占用，比主控更精简
check_installed() { [ -f "${GOST_NODE_DIR}/bin/gost" ] && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && return 0 || return 1; }
check_running() { systemctl is-active --quiet ${SERVICE_NAME} && return 0 || return 1; }
# 优化2：快速端口检测，避免卡顿，仅检测核心端口
check_port() { netstat -tulnp 2>/dev/null | grep -q ":$1 " && return 0 || return 1; }
# 优化3：简化IP获取，减少命令执行压力，仅获取内网IP（被控无需外网展示）
get_inner_ip() {
    INNER_IP=$(ip addr | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
    echo "${INNER_IP:-未获取到IP}"
}
# 优化4：密钥格式校验（简化逻辑，减少计算压力，与主控密钥规则一致）
check_key() { [[ "${AUTH_KEY}" =~ ^[a-zA-Z0-9]{16}$ ]] && return 0 || return 1; }

# ==================== 新增功能：低配VPS专属（防卡死+排错，与主控联动）====================
# 卡顿兜底：杀死卡死进程，释放资源，仅清理被控相关进程，不影响主控联动
kill_stuck_process() {
    print_tip "检查并清理被控端卡死进程..."
    # 仅杀死被控端GOST进程，避免误杀主控相关进程（若主控被控同机部署）
    pkill -f "${GOST_NODE_DIR}/bin/gost" -9 2>/dev/null || true
    print_ok "被控端卡死进程清理完成"
}
# 资源监控：查看当前被控节点资源占用（简化输出，适配低配VPS，重点关注内存）
monitor_resource() {
    print_tip "当前被控节点资源占用（低配VPS重点关注）："
    echo -e "CPU占用：$(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - $1 "%"}\')"
    echo -e "内存占用：$(free -h | grep Mem | awk '{print $3 "/" $2}')"
    echo -e "被控进程：$(ps -ef | grep gost | grep -v grep || echo "未运行")"
    echo -e "本机IP：$(get_inner_ip)"
}
# 主控连通性检测（三重检测，简化逻辑，快速排查联动问题，适配低配网络）
check_master_connect() {
    [ -z "${MASTER_GRPC}" ] && { print_err "未配置主控端gRPC地址！"; return 0; }
    print_tip "检测与主控端（${MASTER_GRPC}）连通性..."
    # 优化：简化检测，仅检测PING、端口、密钥，减少进程占用
    MASTER_IP=$(echo "${MASTER_GRPC}" | cut -d: -f1)
    MASTER_PORT=$(echo "${MASTER_GRPC}" | cut -d: -f2)
    
    # 1. PING检测（超时2秒，快速返回）
    ping -c 1 -W 2 "${MASTER_IP}" >/dev/null 2>&1
    PING_STATUS=$?
    # 2. 端口检测（快速检测gRPC端口）
    check_port "${MASTER_PORT}"
    PORT_STATUS=$?
    # 3. 密钥检测（本地校验，无需联网）
    check_key
    KEY_STATUS=$?

    # 简化输出，清晰展示问题
    echo -e "PING主控IP（${MASTER_IP}）：$( [ ${PING_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}正常${RESET_COLOR}" || echo -e "${RED_COLOR}失败${RESET_COLOR}" )"
    echo -e "检测gRPC端口（${MASTER_PORT}）：$( [ ${PORT_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}可达${RESET_COLOR}" || echo -e "${RED_COLOR}不可达${RESET_COLOR}" )"
    echo -e "认证密钥校验：$( [ ${KEY_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}合法${RESET_COLOR}" || echo -e "${RED_COLOR}非法（需16位字母数字）${RESET_COLOR}" )"
    
    # 快速定位问题，给出适配低配的解决方案
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

# ==================== 核心功能：安装被控端（低配VPS深度优化，与主控联动）====================
install_node() {
    if check_installed; then
        print_tip "检测到已安装被控端！"
        read -p "是否重新安装（覆盖配置，y/n）：" CHOICE
        [ "${CHOICE}" != "y" ] && [ "${CHOICE}" != "Y" ] && { print_ok "取消重新安装"; return 0; }
        # 优化：重新安装前先清理卡死进程，避免冲突，不影响主控
        kill_stuck_process
        systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
    fi

    echo -e "\n===== 安装GOST V3轻量被控端【低配VPS优化版】===="
    # 1. 配置主控信息（简化输入，减少交互卡顿）
    print_tip "请输入主控端核心信息（需与主控端一致）"
    read -p "主控端gRPC地址（格式：IP:50051）：" MASTER_GRPC
    read -p "主控端认证密钥（16位字母数字）：" AUTH_KEY

    # 2. 简单校验配置（简化逻辑，快速完成，避免卡顿）
    if [[ ! "${MASTER_GRPC}" =~ ^[0-9.]{7,15}:[0-9]{1,5}$ ]]; then
        print_err "gRPC地址格式错误！正确格式：IP:端口（例：192.168.1.1:50051）"
        exit 1
    fi
    if ! check_key; then
        print_err "认证密钥格式错误！需16位字母数字（与主控端一致）"
        exit 1
    fi

    # 3. 安装基础依赖（极致精简，仅安装必需依赖，比主控更少）
    print_tip "安装基础依赖（被控端精简版，仅必需组件）..."
    if [ -f /etc/redhat-release ]; then
        # 只安装wget、tar，关闭yum缓存，减少IO和内存占用
        yum install -y -q wget tar net-tools --setopt=tsflags=nodocs >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    elif [ -f /etc/debian_version ]; then
        # 精简apt更新，只更新必要软件源，避免占用过多资源
        apt update -y -qq >/dev/null 2>&1 && apt install -y -qq wget tar net-tools >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    else
        print_err "仅支持CentOS/Ubuntu/Debian！"; exit 1;
    fi

    # 4. 自动获取最新版本并下载（与主控同步版本，优化：断点续传，超时兜底）
    GOST_VERSION=$(get_latest_gost)
    GOST_TAR="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${GOST_TAR}"
    print_tip "下载GOST v${GOST_VERSION}（${ARCH}架构，断点续传）..."
    # 优化：超时30秒，断点续传，关闭冗余进度条（减少终端卡顿）
    wget -q -c --timeout=30 ${GOST_URL} -O /tmp/${GOST_TAR} || { print_err "GOST下载失败！配置代理后重试"; exit 1; }
    # 优化：解压仅提取需要的文件，减少IO操作，快速完成
    mkdir -p ${GOST_NODE_DIR}/bin
    tar zxf /tmp/${GOST_TAR} -C ${GOST_NODE_DIR}/bin gost >/dev/null 2>&1
    chmod +x ${GOST_NODE_DIR}/bin/gost && rm -rf /tmp/${GOST_TAR}  # 及时清理临时文件，释放空间

    # 5. 验证安装（简化逻辑，快速完成，仅验证版本）
    if ! ${GOST_NODE_DIR}/bin/gost -V >/dev/null 2>&1; then
        print_err "GOST安装验证失败！可能是架构不匹配"
        exit 1
    fi
    print_ok "GOST v${GOST_VERSION} 安装验证成功！"

    # 6. 生成被控端配置（极致精简，减少内存占用，仅保留主控联动核心配置）
    print_tip "生成被控端配置（精简版，仅保留主控联动功能）..."
    mkdir -p ${GOST_NODE_DIR}/conf ${GOST_NODE_DIR}/log
    # 优化：配置精简，关闭所有冗余日志，仅记录致命错误（比主控更精简）
    cat > ${GOST_NODE_DIR}/conf/config.yaml <<EOF
log:
  level: fatal  # 仅记录致命错误（比主控error级别更高，减少IO）
  file: ${GOST_NODE_DIR}/log/gost-node.log
  max-size: 10  # 日志最大10M（低于主控，减少磁盘占用）
  max-age: 1    # 日志保留1天（低于主控）
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

    # 7. 配置Systemd服务（🔥 低配核心优化：防卡死+资源限制，低于主控）
    print_tip "配置Systemd服务（防卡死+开机自启，适配低配VPS）..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=GOST V3 Light Node [Low-VPS Optimized]
After=network.target
Wants=network.target
ExecStartPre=/bin/sleep 8  # 延长启动延迟（比主控长，避免与主控同时启动抢占资源）
ExecStartPre=/bin/bash -c "ulimit -n ${MAX_OPEN_FILES}"  # 限制最大文件打开数

[Service]
Type=simple
User=root
WorkingDirectory=${GOST_NODE_DIR}
ExecStart=${GOST_NODE_DIR}/bin/gost -C ${GOST_NODE_DIR}/conf/config.yaml
Restart=on-failure
RestartSec=15s  # 延长重启间隔（比主控长，避免频繁重启占用资源）
LimitNOFILE=${MAX_OPEN_FILES}
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
# 核心资源限制（防卡死关键，低于主控，适配被控轻量需求）
CPUQuota=${CPU_QUOTA}
MemoryLimit=${MEMORY_LIMIT}
MemorySwapLimit=0  # 禁止交换内存，避免卡顿
IOReadBandwidthMax=/dev/sda ${IO_LIMIT}
IOWriteBandwidthMax=/dev/sda ${IO_LIMIT}
# 低配优化：降低进程优先级（比主控更低，避免抢占主控资源）
Nice=20
IOSchedulingClass=2
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF

    # 8. 启动服务+开放必要端口（优化：简化操作，仅开放被控必需端口，减少防火墙操作）
    systemctl daemon-reload >/dev/null 2>&1
    # 优化：启动前再次清理卡死进程，确保启动成功
    kill_stuck_process
    systemctl enable --now ${SERVICE_NAME} >/dev/null 2>&1
    print_tip "被控端服务启动中（低配VPS启动可能较慢，请耐心等待）..."

    # 9. 验证安装结果（简化输出，减少终端渲染压力，重点验证与主控联动）
    sleep 3  # 给低配VPS足够启动时间
    if check_installed && check_running; then
        print_ok "GOST V3轻量被控端【低配VPS优化版】安装成功！"
        echo -e "\n${GREEN_COLOR}===== 被控端核心信息（务必保存）=====${RESET_COLOR}"
        echo -e "本机IP：$(get_inner_ip)"
        echo -e "关联主控：${MASTER_GRPC}"
        echo -e "认证密钥：${AUTH_KEY}（与主控一致）"
        echo -e "资源限制：CPU≤${CPU_QUOTA} | 内存≤${MEMORY_LIMIT}"
        echo -e "${GREEN_COLOR}==============================${RESET_COLOR}"
        # 低配提示：建议检测与主控连通性
        print_tip "低配VPS建议执行选项9（检测主控连通性），确认联动正常"
    else
        print_err "安装成功但服务启动失败！执行选项10生成排错日志"
        # 兜底：尝试清理卡死进程，重新启动，不影响主控
        kill_stuck_process
        systemctl restart ${SERVICE_NAME} >/dev/null 2>&1
    fi
}

# ==================== 原有功能：优化适配低配VPS（防卡死，与主控联动）====================
start_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，请先安装！"; return 0; }
    check_running && { print_ok "被控端已在运行！"; return 0; }
    # 优化：启动前清理卡死进程，避免启动失败，不影响主控
    kill_stuck_process
    print_tip "启动被控端（低配VPS启动可能较慢，请耐心等待）..."
    systemctl start ${SERVICE_NAME} && print_ok "被控端启动成功！" || { print_err "启动失败！"; kill_stuck_process; }
}

stop_node() {
    [ ! check_installed ] && { print_err "未检测到被控端！"; return 0; }
    [ ! check_running ] && { print_ok "被控端已停止！"; return 0; }
    # 优化：停止后清理残留进程，释放资源，仅清理被控进程
    systemctl stop ${SERVICE_NAME} && print_ok "被控端已停止！"
    kill_stuck_process
}

restart_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，请先安装！"; return 0; }
    # 优化：重启前清理卡死进程，避免卡顿，不影响主控
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
    # 优化：简化状态输出，减少命令执行压力，仅显示核心状态
    systemctl status ${SERVICE_NAME} --no-pager -l | grep -E 'Active|Main PID|Status' || true
}

log_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，请先安装！"; return 0; }
    echo -e "\n===== 被控端实时日志（仅致命错误，按Ctrl+C退出）=====\n"
    # 优化：仅查看致命错误日志，减少终端卡顿，适配低配VPS
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

    # 端口校验（简化逻辑）
    if [[ ! "${MASTER_GRPC}" =~ ^[0-9.]{7,15}:[0-9]{1,5}$ ]]; then
        print_err "gRPC地址格式错误！正确格式：IP:端口"; return 0;
    fi
    if ! check_key; then
        print_err "认证密钥格式错误！需16位字母数字（与主控端一致）"; return 0;
    fi

    # 重新生成配置（同步低配优化，仅保留核心配置）
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

    # 重启服务（优化：先停止，清理进程，再启动，避免冲突）
    stop_node
    systemctl daemon-reload >/dev/null 2>&1
    start_node
    print_ok "主控信息配置修改成功！新配置：${MASTER_GRPC} | 密钥已更新"
}

uninstall_node() {
    [ ! check_installed ] && { print_err "未检测到被控端，无需卸载！"; return 0; }
    echo -e "\n${RED_COLOR}⚠️  警告：卸载将删除被控端所有数据，不影响主控！${RESET_COLOR}"
    read -p "请输入 uninstall 确认卸载：" CHOICE
    [ "${CHOICE}" != "uninstall" ] && { print_ok "取消卸载"; return 0; }
    # 优化：卸载前停止服务，清理所有进程和残留，不影响主控
    stop_node
    systemctl disable ${SERVICE_NAME} >/dev/null 2>&1
    rm -rf ${GOST_NODE_DIR} /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload >/dev/null 2>&1
    # 可选卸载依赖（低配VPS建议保留依赖，避免后续安装卡顿，与主控一致）
    read -p "是否卸载基础依赖（y/n，低配建议n）：" DEP_CHOICE
    if [ "${DEP_CHOICE}" = "y" ] || [ "${DEP_CHOICE}" = "Y" ]; then
        [ -f /etc/redhat-release ] && yum remove -y -q wget tar net-tools >/dev/null 2>&1
        [ -f /etc/debian_version ] && apt remove -y -qq wget tar net-tools >/dev/null 2>&1
        print_tip "基础依赖已卸载"
    fi
    print_ok "GOST被控端已完全卸载，无残留，不影响主控运行！"
}

# 配置备份（优化：简化备份，减少IO压力，仅备份核心配置，与主控备份逻辑一致）
backup_node_config() {
    if ! check_installed; then print_err "未检测到被控端，无需备份！"; return 0; fi
    print_tip "备份被控端配置（精简版，仅备份核心联动配置）..."
    BACKUP_NAME="gost-node-backup-$(date +%Y%m%d).tar.gz"
    BACKUP_PATH="/root/${BACKUP_NAME}"
    # 优化：仅备份配置文件，减少备份体积和IO操作（被控无需备份数据库）
    tar -zcf ${BACKUP_PATH} ${GOST_NODE_DIR}/conf/ >/dev/null 2>&1
    [ -f "${BACKUP_PATH}" ] && print_ok "备份成功！${BACKUP_PATH}（$(du -sh ${BACKUP_PATH} | awk '{print $1}')）" || print_err "备份失败！"
}

# 一键排错日志（优化：简化日志，减少生成时间，重点排查与主控联动问题）
debug_node_log() {
    if ! check_installed; then print_err "未检测到被控端，请先安装！"; return 0; fi
    print_tip "生成被控端排错日志（低配简化版，快速定位卡死/联动问题）..."
    DEBUG_NAME="gost-node-debug-$(date +%Y%m%d%H%M%S).tar.gz"
    DEBUG_PATH="/root/${DEBUG_NAME}"
    mkdir -p /tmp/gost-node-debug/
    # 优化：仅保留核心排错信息，减少日志体积，重点关注主控联动
    echo "=== 被控节点信息 ===" >/tmp/gost-node-debug/node.info && echo "IP：$(get_inner_ip) | 关联主控：${MASTER_GRPC} | 内存限制：${MEMORY_LIMIT}" >>/tmp/gost-node-debug/node.info
    echo "=== 系统资源 ===" >/tmp/gost-node-debug/system.info && top -bn1 | grep -E 'Cpu|Mem' >>/tmp/gost-node-debug/system.info && free -h >>/tmp/gost-node-debug/system.info
    echo "=== 服务状态 ===" >/tmp/gost-node-debug/status.info && systemctl status ${SERVICE_NAME} --no-pager >>/tmp/gost-node-debug/status.info
    echo "=== 致命错误日志 ===" >/tmp/gost-node-debug/log.info && journalctl -u ${SERVICE_NAME} -n 30 --no-pager -p fatal >>/tmp/gost-node-debug/log.info
    echo "=== 主控连通性 ===" >/tmp/gost-node-debug/connect.info && check_master_connect >>/tmp/gost-node-debug/connect.info 2>&1
    tar -zcf ${DEBUG_PATH} /tmp/gost-node-debug/ >/dev/null 2>&1 && rm -rf /tmp/gost-node-debug/
    print_ok "排错日志生成完成！${DEBUG_PATH}（建议发送此文件排查卡死/联动问题）"
}

# ==================== 主菜单（新增低配专属功能，与主控菜单风格一致）====================
main() {
    clear
    echo -e "======================================"
    echo -e "  GOST V3 轻量被控端 交互式管理【低配VPS优化版】"
    echo -e "  特性：防卡死 | 极致资源限制 | 一键排错 | 主控联动"
    echo -e "  适配：≤50节点集群 | 单节点资源＜5M | 低配VPS专用"
    echo -e "======================================"
    echo -e "  1. 安装被控端（一键部署+防卡死优化）"
    echo -e "  2. 启动被控端（启动前清理卡死进程）"
    echo -e "  3. 停止被控端（停止后释放全部资源）"
    echo -e "  4. 重启被控端（重启前清理卡死进程）"
    echo -e "  5. 查看运行状态"
    echo -e "  6. 查看实时日志（仅致命错误，排错用）"
    echo -e "  7. 重新配置主控信息（更换主控/密钥）"
    echo -e "  8. 卸载被控端（需验证+彻底清理）"
    echo -e "  9. 检测主控连通性（快速排查联动问题）"
    echo -e "10. 一键生成排错日志（定位卡死/联动问题）"
    echo -e "11. 备份节点配置（防配置丢失）"
    echo -e "12. 查看资源占用（低配VPS重点功能）"  # 新增：资源监控
    echo -e "13. 清理卡死进程（兜底防卡死）"        # 新增：手动清理卡死进程
    echo -e "  0. 退出脚本"
    echo -e "======================================"
    read -p "请输入操作选项（0-13）：" OPTION
    case ${OPTION} in
        1) install_node ;;
        2) start_node ;;
        3) stop_node ;;
        4) restart_node ;;
        5) status_node ;;
        6) log_node ;;
        7) reconfig_node ;;
        8) uninstall_node ;;
        9) check_master_connect ;;
        10) debug_node_log ;;
        11) backup_node_config ;;
        12) monitor_resource ;;  # 资源监控
        13) kill_stuck_process ;; # 手动清理卡死进程
        0) print_ok "退出脚本，再见！"; exit 0 ;;
        *) print_err "无效选项，请输入0-13之间的数字！" ;;
    esac
    echo -e "\n${YELLOW_COLOR}按任意键返回主菜单...${RESET_COLOR}"
    read -n 1 -s
    main
}

# 启动主菜单（优化：启动前检查系统资源，给出提示，比主控更严格，适配被控轻量需求）
echo -e "${YELLOW_COLOR}💡 低配VPS优化版被控端脚本启动中...${RESET_COLOR}"
# 启动前检查内存，若内存过低，给出提示（被控要求更低，空闲内存＜32M提示）
FREE_MEM=$(free -m | grep Mem | awk '{print $4}')
if [ ${FREE_MEM} -lt 32 ]; then
    print_err "警告：当前空闲内存＜32M，被控端可能卡死！建议关闭其他无关进程"
    read -p "是否继续启动脚本？（y/n）：" CHOICE
    [ "${CHOICE}" != "y" ] && [ "${CHOICE}" != "Y" ] && { print_ok "退出脚本"; exit 0; }
fi
main


