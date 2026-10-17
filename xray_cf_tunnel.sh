#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  xray-cf-tunnel.sh — 一键 Cloudflare Tunnel (Argo) 节点部署
#  无需公网 IP / 端口映射，cloudflared 隧道主动连 CF
#  单节点 VLESS + WebSocket，走 CF 边缘（橙云效果）
# ============================================================

# ── 常量 ──────────────────────────────────────────────
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_PATH="$XRAY_CONFIG_DIR/config.json"
XRAY_BINARY="/usr/local/bin/xray"
CLOUDFLARED_BINARY="/usr/local/bin/cloudflared"
STATE_DIR="/etc/xray-cf-tunnel"
STATE_PATH="$STATE_DIR/state.json"
CF_ACCOUNT_PATH="$STATE_DIR/cf_account.json"
LAST_LINKS_PATH="$(pwd)/cf_tunnel_last_links.txt"
TUNNEL_NAME="xray-cf-tunnel"

CF_API="https://api.cloudflare.com/client/v4"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# ── 工具 ──────────────────────────────────────────────
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m·\033[0m %s\n' "$*" >&2; }

urlencode() {
    local s="$1" c i
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]'; }

# ── init 系统检测 ─────────────────────────────────────
INIT_SYSTEM=""
detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

# ── 包管理器 ──────────────────────────────────────────
install_deps() {
    local missing=()
    command -v curl    &>/dev/null || missing+=(curl)
    command -v jq      &>/dev/null || missing+=(jq)
    command -v openssl &>/dev/null || missing+=(openssl)
    [[ ${#missing[@]} -eq 0 ]] && return
    echo "安装依赖: ${missing[*]}"
    if command -v apk &>/dev/null; then
        apk add --no-cache "${missing[@]}"
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}"
    else
        die "无法安装依赖 ${missing[*]}"
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*)        echo "arm" ;;
        *)             die "不支持的架构: $(uname -m)" ;;
    esac
}

# ── 安装 xray ─────────────────────────────────────────
install_xray() {
    echo "正在安装 xray-core ..."
    # 优先官方安装脚本（会创建 systemd 服务）
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if bash -c "curl -fsSL $XRAY_INSTALL_URL | bash -s -- install" 2>/dev/null; then
            [[ -f "$XRAY_BINARY" ]] && { ok "xray-core 安装完成"; return; }
        fi
    fi
    info "使用手动安装方式"
    local arch; arch=$(get_arch)
    local tmp="/tmp/xray-install-$$"
    mkdir -p "$tmp"
    curl -fsSL -o "$tmp/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" || die "下载 xray 失败"
    command -v unzip &>/dev/null || {
        command -v apk &>/dev/null && apk add --no-cache unzip
        command -v apt-get &>/dev/null && apt-get install -y -qq unzip
    }
    unzip -o "$tmp/xray.zip" xray -d /usr/local/bin/ || die "解压失败"
    chmod +x "$XRAY_BINARY"
    rm -rf "$tmp"
    ok "xray-core 安装完成"
}

# ── 安装 cloudflared ──────────────────────────────────
install_cloudflared() {
    echo "正在安装 cloudflared ..."
    local arch; arch=$(get_arch)
    curl -fsSL -o "$CLOUDFLARED_BINARY" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" || die "下载 cloudflared 失败"
    chmod +x "$CLOUDFLARED_BINARY"
    ok "cloudflared 安装完成"
}

# ── CF API ────────────────────────────────────────────
cf_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    local r
    r=$(curl "${args[@]}" "${CF_API}${endpoint}" 2>/dev/null || true)
    if ! echo "$r" | jq -e '.success == true' &>/dev/null; then
        die "CF API 错误 [$method $endpoint]: $(echo "$r" | jq -c '.errors // empty')"
    fi
    echo "$r"
}

# ── CF 凭据 ───────────────────────────────────────────
CF_EMAIL="" CF_KEY="" CF_ACCOUNT_ID=""

load_cf_account() {
    [[ -f "$CF_ACCOUNT_PATH" ]] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
    CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
    CF_ACCOUNT_ID=$(jq -r '.account_id // ""' "$CF_ACCOUNT_PATH")
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]
}

save_cf_account() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" --arg a "$CF_ACCOUNT_ID" \
        '{email:$e,api_key:$k,account_id:$a}' > "$CF_ACCOUNT_PATH"
    chmod 600 "$CF_ACCOUNT_PATH"
}

cf_verify_credentials() {
    local r
    r=$(curl -s -X GET "${CF_API}/zones?per_page=1" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    echo "$r" | jq -e '.success == true' &>/dev/null
}

prompt_cf() {
    if load_cf_account; then
        local masked="${CF_KEY:0:6}...${CF_KEY: -4}"
        read -rp "复用已保存 CF 凭据 ($CF_EMAIL, Key=$masked)? (Y/n): " ans
        if [[ "${ans,,}" =~ ^(|y|yes)$ ]] && cf_verify_credentials; then
            return 0
        fi
    fi
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL || die "输入已中断"
        read -rsp "Cloudflare Global API Key: " CF_KEY || die "输入已中断"; echo
        [[ -z "$CF_EMAIL" || -z "$CF_KEY" ]] && { echo "不能为空，请重试"; continue; }
        echo -n "校验凭据... "
        if cf_verify_credentials; then
            echo "通过"
            save_cf_account
            return 0
        fi
        echo "失败，请重新输入（Ctrl+C 退出）"
    done
}

# ── Zone ──────────────────────────────────────────────
cf_find_zone() {
    local domain="$1" zones best_name="" best_id="" acct=""
    zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[] | "\(.name) \(.id) \(.account.id)"')
    while IFS=' ' read -r zone_name zone_id acct_id; do
        if [[ "$domain" == "$zone_name" || "$domain" == *".$zone_name" ]]; then
            if [[ ${#zone_name} -gt ${#best_name} ]]; then
                best_name="$zone_name"; best_id="$zone_id"; acct="$acct_id"
            fi
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] || return 1
    CF_ACCOUNT_ID="$acct"
    echo "$best_id"
}

# ── Tunnel ────────────────────────────────────────────
cf_create_tunnel() {
    cf_call POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
        "$(jq -n --arg n "$TUNNEL_NAME" '{name:$n, config_src:"cloudflare"}')" \
        | jq -r '.result | "\(.id) \(.token)"'
}

cf_set_ingress() {
    local tunnel_id="$1" domain="$2" port="$3"
    cf_call PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" \
        "$(jq -n --arg h "$domain" --argjson p "$port" \
          '{config:{ingress:[{hostname:$h, service:("http://127.0.0.1:" + ($p|tostring))}, {service:"http_status:404"}]}}')" >/dev/null
}

# 确保域名的 CNAME 指向隧道（CF 一般会自动创建，这里兜底）
cf_ensure_cname() {
    local zone_id="$1" domain="$2" tunnel_id="$3"
    local target="${tunnel_id}.cfargotunnel.com"
    local existing
    existing=$(cf_call GET "/zones/$zone_id/dns_records?type=CNAME&name=$domain" | jq -r '.result[0].content // empty')
    if [[ "$existing" == "$target" ]]; then
        return 0
    fi
    # 删除可能存在的旧记录
    local rid
    rid=$(cf_call GET "/zones/$zone_id/dns_records?type=CNAME&name=$domain" | jq -r '.result[0].id // empty')
    if [[ -n "$rid" ]]; then
        cf_call DELETE "/zones/$zone_id/dns_records/$rid" >/dev/null 2>&1 || true
    fi
    cf_call POST "/zones/$zone_id/dns_records" \
        "$(jq -n --arg n "$domain" --arg c "$target" '{type:"CNAME",name:$n,content:$c,proxied:false,ttl:1}')" >/dev/null
}

cf_get_tunnel_token() {
    cf_call GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$1/token" | jq -r '.result'
}

cf_delete_tunnel() {
    cf_call DELETE "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$1" >/dev/null
}

# ── xray 服务 ─────────────────────────────────────────
write_xray_systemd() {
    [[ -f /etc/systemd/system/xray.service ]] && return
    cat > /etc/systemd/system/xray.service << 'SVCEOF'
[Unit]
Description=Xray proxy server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
}

write_xray_openrc() {
    [[ -f /etc/init.d/xray ]] && return
    cat > /etc/init.d/xray << 'SVCEOF'
#!/sbin/openrc-run
name="xray"
description="Xray proxy server"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
respawn_delay=1
respawn_max=0
supervise_daemon_args="--respawn-delay 1 --respawn-max 0"
supervisor=supervise-daemon
depend() { need net; after firewall; }
SVCEOF
    chmod +x /etc/init.d/xray
}

restart_xray() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        write_xray_systemd
        systemctl restart xray
    else
        write_xray_openrc
        rc-service xray restart
    fi
}

is_active_xray() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active xray &>/dev/null
    else
        rc-service xray status &>/dev/null 2>&1
    fi
}

# ── cloudflared 服务 ──────────────────────────────────
restart_cloudflared() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart cloudflared
    else
        rc-service cloudflared restart
    fi
}

stop_cloudflared() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop cloudflared &>/dev/null 2>&1 || true
        systemctl disable cloudflared &>/dev/null 2>&1 || true
    else
        rc-service cloudflared stop &>/dev/null 2>&1 || true
        rc-update del cloudflared default &>/dev/null 2>&1 || true
    fi
}

# ── xray 配置 ─────────────────────────────────────────
gen_xray_config() {
    local uid="$1" path="$2" port="$3"
    jq -n --arg uid "$uid" --arg path "$path" --argjson port "$port" '{
        log:{loglevel:"warning"},
        inbounds:[{
            tag:"in-vless",
            listen:"127.0.0.1",
            port:$port,
            protocol:"vless",
            settings:{clients:[{id:$uid,flow:""}],decryption:"none"},
            streamSettings:{network:"ws", security:"none", wsSettings:{path:$path}},
            sniffing:{enabled:true, destOverride:["http","tls"]}
        }],
        outbounds:[{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}],
        routing:{domainStrategy:"AsIs",rules:[{type:"field",outboundTag:"block",protocol:["bittorrent"]}]}
    }'
}

# ── 节点链接 ─────────────────────────────────────────
build_link() {
    local uid="$1" domain="$2" path="$3"
    echo "vless://${uid}@${domain}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=$(urlencode "$path")#VLESS"
}

# ── 状态 ──────────────────────────────────────────────
load_state() { [[ -f "$STATE_PATH" ]] && cat "$STATE_PATH"; }
save_state() { mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"; echo "$1" > "$STATE_PATH"; chmod 600 "$STATE_PATH"; }

save_links_snapshot() {
    local domain="$1" uid="$2" link="$3"
    { echo "域名: $domain"; echo "UUID: $uid"; echo; echo "vless $link"; } > "$LAST_LINKS_PATH"
    chmod 600 "$LAST_LINKS_PATH"
}

print_link() {
    local link="$1"
    echo "  VLESS节点 $link"
}

# ── 1. 安装 ──────────────────────────────────────────
do_install() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && die "检测到上次配置($(echo "$state" | jq -r '.domain // "?"'))，请先卸载"

    [[ -f "$XRAY_BINARY" ]] && ok "xray-core 已安装" || install_xray

    prompt_cf

    local domain zone_id
    while true; do
        read -rp "绑定域名: " domain || die "输入已中断"
        [[ -z "$domain" ]] && { echo "域名不能为空，请重试"; continue; }
        if zone_id=$(cf_find_zone "$domain"); then
            info "匹配到 Zone: $zone_id"
            break
        fi
        echo "无法在该 CF 账号下匹配 Zone: $domain，请确认域名已托管（Ctrl+C 退出）"
    done
    save_cf_account

    local uid; uid=$(gen_uuid)
    local short_id="${uid:0:8}"
    local path="/${short_id}-vl"
    local port; port=$(( RANDOM % 50000 + 10000 ))

    echo
    echo "配置预览:"
    echo "  域名:  $domain"
    echo "  UUID:  $uid"
    echo "  隧道:  $TUNNEL_NAME"
    echo "  端口:  $port (xray 本地监听)"
    echo "  路径:  $path"
    echo
    read -rp "确认部署? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    # 1) 创建隧道
    info "创建 Cloudflare Tunnel ..."
    local tr tunnel_id token
    tr=$(cf_create_tunnel)
    tunnel_id=$(echo "$tr" | awk '{print $1}')
    token=$(echo "$tr" | awk '{print $2}')
    [[ -n "$tunnel_id" && -n "$token" ]] || die "创建隧道失败"
    ok "隧道已创建: $tunnel_id"

    # 2) 配置入口 + CNAME
    info "配置隧道入口 ..."
    cf_set_ingress "$tunnel_id" "$domain" "$port"
    cf_ensure_cname "$zone_id" "$domain" "$tunnel_id"
    ok "入口已配置: $domain -> http://127.0.0.1:$port"

    # 3) xray
    info "配置 xray ..."
    mkdir -p "$XRAY_CONFIG_DIR"
    gen_xray_config "$uid" "$path" "$port" > "$XRAY_CONFIG_PATH"
    chmod 644 "$XRAY_CONFIG_PATH"
    restart_xray
    ok "xray 已启动"

    # 4) cloudflared 服务
    info "安装 cloudflared 服务 ..."
    install_cloudflared
    "$CLOUDFLARED_BINARY" service install "$token"
    restart_cloudflared
    ok "cloudflared 已启动"

    # 5) 节点链接
    local link; link=$(build_link "$uid" "$domain" "$path")
    save_links_snapshot "$domain" "$uid" "$link"
    save_state "$(jq -n --arg d "$domain" --arg z "$zone_id" --arg u "$uid" --arg tid "$tunnel_id" --argjson p "$port" --arg pa "$path" --arg l "$link" \
        '{domain:$d,zone_id:$z,uuid:$u,tunnel_id:$tid,port:$p,path:$pa,link:$l}')"

    echo
    ok "部署完成"
    print_link "$link"
    echo
    echo "节点链接已保存到 $LAST_LINKS_PATH"
    echo
    info "提示: 首次连接稍等 10-30 秒让隧道建立"
}

# ── 2. 卸载 ──────────────────────────────────────────
do_uninstall() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到上次配置"

    local domain tunnel_id; domain=$(echo "$state" | jq -r '.domain')
    tunnel_id=$(echo "$state" | jq -r '.tunnel_id // ""')
    echo "正在卸载: $domain"

    # cloudflared
    if command -v cloudflared &>/dev/null; then
        cloudflared service uninstall &>/dev/null 2>&1 || true
        stop_cloudflared
        ok "cloudflared 已停止并卸载服务"
    fi

    # xray
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop xray &>/dev/null 2>&1 || true
        systemctl disable xray &>/dev/null 2>&1 || true
    else
        rc-service xray stop &>/dev/null 2>&1 || true
        rc-update del xray default &>/dev/null 2>&1 || true
    fi
    rm -f "$XRAY_CONFIG_PATH"
    ok "xray 已停止"

    # 删除隧道 + DNS
    if load_cf_account && [[ -n "$tunnel_id" ]]; then
        cf_delete_tunnel "$tunnel_id" && ok "隧道已删除: $tunnel_id"
        local zone_id; zone_id=$(echo "$state" | jq -r '.zone_id // ""')
        if [[ -n "$zone_id" ]]; then
            local rid
            rid=$(cf_call GET "/zones/$zone_id/dns_records?type=CNAME&name=$domain" | jq -r '.result[0].id // empty')
            [[ -n "$rid" ]] && cf_call DELETE "/zones/$zone_id/dns_records/$rid" >/dev/null && ok "DNS CNAME 已删除"
        fi
    else
        echo "无 CF 凭据，跳过隧道删除"
    fi

    rm -f "$STATE_PATH" "$CF_ACCOUNT_PATH" "$LAST_LINKS_PATH"
    ok "卸载完成"
}

# ── 3. 查看节点 ──────────────────────────────────────
do_show() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then cat "$LAST_LINKS_PATH"; return; fi
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "无历史节点"
    echo "域名: $(echo "$state" | jq -r '.domain')"
    echo "UUID: $(echo "$state" | jq -r '.uuid')"
    print_link "$(echo "$state" | jq -r '.link')"
}

# ── 4. 修改配置 ──────────────────────────────────────
do_modify() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain uid port path tunnel_id
    domain=$(echo "$state" | jq -r '.domain')
    uid=$(echo "$state" | jq -r '.uuid')
    port=$(echo "$state" | jq -r '.port')
    path=$(echo "$state" | jq -r '.path')
    tunnel_id=$(echo "$state" | jq -r '.tunnel_id')

    echo
    echo "当前配置:"
    echo "  域名: $domain"
    echo "  UUID: $uid"
    echo "  端口: $port"
    echo "  路径: $path"
    echo
    echo "  1. 修改 UUID"
    echo "  2. 修改端口"
    echo "  3. 修改 WS 路径"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-3]: " mc
    [[ "$mc" =~ ^[0-3]$ ]] || die "无效选项"
    [[ "$mc" == "0" ]] && return

    local changed=false
    if [[ "$mc" == "1" ]]; then
        read -rp "新 UUID(留空=重新生成): " iu
        if [[ -n "$iu" ]]; then
            [[ "$iu" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
            uid="${iu,,}"
        else
            uid=$(gen_uuid)
        fi
        changed=true
    fi
    if [[ "$mc" == "2" ]]; then
        read -rp "新端口(当前=$port): " np
        [[ -n "$np" ]] && [[ "$np" =~ ^[0-9]+$ ]] || die "无效端口"
        port="$np"
        changed=true
    fi
    if [[ "$mc" == "3" ]]; then
        read -rp "新 WS 路径前缀(当前=$path): " npath
        [[ -n "$npath" ]] || die "不能为空"
        [[ "$npath" == /* ]] || npath="/${npath}"
        path="${npath}-vl"
        changed=true
    fi
    [[ "$changed" == "true" ]] || { echo "无修改"; return; }

    # xray
    gen_xray_config "$uid" "$path" "$port" > "$XRAY_CONFIG_PATH"
    restart_xray
    ok "xray 已重启"

    # 隧道入口（端口可能变了）
    if load_cf_account; then
        cf_set_ingress "$tunnel_id" "$domain" "$port"
        ok "隧道入口已更新"
    fi

    local link; link=$(build_link "$uid" "$domain" "$path")
    save_links_snapshot "$domain" "$uid" "$link"
    save_state "$(jq -n --arg d "$domain" --arg z "$(echo "$state" | jq -r '.zone_id')" --arg u "$uid" --arg tid "$tunnel_id" --argjson p "$port" --arg pa "$path" --arg l "$link" \
        '{domain:$d,zone_id:$z,uuid:$u,tunnel_id:$tid,port:$p,path:$pa,link:$l}')"

    echo
    ok "配置已更新"
    print_link "$link"
}

# ── 5. 重启 ──────────────────────────────────────────
do_restart() {
    restart_xray
    ok "xray 已重启"
    restart_cloudflared
    ok "cloudflared 已重启"
}

# ── 6. 隧道状态 ──────────────────────────────────────
do_status() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    echo
    echo "域名: $(echo "$state" | jq -r '.domain')"
    echo "UUID: $(echo "$state" | jq -r '.uuid')"
    echo "隧道: $(echo "$state" | jq -r '.tunnel_id')"
    echo
    echo -n "xray:       "; is_active_xray && echo "运行中" || echo "未运行"
    echo -n "cloudflared: "; if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active cloudflared &>/dev/null && echo "运行中" || echo "未运行"; else rc-service cloudflared status &>/dev/null 2>&1 && echo "运行中" || echo "未运行"; fi
    echo
    print_link "$(echo "$state" | jq -r '.link')"
}

# ── 主入口 ────────────────────────────────────────────
ensure_shortcut() {
    local target="/usr/local/bin/xt"
    local content='#!/bin/sh
exec bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/xray_cf_tunnel.sh) "$@"
'
    if [[ -f "$target" ]] && grep -q "xray_cf_tunnel.sh" "$target"; then
        return
    fi
    printf '%s' "$content" > "$target"
    chmod +x "$target"
    ok "快捷命令 xt 已注册"
}

main() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行此脚本"
    detect_init
    install_deps
    need_cmd() { command -v "$1" &>/dev/null || die "缺少依赖: $1"; }
    need_cmd curl; need_cmd jq
    ensure_shortcut

    local state current_domain=""
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && current_domain=$(echo "$state" | jq -r '.domain // ""')

    echo
    echo "  xray-cf-tunnel ($INIT_SYSTEM)"
    echo
    echo "  1. 安装节点"
    echo "  2. 卸载"
    echo "  3. 查看节点"
    echo "  4. 修改配置(UUID/端口/路径)"
    echo "  5. 重启服务"
    echo "  6. 查看状态"
    [[ -n "$current_domain" ]] && echo "     (当前: $current_domain)"
    echo

    read -rp "请选择 [1-6]: " choice
    case "$choice" in
        1) do_install ;; 2) do_uninstall ;; 3) do_show ;;
        4) do_modify ;; 5) do_restart ;; 6) do_status ;;
        *) die "无效选项: $choice" ;;
    esac
}

main "$@"
