#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本
# 版本: v2.10.0
# 更新日志 (v2.10.0):
# - [新增] mldsa65 抗量子签名：tls ping 探测 pqv + 证书链 >3500 时询问是否启用
# - [新增] 回落限速 limitFallbackUpload/Download：参数随机化，避免脚本指纹
# - [新增] dokodemo-door 防盗刷开关：默认关闭（dest 直连目标），支持运行时切换
# - [新增] 菜单 9「诊断 Xray 安装状态」，一次输出二进制/服务/配置/网络/磁盘状态
# - [新增] reality-checker 集成：自动探测工具，展示 CDN/被墙/热门度报告
# - [新增] view_all_info 输出客户端兼容提示（Mihomo 需 chrome + ML-KEM 开关）
# - [修复] 官方安装器子命令错误：install-geodata → update-geodata（官方无前者）
# - [修复] 官方安装器调用形式：bash -c "<script>" @ <cmd>（原 bash -s -- 会误解析 --xxx）
# - [修复] check_xray_status 在 pipefail 下因 SIGPIPE 输出"未知"版本号
# - [修复] update_xray 中 current_version/new_version 取值为空导致误判
# - [修复] error() 在 case 无匹配时返回 1，配合 set -e 会在 return 前终止脚本
# - [修复] main_menu 对功能函数返回值兜底，避免单项失败导致整个菜单退出
# - [修复] 官方安装器输出不再丢弃，失败时回显日志摘要
# - [修复] update_xray 校验 API 响应、检查 run_core_install 返回值、更新后回读版本
# - [修复] 回落限速随机数改用 SRANDOM，修正 RANDOM 16 位导致的抖动范围过窄
# - [修复] 卸载时清理 mldsa65.verify 残留记录
# - [修复] geosite/geoip 先走官方安装器，失败后询问是否用 wget 从 MetaCubeX 下载
# - [修复] 核心安装改用 install --without-geodata，避免官方先拉取失败的 Loyalsoldier 源
# - [修复] SNI target 探活：tls ping 校验 with SNI 必须握手成功，并输出 pqv/证书链长度
# - [修复] SS2022 分享链接按 SIP002 明文 method:percentEncodedPassword，IPv6 补 []，tag 编码
# - [修复] get_public_ip 中 ((attempts++)) 在 set -e 下中断函数，导致 IPv6 回退失效
# - [修复] 卸载时清理本脚本添加的 firewalld 规则与历史端口残留提示
# - [修复] 双协议安装漏传 FALLBACK_LIMIT，导致限速设置静默失效
# - [修复] 修改配置时防火墙不清理旧端口，导致改端口后旧端口持续开放
# - [维护] 清理 shellcheck SC1087/SC2034 告警（颜色变量加花括号、nameref 抑制注释）
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="v2.10.0"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly xray_dat_dir="/usr/local/share/xray"
readonly geodata_release_url="https://github.com/MetaCubeX/meta-rules-dat/releases/latest"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
xray_status_info=""
is_quiet=false

# --- 辅助函数 ---
error() {
    echo -e "\n${red}[✖] $1${none}\n" >&2

    case "$1" in
        *"网络"*|*"下载"*)
            echo -e "${yellow}提示: 检查网络连接或更换DNS${none}" >&2 ;;
        *"权限"*|*"root"*)
            echo -e "${yellow}提示: 请使用 sudo 运行脚本${none}" >&2 ;;
        *"端口"*)
            echo -e "${yellow}提示: 尝试使用其他端口号${none}" >&2 ;;
        *)
            : ;;
    esac
    # 显式返回 0：set -e 下若 case 无匹配则函数返回 1，会导致调用方在 return 前被终止
    return 0
}

info() { [[ "$is_quiet" = false ]] && echo -e "\n${yellow}[!] $1${none}\n" || true; }
success() { [[ "$is_quiet" = false ]] && echo -e "\n${green}[✔] $1${none}\n" || true; }
warning() { [[ "$is_quiet" = false ]] && echo -e "\n${yellow}[⚠] $1${none}\n" || true; }

spinner() {
    local pid="$1"
    local spinstr='|/-\'
    if [[ "$is_quiet" = true ]]; then
        wait "$pid"
        return
    fi
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip
    local attempts=0
    local max_attempts=2

    while [[ $attempts -lt $max_attempts ]]; do
        for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
            for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
                ip=$($cmd "$url" 2>/dev/null) || true
                if [[ -n "$ip" ]]; then echo "$ip"; return; fi
            done
        done
        attempts=$((attempts + 1))
        [[ $attempts -lt $max_attempts ]] && sleep 1 || true
    done

    # IPv6 fallback
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) || true
            if [[ -n "$ip" ]]; then echo "$ip"; return; fi
        done
    done
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ "$(id -u)" != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl) &> /dev/null &
        spinner $!
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
            error "依赖 (jq/curl) 自动安装失败。请手动运行 'apt update && apt install -y jq curl' 后重试。"
            exit 1
        fi
        success "依赖已成功安装。"
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" || ! -x "$xray_binary_path" ]]; then
        xray_status_info=" Xray 状态: ${red}未安装${none}"
        return
    fi
    local xray_version
    # 不用管道 + head：pipefail 下 xray 会因 SIGPIPE(141) 让整个管道失败，
    # 导致 || echo "未知" 被触发，把 "未知" 拼进版本号
    local ver_line
    ver_line=$("$xray_binary_path" version 2>/dev/null | sed -n '1p') || ver_line=""
    xray_version=$(echo "$ver_line" | awk '{print $2}')
    [[ -z "$xray_version" ]] && xray_version="未知"
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then
        service_status="${green}运行中${none}"
    else
        service_status="${yellow}未运行${none}"
    fi
    xray_status_info=" Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

quick_status() {
    if [[ ! -f "$xray_binary_path" ]]; then
        echo -e " ${red}●${none} 未安装"
        return
    fi

    local status_icon
    if systemctl is-active --quiet xray 2>/dev/null; then
        status_icon="${green}●${none}"
    else
        status_icon="${red}●${none}"
    fi

    echo -e " $status_icon Xray $(systemctl is-active xray 2>/dev/null || echo "inactive")"
}

# --- 核心配置生成函数 ---
generate_ss_key() {
    openssl rand -base64 16
}

build_vless_inbound() {
    # 第 7 个可选参数 mldsa65_seed：为空时使用标准 x25519（向后兼容）
    # 第 8 个可选参数 fallback_limit：为 "afterBytes,bytesPerSec,burstBytesPerSec" 时写入回落限速
    # 第 9 个可选参数 use_dokodemo：true=dest 指向本地 dokodemo（防盗刷）；false=dest 直连目标（默认）
    local port="$1" uuid="$2" domain="$3" private_key="$4" public_key="$5" internal_port="$6" mldsa65_seed="${7:-}" fallback_limit="${8:-}" use_dokodemo="${9:-false}" shortid="94451705"
    local limit_json='{}' dest_addr
    if [[ "$use_dokodemo" == true && -n "$internal_port" ]]; then
        dest_addr="127.0.0.1:${internal_port}"
    else
        dest_addr="${domain}:443"
    fi
    if [[ -n "$fallback_limit" ]]; then
        local after_bytes bytes_per_sec burst
        IFS=',' read -r after_bytes bytes_per_sec burst <<< "$fallback_limit"
        limit_json=$(jq -n --argjson a "$after_bytes" --argjson b "$bytes_per_sec" --argjson c "$burst" \
            '{limitFallbackUpload: {afterBytes: $a, bytesPerSec: $b, burstBytesPerSec: $c},
              limitFallbackDownload: {afterBytes: $a, bytesPerSec: $b, burstBytesPerSec: $c}}')
    fi
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" --arg dest_addr "$dest_addr" --arg mldsa65_seed "$mldsa65_seed" --argjson limit_json "$limit_json" \
    '{"listen": "0.0.0.0", "port": $port, "protocol": "vless", "settings": {"clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": ({"show": false, "dest": $dest_addr, "xver": 0, "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid]} + (if $mldsa65_seed != "" then {"mldsa65Seed": $mldsa65_seed} else {} end) + $limit_json)}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]} }'
}

# 回落限速参数生成：官方要求脚本随机化，避免全网参数雷同形成指纹
# 输出到全局变量 FALLBACK_LIMIT，格式 "afterBytes,bytesPerSec,burstBytesPerSec"
FALLBACK_LIMIT=""
prompt_for_fallback_limit() {
    FALLBACK_LIMIT=""
    local answer
    warning "回落限速可防止服务器成为他人的加速节点，但官方明确指出：限速本身是一种特征，不建议启用。"
    echo -e "  ${cyan}适用场景:${none} 偷用的是 Cloudflare 这类免费 CDN 证书（你当前 SNI: archives.harvard.edu 属于此类）"
    echo -e "  ${cyan}机制:${none} 令牌桶，传输 afterBytes 字节后限速 bytesPerSec，桶容量 burstBytesPerSec"
    read -p " 是否启用回落限速？[y/N]: " answer || true
    if [[ ! "$answer" =~ ^[yY]$ ]]; then
        info "不启用回落限速。"
        return 0
    fi

    # 用户可自定义，直接回车用官方示例值并加随机抖动
    local custom
    read -p " 自定义参数 \"afterBytes,bytesPerSec,burstBytesPerSec\" (留空=官方示例值+随机抖动): " custom || true
    if [[ -n "$custom" ]]; then
        if [[ "$custom" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]]; then
            FALLBACK_LIMIT="$custom"
            info "将使用自定义限速参数: ${cyan}${FALLBACK_LIMIT}${none}"
            return 0
        fi
        warning "格式无效，改用随机化参数。"
    fi

    # 基准 10MB/1MB/s/5MB/s，各加 ±20% 抖动避免指纹
    # SRANDOM 是 32 位（bash 5.1+）；RANDOM 只有 16 位，取模后覆盖不了目标区间
    local rnd_a rnd_b rnd_c
    if [[ -n "${SRANDOM:-}" ]]; then
        rnd_a=$SRANDOM; rnd_b=$SRANDOM; rnd_c=$SRANDOM
    else
        # 老版 bash 兜底：用多次 RANDOM 拼出更大的取值范围
        rnd_a=$(( RANDOM * 61 + RANDOM ))
        rnd_b=$(( RANDOM * 7 + RANDOM ))
        rnd_c=$RANDOM
    fi
    local jitter_a jitter_b jitter_c
    jitter_a=$(( (rnd_a % 4000001) + 8388608 ))           # 8MB ~ 12.4MB
    jitter_b=$(( (rnd_b % 419431) + 838861 ))             # 800KB/s ~ 1.2MB/s
    jitter_c=$(( jitter_b * ((rnd_c % 3) + 4) ))          # 基准的 4~6 倍
    FALLBACK_LIMIT="${jitter_a},${jitter_b},${jitter_c}"
    info "已生成随机化限速参数: ${cyan}${FALLBACK_LIMIT}${none}"
    info "即: 传输 $(( jitter_a / 1048576 ))MB 后限速 $(( jitter_b / 1024 ))KB/s，突发上限 $(( jitter_c / 1048576 ))MB/s"
}

# 询问并在用户许可后生成 ML-DSA-65 密钥对（抗量子签名，可选增强）
# 输出：种子写到 stdout 的上方变量 default_mldsa_seed / default_mldsa_verify
# 返回 0 表示用户同意启用且生成成功
prompt_for_mldsa65() {
    local domain="$1" pqv="$2" chain_len="$3"
    local -n o_seed="$4" o_verify="$5"
    o_seed="" o_verify=""

    [[ "$pqv" = true ]] || return 1
    if [[ -z "$chain_len" || "$chain_len" -le 3500 ]]; then
        warning "目标证书链 ${chain_len:-未知} 字节，不足 3501，启用 mldsa65 会产生特征，已跳过。"
        return 1
    fi
    [[ -x "$xray_binary_path" ]] || return 1

    local answer
    warning "该目标支持后量子密钥交换且证书链 ${chain_len} 字节，可启用 ML-DSA-65 抗量子签名。"
    echo -e "  ${cyan}说明:${none} 服务端写 mldsa65Seed，客户端链接追加 mldsa65Verify；不启用仍可正常连接。"
    read -p " 是否启用 mldsa65 抗量子签名？[y/N]: " answer || true
    if [[ ! "$answer" =~ ^[yY]$ ]]; then
        info "已跳过 mldsa65，使用标准 x25519。"
        return 1
    fi

    local key_pair seed verify
    key_pair=$("$xray_binary_path" mldsa65 2>/dev/null) || { warning "mldsa65 命令执行失败，已跳过。"; return 1; }
    seed=$(echo "$key_pair" | awk '/Seed:/ {print $2}')
    verify=$(echo "$key_pair" | awk '/Verify:/ {print $2}')
    if [[ -z "$seed" || -z "$verify" ]]; then
        warning "解析 mldsa65 密钥失败，已跳过（保持 x25519）。"
        return 1
    fi

    # o_seed / o_verify 是 nameref（local -n），赋值即写入调用方变量。
    # 工具无法追踪这层间接引用，因此就近抑制 SC2034。
    # shellcheck disable=SC2034
    o_seed="$seed"
    # shellcheck disable=SC2034
    o_verify="$verify"
    success "mldsa65 密钥已生成。"
    return 0
}

# 由已有 seed 反推 Verify 公钥（用于链接生成时从配置还原 pqv）
mldsa65_verify_from_seed() {
    local seed="$1"
    [[ -x "$xray_binary_path" && -n "$seed" ]] || return 0
    "$xray_binary_path" mldsa65 -i "$seed" 2>/dev/null | awk '/Verify:/ {print $2}' || true
}

# 记录 mldsa65 Verify 到 Xray 数据目录旁的受保护文件，供后续链接生成反查
readonly mldsa65_record_path="/usr/local/etc/xray/mldsa65.verify"
write_mldsa65_verify() {
    local verify="$1"
    [[ -n "$verify" ]] || return 0
    printf 'mldsa65Verify=%s\n' "$verify" > "$mldsa65_record_path"
    chmod 600 "$mldsa65_record_path"
    chown root:root "$mldsa65_record_path"
}

build_ss_inbound() {
    local port="$1" password="$2"
    jq -n --argjson port "$port" --arg password "$password" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "shadowsocks", "settings": {"method": "2022-blake3-aes-128-gcm", "password": $password} }'
}

# --- 防盗刷：生成 dokodemo-door inbound ---
build_dokodemo_inbound() {
    local domain="$1" internal_port="$2"
    jq -n --argjson internal_port "$internal_port" --arg domain "$domain" \
    '{
        "listen": "127.0.0.1",
        "tag": "dokodemo-in",
        "port": $internal_port,
        "protocol": "dokodemo-door",
        "settings": {
            "address": $domain,
            "port": 443,
            "network": "tcp"
        },
        "sniffing": {
            "enabled": true,
            "destOverride": ["tls"],
            "routeOnly": true
        }
    }'
}

# --- 防盗刷开关：统一判断当前配置是否启用了 dokodemo ---
has_dokodemo() {
    [[ -f "$xray_config_path" ]] || return 1
    local tag
    tag=$(jq -r '.inbounds[] | select(.tag == "dokodemo-in") | .tag' "$xray_config_path" 2>/dev/null || true)
    [[ -n "$tag" ]]
}

# 交互询问是否启用 dokodemo（防盗刷）
# 参数: $1=默认值(yes|no)  $2=是否允许"留空不改"(true|false)
# 输出到全局变量 USE_DOKODEMO=true|false
USE_DOKODEMO=false
prompt_for_dokodemo() {
    local default_choice="${1:-no}"
    local allow_keep="${2:-false}"
    local answer prompt_text

    if [[ "$allow_keep" == true ]]; then
        local cur_state="关闭"
        has_dokodemo && cur_state="启用"
        prompt_text=" -> 防盗刷转发 dokodemo-door (当前: ${cyan}${cur_state}${none}) [y=启用 n=关闭, 留空不改]: "
        read -p "$(echo -e "$prompt_text")" answer || true
        if [[ -z "$answer" ]]; then
            has_dokodemo && USE_DOKODEMO=true || USE_DOKODEMO=false
            return 0
        fi
    else
        local hint="y/N"
        [[ "$default_choice" == yes ]] && hint="Y/n"
        read -p " -> 是否启用防盗刷转发 dokodemo-door？[${hint}]: " answer || true
        if [[ -z "$answer" ]]; then
            [[ "$default_choice" == yes ]] && USE_DOKODEMO=true || USE_DOKODEMO=false
            return 0
        fi
    fi

    if [[ "$answer" =~ ^[yY]$ ]]; then
        USE_DOKODEMO=true
    else
        USE_DOKODEMO=false
    fi
    return 0
}

# 询问内部转发端口（仅在启用 dokodemo 时调用）
prompt_for_internal_port() {
    local -n o_port="$1"
    local current="${2:-23333}"
    local default_port="${3:-23333}"
    local input

    while true; do
        read -p "$(echo -e " -> 内部转发端口 (仅本机监听, 当前: ${cyan}${current}${none}, 默认 ${default_port}): ")" input || true
        [[ -z "$input" ]] && input="$default_port"
        if is_valid_port "$input"; then
            # o_port 是 nameref（local -n），赋值即写入调用方变量
            # shellcheck disable=SC2034
            o_port="$input"
            return 0
        fi
        error "端口无效，请输入 1-65535。"
    done
}

# --- 防火墙配置（幂等：清理旧端口 + 开放新端口 + 确保内部端口不对外开放） ---
# 参数: external_port [internal_port] [old_external_port] [old_internal_port]
setup_firewalld() {
    local external_port="$1"
    local internal_port="${2:-}"
    local old_external_port="${3:-}"
    local old_internal_port="${4:-}"

    if ! command -v firewall-cmd &>/dev/null; then
        info "firewalld 未安装，正在自动安装..."
        if command -v apt &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y firewalld &> /dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y firewalld &> /dev/null
        elif command -v yum &>/dev/null; then
            yum install -y firewalld &> /dev/null
        fi
        if ! command -v firewall-cmd &>/dev/null; then
            warning "firewalld 安装失败，请手动配置防火墙：开放 ${external_port}/tcp"
            [[ -n "$internal_port" ]] && warning "并确保 ${internal_port}/tcp 不要对外开放"
            return 1
        fi
        success "firewalld 安装成功。"
    fi

    if ! systemctl is-active --quiet firewalld; then
        info "firewalld 未运行，正在启动..."
        systemctl start firewalld >/dev/null 2>&1 || {
            warning "firewalld 启动失败，请手动配置防火墙规则。"
            return 1
        }
    fi

    info "正在配置防火墙规则..."
    # 1) 先关闭不再需要的旧端口（端口变更 / 关闭防盗刷时）
    if [[ -n "$old_external_port" && "$old_external_port" != "$external_port" ]]; then
        firewall-cmd --permanent --remove-port="${old_external_port}/tcp" >/dev/null 2>&1 || true
        info "已关闭旧的外部端口: ${old_external_port}/tcp"
    fi
    if [[ -n "$old_internal_port" && ( -z "$internal_port" || "$old_internal_port" != "$internal_port" ) ]]; then
        firewall-cmd --permanent --remove-port="${old_internal_port}/tcp" >/dev/null 2>&1 || true
    fi

    # 2) 开放当前外部端口
    firewall-cmd --permanent --add-port="${external_port}/tcp" >/dev/null 2>&1 || true

    # 3) 内部端口任何情况下都不对外开放
    if [[ -n "$internal_port" ]]; then
        firewall-cmd --permanent --remove-port="${internal_port}/tcp" >/dev/null 2>&1 || true
    fi

    firewall-cmd --reload >/dev/null 2>&1 || true

    if [[ -n "$internal_port" ]]; then
        success "防火墙规则已生效：外部端口 ${external_port} 已开放，内部端口 ${internal_port} 未对外开放。"
    else
        success "防火墙规则已生效：外部端口 ${external_port} 已开放（直连模式，无内部转发端口）。"
    fi
}

# 开放额外端口（如 Shadowsocks），不涉及内部端口逻辑
# 参数: $1=端口  $2=用途名称(可选，仅用于输出)
open_extra_port() {
    local port="$1"
    local label="${2:-额外}"
    [[ -n "$port" ]] || return 0
    if ! command -v firewall-cmd &>/dev/null; then
        warning "firewalld 未安装，请手动开放 ${port}/tcp"
        return 0
    fi
    if ! systemctl is-active --quiet firewalld; then
        return 0
    fi
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "已开放 ${label} 端口: ${port}/tcp"
    return 0
}

write_config() {
    local inbounds_json="$1"
    local sni="${2:-}"
    local config_content

    # sni 非空表示启用了 dokodemo 防盗刷，此时才需要 SNI 白名单 routing + block 出站
    if [[ -n "$sni" ]]; then
        config_content=$(jq -n --argjson inbounds "$inbounds_json" --arg sni "$sni" \
        '{
          "log": {"loglevel": "warning"},
          "inbounds": $inbounds,
          "outbounds": [
            {
              "protocol": "freedom",
              "tag": "direct",
              "settings": {
                "domainStrategy": "UseIPv4v6"
              }
            },
            {
              "protocol": "blackhole",
              "tag": "block"
            }
          ],
          "routing": {
            "rules": [
              {
                "inboundTag": ["dokodemo-in"],
                "domain": [$sni],
                "outboundTag": "direct"
              },
              {
                "inboundTag": ["dokodemo-in"],
                "outboundTag": "block"
              }
            ]
          }
        }')
    else
        config_content=$(jq -n --argjson inbounds "$inbounds_json" \
        '{
          "log": {"loglevel": "warning"},
          "inbounds": $inbounds,
          "outbounds": [
            {
              "protocol": "freedom",
              "settings": {
                "domainStrategy": "UseIPv4v6"
              }
            }
          ]
        }')
    fi

    if ! echo "$config_content" | jq . >/dev/null 2>&1; then
        error "生成的配置文件格式错误！"
        return 1
    fi

    echo "$config_content" > "$xray_config_path"

    chmod 644 "$xray_config_path"
    chown root:root "$xray_config_path"
}

execute_official_script() {
    local args="$1"
    local script_content log_file pid
    log_file=$(mktemp /tmp/xray-install.XXXXXX.log 2>/dev/null || echo "/tmp/xray-install.$$.log")

    script_content=$(curl -fsSL --max-time 60 "$xray_install_script_url" 2>/dev/null) || {
        error "下载 Xray 官方安装脚本失败（网络不可达或 DNS 异常）。"
        rm -f "$log_file"
        return 1
    }
    if [[ -z "$script_content" || ! "$script_content" =~ "install-release" ]]; then
        error "下载到的官方安装脚本内容异常（可能被劫持或返回了错误页）。"
        rm -f "$log_file"
        return 1
    fi

    # 官方调用形式: bash -c "<script>" @ <command> [options]
    # 这里的 @ 是 $0 占位符（防止后续参数被 bash 当自身选项），
    # 不能写成 bash script.sh @ args —— 那样 --xxx 会被 bash 自身解析报 unknown option
    # shellcheck disable=SC2086  # args 需按空格拆分（如 "install --without-geodata"）
    bash -c "$script_content" @ $args > "$log_file" 2>&1 &
    pid=$!
    spinner $pid
    if ! wait $pid; then
        error "官方安装器执行失败（参数: ${args}），日志摘要："
        tail -n 25 "$log_file" >&2
        info "完整日志保留在: ${cyan}${log_file}${none}"
        return 1
    fi
    rm -f "$log_file"
    return 0
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    # --without-geodata: 官方安装器默认会先拉 Loyalsoldier 的 geoip/geosite，
    # 该源经常失败；这里让官方只装核心，数据文件统一由 install_geodata 处理。
    if ! execute_official_script "install --without-geodata"; then
        error "Xray 核心安装失败！"
        return 1
    fi

    install_geodata

    success "Xray 核心及数据文件已准备就绪。"
}

# 数据文件：官方源装不上时，询问是否用 wget 从 MetaCubeX 下载
install_geodata() {
    local geosite_url="${geodata_release_url}/download/geosite.dat"
    local geoip_url="${geodata_release_url}/download/geoip.dat"
    local need_geosite=false need_geoip=false answer=""

    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    # 官方子命令是 update-geodata，不是 install-geodata
    if ! execute_official_script "update-geodata"; then
        error "Geo-data 更新失败！"
        info "这通常不影响核心功能，您可以稍后手动更新。"
    fi

    [[ -s "$xray_dat_dir/geosite.dat" ]] || need_geosite=true
    [[ -s "$xray_dat_dir/geoip.dat" ]] || need_geoip=true
    if [[ "$need_geosite" = false && "$need_geoip" = false ]]; then
        return 0
    fi

    warning "官方数据源未能提供以下文件：${need_geosite:+geosite.dat }${need_geoip:+geoip.dat}"
    echo -e "  ${cyan}下载源:${none}   https://github.com/MetaCubeX/meta-rules-dat/releases/latest"
    echo -e "  ${cyan}geosite 地址:${none} ${geosite_url}"
    echo -e "  ${cyan}geoip 地址:${none}   ${geoip_url}"
    echo -e "  ${cyan}安装路径:${none}   ${xray_dat_dir}/geosite.dat, ${xray_dat_dir}/geoip.dat"
    read -p " 是否用 wget 从 MetaCubeX 手动下载？[Y/n]: " answer || true
    if [[ "$answer" =~ ^[nN]$ ]]; then
        info "已跳过手动下载，数据文件保持原样。"
        return 0
    fi

    mkdir -p "$xray_dat_dir"
    if [[ "$need_geosite" = true ]]; then
        echo -e " 正在下载: ${cyan}${geosite_url}${none}"
        if wget -O "$xray_dat_dir/geosite.dat" "$geosite_url"; then
            success "geosite.dat 下载成功。"
        else
            warning "geosite.dat 下载失败，Xray 仍可运行。"
            rm -f "$xray_dat_dir/geosite.dat"
        fi
    fi
    if [[ "$need_geoip" = true ]]; then
        echo -e " 正在下载: ${cyan}${geoip_url}${none}"
        if wget -O "$xray_dat_dir/geoip.dat" "$geoip_url"; then
            success "geoip.dat 下载成功。"
        else
            warning "geoip.dat 下载失败，Xray 仍可运行。"
            rm -f "$xray_dat_dir/geoip.dat"
        fi
    fi
}

# --- 输入验证与交互函数 ---
is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_port_available() {
    local port="$1"
    is_valid_port "$port" || return 1

    if ss -tlpn 2>/dev/null | grep -q ":$port "; then
        warning "端口 $port 已被占用，建议选择其他端口"
        return 1
    fi
    return 0
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]
}

# --- reality-checker 集成（可选工具，自动探测；找不到就跳过） ---
# 工具来源: https://github.com/V2RaySSR/RealityChecker
# 用法: reality-checker check <域名>
find_reality_checker() {
    local c
    # 1) PATH 中直接可用
    if command -v reality-checker &>/dev/null; then
        command -v reality-checker
        return 0
    fi
    # 2) 脚本同目录（用户习惯放置位置）
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || script_dir=""
    if [[ -n "$script_dir" ]]; then
        for c in "$script_dir/reality-checker" "$script_dir/RealityChecker/reality-checker"; do
            if [[ -x "$c" ]]; then echo "$c"; return 0; fi
        done
    fi
    # 3) 常见安装路径
    for c in /usr/local/bin/reality-checker /usr/bin/reality-checker /root/reality-checker "$HOME/reality-checker"; do
        if [[ -x "$c" ]]; then echo "$c"; return 0; fi
    done
    return 1
}

# 调用 reality-checker 展示检测结果；未安装时静默跳过
run_reality_checker() {
    local domain="$1"
    local bin=""

    bin=$(find_reality_checker) || bin=""
    if [[ -z "$bin" ]]; then
        info "未检测到 reality-checker，跳过第三方检测。"
        info "如需更完整的评估（CDN/被墙/热门度），可从以下地址安装："
        info "  ${cyan}https://github.com/V2RaySSR/RealityChecker/releases/latest${none}"
        return 0
    fi

    info "使用 reality-checker 检测: ${cyan}${bin}${none}"
    local output rc=0
    # 只取 stdout：2>/dev/null 避免 stderr 日志混入表格导致边框错位
    # timeout 60：该工具会做被墙/GeoIP/CDN 多轮网络请求，防止无限等待
    output=$(timeout 60 "$bin" check "$domain" 2>/dev/null) || rc=$?

    if [[ "$rc" == 124 ]]; then
        warning "reality-checker 执行超时（60s），已跳过（不影响安装）。"
        return 0
    fi
    if [[ -z "$output" ]]; then
        warning "reality-checker 无输出，跳过（不影响安装）。"
        return 0
    fi

    # 展示结果（限制行数，避免刷屏）
    echo "$output" | sed -n '1,40p'
    if [[ "$rc" != 0 ]]; then
        warning "reality-checker 退出码非 0（${rc}），结果仅供参考。"
    fi
    info "注意：若「最终域名」与输入的 SNI 不同，说明目标发生了重定向；"
    info "REALITY 的 SNI 必须与证书域名匹配，请自行确认该重定向是否影响握手。"
    return 0
}

# 用 xray tls ping 校验 SNI 是否被目标接受（用目标真实 IP，不要用 1.1.1.1）
# 参数: $1=域名  $2=是否运行 reality-checker(true|false, 默认 false)
# 返回 0 = 可用；1 = with SNI 握手失败，目标不可用作 REALITY target
# 结果通过全局变量 SNI_PQV / SNI_CHAIN_LEN 回传给调用方，用于决定是否询问 mldsa65
#
# 注意：reality-checker 会做多轮网络请求，耗时可达数十秒，因此仅在用户交互输入
# SNI 时显示（with_checker=true）；安装后的补测、改配置时的重复探测均只做 tls ping。
SNI_PQV=false
SNI_CHAIN_LEN=""

check_sni_target() {
    local domain="$1"
    local with_checker="${2:-false}"
    SNI_PQV=false
    SNI_CHAIN_LEN=""
    local ping_ok=true

    # --- 第一部分：xray tls ping（毫秒级，始终执行） ---
    if [[ -x "$xray_binary_path" ]]; then
        local target_ip output
        target_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}') || target_ip=""
        if [[ -z "$target_ip" ]]; then
            warning "无法解析 $domain 的 IPv4 地址，跳过 tls ping 探活。"
        else
            draw_divider
            echo -e "${cyan} [ 目标探测: xray tls ping → ${domain} (${target_ip}) ]${none}"
            output=$("$xray_binary_path" tls ping "$domain" --ip "$target_ip" 2>&1) || true
            echo "$output" | sed -n '1,24p'

            if ! echo "$output" | grep -q "Handshake succeeded"; then
                ping_ok=false
                error "目标 $domain 与该 SNI 握手失败，REALITY 会表现为连不上！"
                warning "请换单站域名（避开 *.pantheon.io / *.pages.dev / *.vercel.app 等多租户托管）。"
            else
                if echo "$output" | grep -q "TLS Post-Quantum key exchange:[[:space:]]*true"; then
                    SNI_PQV=true
                fi
                SNI_CHAIN_LEN=$(echo "$output" | grep "Certificate chain's total length" | sed -n '1p' | awk '{print $5}') || SNI_CHAIN_LEN=""
                info "SNI 探活通过。后量子密钥交换: ${cyan}${SNI_PQV}${none}${SNI_CHAIN_LEN:+, 证书链长度: ${cyan}${SNI_CHAIN_LEN}${none}}"

                if [[ "$SNI_PQV" = true ]]; then
                    if [[ -n "$SNI_CHAIN_LEN" && "$SNI_CHAIN_LEN" -gt 3500 ]]; then
                        info "该目标可启用 mldsa65 抗量子签名（安装时可选择，默认不启用）。"
                    else
                        warning "该目标支持后量子密钥交换，但证书链不足 3501，不建议启用 mldsa65。"
                    fi
                else
                    info "该目标不支持后量子密钥交换，使用标准 x25519（无需 mldsa65）。"
                fi
            fi
        fi
    else
        info "xray 尚未安装，跳过 tls ping 探活（安装完成后会补测）。"
    fi

    # --- 第二部分：reality-checker 第三方检测（仅交互输入 SNI 时展示，避免重复耗时） ---
    if [[ "$with_checker" == true ]]; then
        draw_divider
        run_reality_checker "$domain"
        draw_divider
    fi

    [[ "$ping_ok" == true ]] && return 0 || return 1
}

prompt_for_vless_config() {
    local -n p_port="$1" p_uuid="$2" p_sni="$3"
    local default_port="${4:-443}"

    while true; do
        read -p "$(echo -e " -> 请输入 VLESS 端口 (默认: ${cyan}${default_port}${none}): ")" p_port || true
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available "$p_port"; then break; fi
    done
    info "VLESS 端口将使用: ${cyan}${p_port}${none}"

    read -p "$(echo -e " -> 请输入UUID (留空将自动生成): ")" p_uuid || true
    if [[ -z "$p_uuid" ]]; then
        p_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${p_uuid}${none}"
    fi

    while true; do
        read -p "$(echo -e " -> 请输入SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" p_sni || true
        [[ -z "$p_sni" ]] && p_sni="learn.microsoft.com"
        if ! is_valid_domain "$p_sni"; then
            error "域名格式无效，请重新输入。"
            continue
        fi
        if check_sni_target "$p_sni" true; then break; fi
        warning "目标不接受该 SNI，请换一个域名后重试。"
    done
    info "SNI 域名将使用: ${cyan}${p_sni}${none}"
}
prompt_for_ss_config() {
    local -n p_port="$1" p_pass="$2"
    local default_port="${3:-8388}"

    while true; do
        read -p "$(echo -e " -> 请输入 Shadowsocks 端口 (默认: ${cyan}${default_port}${none}): ")" p_port || true
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available "$p_port"; then break; fi
    done
    info "Shadowsocks 端口将使用: ${cyan}${p_port}${none}"

    read -p "$(echo -e " -> 请输入 Shadowsocks 密钥 (留空将自动生成): ")" p_pass || true
    if [[ -z "$p_pass" ]]; then
        p_pass=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${p_pass}${none}"
    fi
}

# --- 菜单功能函数 ---
draw_divider() {
    printf "%0.s─" {1..48}
    printf "\n"
}

draw_menu_header() {
    clear
    echo -e "${cyan} Xray VLESS-Reality & Shadowsocks-2022 管理脚本${none}"
    echo -e "${yellow} Version: ${SCRIPT_VERSION}${none}"
    draw_divider
    check_xray_status
    echo -e "${xray_status_info}"
    quick_status
    draw_divider
}

press_any_key_to_continue() {
    echo ""
    read -n 1 -s -r -p " 按任意键返回主菜单..." || true
}

install_menu() {
    local vless_exists="" ss_exists=""
    if [[ -f "$xray_config_path" ]]; then
        vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
        ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    fi

    draw_menu_header
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "您已安装 VLESS-Reality + Shadowsocks-2022 双协议。"
        info "如需修改，请使用主菜单的修改配置选项。如需重装，请先卸载后，再重新安装。"
        return
    elif [[ -n "$vless_exists" && -z "$ss_exists" ]]; then
        info "检测到您已安装 VLESS-Reality"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 Shadowsocks-2022 (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 VLESS-Reality"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) add_ss_to_vless ;; 2) install_vless_only ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -z "$vless_exists" && -n "$ss_exists" ]]; then
        info "检测到您已安装 Shadowsocks-2022"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 VLESS-Reality (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) add_vless_to_ss ;; 2) install_ss_only ;; 0) return ;; *) error "无效选项。" ;; esac
    else
        clean_install_menu
    fi
}

clean_install_menu() {
    draw_menu_header
    echo -e "${cyan} 请选择要安装的协议类型${none}"
    draw_divider
    printf "  ${green}%-2s${none} %-35s\n" "1." "仅 VLESS-Reality"
    printf "  ${cyan}%-2s${none} %-35s\n" "2." "仅 Shadowsocks-2022"
    printf "  ${yellow}%-2s${none} %-35s\n" "3." "VLESS-Reality + Shadowsocks-2022 (双协议)"
    draw_divider
    printf "  ${magenta}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider
    read -p " 请输入选项 [0-3]: " choice || true
    case "$choice" in 1) install_vless_only ;; 2) install_ss_only ;; 3) install_dual ;; 0) return ;; *) error "无效选项。" ;; esac
}

add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi
    local vless_inbound dokodemo_inbound vless_port vless_domain default_ss_port ss_port ss_password ss_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    dokodemo_inbound=$(jq '.inbounds[] | select(.tag == "dokodemo-in")' "$xray_config_path" 2>/dev/null || true)
    vless_port=$(echo "$vless_inbound" | jq -r '.port')
    vless_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    default_ss_port=$([[ "$vless_port" == "443" ]] && echo "8388" || echo "$((vless_port + 1))")

    prompt_for_ss_config ss_port ss_password "$default_ss_port"

    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    if [[ -n "$dokodemo_inbound" ]]; then
        write_config "[$dokodemo_inbound, $vless_inbound, $ss_inbound]" "$vless_domain"
    else
        write_config "[$vless_inbound, $ss_inbound]"
    fi

    if ! restart_xray; then return 1; fi

    open_extra_port "$ss_port" "Shadowsocks"

    success "追加安装成功！"
    view_all_info
}

add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi
    local ss_inbound ss_port default_vless_port vless_port vless_uuid vless_domain internal_port key_pair private_key public_key vless_inbound dokodemo_inbound mldsa65_seed="" mldsa65_verify=""
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    ss_port=$(echo "$ss_inbound" | jq -r '.port')
    default_vless_port=$([[ "$ss_port" == "8388" ]] && echo "443" || echo "$((ss_port - 1))")

    prompt_for_vless_config vless_port vless_uuid vless_domain "$default_vless_port"
    prompt_for_dokodemo no false
    if [[ "$USE_DOKODEMO" == true ]]; then
        prompt_for_internal_port internal_port 23333 23333
    else
        internal_port=""
    fi
    # 确保 SNI_PQV/SNI_CHAIN_LEN 为本次所选域名的最新探测结果
    check_sni_target "$vless_domain" || warning "SNI 探活未通过，仍继续安装；如连不上请更换域名。"

    info "正在生成 Reality 密钥对..."
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password/ {print $3}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    if prompt_for_mldsa65 "$vless_domain" "$SNI_PQV" "$SNI_CHAIN_LEN" mldsa65_seed mldsa65_verify; then
        write_mldsa65_verify "$mldsa65_verify"
    fi
    # 回退时保留已有限速设置
    local existing_limit
    existing_limit=$(jq -r '(.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.limitFallbackUpload) // empty | if . == "" then "" else "\(.afterBytes),\(.bytesPerSec),\(.burstBytesPerSec)" end' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$existing_limit" ]]; then
        FALLBACK_LIMIT="$existing_limit"
        info "检测到已有回落限速设置，保留: ${cyan}${FALLBACK_LIMIT}${none}"
    else
        prompt_for_fallback_limit
    fi

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key" "$internal_port" "$mldsa65_seed" "$FALLBACK_LIMIT" "$use_dokodemo")
    dokodemo_inbound=$(build_dokodemo_inbound "$vless_domain" "$internal_port")
    if [[ "$use_dokodemo" == true ]]; then
        write_config "[$dokodemo_inbound, $vless_inbound, $ss_inbound]" "$vless_domain"
    else
        write_config "[$vless_inbound, $ss_inbound]"
    fi

    if ! restart_xray; then return 1; fi

    setup_firewalld "$vless_port" "$internal_port"

    success "追加安装成功！"
    view_all_info
}

install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain internal_port
    prompt_for_vless_config port uuid domain
    prompt_for_dokodemo no false
    if [[ "$USE_DOKODEMO" == true ]]; then
        prompt_for_internal_port internal_port 23333 23333
    else
        internal_port=""
    fi
    run_install_vless "$port" "$uuid" "$domain" "$internal_port"
}

install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password
    prompt_for_ss_config port password
    run_install_ss "$port" "$password"
}

install_dual() {
    info "开始配置双协议 (VLESS-Reality + Shadowsocks-2022)..."
    local vless_port vless_uuid vless_domain ss_port ss_password internal_port
    prompt_for_vless_config vless_port vless_uuid vless_domain
    prompt_for_dokodemo no false
    if [[ "$USE_DOKODEMO" == true ]]; then
        prompt_for_internal_port internal_port 23333 23333
    else
        internal_port=""
    fi

    local default_ss_port
    if [[ "$vless_port" == "443" ]]; then
        default_ss_port=8388
    else
        default_ss_port=$((vless_port + 1))
    fi

    prompt_for_ss_config ss_port ss_password "$default_ss_port"

    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password" "$internal_port"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在检查最新版本..."
    local current_version latest_version api_resp force=""
    current_version=$("$xray_binary_path" version 2>/dev/null | sed -n '1p' | awk '{print $2}')

    # -fSL: HTTP 错误直接失败；--max-time 防止卡死；不再静默吞掉限流/网络错误
    local curl_rc=0
    api_resp=$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null) || curl_rc=$?
    if [[ "$curl_rc" != 0 ]]; then
        error "请求 GitHub API 失败（curl 退出码 ${curl_rc}：6=DNS 解析失败, 7=连接失败, 28=超时）。"
        info "可手动更新: bash -c \"\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install"
        return 1
    fi
    latest_version=$(echo "$api_resp" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        error "无法解析最新版本号（GitHub API 可能已限流，未认证请求限制为 60 次/小时）。"
        info "API 原始响应: $(echo "$api_resp" | head -c 200)"
        return 1
    fi

    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"

    if [[ "$current_version" == "$latest_version" ]]; then
        success "您的 Xray 已是最新版本（${current_version}）。"
        read -p " 是否强制重装当前版本（用于修复/验证安装链路）？[y/N]: " force || true
        if [[ ! "$force" =~ ^[yY]$ ]]; then
            return 0
        fi
        info "开始强制重装 ${latest_version}..."
    else
        info "发现新版本，开始更新..."
    fi

    if ! run_core_install; then
        error "Xray 核心更新失败，版本未变更（当前仍为 ${current_version}）。"
        return 1
    fi
    if ! restart_xray; then
        error "核心文件已更新，但服务重启失败。请检查: journalctl -u xray -n 50 --no-pager"
        return 1
    fi

    # 回读实际版本，避免“看起来成功”
    local new_version
    new_version=$("$xray_binary_path" version 2>/dev/null | sed -n '1p' | awk '{print $2}')
    if [[ "$new_version" == "$latest_version" ]]; then
        if [[ "$current_version" == "$latest_version" ]]; then
            success "重装完成：版本 ${new_version} 未变（安装链路正常）。"
        else
            success "Xray 更新成功：${current_version} → ${new_version}"
        fi
    else
        warning "服务已重启，但版本仍为 ${new_version}（预期 ${latest_version}）。"
        info "PATH 中的 xray: $(command -v xray 2>/dev/null || echo '未找到')"
        info "实际二进制: ${xray_binary_path}"
    fi
}

# 诊断：一次性输出安装链路各环节状态，用于定位“更新无反应”类问题
diagnose_xray() {
    draw_menu_header
    echo -e "${cyan} Xray 安装诊断${none}"
    draw_divider
    echo -e " 二进制路径: ${xray_binary_path}"
    if [[ -x "$xray_binary_path" ]]; then
        echo -e " 版本: $("$xray_binary_path" version 2>&1 | sed -n '1p')"
        echo -e " 二进制修改时间: $(stat -c '%y' "$xray_binary_path" 2>/dev/null || echo '未知')"
        echo -e " 二进制大小: $(stat -c '%s' "$xray_binary_path" 2>/dev/null || echo '未知') 字节"
    else
        echo -e " ${red}未找到可执行的 xray${none}"
    fi
    echo -e " PATH 中的 xray: $(command -v xray 2>/dev/null || echo '未找到')"
    echo -e " 服务状态: $(systemctl is-active xray 2>/dev/null || echo 'inactive')"
    echo -e " 配置文件: $([[ -f "$xray_config_path" ]] && echo '存在' || echo '缺失')"
    if [[ -f "$xray_config_path" && -x "$xray_binary_path" ]]; then
        if "$xray_binary_path" run -test -c "$xray_config_path" >/dev/null 2>&1; then
            echo -e " 配置校验: ${green}通过${none}"
        else
            echo -e " 配置校验: ${red}失败${none}"
        fi
    fi
    echo -e " GitHub API: $(curl -fsS --max-time 8 https://api.github.com/rate_limit >/dev/null 2>&1 && echo -e "${green}可达${none}" || echo -e "${red}不可达${none}")"
    echo -e " 安装脚本: $(curl -fsS --max-time 8 -o /dev/null -w '%{http_code}' "$xray_install_script_url" 2>/dev/null || echo '失败')"
    echo -e " geosite.dat: $([[ -s "$xray_dat_dir/geosite.dat" ]] && echo "存在 ($(stat -c%s "$xray_dat_dir/geosite.dat") 字节)" || echo -e "${red}缺失${none}")"
    echo -e " geoip.dat: $([[ -s "$xray_dat_dir/geoip.dat" ]] && echo "存在 ($(stat -c%s "$xray_dat_dir/geoip.dat") 字节)" || echo -e "${red}缺失${none}")"
    echo -e " 磁盘剩余: $(df -h / | awk 'NR==2 {print $4}')"
    draw_divider
    info "若 API 不可达但安装脚本可达，可手动执行:"
    info "bash -c \"\$(curl -fsSL ${xray_install_script_url})\" @ install"
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    read -p "$(echo -e "${yellow}您确定要卸载 Xray 吗？这将删除所有配置！[Y/n]: ${none}")" confirm || true
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        info "操作已取消。"
        return
    fi

    # 先读取端口，卸载后配置文件会被删除
    local vless_port="" internal_port="" ss_port=""
    if [[ -f "$xray_config_path" ]]; then
        vless_port=$(jq -r '.inbounds[] | select(.protocol == "vless") | .port' "$xray_config_path" 2>/dev/null || true)
        internal_port=$(jq -r '.inbounds[] | select(.tag == "dokodemo-in") | .port' "$xray_config_path" 2>/dev/null || true)
        ss_port=$(jq -r '.inbounds[] | select(.protocol == "shadowsocks") | .port' "$xray_config_path" 2>/dev/null || true)
    fi

    info "正在卸载 Xray..."
    if ! execute_official_script "remove --purge"; then
        error "Xray 卸载失败！"
        return 1
    fi

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        info "正在清理防火墙规则..."
        [[ -n "$vless_port" ]] && firewall-cmd --permanent --remove-port="${vless_port}/tcp" >/dev/null 2>&1 || true
        [[ -n "$internal_port" ]] && firewall-cmd --permanent --remove-port="${internal_port}/tcp" >/dev/null 2>&1 || true
        [[ -n "$ss_port" ]] && firewall-cmd --permanent --remove-port="${ss_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        warning "提示：以上仅清理当前配置中的端口。若你曾用旧版脚本改过端口，"
        warning "可能仍有历史端口残留，请执行 firewall-cmd --list-ports 自行确认。"
    fi

    rm -f ~/xray_subscription_info.txt
    # 清理本脚本自建的文件（官方 remove --purge 未必覆盖自定义文件）
    rm -f "$mldsa65_record_path"
    success "Xray 已成功卸载。"
}

# 关闭 mldsa65：删除 mldsa65Seed，回到纯 x25519（不改 UUID/端口/SNI/密钥）
disable_mldsa65() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装。" && return; fi

    local seed
    seed=$(jq -r '.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.mldsa65Seed // empty' "$xray_config_path" 2>/dev/null || true)
    if [[ -z "$seed" ]]; then
        info "当前未启用 mldsa65，无需回退。"
        return 0
    fi

    warning "将删除 mldsa65Seed，回到标准 x25519 REALITY。"
    info "其它配置（UUID / 端口 / SNI / 密钥 / Shadowsocks）保持不变。"
    read -p " 确认关闭 mldsa65？[y/N]: " confirm || true
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "操作已取消。"
        return 0
    fi

    local tmp_config
    tmp_config=$(mktemp)
    if ! jq '(.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings) |= del(.mldsa65Seed)' \
        "$xray_config_path" > "$tmp_config"; then
        rm -f "$tmp_config"
        error "生成新配置失败，原配置未改动。"
        return 1
    fi

    local vless_domain
    vless_domain=$(jq -r '.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.serverNames[0]' "$tmp_config" 2>/dev/null || true)
    local ss_exists
    ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$tmp_config" 2>/dev/null || true)
    if [[ -z "$vless_domain" ]]; then
        rm -f "$tmp_config"
        error "读取 SNI 失败，原配置未改动。"
        return 1
    fi

    mv "$tmp_config" "$xray_config_path"
    chmod 644 "$xray_config_path"
    chown root:root "$xray_config_path"
    if [[ -n "$ss_exists" ]]; then
        info "Shadowsocks 配置已保留。"
    fi

    rm -f "$mldsa65_record_path"

    if ! restart_xray; then return 1; fi

    success "mldsa65 已关闭，realitySettings 仅保留 x25519。"
    view_all_info
}

modify_config_menu() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装。" && return; fi

    local vless_exists="" ss_exists=""
    vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)

    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        draw_menu_header
        echo -e "${cyan} 请选择要修改的协议配置${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "VLESS-Reality"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) modify_vless_config ;; 2) modify_ss_config ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -n "$vless_exists" ]]; then
        modify_vless_config
    elif [[ -n "$ss_exists" ]]; then
        modify_ss_config
    else
        error "未找到可修改的协议配置。"
    fi
}

modify_vless_config() {
    info "开始修改 VLESS-Reality 配置..."
    local vless_inbound current_port current_uuid current_domain private_key public_key port uuid domain internal_port new_vless_inbound dokodemo_inbound ss_inbound new_inbounds current_seed mldsa65_seed="" mldsa65_verify=""
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    current_port=$(echo "$vless_inbound" | jq -r '.port')
    current_uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
    current_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    private_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.privateKey')
    public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
    # 保留既有 mldsa65Seed，避免修改端口/SNI 时丢失
    current_seed=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.mldsa65Seed // empty' 2>/dev/null || true)
    mldsa65_seed="$current_seed"

    # 读取当前 dokodemo 状态与内部端口
    local cur_dokodemo=false cur_internal_port=""
    if has_dokodemo; then
        cur_dokodemo=true
        cur_internal_port=$(jq -r '.inbounds[] | select(.tag == "dokodemo-in") | .port' "$xray_config_path" 2>/dev/null || echo "23333")
    fi

    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port=$current_port
        if is_port_available "$port" || [[ "$port" == "$current_port" ]]; then break; fi
    done

    read -p "$(echo -e " -> 新UUID (当前: ${cyan}${current_uuid}${none}, 留空不改): ")" uuid || true
    [[ -z "$uuid" ]] && uuid=$current_uuid

    while true; do
        read -p "$(echo -e " -> 新SNI域名 (当前: ${cyan}${current_domain}${none}, 留空不改): ")" domain || true
        [[ -z "$domain" ]] && domain=$current_domain
        if ! is_valid_domain "$domain"; then
            error "域名格式无效，请重新输入。"
            continue
        fi
        if [[ "$domain" == "$current_domain" ]]; then
            # 未改域名：仅在没有 mldsa65 时才需要探测（为后续询问准备 SNI_PQV/SNI_CHAIN_LEN）
            if [[ -z "$mldsa65_seed" ]]; then
                check_sni_target "$domain" || true
            fi
            break
        fi
        if check_sni_target "$domain" true; then break; fi
        warning "目标不接受该 SNI，请换一个域名后重试。"
    done

    # 防盗刷开关：留空保持现状，y 启用，n 关闭
    prompt_for_dokodemo no true
    local use_dokodemo="$USE_DOKODEMO"
    if [[ "$use_dokodemo" == true ]]; then
        local new_internal_port
        prompt_for_internal_port new_internal_port "${cur_internal_port:-23333}" 23333
        internal_port="$new_internal_port"
    else
        internal_port=""
    fi

    # 仅当当前未启用 mldsa65 时才询问是否新增启用
    if [[ -z "$mldsa65_seed" ]]; then
        if prompt_for_mldsa65 "$domain" "$SNI_PQV" "$SNI_CHAIN_LEN" mldsa65_seed mldsa65_verify; then
            write_mldsa65_verify "$mldsa65_verify"
        fi
    else
        info "检测到已启用 mldsa65，保留现有配置。"
    fi

    # 回落限速：显示当前状态，允许保留/修改/清除
    FALLBACK_LIMIT=""
    local cur_limit cur_after cur_rate cur_burst
    cur_limit=$(jq -r '.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.limitFallbackUpload // empty' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$cur_limit" ]]; then
        cur_after=$(echo "$cur_limit" | jq -r '.afterBytes')
        cur_rate=$(echo "$cur_limit" | jq -r '.bytesPerSec')
        cur_burst=$(echo "$cur_limit" | jq -r '.burstBytesPerSec')
        info "当前回落限速: afterBytes=${cur_after}, bytesPerSec=${cur_rate}, burstBytesPerSec=${cur_burst}"
        local limit_choice
        read -p " 回落限速 [1=保留 2=重新设置 3=关闭] (默认1): " limit_choice || true
        case "$limit_choice" in
            2) prompt_for_fallback_limit ;;
            3) info "将关闭回落限速。"; FALLBACK_LIMIT="" ;;
            *) FALLBACK_LIMIT="${cur_after},${cur_rate},${cur_burst}"; info "保留现有限速设置。" ;;
        esac
    else
        read -p "$(echo -e " -> 是否启用回落限速？[y/N]: ")" enable_limit || true
        if [[ "$enable_limit" =~ ^[yY]$ ]]; then
            prompt_for_fallback_limit
        else
            FALLBACK_LIMIT=""
        fi
    fi

    new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key" "$internal_port" "$mldsa65_seed" "$FALLBACK_LIMIT" "$use_dokodemo")
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    if [[ "$use_dokodemo" == true ]]; then
        dokodemo_inbound=$(build_dokodemo_inbound "$domain" "$internal_port")
        new_inbounds="[$dokodemo_inbound, $new_vless_inbound]"
        [[ -n "$ss_inbound" ]] && new_inbounds="[$dokodemo_inbound, $new_vless_inbound, $ss_inbound]"
        write_config "$new_inbounds" "$domain"
    else
        new_inbounds="[$new_vless_inbound]"
        [[ -n "$ss_inbound" ]] && new_inbounds="[$new_vless_inbound, $ss_inbound]"
        write_config "$new_inbounds"
    fi
    if ! restart_xray; then return 1; fi

    # 防火墙：传入旧端口用于清理，避免端口变更后旧端口残留开放
    setup_firewalld "$port" "$internal_port" "$current_port" "${cur_internal_port:-}"

    # 关闭防盗刷时提示残留的旧内部端口已清理
    if [[ "$cur_dokodemo" == true && "$use_dokodemo" == false ]]; then
        info "防盗刷转发已关闭：dokodemo-door inbound 与 routing 规则已移除。"
    elif [[ "$cur_dokodemo" == false && "$use_dokodemo" == true ]]; then
        info "防盗刷转发已启用：dokodemo-door 监听 127.0.0.1:${internal_port}。"
    fi

    success "配置修改成功！"
    view_all_info
}

modify_ss_config() {
    info "开始修改 Shadowsocks-2022 配置..."
    local ss_inbound current_port current_password port password new_ss_inbound vless_inbound dokodemo_inbound vless_domain new_inbounds
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    current_port=$(echo "$ss_inbound" | jq -r '.port')
    current_password=$(echo "$ss_inbound" | jq -r '.settings.password')

    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port=$current_port
        if is_port_available "$port" || [[ "$port" == "$current_port" ]]; then break; fi
    done

    read -p "$(echo -e " -> 新密钥 (当前: ${cyan}${current_password}${none}, 留空不改): ")" password || true
    [[ -z "$password" ]] && password=$current_password

    new_ss_inbound=$(build_ss_inbound "$port" "$password")
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    dokodemo_inbound=$(jq '.inbounds[] | select(.tag == "dokodemo-in")' "$xray_config_path" 2>/dev/null || true)
    vless_domain=""
    if [[ -n "$vless_inbound" ]]; then
        vless_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    fi

    if [[ -n "$dokodemo_inbound" ]]; then
        new_inbounds="[$dokodemo_inbound, $vless_inbound, $new_ss_inbound]"
        write_config "$new_inbounds" "$vless_domain"
    elif [[ -n "$vless_inbound" ]]; then
        new_inbounds="[$vless_inbound, $new_ss_inbound]"
        write_config "$new_inbounds"
    else
        write_config "[$new_ss_inbound]"
    fi
    if ! restart_xray; then return 1; fi

    # 端口变更时关闭旧端口、开放新端口
    if [[ "$port" != "$current_port" ]]; then
        if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --remove-port="${current_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    fi
    open_extra_port "$port" "Shadowsocks"

    success "配置修改成功！"
    view_all_info
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return 1; fi

    info "正在重启 Xray 服务..."
    if ! systemctl restart xray; then
        error "尝试重启 Xray 服务失败！"
        echo -e "\n${yellow}错误详情:${none}"
        systemctl status xray --no-pager -l | tail -5
        return 1
    fi

    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
    else
        error "服务启动失败，详细信息:"
        systemctl status xray --no-pager -l | tail -5
        return 1
    fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

view_all_info() {
    if [ ! -f "$xray_config_path" ]; then
        [[ "$is_quiet" = true ]] && return
        error "错误: 配置文件不存在。"
        return
    fi

    [[ "$is_quiet" = false ]] && clear && echo -e "${cyan} Xray 配置及订阅信息${none}" && draw_divider

    local ip
    ip=$(get_public_ip)
    if [[ -z "$ip" ]]; then
        [[ "$is_quiet" = false ]] && error "无法获取公网 IP 地址。"
        return 1
    fi
    local host
    host=$(hostname)
    local -a links_array=()

    local vless_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$vless_inbound" ]]; then
        local uuid port domain public_key shortid display_ip link_name_raw link_name_encoded vless_url mldsa_verify pqv_param
        uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
        port=$(echo "$vless_inbound" | jq -r '.port')
        domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        mldsa_verify=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.mldsa65Verify // empty' 2>/dev/null || true)
        # 服务端存 mldsa65Seed，客户端链接要用对应的 mldsa65Verify（pqv 参数）
        if [[ -z "$mldsa_verify" && -f "$mldsa65_record_path" ]]; then
            mldsa_verify=$(sed -n 's/^mldsa65Verify=//p' "$mldsa65_record_path" 2>/dev/null | head -n 1)
        fi
        if [[ -z "$mldsa_verify" ]]; then
            local seed
            seed=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.mldsa65Seed // empty' 2>/dev/null || true)
            if [[ -n "$seed" ]]; then
                mldsa_verify=$(mldsa65_verify_from_seed "$seed")
            fi
        fi
        pqv_param=""
        [[ -n "$mldsa_verify" ]] && pqv_param="&pqv=${mldsa_verify}"

        if [[ -z "$public_key" ]]; then
            [[ "$is_quiet" = false ]] && error "VLESS配置不完整，可能已损坏。"
        else
            display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
            link_name_raw="$host X-reality"
            link_name_encoded=$(printf '%s' "$link_name_raw" | jq -sRr @uri)
            vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}${pqv_param}#${link_name_encoded}"
            links_array+=("$vless_url")

            if [[ "$is_quiet" = false ]]; then
                echo -e "${green} [ VLESS-Reality 配置 ]${none}"
                printf "    %s: ${cyan}%s${none}\n" "节点名称" "$link_name_raw"
                printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
                printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
                printf "    %s: ${cyan}%s${none}\n" "UUID" "${uuid}"
                printf "    %s: ${cyan}%s${none}\n" "流控" "xtls-rprx-vision"
                printf "    %s: ${cyan}%s${none}\n" "传输协议" "tcp"
                printf "    %s: ${cyan}%s${none}\n" "安全类型" "reality"
                printf "    %s: ${cyan}%s${none}\n" "SNI" "$domain"
                printf "    %s: ${cyan}%s${none}\n" "指纹" "chrome"
                printf "    %s: ${cyan}%s${none}\n" "PublicKey" "${public_key}"
                printf "    %s: ${cyan}%s${none}\n" "ShortId" "$shortid"
                if [[ -n "$mldsa_verify" ]]; then
                    printf "    %s: ${cyan}%s${none}\n" "ML-DSA-65 Verify (pqv)" "$mldsa_verify"
                fi
                local fw_mode dokodemo_port
                if has_dokodemo; then
                    dokodemo_port=$(jq -r '.inbounds[] | select(.tag == "dokodemo-in") | .port' "$xray_config_path" 2>/dev/null || echo "?")
                    fw_mode="启用 (dokodemo-door ${dokodemo_port} + SNI 白名单)"
                else
                    fw_mode="关闭 (dest 直连 ${domain}:443)"
                fi
                printf "    %s: ${cyan}%s${none}\n" "防盗刷转发" "$fw_mode"
                local limit_upload
                limit_upload=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.limitFallbackUpload // empty' 2>/dev/null || true)
                if [[ -n "$limit_upload" ]]; then
                    printf "    %s: ${cyan}%s${none}\n" "回落限速" \
                        "after $(echo "$limit_upload" | jq -r '.afterBytes') 字节后限速 $(echo "$limit_upload" | jq -r '.bytesPerSec') B/s，突发 $(echo "$limit_upload" | jq -r '.burstBytesPerSec') B/s"
                fi
            fi
        fi
    fi

    local ss_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$ss_inbound" ]]; then
        local port method password link_name_raw ss_url encoded_pass encoded_tag display_host
        port=$(echo "$ss_inbound" | jq -r '.port')
        method=$(echo "$ss_inbound" | jq -r '.settings.method')
        password=$(echo "$ss_inbound" | jq -r '.settings.password')
        link_name_raw="$host X-ss2022"
        # SIP002：2022 系列 AEAD 的 userinfo 必须明文 method:percentEncodedPassword，不能整体 base64
        encoded_pass=$(printf '%s' "$password" | jq -sRr @uri)
        encoded_tag=$(printf '%s' "$link_name_raw" | jq -sRr @uri)
        display_host=$ip && [[ $ip =~ ":" ]] && display_host="[$ip]"
        ss_url="ss://${method}:${encoded_pass}@${display_host}:${port}#${encoded_tag}"
        links_array+=("$ss_url")

        if [[ "$is_quiet" = false ]]; then
            echo ""
            echo -e "${green} [ Shadowsocks-2022 配置 ]${none}"
            printf "    %s: ${cyan}%s${none}\n" "节点名称" "$link_name_raw"
            printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
            printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
            printf "    %s: ${cyan}%s${none}\n" "加密方式" "$method"
            printf "    %s: ${cyan}%s${none}\n" "密码" "${password}"
        fi
    fi

    if [ ${#links_array[@]} -gt 0 ]; then
        if [[ "$is_quiet" = true ]]; then
            printf "%s\n" "${links_array[@]}"
        else
            draw_divider
            printf "%s\n" "${links_array[@]}" > ~/xray_subscription_info.txt
            success "所有订阅链接已汇总保存到: ~/xray_subscription_info.txt"

            echo -e "\n${yellow} --- V2Ray / Clash 等客户端可直接导入以下链接 --- ${none}\n"
            for link in "${links_array[@]}"; do
                echo -e "${cyan}${link}${none}\n"
            done
            if printf '%s\n' "${links_array[@]}" | grep -q 'pqv='; then
                info "本节点已启用 mldsa65（链接含 pqv=）。Xray 系客户端（v2rayN 等）会识别 pqv；"
                info "Mihomo/Clash 内核目前不支持该字段，请忽略 pqv 参数，其余参数照常填写即可连接。"
            fi
            print_client_notes
            draw_divider
        fi
    elif [[ "$is_quiet" = false ]]; then
        info "当前未安装任何协议，无订阅信息可显示。"
    fi
}

# 客户端兼容性提示：依据 Xray-core issue #6714 的官方结论
print_client_notes() {
    local notes
    notes=$(cat <<'NOTE'

 --- 客户端连接须知（重要） ---
 [Xray 服务端 v26.9.8+ 的强制策略]
 REALITY 服务端要求 Client Hello 必须携带 ML-KEM-768 的 key share，
 且必须排在 X25519 之前，否则直接回落到目标站，客户端表现为 "reality verification failed"。
 依据: https://github.com/XTLS/Xray-core/issues/6714#issuecomment-5581324161
   原文: 对于 Xray 只有前三个指纹能连，对于 Mihomo 只能 Chrome，对于 sing-box 不能连

 [Mihomo / Clash 用户 - 必须手动补这两行]
   client-fingerprint: chrome
   reality-opts:
     support-x25519mlkem768: true      # 不写则内核会剥除 ML-KEM，必然连不上
 原因: Mihomo 的该开关默认 false，为 false 时会从 ClientHello 里剔除 ML-KEM。
 参考: https://github.com/MetaCubeX/mihomo/issues/3193
 firefox 指纹在 Mihomo 下无法连接，必须用 chrome。

 [vless:// 链接无法携带该参数]
 VLESS 链接规范里没有 support-x25519mlkem768 字段，直接复制本链接到 Mihomo 会连不上，
 需要按上面的 YAML 手动补齐。Xray 系客户端（v2rayN 等）直接导入链接即可。

 [已知受影响的客户端]
 sing-box / Karing / Shadowrocket: 因 TLS 栈不发 ML-KEM，无法连接该服务端。
 参考: SagerNet/sing-box#4520, KaringX/karing#1952, MHSanaei/3x-ui#6563

NOTE
)
    echo -e "${yellow}${notes}${none}"
}

# --- 核心安装逻辑函数 ---
run_install_vless() {
    local port="$1" uuid="$2" domain="$3" internal_port="$4"
    # 空 internal_port 表示未启用 dokodemo（直连模式），不再赋默认值
    local use_dokodemo=false
    [[ -n "$internal_port" ]] && use_dokodemo=true
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    # 核心刚装好，此时再探活一次（首次安装时 prompt 阶段还没有 xray，探活被跳过）
    check_sni_target "$domain" || warning "SNI 探活未通过，仍继续安装；如连不上请更换域名。"
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound dokodemo_inbound mldsa65_seed="" mldsa65_verify=""
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password/ {print $3}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    if prompt_for_mldsa65 "$domain" "$SNI_PQV" "$SNI_CHAIN_LEN" mldsa65_seed mldsa65_verify; then
        write_mldsa65_verify "$mldsa65_verify"
    fi
    prompt_for_fallback_limit

    vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key" "$internal_port" "$mldsa65_seed" "$FALLBACK_LIMIT" "$use_dokodemo")
    if [[ "$use_dokodemo" == true ]]; then
        dokodemo_inbound=$(build_dokodemo_inbound "$domain" "$internal_port")
        write_config "[$dokodemo_inbound, $vless_inbound]" "$domain"
    else
        write_config "[$vless_inbound]"
    fi

    if ! restart_xray; then exit 1; fi

    setup_firewalld "$port" "$internal_port"

    success "VLESS-Reality 安装成功！"
    view_all_info
}

run_install_ss() {
    local port="$1" password="$2"
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    local ss_inbound
    ss_inbound=$(build_ss_inbound "$port" "$password")
    write_config "[$ss_inbound]"

    if ! restart_xray; then exit 1; fi

    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

run_install_dual() {
    local vless_port="$1" vless_uuid="$2" vless_domain="$3" ss_port="$4" ss_password="$5" internal_port="$6"
    # 空 internal_port 表示未启用 dokodemo（直连模式）
    local use_dokodemo=false
    [[ -n "$internal_port" ]] && use_dokodemo=true
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    check_sni_target "$vless_domain" || warning "SNI 探活未通过，仍继续安装；如连不上请更换域名。"
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound ss_inbound dokodemo_inbound mldsa65_seed="" mldsa65_verify=""
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password/ {print $3}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    if prompt_for_mldsa65 "$vless_domain" "$SNI_PQV" "$SNI_CHAIN_LEN" mldsa65_seed mldsa65_verify; then
        write_mldsa65_verify "$mldsa65_verify"
    fi
    prompt_for_fallback_limit

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key" "$internal_port" "$mldsa65_seed" "$FALLBACK_LIMIT" "$use_dokodemo")
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    if [[ "$use_dokodemo" == true ]]; then
        dokodemo_inbound=$(build_dokodemo_inbound "$vless_domain" "$internal_port")
        write_config "[$dokodemo_inbound, $vless_inbound, $ss_inbound]" "$vless_domain"
    else
        write_config "[$vless_inbound, $ss_inbound]"
    fi

    if ! restart_xray; then exit 1; fi

    setup_firewalld "$vless_port" "$internal_port"
    open_extra_port "$ss_port"

    success "双协议安装成功！"
    view_all_info
}

# --- 主菜单与脚本入口 ---
main_menu() {
    while true; do
        draw_menu_header
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 Xray (VLESS/Shadowsocks)"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "3." "卸载 Xray"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "4." "修改配置"
        printf "  ${cyan}%-2s${none} %-35s\n" "5." "重启 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "6." "查看 Xray 日志"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看订阅信息"
        printf "  ${red}%-2s${none} %-35s\n" "8." "关闭 mldsa65 (回退纯 x25519)"
        printf "  ${magenta}%-2s${none} %-35s\n" "9." "诊断 Xray 安装状态"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        draw_divider

        read -p " 请输入选项 [0-9]: " choice || true

        local needs_pause=true

        case "$choice" in
            1) install_menu || true ;;
            2) update_xray || true ;;
            3) uninstall_xray || true ;;
            4) modify_config_menu || true ;;
            5) restart_xray || true ;;
            6) view_xray_log; needs_pause=false ;;
            7) view_all_info || true ;;
            8) disable_mldsa65 || true ;;
            9) diagnose_xray || true ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项。请输入0到9之间的数字。" ;;
        esac

        if [ "$needs_pause" = true ]; then
            press_any_key_to_continue
        fi
    done
}

# --- 非交互式安装逻辑 ---
non_interactive_usage() {
    cat << 'EOF'

非交互式安装用法:
  ./$(basename "$0") install --type <vless|ss|dual> [选项...]

  通用选项:
    --type <type>      安装类型 (必须: vless, ss, dual)
    --quiet            静默模式, 成功后只输出订阅链接

  VLESS 选项:
    --vless-port <p>   VLESS 端口 (默认: 443)
    --uuid <uuid>      UUID (默认: 随机生成)
    --sni <domain>     SNI 域名 (默认: learn.microsoft.com)
    --internal-port <p>  内部转发端口, 防盗刷 (默认: 23333)

  Shadowsocks 选项:
    --ss-port <p>      Shadowsocks 端口 (默认: 8388)
    --ss-pass <pass>   Shadowsocks 密码 (默认: 随机生成)

  示例:
    # 安装 VLESS (使用默认值)
    ./$(basename "$0") install --type vless

    # 安静地安装双协议并指定 VLESS 端口和 UUID，并将链接保存到文件
    ./$(basename "$0") install --type dual --vless-port 2053 --uuid 'your-uuid-here' --quiet > links.txt
EOF
}

non_interactive_dispatcher() {
    if [[ $# -eq 0 || "$1" != "install" ]]; then
        main_menu
        return
    fi
    shift

    local type="" vless_port="" uuid="" sni="" internal_port="" ss_port="" ss_pass=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) type="$2"; shift 2 ;;
            --vless-port) vless_port="$2"; shift 2 ;;
            --uuid) uuid="$2"; shift 2 ;;
            --sni) sni="$2"; shift 2 ;;
            --internal-port) internal_port="$2"; shift 2 ;;
            --ss-port) ss_port="$2"; shift 2 ;;
            --ss-pass) ss_pass="$2"; shift 2 ;;
            --quiet) is_quiet=true; shift ;;
            *) error "未知参数: $1"; non_interactive_usage; exit 1 ;;
        esac
    done

    case "$type" in
        vless)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            [[ -z "$internal_port" ]] && internal_port=23333
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$sni" || ! is_valid_port "$internal_port"; then
                error "VLESS 参数无效。请检查端口或SNI域名。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装 VLESS..."
            run_install_vless "$vless_port" "$uuid" "$sni" "$internal_port"
            ;;
        ss)
            [[ -z "$ss_port" ]] && ss_port=8388
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            if ! is_valid_port "$ss_port"; then
                error "Shadowsocks 参数无效。请检查端口。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装 Shadowsocks..."
            run_install_ss "$ss_port" "$ss_pass"
            ;;
        dual)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            [[ -z "$internal_port" ]] && internal_port=23333
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            if [[ -z "$ss_port" ]]; then
                if [[ "$vless_port" == "443" ]]; then ss_port=8388; else ss_port=$((vless_port + 1)); fi
            fi
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$sni" || ! is_valid_port "$ss_port" || ! is_valid_port "$internal_port"; then
                error "双协议参数无效。请检查端口或SNI域名。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装双协议..."
            run_install_dual "$vless_port" "$uuid" "$sni" "$ss_port" "$ss_pass" "$internal_port"
            ;;
        *)
            error "必须通过 --type 指定安装类型 (vless|ss|dual)"
            non_interactive_usage
            exit 1
            ;;
    esac
}

# --- 脚本主入口 ---
main() {
    pre_check
    non_interactive_dispatcher "$@"
}

main "$@"
