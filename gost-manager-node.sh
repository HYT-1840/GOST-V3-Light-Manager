#!/bin/bash
set -euo pipefail
# GOST V3 轻量被控端 交互式管理脚本（恢复正常资源占用 + 增加日志输出）
# 说明：本文件在原低配优化版基础上恢复为正常资源限制并将日志级别提升为 info 以便排查问题。
# 变更要点：
# - CPUQuota: 50%
# - MemoryLimit: 256M
# - 移除激进的 IO 限制与禁止交换设置（兼容性更好）
# - MAX_OPEN_FILES 提升为 65536
# - 日志级别由 fatal -> info；实时查看与排错包含 info 级别日志

# ==================== 基础配置（恢复正常资源占用，与主控同步）====================
SERVICE_NAME="gost-node"
GOST_NODE_DIR="/usr/local/gost-node"
MASTER_GRPC=""          # 主控端gRPC地址（格式：IP:50051）
AUTH_KEY=""             # 主控端认证密钥（需与主控一致）
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
# 颜色定义（保持输出）
RED_COLOR="\033[31m"
GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
RESET_COLOR="\033[0m"
# 恢复为合理的资源限制（非极限模式）
CPU_QUOTA="50%"         # CPU 最大占用（合理默认）
MEMORY_LIMIT="256M"     # 内存限制 256M（恢复为常规值）
IO_LIMIT=""             # 不强制设置 IO 限制（兼容更多 VPS）
MAX_OPEN_FILES=65536    # 提高最大文件打开数，避免因过低导致失败

# ==================== 核心新增：自动获取GitHub最新GOST版本（与主控同步）====================
get_latest_gost() {
    print_tip "获取GOST最新版本..."
    LATEST_VERSION=$(curl -s --connect-timeout 10 https://api.github.com/repos/go-gost/gost/releases/latest | grep -E 'tag_name' | cut -d'"' -f4 | sed 's/v//g')
    if [ -z "${LATEST_VERSION}" ]; then
        print_err "获取版本失败！检查GitHub网络（若网络受限建议用代理）"
        exit 1
    fi
    print_ok "最新版本：v${LATEST_VERSION}"
    echo "${LATEST_VERSION}"
}

# ==================== 工具函数（恢复正常日志输出）====================
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

# ==================== 新增功能：防卡死+排错（保留）====================
kill_stuck_process() {
    print_tip "检查并清理被控端卡死进程..."
    pkill -f "${GOST_NODE_DIR}/bin/gost" -9 2>/dev/null || true
    print_ok "被控端卡死进程清理完成"
}
monitor_resource() {
    print_tip "当前被控节点资源占用："
    CPU_USAGE=$(top -bn1 | grep 'Cpu(s)' | awk -F',' '{for(i=1;i<=NF;i++){if($i ~ /id/){print $i}}}' | awk '{print 100 - $1 "%"}' 2>/dev/null || echo "N/A")
    echo -e "CPU占用：${CPU_USAGE}"
    echo -e "内存占用：$(free -h | grep Mem | awk '{print $3 "/" $2}')"
    echo -e "交换空间：$(free -h | grep Swap | awk '{print $3 "/" $2}')"
    echo -e "被控进程：$(ps -ef | grep gost | grep -v grep || echo "未运行")"
    echo -e "本机IP：$(get_inner_ip)"
}
check_master_connect() {
    [ -z "${MASTER_GRPC}" ] && { print_err "未配置主控端gRPC地址！"; return 0; }
    print_tip "检测与主控端（${MASTER_GRPC}）连通性..."
    MASTER_IP=$(echo "${MASTER_GRPC}" | cut -d: -f1)
    MASTER_PORT=$(echo "${MASTER_GRPC}" | cut -d: -f2)
    ping -c 1 -W 2 "${MASTER_IP}" >/dev/null 2>&1
    PING_STATUS=$?
    check_port "${MASTER_PORT}"
    PORT_STATUS=$?
    check_key
    KEY_STATUS=$?
    echo -e "PING主控IP（${MASTER_IP}）：$( [ ${PING_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}正常${RESET_COLOR}" || echo -e "${RED_COLOR}失败${RESET_COLOR}" )"
    echo -e "检测gRPC端口（${MASTER_PORT}）：$( [ ${PORT_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}可达${RESET_COLOR}" || echo -e "${RED_COLOR}不可达${RESET_COLOR}" )"
    echo -e "认证密钥校验：$( [ ${KEY_STATUS} -eq 0 ] && echo -e "${GREEN_COLOR}合法${RESET_COLOR}" || echo -e "${RED_COLOR}非法（需16位字母数字）${RESET_COLOR}" )"
    if [ ${PING_STATUS} -ne 0 ]; then
        print_tip "解决方案：检查主控与被控网络连通性，若网络受限请调整防火墙/路由或使用代理"
    elif [ ${PORT_STATUS} -ne 0 ]; then
        print_tip "解决方案：检查主控端gRPC端口是否开放，或主控服务是否运行"
    elif [ ${KEY_STATUS} -ne 0 ]; then
        print_tip "解决方案：重新配置主控密钥（需与主控端16位字母数字密钥一致）"
    else
        print_ok "与主控端连通性正常，可正常联动！"
    fi
}

# ==================== 安装/配置（恢复日志输出到 info 级别）====================
install_node() {
    if check_installed; then
        print_tip "检测到已安装被控端！"
        read -p "是否重新安装（覆盖配置，y/n）：" CHOICE
        [ "${CHOICE}" != "y" ] && [ "${CHOICE}" != "Y" ] && { print_ok "取消重新安装"; return 0; }
        kill_stuck_process
        systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
    fi

    echo -e "\n===== 安装GOST V3被控端（恢复资源限制 + 增强日志）===="
    print_tip "请输入主控端核心信息（需与主控端一致）"
    read -p "主控端gRPC地址（格式：IP:50051）：" MASTER_GRPC
    read -p "主控端认证密钥（16位字母数字）：" AUTH_KEY

    if [[ ! "${MASTER_GRPC}" =~ ^[0-9.]{7,15}:[0-9]{1,5}$ ]]; then
        print_err "gRPC地址格式错误！正确格式：IP:端口（例：192.168.1.1:50051）"
        exit 1
    fi
    if ! check_key; then
        print_err "认证密钥格式错误！需16位字母数字（与主控端一致）"
        exit 1
    fi

    print_tip "安装基础依赖（仅必需组件）..."
    if [ -f /etc/redhat-release ]; then
        yum install -y -q wget tar net-tools --setopt=tsflags=nodocs >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    elif [ -f /etc/debian_version ]; then
        apt update -y -qq >/dev/null 2>&1 && apt install -y -qq wget tar net-tools >/dev/null 2>&1 || { print_err "依赖安装失败"; exit 1; }
    else
        print_err "仅支持CentOS/Ubuntu/Debian！"; exit 1;
    fi

    GOST_VERSION=$(get_latest_gost)
    GOST_TAR="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${GOST_TAR}"
    print_tip "下载GOST v${GOST_VERSION}（${ARCH}架构，断点续传）..."
    wget -q -c --timeout=30 ${GOST_URL} -O /tmp/${GOST_TAR} || { print_err "GOST下载失败！配置代理后重试"; exit 1; }
    mkdir -p ${GOST_NODE_DIR}/bin
    tar zxf /tmp/${GOST_TAR} -C ${GOST_NODE_DIR}/bin gost >/dev/null 2>&1 || true
    chmod +x ${GOST_NODE_DIR}/bin/gost && rm -rf /tmp/${GOST_TAR}

    if ! ${GOST_NODE_DIR}/bin/gost -V >/dev/null 2>&1; then
        print_err "GOST安装验证失败！可能是架构不匹配"
        exit 1
    fi
    print_ok "GOST v${GOST_VERSION} 安装验证成功！"

    print_tip "生成被控端配置（日志级别：info）..."
    mkdir -p ${GOST_NODE_DIR}/conf ${GOST_NODE_DIR}/log
    cat > ${GOST_NODE_DIR}/conf/config.yaml <<EOF
log:
  level: info     # 增强日志输出，便于排查
  file: ${GOST_NODE_DIR}/log/gost-node.log
  max-size: 50    # 日志最大50M
  max-age: 7      # 日志保留7天
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

    print_tip "配置Systemd服务（恢复为正常资源限制）..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=GOST V3 Node (normal resource limits)
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${GOST_NODE_DIR}
ExecStart=${GOST_NODE_DIR}/bin/gost -C ${GOST_NODE_DIR}/conf/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=${MAX_OPEN_FILES}
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
# 资源限制（适度，兼容多数 VPS）
CPUQuota=${CPU_QUOTA}
MemoryLimit=${MEMORY_LIMIT}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    kill_stuck_process
    systemctl enable --now ${SERVICE_NAME} >/dev/null 2>&1
    print_tip "被控端服务启动中（请等待几秒）..."

    sleep 3
    if check_installed && check_running; then
        print_ok "GOST 被控端安装并启动成功！"
        echo -e "\n${GREEN_COLOR}===== 被控端核心信息（务必保存）=====${RESET_COLOR}"
        echo -e "本机IP：$(get_inner_ip)"
        echo -e "关联主控���${MASTER_GRPC}"
        echo -e "认证密钥：${AUTH_KEY}（与主控一致）"
        echo -e "资源限制：CPU≤${CPU_QUOTA} | 内存≤${MEMORY_LIMIT}"
        echo -e "${GREEN_COLOR}==============================${RESET_COLOR}"
        print_tip "建议执行选项9（检测主控连通性）和选项6/10查看日志与排错信息"
    else
        print_err "安装成功但服务启动失败！请查看日志（选项6或 systemctl status）"
        kill_stuck_process
        systemctl restart ${SERVICE_NAME} >/dev/null 2>&1 || true
    fi
}

# ==================== 运行控制 =====================
start_node() {
    if ! check_installed; then print_err "未检测到被控端，请先安装！"; return 0; fi
    if check_running; then print_ok "被控端已在运行！"; return 0; fi
    kill_stuck_process
    print_tip "启动被控端..."
    systemctl start ${SERVICE_NAME} && print_ok "被控端启动成功！" || { print_err "启动失败！"; kill_stuck_process; }
}

stop_node() {
    if ! check_installed; then print_err "未检测到被控端！"; return 0; fi
    if ! check_running; then print_ok "被控端已停止！"; return 0; fi
    systemctl stop ${SERVICE_NAME} && print_ok "被控端已停止！"
    kill_stuck_process
}

restart_node() {
    if ! check_installed; then print_err "未检测到被控端，请先安装！"; return 0; fi
    kill_stuck_process
    print_tip "重启被控端..."
    systemctl restart ${SERVICE_NAME} && print_ok "被控端重启成功！" || { print_err "重启失败！"; kill_stuck_process; }
}

status_node() {
    if ! check_installed; then print_err "未检测到被控端，请先安装！"; return 0; fi
    echo -e "\n===== GOST 被控端 运行状态 ====="
    echo -e "服务状态：$(check_running && echo -e "${GREEN_COLOR}运行中${RESET_COLOR}" || echo -e "${RED_COLOR}已停止${RESET_COLOR}")"
    echo -e "本机IP：$(get_inner_ip)"
    echo -e "关联主控：${MASTER_GRPC:-未配置}"
    echo -e "配置信息：CPU≤${CPU_QUOTA} | 内存≤${MEMORY_LIMIT}"
    echo -e "核心路径：安装=${GOST_NODE_DIR}/bin/gost | 配置=${GOST_NODE_DIR}/conf"
    echo -e "====================================================="
    systemctl status ${SERVICE_NAME} --no-pager -l | grep -E 'Active|Main PID|Status' || true
}

log_node() {
    if ! check_installed; then print_err "未检测到被控端，请先安装！"; return 0; fi
    echo -e "\n===== 被控端实时日志（info 及以上，按Ctrl+C退出）=====\n"
    journalctl -u ${SERVICE_NAME} -f -p info
}

reconfig_node() {
    if ! check_installed; then print_err "未检测到被控端，请先安装！"; return 0; fi
    echo -e "\n===== 重新配置主控端信息（与主控端保持一致）====="
    echo -e "当前配置：主控gRPC=${MASTER_GRPC:-未配置} | 密钥=${AUTH_KEY:-未配置}"
    read -p "新主控端gRPC地址（格式：IP:50051）：" NEW_MASTER
    read -p "新主控端认证密钥（16位字母数字）：" NEW_KEY
    MASTER_GRPC=${NEW_MASTER:-${MASTER_GRPC}}
    AUTH_KEY=${NEW_KEY:-${AUTH_KEY}}
    if [[ ! "${MASTER_GRPC}" =~ ^[0-9.]{7,15}:[0-9]{1,5}$ ]]; then
        print_err "gRPC地址格式错误！正确格式：IP:端口"; return 0;
    fi
    if ! check_key; then
        print_err "认证密钥格式错误！需16位字母数字（与主控端一致）"; return 0;
    fi
    cat > ${GOST_NODE_DIR}/conf/config.yaml <<EOF
log:
  level: info
  file: ${GOST_NODE_DIR}/log/gost-node.log
  max-size: 50
  max-age: 7
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
    stop_node
    systemctl daemon-reload >/dev/null 2>&1
    start_node
    print_ok "主控信息配置修改成功！新配置：${MASTER_GRPC} | 密钥已更新"
}

uninstall_node() {
    if ! check_installed; then print_err "未检测到被控端，无需卸载！"; return 0; fi
    echo -e "\n${RED_COLOR}⚠️ 卸载将删除被控端所有数据，不影响主控！${RESET_COLOR}"
    read -p "请输入 uninstall 确认卸载：" CHOICE
    [ "${CHOICE}" != "uninstall" ] && { print_ok "取消卸载"; return 0; }
    stop_node
    systemctl disable ${SERVICE_NAME} >/dev/null 2>&1
    rm -rf ${GOST_NODE_DIR} /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload >/dev/null 2>&1
    read -p "是否卸载基础依赖（y/n，建议 n）：" DEP_CHOICE
    if [ "${DEP_CHOICE}" = "y" ] || [ "${DEP_CHOICE}" = "Y" ]; then
        [ -f /etc/redhat-release ] && yum remove -y -q wget tar net-tools >/dev/null 2>&1
        [ -f /etc/debian_version ] && apt remove -y -qq wget tar net-tools >/dev/null 2>&1
        print_tip "基础依赖已卸载"
    fi
    print_ok "GOST被控端已完全卸载"
}

backup_node_config() {
    if ! check_installed; then print_err "未检测到被控端，无需备份！"; return 0; fi
    print_tip "备份被控端配置..."
    BACKUP_NAME="gost-node-backup-$(date +%Y%m%d).tar.gz"
    BACKUP_PATH="/root/${BACKUP_NAME}"
    tar -zcf ${BACKUP_PATH} ${GOST_NODE_DIR}/conf/ >/dev/null 2>&1
    [ -f "${BACKUP_PATH}" ] && print_ok "备份成功！${BACKUP_PATH}（$(du -sh ${BACKUP_PATH} | awk '{print $1}')）" || print_err "备份失败！"
}

debug_node_log() {
    if ! check_installed; then print_err "未检测到被控端，请先安装！"; return 0; fi
    print_tip "生成被控端排错日志（包含 info 级别）..."
    DEBUG_NAME="gost-node-debug-$(date +%Y%m%d%H%M%S).tar.gz"
    DEBUG_PATH="/root/${DEBUG_NAME}"
    mkdir -p /tmp/gost-node-debug/
    echo "=== 被控节点信息 ===" >/tmp/gost-node-debug/node.info && echo "IP：$(get_inner_ip) | 关联主控：${MASTER_GRPC} | 内存限制：${MEMORY_LIMIT}" >>/tmp/gost-node-debug/node.info
    echo "=== 系统资源 ===" >/tmp/gost-node-debug/system.info && top -bn1 | grep -E 'Cpu|Mem' >>/tmp/gost-node-debug/system.info && free -h >>/tmp/gost-node-debug/system.info
    echo "=== 服务状态 ===" >/tmp/gost-node-debug/status.info && systemctl status ${SERVICE_NAME} --no-pager >>/tmp/gost-node-debug/status.info
    echo "=== Info/错误日志 ===" >/tmp/gost-node-debug/log.info && journalctl -u ${SERVICE_NAME} -n 200 --no-pager -p info >>/tmp/gost-node-debug/log.info
    echo "=== 主控连通性 ===" >/tmp/gost-node-debug/connect.info && check_master_connect >>/tmp/gost-node-debug/connect.info 2>&1
    tar -zcf ${DEBUG_PATH} /tmp/gost-node-debug/ >/dev/null 2>&1 && rm -rf /tmp/gost-node-debug/
    print_ok "排错日志生成完成！${DEBUG_PATH}（建议发送此文件排查问题）"
}

# ==================== 主菜单 =====================
main() {
    clear
    echo -e "======================================"
    echo -e "  GOST V3 被控端 管理（恢复资源 & 增强日志）"
    echo -e "======================================"
    echo -e "  1. 安装被控端"
    echo -e "  2. 启动被控端"
    echo -e "  3. 停止被控端"
    echo -e "  4. 重启被控端"
    echo -e "  5. 查看运行状态"
    echo -e "  6. 查看实时日志（info 及以上）"
    echo -e "  7. 重新配置主控信息"
    echo -e "  8. 卸载被控端"
    echo -e "  9. 检测主控连通性"
    echo -e "  10. 一键生成排错日志"
    echo -e "  11. 备份节点配置"
    echo -e "  12. 查看资源占用"
    echo -e "  13. 清理卡死进程"
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
        12) monitor_resource ;;
        13) kill_stuck_process ;;
        0) print_ok "退出脚本，再见！"; exit 0 ;;
        *) print_err "无效选项，请输入0-13之间的数字！" ;;
    esac
    echo -e "\n${YELLOW_COLOR}按任意键返回主菜单...${RESET_COLOR}"
    read -n 1 -s
    main
}

echo -e "${YELLOW_COLOR}脚本启动中...${RESET_COLOR}"
FREE_MEM=$(free -m | grep Mem | awk '{print $4}')
if [ ${FREE_MEM} -lt 32 ]; then
    print_err "当前空闲内存＜32M，可能影响安装/运行"
    read -p "是否继续启动脚本？（y/n）：" CHOICE
    [ "${CHOICE}" != "y" ] && [ "${CHOICE}" != "Y" ] && { print_ok "退出脚本"; exit 0; }
fi
main
