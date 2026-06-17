#!/bin/sh
# =================================================================
# Sing-box VLESS-WS-TLS + Hysteria 2 一键部署脚本
# 兼容: Debian / Ubuntu / CentOS / Alpine
# 用法: sh vless_h2.sh [-passwd <密码>] [-port <端口>]
# =================================================================
set -e

# ================== 硬编码配置 ==================
UUID="fdeeda45-0a8e-4570-bcc6-d68c995f5830"
SINGBOX_VER="1.11.1"
MASQ_DOMAIN="www.bing.com"
SERVICE_NAME="vless-singbox"

# ================== 参数解析 ==================
PASSWORD="qwe123"
PORT=8989

while [ $# -gt 0 ]; do
    case "$1" in
        -passwd) PASSWORD="$2"; shift 2 ;;
        -port)   PORT="$2";     shift 2 ;;
        -h|--help)
            echo "用法: sh vless_h2.sh [-passwd <密码>] [-port <端口>]"
            echo ""
            echo "参数:"
            echo "  -passwd <密码>   Hysteria 2 连接密码 (默认: qwe123)"
            echo "  -port   <端口>   VLESS 端口, H2 自动 +1  (默认: 8989)"
            echo ""
            echo "示例:"
            echo "  sh vless_h2.sh"
            echo "  sh vless_h2.sh -passwd MyPass123 -port 9000"
            exit 0 ;;
        *) echo "[错误] 未知参数: $1"; exit 1 ;;
    esac
done

# 端口校验
case "$PORT" in
    *[!0-9]*) echo "[错误] 端口必须是数字"; exit 1 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65534 ]; then
    echo "[错误] 端口必须是 1-65534 之间的数字"
    exit 1
fi

PORT2=$((PORT + 1))

# ================== 系统检测 ==================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)        OS_FAMILY="debian" ;;
            centos|rhel|rocky|alma|fedora) OS_FAMILY="centos" ;;
            alpine)               OS_FAMILY="alpine" ;;
            *)                    OS_FAMILY="$ID" ;;
        esac
    elif [ -f /etc/centos-release ]; then
        OS_FAMILY="centos"
    elif [ -f /etc/alpine-release ]; then
        OS_FAMILY="alpine"
    else
        OS_FAMILY="unknown"
    fi
}

detect_os

# 按系统设置变量（包管理器 / 防火墙命令）
case "$OS_FAMILY" in
    debian)
        PKG_UPDATE="apt-get update -qq"
        PKG_INSTALL="apt-get install -y -qq"
        FW_CMDS="ufw"
        ;;
    centos)
        PKG_UPDATE=""
        PKG_INSTALL="yum install -y"
        FW_CMDS="firewall-cmd"
        ;;
    alpine)
        PKG_UPDATE=""
        PKG_INSTALL="apk add --no-cache"
        FW_CMDS="iptables"
        ;;
    *)
        PKG_UPDATE=""
        PKG_INSTALL=""
        FW_CMDS="iptables"
        ;;
esac

# ================== 工具函数 ==================
log() { printf '[%s] %s\n' "$1" "$2"; }

get_public_ip() {
    for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -s --connect-timeout 3 "$url" 2>/dev/null) || continue
        case "$ip" in
            10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|127.*) ;;
            *) if [ -n "$ip" ]; then echo "$ip"; return; fi ;;
        esac
    done
    echo "127.0.0.1"
}

detect_libc() {
    if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
        echo "musl"
    elif ldd --version 2>&1 | grep -qi musl; then
        echo "musl"
    else
        echo "glibc"
    fi
}

detect_init() {
    if command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

# ================== 安装依赖 ==================
install_deps() {
    missing=""
    for cmd in openssl curl tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if [ -z "$missing" ]; then return; fi

    log "依赖" "缺少:$missing, 正在安装..."

    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq
        apt-get install -y -qq $missing
    elif [ "$OS_FAMILY" = "centos" ]; then
        yum install -y $missing
    elif [ "$OS_FAMILY" = "alpine" ]; then
        apk add --no-cache $missing
    else
        log "错误" "无法自动安装依赖, 请手动安装:$missing"
        exit 1
    fi

    # 验证安装结果
    for cmd in $missing; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "错误" "$cmd 安装失败!"
            exit 1
        fi
    done
    log "依赖" "安装完成"
}

# ================== 防火墙 ==================
open_ports() {
    # ufw (Debian/Ubuntu)
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
        ufw allow "$PORT"/udp >/dev/null 2>&1 || true
        ufw allow "$PORT2"/tcp >/dev/null 2>&1 || true
        ufw allow "$PORT2"/udp >/dev/null 2>&1 || true
        log "防火墙" "ufw: 已开放 $PORT, $PORT2 (tcp+udp)"
        return
    fi

    # firewalld (CentOS/RHEL)
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${PORT2}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${PORT2}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log "防火墙" "firewalld: 已开放 $PORT, $PORT2 (tcp+udp)"
        return
    fi

    # iptables (Alpine / 回退)
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        iptables -C INPUT -p tcp --dport "$PORT2" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$PORT2" -j ACCEPT
        iptables -C INPUT -p udp --dport "$PORT2" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "$PORT2" -j ACCEPT
        # Alpine 持久化
        if [ "$OS_FAMILY" = "alpine" ] && command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules-save
        fi
        log "防火墙" "iptables: 已开放 $PORT, $PORT2 (tcp+udp)"
        return
    fi

    log "防火墙" "未检测到防火墙工具, 跳过端口开放"
}

# ================== 下载 sing-box ==================
download_singbox() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    SINGBOX_BIN="${SCRIPT_DIR}/sing-box"

    if [ -f "$SINGBOX_BIN" ]; then
        log "sing-box" "已存在, 跳过下载"
        return
    fi

    LIBC_TYPE=$(detect_libc)
    if [ "$LIBC_TYPE" = "musl" ]; then
        SUFFIX="linux-musl-amd64"
    else
        SUFFIX="linux-amd64"
    fi

    TARBALL="sing-box-${SINGBOX_VER}-${SUFFIX}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/${TARBALL}"
    log "下载" "sing-box v${SINGBOX_VER} (${LIBC_TYPE})"

    curl -fSL -o "${SCRIPT_DIR}/sing-box.tar.gz" "$URL"

    # 通用解压（兼容 GNU tar 和 BusyBox tar）
    EXT_DIR="/tmp/_singbox_ext_$$"
    mkdir -p "$EXT_DIR"
    tar -zxf "${SCRIPT_DIR}/sing-box.tar.gz" -C "$EXT_DIR"

    FOUND=$(find "$EXT_DIR" -name 'sing-box' -type f | head -1)
    if [ -z "$FOUND" ]; then
        log "错误" "解压后未找到 sing-box 二进制文件"
        rm -rf "$EXT_DIR" "${SCRIPT_DIR}/sing-box.tar.gz"
        exit 1
    fi

    cp "$FOUND" "$SINGBOX_BIN"
    chmod 755 "$SINGBOX_BIN"
    rm -rf "$EXT_DIR" "${SCRIPT_DIR}/sing-box.tar.gz"
    log "下载" "sing-box 安装完成"
}

# ================== 证书生成 ==================
generate_cert() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    CERT_PEM="${SCRIPT_DIR}/cert.pem"
    KEY_PEM="${SCRIPT_DIR}/key.pem"

    if [ -f "$CERT_PEM" ] && [ -f "$KEY_PEM" ]; then
        log "证书" "已存在, 跳过生成"
        return
    fi

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" \
        -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes 2>/dev/null
    log "证书" "已生成 (CN=${MASQ_DOMAIN}, 365天)"
}

# ================== 生成配置 ==================
generate_config() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    CONFIG_JSON="${SCRIPT_DIR}/config.json"

    cat > "$CONFIG_JSON" <<CFGEOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [{ "uuid": "${UUID}", "name": "vless-user" }],
      "tls": {
        "enabled": true,
        "server_name": "${MASQ_DOMAIN}",
        "certificate_path": "${CERT_PEM}",
        "key_path": "${KEY_PEM}"
      },
      "transport": {
        "type": "ws",
        "path": "/",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT2},
      "users": [{ "password": "${PASSWORD}" }],
      "tls": {
        "enabled": true,
        "server_name": "${MASQ_DOMAIN}",
        "certificate_path": "${CERT_PEM}",
        "key_path": "${KEY_PEM}"
      },
      "obfs": {
        "type": "salamander",
        "password": "${PASSWORD}"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
CFGEOF
    log "配置" "config.json 已生成"
}

# ================== 生成链接 ==================
generate_links() {
    IP=$(get_public_ip)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    LINK_TXT="${SCRIPT_DIR}/proxy_links.txt"

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?security=tls&encryption=none&type=ws&path=%2F&sni=${MASQ_DOMAIN}&allowInsecure=1#VLESS-WS-${IP}"
    HY2_LINK="hysteria2://${PASSWORD}@${IP}:${PORT2}?insecure=1&sni=${MASQ_DOMAIN}&obfs=salamander&obfs-password=${PASSWORD}#HY2-${IP}"

    cat > "$LINK_TXT" <<LINKEOF
==================== PROXY LINKS ====================
【VLESS-WS-TLS 链接 (端口: ${PORT} / TCP)】:
${VLESS_LINK}

【Hysteria 2 混淆加速链接 (端口: ${PORT2} / UDP)】:
${HY2_LINK}
=====================================================
LINKEOF

    echo ""
    cat "$LINK_TXT"
    echo ""
}

# ================== 服务管理 ==================
setup_service() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    INIT_SYSTEM=$(detect_init)

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
        cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=Vless Singbox Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_JSON}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl start "$SERVICE_NAME"
        log "服务" "systemd 服务已启动"

    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
        cat > "$SERVICE_FILE" <<ORCEOF
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="Vless Singbox Service"
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_JSON}"
command_user="root"
command_background="yes"
directory="${SCRIPT_DIR}"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    after net
}
ORCEOF
        chmod +x "$SERVICE_FILE"
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
        rc-service "$SERVICE_NAME" stop 2>/dev/null || true
        rc-service "$SERVICE_NAME" start
        log "服务" "OpenRC 服务已启动"

    else
        log "服务" "未检测到 systemd/OpenRC, 以 nohup 后台运行"
        pkill -f "sing-box run -c" 2>/dev/null || true
        nohup "$SINGBOX_BIN" run -c "$CONFIG_JSON" >/dev/null 2>&1 &
    fi
}

# ================== 午夜定时重启 ==================
setup_cron() {
    INIT_SYSTEM=$(detect_init)
    CRON_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        RESTART_CMD="systemctl restart ${SERVICE_NAME}"
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        RESTART_CMD="rc-service ${SERVICE_NAME} restart"
    else
        RESTART_CMD="pkill -f 'sing-box run -c' || true; sleep 2; cd ${CRON_SCRIPT_DIR} && nohup ${SINGBOX_BIN} run -c ${CONFIG_JSON} >/dev/null 2>&1 &"
    fi

    CRON_LINE="0 0 * * * ${RESTART_CMD} # ${SERVICE_NAME} midnight restart"

    # 确保 crontab 命令可用
    if ! command -v crontab >/dev/null 2>&1; then
        if [ "$OS_FAMILY" = "alpine" ]; then
            apk add --no-cache dcron >/dev/null 2>&1 || true
        fi
    fi

    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "# ${SERVICE_NAME} midnight restart"; echo "$CRON_LINE") | crontab -
        log "定时" "已设置 cron 午夜重启 (北京时间 00:00)"
    else
        log "定时" "crontab 不可用, 跳过午夜定时重启"
    fi
}

# ================== 主流程 ==================
main() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    CERT_PEM="${SCRIPT_DIR}/cert.pem"
    KEY_PEM="${SCRIPT_DIR}/key.pem"
    CONFIG_JSON="${SCRIPT_DIR}/config.json"
    SINGBOX_BIN="${SCRIPT_DIR}/sing-box"

    echo "======================================================="
    echo " Sing-box 一键部署 (VLESS-WS-TLS + Hysteria 2)"
    echo "======================================================="
    echo " 系统:   ${OS_FAMILY}"
    echo " 端口:   VLESS=${PORT}  HY2=${PORT2}"
    echo " 密码:   ${PASSWORD}"
    echo " UUID:   ${UUID}"
    echo "======================================================="
    echo ""

    log "步骤" "1/8 安装依赖..."
    install_deps

    log "步骤" "2/8 开放防火墙端口..."
    open_ports

    log "步骤" "3/8 下载 sing-box..."
    download_singbox

    log "步骤" "4/8 生成证书..."
    generate_cert

    log "步骤" "5/8 生成配置..."
    generate_config

    log "步骤" "6/8 获取公网 IP 并生成链接..."
    generate_links

    log "步骤" "7/8 配置系统服务..."
    setup_service

    log "步骤" "8/8 配置定时重启..."
    setup_cron

    echo ""
    echo "======================================================="
    echo " 部署完成!"
    echo "======================================================="
    INIT_SYSTEM=$(detect_init)
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        echo " 查看状态: systemctl status ${SERVICE_NAME}"
        echo " 查看日志: journalctl -u ${SERVICE_NAME} -f"
        echo " 重启服务: systemctl restart ${SERVICE_NAME}"
        echo " 停止服务: systemctl stop ${SERVICE_NAME}"
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        echo " 查看状态: rc-service ${SERVICE_NAME} status"
        echo " 重启服务: rc-service ${SERVICE_NAME} restart"
        echo " 停止服务: rc-service ${SERVICE_NAME} stop"
    fi
    echo " 链接文件: ${SCRIPT_DIR}/proxy_links.txt"
    echo "======================================================="
}

main
