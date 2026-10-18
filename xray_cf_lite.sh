#!/usr/bin/env bash
set -euo pipefail

# ── 常量 ──────────────────────────────────────────────
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_PATH="$XRAY_CONFIG_DIR/config.json"
XRAY_BINARY="/usr/local/bin/xray"
STATE_DIR="/etc/xray-cf-lite"
STATE_PATH="$STATE_DIR/state.json"
CF_ACCOUNT_PATH="$STATE_DIR/cf_account.json"
ORIGIN_CERT_PATH="$STATE_DIR/origin.pem"
ORIGIN_KEY_PATH="$STATE_DIR/origin.key"
ORIGIN_CSR_PATH="$STATE_DIR/origin.csr"
LAST_LINKS_PATH="$(pwd)/cf_lite_last_links.txt"

CF_API="https://api.cloudflare.com/client/v4"
MANAGED_PREFIX="xray-cf-lite "
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
PREFERRED_SUB_BASE="https://sub.eooce.xx.kg"

declare -A PROTO_SUFFIX=([vless]="vl")
declare -A PROTO_LABEL=([vless]="VLESS")

# ── 工具 ──────────────────────────────────────────────
die()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# 状态提示一律走 stderr：有些函数用 stdout 返回 JSON（如 cf_relax_security），
# 提示混进去会让调用方的 $(...) 拿到「提示+JSON」，jq --argjson 直接解析失败。
ok()      { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
info()    { printf '\033[36m·\033[0m %s\n' "$*" >&2; }
need_cmd(){ command -v "$1" &>/dev/null || die "缺少依赖: $1"; }


urlencode() {
    local s="$1" c
    local -i i
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
    command -v unzip   &>/dev/null || missing+=(unzip)
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
        die "无法安装依赖 ${missing[*]}，请手动安装"
    fi
}

# ── xray 服务管理 ────────────────────────────────────
XRAY_OPENRC_SCRIPT="/etc/init.d/xray"

write_openrc_script() {
    cat > "$XRAY_OPENRC_SCRIPT" << 'INITEOF'
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
respawn_period=86400
supervise_daemon_args="--respawn-delay ${respawn_delay} --respawn-max ${respawn_max} --respawn-period ${respawn_period}"
supervisor=supervise-daemon
depend() { need net; after firewall; }
INITEOF
    chmod +x "$XRAY_OPENRC_SCRIPT"
}

svc_enable()    { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl enable xray &>/dev/null; else rc-update add xray default &>/dev/null; fi; true; }
svc_start()     { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart xray; else [[ -f "$XRAY_OPENRC_SCRIPT" ]] || write_openrc_script; rc-service xray restart; fi; }
svc_stop()      { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl stop xray &>/dev/null; systemctl disable xray &>/dev/null; else rc-service xray stop &>/dev/null; rc-update del xray default &>/dev/null; fi; true; }
svc_is_active() { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active xray &>/dev/null; else rc-service xray status &>/dev/null 2>&1; fi; }

ensure_systemd_restart() {
    # 确保 systemd 下 xray 崩溃自动重启
    local drop="/etc/systemd/system/xray.service.d"
    if [[ "$INIT_SYSTEM" == "systemd" && ! -f "$drop/restart.conf" ]]; then
        mkdir -p "$drop"
        cat > "$drop/restart.conf" << 'SDEOF'
[Service]
Restart=on-failure
RestartSec=1
SDEOF
        systemctl daemon-reload
    fi
}

restart_xray() {
    [[ "$INIT_SYSTEM" == "systemd" ]] && ensure_systemd_restart
    svc_enable
    svc_start || die "xray 重启失败"
    sleep 1
    svc_is_active || die "xray 未正常启动，请查看日志"
    ok "xray 服务已启动"
}

stop_xray() { svc_stop; }

# ── 网络检测 ─────────────────────────────────────────
get_public_ip() {
    local ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -sf --max-time 8 "$url" 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    done
    die "获取公网 IPv4 失败"
}

# detect_nat 猜测本机是直连公网还是在 NAT 后面。
#
# 只看「公网 IP 有没有绑在网卡上」会误判：云厂商（AWS/GCP/阿里云等）常用一对一 NAT，
# 网卡上是内网地址，但公网端口其实直达。这类机器判成 NAT 会逼用户去填并不存在的端口映射。
# 所以这里只作为默认建议，最终由用户确认（见 prompt_net_mode）。
detect_nat() {
    local public_ip
    public_ip=$(get_public_ip)
    if ip addr show 2>/dev/null | grep -qE "inet ${public_ip}/"; then
        echo "direct"
        return
    fi
    echo "nat"
}

# prompt_net_mode 拿探测结果当默认值，让用户可以改。
#
# 探测不可能百分百准，判错了又没法改的话，装出来的配置就是错的（issue #1）。
net_mode_label() {
    [[ "$1" == "direct" ]] && echo "直连（公网端口直达本机）" || echo "NAT（需要端口映射）"
}

prompt_net_mode() {
    local detected="$1" ans
    echo >&2
    info "网络环境探测结果: $(net_mode_label "$detected")" >&2
    if [[ "$detected" == "nat" ]]; then
        echo "  如果这台机器有独立公网 IP、外部能直接连到你要开的端口（常见于云厂商的一对一 NAT）," >&2
        echo "  这里就该选直连，否则会让你填一堆并不存在的端口映射。" >&2
    else
        echo "  如果这台机器其实在 NAT/软路由后面，对外端口和本机监听端口不一致，这里要选 NAT。" >&2
    fi
    read -rp "使用哪种模式? (1=直连, 2=NAT, 回车=用探测结果): " ans
    case "$ans" in
        1) echo "direct" ;;
        2) echo "nat" ;;
        "") echo "$detected" ;;
        *) die "无效选项: $ans" ;;
    esac
}

get_listening_ports() {
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' '
}

rand_port() {
    local existing="$1" p
    while true; do
        p=$(( RANDOM % 50000 + 10000 ))
        echo "$existing" | grep -qw "$p" || { echo "$p"; return; }
    done
}

# ── CF API ────────────────────────────────────────────
cf_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -f -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

cf_call_raw() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

# ── CF 凭据 ───────────────────────────────────────────
CF_EMAIL="" CF_KEY=""

load_cf_account() {
    [[ -f "$CF_ACCOUNT_PATH" ]] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
    CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]
}

save_cf_account() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" '{email:$e,api_key:$k}' > "$CF_ACCOUNT_PATH"
    chmod 600 "$CF_ACCOUNT_PATH"
}

# 验证 CF 凭据是否有效（用 verify 接口，避免拿到无效 key 继续跑）
cf_verify_credentials() {
    local r
    r=$(curl -s -X GET "${CF_API}/user/tokens/verify" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    # Global API Key 在 tokens/verify 上可能不适用，回退到列 zones 验证
    if echo "$r" | jq -e '.success == true' &>/dev/null; then
        return 0
    fi
    r=$(curl -s -X GET "${CF_API}/zones?per_page=1" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    echo "$r" | jq -e '.success == true' &>/dev/null
}

prompt_cf() {
    # 先尝试复用已保存凭据
    if load_cf_account; then
        local masked="${CF_KEY:0:6}...${CF_KEY: -4}"
        read -rp "复用已保存 CF 凭据 ($CF_EMAIL, Key=$masked)? (Y/n): " ans
        if [[ "${ans,,}" =~ ^(|y|yes)$ ]]; then
            if cf_verify_credentials; then
                return 0
            fi
            echo "已保存的 CF 凭据校验失败，请重新输入"
        fi
    fi
    # 循环让用户输入直到校验通过
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL || die "输入已中断"
        read -rsp "Cloudflare Global API Key: " CF_KEY || die "输入已中断"; echo
        if [[ -z "$CF_EMAIL" || -z "$CF_KEY" ]]; then
            echo "邮箱和 API Key 不能为空，请重试"
            continue
        fi
        echo -n "校验凭据... "
        if cf_verify_credentials; then
            echo "通过"
            save_cf_account
            return 0
        fi
        echo "失败：邮箱或 API Key 错误，请重新输入（Ctrl+C 退出）"
    done
}

# ── CF DNS / SSL / Origin Rules ───────────────────────
cf_find_zone() {
    local domain="$1" zones best_name="" best_id=""
    zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[] | "\(.name) \(.id)"')
    while IFS=' ' read -r zone_name zone_id; do
        if [[ "$domain" == "$zone_name" || "$domain" == *".$zone_name" ]]; then
            [[ ${#zone_name} -gt ${#best_name} ]] && best_name="$zone_name" && best_id="$zone_id"
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] || return 1
    echo "$best_id"
}

cf_get_dns() {
    cf_call GET "/zones/$1/dns_records?type=A&name=$2" | jq '.result[0] // empty'
}

cf_upsert_dns() {
    local zone_id="$1" domain="$2" ip="$3"
    local payload existing
    payload=$(jq -n --arg n "$domain" --arg c "$ip" '{type:"A",name:$n,content:$c,proxied:true,ttl:1}')
    existing=$(cf_get_dns "$zone_id" "$domain")
    if [[ -n "$existing" ]]; then
        local rid; rid=$(echo "$existing" | jq -r '.id')
        cf_call PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" | jq -r '.result.id'
    else
        cf_call POST "/zones/${zone_id}/dns_records" "$payload" | jq -r '.result.id'
    fi
}

cf_get_ssl()  { cf_call GET "/zones/$1/settings/ssl" | jq -r '.result.value'; }
cf_set_ssl()  { cf_call PATCH "/zones/$1/settings/ssl" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

# ── CF 安全规则 ───────────────────────────────────────
cf_get_security_level() { cf_call GET "/zones/$1/settings/security_level" | jq -r '.result.value'; }
cf_set_security_level() { cf_call PATCH "/zones/$1/settings/security_level" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

cf_get_browser_check() { cf_call GET "/zones/$1/settings/browser_check" | jq -r '.result.value'; }
cf_set_browser_check() { cf_call PATCH "/zones/$1/settings/browser_check" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

cf_get_bot_management() { cf_call_raw GET "/zones/$1/bot_management" | jq '.result // {}'; }

cf_set_bot_fight_off() {
    local zone_id="$1"
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$(jq -n '{
        enable_js: false,
        sbfm_likely_automated: "allow",
        sbfm_definitely_automated: "allow",
        sbfm_verified_bots: "allow",
        sbfm_static_resource_protection: false
    }')" | jq -e '.success' &>/dev/null
}

cf_restore_bot_management() {
    local zone_id="$1" backup="$2"
    # 只恢复我们改过的字段
    local payload
    payload=$(echo "$backup" | jq '{
        enable_js: .enable_js,
        sbfm_likely_automated: .sbfm_likely_automated,
        sbfm_definitely_automated: .sbfm_definitely_automated,
        sbfm_verified_bots: .sbfm_verified_bots,
        sbfm_static_resource_protection: .sbfm_static_resource_protection
    }')
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$payload" | jq -e '.success' &>/dev/null
}

# 安装时：备份安全设置 -> 关闭拦截
cf_relax_security() {
    local zone_id="$1"
    local sec_level bot_mgmt browser_check

    sec_level=$(cf_get_security_level "$zone_id")
    browser_check=$(cf_get_browser_check "$zone_id")
    bot_mgmt=$(cf_get_bot_management "$zone_id")

    # 降低 security level
    if [[ "$sec_level" != "essentially_off" ]]; then
        cf_set_security_level "$zone_id" "essentially_off"
        ok "Security Level: essentially_off"
    fi

    # 关闭 Browser Integrity Check
    if [[ "$browser_check" != "off" ]]; then
        cf_set_browser_check "$zone_id" "off"
        ok "Browser Check: off"
    fi

    # 关闭 Bot Fight Mode
    local sbfm_likely
    sbfm_likely=$(echo "$bot_mgmt" | jq -r '.sbfm_likely_automated // ""')
    if [[ "$sbfm_likely" != "allow" ]]; then
        cf_set_bot_fight_off "$zone_id"
        ok "Bot Fight Mode: 已关闭"
    fi

    # 返回备份 JSON
    jq -n --arg sl "$sec_level" --arg bc "$browser_check" --argjson bm "$bot_mgmt"         '{security_level:$sl, browser_check:$bc, bot_management:$bm}'
}

# 卸载时：恢复安全设置
cf_restore_security() {
    local zone_id="$1" backup="$2"
    [[ -z "$backup" || "$backup" == "null" ]] && return

    local sl bc bm
    sl=$(echo "$backup" | jq -r '.security_level // ""')
    bc=$(echo "$backup" | jq -r '.browser_check // ""')
    bm=$(echo "$backup" | jq '.bot_management // null')

    [[ -n "$sl" ]] && cf_set_security_level "$zone_id" "$sl" && ok "Security Level 已恢复: $sl"
    [[ -n "$bc" ]] && cf_set_browser_check "$zone_id" "$bc" && ok "Browser Check 已恢复: $bc"
    [[ "$bm" != "null" ]] && cf_restore_bot_management "$zone_id" "$bm" && ok "Bot Fight Mode 已恢复"
}

cf_get_origin_rules() {
    local r; r=$(cf_call_raw GET "/zones/$1/rulesets/phases/http_request_origin/entrypoint")
    echo "$r" | jq -r 'if .success then .result.rules // [] else [] end' 2>/dev/null || echo '[]'
}

cf_put_origin_rules() {
    local r; r=$(cf_call_raw PUT "/zones/$1/rulesets/phases/http_request_origin/entrypoint" \
        "$(jq -n --argjson r "$2" '{rules:$r}')")
    echo "$r" | jq -e '.success' &>/dev/null || die "Origin Rules 写入失败: $(echo "$r" | jq -c '.errors')"
}

# cf_port = 外部端口（CF Origin Rules 转发的目标端口）
build_new_origin_rules() {
    local domain="$1" routes_json="$2"
    echo "$routes_json" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | {
            description: ($pfx + .protocol + " " + .path),
            enabled: true,
            expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + .path + "\")"),
            action: "route",
            action_parameters: { origin: { port: .cf_port } }
        }
    ]'
}

apply_origin_rules() {
    local zone_id="$1" domain="$2" routes_json="$3"
    local existing kept new_managed merged
    existing=$(cf_get_origin_rules "$zone_id")
    kept=$(echo "$existing" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | select(
            (.description | startswith($pfx) | not) or
            (.expression | ascii_downcase | contains("http.host eq \"" + ($d|ascii_downcase) + "\"") | not)
        )
    ]')
    new_managed=$(build_new_origin_rules "$domain" "$routes_json")
    merged=$(jq -n --argjson a "$kept" --argjson b "$new_managed" '$a + $b')
    cf_put_origin_rules "$zone_id" "$merged"
}

# ── CF Origin 证书（Full Strict 用）──────────────────
# 生成 key + CSR，调 CF API 签发 Origin 证书并保存到 STATE_DIR。
# 证书由 CF 信任、有效期 15 年，无需续期；CF SSL 设 strict 时启用。
cf_setup_origin_cert() {
    local zone_id="$1" domain="$2"
    info "生成 Origin 证书（Full Strict）..."
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$ORIGIN_KEY_PATH" \
        -out "$ORIGIN_CSR_PATH" \
        -subj "/CN=${domain}" 2>/dev/null \
        || die "生成 CSR 失败"

    local csr_pem payload r cert
    csr_pem=$(cat "$ORIGIN_CSR_PATH")
    payload=$(jq -n --arg csr "$csr_pem" --arg d "$domain" \
        '{csr:$csr, hostnames:[$d], request_type:"origin-rsa", requested_validity:5475}')
    r=$(cf_call_raw POST "/certificates" "$payload")
    cert=$(echo "$r" | jq -r '.result.certificate // empty')
    [[ -n "$cert" ]] || die "创建 Origin 证书失败: $(echo "$r" | jq -c '.errors // empty')"

    echo "$cert" > "$ORIGIN_CERT_PATH"
    chmod 600 "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH"
    rm -f "$ORIGIN_CSR_PATH"
    ok "Origin 证书已保存: $ORIGIN_CERT_PATH"
}

# ── xray 安装 ─────────────────────────────────────────
install_xray() {
    echo "正在安装 xray-core ..."

    # 优先尝试官方安装脚本（需要 systemd）
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if bash -c "curl -fsSL $XRAY_INSTALL_URL | bash -s -- install" 2>/dev/null; then
            [[ -f "$XRAY_BINARY" ]] && { ok "xray-core 安装完成"; return; }
        fi
    fi

    # 回退：手动下载二进制
    info "使用手动安装方式"
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7*)        arch="arm32-v7a" ;;
        *)             die "不支持的架构: $(uname -m)" ;;
    esac

    # 直接用 releases/latest/download 直链，不走 GitHub API（未认证 API 每 IP 每小时仅 60 次，
    # NAT 小鸡共享出口极易撞限流导致取版本号失败）。版本号仅用于日志显示，取不到不致命。
    # 末尾 || true：脚本头部 set -euo pipefail，API 不可达时 curl 非 0 会经 pipefail
    # 冒泡成命令替换失败并触发 set -e 提前退出，永远走不到下面的直链下载。
    local ver=""
    ver=$(curl -sf "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null) || true
    [[ -n "$ver" && "$ver" != "null" ]] && info "xray $ver ($arch)" || info "xray latest ($arch)"

    local tmp="/tmp/xray-install-$$"
    mkdir -p "$tmp"
    curl -fsSL -o "$tmp/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" || die "下载失败"

    command -v unzip &>/dev/null || {
        command -v apk &>/dev/null && apk add --no-cache unzip
        command -v apt-get &>/dev/null && apt-get install -y -qq unzip
    }

    unzip -o "$tmp/xray.zip" xray -d /usr/local/bin/ || die "解压失败"
    chmod +x "$XRAY_BINARY"
    rm -rf "$tmp"

    # 下载 geodata
    local geo_dir="/usr/local/share/xray"
    mkdir -p "$geo_dir"
    for f in geoip.dat geosite.dat; do
        [[ -f "$geo_dir/$f" ]] || curl -fsSL -o "$geo_dir/$f" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" 2>/dev/null || true
    done

    [[ -f "$XRAY_BINARY" ]] || die "安装后未找到 xray"
    ok "xray-core 安装完成: $($XRAY_BINARY version | head -1)"
}

# ── xray 配置生成 ─────────────────────────────────────
# 外部工具（fanout 等）注入的出站/路由统一带这个前缀，重建配置时予以保留。
EXTERNAL_TAG_PREFIX="fanout-"

# external_outbounds 从现有配置里捞出外部注入的出站。没有配置或没有匹配项时返回 []。
external_outbounds() {
    [[ -f "$XRAY_CONFIG_PATH" ]] || { echo '[]'; return; }
    jq --arg p "$EXTERNAL_TAG_PREFIX" \
        '[.outbounds // [] | .[] | select((.tag // "") | startswith($p))]' \
        "$XRAY_CONFIG_PATH" 2>/dev/null || echo '[]'
}

# external_routing_rules 捞出外部注入的分流规则，并把 inboundTag 重映射到新的入站 tag。
#
# 入站 tag 形如 in-<protocol>-<port>，改端口后 tag 会变，直接照搬旧规则会指向
# 已不存在的 inboundTag（xray 不报错，规则静默失效）。这里按协议重新匹配：
# 旧规则绑的是哪个协议，新配置里该协议的 tag 是什么，就替换成什么。
external_routing_rules() {
    local routes_json="$1"
    [[ -f "$XRAY_CONFIG_PATH" ]] || { echo '[]'; return; }

    # 协议 -> 新 tag 的映射
    local proto_map
    proto_map=$(echo "$routes_json" | jq '[.[] | {key:.protocol, value:("in-" + .protocol + "-" + (.listen_port|tostring))}] | from_entries')

    # 旧 tag -> 协议（从旧配置的 inbounds 里读，tag 可能已过时但协议是准的）
    local old_map
    old_map=$(jq '[.inbounds // [] | .[] | {key:(.tag // ""), value:(.protocol // "")}] | from_entries' \
        "$XRAY_CONFIG_PATH" 2>/dev/null) || { echo '[]'; return; }

    jq --arg p "$EXTERNAL_TAG_PREFIX" --argjson pm "$proto_map" --argjson om "$old_map" '
        [ .routing.rules // [] | .[]
          | select((.outboundTag // "") | startswith($p))
          | . as $rule
          | ( [ (.inboundTag // [])[] | $om[.] // empty | $pm[.] // empty ] | unique ) as $newtags
          | select($newtags | length > 0)
          | $rule + {inboundTag: $newtags}
        ]' "$XRAY_CONFIG_PATH" 2>/dev/null || echo '[]'
}

gen_xray_config() {
    local routes_json="$1" uid="$2" ssl_mode="${3:-flexible}"
    local security="none" tls_json="null"
    if [[ "$ssl_mode" == "strict" ]]; then
        security="tls"
        tls_json=$(jq -n --arg c "$ORIGIN_CERT_PATH" --arg k "$ORIGIN_KEY_PATH" \
            '{certificates:[{certificateFile:$c,keyFile:$k}], alpn:["http/1.1"]}')
    fi
    local inbounds
    inbounds=$(echo "$routes_json" | jq --arg uid "$uid" --arg sec "$security" --argjson tls "$tls_json" '[
        .[] | {
            tag: ("in-" + .protocol + "-" + (.listen_port|tostring)),
            listen: "0.0.0.0",
            port: .listen_port,
            protocol: .protocol,
            settings: (
                if .protocol == "vless" then {clients:[{id:$uid,flow:""}],decryption:"none"}
                elif .protocol == "trojan" then {clients:[{password:$uid}]}
                else {clients:[{id:$uid,alterId:0}]}
                end
            ),
            streamSettings: ( { network:"ws", security:$sec, wsSettings:{path:.path} }
                              + (if $tls == null then {} else {tlsSettings:$tls} end) ),
            sniffing: { enabled:true, destOverride:["http","tls"] }
        }
    ]')
    # 保留外部工具（如 fanout）注入的出站与分流规则。
    # 它们统一带 EXTERNAL_TAG_PREFIX 前缀，重新生成配置时原样带过来，
    # 否则用户在这里改个 UUID 就会把已配好的出口绑定悄悄冲掉，流量默默回到直连。
    local ext_outbounds ext_rules
    ext_outbounds=$(external_outbounds)
    ext_rules=$(external_routing_rules "$routes_json")

    jq -n --argjson inb "$inbounds" --argjson eob "$ext_outbounds" --argjson erl "$ext_rules" '{
        log:{loglevel:"warning"},
        inbounds:$inb,
        outbounds:([{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}] + $eob),
        routing:{domainStrategy:"AsIs",rules:([{type:"field",outboundTag:"block",protocol:["bittorrent"]}] + $erl)}
    }'
}

write_xray_config() {
    mkdir -p "$XRAY_CONFIG_DIR"
    echo "$1" > "$XRAY_CONFIG_PATH"
    chmod 644 "$XRAY_CONFIG_PATH"
    ok "xray 配置已写入 $XRAY_CONFIG_PATH"
}

# ── 节点链接 ─────────────────────────────────────────
build_link() {
    # 单个 VLESS 节点：直连域名（走 CF 橙云 + Origin Rules）
    local uid="$1" domain="$2" path="$4"
    echo "vless://${uid}@${domain}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=$(urlencode "$path")#VLESS"
}

gen_all_links() {
    local uid="$1" domain="$2" routes_json="$3"
    local links_json='{}'
    local proto path link
    while IFS=$'\t' read -r proto path; do
        link=$(build_link "$uid" "$domain" "$proto" "$path")
        links_json=$(echo "$links_json" | jq --arg p "$proto" --arg l "$link" '. + {($p):$l}')
    done < <(echo "$routes_json" | jq -r '.[] | [.protocol, .path] | @tsv')
    echo "$links_json"
}

# ── 状态 ──────────────────────────────────────────────
load_state() { [[ -f "$STATE_PATH" ]] && cat "$STATE_PATH"; }
save_state() { mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"; echo "$1" > "$STATE_PATH"; chmod 600 "$STATE_PATH"; }
remove_state() { rm -f "$STATE_PATH"; }

save_links_snapshot() {
    local domain="$1" uid="$2" links_json="$3"
    { echo "域名: $domain"; echo "UUID: $uid"; echo
      echo "$links_json" | jq -r 'to_entries[] | "\(.key) \(.value)"'
    } > "$LAST_LINKS_PATH"
    chmod 600 "$LAST_LINKS_PATH"
}

print_links() {
    local links_json="$1"
    local proto link
    while IFS=$'\t' read -r proto link; do
        echo "  ${PROTO_LABEL[$proto]:-$proto}节点 $link"
    done < <(echo "$links_json" | jq -r 'to_entries[] | [.key, .value] | @tsv')
}

# ── 交互辅助 ─────────────────────────────────────────
prompt_uuid() {
    local uid
    read -rp "UUID(留空=自动生成): " custom_uuid
    if [[ -n "$custom_uuid" ]]; then
        [[ "$custom_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
        uid="${custom_uuid,,}"
    else
        uid=$(gen_uuid)
    fi
    echo "$uid"
}

prompt_path_prefix() {
    local default="$1"
    read -rp "WS 路径前缀(留空=/${default}): " pfx
    [[ -z "$pfx" ]] && pfx="/${default}"
    [[ "$pfx" == /* ]] || pfx="/${pfx}"
    echo "$pfx"
}

prompt_ssl_mode() {
    echo >&2
    info "SSL 模式:" >&2
    echo "  1 = 严格 Full Strict（推荐）：源站启用 HTTPS + Origin 证书，更安全" >&2
    echo "  2 = 灵活 Flexible：源站走 HTTP，配置简单" >&2
    read -rp "选择 SSL 模式 (1=严格, 2=灵活, 回车=严格): " ans
    case "$ans" in
        2) echo "flexible" ;;
        *) echo "strict" ;;
    esac
}

# 生成路由 JSON，NAT 和直连通用
# NAT 时 xray 监听 listen_port(内部)，CF 转发到 cf_port(外部)
# 直连时 listen_port == cf_port
build_routes() {
    local net_mode="$1" path_prefix="$2" proto_count="$3"
    shift 3
    local protocols=("$@")

    local routes_json='[]'

    if [[ "$net_mode" == "nat" ]]; then
        echo >&2
        info "NAT 模式: 逐个配置每个协议的端口映射" >&2
        echo >&2

        for proto in "${protocols[@]}"; do
            local int_port ext_port
            read -rp "${proto} 内部监听端口(xray监听): " int_port
            [[ "$int_port" =~ ^[0-9]+$ ]] || die "无效端口: $int_port"
            read -rp "${proto} 外部映射端口(对外暴露): " ext_port
            [[ "$ext_port" =~ ^[0-9]+$ ]] || die "无效端口: $ext_port"
            local path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
            routes_json=$(echo "$routes_json" | jq \
                --arg p "$proto" --argjson lp "$((int_port))" --argjson cp "$((ext_port))" --arg pa "$path" \
                '. + [{protocol:$p, listen_port:$lp, cf_port:$cp, path:$pa}]')
        done
    else
        read -rp "自定义端口?(逗号分隔，留空=随机): " custom_ports_raw
        local existing_ports
        existing_ports=$(get_listening_ports)
        local custom_ports=()
        if [[ -n "$custom_ports_raw" ]]; then
            IFS=',' read -ra custom_ports <<< "$custom_ports_raw"
            [[ ${#custom_ports[@]} -eq $proto_count ]] || die "端口数量与协议数不一致"
        fi

        local pi=0
        for proto in "${protocols[@]}"; do
            local port
            if [[ ${#custom_ports[@]} -gt 0 ]]; then
                port="${custom_ports[$pi]// /}"
                [[ "$port" =~ ^[0-9]+$ ]] || die "无效端口: $port"
            else
                port=$(rand_port "$existing_ports")
            fi
            existing_ports="$existing_ports $port"
            local path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
            routes_json=$(echo "$routes_json" | jq \
                --arg p "$proto" --argjson lp "$((port))" --arg pa "$path" \
                '. + [{protocol:$p, listen_port:$lp, cf_port:$lp, path:$pa}]')
            pi=$((pi + 1))
        done
    fi

    echo "$routes_json"
}

# ── 1. 安装 ──────────────────────────────────────────
do_install() {
    local state
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && die "检测到上次配置($(echo "$state" | jq -r '.domain // "?"'))，请先卸载"

    [[ -f "$XRAY_BINARY" ]] && ok "xray-core 已安装" || install_xray

    local net_mode
    net_mode=$(prompt_net_mode "$(detect_nat)")
    ok "网络模式: $(net_mode_label "$net_mode")"

    prompt_cf

    # 输入域名并校验能匹配到 CF Zone，失败可重输
    local domain zone_id
    while true; do
        read -rp "绑定域名: " domain || die "输入已中断"
        if [[ -z "$domain" ]]; then
            echo "域名不能为空，请重试"
            continue
        fi
        if zone_id=$(cf_find_zone "$domain"); then
            info "匹配到 Zone: $zone_id"
            break
        fi
        echo "无法在该 CF 账号下匹配 Zone: $domain，请确认域名已托管并重输（Ctrl+C 退出）"
    done

    local protocols=(vless)

    local uid
    uid=$(prompt_uuid)
    local short_id="${uid:0:8}"
    local path_prefix
    path_prefix=$(prompt_path_prefix "$short_id")

    local ssl_mode
    ssl_mode=$(prompt_ssl_mode)

    local routes_json
    routes_json=$(build_routes "$net_mode" "$path_prefix" "${#protocols[@]}" "${protocols[@]}")

    # 预览
    echo
    echo "配置预览:"
    echo "  域名:  $domain"
    echo "  UUID:  $uid"
    echo "  模式:  $net_mode"
    echo "  SSL:   $ssl_mode"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    read -rp "确认部署? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    # xray
    local config
    if [[ "$ssl_mode" == "strict" ]]; then
        cf_setup_origin_cert "$zone_id" "$domain"
    fi
    config=$(gen_xray_config "$routes_json" "$uid" "$ssl_mode")
    write_xray_config "$config"
    [[ "$INIT_SYSTEM" == "openrc" && ! -f "$XRAY_OPENRC_SCRIPT" ]] && write_openrc_script && ok "OpenRC 服务脚本已创建"
    restart_xray

    # CF
    local public_ip dns_before ssl_before origin_rules_before dns_record_id
    public_ip=$(get_public_ip)
    dns_before=$(cf_get_dns "$zone_id" "$domain" || echo "null")
    [[ "$dns_before" == "" ]] && dns_before="null"
    ssl_before=$(cf_get_ssl "$zone_id")
    origin_rules_before=$(cf_get_origin_rules "$zone_id")

    dns_record_id=$(cf_upsert_dns "$zone_id" "$domain" "$public_ip")
    ok "DNS A 记录: $domain -> $public_ip (已代理)"
    cf_set_ssl "$zone_id" "$ssl_mode"
    ok "SSL 模式: $ssl_mode"
    apply_origin_rules "$zone_id" "$domain" "$routes_json"
    ok "Origin Rules: ${#protocols[@]} 条"

    # 安全规则：关闭可能拦截 WS 的设置
    local security_backup
    security_backup=$(cf_relax_security "$zone_id")

    # 节点链接
    local links_json
    links_json=$(gen_all_links "$uid" "$domain" "$routes_json")
    save_links_snapshot "$domain" "$uid" "$links_json"

    # 状态
    local dns_existed="false"
    [[ "$dns_before" != "null" ]] && dns_existed="true"
    # jq --argjson 遇到空串会整体失败，导致 state.json 存不下来（存不下就没法改配置/卸载）。
    # CF 接口任何一个返回空都不该拖垮状态保存，这里统一兜底成合法 JSON。
    [[ -n "$dns_before" ]]          || dns_before="null"
    [[ -n "$origin_rules_before" ]] || origin_rules_before="[]"
    [[ -n "$security_backup" ]]     || security_backup="null"
    [[ -n "$links_json" ]]          || links_json="{}"
    [[ -n "$routes_json" ]]         || routes_json="[]"
    save_state "$(jq -n \
        --arg d "$domain" --arg z "$zone_id" --arg u "$uid" --arg s "$short_id" --arg mode "$net_mode" \
        --arg sslmode "$ssl_mode" \
        --argjson routes "$routes_json" \
        --arg drid "$dns_record_id" --argjson dex "$dns_existed" --argjson drec "$dns_before" \
        --arg ssl "$ssl_before" --argjson orbk "$origin_rules_before" --argjson links "$links_json" \
        --argjson secbk "$security_backup" \
        '{domain:$d,zone_id:$z,uuid:$u,short_id:$s,net_mode:$mode,ssl_mode:$sslmode,routes:$routes,
          managed_dns_record_id:$drid,dns_backup:{existed:$dex,record:$drec},
          ssl_backup:$ssl,origin_rules_backup:$orbk,security_backup:$secbk,links:$links}')"

    echo
    ok "部署完成"
    print_links "$links_json"
    echo
    echo "节点链接已保存到 $LAST_LINKS_PATH"
}

# ── 删除节点核心清理（删除节点 / 卸载脚本 共用）──────
# 注意：不改动 SSL 模式；DNS 记录只精确删除本节点域名的解析
_delete_node_core() {
    local state="$1"
    local domain zone_id rids rid sec_bk

    domain=$(echo "$state" | jq -r '.domain // ""')

    stop_xray
    rm -f "$XRAY_CONFIG_PATH"
    ok "xray 已停止"

    if ! load_cf_account; then
        info "无 CF 凭据，跳过云端清理"
        return 0
    fi

    zone_id=$(echo "$state" | jq -r '.zone_id // ""')
    if [[ -z "$zone_id" ]]; then
        info "state 中无 zone_id，跳过云端清理"
        return 0
    fi

    # 恢复 Origin Rules 备份
    cf_put_origin_rules "$zone_id" "$(echo "$state" | jq '.origin_rules_backup // []')"
    ok "Origin Rules 已恢复"

    # 恢复安全规则（Bot Fight / Security Level / Browser Check），不动 SSL 模式
    sec_bk=$(echo "$state" | jq '.security_backup // null')
    cf_restore_security "$zone_id" "$sec_bk"

    # DNS：精确匹配本节点域名（二级域名），同名记录（CNAME/A 等）全部删除
    rids=$(cf_call_raw GET "/zones/${zone_id}/dns_records?name=${domain}" 2>/dev/null | jq -r '.result[]?.id // empty' || true)
    if [[ -n "$rids" ]]; then
        while IFS= read -r rid; do
            [[ -n "$rid" ]] || continue
            cf_call_raw DELETE "/zones/${zone_id}/dns_records/${rid}" >/dev/null 2>&1 || true
        done <<< "$rids"
        ok "DNS 解析已删除: $domain"
    else
        info "未找到 $domain 的 DNS 记录"
    fi
}

# ── 2. 删除节点 ──────────────────────────────────────
do_delete_node() {
    local state
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到已部署节点"

    local domain; domain=$(echo "$state" | jq -r '.domain')
    echo "正在删除节点: $domain"

    _delete_node_core "$state"

    remove_state
    rm -f "$LAST_LINKS_PATH" "$CF_ACCOUNT_PATH" "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH" "$ORIGIN_CSR_PATH"
    ok "已清理节点快照与 CF 凭据"
    ok "节点已删除 (SSL 模式未改动)"
}

# ── 0. 卸载脚本 ──────────────────────────────────────
# 自动读取节点 -> 删除节点 -> 停止服务 -> 删除本地脚本文件
do_uninstall_script() {
    local state
    state=$(load_state 2>/dev/null || true)

    echo
    read -rp "$(printf '\033[31m确定卸载脚本? 将自动删除已部署节点并自删脚本文件 (y/N): \033[0m')" confirm
    [[ "${confirm,,}" =~ ^y(es)?$ ]] || { info "已取消"; return 0; }

    if [[ -n "$state" ]]; then
        info "检测到已部署节点，自动执行删除节点..."
        _delete_node_core "$state"
        remove_state
        rm -f "$LAST_LINKS_PATH" "$CF_ACCOUNT_PATH" "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH" "$ORIGIN_CSR_PATH"
    else
        info "未检测到已部署节点，仅停止服务并清理"
        stop_xray
    fi

    rm -rf "$STATE_DIR"
    rm -f /usr/local/bin/x

    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    printf '\033[31m卸载完成，脚本文件已删除: %s\033[0m\n' "$self"
    rm -f -- "$self" 2>/dev/null || true
    exit 0
}

# ── 3. 查看节点 ──────────────────────────────────────
# 取节点链接：优先订阅快照，其次 state
get_node_link() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then
        local link
        link=$(awk '/^vless /{sub(/^vless /,""); print; exit}' "$LAST_LINKS_PATH")
        [[ -n "$link" ]] && { echo "$link"; return 0; }
    fi
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || return 1
    echo "$state" | jq -r '.links | to_entries[0].value // empty'
}

print_node_links() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then cat "$LAST_LINKS_PATH"; return; fi
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "无历史节点"
    echo "域名: $(echo "$state" | jq -r '.domain')"
    echo "UUID: $(echo "$state" | jq -r '.uuid')"
    echo "$state" | jq -r '.links | to_entries[] | "\(.key) \(.value)"'
}

# 生成优选订阅：调用第三方优选服务（节点信息会提交到该服务）
gen_preferred_sub() {
    local node_link
    node_link=$(get_node_link) || die "未找到节点链接"
    echo
    info "生成优选订阅（需联网访问第三方服务）..."
    echo
    echo "  ⚠️  注意：节点信息会提交到第三方服务（$PREFERRED_SUB_BASE）"
    echo
    echo "优选订阅:"
    echo "  ${PREFERRED_SUB_BASE}/sub?link=$(urlencode "$node_link")"
    echo
    echo "用法: 把上面链接填进客户端订阅，客户端会自动优选最快 IP"
}

do_show() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" || -f "$LAST_LINKS_PATH" ]] || die "无历史节点"

    echo
    echo "  1. 查看节点链接"
    echo "  2. 生成优选订阅"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-2]: " sc
    case "$sc" in
        1) print_node_links ;;
        2) gen_preferred_sub ;;
        *) return ;;
    esac
}

# ── 4. 修改配置 ──────────────────────────────────────
do_modify() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain uid routes_json net_mode
    domain=$(echo "$state" | jq -r '.domain')
    uid=$(echo "$state" | jq -r '.uuid')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode // "direct"')

    echo
    echo "当前配置 ($net_mode):"
    echo "  域名: $domain  UUID: $uid"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    echo "  1. 修改 UUID"
    echo "  2. 修改端口"
    echo "  3. 修改 WS 路径"
    echo "  4. 全部修改"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-4]: " mc

    local new_uid="$uid" new_routes="$routes_json" changed=false

    [[ "$mc" =~ ^[0-4]$ ]] || die "无效选项"
    [[ "$mc" == "0" ]] && return

    if [[ "$mc" == "1" || "$mc" == "4" ]]; then
        read -rp "新 UUID(留空=重新生成): " iu
        if [[ -n "$iu" ]]; then
            [[ "$iu" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
            new_uid="${iu,,}"
        else
            new_uid=$(gen_uuid)
        fi
        changed=true; ok "UUID: $new_uid"
    fi

    if [[ "$mc" == "2" || "$mc" == "4" ]]; then
        local pc; pc=$(echo "$new_routes" | jq 'length')
        if [[ "$net_mode" == "nat" ]]; then
            echo "当前映射: $(echo "$new_routes" | jq -r '[.[] | "\(.listen_port):\(.cf_port)"] | join(",")')"
            read -rp "新端口映射(内部:外部，共${pc}组，留空=不改): " mr
            if [[ -n "$mr" ]]; then
                IFS=',' read -ra maps <<< "$mr"
                [[ ${#maps[@]} -eq $pc ]] || die "数量不匹配"
                local idx=0
                for m in "${maps[@]}"; do
                    m="${m// /}"; local lp="${m%%:*}" cp="${m##*:}"
                    [[ "$lp" =~ ^[0-9]+$ && "$cp" =~ ^[0-9]+$ ]] || die "无效: $m"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson l "$((lp))" --argjson c "$((cp))" '.[$i].listen_port=$l|.[$i].cf_port=$c')
                    idx=$((idx+1))
                done
                changed=true; ok "端口已更新"
            fi
        else
            echo "当前端口: $(echo "$new_routes" | jq -r '[.[].listen_port|tostring] | join(",")')"
            read -rp "新端口(逗号分隔，共${pc}个，留空=不改): " pr
            if [[ -n "$pr" ]]; then
                IFS=',' read -ra nps <<< "$pr"
                [[ ${#nps[@]} -eq $pc ]] || die "数量不匹配"
                local idx=0
                for np in "${nps[@]}"; do
                    np="${np// /}"; [[ "$np" =~ ^[0-9]+$ ]] || die "无效: $np"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((np))" '.[$i].listen_port=$p|.[$i].cf_port=$p')
                    idx=$((idx+1))
                done
                changed=true; ok "端口已更新"
            fi
        fi
    fi

    if [[ "$mc" == "3" || "$mc" == "4" ]]; then
        echo "当前路径: $(echo "$new_routes" | jq -r '[.[].path] | join(", ")')"
        read -rp "新 WS 路径前缀(留空=不改): " np
        if [[ -n "$np" ]]; then
            [[ "$np" == /* ]] || np="/${np}"
            new_routes=$(echo "$new_routes" | jq --arg pfx "$np" '[.[]|.path=($pfx+"-"+(if .protocol=="vless" then "vl" elif .protocol=="trojan" then "tr" else "vm" end))]')
            changed=true; ok "路径已更新"
        fi
    fi

    [[ "$changed" == "true" ]] || { echo "无修改"; return; }

    write_xray_config "$(gen_xray_config "$new_routes" "$new_uid" "$(echo "$state" | jq -r '.ssl_mode // "flexible"')")"
    restart_xray

    if load_cf_account; then
        apply_origin_rules "$(echo "$state" | jq -r '.zone_id')" "$domain" "$new_routes"
        ok "Origin Rules 已更新"
    fi

    local links_json; links_json=$(gen_all_links "$new_uid" "$domain" "$new_routes")
    save_links_snapshot "$domain" "$new_uid" "$links_json"
    save_state "$(echo "$state" | jq --arg u "$new_uid" --argjson r "$new_routes" --argjson l "$links_json" --arg s "${new_uid:0:8}" \
        '.uuid=$u|.short_id=$s|.routes=$r|.links=$l')"

    echo; ok "配置已更新"; print_links "$links_json"
}

# ── 5. 查看当前配置 ──────────────────────────────────
do_show_config() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    echo
    echo "域名:  $(echo "$state" | jq -r '.domain')"
    echo "UUID:  $(echo "$state" | jq -r '.uuid')"
    echo "模式:  $(echo "$state" | jq -r '.net_mode // "direct"')"
    echo "SSL:   $(echo "$state" | jq -r '.ssl_mode // "flexible"')"
    echo
    echo "入站:"
    echo "$state" | jq -r '.routes[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    echo -n "xray: "; svc_is_active && echo "运行中" || echo "未运行"
    echo
    echo "节点:"
    print_links "$(echo "$state" | jq '.links')"
    echo
}

# ── 6. 更新外部端口（NAT 快捷操作）──────────────────
do_update_ports() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain routes_json net_mode
    domain=$(echo "$state" | jq -r '.domain')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode // "direct"')

    echo
    echo "当前端口映射:"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port) -> 外部:\(.cf_port)"'
    echo

    local pc; pc=$(echo "$routes_json" | jq 'length')

    if [[ "$net_mode" == "nat" ]]; then
        info "NAT 模式: 只更新外部端口(CF Origin Rules)，xray 监听端口不变"
        echo

        local new_routes="$routes_json" idx=0
        # 先把数据收进数组再循环：若用 `done < <(...)`，循环体的 stdin 会被数据流占用，
        # 里面的交互 read 会吃掉下一行数据。
        local rows=() row
        mapfile -t rows < <(echo "$routes_json" | jq -r '.[] | [.protocol, (.cf_port|tostring)] | @tsv')
        for row in "${rows[@]}"; do
            local proto="${row%%$'\t'*}" old_cp="${row##*$'\t'}" ne
            read -rp "${proto} 新外部端口(当前=${old_cp}): " ne
            [[ -n "$ne" ]] || die "不能为空"
            [[ "$ne" =~ ^[0-9]+$ ]] || die "无效端口: $ne"
            new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ne))" '.[$i].cf_port=$p')
            idx=$((idx+1))
        done

        echo
        echo "更新预览:"
        echo "$new_routes" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port) -> 外部:\(.cf_port)"'
        read -rp "确认? (Y/n): " confirm
        [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

        # 只更新 CF Origin Rules，不动 xray
        load_cf_account || die "未找到 CF 凭据"
        apply_origin_rules "$(echo "$state" | jq -r '.zone_id')" "$domain" "$new_routes"
        ok "Origin Rules 已更新"

        # 同时更新 DNS（公网 IP 可能也变了）
        local public_ip; public_ip=$(get_public_ip)
        local zone_id; zone_id=$(echo "$state" | jq -r '.zone_id')
        local current_dns; current_dns=$(cf_get_dns "$zone_id" "$domain")
        local current_ip; current_ip=$(echo "$current_dns" | jq -r '.content // ""')
        if [[ "$current_ip" != "$public_ip" ]]; then
            cf_upsert_dns "$zone_id" "$domain" "$public_ip" >/dev/null
            ok "DNS 已更新: $domain -> $public_ip"
        fi

        local uid; uid=$(echo "$state" | jq -r '.uuid')
        local links_json; links_json=$(gen_all_links "$uid" "$domain" "$new_routes")
        save_links_snapshot "$domain" "$uid" "$links_json"
        save_state "$(echo "$state" | jq --argjson r "$new_routes" --argjson l "$links_json" '.routes=$r|.links=$l')"

        echo; ok "外部端口已更新"; print_links "$links_json"
    else
        info "直连模式: 端口变更需要同时修改 xray 监听，请使用 [4.修改配置]"
    fi
}

# ── 7. 重启 xray ─────────────────────────────────────
# ── 8. 切换网络模式 ──────────────────────────────────
# 探测可能判错（issue #1），装完之后也得能改，否则只能卸载重装。
do_switch_net_mode() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain zone_id uid cur routes_json
    domain=$(echo "$state" | jq -r '.domain')
    zone_id=$(echo "$state" | jq -r '.zone_id')
    uid=$(echo "$state" | jq -r '.uuid')
    cur=$(echo "$state" | jq -r '.net_mode // "direct"')
    routes_json=$(echo "$state" | jq '.routes')

    echo
    echo "当前模式: $(net_mode_label "$cur")"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  外部:\(.cf_port)"'
    echo

    local target
    if [[ "$cur" == "nat" ]]; then
        target="direct"
        echo "切成直连后，对外端口将与 xray 监听端口一致。"
    else
        target="nat"
        echo "切成 NAT 后，需要为每个协议指定对外端口（路由器/宿主上映射到监听端口）。"
    fi
    read -rp "确认切换到 $(net_mode_label "$target")? (y/N): " c
    [[ "${c,,}" =~ ^(y|yes)$ ]] || die "已取消"

    local new_routes="$routes_json"
    if [[ "$target" == "direct" ]]; then
        # 直连下外部端口就是监听端口
        new_routes=$(echo "$new_routes" | jq '[.[] | .cf_port = .listen_port]')
    else
        local idx=0
        # 同上：先收进数组，别让数据流占住循环体的 stdin
        local rows=() row
        mapfile -t rows < <(echo "$routes_json" | jq -r '.[] | [.protocol, (.listen_port|tostring)] | @tsv')
        for row in "${rows[@]}"; do
            local proto="${row%%$'\t'*}" lp="${row##*$'\t'}" ep
            read -rp "${proto} 对外端口(监听=${lp}, 回车=相同): " ep
            [[ -n "$ep" ]] || ep="$lp"
            [[ "$ep" =~ ^[0-9]+$ ]] || die "无效端口: $ep"
            new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ep))" '.[$i].cf_port=$p')
            idx=$((idx+1))
        done
    fi

    echo
    echo "更新预览:"
    echo "$new_routes" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  外部:\(.cf_port)"'
    read -rp "确认? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    load_cf_account || die "未找到 CF 凭据"
    apply_origin_rules "$zone_id" "$domain" "$new_routes"
    ok "Origin Rules 已更新"

    local links_json; links_json=$(gen_all_links "$uid" "$domain" "$new_routes")
    save_links_snapshot "$domain" "$uid" "$links_json"
    save_state "$(echo "$state" | jq --arg m "$target" --argjson r "$new_routes" --argjson l "$links_json" \
        '.net_mode=$m | .routes=$r | .links=$l')"

    echo; ok "已切换到 $(net_mode_label "$target")"; print_links "$links_json"
}

do_restart() {
    if ! svc_is_active; then
        echo "xray 当前未运行，正在启动..."
    else
        echo "正在重启 xray..."
    fi
    restart_xray
}

# ── 主入口 ────────────────────────────────────────────
ensure_shortcut() {
    local target="/usr/local/bin/x"
    # 已指向本仓库则跳过；否则（旧版/指向别处）一律重写，避免一直拉到旧脚本
    if [[ -f "$target" ]] && grep -q "XIEBROxzz/xray-cf-lite" "$target"; then
        return
    fi
    cat > "$target" << 'SCEOF'
#!/bin/sh
exec bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/xray_cf_lite.sh) "$@"
SCEOF
    chmod +x "$target"
    ok "快捷命令 x 已更新指向本仓库"
}

main() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行此脚本"
    detect_init
    install_deps
    need_cmd curl; need_cmd jq
    ensure_shortcut

    local state current_domain="" net_mode=""
    state=$(load_state 2>/dev/null || true)
    if [[ -n "$state" ]]; then
        current_domain=$(echo "$state" | jq -r '.domain // ""')
        net_mode=$(echo "$state" | jq -r '.net_mode // ""')
    fi

    echo
    echo "  xray-cf-lite ($INIT_SYSTEM)"
    echo
    echo "  1. 安装节点"
    echo "  2. 删除节点"
    echo "  3. 查看节点/优选订阅"
    echo "  4. 修改配置(UUID/端口/路径)"
    echo "  5. 查看当前配置"
    echo "  6. 更新外部端口(NAT换端口)"
    echo "  7. 重启 xray"
    echo "  8. 切换网络模式(直连/NAT)"
    [[ -n "$current_domain" ]] && echo "     (当前: $current_domain${net_mode:+ [$net_mode]})"
    echo
    echo -e "\033[31m  0. 卸载脚本\033[0m"
    echo

    read -rp "请选择 [0-8]: " choice
    case "$choice" in
        1) do_install ;; 2) do_delete_node ;; 3) do_show ;;
        4) do_modify ;; 5) do_show_config ;; 6) do_update_ports ;;
        7) do_restart ;; 8) do_switch_net_mode ;;
        0) do_uninstall_script ;;
        *) die "无效选项: $choice" ;;
    esac
}

main "$@"
