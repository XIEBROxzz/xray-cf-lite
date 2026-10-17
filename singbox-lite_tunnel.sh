#!/bin/bash

# sing-box-lite —— 仅保留 Argo 隧道（临时/固定）的精简管理脚本
# 前置支持完整保留：依赖安装、sing-box/cloudflared 核心安装、服务管理与配置初始化。

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# 配置、元数据、私钥和临时文件默认仅 root 可读写。
umask 077

# 基础路径定义
export SCRIPT_VERSION="1"
export DEFAULT_SNI="www.amd.com"
export WS_EARLY_DATA_SIZE="2560"
export WS_EARLY_DATA_HEADER="Sec-WebSocket-Protocol"
SELF_SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SELF_SCRIPT_PATH")"
SINGBOX_DIR="/usr/local/etc/sing-box"
SINGBOX_FIXED_VERSION="1.13.21"
SINGBOX_CORE_LOCK_FILE="${SINGBOX_DIR}/core-version.lock"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main"
SCRIPT_UPDATE_URL="${GITHUB_RAW_BASE}/singbox-lite_tunnel.sh"

# --- 核心工具函数 ---

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
ORANGE='\033[0;33m'

# 打印消息函数
_info() { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn() { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_warning() { _warn "$1"; } # 别名兼容
_error() { echo -e "${RED}[错误] $1${NC}" >&2; }

_is_podman_environment() {
    [ -f /run/.containerenv ] && return 0
    grep -qaE 'libpod|podman' /proc/1/cgroup /proc/1/environ 2>/dev/null
}

_flock_wait() {
    local fd="$1" timeout="${2:-30}" attempts i
    [[ "$fd" =~ ^[0-9]+$ && "$timeout" =~ ^[0-9]+$ ]] || return 1
    attempts=$((timeout * 10))
    for ((i = 0; i <= attempts; i++)); do
        flock -n "$fd" 2>/dev/null && return 0
        ((i < attempts)) && sleep 0.1
    done
    return 1
}

_with_state_lock() {
    if [ "${SINGBOXLITE_LOCK_HELD:-0}" = "1" ]; then
        "$@"
        return $?
    fi
    if ! command -v flock &>/dev/null; then
        _error "缺少 flock，拒绝在无共享锁保护下修改配置；请先安装 util-linux。"
        return 1
    fi

    (
        mkdir -p "$SINGBOX_DIR" 2>/dev/null || exit 1
        exec 9>"${SINGBOX_DIR}/.singboxlite.lock" || exit 1
        if ! _flock_wait 9 30; then
            _error "等待 singbox-lite 状态锁超时，请稍后重试。"
            exit 1
        fi
        export SINGBOXLITE_LOCK_HELD=1
        "$@"
    )
}

_secure_state_permissions() {
    [ -d "$SINGBOX_DIR" ] && chmod 700 "$SINGBOX_DIR" 2>/dev/null || true
    local path
    for path in \
        "$CONFIG_FILE" "$CLASH_YAML_FILE" "$METADATA_FILE" "$ARGO_METADATA_FILE" \
        "${SINGBOX_DIR}/relay.json" "$SINGBOX_CORE_LOCK_FILE"; do
        [ -f "$path" ] && chmod 600 "$path" 2>/dev/null || true
    done
    for path in "$SINGBOX_DIR"/*.key; do
        [ -f "$path" ] && chmod 600 "$path" 2>/dev/null || true
    done
}

# 检查 root 权限
_check_root() {
    if [[ $EUID -ne 0 ]]; then
        _error "此脚本必须以 root 权限运行。"
        exit 1
    fi
}

# 编解码器 (纯 Bash 稳健实现)
_url_decode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
}
_url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

_ws_path_with_early_data() {
    local ws_path="${1:-/}"
    if [[ "$ws_path" == *"ed="* ]]; then
        printf '%s' "$ws_path"
        return
    fi
    if [[ "$ws_path" == *"?"* ]]; then
        printf '%s&ed=%s' "$ws_path" "$WS_EARLY_DATA_SIZE"
    else
        printf '%s?ed=%s' "$ws_path" "$WS_EARLY_DATA_SIZE"
    fi
}

# 系统环境检测
_detect_init_system() {
    if [ -f /sbin/openrc-run ] || command -v rc-service &>/dev/null; then
        export INIT_SYSTEM="openrc"
        export SERVICE_FILE="/etc/init.d/sing-box"
    elif command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        export INIT_SYSTEM="systemd"
        export SERVICE_FILE="/etc/systemd/system/sing-box.service"
    else
        export INIT_SYSTEM="direct"
        export SERVICE_FILE=""
    fi
}

# 端口占用检查
_check_port_occupied() {
    local port=$1
    local proto=${2:-tcp}
    if [[ "$proto" == "tcp" ]]; then
        if command -v ss &>/dev/null; then
            ss -lnpt | grep -q ":${port} " && return 0
        else
            netstat -lnpt | grep -q ":${port} " && return 0
        fi
    else
        if command -v ss &>/dev/null; then
            ss -lnpu | grep -q ":${port} " && return 0
        else
            netstat -lnpu | grep -q ":${port} " && return 0
        fi
    fi
    return 1
}

_is_pid_running_cmd() {
    local pid="$1"
    local pattern="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Fq "$pattern"
    else
        ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$pattern"
    fi
}

_is_pid_file_running_cmd() {
    local pid_file="$1"
    local pattern="$2"
    local pid
    [ -s "$pid_file" ] || return 1
    pid=$(cat "$pid_file" 2>/dev/null)
    _is_pid_running_cmd "$pid" "$pattern"
}

_prepare_singbox_runtime_pid() {
    local legacy_pid_file="/tmp/sing-box.pid"
    mkdir -p "$RUNTIME_DIR" || return 1
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || return 1

    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
        rm -f -- "$legacy_pid_file"
        return 0
    fi
    rm -f -- "$PID_FILE"

    if _is_pid_file_running_cmd "$legacy_pid_file" "$SINGBOX_BIN"; then
        local legacy_pid
        legacy_pid=$(cat "$legacy_pid_file" 2>/dev/null)
        printf '%s\n' "$legacy_pid" > "$PID_FILE" || return 1
        chmod 600 "$PID_FILE" 2>/dev/null || return 1
    fi
    rm -f -- "$legacy_pid_file"
}

_check_port_in_singbox_file() {
    local file="$1" port="$2" proto="${3:-tcp}" exclude_tag="${4:-}"
    [ -s "$file" ] || return 1
    jq -e --argjson port "$port" --arg proto "$proto" --arg exclude "$exclude_tag" '
        def transports:
            if (.type == "hysteria2" or .type == "tuic") then ["udp"]
            elif (.type == "shadowsocks" or .type == "mixed") then ["tcp", "udp"]
            elif .type == "direct" then
                ((.network // "tcp") | if . == "tcp+udp" then ["tcp", "udp"] else [.] end)
            else ["tcp"] end;
        .inbounds[]?
        | select((.listen_port | tonumber?) == $port)
        | select($exclude == "" or (.tag != $exclude and ((.tag // "") | startswith($exclude + "-hop-") | not)))
        | select(transports | index($proto) != null)
    ' "$file" >/dev/null 2>&1
}

# 兼容旧调用；默认检查主 sing-box 的 TCP 监听。
_check_port_in_config() {
    local port="$1" proto="${2:-tcp}" exclude_tag="${3:-}"
    _check_port_in_singbox_file "$CONFIG_FILE" "$port" "$proto" "$exclude_tag"
}

# 综合端口冲突检测：系统监听、主配置、中转配置统一检查。
_check_port_conflict() {
    local port="$1" requested_proto="${2:-tcp}" silent="${3:-false}" exclude_tag="${4:-}"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        [ "$silent" != "true" ] && _error "端口 ${port} 无效，应为 1-65535。"
        return 0
    fi

    local protocols=""
    case "$requested_proto" in
        tcp) protocols="tcp" ;;
        udp) protocols="udp" ;;
        tcp+udp|udp+tcp|both) protocols="tcp udp" ;;
        *) protocols="$requested_proto" ;;
    esac

    local proto source
    for proto in $protocols; do
        source=""
        if _check_port_in_singbox_file "$CONFIG_FILE" "$port" "$proto" "$exclude_tag"; then
            source="主 sing-box 配置"
        elif _check_port_in_singbox_file "${SINGBOX_DIR}/relay.json" "$port" "$proto" ""; then
            source="中转 relay.json"
        elif _check_port_occupied "$port" "$proto"; then
            source="系统监听"
        fi
        if [ -n "$source" ]; then
            [ "$silent" != "true" ] && _error "${proto^^} 端口 ${port} 已被${source}占用。"
            return 0
        fi
    done
    return 1
}

# 统一服务管理
_manage_service() {
    local action="$1"

    if [[ "$action" == "restart" || "$action" == "start" ]]; then
        _time_prepare_ntp_config || return 1
        _ensure_relay_config || return 1
        local preflight_result
        if ! preflight_result=$(_check_combined_config_files "$SINGBOX_BIN" "$CONFIG_FILE" "$RELAY_CONFIG_FILE" 2>&1); then
            _error "拒绝启动：config.json + relay.json 组合配置无效。"
            echo "$preflight_result"
            return 1
        fi
        _secure_state_permissions
    fi

    [ -z "$INIT_SYSTEM" ] && _detect_init_system
    [ "$action" == "status" ] || _info "正在使用 ${INIT_SYSTEM} 执行: $action..."
    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" == "status" ]; then systemctl status sing-box --no-pager -l; return; fi
            if [ "$action" == "start" ] || [ "$action" == "restart" ]; then
                systemctl reset-failed sing-box >/dev/null 2>&1 || true
            fi
            systemctl "$action" sing-box 8>&- 9>&- 219>&- ;;
        openrc)
            if [ "$action" == "status" ]; then rc-service sing-box status; return; fi
            rc-service sing-box "$action" 8>&- 9>&- 219>&- ;;
        direct)
            if ! _prepare_singbox_runtime_pid; then
                _error "无法准备受保护的运行目录: ${RUNTIME_DIR}"
                return 1
            fi
            case "$action" in
                start)
                    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _success "sing-box 已在 direct 模式运行。"
                        return 0
                    fi
                    rm -f "$PID_FILE"
                    [ -s "${SINGBOX_DIR}/relay.json" ] || echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "${SINGBOX_DIR}/relay.json"
                    nohup env GOMEMLIMIT="$(_get_mem_limit)MiB" \
                        "$SINGBOX_BIN" run -c "$CONFIG_FILE" -c "${SINGBOX_DIR}/relay.json" \
                        >> "$LOG_FILE" 2>&1 8>&- 9>&- 219>&- &
                    echo $! > "$PID_FILE"
                    chmod 600 "$PID_FILE" 2>/dev/null || true
                    sleep 1
                    if ! _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _error "sing-box 启动后立即退出，请检查日志。"
                        rm -f "$PID_FILE"
                        return 1
                    fi
                    _success "sing-box 已以 direct 后台模式启动。"
                    ;;
                stop)
                    if [ -s "$PID_FILE" ]; then
                        local pid
                        pid=$(cat "$PID_FILE" 2>/dev/null)
                        if _is_pid_running_cmd "$pid" "$SINGBOX_BIN"; then
                            kill "$pid" 2>/dev/null
                        fi
                    fi
                    rm -f "$PID_FILE"
                    _success "sing-box direct 后台进程已停止。"
                    ;;
                restart)
                    _manage_service stop
                    sleep 1
                    _manage_service start
                    ;;
                status)
                    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _success "sing-box direct 后台模式运行中 (PID: $(cat "$PID_FILE"))"
                    else
                        rm -f "$PID_FILE"
                        _warn "sing-box direct 后台模式未运行。"
                        return 1
                    fi
                    ;;
                *) _error "direct 模式不支持的服务操作: $action"; return 1 ;;
            esac
            ;;
        *) _error "不支持的服务管理系统" ;;
    esac
}

# 智能包管理
_pkg_install() {
    local pkgs="$*"
    [ -z "$pkgs" ] && return 0
    if command -v apk &>/dev/null; then
        apk add --no-cache $pkgs >/dev/null 2>&1
    elif command -v apt-get &>/dev/null; then
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls -A /var/lib/apt/lists/ 2>/dev/null | wc -l)" -le 1 ]; then
            apt-get update -qq >/dev/null 2>&1
        fi
        if _is_podman_environment; then
            local pkg
            for pkg in $pkgs; do
                if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
                    continue
                fi
                if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                    -o Dpkg::Use-Pty=0 -o Acquire::Languages=none "$pkg" >/dev/null 2>&1; then
                    apt-get update -qq -o Acquire::Languages=none >/dev/null 2>&1 || return 1
                    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                        -o Dpkg::Use-Pty=0 -o Acquire::Languages=none "$pkg" >/dev/null 2>&1 || return 1
                fi
            done
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 || {
                apt-get update -qq >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
            }
        fi
    elif command -v yum &>/dev/null; then yum install -y $pkgs >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then dnf install -y $pkgs >/dev/null 2>&1
    else
        return 1
    fi
}

# 原子修改 JSON/YAML 文件
_atomic_modify_json() {
    local file="$1" filter="$2"
    shift 2
    [ ! -f "$file" ] && return 1
    _with_state_lock _atomic_modify_json_locked "$file" "$filter" "$@"
}
_atomic_modify_json_locked() {
    local file="$1" filter="$2"
    shift 2
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if jq "$@" "$filter" "$file" > "$tmp" && jq empty "$tmp" >/dev/null 2>&1; then
        chmod 600 "$tmp" 2>/dev/null || true
        if ! mv -f "$tmp" "$file"; then
            _error "替换 JSON 失败: $file"
            rm -f "$tmp"
            return 1
        fi
    else
        _error "修改 JSON 失败: $file"
        rm -f "$tmp"
        return 1
    fi
}
_atomic_modify_yaml() {
    local file="$1" filter="$2"
    [ ! -f "$file" ] && return 1
    _with_state_lock _atomic_modify_yaml_locked "$file" "$filter"
}
_atomic_modify_yaml_locked() {
    local file="$1" filter="$2"
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    cp "$file" "$tmp" || { rm -f "$tmp"; return 1; }
    if ${YQ_BINARY} eval "$filter" -i "$tmp" 2>/dev/null; then
        chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    else
        _error "修改 YAML 失败: $file"
        rm -f "$tmp"
        return 1
    fi
}

_ensure_relay_config_locked() {
    if [ ! -s "$RELAY_CONFIG_FILE" ]; then
        local tmp
        tmp=$(mktemp "${RELAY_CONFIG_FILE}.tmp.XXXXXX") || return 1
        printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$tmp"
        chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$RELAY_CONFIG_FILE" || { rm -f "$tmp"; return 1; }
    fi
    jq empty "$RELAY_CONFIG_FILE" >/dev/null 2>&1
}

_ensure_relay_config() {
    mkdir -p "$SINGBOX_DIR" || return 1
    _with_state_lock _ensure_relay_config_locked
}

_check_combined_config_files() {
    local binary="${1:-$SINGBOX_BIN}" main_config="${2:-$CONFIG_FILE}" relay_config="${3:-$RELAY_CONFIG_FILE}"
    [ -x "$binary" ] || { _error "sing-box 核心不可执行: $binary"; return 1; }
    [ -s "$main_config" ] || { _error "主配置不存在或为空: $main_config"; return 1; }
    [ -s "$relay_config" ] || { _error "中转配置不存在或为空: $relay_config"; return 1; }
    "$binary" check -c "$main_config" -c "$relay_config"
}

_build_dns_config_json() {
    local address="$1" strategy="$2" type server port path resolver="" server_json
    case "$strategy" in
        prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only) ;;
        *) return 1 ;;
    esac

    if [ "$address" = "local" ]; then
        jq -cn --arg strategy "$strategy" '{servers:[{type:"local",tag:"dns-local",prefer_go:true}],final:"dns-local",strategy:$strategy}'
        return $?
    elif [[ "$address" =~ ^https://(\[[^]]+\]|[^/:]+)(:([0-9]+))?(/.*)?$ ]]; then
        type="https"; server="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]:-443}"; path="${BASH_REMATCH[4]:-/dns-query}"
    elif [[ "$address" =~ ^tls://(\[[^]]+\]|[^/:]+)(:([0-9]+))?/?$ ]]; then
        type="tls"; server="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]:-853}"; path=""
    elif [[ "$address" =~ ^tcp://(\[[^]]+\]|[^/:]+)(:([0-9]+))?/?$ ]]; then
        type="tcp"; server="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]:-53}"; path=""
    elif [[ "$address" =~ ^udp://(\[[^]]+\]|[^/:]+)(:([0-9]+))?/?$ ]]; then
        type="udp"; server="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]:-53}"; path=""
    elif [[ "$address" != *"://"* && "$address" != *[[:space:]]* ]]; then
        type="udp"; server="$address"; port="53"; path=""
    else
        return 1
    fi

    server="${server#[}"; server="${server%]}"
    [ -n "$server" ] && [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || return 1
    [[ "$server" =~ ^[0-9.]+$ || "$server" == *:* ]] || resolver="dns-bootstrap"

    server_json=$(jq -cn \
        --arg type "$type" --arg server "$server" --argjson port "$((10#$port))" \
        --arg path "$path" --arg resolver "$resolver" '
        {type:$type,tag:"dns-local",server:$server,server_port:$port}
        + (if $type == "https" then {path:$path} else {} end)
        + (if $resolver != "" then {domain_resolver:$resolver} else {} end)
    ') || return 1

    if [ -n "$resolver" ]; then
        jq -cn --argjson server "$server_json" --arg strategy "$strategy" \
            '{servers:[{type:"local",tag:"dns-bootstrap",prefer_go:true},$server],final:"dns-local",strategy:$strategy}'
    else
        jq -cn --argjson server "$server_json" --arg strategy "$strategy" \
            '{servers:[$server],final:"dns-local",strategy:$strategy}'
    fi
}

# --- 时间管理（前置支持） ---

_time_is_container() {
    [ -e /run/.containerenv ] || [ -e /.dockerenv ] || [ -s /run/systemd/container ] && return 0
    if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet 2>/dev/null; then
        return 0
    fi
    grep -qaE 'container=|lxc|libpod|podman|docker' /proc/1/environ /proc/1/cgroup 2>/dev/null
}

_time_probe_ntp() {
    local server="$1" port="${2:-123}" nonce escaped="" raw started finished i octet
    local -a bytes
    TIME_PROBE_EPOCH="" TIME_PROBE_OFFSET="" TIME_PROBE_SOURCE=""
    [[ "$port" =~ ^[0-9]+$ ]] && ((port > 0 && port <= 65535)) || return 1
    for i in timeout bash openssl dd od date; do command -v "$i" >/dev/null 2>&1 || return 1; done
    nonce=$(openssl rand -hex 8) || return 1
    [[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || return 1
    for ((i=0; i<16; i+=2)); do escaped+="\\x${nonce:i:2}"; done
    started=$(date +%s) || return 1
    raw=$(timeout -s KILL 3 bash -c '
        exec 3<>"/dev/udp/$1/$2" || exit 1
        packet="\\043"
        for ((i=0; i<39; i++)); do packet+="\\000"; done
        printf "%b" "$packet$3" >&3 || exit 1
        timeout -s KILL 2 dd bs=512 count=1 <&3 2>/dev/null | od -An -v -tu1
    ' bash "$server" "$port" "$escaped" 2>/dev/null) || return 1
    finished=$(date +%s) || return 1
    raw=${raw//$'\n'/ }
    read -r -a bytes <<< "$raw"
    [ "${#bytes[@]}" -ge 48 ] || return 1
    for octet in "${bytes[@]}"; do [[ "$octet" =~ ^[0-9]+$ ]] && ((octet <= 255)) || return 1; done
    (( (bytes[0] & 7) == 4 && (bytes[0] >> 6) != 3 && bytes[1] > 0 && bytes[1] < 16 )) || return 1
    for ((i=0; i<8; i++)); do
        (( bytes[24+i] == 16#${nonce:i*2:2} )) || return 1
    done
    TIME_PROBE_EPOCH=$((bytes[40]*16777216 + bytes[41]*65536 + bytes[42]*256 + bytes[43] - 2208988800))
    ((TIME_PROBE_EPOCH >= 1577836800 && finished >= started && finished-started <= 5)) || return 1
    TIME_PROBE_OFFSET=$((TIME_PROBE_EPOCH - (started+finished)/2))
    TIME_PROBE_SOURCE="$server:$port"
}

_time_has_ss2022() {
    local config
    for config in "$CONFIG_FILE" "${RELAY_CONFIG_FILE:-${SINGBOX_DIR}/relay.json}"; do
        [ -s "$config" ] || continue
        jq -e '[.inbounds[]?, .outbounds[]?] | any(.type == "shadowsocks" and ((.method // "") | startswith("2022-")))' "$config" >/dev/null 2>&1 && return 0
    done
    return 1
}

_time_prepare_ntp_config() {
    _with_state_lock _time_prepare_ntp_config_locked
}

_time_prepare_ntp_config_locked() {
    [ -s "$CONFIG_FILE" ] || return 0
    local current managed="" wanted server state_file="${SINGBOX_DIR}/time-sync.json"
    local status="unreachable" tmp old_present
    current=$(jq -cS '.ntp // null' "$CONFIG_FILE") || return 1
    old_present=$(jq -r 'has("ntp")' "$CONFIG_FILE") || return 1
    [ ! -s "$state_file" ] || managed=$(jq -cS '.managed_ntp // null' "$state_file" 2>/dev/null)
    if [ "$current" != null ] && [ "$current" != "$managed" ] && ! jq -e '
        .ntp == {enabled:true,server:"time.apple.com",server_port:123,interval:"30m"}
        or .ntp == {enabled:true,server:"time.apple.com",server_port:123,interval:"1m",write_to_system:false,connect_timeout:"3s"}
    ' "$CONFIG_FILE" >/dev/null; then
        if _time_has_ss2022; then
            _info "保留用户自定义 NTP 配置；SS2022 需确认校时成功。"
        fi
        return 0
    fi

    wanted='{"enabled":false}'
    for server in time.apple.com time.cloudflare.com time.google.com; do
        if _time_probe_ntp "$server" 123; then
            wanted=$(jq -cn --arg s "$server" '{enabled:true,server:$s,server_port:123,interval:"1m",write_to_system:false,connect_timeout:"3s"}') || return 1
            status="reachable"
            break
        fi
    done
    tmp=$(mktemp "${state_file}.tmp.XXXXXX") || return 1
    if ! jq -n --argjson ntp "$wanted" --arg status "$status" --arg offset "${TIME_PROBE_OFFSET:-}" --arg source "${TIME_PROBE_SOURCE:-}" --arg checked "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{managed_ntp:$ntp,last_probe_status:$status,system_offset_seconds:$offset,source:$source,checked_at_system_utc:$checked}' > "$tmp" || ! chmod 600 "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [ "$current" != "$(printf '%s' "$wanted" | jq -cS .)" ]; then
        if ! _atomic_modify_json "$CONFIG_FILE" '.ntp = $ntp' --argjson ntp "$wanted"; then
            rm -f -- "$tmp"
            return 1
        fi
    fi
    if ! mv -f "$tmp" "$state_file"; then
        _atomic_modify_json "$CONFIG_FILE" 'if $present then .ntp=$ntp else del(.ntp) end' --argjson ntp "$current" --argjson present "$old_present" || _error "恢复原 NTP 配置失败"
        rm -f -- "$tmp"
        return 1
    fi
    if [ "$status" = reachable ]; then
        _info "核心 NTP: ${TIME_PROBE_SOURCE}，每 1 分钟补偿时间；系统偏差约 ${TIME_PROBE_OFFSET} 秒，不写系统时钟。"
    else
        _warn "三个 NTP 时间源均未通过有界探测，暂不启用脚本管理的内置 NTP，避免拖延节点启动。"
    fi
    return 0
}

_sync_system_time() {
    if _time_is_container; then
        _warn "容器不执行系统校时；其余进程仍依赖宿主机时间。"
        return 0
    fi
    local caps sync_ok=false
    caps=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
    if ! [[ "$caps" =~ ^[0-9a-fA-F]+$ ]] || (( (16#$caps & (1 << 25)) == 0 )); then
        _warn "缺少 CAP_SYS_TIME，不尝试修改系统时间。"
        return 1
    fi
    if command -v chronyc >/dev/null 2>&1 && timeout 5 chronyc tracking >/dev/null 2>&1; then
        timeout 8 chronyc makestep >/dev/null 2>&1 && sync_ok=true
    elif _pkg_install ntpdate >/dev/null 2>&1 && command -v ntpdate >/dev/null 2>&1; then
        timeout 10 ntpdate -u time.cloudflare.com >/dev/null 2>&1 && sync_ok=true
    elif [ "${INIT_SYSTEM:-}" = openrc ] && _pkg_install chrony >/dev/null 2>&1; then
        timeout 10 chronyd -q 'server time.cloudflare.com iburst' >/dev/null 2>&1 && sync_ok=true
    fi
    if [ "$sync_ok" != true ]; then
        _error "系统校时失败，不能宣称已同步；请检查权限、时间源及网络。"
        return 1
    fi
    _success "系统校时完成。"
}

# --- Clash YAML 节点管理 ---

_get_proxy_field() {
    local proxy_name="$1" field="$2"
    export PROXY_NAME="$proxy_name"
    ${YQ_BINARY} eval '.proxies[] | select(.name == env(PROXY_NAME)) | '"$field" "${CLASH_YAML_FILE}" 2>/dev/null | head -n 1
}
_add_node_to_yaml() {
    local proxy_json="$1"
    _with_state_lock _add_node_to_yaml_locked "$proxy_json"
}
_add_node_to_yaml_locked() {
    local proxy_json="$1"
    local proxy_name
    proxy_name=$(echo "$proxy_json" | jq -r .name)
    [ -n "$proxy_name" ] && [ "$proxy_name" != "null" ] || { _error "节点名称为空，拒绝写入共享 YAML。"; return 1; }
    export PROXY_NAME="$proxy_name"
    if ${YQ_BINARY} eval '.proxies[] | select(.name == env(PROXY_NAME)) | .name' "$CLASH_YAML_FILE" 2>/dev/null | grep -Fxq "$proxy_name"; then
        _error "共享 Clash YAML 已存在同名节点 [$proxy_name]；请更换名称。"
        return 1
    fi
    if ! ${YQ_BINARY} eval '.proxy-groups[] | select(.name == "节点选择") | .name' "$CLASH_YAML_FILE" 2>/dev/null | grep -Fxq '节点选择'; then
        _error "共享 Clash YAML 缺少 [节点选择] 分组，拒绝写入孤立代理。"
        return 1
    fi
    local yaml_backup
    yaml_backup=$(mktemp "${CLASH_YAML_FILE}.add.backup.XXXXXX") || return 1
    cp -p "$CLASH_YAML_FILE" "$yaml_backup" || { rm -f "$yaml_backup"; return 1; }
    _atomic_modify_yaml "$CLASH_YAML_FILE" ".proxies |= . + [${proxy_json}]" || { mv -f "$yaml_backup" "$CLASH_YAML_FILE"; return 1; }
    export PROXY_NAME="$proxy_name"
    if ! _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxy-groups[] | select(.name == "节点选择") | .proxies) = ((((.proxy-groups[] | select(.name == "节点选择") | .proxies) // []) + [env(PROXY_NAME)]) | unique)'; then
        mv -f "$yaml_backup" "$CLASH_YAML_FILE"
        return 1
    fi
    rm -f "$yaml_backup"
}
_remove_node_from_yaml() {
    local proxy_name="$1"
    _with_state_lock _remove_node_from_yaml_locked "$proxy_name"
}
_remove_node_from_yaml_locked() {
    local proxy_name="$1"
    export PROXY_NAME="$proxy_name"
    local yaml_backup
    yaml_backup=$(mktemp "${CLASH_YAML_FILE}.remove.backup.XXXXXX") || return 1
    cp -p "$CLASH_YAML_FILE" "$yaml_backup" || { rm -f "$yaml_backup"; return 1; }
    _atomic_modify_yaml "$CLASH_YAML_FILE" 'del(.proxies[] | select(.name == env(PROXY_NAME)))' || { mv -f "$yaml_backup" "$CLASH_YAML_FILE"; return 1; }
    if ! _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxy-groups[] | .proxies) |= (((. // []) | map(select(. != env(PROXY_NAME)))))'; then
        mv -f "$yaml_backup" "$CLASH_YAML_FILE"
        return 1
    fi
    rm -f "$yaml_backup"
}

# --- 资源与环境管理 ---

_get_mem_limit() {
    local total_mem_mb=0 cgroup_limit="" candidate_mb=0
    local limit limit_file

    total_mem_mb=$(awk '/^MemTotal:/{print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null)
    [[ "$total_mem_mb" =~ ^[0-9]+$ ]] || total_mem_mb=0

    if [ -r /sys/fs/cgroup/memory.max ]; then
        for limit_file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high; do
            [ -r "$limit_file" ] || continue
            cgroup_limit=$(cat "$limit_file" 2>/dev/null)
            if [[ "$cgroup_limit" =~ ^[0-9]+$ ]] && [ "$cgroup_limit" -lt 9223372036854771712 ] 2>/dev/null; then
                candidate_mb=$((cgroup_limit / 1024 / 1024))
                if [ "$candidate_mb" -gt 0 ] && { [ "$total_mem_mb" -eq 0 ] || [ "$candidate_mb" -lt "$total_mem_mb" ]; }; then
                    total_mem_mb=$candidate_mb
                fi
            fi
        done
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cgroup_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        if [[ "$cgroup_limit" =~ ^[0-9]+$ ]] && [ "$cgroup_limit" -lt 9223372036854771712 ] 2>/dev/null; then
            candidate_mb=$((cgroup_limit / 1024 / 1024))
            if [ "$candidate_mb" -gt 0 ] && { [ "$total_mem_mb" -eq 0 ] || [ "$candidate_mb" -lt "$total_mem_mb" ]; }; then
                total_mem_mb=$candidate_mb
            fi
        fi
    fi

    [ "$total_mem_mb" -gt 0 ] || total_mem_mb=128

    if [ "$total_mem_mb" -le 128 ]; then
        limit=$((total_mem_mb * 5 / 16))
    elif [ "$total_mem_mb" -le 256 ]; then
        limit=$((total_mem_mb * 50 / 100))
    elif [ "$total_mem_mb" -le 512 ]; then
        limit=$((total_mem_mb * 65 / 100))
    else
        limit=$((total_mem_mb * 80 / 100))
    fi

    [ "$limit" -lt 32 ] && limit=32
    echo "$limit"
}

_release_install_cache() {
    sync 2>/dev/null || true
    return 0
}

# 安装 yq
_install_yq() {
    if [ ! -x "$YQ_BINARY" ] || ! "$YQ_BINARY" --version >/dev/null 2>&1; then
        _info "安装 yq..."
        local arch
        arch=$(uname -m)
        case $arch in
            x86_64|amd64) arch='amd64' ;;
            aarch64|arm64) arch='arm64' ;;
            armv7l|armv7|armhf) arch='arm' ;;
            *) _error "yq 不支持当前架构: $(uname -m)"; return 1 ;;
        esac
        local asset="yq_linux_${arch}"
        local release_json release_tag release_base
        release_json=$(curl -fsSL --max-time 15 https://api.github.com/repos/mikefarah/yq/releases/latest 2>/dev/null) || true
        release_tag=$(printf '%s' "$release_json" | jq -r '.tag_name // empty' 2>/dev/null)
        if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            _error "无法解析 yq 官方 release tag。"
            return 1
        fi
        release_base="https://github.com/mikefarah/yq/releases/download/${release_tag}"

        local tmp_yq checksums_tmp order_tmp
        tmp_yq=$(mktemp "$(dirname "$YQ_BINARY")/.yq.new.XXXXXX") || return 1
        checksums_tmp=$(mktemp /tmp/singboxlite-yq-checksums.XXXXXX) || { rm -f -- "$tmp_yq"; return 1; }
        order_tmp=$(mktemp /tmp/singboxlite-yq-order.XXXXXX) || { rm -f -- "$tmp_yq" "$checksums_tmp"; return 1; }
        if ! wget -qO "$tmp_yq" "${release_base}/${asset}" \
            || ! wget -qO "$checksums_tmp" "${release_base}/checksums" \
            || ! wget -qO "$order_tmp" "${release_base}/checksums_hashes_order"; then
            rm -f -- "$tmp_yq" "$checksums_tmp" "$order_tmp"
            _error "yq 或官方校验文件下载失败。"
            return 1
        fi

        local sha_line sha_field expected_sha actual_sha
        sha_line=$(grep -n -x -m 1 'SHA-256' "$order_tmp" | cut -d: -f1)
        if ! [[ "$sha_line" =~ ^[0-9]+$ ]]; then
            rm -f -- "$tmp_yq" "$checksums_tmp" "$order_tmp"
            _error "yq 官方校验文件缺少 SHA-256 定义。"
            return 1
        fi
        sha_field=$((sha_line + 1))
        expected_sha=$(awk -v name="$asset" -v field="$sha_field" '
            $1 == name { count++; value=$field }
            END { if (count == 1) print tolower(value) }
        ' "$checksums_tmp")
        actual_sha=$(openssl dgst -sha256 "$tmp_yq" 2>/dev/null | awk '{print tolower($NF)}')
        if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || [ "$actual_sha" != "$expected_sha" ]; then
            rm -f -- "$tmp_yq" "$checksums_tmp" "$order_tmp"
            _error "yq SHA-256 校验失败，拒绝安装。"
            return 1
        fi
        rm -f -- "$checksums_tmp" "$order_tmp"

        if ! chmod 755 "$tmp_yq" || ! "$tmp_yq" --version >/dev/null 2>&1 \
            || ! mv -f "$tmp_yq" "$YQ_BINARY"; then
            rm -f -- "$tmp_yq"
            _error "yq 下载或完整性自检失败。"
            return 1
        fi
    fi
}

# --- 核心变量定义 ---
export SINGBOX_DIR="/usr/local/etc/sing-box"
export SINGBOX_BIN="/usr/local/bin/sing-box"
export SINGBOX_FIXED_VERSION="1.13.21"
export SINGBOX_CORE_LOCK_FILE="${SINGBOX_DIR}/core-version.lock"
export YQ_BINARY="/usr/local/bin/yq"
export CONFIG_FILE="${SINGBOX_DIR}/config.json"
export RELAY_CONFIG_FILE="${SINGBOX_DIR}/relay.json"
export CLASH_YAML_FILE="${SINGBOX_DIR}/clash.yaml"
export METADATA_FILE="${SINGBOX_DIR}/metadata.json"
export ARGO_METADATA_FILE="${SINGBOX_DIR}/argo_metadata.json"
export LOG_FILE="/var/log/sing-box.log"
export ARGO_LOG_FILE="/var/log/singbox_argo.log"
export RUNTIME_DIR="/run/singboxlite"
export PID_FILE="${RUNTIME_DIR}/sing-box.pid"
export CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
# 固定隧道统一本地端口 + Cloudflare API (邮箱+Global API Key 自动部署)
export ARGO_FIXED_PORT="8080"
export CF_API_BASE="https://api.cloudflare.com/client/v4"
export CF_ACCOUNT_FILE="${SINGBOX_DIR}/cf_account.json"
export DEP_STATE_FILE="${SINGBOX_DIR}/dependencies.ok"
export DEP_STATE_VERSION="20260831-lowmem-1"
_detect_init_system
case "$INIT_SYSTEM" in
    openrc) export SERVICE_FILE="/etc/init.d/sing-box" ;;
    systemd) export SERVICE_FILE="/etc/systemd/system/sing-box.service" ;;
    *) export SERVICE_FILE="" ;;
esac

server_ip=""
BATCH_MODE=false
VIEW_LINKS_TMP=""
_cleanup_main_temp_files() {
    [ -z "${VIEW_LINKS_TMP:-}" ] || rm -f -- "$VIEW_LINKS_TMP"
}
trap _cleanup_main_temp_files EXIT

# 依赖安装
_install_dependencies() {
    local force="${1:-false}"
    if [ "$force" != "true" ] && [ -s "$DEP_STATE_FILE" ] && grep -qx "$DEP_STATE_VERSION" "$DEP_STATE_FILE" 2>/dev/null; then
        local missing_cached=""
        for cmd in bash jq curl wget openssl tar unzip flock; do
            if ! command -v "$cmd" &>/dev/null; then
                missing_cached="$missing_cached $cmd"
            fi
        done
        if [ -z "$missing_cached" ] && [ -x "$YQ_BINARY" ]; then
            return 0
        fi
        [ ! -x "$YQ_BINARY" ] && missing_cached="$missing_cached yq"
        _warn "依赖缓存存在，但关键工具缺失:${missing_cached}，将执行一次修复安装。"
    fi

    local lock_pkg="util-linux"
    command -v apk &>/dev/null && lock_pkg="util-linux-misc"
    local core_pkgs="bash curl jq openssl wget tar unzip ca-certificates ${lock_pkg}"
    local optional_pkgs="procps socat iproute2 cron lsof"

    if _is_podman_environment; then
        optional_pkgs=""
        _info "检测到 Podman 容器：跳过可选依赖，仅保留脚本核心依赖"
    fi

    if command -v apk &>/dev/null; then
        optional_pkgs="${optional_pkgs/cron/dcron}"
    elif ! command -v apt-get &>/dev/null && ! command -v yum &>/dev/null && ! command -v dnf &>/dev/null; then
        optional_pkgs="${optional_pkgs/cron/cronie}"
    fi

    _info "正在安装核心依赖..."
    _pkg_install $core_pkgs
    if ! command -v flock &>/dev/null; then
        _pkg_install util-linux 2>/dev/null || true
    fi

    if [ -n "$optional_pkgs" ]; then
        _info "正在安装可选依赖..."
        _pkg_install $optional_pkgs 2>/dev/null || {
            _warn "部分可选依赖批量安装遇到冲突，正在逐个重试..."
            for pkg in $optional_pkgs; do
                _pkg_install "$pkg" 2>/dev/null || true
            done
        }
    fi

    _install_yq

    if command -v apk &>/dev/null; then
        if command -v crond &>/dev/null; then
            rc-service dcron start 2>/dev/null || true
            rc-update add dcron default 2>/dev/null || true
        fi
    fi

    local missing=""
    for cmd in bash jq curl wget openssl tar unzip flock; do
        if ! command -v "$cmd" &>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ ! -x "$YQ_BINARY" ]; then
        missing="$missing yq"
    fi
    if [ -n "$missing" ]; then
        _error "以下关键依赖安装失败:${missing}"
        _error "请使用系统包管理器手动安装这些工具（如 apk add / apt-get install / yum install）"
        exit 1
    fi

    mkdir -p "$SINGBOX_DIR"
    printf '%s\n' "$DEP_STATE_VERSION" > "$DEP_STATE_FILE"
}

_singbox_core_is_locked() {
    [ -s "$SINGBOX_CORE_LOCK_FILE" ]
}

_write_singbox_core_lock() {
    local tmp
    mkdir -p "$SINGBOX_DIR" || return 1
    tmp=$(mktemp "${SINGBOX_CORE_LOCK_FILE}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$SINGBOX_FIXED_VERSION" > "$tmp" \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$SINGBOX_CORE_LOCK_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

_install_sing_box() {
    local requested_version="${1:-latest}"
    local api_url requested_label
    case "$requested_version" in
        latest)
            api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
            requested_label="最新稳定版"
            ;;
        "$SINGBOX_FIXED_VERSION")
            api_url="https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${SINGBOX_FIXED_VERSION}"
            requested_label="固定版 v${SINGBOX_FIXED_VERSION}"
            ;;
        *)
            _error "不允许安装未授权的 sing-box 版本: ${requested_version}"
            return 1
            ;;
    esac
    _info "正在安装 ${requested_label} sing-box..."
    local arch=$(uname -m)
    local arch_tag
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='armv7' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac

    local libc_suffix=""
    if ldd --version 2>&1 | grep -qi musl || [ -f /etc/alpine-release ]; then
        _info "检测到 musl libc (Alpine 等系统)，将下载 musl 版本..."
        libc_suffix="-musl"
    fi

    local search_pattern="linux-${arch_tag}${libc_suffix}.tar.gz"
    local asset_info release_tag release_draft release_prerelease
    local asset_count asset_name download_url asset_digest release_version expected_asset_name
    if ! asset_info=$(curl -fsSL --retry 3 --connect-timeout 10 "$api_url" | jq -r --arg pattern "$search_pattern" '
        [.assets[] | select(.name | endswith($pattern))] as $matches
        | [(.tag_name // ""),
           (if (.draft | type) == "boolean" then .draft else true end),
           (if (.prerelease | type) == "boolean" then .prerelease else true end),
           ($matches | length), ($matches[0].name // ""),
           ($matches[0].browser_download_url // ""), ($matches[0].digest // "")]
        | @tsv
    '); then
        _error "无法读取 sing-box 官方发布信息。"
        return 1
    fi
    IFS=$'\t' read -r release_tag release_draft release_prerelease asset_count asset_name download_url asset_digest <<< "$asset_info"
    if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || [ "$release_draft" != "false" ] || [ "$release_prerelease" != "false" ]; then
        _error "sing-box 官方发布元数据无效或不是稳定版，已拒绝安装。"
        return 1
    fi
    release_version="${release_tag#v}"
    if [ "$requested_version" != "latest" ] && [ "$release_version" != "$requested_version" ]; then
        _error "固定版响应不匹配：请求 v${requested_version}，实际为 ${release_tag}。"
        return 1
    fi
    if [ "$asset_count" != "1" ]; then
        _error "sing-box 官方发布中目标资产数量异常 (${asset_count:-无法解析})，已拒绝安装。"
        return 1
    fi
    expected_asset_name="sing-box-${release_version}-linux-${arch_tag}${libc_suffix}.tar.gz"
    if [ "$asset_name" != "$expected_asset_name" ] || [ -z "$download_url" ] \
        || [[ "$download_url" != "https://github.com/SagerNet/sing-box/releases/download/${release_tag}/${expected_asset_name}" ]]; then
        _error "无法获取可信的 sing-box 下载链接 (搜索: ${search_pattern})。"
        return 1
    fi
    if [[ ! "$asset_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        _error "sing-box 官方资产缺少有效的 API SHA-256 摘要，已拒绝替换核心。"
        return 1
    fi

    local temp_dir extracted_bin expected actual staged_bin digest_file extracted_version
    mkdir -p /var/tmp || { _error "创建安装临时目录失败。"; return 1; }
    local stale_dir stale_pid
    for stale_dir in /var/tmp/.singbox-install.*; do
        [ -d "$stale_dir" ] || continue
        stale_pid=""
        [ -s "${stale_dir}/.active" ] && stale_pid=$(cat "${stale_dir}/.active" 2>/dev/null)
        if [ -n "$stale_pid" ] && kill -0 "$stale_pid" 2>/dev/null; then
            continue
        fi
        rm -rf -- "$stale_dir"
    done
    temp_dir=$(mktemp -d /var/tmp/.singbox-install.XXXXXX) || { _error "创建临时目录失败。"; return 1; }
    printf '%s\n' "$$" > "${temp_dir}/.active"
    digest_file="${temp_dir}/.archive.sha256"

    _info "正在下载并校验 sing-box 安装包..."
    if command -v sha256sum &>/dev/null; then
        wget -qO- "$download_url" | tee >(sha256sum > "$digest_file") | tar -xzf - -C "$temp_dir"
    else
        wget -qO- "$download_url" | tee >(openssl dgst -sha256 > "$digest_file") | tar -xzf - -C "$temp_dir"
    fi
    local -a stream_status=("${PIPESTATUS[@]}")
    if [ "${stream_status[0]:-1}" -ne 0 ] || [ "${stream_status[2]:-1}" -ne 0 ]; then
        _error "sing-box 安装包下载失败。"
        rm -rf "$temp_dir"
        return 1
    fi
    local digest_wait=0
    while [ ! -s "$digest_file" ] && [ "$digest_wait" -lt 50 ]; do
        sleep 0.1
        digest_wait=$((digest_wait + 1))
    done
    expected="${asset_digest#sha256:}"
    if command -v sha256sum &>/dev/null; then
        actual=$(awk '{print $1}' "$digest_file" 2>/dev/null)
    else
        actual=$(awk '{print $NF}' "$digest_file" 2>/dev/null)
    fi
    if [ -z "$expected" ] || [ -z "$actual" ] || [ "${expected,,}" != "${actual,,}" ]; then
        _error "sing-box 安装包 SHA-256 校验失败，已拒绝替换核心。"
        rm -rf "$temp_dir"
        return 1
    fi

    extracted_bin=$(find "$temp_dir" -name sing-box -type f 2>/dev/null | head -n 1)
    if [ -z "$extracted_bin" ]; then
        _error "解压后未找到 sing-box 二进制文件。"
        rm -rf "$temp_dir"
        return 1
    fi
    chmod 755 "$extracted_bin" || { rm -rf "$temp_dir"; return 1; }
    if ! "$extracted_bin" version >/dev/null 2>&1; then
        _error "下载的 sing-box 核心无法执行，已拒绝安装。"
        rm -rf "$temp_dir"
        return 1
    fi
    extracted_version=$("$extracted_bin" version 2>/dev/null | sed -n 's/^sing-box version \([^[:space:]]*\).*/\1/p' | head -n 1)
    if [ "$extracted_version" != "$release_version" ]; then
        _error "下载核心版本与官方发布不匹配：期望 v${release_version}，实际 v${extracted_version:-未知}。"
        rm -rf "$temp_dir"
        return 1
    fi

    if [ -s "$CONFIG_FILE" ]; then
        local validation_relay="$RELAY_CONFIG_FILE"
        if [ ! -s "$validation_relay" ]; then
            validation_relay="${temp_dir}/relay.json"
            printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$validation_relay"
        fi
        local validation_result
        if ! validation_result=$(_check_combined_config_files "$extracted_bin" "$CONFIG_FILE" "$validation_relay" 2>&1); then
            _error "新核心无法加载当前 config.json + relay.json，已取消更新："
            echo "$validation_result"
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    mkdir -p "$(dirname "$SINGBOX_BIN")" || { rm -rf "$temp_dir"; return 1; }
    staged_bin=$(mktemp "$(dirname "$SINGBOX_BIN")/.sing-box.new.XXXXXX") || { rm -rf "$temp_dir"; return 1; }
    rm -f -- "$staged_bin"
    if ! mv -f -- "$extracted_bin" "$staged_bin"; then
        if ! cp -- "$extracted_bin" "$staged_bin"; then
            rm -f -- "$staged_bin"; rm -rf -- "$temp_dir"; return 1
        fi
    fi
    chmod 755 "$staged_bin" || { rm -f -- "$staged_bin"; rm -rf -- "$temp_dir"; return 1; }

    SINGBOX_UPDATE_BACKUP=""
    SINGBOX_UPDATE_HAD_OLD="false"
    if [ -f "$SINGBOX_BIN" ]; then
        SINGBOX_UPDATE_HAD_OLD="true"
        SINGBOX_UPDATE_BACKUP="$(dirname "$SINGBOX_BIN")/.sing-box.rollback.$$"
        cp -p "$SINGBOX_BIN" "$SINGBOX_UPDATE_BACKUP" || {
            rm -f "$staged_bin"; rm -rf "$temp_dir"; return 1;
        }
    fi
    if ! mv -f "$staged_bin" "$SINGBOX_BIN"; then
        rm -f "$staged_bin" "$SINGBOX_UPDATE_BACKUP"
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"
    _release_install_cache
    SINGBOX_STAGED_VERSION="$release_version"
    _success "sing-box v${release_version} 已安全暂存: ${SINGBOX_BIN}"
}

_rollback_singbox_binary() {
    if [ "${SINGBOX_UPDATE_HAD_OLD:-false}" = "true" ] && [ -s "${SINGBOX_UPDATE_BACKUP:-}" ]; then
        mv -f "$SINGBOX_UPDATE_BACKUP" "$SINGBOX_BIN" && chmod 755 "$SINGBOX_BIN"
    elif [ "${SINGBOX_UPDATE_HAD_OLD:-false}" != "true" ]; then
        rm -f "$SINGBOX_BIN"
    fi
    SINGBOX_UPDATE_BACKUP=""
}

_commit_singbox_binary() {
    [ -n "${SINGBOX_UPDATE_BACKUP:-}" ] && rm -f "$SINGBOX_UPDATE_BACKUP"
    SINGBOX_UPDATE_BACKUP=""
}

_install_cloudflared() {
    if [ -x "${CLOUDFLARED_BIN}" ] && "${CLOUDFLARED_BIN}" --version >/dev/null 2>&1; then
        _info "cloudflared 已安装: $(${CLOUDFLARED_BIN} --version 2>&1 | head -n1)"
        return 0
    fi

    _info "正在安装依据环境所需的组件 (ca-certificates)..."
    _pkg_install ca-certificates

    _info "正在安装 cloudflared..."
    local arch=$(uname -m)
    local arch_tag
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='arm' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac

    local asset_name="cloudflared-linux-${arch_tag}"
    local asset_count asset_info download_url asset_digest expected actual
    if ! asset_info=$(curl -fsSL --retry 3 --connect-timeout 10 https://api.github.com/repos/cloudflare/cloudflared/releases/latest | jq -r --arg name "$asset_name" '
        [.assets[] | select(.name == $name)] as $matches
        | [($matches | length), ($matches[0].browser_download_url // ""), ($matches[0].digest // "")]
        | @tsv
    '); then
        _error "无法读取 cloudflared 官方发布信息。"
        return 1
    fi
    IFS=$'\t' read -r asset_count download_url asset_digest <<< "$asset_info"
    if [ "$asset_count" != "1" ]; then
        _error "cloudflared 官方发布中目标资产数量异常 (${asset_count:-无法解析})。"
        return 1
    fi
    if [[ "$download_url" != https://github.com/cloudflare/cloudflared/releases/download/* ]] \
        || [[ ! "$asset_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        _error "cloudflared 官方资产缺少可信下载地址或 API SHA-256 摘要，已拒绝安装。"
        return 1
    fi

    mkdir -p "$(dirname "$CLOUDFLARED_BIN")" || return 1
    local tmp_cloudflared
    tmp_cloudflared=$(mktemp "$(dirname "$CLOUDFLARED_BIN")/.cloudflared.new.XXXXXX") || return 1
    if ! wget -qO "$tmp_cloudflared" "$download_url"; then
        rm -f "$tmp_cloudflared"
        _error "cloudflared 下载失败!"
        return 1
    fi
    expected="${asset_digest#sha256:}"
    if command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "$tmp_cloudflared" | awk '{print $1}')
    else
        actual=$(openssl dgst -sha256 "$tmp_cloudflared" 2>/dev/null | awk '{print $NF}')
    fi
    if [ -z "$actual" ] || [ "${actual,,}" != "$expected" ]; then
        rm -f -- "$tmp_cloudflared"
        _error "cloudflared SHA-256 校验失败，已拒绝安装。"
        return 1
    fi
    chmod 755 "$tmp_cloudflared" || { rm -f "$tmp_cloudflared"; return 1; }
    if ! "$tmp_cloudflared" --version >/dev/null 2>&1; then
        rm -f "$tmp_cloudflared"
        _error "下载的 cloudflared 无法执行，已拒绝安装。"
        return 1
    fi
    mv -f "$tmp_cloudflared" "$CLOUDFLARED_BIN" || { rm -f "$tmp_cloudflared"; return 1; }

    _success "cloudflared 安装成功: $(${CLOUDFLARED_BIN} --version 2>&1 | head -n1)"
}

# --- Argo Tunnel 功能 ---

_prepare_argo_runtime_dir() {
    if [ -L "$RUNTIME_DIR" ]; then
        _error "Argo 运行目录不能是符号链接: $RUNTIME_DIR"
        return 1
    fi
    mkdir -p "$RUNTIME_DIR" || return 1
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || return 1
}

_argo_pid_file() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    printf '%s/argo-%s.pid\n' "$RUNTIME_DIR" "$port"
}

_argo_log_file() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    printf '/var/log/singbox_argo_%s.log\n' "$port"
}

_migrate_legacy_argo_state() {
    local port="$1" pid_file legacy_pid_file legacy_log_file legacy_pid=""
    pid_file=$(_argo_pid_file "$port") || return 1
    _prepare_argo_runtime_dir || return 1
    legacy_pid_file="/tmp/singbox_argo_${port}.pid"
    legacy_log_file="/tmp/singbox_argo_${port}.log"

    if _is_pid_file_running_cmd "$pid_file" "$CLOUDFLARED_BIN"; then
        rm -f -- "$legacy_pid_file" "$legacy_log_file"
        return 0
    fi
    rm -f -- "$pid_file"

    if [ -s "$legacy_pid_file" ] && [ ! -L "$legacy_pid_file" ]; then
        legacy_pid=$(cat "$legacy_pid_file" 2>/dev/null)
        if _is_pid_running_cmd "$legacy_pid" "$CLOUDFLARED_BIN"; then
            printf '%s\n' "$legacy_pid" > "$pid_file" || return 1
            chmod 600 "$pid_file" 2>/dev/null || { rm -f -- "$pid_file"; return 1; }
        fi
    fi
    rm -f -- "$legacy_pid_file" "$legacy_log_file"
}

_argo_domain_resolves() {
    local domain="$1" remote_ip="" dns_json=""
    [[ "$domain" =~ ^[A-Za-z0-9-]+\.trycloudflare\.com$ ]] || return 1

    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$domain" >/dev/null 2>&1 && return 0
        getent hosts "$domain" >/dev/null 2>&1 && return 0
    fi
    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$domain" >/dev/null 2>&1 && return 0
    fi

    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        dns_json=$(curl -fsS --connect-timeout 5 --max-time 10 \
            -H 'accept: application/dns-json' --get \
            --data-urlencode "name=${domain}" --data-urlencode 'type=A' \
            'https://1.1.1.1/dns-query' 2>/dev/null || true)
        printf '%s' "$dns_json" | jq -e '
            (.Status == 0) and any(.Answer[]?; (.type == 1 or .type == 28) and ((.data // "") | length > 0))
        ' >/dev/null 2>&1 && return 0
    fi

    remote_ip=$(curl -ksS --connect-timeout 5 --max-time 8 -o /dev/null \
        -w '%{remote_ip}' "https://${domain}/" 2>/dev/null || true)
    [ -n "$remote_ip" ]
}

_start_argo_tunnel() {
    local target_port="$1"
    local protocol="$2"
    local token="$3" # 可选，用于固定隧道
    local retry_count="${4:-0}"

    local pid_file log_file
    pid_file=$(_argo_pid_file "$target_port") || { _error "无效的 Argo 内部端口: $target_port"; return 1; }
    log_file=$(_argo_log_file "$target_port") || return 1
    _migrate_legacy_argo_state "$target_port" || return 1

    _info "正在启动 Argo 隧道 (端口: $target_port)..." >&2

    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file" 2>/dev/null)
        if _is_pid_running_cmd "$old_pid" "$CLOUDFLARED_BIN"; then
            _warning "检测到端口 $target_port 的 Argo 隧道已在运行 (PID: $old_pid)" >&2
            return 0
        fi
    fi

    rm -f -- "$pid_file" "$log_file"
    : > "$log_file" || return 1
    chmod 600 "$log_file" 2>/dev/null || return 1
    _sync_system_time

    if [ -n "$token" ]; then
        # --- Token 固定隧道模式 ---
        _info "启动固定隧道 (Token 模式)..." >&2

        nohup "${CLOUDFLARED_BIN}" tunnel --protocol http2 --no-autoupdate run --token "$token" > "${log_file}" 2>&1 &

        local cf_pid=$!
        printf '%s\n' "$cf_pid" > "${pid_file}"
        chmod 600 "$pid_file" 2>/dev/null || true

        sleep 5
        if ! _is_pid_running_cmd "$cf_pid" "$CLOUDFLARED_BIN"; then
             _error "cloudflared 进程已退出！" >&2
             _error "Token 可能无效，或者网络连接被拒绝。" >&2
             echo "--- 错误日志 (最后 20 行) ---" >&2
             cat "${log_file}" | tail -20 >&2
             echo "-----------------------------"
             rm -f -- "$pid_file"
             return 1
        fi
        _enable_argo_watchdog
        _success "Argo 固定隧道 (端口: $target_port) 启动成功!" >&2
        return 0
    else
        # --- URL 临时隧道模式 ---
        _info "启动临时隧道，指向 127.0.0.1:${target_port}..." >&2

        nohup "${CLOUDFLARED_BIN}" tunnel --protocol http2 --no-autoupdate --url "http://127.0.0.1:${target_port}" \
            --logfile "${log_file}" \
            > /dev/null 2>&1 &

        local cf_pid=$!
        printf '%s\n' "$cf_pid" > "${pid_file}"
        chmod 600 "$pid_file" 2>/dev/null || true

        _info "等待隧道建立 (最多30秒)..." >&2

        local tunnel_domain=""
        local wait_count=0
        local max_wait=30

        while [ $wait_count -lt $max_wait ]; do
            sleep 2
            wait_count=$((wait_count + 2))

            if ! _is_pid_running_cmd "$cf_pid" "$CLOUDFLARED_BIN"; then
                _error "cloudflared 进程已退出，请检查日志: ${log_file}" >&2
                cat "${log_file}" 2>/dev/null | tail -20 >&2
                return 1
            fi

            if [ -f "${log_file}" ]; then
                tunnel_domain=$(grep -oE 'https?://[a-zA-Z0-9-]+\.trycloudflare\.com' "${log_file}" 2>/dev/null | head -n 1 | sed -E 's|https?://||')
                if [ -n "$tunnel_domain" ]; then
                    break
                fi
            fi
            echo -n "." >&2
        done
        echo "" >&2

        if [ -n "$tunnel_domain" ]; then
            _info "域名已获取，正在等待 DNS 发布 (最多90秒)..." >&2
            local dns_wait=0 dns_ready=false
            while [ "$dns_wait" -lt 90 ]; do
                if _argo_domain_resolves "$tunnel_domain"; then
                    dns_ready=true
                    break
                fi
                if ! _is_pid_running_cmd "$cf_pid" "$CLOUDFLARED_BIN"; then
                    break
                fi
                sleep 5
                dns_wait=$((dns_wait + 5))
            done

            if [ "$dns_ready" != true ]; then
                _warn "Cloudflare 已分配临时域名，但 DNS 尚未发布，正在清理本次隧道。" >&2
                _is_pid_running_cmd "$cf_pid" "$CLOUDFLARED_BIN" && kill "$cf_pid" 2>/dev/null
                wait "$cf_pid" 2>/dev/null || true
                rm -f -- "$pid_file" "$log_file"
                if [ "$retry_count" -lt 1 ]; then
                    _warn "正在自动重新申请一次临时域名..." >&2
                    _start_argo_tunnel "$target_port" "$protocol" "" "$((retry_count + 1))"
                    return $?
                fi
                _error "Cloudflare 临时域名连续两次未完成 DNS 发布，请稍后重试。" >&2
                return 1
            fi

            _info "域名已发布，正在进行稳定性测试 (5秒)..." >&2
            sleep 5
            if ! _is_pid_running_cmd "$cf_pid" "$CLOUDFLARED_BIN"; then
                 _error "稳定性测试失败：cloudflared 进程异常退出。" >&2
                 cat "${log_file}" 2>/dev/null | tail -n 10 >&2
                 return 1
            fi

            _enable_argo_watchdog
            _success "Argo 临时隧道建立成功: ${tunnel_domain}" >&2
            echo "$tunnel_domain"
            return 0
        else
            _error "获取临时域名超时。请检查网络。日志最后几行：" >&2
            cat "${log_file}" 2>/dev/null | tail -n 5 >&2
            _is_pid_running_cmd "$cf_pid" "$CLOUDFLARED_BIN" && kill "$cf_pid" 2>/dev/null
            rm -f "${pid_file}"
            return 1
        fi
    fi
}

_stop_argo_tunnel() {
    local target_port="$1"
    local pid_file log_file
    pid_file=$(_argo_pid_file "$target_port") || return 1
    log_file=$(_argo_log_file "$target_port") || return 1
    _migrate_legacy_argo_state "$target_port" || return 1

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
            kill "$pid" 2>/dev/null
            _success "Argo 隧道 (端口: $target_port) 已停止"
        fi
    fi
    rm -f -- "$pid_file" "$log_file" "/tmp/singbox_argo_${target_port}.pid" "/tmp/singbox_argo_${target_port}.log"
}

_stop_all_argo_tunnels() {
    _info "正在停止所有 Argo 隧道..."
    local stopped_any=false
    local pid_file filename port

    if [ -s "$ARGO_METADATA_FILE" ]; then
        while IFS= read -r port; do
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            _stop_argo_tunnel "$port"
            stopped_any=true
        done < <(jq -r '.[].local_port // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
    fi

    for pid_file in "$RUNTIME_DIR"/argo-*.pid; do
        [ -e "$pid_file" ] || continue
        filename=$(basename "$pid_file")
        port=${filename#argo-}
        port=${port%.pid}
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        _stop_argo_tunnel "$port"
        stopped_any=true
    done
    for pid_file in /tmp/singbox_argo_*.pid; do
        [ -e "$pid_file" ] || continue
        filename=$(basename "$pid_file")
        port=${filename#singbox_argo_}
        port=${port%.pid}
        [[ "$port" =~ ^[0-9]+$ ]] || { rm -f -- "$pid_file"; continue; }
        _stop_argo_tunnel "$port"
        stopped_any=true
    done
    if [ "$stopped_any" = false ]; then
        _warn "未找到本脚本记录的 Argo PID 文件，未执行全局 cloudflared 清理。"
    fi
}

# ============================================================
# Cloudflare API 自动部署（固定隧道）
# 凭据: 邮箱 + Global API Key；自动完成三件事:
#   1) 创建命名隧道 (隧道名 = 二级域名前缀, 如 abc.example.com -> abc)
#   2) 写入云端 ingress (统一 http://127.0.0.1:8080)
#   3) 自动创建 DNS CNAME (橙云 proxied, 指向 <tunnel_id>.cfargotunnel.com)
# 删除节点/卸载时统一删除云端隧道与 DNS 记录。
# ============================================================
CF_EMAIL="" CF_KEY="" CF_ACCOUNT_ID=""

_cf_load_account() {
    [ -s "$CF_ACCOUNT_FILE" ] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_FILE" 2>/dev/null)
    CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_FILE" 2>/dev/null)
    CF_ACCOUNT_ID=$(jq -r '.account_id // ""' "$CF_ACCOUNT_FILE" 2>/dev/null)
    [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]
}

_cf_save_account() {
    mkdir -p "$SINGBOX_DIR" 2>/dev/null || return 1
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" --arg a "$CF_ACCOUNT_ID" \
        '{email: $e, api_key: $k, account_id: $a}' > "$CF_ACCOUNT_FILE" 2>/dev/null || return 1
    chmod 600 "$CF_ACCOUNT_FILE" 2>/dev/null || true
    return 0
}

_cf_verify_credentials() {
    local r
    r=$(curl -sS --connect-timeout 10 --max-time 30 \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
        -H "Content-Type: application/json" \
        "${CF_API_BASE}/zones?per_page=1" 2>/dev/null || true)
    printf '%s' "$r" | jq -e '.success == true' >/dev/null 2>&1
}

_prompt_cf_account() {
    if _cf_load_account; then
        local masked="${CF_KEY:0:6}...${CF_KEY: -4}"
        read -rp "检测到已保存的 Cloudflare 凭据 (${CF_EMAIL}, Key=${masked})，复用? (Y/n): " cf_reuse
        if [[ ! "${cf_reuse,,}" =~ ^(n|no)$ ]] && _cf_verify_credentials; then
            return 0
        fi
    fi
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL || return 1
        read -rsp "Cloudflare Global API Key: " CF_KEY || return 1
        echo ""
        if [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
            _warning "邮箱与 Global API Key 不能为空，请重新输入。"
            continue
        fi
        _info "正在校验 Cloudflare 凭据..."
        if _cf_verify_credentials; then
            _success "Cloudflare 凭据校验通过 (凭据已保存到 ${CF_ACCOUNT_FILE})"
            _cf_save_account || _warning "凭据保存失败，本次会话仍可继续。"
            return 0
        fi
        _error "Cloudflare 凭据校验失败，请重新输入 (Ctrl+C 退出)。"
    done
}

# 统一 CF API 调用入口 (需要 CF_EMAIL/CF_KEY 已就绪)
_cf_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(curl -sS --connect-timeout 10 --max-time 30 -X "$method"
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY"
        -H "Content-Type: application/json")
    [ -n "$data" ] && args+=(-d "$data")
    local r
    r=$("${args[@]}" "${CF_API_BASE}${endpoint}" 2>/dev/null) || true
    if ! printf '%s' "$r" | jq -e '.success == true' >/dev/null 2>&1; then
        local msg
        msg=$(printf '%s' "$r" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null)
        _error "Cloudflare API 错误 [$method $endpoint]: ${msg:-无响应或网络错误}"
        return 1
    fi
    printf '%s' "$r"
}

# 隧道名称: 取二级域名前缀 (abc.example.com -> abc ; a.b.c.example.com -> a)
_argo_tunnel_name_from_domain() {
    local domain="$1"
    domain="${domain%%.}"
    printf '%s' "$domain" | awk -F. '{print $1}' | tr -cd 'a-zA-Z0-9-_'
}

_cf_find_zone() {
    local domain="$1" zones best_name="" best_id="" best_acct="" zone_name zone_id acct_id
    zones=$(_cf_call GET "/zones?per_page=100") || return 1
    zones=$(printf '%s' "$zones" | jq -r '.result[] | "\(.name) \(.id) \(.account.id)"' 2>/dev/null)
    while read -r zone_name zone_id acct_id; do
        [ -n "$zone_name" ] || continue
        if [ "$domain" == "$zone_name" ] || [[ "$domain" == *".$zone_name" ]]; then
            if [ ${#zone_name} -gt ${#best_name} ]; then
                best_name="$zone_name"; best_id="$zone_id"; best_acct="$acct_id"
            fi
        fi
    done <<< "$zones"
    [ -n "$best_id" ] || return 1
    printf '%s %s\n' "$best_id" "$best_acct"
}

_cf_create_tunnel() {
    local tname="$1"
    [ -n "$CF_ACCOUNT_ID" ] || { _error "Cloudflare Account ID 为空，无法创建隧道。"; return 1; }
    printf '%s' "$(_cf_call POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
        "$(jq -n --arg n "$tname" '{name: $n, config_src: "cloudflare"}')")" \
        | jq -r '.result | "\(.id) \(.token)"'
}

_cf_set_ingress() {
    local tunnel_id="$1" domain="$2" port="$3"
    _cf_call PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
        "$(jq -n --arg h "$domain" --argjson p "$port" \
            '{config: {ingress: [{hostname: $h, service: ("http://127.0.0.1:" + ($p|tostring))}, {service: "http_status:404"}]}}')" >/dev/null
}

_cf_ensure_cname() {
    local zone_id="$1" domain="$2" tunnel_id="$3"
    local target="${tunnel_id}.cfargotunnel.com"
    local rec existing_id existing_content
    rec=$(_cf_call GET "/zones/${zone_id}/dns_records?type=CNAME&name=${domain}") || return 1
    existing_id=$(printf '%s' "$rec" | jq -r '.result[0].id // ""' 2>/dev/null)
    existing_content=$(printf '%s' "$rec" | jq -r '.result[0].content // ""' 2>/dev/null)
    if [ -n "$existing_id" ] && [ "$existing_content" == "$target" ]; then
        _info "DNS 解析已存在且指向正确: ${domain} -> ${target}"
        return 0
    fi
    if [ -n "$existing_id" ]; then
        _info "删除旧的 CNAME 记录 (${existing_content})..."
        _cf_call DELETE "/zones/${zone_id}/dns_records/${existing_id}" >/dev/null || true
    fi
    _cf_call POST "/zones/${zone_id}/dns_records" \
        "$(jq -n --arg n "$domain" --arg c "$target" '{type: "CNAME", name: $n, content: $c, proxied: true, ttl: 1}')" >/dev/null
    _success "DNS 解析已自动创建: ${domain} -> ${target} (proxied)"
}

_cf_delete_tunnel() {
    _cf_call DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${1}" >/dev/null
}

# 删除域名下同名 DNS 记录 (CNAME/A 等都清理)
_cf_delete_zone_records() {
    local zone_id="$1" domain="$2" rids rid
    rids=$(_cf_call GET "/zones/${zone_id}/dns_records?name=${domain}") || return 1
    rids=$(printf '%s' "$rids" | jq -r '.result[]?.id // empty' 2>/dev/null)
    [ -n "$rids" ] || { _info "未找到 ${domain} 的 DNS 记录。"; return 0; }
    while IFS= read -r rid; do
        [ -n "$rid" ] || continue
        if _cf_call DELETE "/zones/${zone_id}/dns_records/${rid}" >/dev/null 2>&1; then
            _success "DNS 记录已删除 (${domain})"
        fi
    done <<< "$rids"
    return 0
}

# 清理某固定隧道节点的云端资源 (隧道 + DNS)
_cf_cleanup_tunnel() {
    local tunnel_id="$1" zone_id="$2" domain="$3"
    if [ -z "$tunnel_id" ]; then
        _warning "该节点未记录隧道 ID (旧版 Token 部署)，已跳过云端删除，请手动在 CF 控制台删除。"
        return 0
    fi
    if ! _cf_load_account; then
        _warning "未找到已保存的 Cloudflare 凭据，已跳过云端删除 (隧道: ${tunnel_id})，请手动清理。"
        return 0
    fi
    _info "正在删除 Cloudflare 云端隧道 (${tunnel_id})..."
    if _cf_delete_tunnel "$tunnel_id" 2>/dev/null; then
        _success "云端隧道已删除。"
    else
        _warning "云端隧道删除失败 (可能已被手动删除)，继续本地清理。"
    fi
    if [ -n "$zone_id" ] && [ -n "$domain" ]; then
        _cf_delete_zone_records "$zone_id" "$domain" 2>/dev/null || _warning "DNS 记录删除失败，请手动检查。"
    fi
    return 0
}

# 按节点 tag 从元数据读取并清理云端资源
_cf_remove_for_node_key() {
    local tag="$1" ftype tunnel_id zone_id domain
    [ -n "$tag" ] || return 0
    [ -f "$ARGO_METADATA_FILE" ] || return 0
    ftype=$(jq -r --arg tag "$tag" '.[$tag].type // ""' "$ARGO_METADATA_FILE" 2>/dev/null)
    [ "$ftype" == "fixed" ] || return 0
    tunnel_id=$(jq -r --arg tag "$tag" '.[$tag].tunnel_id // ""' "$ARGO_METADATA_FILE" 2>/dev/null)
    zone_id=$(jq -r --arg tag "$tag" '.[$tag].zone_id // ""' "$ARGO_METADATA_FILE" 2>/dev/null)
    domain=$(jq -r --arg tag "$tag" '.[$tag].domain // ""' "$ARGO_METADATA_FILE" 2>/dev/null)
    _cf_cleanup_tunnel "$tunnel_id" "$zone_id" "$domain"
}

# ============================================================
# 统一 Argo 节点创建函数 (VLESS/Trojan)
# 参数: $1 = 协议类型 ("vless" 或 "trojan")
# ============================================================
_add_argo_node() {
    local protocol="$1"
    local protocol_label=""
    local proto_name=""
    case "$protocol" in
        vless) protocol_label="VLESS-WS"; proto_name="Vless" ;;
        trojan) protocol_label="Trojan-WS"; proto_name="Trojan" ;;
        *) _error "不支持的 Argo 协议: $protocol"; return 1 ;;
    esac

    _info "--- 创建 ${protocol_label} + Argo 隧道节点 ---"

    _install_cloudflared || return 1

    local port="" token="" tunnel_domain="" argo_type="temp" tunnel_id="" zone_id="" tunnel_name="" tr_tunnel=""

    read -p "请输入 WebSocket 路径 (回车随机生成): " ws_path
    if [ -z "$ws_path" ]; then
        ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
        _info "已生成随机路径: ${ws_path}"
    else
        [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
    fi

    local password=""
    if [ "$protocol" == "trojan" ]; then
        read -p "请输入 Trojan 密码 (回车随机生成): " password
        if [ -z "$password" ]; then
            password=$(${SINGBOX_BIN} generate rand --hex 16)
            _info "已生成随机密码: ${password}"
        fi
    fi

    echo ""
    echo "请选择隧道模式:"
    echo "  1. 临时隧道 (无需配置, 随机域名, 不稳定，重启失效)"
    echo "  2. 固定隧道 (需 CF 邮箱+Global API Key, 自动创建隧道和DNS, 稳定持久)"
    read -p "请选择 [1/2] (默认: 1): " tunnel_mode
    tunnel_mode=${tunnel_mode:-1}

    if [ "$tunnel_mode" == "2" ]; then
        argo_type="fixed"
        _info "您选择了 [固定隧道] 模式 (Cloudflare API 自动部署)。"

        if ! _prompt_cf_account; then
            _error "未获得有效的 Cloudflare 凭据，已取消创建。"
            return 1
        fi

        local pref_domain="" zinfo=""
        while true; do
            read -p "请输入绑定域名 (例如 abc.example.com): " pref_domain
            if [ -z "$pref_domain" ]; then
                _warning "域名不能为空，请重试。"
                continue
            fi
            if zinfo=$(_cf_find_zone "$pref_domain"); then
                zone_id=$(echo "$zinfo" | awk '{print $1}')
                CF_ACCOUNT_ID=$(echo "$zinfo" | awk '{print $2}')
                _cf_save_account || _warning "保存 Cloudflare 凭据失败。"
                _success "匹配到 Zone: $zone_id"
                break
            fi
            _error "无法在当前 Cloudflare 账号下匹配 Zone: ${pref_domain}，请确认域名已托管 (Ctrl+C 退出)"
        done
        tunnel_domain="$pref_domain"

        tunnel_name=$(_argo_tunnel_name_from_domain "$tunnel_domain")
        if [ -z "$tunnel_name" ]; then
            _error "无法从域名提取隧道名: ${tunnel_domain}"
            return 1
        fi
        _info "隧道名 (二级域名前缀): ${tunnel_name}"

        port="$ARGO_FIXED_PORT"
        if _check_port_conflict "$port" "tcp"; then
            _error "固定隧道统一使用本地端口 ${port}，但该端口已被占用。"
            _error "请先删除占用该端口的现有节点后再试。"
            return 1
        fi

        echo ""
        echo "配置预览:"
        echo "  内核:     sing-box (${protocol_label})"
        echo "  绑定域名: ${tunnel_domain}"
        echo "  隧道名:   ${tunnel_name} (二级域名前缀)"
        echo "  本地服务: http://127.0.0.1:${port} (sing-box 监听)"
        echo "  DNS:      服务器为您自动解析本隧道 (橙云, http://127.0.0.1:${port} 流量映射)"
        echo ""
        read -p "确认部署? (Y/n): " confirm_fix
        if [[ ! "${confirm_fix,,}" =~ ^(|y|yes)$ ]]; then
            _info "已取消部署。"
            return 1
        fi

        _info "创建 Cloudflare Tunnel (${tunnel_name})..."
        if ! tr_tunnel=$(_cf_create_tunnel "$tunnel_name"); then
            _error "创建隧道失败，已取消部署。"
            return 1
        fi
        tunnel_id=$(echo "$tr_tunnel" | awk '{print $1}')
        token=$(echo "$tr_tunnel" | awk '{print $2}')
        if [ -z "$tunnel_id" ] || [ -z "$token" ]; then
            _error "创建隧道返回数据异常，已取消部署。"
            return 1
        fi
        _success "隧道已创建: ${tunnel_name} (${tunnel_id})"

        _info "配置隧道入口 (ingress)..."
        if ! _cf_set_ingress "$tunnel_id" "$tunnel_domain" "$port"; then
            _error "配置 ingress 失败，正在回滚云端隧道..."
            _cf_delete_tunnel "$tunnel_id" 2>/dev/null || true
            return 1
        fi

        _info "自动添加 DNS 解析..."
        if ! _cf_ensure_cname "$zone_id" "$tunnel_domain" "$tunnel_id"; then
            _error "DNS 解析创建失败，正在回滚云端隧道..."
            _cf_delete_tunnel "$tunnel_id" 2>/dev/null || true
            return 1
        fi

        _success "云端配置完成: ${tunnel_domain} -> http://127.0.0.1:${port} (无需手动配置 CF 后台)"
    else
        _info "您选择了 [临时隧道] 模式。"

        read -p "请输入 Argo 内部监听端口 (回车随机生成): " input_port
        port="$input_port"

        while true; do
            if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
                _check_port_conflict "$port" "tcp" && port="" && continue
                _info "已使用监听端口: ${port}"
                break
            else
                [ -n "$port" ] && _warning "端口格式无效，将重新生成..."
                port=$(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 50001 + 10000 ))
                _info "正在尝试分配随机内部端口: ${port}..."
            fi
        done
    fi

    local default_prefix="Argo-Temp"
    if [ "$argo_type" == "fixed" ]; then
        default_prefix="Argo-Fixed"
    fi
    local default_name="${default_prefix}-${proto_name}-${port}"

    echo ""
    read -p "请输入节点名称 (默认: ${default_name}): " custom_name
    local name=${custom_name:-$default_name}

    local tag="argo-${protocol}-ws-${port}"
    local uuid=""
    local inbound_json=""

    if [ "$protocol" == "vless" ]; then
        uuid=$(${SINGBOX_BIN} generate uuid)
        inbound_json=$(jq -n \
            --arg t "$tag" \
            --arg p "$port" \
            --arg u "$uuid" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "type": "vless",
                "tag": $t,
                "listen": "127.0.0.1",
                "listen_port": ($p|tonumber),
                "users": [{"uuid": $u, "flow": ""}],
                "transport": {
                    "type": "ws",
                    "path": $wsp,
                    "max_early_data": $ed,
                    "early_data_header_name": $edh
                }
            }')
    elif [ "$protocol" == "trojan" ]; then
        inbound_json=$(jq -n \
            --arg t "$tag" \
            --arg p "$port" \
            --arg pw "$password" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "type": "trojan",
                "tag": $t,
                "listen": "127.0.0.1",
                "listen_port": ($p|tonumber),
                "users": [{"password": $pw}],
                "transport": {
                    "type": "ws",
                    "path": $wsp,
                    "max_early_data": $ed,
                    "early_data_header_name": $edh
                }
            }')
    fi

    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

    _manage_service "restart"
    sleep 2

    if [ "$argo_type" == "fixed" ]; then
        if ! _start_argo_tunnel "$port" "${protocol}-ws" "$token"; then
             _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"
             _manage_service "restart"
             _cf_cleanup_tunnel "$tunnel_id" "$zone_id" "$tunnel_domain" 2>/dev/null || true
             return 1
        fi
    else
        local real_domain=$(_start_argo_tunnel "$port" "${protocol}-ws")
        if [ -z "$real_domain" ] || [ "$real_domain" == "" ]; then
            _error "隧道启动失败，正在回滚配置..."
            _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"
            _manage_service "restart"
            return 1
        fi
        tunnel_domain="$real_domain"
    fi

    local credential_key="" credential_val=""
    if [ "$protocol" == "vless" ]; then
        credential_key="uuid"; credential_val="$uuid"
    else
        credential_key="password"; credential_val="$password"
    fi

    local argo_meta=$(jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg domain "$tunnel_domain" \
        --arg port "$port" \
        --arg cred_val "$credential_val" \
        --arg cred_key "$credential_key" \
        --arg path "$ws_path" \
        --arg protocol "${protocol}-ws" \
        --arg type "$argo_type" \
        --arg token "$token" \
        --arg tunnel_id "$tunnel_id" \
        --arg zone_id "$zone_id" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, domain: $domain, local_port: ($port|tonumber), ($cred_key): $cred_val, path: $path, protocol: $protocol, type: $type, token: $token, tunnel_id: $tunnel_id, zone_id: $zone_id, created_at: $created}}')

    if [ ! -f "$ARGO_METADATA_FILE" ]; then
        echo '{}' > "$ARGO_METADATA_FILE"
    fi
    _atomic_modify_json "$ARGO_METADATA_FILE" ". + $argo_meta"

    local proxy_json=""
    if [ "$protocol" == "vless" ]; then
        proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$tunnel_domain" \
            --arg u "$uuid" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "name": $n,
                "type": "vless",
                "server": $s,
                "port": 443,
                "uuid": $u,
                "tls": true,
                "udp": true,
                "skip-cert-verify": false,
                "network": "ws",
                "servername": $s,
                "ws-opts": {
                    "path": $wsp,
                    "max-early-data": $ed,
                    "early-data-header-name": $edh,
                    "headers": {
                        "Host": $s
                    }
                }
            }')
    elif [ "$protocol" == "trojan" ]; then
        proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$tunnel_domain" \
            --arg pw "$password" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "name": $n,
                "type": "trojan",
                "server": $s,
                "port": 443,
                "password": $pw,
                "udp": true,
                "skip-cert-verify": false,
                "network": "ws",
                "sni": $s,
                "ws-opts": {
                    "path": $wsp,
                    "max-early-data": $ed,
                    "early-data-header-name": $edh,
                    "headers": {
                        "Host": $s
                    }
                }
            }')
    fi

    if ! _add_node_to_yaml "$proxy_json"; then
        _stop_argo_tunnel "$port"
        _atomic_modify_json "$CONFIG_FILE" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag" >/dev/null 2>&1 || true
        _atomic_modify_json "$ARGO_METADATA_FILE" 'del(.[$tag])' --arg tag "$tag" >/dev/null 2>&1 || true
        return 1
    fi

    if ! _enable_argo_watchdog; then
        _stop_argo_tunnel "$port"
        _atomic_modify_json "$CONFIG_FILE" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag" >/dev/null 2>&1 || true
        _atomic_modify_json "$ARGO_METADATA_FILE" 'del(.[$tag])' --arg tag "$tag" >/dev/null 2>&1 || true
        _remove_node_from_yaml "$name" >/dev/null 2>&1 || true
        _manage_service "restart" >/dev/null 2>&1 || true
        return 1
    fi

    echo ""
    _success "${protocol_label} + Argo 节点创建成功!"
    echo "-------------------------------------------"
    echo -e "节点名称: ${GREEN}${name}${NC}"
    echo -e "隧道类型: ${CYAN}${argo_type}${NC}"
    echo -e "隧道域名: ${CYAN}${tunnel_domain}${NC}"
    echo -e "本地端口: ${port}"
    echo "-------------------------------------------"

    if [ "$protocol" == "vless" ]; then
        _show_node_link "vless-ws" "$name" "$tunnel_domain" "443" "$tag" "$uuid" "$ws_path"
    else
        _show_node_link "trojan-ws" "$name" "$tunnel_domain" "443" "$tag" "$password" "$ws_path"
    fi

    echo "-------------------------------------------"
    if [ "$argo_type" == "temp" ]; then
        _warning "注意: 临时隧道每次重启域名会变化！"
    fi
}

_add_argo_vless_ws() { _add_argo_node "vless"; }

_add_argo_trojan_ws() { _add_argo_node "trojan"; }

_view_argo_nodes() {
    _info "--- Argo 隧道节点信息 ---"

    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点。"
        return
    fi

    echo "==================================================="
    jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.type)|\(.value.protocol)|\(.value.local_port)|\(.value.domain)|\(.value.uuid // "")|\(.value.path // "")|\(.value.password // "")"' "$ARGO_METADATA_FILE" | \
    while IFS='|' read -r tag name argo_type protocol port domain uuid path password; do
        echo -e "节点: ${GREEN}${name}${NC}"
        echo -e "  协议: ${protocol}"
        echo -e "  端口: ${port}"

        local pid_file
        _migrate_legacy_argo_state "$port" >/dev/null 2>&1 || true
        pid_file=$(_argo_pid_file "$port")
        local state="${RED}已停止${NC}"
        local running_domain=""

        local pid=""
        if [ -f "$pid_file" ]; then pid=$(cat "$pid_file" 2>/dev/null); fi
        if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
             state="${GREEN}运行中${NC} (PID: $pid)"
             if [ "$argo_type" == "temp" ] || [ -z "$domain" ] || [ "$domain" == "null" ]; then
                  local log_file
                  log_file=$(_argo_log_file "$port")
                  local temp_domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -1 | sed 's|https://||')
                   [ -n "$temp_domain" ] && domain="$temp_domain"
             fi
             running_domain="$domain"
        fi

        if [ -n "$domain" ] && [ "$domain" != "null" ]; then
             local link=""

             link=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$ARGO_METADATA_FILE")

               if [ -z "$link" ] || [ "$link" == "null" ]; then
                   local safe_name=$(_url_encode "$name")
                   local ed_path=$(_ws_path_with_early_data "$path")
                   local safe_path=$(_url_encode "$ed_path")

                   if [[ "$protocol" == "vless-ws" ]]; then
                       link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${safe_path}&sni=${domain}#${safe_name}"
                 elif [[ "$protocol" == "trojan-ws" ]]; then
                     local safe_pw=$(_url_encode "$password")
                     link="trojan://${safe_pw}@${domain}:443?security=tls&type=ws&host=${domain}&path=${safe_path}&sni=${domain}#${safe_name}"
                 fi
             fi

             if [ -n "$link" ]; then
                  echo -e "  ${YELLOW}链接:${NC} $link"
             fi
        fi
        echo "-------------------------------------------"
    done

    echo -e "${YELLOW}提示: 请使用 [7] 重启隧道 来刷新所有节点状态或获取新临时域名。${NC}"
    echo "==================================================="
}

_delete_argo_node() {
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点可删除。"
        return
    fi

    _info "--- 删除 Argo 隧道节点 ---"

    local i=1
    local keys=()
    local names=()
    local ports=()

    while IFS='|' read -r key name port; do
        keys+=("$key")
        names+=("$name")
        ports+=("$port")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)"' "$ARGO_METADATA_FILE")

    if [ ${#keys[@]} -eq 0 ]; then
         _warning "读取元数据失败。"
         return
    fi

    echo " 0) 返回"
    read -p "请选择要删除的节点: " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "${#keys[@]}" ]; then
        _error "无效输入"
        return
    fi

    if [ "$choice" -eq 0 ]; then return; fi

    local idx=$((choice - 1))
    local selected_key="${keys[$idx]}"
    local selected_name="${names[$idx]}"
    local selected_port="${ports[$idx]}"

    _info "正在删除节点: ${selected_name} (端口: ${selected_port})..."

    _cf_remove_for_node_key "$selected_key"

    _stop_argo_tunnel "$selected_port"

    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$selected_key\"))"

    _atomic_modify_json "$ARGO_METADATA_FILE" 'del(.[$tag])' --arg tag "$selected_key"

    _remove_node_from_yaml "$selected_name"

    if [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        _disable_argo_watchdog
    fi

    _manage_service "restart"

    _success "节点 ${selected_name} 已删除！"
}

_restart_argo_tunnel_menu() {
    _info "--- 重启 Argo 隧道 ---"

     if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点。"
        return
    fi

    local i=1
    local keys=()
    local names=()
    local ports=()
    local protocols=()
    local types=()
    local tokens=()

    while IFS='|' read -r key name port proto type token; do
        keys+=("$key")
        names+=("$name")
        ports+=("$port")
        protocols+=("$proto")
        types+=("$type")
        tokens+=("$token")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)|\(.value.protocol)|\(.value.type)|\(.value.token)"' "$ARGO_METADATA_FILE")

    echo " a) 重启所有节点"
    echo " 0) 返回"
    read -p "请选择: " choice

    local selected_indices=()
    if [ "$choice" == "a" ]; then
        for ((j=0; j<${#keys[@]}; j++)); do selected_indices+=("$j"); done
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#keys[@]}" ]; then
        selected_indices+=($((choice - 1)))
    else
        if [ "$choice" -ne 0 ]; then _error "无效输入"; fi
        return
    fi

    local names=() ports=() protocols=() types=() tokens=() tags=() uuids=() passwords=() paths=()
    while IFS='|' read -r key name port proto type token uuid pw path; do
        tags+=("$key")
        names+=("$name")
        ports+=("$port")
        protocols+=("$proto")
        types+=("$type")
        tokens+=("$token")
        uuids+=("$uuid")
        passwords+=("$pw")
        paths+=("$path")
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)|\(.value.protocol)|\(.value.type)|\(.value.token // "")|\(.value.uuid // "")|\(.value.password // "")|\(.value.path // "")"' "$ARGO_METADATA_FILE")

    for i in "${!selected_indices[@]}"; do
        local idx="${selected_indices[$i]}"
        local tag="${tags[$idx]}"
        local name="${names[$idx]}"
        local port="${ports[$idx]}"
        local proto_full="${protocols[$idx]}"
        local type="${types[$idx]}"
        local token="${tokens[$idx]}"
        local uuid="${uuids[$idx]}"
        local password="${passwords[$idx]}"
        local ws_path="${paths[$idx]}"

        local proto_short="vless"
        [[ "$proto_full" == "trojan-ws" ]] && proto_short="trojan"

        _info "正在重启: $name (端口: $port)..."

        _stop_argo_tunnel "$port"
        sleep 1

        local new_domain=""
        if [ "$type" == "fixed" ]; then
            if _start_argo_tunnel "$port" "$proto_short-ws" "$token"; then
                 new_domain=$(jq -r --arg tag "$tag" '.[$tag].domain // empty' "$ARGO_METADATA_FILE")
            else
                 _error "固定隧道重启失败: $name"
            fi
        else
            new_domain=$(_start_argo_tunnel "$port" "$proto_short-ws")
            if [ -n "$new_domain" ]; then
                 _atomic_modify_json "$ARGO_METADATA_FILE" '.[$tag].domain = $domain' \
                     --arg tag "$tag" --arg domain "$new_domain"
                 _success "更新临时域名: $new_domain"

                 if [[ "$proto_full" == "vless-ws" ]]; then
                     _show_node_link "vless-ws" "$name" "$new_domain" "443" "$tag" "$uuid" "$ws_path" >/dev/null
                 else
                     _show_node_link "trojan-ws" "$name" "$new_domain" "443" "$tag" "$password" "$ws_path" >/dev/null
                 fi
            else
                 _error "临时隧道重启失败: $name"
            fi
        fi
    done
    _success "操作完成。"
}

# --- Argo 守护进程逻辑 ---

_argo_keepalive() {
    _prepare_argo_runtime_dir || return 1
    command -v flock >/dev/null 2>&1 || { _error "缺少 flock，Argo 守护任务已拒绝无锁运行。"; return 1; }
    exec 7>"${RUNTIME_DIR}/argo-keepalive.lock" || return 1
    flock -n 7 || { exec 7>&-; return 0; }

    local max_size=$((10 * 1024 * 1024))
    local log_size
    for log in "$LOG_FILE" "$ARGO_LOG_FILE"; do
        log_size=0
        [ -f "$log" ] && log_size=$(wc -c < "$log" 2>/dev/null || echo 0)
        if [[ "$log_size" =~ ^[0-9]+$ ]] && [ "$log_size" -ge "$max_size" ]; then
            local log_tmp
            log_tmp=$(mktemp "${log}.tmp.XXXXXX") || continue
            if tail -n 1000 "$log" > "$log_tmp"; then
                chmod 600 "$log_tmp" 2>/dev/null || true
                mv -f "$log_tmp" "$log"
            else
                rm -f "$log_tmp"
            fi
        fi
    done

    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        flock -u 7 2>/dev/null || true
        exec 7>&-
        return
    fi

    local entry tag port type token protocol name uuid password path
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        tag=$(jq -r '.key // empty' <<< "$entry")
        port=$(jq -r '.value.local_port // empty' <<< "$entry")
        type=$(jq -r '.value.type // ""' <<< "$entry")
        token=$(jq -r '.value.token // ""' <<< "$entry")
        protocol=$(jq -r '.value.protocol // "vless-ws"' <<< "$entry")
        name=$(jq -r '.value.name // ""' <<< "$entry")
        uuid=$(jq -r '.value.uuid // ""' <<< "$entry")
        password=$(jq -r '.value.password // ""' <<< "$entry")
        path=$(jq -r '.value.path // ""' <<< "$entry")
        [ -z "$tag" ] && continue
        [[ "$port" =~ ^[0-9]+$ ]] || {
            logger "sing-box-watchdog: Ignoring invalid Argo metadata entry: $tag"
            continue
        }

        local pid_file
        _migrate_legacy_argo_state "$port" >/dev/null 2>&1 || true
        pid_file=$(_argo_pid_file "$port")
        local is_running=false

        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
                is_running=true
            fi
        fi

        if [ "$is_running" = false ]; then
            logger "sing-box-watchdog: Detected dead tunnel for $tag (Port: $port). Restarting..."

            local proto_short="vless"
            [[ "$protocol" == "trojan-ws" ]] && proto_short="trojan"

            if [ "$type" == "fixed" ] && [ -n "$token" ]; then
                 if _start_argo_tunnel "$port" "$proto_short-ws" "$token"; then
                     logger "sing-box-watchdog: Fixed tunnel $tag restarted successfully."
                 else
                     logger "sing-box-watchdog: Failed to restart fixed tunnel $tag."
                 fi
            else
                 local new_domain=$(_start_argo_tunnel "$port" "$proto_short-ws")
                 if [ -n "$new_domain" ]; then
                      _atomic_modify_json "$ARGO_METADATA_FILE" '.[$tag].domain = $domain' \
                          --arg tag "$tag" --arg domain "$new_domain"
                      logger "sing-box-watchdog: Temp tunnel $tag restarted with new domain: $new_domain"

                      if [[ "$protocol" == "vless-ws" ]]; then
                          _show_node_link "vless-ws" "$name" "$new_domain" "443" "$tag" "$uuid" "$path" >/dev/null
                      else
                          _show_node_link "trojan-ws" "$name" "$new_domain" "443" "$tag" "$password" "$path" >/dev/null
                      fi
                 else
                      logger "sing-box-watchdog: Failed to restart temp tunnel $tag."
                 fi
            fi
        fi
    done < <(jq -c 'to_entries[]' "$ARGO_METADATA_FILE" 2>/dev/null)
    flock -u 7 2>/dev/null || true
    exec 7>&-
}

_ensure_argo_cron() {
    local cron_pkg="cron"
    local services=(cron crond cronie)
    local service_name started=false

    if command -v apk &>/dev/null; then
        cron_pkg="dcron"
        services=(dcron crond)
    elif ! command -v apt-get &>/dev/null; then
        cron_pkg="cronie"
        services=(crond cronie)
    fi

    if ! command -v crontab &>/dev/null; then
        _info "正在按需安装 Argo 守护依赖: ${cron_pkg}..."
        if ! _pkg_install "$cron_pkg" || ! command -v crontab &>/dev/null; then
            _error "安装 Argo 守护依赖失败，未创建不受守护的隧道节点。"
            return 1
        fi
    fi

    case "${INIT_SYSTEM:-}" in
        systemd)
            for service_name in "${services[@]}"; do
                if systemctl enable --now "${service_name}.service" >/dev/null 2>&1; then
                    started=true
                    break
                fi
            done
            ;;
        openrc)
            for service_name in "${services[@]}"; do
                if rc-service "$service_name" start >/dev/null 2>&1; then
                    rc-update add "$service_name" default >/dev/null 2>&1 || true
                    started=true
                    break
                fi
            done
            ;;
        *)
            if command -v service &>/dev/null; then
                for service_name in "${services[@]}"; do
                    if service "$service_name" start >/dev/null 2>&1; then
                        started=true
                        break
                    fi
                done
            fi
            ;;
    esac

    if [ "$started" != true ]; then
        _error "Cron 服务启动失败，无法启用 Argo 自动守护。"
        return 1
    fi
}

_enable_argo_watchdog() {
    local job="* * * * * bash ${SELF_SCRIPT_PATH} keepalive >/dev/null 2>&1"

    _ensure_argo_cron || return 1
    if crontab -l 2>/dev/null | grep -Fq "$job"; then
        return 0
    fi

    _info "正在添加后台守护进程 (Watchdog)..."
    if (crontab -l 2>/dev/null; echo "$job") | crontab -; then
        _success "守护进程已启用！(每分钟检查并自动修复失效隧道)"
        return 0
    fi

    _error "添加 Crontab 失败，未创建不受守护的隧道节点。"
    return 1
}

_disable_argo_watchdog() {
    local job="bash ${SELF_SCRIPT_PATH} keepalive"

    if crontab -l 2>/dev/null | grep -Fq "$job"; then
        _info "正在移除后台守护进程..."
        crontab -l 2>/dev/null | grep -Fv "$job" | crontab -
        _success "守护进程已移除。"
    fi
}

_uninstall_argo() {
    _warning "！！！警告！！！"
    _warning "本操作将删除所有 Argo 隧道节点和 cloudflared 程序。"
    echo ""
    echo "即将删除的内容："
    echo -e "  ${RED}-${NC} cloudflared 程序: ${CLOUDFLARED_BIN}"
    echo -e "  ${RED}-${NC} 所有 Argo 日志文件和元数据文件"
    echo -e "  ${RED}-${NC} 固定隧道的云端资源 (Cloudflare Tunnel 与其 DNS 解析记录)"

    if [ -f "$ARGO_METADATA_FILE" ]; then
        local argo_count=$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null || echo "0")
        echo -e "  ${RED}-${NC} Argo 节点数量: ${argo_count} 个"
    fi

    echo ""
    read -p "$(echo -e ${YELLOW}"确定要卸载 Argo 服务吗? (y/N): "${NC})" confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        _info "卸载已取消。"
        return
    fi

    _info "正在卸载 Argo 服务..."

    _stop_all_argo_tunnels

    if [ -f "$ARGO_METADATA_FILE" ]; then
        local tags=()
        mapfile -t tags < <(jq -r 'keys[]' "$ARGO_METADATA_FILE" 2>/dev/null)
        local tag node_name
        for tag in "${tags[@]}"; do
             if [ -n "$tag" ]; then
                _info "正在删除 Argo 隧道: $tag ..."
                _cf_remove_for_node_key "$tag" 2>/dev/null || true
                node_name=$(jq -r --arg tag "$tag" '.[$tag].name // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
                _atomic_modify_json "$ARGO_METADATA_FILE" 'del(.[$tag])' --arg tag "$tag" 2>/dev/null
                _atomic_modify_json "$CONFIG_FILE" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag"

                if [ -n "$node_name" ] && [ "$node_name" != "null" ]; then
                    _remove_node_from_yaml "$node_name"
                fi
             fi
        done
    fi

    _disable_argo_watchdog

    _info "正在清理 cloudflared 文件及服务..."

    if command -v systemctl &>/dev/null; then
        systemctl stop cloudflared >/dev/null 2>&1
        systemctl disable cloudflared >/dev/null 2>&1
    fi

    _stop_all_argo_tunnels 2>/dev/null

    rm -f "$RUNTIME_DIR"/argo-*.pid /var/log/singbox_argo_*.log
    rm -f /tmp/singbox_argo_*.pid /tmp/singbox_argo_*.log
    rm -f "${CLOUDFLARED_BIN}" "${ARGO_METADATA_FILE}" "${CF_ACCOUNT_FILE}"
    rm -rf "/etc/cloudflared"

    _manage_service "restart"

    _success "Argo 服务已完全卸载！"
    _success "已释放 cloudflared 占用的空间。"
}

_view_argo_logs() {
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        _warning "当前没有任何 Argo 隧道节点。"
        return
    fi

    _info "--- 选择要查看日志的 Argo 隧道 ---"
    local tags=()
    mapfile -t tags < <(jq -r 'keys[]' "$ARGO_METADATA_FILE")
    local i=1
    local tag_list=()
    local tag name port
    for tag in "${tags[@]}"; do
        name=$(jq -r --arg tag "$tag" '.[$tag].name // empty' "$ARGO_METADATA_FILE")
        port=$(jq -r --arg tag "$tag" '.[$tag].local_port // empty' "$ARGO_METADATA_FILE")
        echo "  ${i}) ${name} (端口: ${port})"
        tag_list[$i]=$tag
        ((i++))
    done
    echo "  0) 返回上级菜单"
    read -p "请输入选项: " log_choice
    [[ "$log_choice" == "0" || -z "$log_choice" ]] && return

    local selected_tag=${tag_list[$log_choice]}
    if [ -n "$selected_tag" ]; then
        port=$(jq -r --arg tag "$selected_tag" '.[$tag].local_port // empty' "$ARGO_METADATA_FILE")
        local log_file
        log_file=$(_argo_log_file "$port")
        if [ -f "$log_file" ]; then
            _info "正在查看隧道日志 [${selected_tag}]，按 Ctrl+C 退出。"
            tail -f "$log_file"
        else
            _error "日志文件不存在: ${log_file}"
        fi
    else
        _error "无效选项"
    fi
}

_sync_argo_early_data() {
    local config_updated=false
    local links_updated=false
    local yaml_updated=false

    export WS_ED="$WS_EARLY_DATA_SIZE"
    export WS_EDH="$WS_EARLY_DATA_HEADER"

    if [ -s "$CONFIG_FILE" ] && jq -e 'any(.inbounds[]?; ((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws") and (((.transport.max_early_data // 0) != (env.WS_ED | tonumber)) or ((.transport.early_data_header_name // "") != env.WS_EDH))))' "$CONFIG_FILE" >/dev/null 2>&1; then
        _atomic_modify_json "$CONFIG_FILE" '(.inbounds[] | select((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws")) | .transport.max_early_data) = (env.WS_ED | tonumber) | (.inbounds[] | select((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws")) | .transport.early_data_header_name) = env.WS_EDH' || return 1
        config_updated=true
    fi

    if [ -s "$ARGO_METADATA_FILE" ]; then
        while IFS=$'\t' read -r tag protocol name domain uuid password path share_link; do
            [ -z "$tag" ] && continue
            [[ "$protocol" != "vless-ws" && "$protocol" != "trojan-ws" ]] && continue
            [[ -z "$domain" || "$domain" == "null" ]] && continue

            if [ -s "$CLASH_YAML_FILE" ] && [ -x "$YQ_BINARY" ] && [ -n "$name" ] && [ "$name" != "null" ]; then
                export PROXY_NAME="$name"
                local yaml_needs_update
                yaml_needs_update=$(${YQ_BINARY} eval '.proxies[] | select(.name == env(PROXY_NAME) and .network == "ws" and (((.["ws-opts"]["max-early-data"] // "") | tostring) != strenv(WS_ED) or (.["ws-opts"]["early-data-header-name"] // "") != env(WS_EDH))) | .name' "$CLASH_YAML_FILE" 2>/dev/null | head -n 1)
                if [ -n "$yaml_needs_update" ] && [ "$yaml_needs_update" != "null" ]; then
                    _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == env(PROXY_NAME) and .network == "ws") | .["ws-opts"]["max-early-data"]) = (env.WS_ED | tonumber) | (.proxies[] | select(.name == env(PROXY_NAME) and .network == "ws") | .["ws-opts"]["early-data-header-name"]) = env(WS_EDH)' >/dev/null 2>&1 && yaml_updated=true
                fi
            fi

            if [[ "$share_link" == *"ed%3D${WS_EARLY_DATA_SIZE}"* || "$share_link" == *"ed=${WS_EARLY_DATA_SIZE}"* ]]; then
                continue
            fi

            if [[ "$protocol" == "vless-ws" && -n "$uuid" && "$uuid" != "null" ]]; then
                _show_node_link "vless-ws" "$name" "$domain" "443" "$tag" "$uuid" "$path" >/dev/null
                links_updated=true
            elif [[ "$protocol" == "trojan-ws" && -n "$password" && "$password" != "null" ]]; then
                _show_node_link "trojan-ws" "$name" "$domain" "443" "$tag" "$password" "$path" >/dev/null
                links_updated=true
            fi
        done < <(jq -r 'to_entries[] | [.key, (.value.protocol // "vless-ws"), (.value.name // ""), (.value.domain // ""), (.value.uuid // ""), (.value.password // ""), (.value.path // "/"), (.value.share_link // "")] | @tsv' "$ARGO_METADATA_FILE" 2>/dev/null)
    fi

    if [ "$config_updated" = true ]; then
        _info "已为既有 Argo WS 节点补齐 Early Data 配置，正在重启 sing-box..."
        _manage_service restart
    elif [ "$links_updated" = true ] || [ "$yaml_updated" = true ]; then
        _info "已同步既有 Argo WS 节点的 Early Data 客户端配置。"
    fi
}

_argo_menu() {
    _sync_argo_early_data
    while true; do
        clear
        echo -e "${CYAN}"
        echo '  ╔═══════════════════════════════════════╗'
        echo '  ║           Argo 隧道节点管理           ║'
        echo '  ╚═══════════════════════════════════════╝'
        echo -e "${NC}"

        echo -e "  ${CYAN}【创建节点】${NC}"
        echo -e "    ${GREEN}[1]${NC} 创建 VLESS-WS + Argo 节点"
        echo -e "    ${GREEN}[2]${NC} 创建 Trojan-WS + Argo 节点"
        echo ""

        echo -e "  ${CYAN}【节点管理】${NC}"
        echo -e "    ${GREEN}[3]${NC} 查看 Argo 节点信息"
        echo -e "    ${GREEN}[4]${NC} 查看 Argo 隧道日志"
        echo -e "    ${GREEN}[5]${NC} 删除 Argo 节点"
        echo ""

        echo -e "  ${CYAN}【隧道控制】${NC}"
        echo -e "    ${RED}[6]${NC} 卸载 Argo 服务"
        echo -e "    ${GREEN}[7]${NC} 重启 Argo 隧道"
        echo ""

        echo -e "  ─────────────────────────────────────────"
        echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
        echo ""

        read -p "  请输入选项 [0-7]: " choice

        case $choice in
            1) _add_argo_vless_ws ;;
            2) _add_argo_trojan_ws ;;
            3) _view_argo_nodes ;;
            4) _view_argo_logs ;;
            5) _delete_argo_node ;;
            6) _uninstall_argo ;;
            7) _restart_argo_tunnel_menu ;;
            0) break ;;
            *) _error "无效选项" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# --- 服务与配置管理 ---

_create_systemd_service() {
    local mem_limit_mb=$(_get_mem_limit)

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Environment="GOMEMLIMIT=${mem_limit_mb}MiB"
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE} -c ${SINGBOX_DIR}/relay.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

_create_openrc_service() {
    touch "${LOG_FILE}"
    local mem_limit_mb=$(_get_mem_limit)

    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

description="sing-box service"
export GOMEMLIMIT="${mem_limit_mb}MiB"
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE} -c ${SINGBOX_DIR}/relay.json"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0

pidfile="${PID_FILE}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

start_pre() {
    checkpath -d -m 0700 ${RUNTIME_DIR}
}

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$SERVICE_FILE"
}

_create_service_files() {

    _info "正在创建 ${INIT_SYSTEM} 服务文件..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        _create_systemd_service
        systemctl daemon-reload
        systemctl enable sing-box
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        touch "$LOG_FILE"
        _create_openrc_service
        rc-update add sing-box default
    elif [ "$INIT_SYSTEM" == "direct" ]; then
        touch "$LOG_FILE"
        _info "当前容器没有 systemd/openrc，将使用 direct 后台模式管理 sing-box。"
        return 0
    fi
    _success "${INIT_SYSTEM} 服务创建并启用成功。"
}

_cleanup_runtime_logs() {
    local state_file="${SINGBOX_DIR}/.last_log_cleanup"
    local now last
    now=$(date +%s 2>/dev/null) || return 1
    last=$(cat "$state_file" 2>/dev/null)

    if ! [[ "$last" =~ ^[0-9]+$ ]]; then
        last=0
    fi
    [ $((now - last)) -lt 172800 ] && return 0

    local log
    for log in "$LOG_FILE" "$ARGO_LOG_FILE" /var/log/singbox_argo_*.log; do
        [ -f "$log" ] && : > "$log"
    done
    printf '%s\n' "$now" > "$state_file"
}

_setup_log_cleanup() {
    command -v crontab >/dev/null 2>&1 || {
        _warning "未找到 crontab，无法启用每 2 天自动清理日志。"
        return 1
    }

    local tag="# sing-box-log-cleanup"
    local job="17 * * * * bash ${SELF_SCRIPT_PATH} cleanup-logs >/dev/null 2>&1 ${tag}"
    local current
    current=$(crontab -l 2>/dev/null || true)
    if ! printf '%s\n' "$current" | grep -Fq "$tag"; then
        { printf '%s\n' "$current"; printf '%s\n' "$job"; } | sed '/^$/d' | crontab - || return 1
    fi
    _cleanup_runtime_logs
}

_remove_log_cleanup() {
    local tag="# sing-box-log-cleanup"
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$tag"; then
        crontab -l 2>/dev/null | grep -Fv "$tag" | crontab -
    fi
    rm -f "${SINGBOX_DIR}/.last_log_cleanup"
}

_view_log() {
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        _info "按 Ctrl+C 退出日志查看。"
        journalctl -u sing-box -f --no-pager
    else
        if [ ! -f "$LOG_FILE" ]; then
            _warning "日志文件 ${LOG_FILE} 不存在。"
            return
        fi
        _info "按 Ctrl+C 退出日志查看 (日志文件: ${LOG_FILE})。"
        tail -f "$LOG_FILE"
    fi
}

_uninstall() {
    _warning "！！！警告！！！"
    _warning "本操作将停止并禁用 sing-box 服务，"
    _warning "删除所有相关文件 (包括二进制、脚本、别名及配置文件)。"

    echo ""
    echo "即将删除以下内容："
    echo -e "  ${RED}-${NC} 主配置与脚本目录: ${SINGBOX_DIR}"
    echo -e "  ${RED}-${NC} sing-box 二进制: ${SINGBOX_BIN}"
    echo -e "  ${RED}-${NC} yq 二进制: ${YQ_BINARY}"
    [ -f "${CLOUDFLARED_BIN}" ] && echo -e "  ${RED}-${NC} cloudflared 二进制: ${CLOUDFLARED_BIN}"
    echo -e "  ${RED}-${NC} 系统别名: /usr/local/bin/sb"
    echo -e "  ${RED}-${NC} 管理脚本: ${SELF_SCRIPT_PATH}"
    echo ""

    read -p "$(echo -e ${YELLOW}"确定要执行卸载吗? (y/N): "${NC})" confirm_main
    [[ "$confirm_main" != "y" && "$confirm_main" != "Y" ]] && _info "卸载已取消。" && return

    _disable_argo_watchdog 2>/dev/null || true
    _stop_all_argo_tunnels 2>/dev/null || true

    _manage_service "stop" >/dev/null 2>&1 || true
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl disable --now sing-box >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-update del sing-box default >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box "$PID_FILE"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed sing-box.service >/dev/null 2>&1 || true
    fi

    # 先用元数据+已存凭据清理云端固定隧道与 DNS 记录 (必须在删除配置目录之前)
    _info "正在清理 Cloudflare 云端固定隧道资源..."
    if [ -f "$ARGO_METADATA_FILE" ]; then
        while IFS= read -r _mtag; do
            [[ -n "$_mtag" ]] && _cf_remove_for_node_key "$_mtag" 2>/dev/null || true
        done < <(jq -r 'keys[]' "$ARGO_METADATA_FILE" 2>/dev/null)
    fi

    _info "正在清理运行规则与配置文件..."
    _remove_log_cleanup

    rm -f "${CLOUDFLARED_BIN}" "$RUNTIME_DIR"/argo-*.pid "$RUNTIME_DIR"/argo-keepalive.lock
    rm -f /tmp/singbox_argo_*.pid /tmp/singbox_argo_*.log
    rm -f "${ARGO_LOG_FILE}" /var/log/singbox_argo_*.log
    rm -rf /etc/cloudflared

    rm -rf "${SINGBOX_DIR}"
    rm -f "${LOG_FILE}"

    rm -f "/usr/local/bin/sb"
    rm -f "${SINGBOX_BIN}" "${YQ_BINARY}"

    rmdir "$RUNTIME_DIR" >/dev/null 2>&1 || true

    _success "清理完成。脚本已自毁。再见！"
    [ -f "${SELF_SCRIPT_PATH}" ] && rm -f "${SELF_SCRIPT_PATH}"
    exit 0
}

_initialize_config_files() {
    mkdir -p ${SINGBOX_DIR}
    if [ ! -s "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "1m",
    "write_to_system": false,
    "connect_timeout": "3s"
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local",
        "prefer_go": true
      }
    ],
    "final": "dns-local",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [],
    "final": "direct",
    "default_domain_resolver": {
      "server": "dns-local",
      "strategy": "prefer_ipv4"
    }
  }
}
EOF
    fi
    [ -s "$METADATA_FILE" ] || echo "{}" > "$METADATA_FILE"

    local RELAY_JSON="${SINGBOX_DIR}/relay.json"
    if [ ! -s "$RELAY_JSON" ]; then
        echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$RELAY_JSON"
        _info "已初始化中转配置文件: $RELAY_JSON"
    fi
    if [ ! -s "$CLASH_YAML_FILE" ]; then
        _info "正在创建全新的 clash.yaml 配置文件..."
        cat > "$CLASH_YAML_FILE" << 'EOF'
port: 7890
socks-port: 7891
mixed-port: 7892
allow-lan: false
bind-address: '*'
mode: rule
log-level: info
ipv6: true
find-process-mode: strict
external-controller: '127.0.0.1:9090'
profile:
  store-selected: true
  store-fake-ip: true
unified-delay: true
tcp-concurrent: true
ntp:
  enable: true
  write-to-system: false
  server: ntp.aliyun.com
  port: 123
  interval: 30
dns:
  enable: true
  respect-rules: true
  use-system-hosts: true
  prefer-h3: false
  listen: '0.0.0.0:1053'
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  fake-ip-filter:
    - +.lan
    - +.local
    - localhost.ptlogin2.qq.com
    - +.msftconnecttest.com
    - +.msftncsi.com
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
    - 'https://1.1.1.1/dns-query'
    - 'https://dns.quad9.net/dns-query'
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  proxy-server-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 'https://1.0.0.1/dns-query'
    - 'https://9.9.9.10/dns-query'
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  dns-hijack:
    - 'any:53'
  device: SakuraiTunnel
  endpoint-independent-nat: true
proxies: []
proxy-groups:
  - name: 节点选择
    type: select
    proxies: []
rules:
  - GEOIP,PRIVATE,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF
    fi
}

_init_relay_config() {
    if [ ! -s "$RELAY_CONFIG_FILE" ]; then
        _ensure_relay_config || return 1
        _info "已初始化中转配置文件"
    fi
}

_cleanup_legacy_config() {
    local needs_restart=false

    if jq -e '.outbounds[] | select(.tag | startswith("relay-out-"))' "$CONFIG_FILE" >/dev/null 2>&1; then
        _warn "检测到旧版中转残留配置，正在清理..."
        if ! cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak_legacy"; then
            _error "无法创建旧版中转配置清理快照，已取消清理。"
            return 1
        fi
        chmod 600 "${CONFIG_FILE}.bak_legacy" 2>/dev/null || true
        _atomic_modify_json "$CONFIG_FILE" '
            .outbounds = ((.outbounds // []) | map(select(((.tag // "") | startswith("relay-out-")) | not)))
            | .route = (.route // {"rules":[]})
            | .route.rules = ((.route.rules // []) | map(select(((.outbound // "") | startswith("relay-out-")) | not)))
            | if any(.outbounds[]?; .tag == "direct") then . else .outbounds = [{"type":"direct","tag":"direct"}] + .outbounds end
        ' || return 1

        _success "配置清理完成。相关中转已被迁移至独立配置文件 (relay.json)。"
        needs_restart=true
    fi

    if ! jq -e '.route.final == "direct"' "$CONFIG_FILE" >/dev/null 2>&1; then
        _warn "检测到 route.final 未设置或不正确，正在修复..."

        _atomic_modify_json "$CONFIG_FILE" 'if .route then .route.final = "direct" else .route = {"rules":[],"final":"direct"} end' || return 1

        _success "route.final 已设置为 direct，主节点流量将走本机 IP。"
        needs_restart=true
    fi

    if [ "$needs_restart" = true ]; then
        return 0
    fi
    return 1
}

_check_and_fix_dns() {
    if [ ! -f "$CONFIG_FILE" ]; then return; fi

    local has_dns legacy_dns has_auto_detect dns_strategy has_default_resolver local_dns_needs_prefer_go
    has_dns=$(jq 'has("dns")' "$CONFIG_FILE" 2>/dev/null)
    legacy_dns=$(jq 'any(.dns.servers[]?; has("address") or ((.type // "") == "")) or any(.dns.rules[]?; has("outbound"))' "$CONFIG_FILE" 2>/dev/null)
    has_auto_detect=$(jq 'try .route.auto_detect_interface catch false' "$CONFIG_FILE" 2>/dev/null)
    dns_strategy=$(jq -r '.dns.strategy // ""' "$CONFIG_FILE" 2>/dev/null)
    has_default_resolver=$(jq '(.route.default_domain_resolver // null) != null' "$CONFIG_FILE" 2>/dev/null)
    local_dns_needs_prefer_go=$(jq 'any(.dns.servers[]?; ((.type // "") == "local") and ((.prefer_go // false) != true))' "$CONFIG_FILE" 2>/dev/null)
    local needs_restart=false

    if [ "$has_dns" == "false" ] || [ "$legacy_dns" == "true" ] || [ "$has_auto_detect" == "true" ] || [ -z "$dns_strategy" ] || [ "$has_default_resolver" != "true" ] || [ "$local_dns_needs_prefer_go" == "true" ]; then
        _warn "检测到 DNS/路由配置需要兼容性修复，正在自动处理..."

        local backup_file
        backup_file=$(mktemp "${CONFIG_FILE}.dnsfix.backup.XXXXXX") || return 1
        cp -p "$CONFIG_FILE" "$backup_file" || { rm -f "$backup_file"; return 1; }
        local legacy_address="local" new_dns replace_dns="false"
        if [ "$legacy_dns" = "true" ]; then
            legacy_address=$(jq -r '.dns.servers[0].address // "local"' "$CONFIG_FILE" 2>/dev/null)
            replace_dns="true"
        elif [ "$has_dns" = "false" ]; then
            replace_dns="true"
        fi
        case "$dns_strategy" in prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only) ;; *) dns_strategy="prefer_ipv4" ;; esac
        new_dns=$(_build_dns_config_json "$legacy_address" "$dns_strategy") || {
            _error "无法迁移旧 DNS 地址：${legacy_address}"
            rm -f "$backup_file"
            return 1
        }
        if _atomic_modify_json "$CONFIG_FILE" '
            if $replace_dns then .dns = $dns else . end
            | .dns.servers |= map(if ((.type // "") == "local") then . + {prefer_go:true} else . end)
            | .route = (.route // {"rules":[]})
            | .route.default_domain_resolver = {"server":"dns-local","strategy":$strategy}
            | del(.route.auto_detect_interface)
        ' --argjson replace_dns "$replace_dns" --argjson dns "$new_dns" --arg strategy "$dns_strategy"; then
            local check_result
            if ! check_result=$(_check_combined_config_files "$SINGBOX_BIN" "$CONFIG_FILE" "$RELAY_CONFIG_FILE" 2>&1); then
                _error "DNS 热修复未通过组合配置校验，已回滚："
                echo "$check_result"
                mv -f "$backup_file" "$CONFIG_FILE"
                return 1
            fi
            rm -f "$backup_file"
            _success "DNS 与路由参数热修复完成！"
            needs_restart=true
        else
            _error "高级修复应用失败，已恢复原配置。"
            mv -f "$backup_file" "$CONFIG_FILE"
        fi
    fi

    if [ -f "$CLASH_YAML_FILE" ] && [ -x "$YQ_BINARY" ]; then
        local clash_ipv6=$(${YQ_BINARY} eval '.ipv6 // false' "$CLASH_YAML_FILE" 2>/dev/null)
        local clash_dns_ipv6=$(${YQ_BINARY} eval '.dns.ipv6 // false' "$CLASH_YAML_FILE" 2>/dev/null)
        if [ "$clash_ipv6" != "true" ] || [ "$clash_dns_ipv6" != "true" ]; then
            if _atomic_modify_yaml "$CLASH_YAML_FILE" '.ipv6 = true | .dns.ipv6 = true' >/dev/null 2>&1; then
                _success "已开启 clash.yaml 的 IPv6 与 DNS IPv6 支持。"
            else
                _warn "clash.yaml IPv6 自动修复失败，请手动检查 YAML 格式。"
            fi
        fi
    fi

    if [ "$needs_restart" == "true" ]; then
        return 0
    fi
    return 1
}

# 显示节点分享链接（Argo 专用）
# 参数: $1=协议类型("vless-ws"/"trojan-ws"), $2=节点名称, $3=域名, $4=端口, $5=tag, $6=uuid/password, $7=ws_path
_show_node_link() {
    local type="$1"
    local name="$2"
    local link_ip="$3"
    local port="$4"
    local tag="$5"

    shift 5

    local url=""

    case "$type" in
        "vless-ws")
            local uuid="$1" ws_path="$2"
            local ed_path=$(_ws_path_with_early_data "$ws_path")
            url="vless://${uuid}@${link_ip}:443?encryption=none&security=tls&type=ws&host=${link_ip}&path=$(_url_encode "$ed_path")&sni=${link_ip}#$(_url_encode "$name")"
            ;;
        "trojan-ws")
            local password="$1" ws_path="$2"
            local ed_path=$(_ws_path_with_early_data "$ws_path")
            url="trojan://$(_url_encode "${password}")@${link_ip}:443?security=tls&type=ws&host=${link_ip}&path=$(_url_encode "$ed_path")&sni=${link_ip}#$(_url_encode "$name")"
            ;;
    esac

    if [ -n "$url" ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════ 分享链接 ═══════════════════${NC}"
        echo -e "${CYAN}${url}${NC}"
        echo -e "${YELLOW}═════════════════════════════════════════════════${NC}"

        if [ -n "$tag" ] && [ "$tag" != "null" ]; then
            _atomic_modify_json "$ARGO_METADATA_FILE" '. + {($tag): ((.[$tag] // {}) + {share_link:$url, name:$name})}' \
                --arg tag "$tag" --arg url "$url" --arg name "$name" || return 1
        fi
    fi
    return 0
}

_check_config() {
    _info "正在按服务真实启动方式检查 config.json + relay.json..."
    _ensure_relay_config || return 1
    local result
    if result=$(_check_combined_config_files "$SINGBOX_BIN" "$CONFIG_FILE" "$RELAY_CONFIG_FILE" 2>&1); then
        _success "config.json + relay.json 组合配置校验通过。"
        return 0
    else
        _error "组合配置检查失败:"
        echo "$result"
        return 1
    fi
}

_require_singbox() {
    if [ ! -f "${SINGBOX_BIN}" ]; then
        _error "此功能需要先安装 Sing-box 核心。请前往主菜单 [2] 进行安装。"
        return 1
    fi
    return 0
}

_install_or_update_singbox() {
    local current_ver="未安装" choice confirm
    if [ -f "${SINGBOX_BIN}" ]; then
        current_ver=$(${SINGBOX_BIN} version 2>/dev/null | head -n1 | awk '{print $3}')
        [ -n "$current_ver" ] || current_ver="未知"
    fi

    clear
    echo -e "${CYAN}"
    echo '  ╔═══════════════════════════════════════╗'
    echo '  ║       安装/更新 Sing-box 核心         ║'
    echo '  ╚═══════════════════════════════════════╝'
    echo -e "${NC}"
    if [ "$current_ver" = "未安装" ]; then
        echo -e "  当前版本: ${YELLOW}未安装${NC}"
    else
        echo -e "  当前版本: ${GREEN}v${current_ver}${NC}"
    fi

    if _singbox_core_is_locked; then
        echo -e "  版本策略: ${YELLOW}固定 v${SINGBOX_FIXED_VERSION}（禁止升级）${NC}"
    else
        echo -e "  版本策略: ${GREEN}跟随最新稳定版${NC}"
    fi
    echo ""
    echo -e "    ${GREEN}[1]${NC} 安装/更新最新稳定版"
    echo -e "    ${GREEN}[2]${NC} 安装固定版 v${SINGBOX_FIXED_VERSION}（安装后禁止升级）"
    echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
    echo ""
    read -r -p "  请选择 [0-2]: " choice
    case "$choice" in
        1)
            if _singbox_core_is_locked; then
                _error "当前核心已固定为 v${SINGBOX_FIXED_VERSION}，不允许升级到其他版本。"
                return 1
            fi
            _do_update_singbox latest
            ;;
        2)
            if ! _singbox_core_is_locked; then
                _warn "安装完成后，脚本将永久锁定 v${SINGBOX_FIXED_VERSION}，后续菜单不再允许核心升级。"
                read -r -p "  确认安装并锁定固定版？(y/N): " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || { _info "已取消固定版安装。"; return 0; }
            fi
            _do_update_singbox "$SINGBOX_FIXED_VERSION"
            ;;
        0) return 0 ;;
        *) _error "无效输入，请选择 [0-2]。"; return 1 ;;
    esac
}

_do_update_singbox() {
    local install_target="${1:-latest}"
    if [ "$install_target" = "latest" ] && _singbox_core_is_locked; then
        _error "固定版锁已启用，拒绝执行 sing-box 核心升级。"
        return 1
    fi
    case "$install_target" in
        latest|"$SINGBOX_FIXED_VERSION") ;;
        *) _error "无效的 sing-box 安装目标: ${install_target}"; return 1 ;;
    esac

    _info "--- 安装/更新 Sing-box 核心 ---"
    _install_dependencies
    if ! _install_sing_box "$install_target"; then
        _error "Sing-box 核心安装/更新失败。"
        return 1
    fi

    _success "sing-box 核心已暂存，正在执行配置和服务验证。"
    if [ ! -f "${CONFIG_FILE}" ] || [ ! -f "${CLASH_YAML_FILE}" ]; then
        _info "检测到主配置文件缺失，正在初始化..."
        _initialize_config_files || { _rollback_singbox_binary; return 1; }
    fi
    _init_relay_config
    _ensure_relay_config || { _rollback_singbox_binary; return 1; }
    _secure_state_permissions

    local check_result
    if ! check_result=$(_check_combined_config_files "$SINGBOX_BIN" "$CONFIG_FILE" "$RELAY_CONFIG_FILE" 2>&1); then
        _error "新核心未通过 config.json + relay.json 组合校验，正在恢复旧核心："
        echo "$check_result"
        _rollback_singbox_binary
        return 1
    fi

    _create_service_files
    _setup_log_cleanup
    _info "正在启动/重启 sing-box 服务..."
    if ! _manage_service restart; then
        _error "新核心启动失败，正在恢复旧核心。"
        _rollback_singbox_binary
        if [ -x "$SINGBOX_BIN" ]; then _manage_service restart >/dev/null 2>&1 || true; fi
        return 1
    fi

    if [ "$install_target" = "$SINGBOX_FIXED_VERSION" ]; then
        if ! _write_singbox_core_lock; then
            _error "固定版本锁写入失败，正在恢复旧核心。"
            _manage_service stop >/dev/null 2>&1 || true
            _rollback_singbox_binary
            if [ -x "$SINGBOX_BIN" ]; then _manage_service restart >/dev/null 2>&1 || true; fi
            return 1
        fi
        _secure_state_permissions
    fi
    _commit_singbox_binary
    if [ "$install_target" = "$SINGBOX_FIXED_VERSION" ]; then
        _success "sing-box 服务已使用固定核心 v${SINGBOX_FIXED_VERSION} 启动，版本升级锁已生效。"
    else
        _success "sing-box 服务已使用最新稳定核心 v${SINGBOX_STAGED_VERSION:-未知} 启动，更新已提交。"
    fi
}

_download_bash_script_atomic() {
    local url="$1" target="$2" label="${3:-脚本}"
    [[ "$url" == https://* ]] || { _error "拒绝从非 HTTPS 地址下载 ${label}。"; return 1; }
    mkdir -p "$(dirname "$target")" || return 1
    local tmp
    tmp=$(mktemp "$(dirname "$target")/.${label}.new.XXXXXX") || return 1
    if ! wget -qO "$tmp" "$url" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        _error "${label} 下载失败或内容为空。"
        return 1
    fi
    if ! head -n 1 "$tmp" | grep -q '^#!/bin/bash' || ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        _error "${label} 未通过 Bash 脚本格式/语法校验，已拒绝覆盖。"
        return 1
    fi
    chmod 755 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

_update_script_locked() {
    _info "--- 更新脚本 ---"

    if [ "$SCRIPT_UPDATE_URL" == "YOUR_GITHUB_RAW_URL_HERE/singbox-lite_tunnel.sh" ]; then
        _error "错误：您尚未在脚本中配置 SCRIPT_UPDATE_URL 变量。"
        _warning "请编辑此脚本，找到 SCRIPT_UPDATE_URL 并填入您正确的 GitHub raw 链接。"
        return 1
    fi

    local cache_bust stage backup downloaded_version
    cache_bust=$(date +%s)
    stage=$(mktemp "$(dirname "$SELF_SCRIPT_PATH")/.singbox-lite.sh.stage.XXXXXX") || return 1
    rm -f -- "$stage"
    if ! _download_bash_script_atomic "${SCRIPT_UPDATE_URL}?v=${cache_bust}" "$stage" "singbox-lite_tunnel.sh"; then
        rm -f -- "$stage"
        return 1
    fi

    downloaded_version=$(sed -n 's/^export SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$stage" | head -n 1)
    if [ -z "$downloaded_version" ]; then
        rm -f -- "$stage"
        _error "下载的主脚本缺少 SCRIPT_VERSION，已拒绝更新。"
        return 1
    fi
    if [[ "$SCRIPT_VERSION" =~ ^[0-9]+$ && "$downloaded_version" =~ ^[0-9]+$ ]] \
        && [ "$((10#$downloaded_version))" -lt "$((10#$SCRIPT_VERSION))" ]; then
        rm -f -- "$stage"
        _error "仓库版本 v${downloaded_version} 低于本地 v${SCRIPT_VERSION}，已拒绝自动降级。"
        return 1
    fi

    backup=""
    if [ -e "$SELF_SCRIPT_PATH" ] || [ -L "$SELF_SCRIPT_PATH" ]; then
        backup=$(mktemp "$(dirname "$SELF_SCRIPT_PATH")/.singbox-lite.sh.rollback.XXXXXX") || { rm -f -- "$stage"; return 1; }
        if ! cp -p -- "$SELF_SCRIPT_PATH" "$backup"; then
            rm -f -- "$stage" "$backup"
            return 1
        fi
    fi

    if ! chmod 755 "$stage" || ! mv -f -- "$stage" "$SELF_SCRIPT_PATH"; then
        _error "脚本提交失败，正在恢复更新前文件。"
        [ -n "$backup" ] && mv -f -- "$backup" "$SELF_SCRIPT_PATH" 2>/dev/null || true
        rm -f -- "$stage" "$backup"
        return 1
    fi
    rm -f -- "$stage" "$backup"
    _success "脚本已更新：v${SCRIPT_VERSION} -> v${downloaded_version}"

    if ! _install_yq; then
        _warning "脚本已更新，但 yq 检查/更新失败，请检查网络后重试。"
    fi

    _info "请重新运行脚本以应用所有变更："
    echo -e "${YELLOW}bash ${SELF_SCRIPT_PATH}${NC}"
    return 0
}

_update_script() {
    _with_state_lock _update_script_locked
    local rc=$?
    [ "$rc" -eq 0 ] && exit 0
    return "$rc"
}

_main_menu() {
    while true; do
        clear
        echo -e "${CYAN}"
        echo '  ____  _             ____            '
        echo ' / ___|(_)_ __   __ _| __ )  _____  __'
        echo ' \___ \| | '\''_ \ / _` |  _ \ / _ \ \/ /'
        echo '  ___) | | | | | (_| | |_) | (_) >  < '
        echo ' |____/|_|_| |_|\__, |____/ \___/_/\_\'
        echo '                |___/    Argo Lite   '
        echo -e "${NC}"

        echo -e "${CYAN}"
        echo "  ╔═══════════════════════════════════════╗"
        echo "  ║      sing-box Argo 隧道精简脚本 v${SCRIPT_VERSION}      ║"
        echo "  ╚═══════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""

        local os_info="未知"
        if [ -f /etc/os-release ]; then
            os_info=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
            [ -z "$os_info" ] && os_info=$(grep -E "^NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
        fi
        [ -z "$os_info" ] && os_info=$(uname -s)

        local sb_version=""
        local service_status="○ 未知"
        if [ -f "$SINGBOX_BIN" ]; then
            sb_version=" v$($SINGBOX_BIN version 2>/dev/null | head -n1 | awk '{print $3}')"
            if _singbox_core_is_locked; then
                sb_version="${sb_version} [固定]"
            fi
            if [ "$INIT_SYSTEM" == "systemd" ]; then
                if systemctl is-active --quiet sing-box 2>/dev/null; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            elif [ "$INIT_SYSTEM" == "openrc" ]; then
                if rc-service sing-box status 2>/dev/null | grep -q "started"; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            elif [ "$INIT_SYSTEM" == "direct" ]; then
                if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            fi
        else
            service_status="${RED}○ 未安装${NC}"
        fi

        local argo_status="${RED}○ 未安装${NC}"
        if [ -f "$CLOUDFLARED_BIN" ]; then
            local argo_running=false
            if [ -s "$ARGO_METADATA_FILE" ]; then
                local argo_port
                while IFS= read -r argo_port; do
                    [[ "$argo_port" =~ ^[0-9]+$ ]] || continue
                    _migrate_legacy_argo_state "$argo_port" >/dev/null 2>&1 || true
                done < <(jq -r '.[].local_port // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
            fi
            for pid_file in "$RUNTIME_DIR"/argo-*.pid; do
                [ -f "$pid_file" ] || continue
                local pid=$(cat "$pid_file" 2>/dev/null)
                if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
                    argo_running=true
                    break
                fi
            done
            if [ "$argo_running" = false ]; then
                if command -v pgrep &>/dev/null; then
                    pgrep -x cloudflared &>/dev/null && argo_running=true
                elif ps w 2>/dev/null | grep -v "grep" | grep -q "cloudflared"; then
                    argo_running=true
                fi
            fi
            if [ "$argo_running" = true ]; then
                argo_status="${GREEN}● 运行中${NC}"
            else
                argo_status="${YELLOW}○ 已安装 (未运行)${NC}"
            fi
        fi

        echo -e "  系统: ${CYAN}${os_info}${NC}  |  模式: ${CYAN}${INIT_SYSTEM}${NC}"
        echo -e "  Sing-box${CYAN}${sb_version}${NC}: ${service_status}  |  Argo: ${argo_status}"
        echo ""

        echo -e "  ${CYAN}【隧道节点】${NC}"
        echo -e "    ${GREEN}[1]${NC} Argo 隧道节点管理 (临时/固定)"
        echo ""

        echo -e "  ${CYAN}【前置支持】${NC}"
        echo -e "    ${GREEN}[2]${NC} 安装/更新 Sing-box 核心"
        echo -e "    ${GREEN}[3]${NC} 重启 sing-box 服务"
        echo -e "    ${GREEN}[4]${NC} 查看服务运行状态"
        echo -e "    ${GREEN}[5]${NC} 查看实时日志"
        echo -e "    ${GREEN}[6]${NC} 检查配置文件"
        echo ""

        echo -e "  ${CYAN}【脚本管理】${NC}"
        echo -e "    ${GREEN}[7]${NC} 更新脚本"
        echo -e "    ${RED}[8]${NC} 卸载脚本"
        echo ""

        echo -e "  ─────────────────────────────────────────────────"
        echo -e "    ${YELLOW}[0]${NC} 退出脚本"
        echo ""

        read -p "  请输入选项 [0-8]: " choice

        case $choice in
            1) _require_singbox && _argo_menu ;;
            2) _install_or_update_singbox ;;
            3) _require_singbox && _manage_service "restart" ;;
            4) _require_singbox && _manage_service "status" ;;
            5) _require_singbox && _view_log ;;
            6) _require_singbox && _check_config ;;
            7) _update_script ;;
            8) _uninstall ;;
            0) exit 0 ;;
            *) _error "无效输入，请重试。" ;;
        esac
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

main() {
    _check_root
    _detect_init_system

    mkdir -p "${SINGBOX_DIR}" 2>/dev/null
    chmod 700 "${SINGBOX_DIR}" 2>/dev/null || true

    _install_dependencies

    if [ -f "${SINGBOX_BIN}" ]; then
        if [ ! -f "${CONFIG_FILE}" ] || [ ! -f "${CLASH_YAML_FILE}" ]; then
             _info "检测到主配置文件缺失，正在初始化..."
             _initialize_config_files
        fi

        _init_relay_config
        _ensure_relay_config || { _error "无法初始化 relay.json。"; return 1; }

        local config_updated=false
        if _cleanup_legacy_config; then
            config_updated=true
        fi

        if _check_and_fix_dns; then
            config_updated=true
        fi

        local ntp_before ntp_after
        ntp_before=$(jq -cS '.ntp // null' "$CONFIG_FILE")
        _time_prepare_ntp_config || { _error "时间补偿配置准备失败"; return 1; }
        ntp_after=$(jq -cS '.ntp // null' "$CONFIG_FILE")
        [ "$ntp_before" = "$ntp_after" ] || config_updated=true

        if [ "$config_updated" = true ]; then
            _manage_service restart
        fi

        if [ -n "$SERVICE_FILE" ] && [ ! -f "$SERVICE_FILE" ]; then
            _create_service_files
        elif [ "$INIT_SYSTEM" == "direct" ] && [ ! -f "$LOG_FILE" ]; then
            touch "$LOG_FILE"
        fi
        _setup_log_cleanup
        _secure_state_permissions
    else
        _warn "sing-box 核心未安装。请通过主菜单 [2] 进行安装。"
    fi

    _main_menu
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        keepalive)
            _argo_keepalive
            exit 0
            ;;
        cleanup-logs)
            _cleanup_runtime_logs
            exit $?
            ;;
        *)
            shift
            ;;
    esac
done

main
