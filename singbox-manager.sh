#!/usr/bin/env bash
# @bossangs-singbox-manager
# singbox-manager.sh — sing-box multi-protocol manager for Debian/Ubuntu and AlmaLinux (systemd), plus Alpine (OpenRC)
# https://github.com/bossangs/singbox
# Supports native sing-box protocols (VLESS Reality, VMess, Hysteria2, TUIC, AnyTLS, Shadowsocks, Trojan), Cloudflare
# Argo/cloudflared tunnels, plus an isolated Xray sidecar for VLESS + TLS transports (XHTTP preferred).
# Every node type can be added from the menu or from non-interactive CLI flags, and every node type can be used as a
# relay entry or relay/forward landing node.
# Existing configs are backed up before each change. Firewall rules are not changed automatically.
# If another sing-box one-click script is detected, nothing is changed; cleanup steps are printed instead.

set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2026.11.20.1"
MARK="# @bossangs-singbox-manager"
XRAY_MARK="# @bossangs-singbox-xray"
XRAY_USER="singbox-xray"
XRAY_BIN="/usr/local/bin/singbox-xray"
XRAY_DIR="/etc/singbox-xray"
XRAY_DIR_MARKER="$XRAY_DIR/.managed-by-singbox-manager"
XRAY_CONF="$XRAY_DIR/config.json"
XRAY_DATA="$XRAY_DIR/manager"
XRAY_CERT_DIR="$XRAY_DIR/certs"
XRAY_BACKUP_DIR="/var/backups/singbox-xray"
XRAY_BACKUP_MARKER="$XRAY_BACKUP_DIR/.managed-by-singbox-manager"
XRAY_SERVICE="singbox-xray"
XRAY_UNIT="/etc/systemd/system/singbox-xray.service"
XRAY_INIT="/etc/init.d/singbox-xray"
XRAY_LOG="/var/log/singbox-xray.log"
RAW_URL="https://api.github.com/repos/bossangs/singbox/contents/singbox-manager.sh?ref=main"
SHORTCUT="/usr/local/bin/sb"
SS_SHORTCUT="/usr/local/bin/sb5"
CONF_DIR="/etc/sing-box"
CONF="$CONF_DIR/config.json"
DATA="$CONF_DIR/manager"
CERT_DIR="$CONF_DIR/certs"
BACKUP_DIR="/var/backups/sing-box-manager"
SERVICE="sing-box"
TRAFFIC_MARK="# @bossangs-singbox-manager-traffic"
TRAFFIC_SERVICE="singbox-manager-traffic"
TRAFFIC_TOTAL="$DATA/traffic-total.json"
TRAFFIC_MARKER="$DATA/.traffic-enabled-by-singbox-manager"
TRAFFIC_LOCK="$DATA/.traffic-monitor.lock"
TRAFFIC_UNIT="/etc/systemd/system/${TRAFFIC_SERVICE}.service"
TRAFFIC_INIT="/etc/init.d/${TRAFFIC_SERVICE}"
TRAFFIC_LOG="/var/log/${TRAFFIC_SERVICE}.log"
# sing-box 官方 deb/rpm 包自带示例配置里的 Shadowsocks 密码（公开的，不能留在线上）
OFFICIAL_SAMPLE_PW="Gn1JUS14bLUHgv1cWDDp4A=="
SB=""
OPENRC_INIT="/etc/init.d/sing-box"
OPENRC_CONFD="/etc/conf.d/sing-box"
SB_LOG="/var/log/sing-box.log"
INIT_SYS=""   # systemd / openrc / none
BBR_MARK_BEGIN="# @bossangs-singbox-manager-tcp-bbr BEGIN"
BBR_MARK_END="# @bossangs-singbox-manager-tcp-bbr END"
BBR_STATE_MARKER="# @bossangs-singbox-manager-tcp-bbr STATE"
BBR_STATE="$DATA/.tcp-bbr-state"
BBR_CC_FILE="/proc/sys/net/ipv4/tcp_congestion_control"
BBR_AVAILABLE_FILE="/proc/sys/net/ipv4/tcp_available_congestion_control"
WATCHDOG_MARK="# @bossangs-singbox-manager-watchdog"
WATCHDOG_CONF_BEGIN="# @bossangs-singbox-manager-watchdog BEGIN"
WATCHDOG_CONF_END="# @bossangs-singbox-manager-watchdog END"
WATCHDOG_SERVICE="singbox-manager-watchdog"
WATCHDOG_TIMER="singbox-manager-watchdog.timer"
WATCHDOG_SYSTEMD_SERVICE="/etc/systemd/system/singbox-manager-watchdog.service"
WATCHDOG_SYSTEMD_TIMER="/etc/systemd/system/singbox-manager-watchdog.timer"
WATCHDOG_SINGBOX_DROPIN="/etc/systemd/system/sing-box.service.d/90-singbox-manager-watchdog.conf"
WATCHDOG_XRAY_DROPIN="/etc/systemd/system/singbox-xray.service.d/90-singbox-manager-watchdog.conf"
WATCHDOG_OPENRC_INIT="/etc/init.d/singbox-manager-watchdog"
WATCHDOG_LOG="/var/log/singbox-manager-watchdog.log"
# Argo（Cloudflare Tunnel / cloudflared）节点
ARGO_BIN="/usr/local/bin/cloudflared"
ARGO_DIR="$DATA/argo"
ARGO_MARK="# @bossangs-singbox-manager-argo"
ARGO_SERVICE=""
ARGO_UNIT=""
ARGO_INIT=""
ARGO_LOG_FILE=""
ARGO_TOKEN_FILE=""
# Telegram 机器人
TG_SERVICE="sing-box-tgbot"
TG_MARK="# @bossangs-singbox-manager-tgbot"
TG_UNIT="/etc/systemd/system/${TG_SERVICE}.service"
TG_INIT="/etc/init.d/${TG_SERVICE}"
TG_LOG="/var/log/${TG_SERVICE}.log"
TG_API="https://api.telegram.org"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_AUTO_PUSH=0
TG_SUPPRESS_AUTOPUSH=""
# Reality SNI 扫描（结果缓存）
SNI_CACHE="$DATA/sni-scan.json"
SNI_BEST=""
SNI_REGION=""

die() { echo "错误：$*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo -i"; }
have() { command -v "$1" >/dev/null 2>&1; }
is_supported_install_os() {
  case "${ID:-}" in
    debian|ubuntu|almalinux|alpine) return 0 ;;
  esac
  # AlmaLinux/Rocky/CentOS 等可能只通过 ID_LIKE 声明 RHEL 兼容性
  case " ${ID_LIKE:-} " in
    *" debian "*|*" rhel "*|*" centos "*) return 0 ;;
  esac
  return 1
}
detect_init() {
  if have systemctl && [[ -d /run/systemd/system ]]; then INIT_SYS=systemd
  elif have rc-service && { have openrc-run || [[ -x /sbin/openrc-run ]]; }; then INIT_SYS=openrc
  elif have systemctl; then INIT_SYS=systemd
  else INIT_SYS=none; fi
}
is_openrc() { [[ "$INIT_SYS" == openrc ]]; }
need_init() { [[ "$INIT_SYS" != none ]] || die "没有找到 systemd 或 OpenRC，无法管理 sing-box 服务（Alpine 请先运行：apk add openrc）"; }
trim_log() {
  # OpenRC 下日志写到文件；超过 20MB 时只保留最后 5000 行
  [[ -f "$SB_LOG" ]] || return 0
  if (( $(wc -c <"$SB_LOG") > 20971520 )); then
    tail -n 5000 "$SB_LOG" >"$SB_LOG.tmp" && cat "$SB_LOG.tmp" >"$SB_LOG"
    rm -f "$SB_LOG.tmp"
  fi
}
svc_restart() {
  need_init
  if is_openrc; then trim_log; rc-service "$SERVICE" restart
  else
    # 连续多次修改时避免触发 systemd 的启动频率限制（start-limit-hit）
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE"
  fi
}
svc_enable() {
  if is_openrc; then rc-update add "$SERVICE" default >/dev/null 2>&1 || true
  else systemctl enable "$SERVICE" >/dev/null 2>&1 || true; fi
}
svc_status() {
  if is_openrc; then rc-service "$SERVICE" status || true
  elif [[ "$INIT_SYS" == systemd ]]; then systemctl --no-pager --full status "$SERVICE" || true
  else echo "没有找到 systemd 或 OpenRC"; fi
}
svc_logs() {
  local n="${1:-100}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=100
  if is_openrc; then
    if [[ -s "$SB_LOG" ]]; then tail -n "$n" "$SB_LOG"; else echo "暂无日志（$SB_LOG）"; fi
  else
    journalctl -u "$SERVICE" -n "$n" --no-pager
  fi
}
svc_log_hint() { if is_openrc; then echo "tail -n 50 $SB_LOG"; else echo "journalctl -u sing-box -n 50 --no-pager"; fi; }
svc_daemon_reload() { if [[ "$INIT_SYS" == systemd ]]; then systemctl daemon-reload; fi; }
pause() { read -r -p "按回车继续..." _ || true; }
random_hex() { openssl rand -hex "${1:-8}"; }
new_uuid() { "$SB" generate uuid; }
prompt() { local __var="$1" __label="$2" __default="${3:-}"; local __v; if [[ -n "$__default" ]]; then read -r -p "$__label [$__default]: " __v; __v="${__v:-$__default}"; else read -r -p "$__label: " __v; fi; printf -v "$__var" '%s' "$__v"; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_tag() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || die "节点名称仅允许字母、数字、下划线和短横线，最长 40 字符"; }

# ---------- 非交互参数 ----------
# 菜单和原有子命令的用法完全不变；这里只是让同一套添加流程也能用 --选项 直接跑完。
declare -A OPTS=()
PARGS=()
NONINT=0
BOOL_OPTS=" yes non-interactive self-signed auto quick json help auto-push tg-push "
optv() {
  # 依次取第一个非空的选项值，没有时输出空（始终返回 0，避免 set -e 误退出）
  local x
  for x in "$@"; do
    if [[ -n "${OPTS[$x]:-}" ]]; then printf '%s' "${OPTS[$x]}"; return 0; fi
  done
  return 0
}
opt_bool() {
  local x
  for x in "$@"; do [[ -n "${OPTS[$x]:-}" ]] && return 0; done
  return 1
}
parse_opts() {
  # --名称 值 / --名称=值 / -y 解析到 OPTS，其余参数按原顺序放进 PARGS
  local a k
  OPTS=(); PARGS=(); NONINT=0
  while (( $# )); do
    a="$1"
    case "$a" in
      -y|--yes) NONINT=1; OPTS[yes]=1; shift ;;
      --non-interactive) NONINT=1; OPTS[non-interactive]=1; shift ;;
      -h|--help) OPTS[help]=1; shift ;;
      --*=*) k="${a%%=*}"; k="${k#--}"; OPTS["${k,,}"]="${a#*=}"; shift ;;
      --*)
        k="${a#--}"; k="${k,,}"
        if [[ " $BOOL_OPTS " == *" $k "* ]]; then
          OPTS["$k"]=1; shift
        else
          (( $# >= 2 )) || die "选项 --$k 后面缺少取值（例如：--$k 值）"
          OPTS["$k"]="$2"; shift 2
        fi ;;
      -*) die "不认识的选项：$a（运行 $(self_cmd) help 查看用法）" ;;
      *) PARGS+=("$a"); shift ;;
    esac
  done
  [[ -n "${OPTS[yes]:-}${OPTS[non-interactive]:-}" ]] && NONINT=1
  return 0
}
ask_value() {
  # $1 变量名；$2 提示文字；$3 默认值；其余参数为可接受的选项名（如 port listen-port）
  local __name="$1" __label="$2" __def="$3" __v
  shift 3
  __v="$(optv "$@")"
  if [[ -z "$__v" ]]; then
    if (( NONINT )); then __v="$__def"; else prompt __v "$__label" "$__def"; fi
  fi
  printf -v "$__name" '%s' "$__v"
}
ask_port() {
  # $1 变量名；$2 提示文字；$3 默认端口；$4 tcp / udp / both
  local __name="$1" __label="$2" __def="$3" __proto="$4" __p
  __p="$(optv port listen-port)"
  if [[ -z "$__p" ]]; then
    if (( NONINT )); then __p="$__def"; else prompt __p "$__label" "$__def"; fi
  fi
  valid_port "$__p" || die "端口必须是 1-65535 的数字"
  __p="$((10#$__p))"
  check_port "$__p" "$__proto"
  printf -v "$__name" '%s' "$__p"
}

self_cmd() {
  # 给用户看的“再次运行本脚本”的命令
  local r
  r="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [[ "$r" == "$SHORTCUT" ]] || shortcut_is_ours; then echo "sb"; return; fi
  case "$0" in
    /dev/fd/*|/proc/*|bash|-bash|sh) echo "./singbox-manager.sh" ;;
    */*) echo "$0" ;;
    *) echo "./$0" ;;
  esac
}

# ---------- sing-box 程序定位 ----------
is_elf() {
  [[ -f "$1" && -x "$1" ]] || return 1
  [[ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]]
}
resolve_sb() {
  # 只接受真正的 sing-box 程序，避免误调用其他一键脚本的同名管理命令
  local c real
  SB=""
  for c in /usr/bin/sing-box /usr/local/bin/sing-box "$(command -v sing-box 2>/dev/null || true)"; do
    [[ -n "$c" && -e "$c" ]] || continue
    real="$(readlink -f "$c" 2>/dev/null || echo "$c")"
    if is_elf "$real"; then SB="$real"; return 0; fi
  done
  return 1
}
need_sb() { resolve_sb || die "未找到 sing-box 程序。先运行：$(self_cmd) install"; }

# ---------- sb 快捷命令 ----------
is_our_script() { [[ -f "$1" ]] && grep -qxF "$MARK" "$1" 2>/dev/null; }
shortcut_is_ours() { [[ -f "$SHORTCUT" && ! -L "$SHORTCUT" ]] && is_our_script "$SHORTCUT"; }
shortcut_is_foreign() { [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]] && ! shortcut_is_ours; }
ss_shortcut_is_ours() {
  [[ -L "$SS_SHORTCUT" ]] && shortcut_is_ours &&
    [[ "$(readlink -f "$SS_SHORTCUT" 2>/dev/null || true)" == "$(readlink -f "$SHORTCUT" 2>/dev/null || true)" ]]
}
install_ss_shortcut() {
  ss_shortcut_is_ours && return 0
  if [[ -e "$SS_SHORTCUT" || -L "$SS_SHORTCUT" ]]; then
    echo "提示：$SS_SHORTCUT 已被其他文件或命令占用，未覆盖；仍可使用菜单第 5 项或 sb add-ss。" >&2
    return 0
  fi
  ln -s "$SHORTCUT" "$SS_SHORTCUT" 2>/dev/null || {
    echo "提示：未能创建 $SS_SHORTCUT；仍可使用菜单第 5 项或 sb add-ss。" >&2
    return 0
  }
  echo "已创建 Shadowsocks 快捷命令：sb5（$SS_SHORTCUT）。"
}
fetch_latest() {
  # 下载最新脚本到 $1，并做语法和身份检查
  local dest="$1" url="${RAW_URL}&cache=$(date +%s)-${RANDOM}"
  curl -fsSL -H 'Accept: application/vnd.github.raw' --max-time 30 "$url" -o "$dest" || { rm -f "$dest"; die "下载失败：$url"; }
  bash -n "$dest" || { rm -f "$dest"; die "下载的脚本语法检查失败，未更新"; }
  is_our_script "$dest" || { rm -f "$dest"; die "下载的文件不是本脚本，未更新"; }
}
install_shortcut() {
  # 把本脚本安装为 /usr/local/bin/sb；不会覆盖其他程序的 sb
  local src tmp
  if shortcut_is_foreign; then
    echo "提示：$SHORTCUT 已被其他程序占用（$(readlink -f "$SHORTCUT" 2>/dev/null || echo "$SHORTCUT")），未覆盖，所以没有创建 sb 快捷命令。" >&2
    echo "      可以继续用 $(self_cmd) 管理；确认那个 sb 不再需要后，删除它再运行：$(self_cmd) shortcut" >&2
    return 0
  fi
  src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [[ "$src" == "$SHORTCUT" ]]; then
    :
  elif [[ -f "$src" && "$src" != /dev/fd/* && "$src" != /proc/* ]] && is_our_script "$src"; then
    install -m 755 "$src" "$SHORTCUT"
  else
    tmp="$(mktemp)"
    fetch_latest "$tmp"
    install -m 755 "$tmp" "$SHORTCUT"
    rm -f "$tmp"
  fi
  install_ss_shortcut
  echo "已创建快捷命令：sb（$SHORTCUT）。以后输入 sb 打开管理菜单，或输入 sb5 直接添加 Shadowsocks。"
  if grep -qE '^[[:space:]]*alias[[:space:]]+sb=' /root/.bashrc 2>/dev/null; then
    echo "注意：/root/.bashrc 里有 alias sb=...，会覆盖 sb 快捷命令。请删除那一行后重新登录。" >&2
  fi
}
cmd_update() {
  local tmp new_ver oldest
  shortcut_is_foreign && die "$SHORTCUT 已被其他程序占用，未更新。"
  tmp="$(mktemp)"
  fetch_latest "$tmp"
  new_ver="$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$tmp" | head -n1)"
  if [[ -z "$new_ver" ]]; then rm -f "$tmp"; die "远端脚本版本号缺失，未更新。"; fi
  oldest="$(printf '%s\n%s\n' "$new_ver" "$SCRIPT_VERSION" | sort -V | head -n1)"
  if [[ "$oldest" == "$new_ver" && "$new_ver" != "$SCRIPT_VERSION" ]]; then
    rm -f "$tmp"
    echo "未更新：本地构建 $SCRIPT_VERSION 比远端 $new_ver 新，包含尚未发布的本地功能；为避免回退，未覆盖 sb。"
    echo "要保留此功能，请从本地安装包更新；后续发布版本后再使用 sb update。"
    return 0
  fi
  install -m 755 "$tmp" "$SHORTCUT"
  rm -f "$tmp"
  install_ss_shortcut
  echo "已更新 sb：${SCRIPT_VERSION} -> ${new_ver:-未知}。运行 sb 打开管理菜单；运行 sb5 直接添加 Shadowsocks。"
}
cmd_remove_shortcut() {
  if watchdog_file_owned "$WATCHDOG_SYSTEMD_TIMER" || watchdog_file_owned "$WATCHDOG_OPENRC_INIT"; then
    echo "看门狗正在使用 sb 快捷命令；请先运行 sb watchdog disable，再删除快捷命令。" >&2
    return 1
  fi
  if shortcut_is_ours; then
    if ss_shortcut_is_ours; then
      rm -f "$SS_SHORTCUT"
      echo "已删除 Shadowsocks 快捷命令 sb5。"
    elif [[ -e "$SS_SHORTCUT" || -L "$SS_SHORTCUT" ]]; then
      echo "提示：$SS_SHORTCUT 不是本脚本创建的，保留不动。" >&2
    fi
    rm -f "$SHORTCUT"
    echo "已删除 sb 快捷命令（sing-box 和节点不受影响）。"
  elif [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]]; then
    die "$SHORTCUT 不是本脚本创建的，未删除。"
  else
    echo "sb 快捷命令不存在。"
  fi
}

# ---------- 服务器公网地址 ----------
valid_ipv4() {
  local o
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
valid_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:.]+$ && ${#1} -le 45 ]]; }
valid_domain() { [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_host() { valid_ipv4 "$1" || valid_ipv6 "$1" || valid_domain "$1"; }
is_private_v4() {
  case "$1" in
    10.*|127.*|0.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
  esac
  return 1
}
detect_public_ip() {
  local u ip a
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ipinfo.io/ip https://api-ipv4.ip.sb/ip; do
    ip="$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if valid_ipv4 "$ip" && ! is_private_v4 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  for u in https://api6.ipify.org https://ipv6.icanhazip.com https://api-ipv6.ip.sb/ip; do
    ip="$(curl -6 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if valid_ipv6 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  # 外部服务都不可用时，尝试本机网卡上的公网 IPv4
  for a in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
    if valid_ipv4 "$a" && ! is_private_v4 "$a"; then printf '%s' "$a"; return 0; fi
  done
  return 1
}
choose_host() {
  # 自动识别公网 IP 作为默认值；回车确认，或输入域名/其他 IP。结果输出到 stdout，提示输出到 stderr。
  local detected="" h
  echo "正在自动识别本机公网 IP……" >&2
  detected="$(detect_public_ip || true)"
  if [[ -n "$detected" ]]; then
    echo "识别到公网地址：$detected" >&2
  else
    echo "没能自动识别公网 IP，请手动输入。" >&2
  fi
  while true; do
    h=""
    if [[ -n "$detected" ]]; then
      read -r -p "服务器地址（回车使用 $detected，也可以输入域名）: " h || h=""
      h="${h:-$detected}"
    else
      read -r -p "服务器公网 IP 或域名: " h || die "没有输入服务器地址"
    fi
    h="${h//[[:space:]]/}"; h="${h#[}"; h="${h%]}"
    if valid_host "$h"; then printf '%s' "$h"; return 0; fi
    echo "格式不对：请输入 IPv4、IPv6 或域名（例如 1.2.3.4 或 vps.example.com）。" >&2
  done
}
save_host() {
  mkdir -p "$DATA"
  printf '%s' "$1" >"$DATA/server-host"
  chmod 600 "$DATA/server-host"
}
public_host() {
  # 读取已保存的服务器地址；为空或无效（包括旧版本保存的 YOUR_SERVER_IP）时重新识别
  local h
  h="$(tr -d '[:space:]' <"$DATA/server-host" 2>/dev/null || true)"
  if ! valid_host "$h"; then
    [[ -n "$h" ]] && echo "已保存的服务器地址 [$h] 无效，重新识别。" >&2
    h="$(choose_host)"
    save_host "$h"
    echo "服务器地址已保存：$h（以后可用 $(self_cmd) host 修改）" >&2
  fi
  printf '%s' "$h"
}
uri_host() { if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi; }
cmd_set_host() {
  local old new
  old="$(tr -d '[:space:]' <"$DATA/server-host" 2>/dev/null || true)"
  [[ -n "$old" ]] && echo "当前保存的服务器地址：$old"
  new="$(choose_host)"
  save_host "$new"
  echo "服务器地址已保存：$new"
  echo "下面是用新地址重新生成的节点信息和分享链接："
  show_links
}

# ---------- 其他 sing-box 脚本检测 ----------
CONFLICTS=()          # 其他脚本仍在使用的痕迹：停下，给出指引
FOREIGN_RM=()         # 指引里需要删除的具体路径（保留本脚本格式配置时使用）
LEFTOVERS=()          # 旧脚本删掉后留下的残留说明
LEFTOVER_FILES=()     # 可自动备份并删除的残留文件/失效链接
LEFTOVER_DIRS=()      # 可自动删除的空目录
LEFTOVER_ALIAS=0      # /root/.bashrc 里旧脚本的 alias
LEFTOVER_UNIT=0       # 删除了 systemd 服务文件，需要 daemon-reload
LEFTOVER_SVC=0        # 删除了失效的服务文件，需要重新写入本脚本的服务文件
CLEANED_ALIAS=0
OTHER_NAME="另一个 sing-box 一键脚本"
OTHER_CADDY=0
OLD_ALIAS_RE='^alias (sb|sing-box)=/usr/local/bin/sing-box$'
openrc_is_official() {
  # 官方 apk 包的服务文件：属于 sing-box 包，且启动程序就是包里的 /usr/bin/sing-box
  # （apk 改过内容的包文件依然算“属于包”，所以必须再核对内容）
  local c
  [[ -f "$1" ]] && pkg_owns "$1" || return 1
  c="$(openrc_cmd "$1")"
  [[ "$c" == /usr/bin/sing-box ]] && is_elf /usr/bin/sing-box
}
openrc_cmd() { sed -n 's/^[[:space:]]*command=["'"'"']\{0,1\}\([^"'"'"' ]*\).*/\1/p' "$1" 2>/dev/null | head -n1; }
is_dangling() { [[ -L "$1" && ! -e "$1" ]]; }
dir_has_files() { [[ -d "$1" ]] && [[ -n "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]]; }
conf_is_ours() { [[ -f "$CONF" ]] && jq -e '.inbounds | type == "array"' "$CONF" >/dev/null 2>&1; }
pkg_owns() {
  # Debian 13 是 usr 合并布局；RPM 查询也尝试真实路径，兼容 /lib -> /usr/lib
  local c
  if have apk && ! have dpkg; then
    apk info -q --who-owns "$1" >/dev/null 2>&1
    return
  fi
  if have dpkg; then
    for c in "$1" "$(readlink -f "$1" 2>/dev/null || true)" "/usr${1#/usr}" "${1#/usr}"; do
      [[ -n "$c" ]] && dpkg -S "$c" >/dev/null 2>&1 && return 0
    done
  fi
  if have rpm; then
    for c in "$1" "$(readlink -f "$1" 2>/dev/null || true)" "/usr${1#/usr}" "${1#/usr}"; do
      [[ -n "$c" ]] && rpm -qf "$c" >/dev/null 2>&1 && return 0
    done
  fi
  return 1
}

detect_conflicts() {
  CONFLICTS=(); FOREIGN_RM=(); LEFTOVERS=(); LEFTOVER_FILES=(); LEFTOVER_DIRS=(); LEFTOVER_ALIAS=0
  OTHER_NAME="另一个 sing-box 一键脚本"
  OTHER_CADDY=0
  local f d real p ver exec_line exec_bin unit

  if [[ -f "$CONF_DIR/sh/sing-box.sh" ]]; then
    ver="$(grep -m1 '^is_sh_ver=' "$CONF_DIR/sh/sing-box.sh" 2>/dev/null | cut -d= -f2 || true)"
    OTHER_NAME="233boy sing-box 脚本${ver:+ $ver}"
  fi
  for d in sh bin conf; do
    if dir_has_files "$CONF_DIR/$d"; then
      case "$d" in
        sh) CONFLICTS+=("$CONF_DIR/sh/ —— 其他脚本的管理程序目录") ;;
        bin) CONFLICTS+=("$CONF_DIR/bin/ —— 其他脚本自带的 sing-box 程序") ;;
        conf) CONFLICTS+=("$CONF_DIR/conf/ —— 其他脚本的节点配置目录") ;;
      esac
      FOREIGN_RM+=("$CONF_DIR/$d")
    elif [[ -d "$CONF_DIR/$d" ]]; then
      LEFTOVERS+=("$CONF_DIR/$d/ —— 旧脚本留下的空目录")
      LEFTOVER_DIRS+=("$CONF_DIR/$d")
    fi
  done

  # 快捷命令和 sing-box 命令
  for p in /usr/local/bin/sing-box "$SHORTCUT"; do
    if is_dangling "$p"; then
      LEFTOVERS+=("$p —— 失效的链接（指向已不存在的 $(readlink "$p" 2>/dev/null || echo '?')）")
      LEFTOVER_FILES+=("$p")
      continue
    fi
    [[ -e "$p" ]] || continue
    real="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    if [[ "$p" == "$SHORTCUT" ]]; then
      if ! shortcut_is_ours && [[ "$real" == "$CONF_DIR"/* ]]; then
        CONFLICTS+=("$p —— 是其他 sing-box 脚本的管理命令（指向 $real）")
        FOREIGN_RM+=("$p")
      fi
    elif ! is_elf "$real"; then
      CONFLICTS+=("$p —— 是其他脚本的管理命令（指向 $real），不是 sing-box 程序")
      FOREIGN_RM+=("$p")
    fi
  done
  p="$(command -v sing-box 2>/dev/null || true)"
  if [[ -n "$p" && "$p" != /usr/local/bin/sing-box && -e "$p" ]]; then
    real="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    is_elf "$real" || { CONFLICTS+=("sing-box 命令（$p）指向脚本 $real，不是 sing-box 程序"); FOREIGN_RM+=("$p"); }
  fi

  # systemd 服务
  if have systemctl && systemctl cat "${SERVICE}.service" >/dev/null 2>&1; then
    exec_line="$(systemctl cat "${SERVICE}.service" 2>/dev/null | sed -n 's/^ExecStart=//p' | sed '/^[[:space:]]*$/d' | tail -n1 || true)"
    exec_bin="${exec_line%% *}"; exec_bin="${exec_bin#[-@+!]}"
    unit="$(systemctl show -p FragmentPath --value "${SERVICE}.service" 2>/dev/null || true)"
    case "$exec_line" in
      "") ;;
      "/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run") ;;  # 官方安装包
      *)
        if [[ ! -e "$exec_bin" ]]; then
          # 启动程序已经不存在：旧脚本删掉后留下的服务文件。本脚本会改用自己的服务文件。
          if [[ -n "$unit" && -f "$unit" ]] && ! pkg_owns "$unit"; then
            LEFTOVERS+=("$unit —— 失效的服务文件（启动程序 $exec_bin 已不存在）")
            LEFTOVER_FILES+=("$unit")
          fi
        elif [[ "$exec_line" == *" run -c $CONF" ]] && is_elf "$(readlink -f "$exec_bin")"; then
          :  # 本脚本写的服务文件
        else
          CONFLICTS+=("sing-box.service 的启动命令不是官方或本脚本的写法：$exec_line")
        fi ;;
    esac
  fi

  # OpenRC 服务（Alpine）
  if [[ -f "$OPENRC_INIT" ]] && ! is_our_script "$OPENRC_INIT" && ! openrc_is_official "$OPENRC_INIT"; then
    exec_bin="$(openrc_cmd "$OPENRC_INIT")"
    if [[ -n "$exec_bin" && ! -e "$exec_bin" ]]; then
      LEFTOVERS+=("$OPENRC_INIT —— 失效的 OpenRC 服务文件（启动程序 $exec_bin 已不存在）")
      LEFTOVER_FILES+=("$OPENRC_INIT")
    else
      CONFLICTS+=("$OPENRC_INIT —— 其他脚本写的 OpenRC 服务文件（启动程序 ${exec_bin:-无法识别}）")
      FOREIGN_RM+=("$OPENRC_INIT")
    fi
  fi

  # 多余的配置文件（官方服务会把 /etc/sing-box 下所有 .json 合并加载）
  shopt -s nullglob
  for f in "$CONF_DIR"/*.json; do
    if [[ "$f" != "$CONF" ]]; then
      CONFLICTS+=("$f —— 多出来的配置文件（官方服务会把 $CONF_DIR 下所有 .json 合并加载）")
      FOREIGN_RM+=("$f")
    fi
  done
  shopt -u nullglob

  if [[ -f "$CONF" ]]; then
    if ! jq -e . "$CONF" >/dev/null 2>&1; then
      CONFLICTS+=("$CONF —— 不是合法的 JSON")
    elif ! conf_is_ours; then
      CONFLICTS+=("$CONF —— 没有 inbounds 数组（其他脚本的配置格式，节点放在别的地方）")
    fi
  fi

  # 旧脚本加进 /root/.bashrc 的别名
  if grep -qE "$OLD_ALIAS_RE" /root/.bashrc 2>/dev/null; then
    LEFTOVERS+=("/root/.bashrc —— 旧脚本加的 alias sb / alias sing-box（会让 sb 指向已不存在的旧命令）")
    LEFTOVER_ALIAS=1
  fi

  [[ -d /etc/caddy/233boy ]] && OTHER_CADDY=1
  (( ${#CONFLICTS[@]} > 0 ))
}

clean_leftovers() {
  # 只在没有其他脚本仍在使用时调用：备份后自动删除残留
  (( ${#LEFTOVER_FILES[@]} + ${#LEFTOVER_DIRS[@]} + LEFTOVER_ALIAS > 0 )) || return 0
  local item f d B items=()
  echo "发现旧 sing-box 脚本留下的残留（旧脚本本身已经不在了），先备份再自动清理："
  for item in "${LEFTOVERS[@]}"; do echo "  - $item"; done
  items=("${LEFTOVER_FILES[@]}")
  (( LEFTOVER_ALIAS )) && items+=(/root/.bashrc)
  if (( ${#items[@]} )); then
    B="/root/singbox-leftovers-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar czf "$B" --ignore-failed-read "${items[@]}" 2>/dev/null || [[ -s "$B" ]] || die "残留备份失败，未做任何清理"
    chmod 600 "$B"
  fi
  for f in "${LEFTOVER_FILES[@]}"; do
    if [[ "$f" == "$OPENRC_INIT" ]]; then rc-update del "$SERVICE" default >/dev/null 2>&1 || true; LEFTOVER_SVC=1; fi
    rm -f "$f"
    if [[ "$f" == *.service ]]; then LEFTOVER_UNIT=1; LEFTOVER_SVC=1; fi
  done
  for d in "${LEFTOVER_DIRS[@]}"; do rmdir "$d" 2>/dev/null || true; done
  if (( LEFTOVER_ALIAS )); then
    sed -i -E "\#${OLD_ALIAS_RE}#d" /root/.bashrc
    CLEANED_ALIAS=1
  fi
  (( LEFTOVER_UNIT )) && svc_daemon_reload
  echo "残留已清理${B:+，备份在 $B}。你的节点配置没有改动。"
  alias_notice
}
alias_notice() {
  (( CLEANED_ALIAS )) || return 0
  cat <<'TXT'
注意：当前这个终端里，旧的 sb 别名可能还在生效。请运行下面这一行（或者重新登录 SSH）后再用 sb：

unalias sb sing-box 2>/dev/null; hash -r

TXT
}

conflict_report() {
  local item self keep=0 n=0 q stop_cmd disable_cmd purge_cmd svc_files reload_cmd
  self="./singbox-manager.sh"
  if is_openrc; then
    stop_cmd="rc-service sing-box stop"
    disable_cmd="rc-service sing-box stop; rc-update del sing-box default"
    purge_cmd="apk info -e sing-box >/dev/null 2>&1 && apk del sing-box"
    svc_files="/etc/init.d/sing-box /etc/conf.d/sing-box"
    reload_cmd=""
  else
    stop_cmd="systemctl stop sing-box"
    disable_cmd="systemctl disable --now sing-box"
    if have dnf; then purge_cmd="rpm -q sing-box >/dev/null 2>&1 && dnf remove -y sing-box"
    elif have yum; then purge_cmd="rpm -q sing-box >/dev/null 2>&1 && yum remove -y sing-box"
    else purge_cmd="dpkg -s sing-box >/dev/null 2>&1 && apt-get purge -y sing-box"; fi
    svc_files="/etc/systemd/system/sing-box.service /etc/systemd/system/sing-box@.service /lib/systemd/system/sing-box.service"
    reload_cmd="systemctl daemon-reload"
  fi
  if conf_is_ours; then keep=1; n="$(jq '.inbounds | length' "$CONF")"; fi
  cat >&2 <<TXT

==================== 检测到其他 sing-box 脚本 ====================
这台服务器上还装着：${OTHER_NAME}
它和本脚本的配置格式、程序位置、系统服务都不一样，两个脚本不能同时管理同一个 sing-box。
本脚本没有修改任何 sing-box 文件，已停止。

还在使用中的痕迹：
TXT
  for item in "${CONFLICTS[@]}"; do echo "  - $item" >&2; done
  if (( ${#LEFTOVERS[@]} )); then
    echo "另外还有这些残留（处理完上面的问题后，本脚本会自动备份并清理）：" >&2
    for item in "${LEFTOVERS[@]}"; do echo "  - $item" >&2; done
  fi
  cat >&2 <<TXT

如果你想继续用原来的脚本，就不要运行本脚本。
要换成本脚本，请逐行复制运行下面的命令。第一段只做备份，不删除任何东西：

B=/root/old-singbox-\$(date +%Y%m%d-%H%M%S).tar.gz
tar czf "\$B" --ignore-failed-read /etc/sing-box /var/log/sing-box ${svc_files} /usr/local/bin/sing-box /usr/local/bin/sb /root/.bashrc
chmod 600 "\$B"
ls -lh "\$B"

TXT
  if (( keep )); then
    q=""
    for item in "${FOREIGN_RM[@]}"; do q+=" $(printf '%q' "$item")"; done
    cat >&2 <<TXT
$CONF 已经是本脚本的格式（${n} 个节点），清理时会保留它，只删除其他脚本的部分。
确认上面显示出了备份文件，再运行：

${stop_cmd}
TXT
    [[ -n "$q" ]] && echo "rm -rf$q" >&2
    cat >&2 <<TXT
sed -i.bak -E '\#${OLD_ALIAS_RE}#d' /root/.bashrc
unalias sb sing-box 2>/dev/null; hash -r

然后在本脚本所在目录重新安装（已有节点会保留）：

${self} install
TXT
  else
    cat >&2 <<TXT
旧脚本的节点会全部失效，请先确认不再需要。确认上面显示出了备份文件，再运行下面的清理命令：

${disable_cmd}
${purge_cmd}
rm -rf /etc/sing-box /var/log/sing-box
rm -f ${svc_files} /usr/local/bin/sing-box /usr/local/bin/sb
sed -i.bak -E '\#${OLD_ALIAS_RE}#d' /root/.bashrc${reload_cmd:+
$reload_cmd}
unalias sb sing-box 2>/dev/null; hash -r

清理完成后，在本脚本所在目录重新安装：

${self} install
TXT
  fi
  if (( OTHER_CADDY )); then
    cat >&2 <<'TXT'

另外检测到 233boy 脚本装的 Caddy（/etc/caddy/233boy）。它通常占用 80/443 端口，
会和 Reality 默认的 443 端口冲突。确定不再需要时，可以先备份再停用：

C=/root/old-caddy-$(date +%Y%m%d-%H%M%S).tar.gz
tar czf "$C" --ignore-failed-read /etc/caddy /lib/systemd/system/caddy.service /usr/local/bin/caddy
systemctl disable --now caddy
TXT
  fi
  echo "==================================================================" >&2
  exit 1
}
check_no_conflicts() {
  if detect_conflicts; then conflict_report; fi
  clean_leftovers
}

# ---------- 通用 ----------
port_free() {
  local p="$1" proto="${2:-tcp}"
  if [[ "$proto" == tcp ]]; then
    ! ss -H -lnt "( sport = :$p )" 2>/dev/null | grep -q .
  else
    ! ss -H -lnu "( sport = :$p )" 2>/dev/null | grep -q .
  fi
}
backup_config() {
  mkdir -p "$BACKUP_DIR" "$DATA" "$CERT_DIR"
  LAST_BACKUP=""
  if [[ -f "$CONF" ]]; then
    LAST_BACKUP="$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S-%N).json"
    cp -a "$CONF" "$LAST_BACKUP"
  fi
}
install_deps() {
  if have apk && ! have apt-get; then
    apk update
    # Alpine 默认只有 BusyBox，补齐脚本用到的 GNU 工具和 ss
    apk add bash ca-certificates curl jq openssl iproute2 coreutils findutils tar grep sed openrc unzip
    return
  fi
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl jq openssl iproute2 unzip
    return
  fi
  if have dnf || have yum; then
    local -a packages=(ca-certificates jq openssl iproute unzip)
    # AlmaLinux minimal 可能预装 curl-minimal；curl 已可用时避免与 curl RPM 冲突
    have curl || packages+=(curl)
    if have dnf; then dnf install -y "${packages[@]}"
    else yum install -y "${packages[@]}"; fi
    return
  fi
  die "未找到 apk、apt-get、dnf 或 yum，无法自动安装依赖"
}
latest_sb_version() {
  # 通过 releases/latest 的跳转读取版本号，不占用 GitHub API 次数
  curl -fsSI --max-time 15 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/v##p' | head -n1
}
sb_release_arch() {
  # uname -m -> sing-box 发布包里的架构名
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    i386|i486|i586|i686|x86) echo 386 ;;
    armv7*|armhf) echo armv7 ;;
    armv6*) echo armv6 ;;
    armv5*) echo armv5 ;;
    riscv64) echo riscv64 ;;
    loongarch64|loong64) echo loong64 ;;
    s390x) echo s390x ;;
    ppc64le) echo ppc64le ;;
    *) return 1 ;;
  esac
}
sb_works() {
  # 确认这个文件真的能在本机运行（例如 musl / glibc 是否匹配）
  [[ -f "$1" ]] && chmod 755 "$1" && "$1" version >/dev/null 2>&1
}
install_sb_tarball() {
  # 下载官方发布的压缩包，取出 sing-box 程序装到 /usr/bin/sing-box
  # $1 版本号；$2 起依次尝试的包名后缀（如 -musl、空）
  local v="$1" arch suffix name url tmp bin
  shift
  arch="$(sb_release_arch)" || { echo "  不认识的 CPU 架构：$(uname -m)，跳过官方压缩包。"; return 1; }
  [[ -n "$v" ]] || { echo "  没有读到 sing-box 最新版本号，跳过官方压缩包。"; return 1; }
  tmp="$(mktemp -d)"
  for suffix in "$@"; do
    name="sing-box-${v}-linux-${arch}${suffix}"
    url="https://github.com/SagerNet/sing-box/releases/download/v${v}/${name}.tar.gz"
    echo "  下载 $url"
    rm -rf "${tmp:?}"/*
    if ! curl -fL --retry 2 --connect-timeout 15 --max-time 300 -o "$tmp/sb.tar.gz" "$url"; then
      echo "  下载失败：${name}.tar.gz"
      continue
    fi
    if ! tar -xzf "$tmp/sb.tar.gz" -C "$tmp"; then
      echo "  解压失败：${name}.tar.gz"
      continue
    fi
    bin="$(find "$tmp" -type f -name sing-box | head -n1)"
    if [[ -z "$bin" ]] || ! sb_works "$bin"; then
      echo "  ${name} 里的程序无法在本机运行，换下一个。"
      continue
    fi
    install -m 755 "$bin" /usr/bin/sing-box
    rm -rf "$tmp"
    echo "  已安装 /usr/bin/sing-box（来自官方发布包 ${name}.tar.gz）"
    return 0
  done
  rm -rf "$tmp"
  return 1
}
install_sb_official_script() {
  # 官方安装脚本出错时也可能返回 0，所以只看装完后程序能不能用
  local v="$1"
  curl -fsSL --max-time 60 https://sing-box.app/install.sh -o /tmp/sing-box-install.sh || { echo "  下载官方安装脚本失败。"; return 1; }
  if [[ -n "$v" ]]; then
    bash /tmp/sing-box-install.sh --version "$v" || true
  else
    bash /tmp/sing-box-install.sh || true
  fi
  rm -f /tmp/sing-box-install.sh
  resolve_sb
}
install_singbox() {
  local v
  if resolve_sb; then
    echo "已检测到 sing-box 程序：$SB"
  else
    v="$(latest_sb_version || true)"
    [[ "$v" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || v=""
    echo "正在安装 sing-box 内核${v:+ $v}……"
    if have apk && ! have apt-get; then
      # Alpine：官方 apk 包在较老的 Alpine（如 3.21）上可能装不上，优先用官方静态压缩包
      echo "[1/3] 官方发布的压缩包（musl 版优先）"
      if install_sb_tarball "$v" -musl "" && resolve_sb; then :
      else
        echo "[2/3] 官方压缩包没有装成，改用官方安装脚本（apk 包）"
        if install_sb_official_script "$v"; then :
        else
          echo "[3/3] 官方 apk 包也没有装成，改用 Alpine 软件源里的 sing-box（版本可能较旧）"
          { apk add sing-box sing-box-openrc || apk add sing-box; } || echo "  Alpine 软件源安装也失败了（Alpine 3.21 及更早版本的软件源里没有 sing-box）。"
        fi
      fi
    else
      echo "[1/2] 官方安装脚本"
      if install_sb_official_script "$v"; then :
      else
        echo "[2/2] 官方安装脚本没有装成，改用官方发布的压缩包"
        install_sb_tarball "$v" "" || true
      fi
    fi
    resolve_sb || die "sing-box 安装失败：上面几种方式都没有成功。请检查服务器能否访问 github.com，或手动把官方发布包里的 sing-box 放到 /usr/bin/sing-box 后重新运行 install"
  fi
  "$SB" version
}
write_clean_config() {
  cat >"$CONF" <<'JSON'
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {"final": "direct"}
}
JSON
  chmod 600 "$CONF"
}
SAMPLE_REMOVED=0
remove_official_sample() {
  # 官方安装包会放一个示例配置：8080 端口的 Shadowsocks，密码是公开的。备份后移除。
  SAMPLE_REMOVED=0
  jq -e --arg pw "$OFFICIAL_SAMPLE_PW" '[.inbounds[]? | select(.password? == $pw)] | length > 0' "$CONF" >/dev/null 2>&1 || return 0
  backup_config
  local others
  others="$(jq --arg pw "$OFFICIAL_SAMPLE_PW" '[.inbounds[] | select(.password? != $pw)] | length' "$CONF")"
  if [[ "$others" == 0 ]]; then
    write_clean_config
  else
    jq --arg pw "$OFFICIAL_SAMPLE_PW" '.inbounds |= map(select(.password? != $pw))' "$CONF" >"${CONF}.tmp"
    install -m 600 "${CONF}.tmp" "$CONF"
    rm -f "${CONF}.tmp"
  fi
  SAMPLE_REMOVED=1
  echo "已移除 sing-box 官方安装包自带的示例 Shadowsocks 节点（8080 端口，密码是公开的）。原配置已备份到 $BACKUP_DIR/"
}
init_config() {
  mkdir -p "$CONF_DIR" "$DATA" "$CERT_DIR" "$BACKUP_DIR"
  [[ -f "$CONF" ]] || write_clean_config
  check_no_conflicts
  remove_official_sample
}
check_config() {
  "$SB" check -c "$CONF"
}
write_unit() {
  cat >/etc/systemd/system/sing-box.service <<UNIT
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${SB} run -c ${CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/sing-box.service
  systemctl daemon-reload
}
write_openrc_init() {
  cat >"$OPENRC_INIT" <<RC
#!/sbin/openrc-run
${MARK}
name="sing-box"
description="sing-box service (singbox-manager)"
supervisor="supervise-daemon"
command="${SB}"
command_args="run -c ${CONF}"
output_log="${SB_LOG}"
error_log="${SB_LOG}"
respawn_delay=3
respawn_max=0
rc_ulimit="-n 1048576"
extra_commands="checkconfig"

depend() {
  after net dns firewall
}

checkconfig() {
  ebegin "Checking \$RC_SVCNAME configuration"
  "\$command" check -c "${CONF}"
  eend \$?
}

start_pre() {
  checkconfig
}
RC
  chmod 755 "$OPENRC_INIT"
}
ensure_openrc_service() {
  # 官方 apk 包自带的服务文件可用时沿用它（只补上日志文件位置），否则写入本脚本的服务文件
  if ! is_our_script "$OPENRC_INIT" && openrc_is_official "$OPENRC_INIT"; then
    if ! grep -q '^output_log=' "$OPENRC_CONFD" 2>/dev/null; then
      printf '\n%s\noutput_log="%s"\nerror_log="%s"\n' "# singbox-manager：把 sing-box 日志写到文件" "$SB_LOG" "$SB_LOG" >>"$OPENRC_CONFD"
    fi
    return 0
  fi
  write_openrc_init
}
reload_service() {
  need_init
  if is_openrc; then
    ensure_openrc_service
    touch "$SB_LOG"; chmod 600 "$SB_LOG"
    svc_enable
    svc_restart
    return
  fi
  # 没有服务文件，或服务文件里的启动程序不是可用的 sing-box 时，写入本脚本的服务文件
  local exec_bin
  exec_bin="$(systemctl cat "${SERVICE}.service" 2>/dev/null | sed -n 's/^ExecStart=//p' | sed '/^[[:space:]]*$/d' | tail -n1 | awk '{print $1}' || true)"
  exec_bin="${exec_bin#[-@+!]}"
  if [[ -z "$exec_bin" ]] || ! is_elf "$(readlink -f "$exec_bin" 2>/dev/null || echo "$exec_bin")"; then
    write_unit
  fi
  svc_enable
  svc_restart
}
LAST_BACKUP=""
svc_is_running() {
  if is_openrc; then rc-service "$SERVICE" status >/dev/null 2>&1
  else [[ "$(systemctl is-active "$SERVICE" 2>/dev/null)" == active ]]; fi
}
port_listening() {
  # 端口是否由 sing-box 进程在监听（别的程序占着这个端口不算）；$1：端口；$2：tcp / udp / both
  local n
  case "${2:-tcp}" in
    both) port_listening "$1" tcp && port_listening "$1" udp; return ;;
    udp) n=u ;;
    *) n=t ;;
  esac
  ss -H -ln${n}p "( sport = :$1 )" 2>/dev/null | grep -q '"sing-box"'
}
svc_healthy() {
  # 重启后确认 sing-box 真的在运行（端口被占等原因会让它启动后马上退出）
  # $1/$2：应该在监听的端口和 tcp / udp / both（可省略）
  local i
  sleep 1
  for i in 1 2 3 4 5 6 7 8; do
    if svc_is_running && { [[ -z "${1:-}" ]] || port_listening "$1" "${2:-tcp}"; }; then
      sleep 0.5
      svc_is_running && return 0
    fi
    sleep 0.5
  done
  return 1
}
commit_jq() {
  # 用 jq 修改配置：先备份，再校验；校验或重启失败时恢复修改前的配置
  # EXPECT_PORT / EXPECT_NET：改完后应该在监听的端口，用来确认服务真的起来了
  local tmp="${CONF}.tmp"
  backup_config
  if ! jq "$@" "$CONF" >"$tmp"; then rm -f "$tmp"; die "生成新配置失败，未做任何改动"; fi
  install -m 600 "$tmp" "$CONF"
  rm -f "$tmp"
  if ! check_config; then
    [[ -n "$LAST_BACKUP" ]] && cp -a "$LAST_BACKUP" "$CONF"
    die "sing-box 配置校验失败，已恢复修改前的配置（没有任何改动）"
  fi
  if ! reload_service || ! svc_healthy "${EXPECT_PORT:-}" "${EXPECT_NET:-}"; then
    [[ -n "$LAST_BACKUP" ]] && cp -a "$LAST_BACKUP" "$CONF"
    svc_restart || true
    EXPECT_PORT=""; EXPECT_NET=""
    if svc_healthy; then
      die "sing-box 用新配置没能正常运行（常见原因：端口被其他程序占用），已恢复修改前的配置，服务已用原配置重新运行。查看日志：$(svc_log_hint)"
    fi
    die "sing-box 用新配置没能正常运行，已恢复修改前的配置，但服务仍未运行，请查看日志：$(svc_log_hint)"
  fi
  EXPECT_PORT=""; EXPECT_NET=""
}
RELAY_OUT=""     # 中转：落地出站 JSON（不含 tag）
RELAY_DESC=""    # 中转：落地说明
RULE_TO=""       # 端口转发：入站固定走的出站 tag
TAG_PREFIX=""    # 中转入口节点名前缀
LAST_TAG=""
apply_json() {
  # 添加入站；中转时同时添加落地出站和“只匹配这个入站”的路由规则（放在最前面）
  local obj="$1" out="${RELAY_OUT:-null}"
  [[ -n "$out" ]] || out=null
  EXPECT_PORT="$(jq -r '.listen_port' <<<"$obj")"
  EXPECT_NET="$(jq -r 'if .type == "hysteria2" or .type == "tuic" then "udp"
    elif .type == "shadowsocks" or .type == "direct" then (.network // "both")
    elif .type == "socks" then "tcp" else "tcp" end' <<<"$obj")"
  commit_jq --argjson obj "$obj" --argjson out "$out" --arg to "$RULE_TO" '
    .inbounds += [$obj]
    | .route = (.route // {})
    | if $out != null then
        ($out + {tag: ("to-" + $obj.tag)}) as $o
        | .outbounds = ((.outbounds // []) + [$o])
        | .route.rules = ([{inbound: [$obj.tag], outbound: $o.tag}] + (.route.rules // []))
      elif $to != "" then
        (if ([.outbounds[]? | select(.tag == $to)] | length) == 0 then .outbounds = ((.outbounds // []) + [{type: "direct", tag: $to}]) else . end)
        | .route.rules = ([{inbound: [$obj.tag], outbound: $to}] + (.route.rules // []))
      else . end'
}
# ---------- TLS 证书（自签 / 已有证书） ----------
TLS_HOST="" TLS_CERT="" TLS_KEY="" TLS_INS="1"
cert_self_signed() {
  # $1：节点名（用于证书文件名）；$2：证书域名或 IP。结果写 TLS_CERT / TLS_KEY
  local tag="$1" host="$2" san cert key
  mkdir -p "$CERT_DIR"
  cert="$CERT_DIR/$tag.crt"; key="$CERT_DIR/$tag.key"
  if [[ -e "$cert" || -e "$key" ]]; then
    die "证书文件已存在（$tag），为保护现有文件未覆盖；请换一个节点名，或改用 --cert/--key 指定已有证书"
  fi
  if valid_ipv4 "$host" || valid_ipv6 "$host"; then san="IP:${host}"; else san="DNS:${host}"; fi
  if ! openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
    -keyout "$key" -out "$cert" -subj "/CN=${host}" -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    rm -f "$cert" "$key"
    die "生成自签证书失败（域名：$host）"
  fi
  chmod 600 "$key"
  chmod 644 "$cert"
  TLS_CERT="$cert"; TLS_KEY="$key"
}
setup_tls() {
  # $1：节点名。确定证书域名与证书文件，结果写 TLS_HOST / TLS_CERT / TLS_KEY / TLS_INS
  # --domain/--sni 指定证书域名；--cert/--key 使用已有证书；--self-signed 强制自签
  local tag="$1" def host cert key choice
  def="$(public_host)"
  host="$(optv domain tls-host cert-host)"
  if [[ -z "$host" ]]; then
    if (( NONINT )); then host="$def"; else prompt host "证书中的域名或服务器 IP（自签证书时客户端将使用 insecure）" "$def"; fi
  fi
  host="${host#[}"; host="${host%]}"
  valid_host "$host" || die "证书域名/IP 无效：$host"
  TLS_HOST="$host"
  cert="$(optv cert)"; key="$(optv key)"
  if [[ -n "$cert" || -n "$key" ]]; then
    [[ -n "$cert" && -n "$key" ]] || die "使用已有证书时必须同时提供 --cert 和 --key"
    [[ -r "$cert" && -s "$cert" ]] || die "证书文件不可读：$cert"
    [[ -r "$key" && -s "$key" ]] || die "私钥文件不可读：$key"
    grep -q 'BEGIN CERTIFICATE' "$cert" 2>/dev/null || die "证书文件里没有 PEM 证书：$cert"
    TLS_INS=0
  elif opt_bool self-signed || (( NONINT )); then
    cert_self_signed "$tag" "$host"
    TLS_INS=1
  else
    echo "证书方式："
    echo "1) 自签证书（默认；客户端需要允许不安全证书 insecure）"
    echo "2) 已有证书文件（例如 acme.sh / Let's Encrypt 签发，客户端正常校验证书）"
    read -r -p "选择 [1-2，默认 1]: " choice || choice=1
    if [[ "${choice:-1}" == 2 ]]; then
      prompt cert "证书文件（fullchain.pem 或 cert.pem）" ""
      prompt key "私钥文件（privkey.pem）" ""
      [[ -r "$cert" && -s "$cert" ]] || die "证书文件不可读：$cert"
      [[ -r "$key" && -s "$key" ]] || die "私钥文件不可读：$key"
      TLS_INS=0
    else
      cert_self_signed "$tag" "$host"
      TLS_INS=1
    fi
  fi
  if [[ -z "$TLS_CERT" ]]; then
    [[ -n "$cert" && -n "$key" ]] || die "证书文件路径为空"
    TLS_CERT="$cert"; TLS_KEY="$key"
  fi
  if (( TLS_INS )); then
    echo "证书：自签（$TLS_CERT，CN/SAN=$host，有效期 825 天），分享链接会带 insecure=1。"
  else
    echo "证书：$TLS_CERT（有效期请自行确认；分享链接不带 insecure）。"
  fi
}
xray_arch() {
  # Xray 官方发行包的架构名称。
  case "$(uname -m)" in
    x86_64|amd64) echo 64 ;;
    i386|i486|i586|i686|x86) echo 32 ;;
    armv5*) echo arm32-v5 ;;
    armv6*) echo arm32-v6 ;;
    armv7*|armhf) if grep -qw vfp /proc/cpuinfo 2>/dev/null; then echo arm32-v7a; else echo arm32-v5; fi ;;
    aarch64|arm64) echo arm64-v8a ;;
    loongarch64|loong64) echo loong64 ;;
    mips) echo mips32 ;;
    mipsel) echo mips32le ;;
    mips64) if have lscpu && lscpu 2>/dev/null | grep -q 'Little Endian'; then echo mips64le; else echo mips64; fi ;;
    mips64el) echo mips64le ;;
    ppc64) echo ppc64 ;;
    ppc64le) echo ppc64le ;;
    riscv64) echo riscv64 ;;
    s390x) echo s390x ;;
    *) return 1 ;;
  esac
}
xray_ensure_unzip() {
  have unzip && return 0
  echo "未检测到 unzip，正在按系统安装解压工具……"
  if have apk && ! have apt-get; then
    if ! apk add --no-cache unzip; then
      apk update && apk add --no-cache unzip || die "Alpine 安装 unzip 失败；请检查 apk 源和网络后重试"
    fi
  elif have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y unzip; then
      apt-get update && apt-get install -y unzip || die "Debian/Ubuntu 安装 unzip 失败；请检查 apt 源和网络后重试"
    fi
  elif have dnf || have yum; then
    if have dnf; then dnf install -y unzip || die "AlmaLinux 安装 unzip 失败；请检查 DNF 软件源和网络后重试"
    else yum install -y unzip || die "RPM 系统安装 unzip 失败；请检查 YUM 软件源和网络后重试"; fi
  else
    die "未找到 apk、apt-get、dnf 或 yum，无法自动安装 unzip"
  fi
  have unzip || die "安装命令已结束，但仍未找到 unzip"
  echo "unzip 已就绪。"
}
xray_install_core() {
  local latest version arch base tmp expected actual candidate
  if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
    "$XRAY_BIN" version >/dev/null 2>&1 || die "$XRAY_BIN 已存在但不是可运行的 Xray 内核；未覆盖任何文件"
    echo "已检测到本脚本使用的 Xray 内核：$XRAY_BIN"
    return 0
  fi
  arch="$(xray_arch)" || die "Xray 官方发行包暂不支持此 CPU 架构：$(uname -m)"
  xray_ensure_unzip
  echo "正在从 Xray 官方 GitHub Releases 安装 Xray 内核（架构：$arch）……"
  latest="$(curl -fsSLI --max-time 30 -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest)" || die "读取 Xray 官方最新版本失败"
  version="${latest##*/}"
  [[ "$version" =~ ^v[0-9][0-9A-Za-z.+-]*$ ]] || die "无法识别 Xray 官方版本号：$version"
  base="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
  tmp="$(mktemp -d)"
  if ! curl -fL --retry 2 --connect-timeout 15 --max-time 300 "$base" -o "$tmp/xray.zip"; then
    rm -rf "$tmp"; die "下载 Xray 官方发行包失败：$base"
  fi
  if ! curl -fL --retry 2 --connect-timeout 15 --max-time 60 "${base}.dgst" -o "$tmp/xray.zip.dgst"; then
    rm -rf "$tmp"; die "下载 Xray 官方校验文件失败，拒绝安装未校验的内核"
  fi
  expected="$(awk -F '=' '/^[[:space:]]*SHA(2-)?256[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print tolower($2); exit}' "$tmp/xray.zip.dgst")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { rm -rf "$tmp"; die "Xray 官方 SHA-256 校验文件格式无效"; }
  actual="$(sha256sum "$tmp/xray.zip" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { rm -rf "$tmp"; die "Xray 官方发行包 SHA-256 校验失败，未安装"; }
  if ! unzip -q "$tmp/xray.zip" -d "$tmp/unpack" || [[ ! -x "$tmp/unpack/xray" ]] || ! "$tmp/unpack/xray" version >/dev/null 2>&1; then
    rm -rf "$tmp"; die "Xray 官方压缩包无法解压或内核不能在本机运行"
  fi
  install -m 755 "$tmp/unpack/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  echo "已安装并通过 SHA-256 校验：$XRAY_BIN（$version）"
}
xray_prepare_user() {
  if ! id -u "$XRAY_USER" >/dev/null 2>&1; then
    if have apk && ! have apt-get; then
      addgroup -S "$XRAY_USER" 2>/dev/null || true
      adduser -S -D -H -h /var/empty -s /sbin/nologin -G "$XRAY_USER" "$XRAY_USER"
    else
      useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --user-group "$XRAY_USER"
    fi
  fi
  [[ "$(id -u "$XRAY_USER")" != 0 ]] || die "专用 Xray 服务账号不能是 root"
}
xray_write_service() {
  if [[ "$INIT_SYS" == systemd ]]; then
    if [[ -e "$XRAY_UNIT" || -L "$XRAY_UNIT" ]] && ! grep -qxF "$XRAY_MARK" "$XRAY_UNIT" 2>/dev/null; then
      die "$XRAY_UNIT 已存在且不属于本脚本；为保护现有服务，未覆盖"
    fi
    cat >"$XRAY_UNIT" <<UNIT
[Unit]
Description=sing-box manager Xray sidecar
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${XRAY_USER}
Group=${XRAY_USER}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${XRAY_DIR}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
${XRAY_MARK}
UNIT
    chmod 644 "$XRAY_UNIT"
    systemctl daemon-reload
  elif is_openrc; then
    if [[ -e "$XRAY_INIT" || -L "$XRAY_INIT" ]] && ! grep -qxF "$XRAY_MARK" "$XRAY_INIT" 2>/dev/null; then
      die "$XRAY_INIT 已存在且不属于本脚本；为保护现有服务，未覆盖"
    fi
    cat >"$XRAY_INIT" <<RC
#!/sbin/openrc-run
${XRAY_MARK}
name="singbox-xray"
description="Xray sidecar for sing-box manager"
supervisor="supervise-daemon"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONF}"
command_user="${XRAY_USER}:${XRAY_USER}"
output_log="${XRAY_LOG}"
error_log="${XRAY_LOG}"
respawn_delay=3
respawn_max=0

start_pre() {
  "${XRAY_BIN}" run -test -config "${XRAY_CONF}"
}
RC
    chmod 755 "$XRAY_INIT"
    touch "$XRAY_LOG"
    chown "$XRAY_USER:$XRAY_USER" "$XRAY_LOG"
    chmod 640 "$XRAY_LOG"
  else
    die "没有找到 systemd 或 OpenRC，无法管理 Xray sidecar"
  fi
}
xray_enable_service() {
  if is_openrc; then rc-update add "$XRAY_SERVICE" default >/dev/null 2>&1 || true
  else systemctl enable "$XRAY_SERVICE" >/dev/null 2>&1 || true; fi
}
xray_trim_log() {
  [[ -f "$XRAY_LOG" ]] || return 0
  local bytes tmp
  bytes="$(wc -c <"$XRAY_LOG")"
  if ((bytes > 20 * 1024 * 1024)); then
    tmp="${XRAY_LOG}.tmp"
    tail -n 5000 "$XRAY_LOG" >"$tmp"
    cat "$tmp" >"$XRAY_LOG"
    rm -f "$tmp"
    chown "$XRAY_USER:$XRAY_USER" "$XRAY_LOG"
    chmod 640 "$XRAY_LOG"
  fi
}
xray_restart_service() {
  if is_openrc; then
    rc-service "$XRAY_SERVICE" stop >/dev/null 2>&1 || true
    xray_trim_log
    rc-service "$XRAY_SERVICE" start
  else systemctl reset-failed "$XRAY_SERVICE" >/dev/null 2>&1 || true; systemctl restart "$XRAY_SERVICE"; fi
}
xray_service_active() {
  if is_openrc; then rc-service "$XRAY_SERVICE" status >/dev/null 2>&1
  else [[ "$(systemctl is-active "$XRAY_SERVICE" 2>/dev/null)" == active ]]; fi
}
xray_check_config() {
  "$XRAY_BIN" run -test -config "$XRAY_CONF"
}
xray_service_healthy() {
  local port="${1:-}" i
  for ((i = 0; i < 20; i++)); do
    if xray_service_active; then
      if [[ -z "$port" ]] || ss -H -lnt "( sport = :$port )" 2>/dev/null | grep -q .; then return 0; fi
    fi
    sleep 0.25
  done
  return 1
}
xray_prepare() {
  local d
  [[ ! -L "$XRAY_DIR" ]] || die "$XRAY_DIR 是符号链接，为保护现有文件未继续操作"
  if [[ -e "$XRAY_DIR" && ! -f "$XRAY_DIR_MARKER" ]]; then
    die "$XRAY_DIR 已存在且没有本脚本所有权标记；为保护现有配置/数据，未修改该目录"
  fi
  if [[ -e "$XRAY_BACKUP_DIR" && ! -f "$XRAY_BACKUP_MARKER" ]]; then
    die "$XRAY_BACKUP_DIR 已存在且没有本脚本所有权标记；为保护现有数据，未修改该目录"
  fi
  [[ ! -L "$XRAY_BACKUP_DIR" ]] || die "$XRAY_BACKUP_DIR 是符号链接，为保护现有文件未继续操作"
  [[ ! -L "$XRAY_CONF" ]] || die "$XRAY_CONF 是符号链接，为保护现有文件未继续操作"
  if [[ "$INIT_SYS" == systemd && ( -e "$XRAY_UNIT" || -L "$XRAY_UNIT" ) ]] && ! grep -qxF "$XRAY_MARK" "$XRAY_UNIT" 2>/dev/null; then
    die "$XRAY_UNIT 已存在且不属于本脚本；为保护现有服务，未安装或修改 Xray 文件"
  fi
  if is_openrc && [[ -e "$XRAY_INIT" || -L "$XRAY_INIT" ]] && ! grep -qxF "$XRAY_MARK" "$XRAY_INIT" 2>/dev/null; then
    die "$XRAY_INIT 已存在且不属于本脚本；为保护现有服务，未安装或修改 Xray 文件"
  fi
  xray_prepare_user
  xray_install_core
  mkdir -p "$XRAY_DIR" "$XRAY_DATA" "$XRAY_CERT_DIR" "$XRAY_BACKUP_DIR"
  for d in "$XRAY_DATA" "$XRAY_CERT_DIR" "$XRAY_BACKUP_DIR"; do
    [[ ! -L "$d" ]] || die "$d 是符号链接，为保护现有文件未继续操作"
  done
  if [[ ! -f "$XRAY_DIR_MARKER" ]]; then
    printf '%s\n' "$XRAY_MARK" >"$XRAY_DIR_MARKER"
    chmod 600 "$XRAY_DIR_MARKER"
  fi
  if [[ ! -f "$XRAY_BACKUP_MARKER" ]]; then
    printf '%s\n' "$XRAY_MARK" >"$XRAY_BACKUP_MARKER"
    chmod 600 "$XRAY_BACKUP_MARKER"
  fi
  chown root:"$XRAY_USER" "$XRAY_DIR" "$XRAY_CERT_DIR"
  chmod 750 "$XRAY_DIR" "$XRAY_CERT_DIR"
  chown root:root "$XRAY_DATA" "$XRAY_BACKUP_DIR"
  chmod 700 "$XRAY_DATA" "$XRAY_BACKUP_DIR"
  if [[ ! -f "$XRAY_CONF" ]]; then
    cat >"$XRAY_CONF" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
JSON
  fi
  chown root:"$XRAY_USER" "$XRAY_CONF"
  chmod 640 "$XRAY_CONF"
  xray_write_service
  xray_check_config || die "Xray 当前配置校验失败，未继续修改；查看配置：$XRAY_CONF"
}
xray_backup_config() {
  local b="$XRAY_BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S-%N).json"
  cp -a "$XRAY_CONF" "$b"
  chmod 600 "$b"
  printf '%s' "$b"
}
xray_commit_jq() {
  # 第一参数是期望监听端口（空表示只检查服务状态），其余参数原样传给 jq。
  local expected_port="$1" backup tmp
  shift
  tmp="${XRAY_CONF}.tmp"
  backup="$(xray_backup_config)"
  if ! jq "$@" "$XRAY_CONF" >"$tmp"; then rm -f "$tmp"; die "生成 Xray 新配置失败，未做任何改动"; fi
  install -o root -g "$XRAY_USER" -m 640 "$tmp" "$XRAY_CONF"
  rm -f "$tmp"
  if ! xray_check_config; then
    cp -a "$backup" "$XRAY_CONF"; chown root:"$XRAY_USER" "$XRAY_CONF"; chmod 640 "$XRAY_CONF"
    die "Xray 配置校验失败，已恢复修改前配置（没有任何改动）"
  fi
  xray_enable_service
  if ! xray_restart_service || ! xray_service_healthy "$expected_port"; then
    cp -a "$backup" "$XRAY_CONF"; chown root:"$XRAY_USER" "$XRAY_CONF"; chmod 640 "$XRAY_CONF"
    xray_restart_service >/dev/null 2>&1 || true
    die "Xray 未能按新配置启动或监听端口；已恢复旧配置。查看服务日志：$(xray_log_hint)"
  fi
}
xray_log_hint() { if is_openrc; then echo "tail -n 100 $XRAY_LOG"; else echo "journalctl -u $XRAY_SERVICE -n 100 --no-pager"; fi; }
xray_port_in_config() { jq -e --argjson p "$1" '[.inbounds[]? | select(.port == $p)] | length > 0' "$XRAY_CONF" >/dev/null 2>&1; }
xray_valid_path() { [[ "$1" == /* && ! "$1" =~ [[:space:]] ]]; }
xray_free_port() {
  local p="$1" i
  for ((i = 0; i < 500; i++, p++)); do
    (( p <= 65535 )) || p=20000
    port_in_config "$p" && continue
    xray_port_in_config "$p" && continue
    port_free "$p" tcp || continue
    printf '%s' "$p"; return 0
  done
  printf '%s' "$1"
}
xray_make_cert() {
  local tag="$1" host="$2" san cert key fingerprint
  cert="$XRAY_CERT_DIR/$tag.crt"; key="$XRAY_CERT_DIR/$tag.key"
  [[ ! -e "$cert" && ! -e "$key" ]] || die "Xray 节点证书文件已存在：$tag（未覆盖）"
  if valid_ipv4 "$host" || valid_ipv6 "$host"; then san="IP:$host"; else san="DNS:$host"; fi
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
    -keyout "$key" -out "$cert" -subj "/CN=${host}" -addext "subjectAltName=${san}" >/dev/null 2>&1 || die "生成 Xray 自签证书失败"
  chown root:"$XRAY_USER" "$cert" "$key"
  chmod 640 "$cert" "$key"
  fingerprint="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/.*=//' | tr -d ':' | tr 'A-F' 'a-f')"
  [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || die "计算自签证书 SHA-256 指纹失败"
  printf '%s\n%s\n%s' "$cert" "$key" "$fingerprint"
}
xray_add_node() {
  local tag host port choice network uri_type cert_result cert key fingerprint uuid path vhost service_name transport obj meta TLS_HOST
  xray_prepare
  ask_tag tag xray-tls
  prompt port "Xray TCP 端口" "$(xray_free_port 8443)"
  valid_port "$port" || die "端口必须是 1-65535 的数字"
  port="$((10#$port))"
  if is_openrc && ((port < 1024)); then die "Alpine/OpenRC 下 Xray 以专用非 root 用户运行，请选择 1024 以上的端口"; fi
  port_in_config "$port" && die "端口 $port 已被 sing-box 节点占用"
  xray_port_in_config "$port" && die "端口 $port 已被其他 Xray 节点占用"
  port_free "$port" tcp || die "端口 $port/tcp 已被其他程序占用"
  prompt TLS_HOST "VLESS + TLS 域名（需解析到本服务器；用于连接地址、SNI 和证书）" ""
  valid_domain "$TLS_HOST" || die "VLESS + TLS 入站必须使用有效域名，不能填 IP"
  host="$TLS_HOST"
  echo "Xray + TLS 传输方式（默认优选 XHTTP auto）："
  echo "1) XHTTP / auto（推荐）"
  echo "2) RAW/TCP"
  echo "3) WebSocket（上游已标记弃用）"
  echo "4) gRPC（上游已标记弃用）"
  echo "5) HTTPUpgrade（上游已标记弃用）"
  read -r -p "选择 [1-5，默认 1]: " choice || choice=1
  case "${choice:-1}" in
    1)
      network=xhttp; uri_type=xhttp
      path="/xhttp-$(random_hex 4)"
      prompt path "XHTTP path" "$path"
      xray_valid_path "$path" || die "XHTTP path 必须以 / 开头且不能包含空白字符"
      prompt vhost "XHTTP Host（默认使用证书域名/IP）" "$TLS_HOST"
      valid_host "$vhost" || die "XHTTP Host 必须是有效域名或 IP"
      transport="$(jq -n --arg host "$vhost" --arg path "$path" '{xhttpSettings:{host:$host,path:$path,mode:"auto"}}')"
      ;;
    2) network=raw; uri_type=tcp; transport='{}' ;;
    3)
      network=ws; uri_type=ws
      path="/ws-$(random_hex 4)"
      prompt path "WebSocket path" "$path"
      xray_valid_path "$path" || die "WebSocket path 必须以 / 开头且不能包含空白字符"
      prompt vhost "WebSocket Host" "$TLS_HOST"
      valid_host "$vhost" || die "WebSocket Host 必须是有效域名或 IP"
      transport="$(jq -n --arg host "$vhost" --arg path "$path" '{wsSettings:{host:$host,path:$path}}')"
      ;;
    4)
      network=grpc; uri_type=grpc
      service_name="grpc-$(clean_tag_fragment "$tag")"
      prompt service_name "gRPC serviceName" "$service_name"
      [[ -n "$service_name" && ! "$service_name" =~ [[:space:]] ]] || die "gRPC serviceName 不能为空且不能包含空白字符"
      transport="$(jq -n --arg name "$service_name" '{grpcSettings:{serviceName:$name}}')"
      ;;
    5)
      network=httpupgrade; uri_type=httpupgrade
      path="/upgrade-$(random_hex 4)"
      prompt path "HTTPUpgrade path" "$path"
      xray_valid_path "$path" || die "HTTPUpgrade path 必须以 / 开头且不能包含空白字符"
      prompt vhost "HTTPUpgrade Host" "$TLS_HOST"
      valid_host "$vhost" || die "HTTPUpgrade Host 必须是有效域名或 IP"
      transport="$(jq -n --arg host "$vhost" --arg path "$path" '{httpupgradeSettings:{host:$host,path:$path}}')"
      ;;
    *) die "无效传输方式" ;;
  esac
  uuid="$("$XRAY_BIN" uuid)" || die "生成 VLESS UUID 失败"
  cert_result="$(xray_make_cert "$tag" "$TLS_HOST")"
  cert="$(sed -n '1p' <<<"$cert_result")"
  key="$(sed -n '2p' <<<"$cert_result")"
  fingerprint="$(sed -n '3p' <<<"$cert_result")"
  # Xray 当前仍兼容 network；method 优先级更高，因此只写 network，避免产生字段覆盖歧义。
  obj="$(jq -n --arg tag "$tag" --arg uuid "$uuid" --arg cert "$cert" --arg key "$key" \
    --arg network "$network" --argjson port "$port" --argjson transport "$transport" \
    '{tag:$tag,listen:"::",port:$port,protocol:"vless",settings:{clients:[{id:$uuid,email:$tag}],decryption:"none"},streamSettings:({network:$network,security:"tls",tlsSettings:{alpn:["h2","http/1.1"],certificates:[{certificateFile:$cert,keyFile:$key}]}} + $transport)}')"
  meta="$(jq -n --arg tag "$tag" --arg host "$host" --arg uuid "$uuid" --arg sni "$TLS_HOST" \
    --arg cert "$cert" --arg key "$key" --arg fp "$fingerprint" --arg network "$network" --arg type "$uri_type" \
    --arg path "${path:-}" --arg xhost "${vhost:-}" --arg service "${service_name:-}" --argjson port "$port" \
    '{protocol:"VLESS + TLS (Xray)",tag:$tag,server:$host,port:$port,uuid:$uuid,sni:$sni,transport:$type,xray_network:$network,certificate:$cert,key:$key,certificate_sha256:$fp} + (if $path != "" then {path:$path} else {} end) + (if $xhost != "" then {host:$xhost} else {} end) + (if $service != "" then {service_name:$service} else {} end)')"
  install -m 600 /dev/null "$XRAY_DATA/$tag.json"
  printf '%s\n' "$meta" >"$XRAY_DATA/$tag.json"
  if ! xray_commit_jq "$port" --argjson obj "$obj" '.inbounds += [$obj]'; then
    rm -f "$XRAY_DATA/$tag.json" "$cert" "$key"; return 1
  fi
  LAST_TAG="$tag"
  echo "Xray VLESS + TLS 节点已添加：$tag（$uri_type；Xray $("$XRAY_BIN" version | awk 'NR==1{print $2}')）"
  echo "证书采用自签 + SHA-256 pin；客户端需支持分享链接参数 pcs，不能支持时请使用受信任证书或客户端的证书指纹设置。"
  print_link "$XRAY_DATA/$tag.json"
  echo "防火墙：请在系统防火墙和云安全组放行 TCP $port。"
}
xray_remove_node() {
  local tag="$1" cert key
  [[ -f "$XRAY_DATA/$tag.json" ]] || die "没有名为 $tag 的 Xray 节点"
  cert="$(jq -r '.certificate // empty' "$XRAY_DATA/$tag.json")"
  key="$(jq -r '.key // empty' "$XRAY_DATA/$tag.json")"
  xray_commit_jq "" --arg t "$tag" '.inbounds |= map(select(.tag != $t))'
  rm -f "$XRAY_DATA/$tag.json" "$cert" "$key"
  echo "已删除 Xray 节点：$tag（其他 sing-box 节点不受影响）"
}
xray_change_port() {
  local tag="$1" new="$2" meta old tmp host
  meta="$XRAY_DATA/$tag.json"
  [[ -f "$meta" ]] || die "没有名为 $tag 的 Xray 节点"
  old="$(jq -r .port "$meta")"
  host="$(jq -r '.sni // empty' "$meta")"
  valid_domain "$host" || die "Xray 节点 $tag 缺少有效的证书域名，未修改端口"
  if [[ -z "$new" ]]; then new="$(xray_free_port "$((old + 1))")"; prompt new "新 Xray TCP 端口" "$new"; fi
  valid_port "$new" || die "端口必须是 1-65535 的数字"
  new="$((10#$new))"
  if is_openrc && ((new < 1024)); then die "Alpine/OpenRC 下 Xray 以专用非 root 用户运行，请选择 1024 以上的端口"; fi
  [[ "$new" != "$old" ]] || { echo "新端口和当前端口相同（$old），没有改动。"; return 0; }
  port_in_config "$new" && die "端口 $new 已被 sing-box 节点占用"
  xray_port_in_config "$new" && die "端口 $new 已被其他 Xray 节点占用"
  port_free "$new" tcp || die "端口 $new/tcp 已被其他程序占用"
  xray_commit_jq "$new" --arg t "$tag" --argjson p "$new" '.inbounds |= map(if .tag == $t then .port = $p else . end)'
  tmp="$meta.tmp"
  jq --argjson p "$new" --arg h "$host" '.port=$p | .server=$h' "$meta" >"$tmp"
  install -m 600 "$tmp" "$meta"; rm -f "$tmp"
  echo "已把 Xray 节点 $tag 的端口从 $old 改为 $new。"
  print_link "$meta"
  echo "请放行 TCP $new，并关闭不再使用的 TCP $old。"
}
xray_status() {
  if [[ ! -x "$XRAY_BIN" ]]; then echo "Xray sidecar 尚未安装。添加 VLESS + TLS 节点时会从官方发行包安装。"; return 0; fi
  echo "=== Xray 版本 ==="; "$XRAY_BIN" version | head -n2 || true
  echo "=== Xray sidecar 服务 ==="
  if is_openrc; then rc-service "$XRAY_SERVICE" status || true
  else systemctl --no-pager --full status "$XRAY_SERVICE" || true; fi
  echo "=== Xray TCP 监听 ==="; ss -lntp | grep -E 'singbox-xray|xray' || true
}
xray_logs() {
  local n="${1:-100}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=100
  if is_openrc; then [[ -s "$XRAY_LOG" ]] && tail -n "$n" "$XRAY_LOG" || echo "暂无 Xray 日志（$XRAY_LOG）"
  else journalctl -u "$XRAY_SERVICE" -n "$n" --no-pager; fi
}

tag_exists() {
  jq -e --arg t "$1" '[.inbounds[]?, .outbounds[]? | select(.tag == $t)] | length > 0' "$CONF" >/dev/null 2>&1 || [[ -e "$DATA/$1.json" || -e "$XRAY_DATA/$1.json" ]]
}
next_tag() {
  local base="$1" n=1
  while tag_exists "${base}-${n}"; do n=$((n + 1)); done
  printf '%s-%s' "$base" "$n"
}
clean_tag_fragment() {
  # 将 sing-box tag 或服务器地址变成管理器允许的短标签片段
  printf '%s' "$1" | LC_ALL=C sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+//; s/-+$//'
}
telegram_local_tag() {
  # 返回本地第一个可用的 sing-box 入站 tag 片段；本地没有合适名称时返回空。
  local source
  while IFS= read -r source; do
    source="$(clean_tag_fragment "$source")"
    [[ -n "$source" ]] || continue
    printf '%s' "${source:0:27}"
    return 0
  done < <(jq -r '.inbounds[]? | .tag? | select(type == "string" and length > 0)' "$CONF")
  return 1
}
telegram_auto_tag() {
  # 优先从本机 sing-box 入站 tag 生成名称；没有可用 tag 时回退到服务器主机名/地址。
  # 默认名在当前配置与凭据目录中自动避开重名；无本地 tag 时调用方可让用户自定义。
  local server_host="${1:-}" source base fallback candidate suffix max_prefix n=1
  source="$(telegram_local_tag || true)"
  if [[ -n "$source" ]]; then
    base="${source}-tg-socks5"
  else
    fallback="$server_host"
    [[ -n "$fallback" ]] || fallback="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
    fallback="$(clean_tag_fragment "$fallback")"
    fallback="${fallback:0:25}"
    base="tg-socks5-${fallback:-node}"
  fi
  while true; do
    suffix="-$n"
    max_prefix=$((40 - ${#suffix}))
    candidate="${base:0:max_prefix}${suffix}"
    if ! tag_exists "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    n=$((n + 1))
  done
}
ask_tag() {
  # $1：变量名；$2：默认前缀
  local __t
  prompt __t "节点名称" "$(next_tag "${TAG_PREFIX}$2")"
  valid_tag "$__t"
  tag_exists "$__t" && die "节点名称 $__t 已存在，请换一个"
  printf -v "$1" '%s' "$__t"
}

# ---------- 分享链接 ----------
print_link() {
  # 根据节点凭据文件生成分享链接（服务器地址取文件里的 server 字段）
  local f="$1" proto h userinfo encoded_server encoded_user encoded_pass port https_link tg_link
  proto="$(jq -r '.protocol' "$f")"
  h="$(uri_host "$(jq -r '.server' "$f")")"
  case "$proto" in
    VMess)
      echo "分享链接（标准 VMess URI；TCP + AEAD，alterId=0）："
      local vmess_json
      vmess_json="$(jq -nc --arg tag "$(jq -r '.tag' "$f")" --arg host "$(jq -r '.server' "$f")" \
        --arg port "$(jq -r '.port' "$f")" --arg uuid "$(jq -r '.uuid' "$f")" \
        '{v:"2",ps:$tag,add:$host,port:$port,id:$uuid,aid:"0",scy:"auto",net:"tcp",type:"none",host:"",path:"",tls:"",sni:""}')"
      printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64 | tr -d '\r\n')"
      ;;
    "VLESS + Reality")
      if (( $(jq '(.fps // [.fp // "chrome"]) | length' "$f") > 1 )); then
        echo "分享链接（标准 VLESS Reality URI，每个指纹一条）："
      else
        echo "分享链接（标准 VLESS Reality URI）："
      fi
      jq -r --arg h "$h" '(.fps // [.fp // "chrome"]) as $fps | $fps[] as $fp
        | "vless://\(.uuid)@\($h):\(.port)?encryption=none&security=reality&sni=\(.sni)&fp=\($fp)&pbk=\(.public_key)&sid=\(.short_id)&type=tcp&flow=xtls-rprx-vision#\(.tag)\(if ($fps | length) > 1 then "-" + $fp else "" end)"' "$f" ;;
    "VLESS + TLS (Xray)")
      local uuid qname qhost qpath qservice qfp typ
      uuid="$(urlencode "$(jq -r '.uuid' "$f")")"
      qname="$(urlencode "$(jq -r '.tag' "$f")")"
      qfp="$(urlencode "$(jq -r '.certificate_sha256' "$f")")"
      typ="$(jq -r '.transport' "$f")"
      printf '分享链接（Xray VLESS + TLS；自签证书 SHA-256 pin）：\n'
      printf 'vless://%s@%s:%s?encryption=none&security=tls&type=%s&sni=%s&fp=chrome&pcs=%s' \
        "$uuid" "$h" "$(jq -r '.port' "$f")" "$typ" "$(urlencode "$(jq -r '.sni' "$f")")" "$qfp"
      case "$typ" in
        xhttp)
          qhost="$(urlencode "$(jq -r '.host // empty' "$f")")"; qpath="$(urlencode "$(jq -r '.path' "$f")")"
          printf '&host=%s&path=%s&mode=auto' "$qhost" "$qpath" ;;
        ws|httpupgrade)
          qhost="$(urlencode "$(jq -r '.host // empty' "$f")")"; qpath="$(urlencode "$(jq -r '.path' "$f")")"
          printf '&host=%s&path=%s' "$qhost" "$qpath" ;;
        grpc) qservice="$(urlencode "$(jq -r '.service_name' "$f")")"; printf '&serviceName=%s' "$qservice" ;;
      esac
      printf '#%s\n' "$qname"
      echo "提示：pcs 是证书 SHA-256 pin（不是跳过验证）；客户端需支持 Xray 分享链接提案中的 pcs 参数。"
      ;;
    Hysteria2)
      if [[ "$(jq -r 'if .insecure == false then "0" else "1" end' "$f")" == 0 ]]; then
        echo "分享链接（使用受信任证书）："
        jq -r --arg h "$h" '"hysteria2://\(.password|@uri)@\($h):\(.port)/?sni=\(.sni)#\(.tag)"' "$f"
      else
        echo "分享链接（自签证书，客户端需允许不安全证书）："
        jq -r --arg h "$h" '"hysteria2://\(.password|@uri)@\($h):\(.port)/?insecure=1&sni=\(.sni)#\(.tag)"' "$f"
      fi ;;
    TUIC)
      if [[ "$(jq -r 'if .insecure == false then "0" else "1" end' "$f")" == 0 ]]; then
        echo "分享链接（使用受信任证书）："
        jq -r --arg h "$h" '"tuic://\(.uuid):\(.password|@uri)@\($h):\(.port)?congestion_control=bbr&alpn=h3&sni=\(.sni)#\(.tag)"' "$f"
      else
        echo "分享链接（自签证书，客户端需允许不安全证书）："
        jq -r --arg h "$h" '"tuic://\(.uuid):\(.password|@uri)@\($h):\(.port)?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=\(.sni)#\(.tag)"' "$f"
      fi ;;
    AnyTLS)
      if [[ "$(jq -r 'if .insecure == false then "0" else "1" end' "$f")" == 0 ]]; then
        echo "分享链接（使用受信任证书；不同客户端 URI 参数可能不同，请核对客户端文档）："
        jq -r --arg h "$h" '(.fps // (if .fp then [.fp] else [""] end)) as $fps | $fps[] as $fp
          | "anytls://\(.password|@uri)@\($h):\(.port)/?sni=\(.sni)\(if $fp != "" then "&fp=" + $fp else "" end)#\(.tag)\(if ($fps | length) > 1 then "-" + $fp else "" end)"' "$f"
      else
        echo "分享链接（自签证书，客户端需允许不安全证书；不同客户端 URI 参数可能不同，请核对客户端文档）："
        jq -r --arg h "$h" '(.fps // (if .fp then [.fp] else [""] end)) as $fps | $fps[] as $fp
          | "anytls://\(.password|@uri)@\($h):\(.port)/?insecure=1&sni=\(.sni)\(if $fp != "" then "&fp=" + $fp else "" end)#\(.tag)\(if ($fps | length) > 1 then "-" + $fp else "" end)"' "$f"
      fi ;;
    Trojan)
      if [[ "$(jq -r 'if .insecure == false then "0" else "1" end' "$f")" == 0 ]]; then
        echo "分享链接（Trojan over TLS，使用受信任证书）："
        jq -r --arg h "$h" '"trojan://\(.password|@uri)@\($h):\(.port)?security=tls&sni=\(.sni)&type=tcp#\(.tag)"' "$f"
      else
        echo "分享链接（自签证书，客户端需允许不安全证书）："
        jq -r --arg h "$h" '"trojan://\(.password|@uri)@\($h):\(.port)?security=tls&sni=\(.sni)&type=tcp&allowInsecure=1#\(.tag)"' "$f"
      fi ;;
    "VMess + WS (Argo)")
      local vmess_json
      echo "分享链接（VMess + WebSocket + TLS，经 Cloudflare Argo 隧道）："
      vmess_json="$(jq -nc --arg tag "$(jq -r '.tag' "$f")" --arg host "$(jq -r '.server' "$f")" \
        --arg path "$(jq -r '.path' "$f")" --arg ws "$(jq -r '.ws_host // .server' "$f")" --arg uuid "$(jq -r '.uuid' "$f")" \
        '{v:"2",ps:$tag,add:$host,port:"443",id:$uuid,aid:"0",scy:"auto",net:"ws",type:"none",host:$ws,path:$path,tls:"tls",sni:$ws}')"
      printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64 | tr -d '\r\n')"
      ;;
    "VLESS + WS (Argo)")
      local ahost apath atag
      ahost="$(urlencode "$(jq -r '.ws_host // .server' "$f")")"
      apath="$(urlencode "$(jq -r '.path' "$f")")"
      atag="$(urlencode "$(jq -r '.tag' "$f")")"
      echo "分享链接（VLESS + WebSocket + TLS，经 Cloudflare Argo 隧道）："
      printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&host=%s&path=%s&sni=%s#%s\n' \
        "$(urlencode "$(jq -r '.uuid' "$f")")" "$h" "$ahost" "$apath" "$ahost" "$atag"
      ;;
    Shadowsocks)
      userinfo="$(jq -j '"\(.method):\(.password)"' "$f" | base64 | tr -d '\r\n')"
      echo "分享链接："
      jq -r --arg h "$h" --arg u "$userinfo" '"ss://\($u)@\($h):\(.port)#\(.tag)"' "$f" ;;
    "Telegram SOCKS5")
      encoded_server="$(urlencode "$(jq -r '.server' "$f")")"
      port="$(jq -r '.port' "$f")"
      encoded_user="$(urlencode "$(jq -r '.username' "$f")")"
      encoded_pass="$(urlencode "$(jq -r '.password' "$f")")"
      https_link="https://t.me/socks?server=$encoded_server&port=$port&user=$encoded_user&pass=$encoded_pass"
      tg_link="tg://socks?server=$encoded_server&port=$port&user=$encoded_user&pass=$encoded_pass"
      echo "Telegram SOCKS5 一键添加链接（点击或复制到 Telegram）："
      printf '%s\n' "$https_link"
      echo "Telegram 应用深链："
      printf '%s\n' "$tg_link"
      echo "手动配置参数（SOCKS5；此节点不支持 MTProto）："
      jq -r '"服务器：\(.server)\n端口：\(.port)\n用户名：\(.username)\n密码：\(.password)"' "$f"
      echo "Telegram 路径：设置 → 数据和存储 → 代理设置 → 添加代理 → SOCKS5。"
      echo "请只把凭据提供给信任的设备/用户；本脚本不会自动修改防火墙。"
      ;;
    *) echo "（未知协议 $proto，无法生成分享链接）" ;;
  esac
}
print_client_payload() {
  # $1 客户端组；按核心支持情况筛选 URI，然后按行合并并 Base64 编码。
  local client="$1" f proto tmp encoded
  shift
  tmp="$(mktemp)"
  for f in "$@"; do
    proto="$(jq -r '.protocol // empty' "$f")"
    case "$client:$proto" in
      "v2rayNG:VLESS + Reality"|"v2rayNG:VMess"|"v2rayNG:Shadowsocks"|"v2rayNG:Trojan"|"v2rayNG:VMess + WS (Argo)"|"v2rayNG:VLESS + WS (Argo)") ;;
      "NekoBox/sing-box:VLESS + Reality"|"NekoBox/sing-box:VMess"|"NekoBox/sing-box:Hysteria2"|"NekoBox/sing-box:TUIC"|"NekoBox/sing-box:AnyTLS"|"NekoBox/sing-box:Shadowsocks"|"NekoBox/sing-box:Trojan"|"NekoBox/sing-box:VMess + WS (Argo)"|"NekoBox/sing-box:VLESS + WS (Argo)") ;;
      *) continue ;;
    esac
    print_link "$f" | grep -E '^(vless|vmess|hysteria2|hy2|tuic|anytls|ss|trojan)://' >>"$tmp" || true
  done
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "$client：没有符合兼容性筛选条件的分享链接。"
    return 0
  fi
  encoded="$(base64 <"$tmp" | tr -d '\r\n')"
  rm -f "$tmp"
  echo
  echo "[$client] Base64 导入内容（每条分享链接按一行编码，复制整行）："
  printf '%s\n' "$encoded"
}
save_node() {
  # $1：节点 tag；$2：凭据 JSON。保存后显示参数和分享链接
  local f="$DATA/$1.json"
  jq --arg r "$RELAY_DESC" 'if $r != "" then . + {relay_to: $r} else . end' <<<"$2" >"$f"
  chmod 600 "$f"
  LAST_TAG="$1"
  jq . "$f"
  print_link "$f"
  tg_maybe_autopush "$1" || true
}

# ---------- TLS 指纹（uTLS） ----------
# sing-box 1.14 支持的 uTLS 指纹；只有 VLESS Reality、AnyTLS 这类 TCP 上的 TLS 协议用得上
FP_LIST=(chrome firefox safari ios android edge 360 qq random randomized)
valid_fp() { local x; for x in "${FP_LIST[@]}"; do [[ "$1" == "$x" ]] && return 0; done; return 1; }
# Reality 需要 TLS 1.3 的 X25519 密钥交换；android、360 指纹没有，客户端会报 nil ecdheKey
REALITY_BAD_FP="android 360"
parse_fps() {
  # 把“1,3”“chrome firefox”“all/全部”转换成去重后的指纹列表（空格分隔）；无效时返回 1
  # $2=reality 时去掉 Reality 用不了的指纹
  local in="$1" mode="${2:-}" t res=() x seen skipped=""
  in="${in//，/ }"; in="${in//、/ }"; in="${in//,/ }"; in="${in//;/ }"; in="${in,,}"
  for t in $in; do
    case "$t" in
      all|全部|a) res=("${FP_LIST[@]}"); break ;;
    esac
    if valid_fp "$t"; then :
    elif [[ "$t" =~ ^[0-9]+$ ]] && (( 10#$t >= 1 && 10#$t <= ${#FP_LIST[@]} )); then t="${FP_LIST[$((10#$t - 1))]}"
    else echo "不认识的指纹：$t（可选：${FP_LIST[*]}，或 all）" >&2; return 1; fi
    seen=0; for x in "${res[@]}"; do [[ "$x" == "$t" ]] && seen=1; done
    (( seen )) || res+=("$t")
  done
  if [[ "$mode" == reality ]]; then
    local keep=()
    for x in "${res[@]}"; do
      if [[ " $REALITY_BAD_FP " == *" $x "* ]]; then skipped+="$x "; else keep+=("$x"); fi
    done
    res=("${keep[@]}")
    [[ -z "$skipped" || "$in" == *all* || "$in" == *全部* ]] ||
      echo "提示：Reality 不支持 ${skipped% } 指纹（缺少 TLS 1.3 的 X25519 密钥交换，客户端会连不上），已跳过。" >&2
  fi
  ((${#res[@]})) || return 1
  printf '%s' "${res[*]}"
}
show_fp_choices() {
  # $1=reality 时说明 android、360 不可用
  echo "  1) chrome   2) firefox   3) safari   4) ios    5) android"
  echo "  6) edge     7) 360       8) qq       9) random 10) randomized（每次连接随机）"
  if [[ "${1:-}" == reality ]]; then
    echo "  all) 全部可用的 8 种（Reality 不支持 android 和 360，会自动跳过）"
  else
    echo "  all) 全部 10 种"
  fi
  echo "可以选多个，用逗号或空格分开，例如 1,2,4 或 chrome firefox。每个指纹生成一条分享链接。"
}
choose_fps() {
  # $1：变量名（结果为空格分隔的指纹列表）；$2：默认值；$3=reality 时排除 Reality 用不了的指纹
  local __v __r __def="${2:-chrome}"
  echo "客户端 TLS 指纹（uTLS fp）："
  show_fp_choices "${3:-}"
  read -r -p "选择 [默认 $__def]: " __v || __v=""
  [[ -n "${__v//[[:space:]]/}" ]] || __v="$__def"
  __r="$(parse_fps "$__v" "${3:-}")" || die "指纹选择无效"
  printf -v "$1" '%s' "$__r"
  echo "已选择指纹：$__r"
}
fps_json() { jq -nc --arg s "$1" '$s | split(" ") | map(select(. != ""))'; }

# ---------- 端口 ----------
port_in_config() { jq -e --argjson p "$1" '[.inbounds[]? | select(.listen_port == $p)] | length > 0' "$CONF" >/dev/null 2>&1; }
check_port() {
  local p="$1" proto="$2"
  valid_port "$p" || die "端口必须是 1-65535 的数字"
  port_in_config "$((10#$p))" && die "端口 $p 已被配置里的其他节点使用，请换一个端口"
  port_free "$p" "$proto" || die "端口 $p/$proto 已被占用，请换一个端口"
}
free_port() {
  # 从 $1 开始找一个没被占用的端口；$2：tcp / udp / both
  local p="$1" proto="${2:-tcp}" i
  for ((i = 0; i < 500; i++, p++)); do
    (( p <= 65535 )) || p=20000
    port_in_config "$p" && continue
    case "$proto" in
      both) port_free "$p" tcp && port_free "$p" udp || continue ;;
      *) port_free "$p" "$proto" || continue ;;
    esac
    printf '%s' "$p"; return 0
  done
  printf '%s' "$1"
}

# ---------- Reality SNI 扫描 ----------
# 候选域名按分类和地区分组；每个域名都从本 VPS 自己独立验证 TLS 1.3 / X25519 / HTTP/2 / 证书链。
SNI_ROWS=()
sni_cat() {
  case "${1,,}" in
    big-tech|bigtech|大厂|科技)
      echo "www.bing.com www.microsoft.com www.apple.com www.amazon.com aws.amazon.com azure.microsoft.com login.live.com www.icloud.com www.cloudflare.com" ;;
    cdn|cdn-saas|saas)
      echo "www.fastly.com cdn.jsdelivr.net unpkg.com cdnjs.cloudflare.com www.akamai.com www.digitalocean.com www.cloudflare.com" ;;
    dev|dev-tools|工具)
      echo "github.com gitlab.com registry.npmjs.org www.npmjs.com hub.docker.com pypi.org www.python.org nodejs.org stackoverflow.com" ;;
    media|streaming|流媒体)
      echo "www.netflix.com open.spotify.com www.twitch.tv www.youtube.com www.disneyplus.com www.vimeo.com" ;;
    ecom|e-commerce|电商)
      echo "www.rakuten.co.jp shopee.sg www.allegro.pl www.mercadolibre.com www.ebay.com www.aliexpress.com" ;;
    all|全部)
      echo "$(sni_cat big-tech) $(sni_cat cdn) $(sni_cat dev) $(sni_cat media) $(sni_cat ecom)" ;;
    *) return 1 ;;
  esac
}
sni_categories() { echo "big-tech cdn dev media ecom all"; }
sni_region_extra() {
  case "${1^^}" in
    US) echo "www.verizon.com www.walmart.com www.usps.com" ;;
    JP) echo "www.yahoo.co.jp www.rakuten.co.jp www.sony.jp www.nicovideo.jp" ;;
    SG) echo "www.shopee.sg www.straitstimes.com www.dbs.com.sg" ;;
    HK) echo "www.hk01.com www.openrice.com www.hktvmall.com" ;;
    KR) echo "www.naver.com www.daum.net www.coupang.com" ;;
    DE) echo "www.spiegel.de www.heise.de www.deutschebahn.com" ;;
    GB) echo "www.bbc.co.uk www.theguardian.com www.gov.uk" ;;
    FR) echo "www.lemonde.fr www.orange.fr www.fnac.com" ;;
    NL) echo "www.nu.nl www.bol.com" ;;
    TW) echo "www.pchome.com.tw www.books.com.tw" ;;
    CA) echo "www.cbc.ca www.canada.ca" ;;
    AU) echo "www.abc.net.au www.seek.com.au" ;;
    RU) echo "www.yandex.ru www.ozon.ru" ;;
    IN) echo "www.flipkart.com www.indiatimes.com" ;;
    BR) echo "www.globo.com www.uol.com.br" ;;
    *) echo "" ;;
  esac
}
sni_detect_region() {
  # 读取本机出口 IP 的国家代码（两个字母）；失败时输出空
  local r
  for u in https://api.country.is/ https://ipinfo.io/country https://ifconfig.co/country-iso https://ipapi.co/country/; do
    r="$(curl -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$r" == \{* ]] && r="$(printf '%s' "$r" | jq -r '.country // empty' 2>/dev/null || true)"
    r="${r^^}"
    [[ "$r" =~ ^[A-Z]{2}$ ]] && { printf '%s' "$r"; return 0; }
  done
  return 0
}
sni_ca_file() {
  local f
  for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem /etc/ssl/certs/ca-bundle.crt; do
    [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 0
}
sni_probe() {
  # $1 域名；输出一行制表符分隔：域名 结果 延迟ms TLS13 X25519 H2 证书 说明
  local d="$1" out="" rc=0 start end ms=0 tls=0 kx=0 h2=0 cert=0 certtxt="bad" note="" ca pem
  local -a args
  ca="$(sni_ca_file)"
  args=(-connect "${d}:443" -servername "$d" -tls1_3 -groups X25519 -alpn h2 -showcerts -verify_hostname "$d")
  [[ -n "$ca" ]] && args+=(-CAfile "$ca")
  start="$(date +%s%N 2>/dev/null || true)"
  out="$(timeout 12 openssl s_client "${args[@]}" </dev/null 2>&1)" || rc=$?
  end="$(date +%s%N 2>/dev/null || true)"
  if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] && (( end > start )); then
    ms=$(( (end - start) / 1000000 ))
  fi
  grep -qE 'Protocol[[:space:]]*:[[:space:]]*TLSv1\.3' <<<"$out" && tls=1
  # TLS 1.3 下 s_client 不再打印 Server Temp Key；用 -groups X25519 强制只协商 X25519，
  # 握手能拿到密码套件就说明对端支持 X25519。TLS 1.2 的输出里则直接看 Server Temp Key。
  if grep -qE 'Server Temp Key[[:space:]]*:[[:space:]]*X25519' <<<"$out"; then
    kx=1
  elif [[ "$tls" == 1 ]] && grep -qE 'Cipher[[:space:]]+is[[:space:]]' <<<"$out"; then
    kx=1
  fi
  grep -qE 'ALPN protocol[[:space:]]*:[[:space:]]*h2' <<<"$out" && h2=1
  if grep -qE 'Verify return code[[:space:]]*:[[:space:]]*0' <<<"$out"; then
    cert=1; certtxt="ok"
    pem="$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' <<<"$out" | head -n 200)"
    if [[ -n "$pem" ]] && printf '%s\n' "$pem" | openssl x509 -noout -checkend 2592000 >/dev/null 2>&1; then
      certtxt="ok>30d"
    elif [[ -n "$pem" ]] && printf '%s\n' "$pem" | openssl x509 -noout -checkend 604800 >/dev/null 2>&1; then
      certtxt="ok<30d"
    else
      certtxt="ok临期"
    fi
  elif [[ "$out" == *"certificate has expired"* ]]; then
    note="证书已过期"
  elif [[ "$rc" != 0 && "$tls" == 0 ]]; then
    note="握手失败"
  fi
  [[ "$tls" == 1 && "$h2" == 0 ]] && note="无 HTTP/2"
  [[ "$tls" == 1 && "$kx" == 0 ]] && note="无 X25519"
  if [[ "$tls" == 1 && "$kx" == 1 && "$h2" == 1 && "$cert" == 1 ]]; then
    printf '%s\tPASS\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$ms" "$tls" "$kx" "$h2" "$certtxt" "$note"
  else
    printf '%s\tFAIL\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$ms" "$tls" "$kx" "$h2" "$certtxt" "$note"
  fi
}
sni_scan() {
  # 从标准输入读域名列表（每行一个），验证后按延迟排序；结果存入 SNI_ROWS，表格输出到 stdout
  local -a list=() chunk=() rows=() passed=() failed=() sorted=()
  local d f x line i=0 max dir cols
  SNI_ROWS=(); SNI_BEST=""
  max="$(optv parallel jobs)"; [[ "$max" =~ ^[0-9]+$ ]] && (( max >= 1 && max <= 32 )) || max=6
  while IFS= read -r d; do
    d="${d//$'\r'/}"
    d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
    [[ -n "$d" ]] || continue
    d="${d,,}"
    [[ "$d" == *://* ]] && d="${d#*://}"
    d="${d%%/*}"; d="${d%%\?*}"; d="${d%%#*}"; d="${d%.}"
    valid_domain "$d" || { echo "  跳过无效域名：$d" >&2; continue; }
    list+=("$d")
  done
  if (( ${#list[@]} == 0 )); then echo "没有可扫描的域名。" >&2; return 1; fi
  dir="$(mktemp -d 2>/dev/null || mktemp -d /tmp/sni-scan.XXXXXX)"
  echo "开始验证 ${#list[@]} 个域名（TLS 1.3 + X25519 + HTTP/2 + 证书），并发 $max：" >&2
  for d in "${list[@]}"; do
    chunk+=("$d")
    if (( ${#chunk[@]} >= max )); then
      for x in "${chunk[@]}"; do i=$((i + 1)); ( sni_probe "$x" >"$dir/$i.tsv" 2>/dev/null ) & done
      wait || true
      chunk=()
    fi
  done
  if (( ${#chunk[@]} )); then
    for x in "${chunk[@]}"; do i=$((i + 1)); ( sni_probe "$x" >"$dir/$i.tsv" 2>/dev/null ) & done
    wait || true
  fi
  for f in "$dir"/*.tsv; do
    [[ -s "$f" ]] || continue
    rows+=("$(head -n 1 "$f")")
  done
  rm -rf "$dir"
  if (( ${#rows[@]} == 0 )); then echo "没有拿到任何扫描结果。" >&2; return 1; fi
  for line in "${rows[@]}"; do
    if [[ "$(cut -f2 <<<"$line")" == PASS ]]; then passed+=("$line"); else failed+=("$line"); fi
  done
  if (( ${#passed[@]} )); then
    while IFS= read -r line; do sorted+=("$line"); done < <(printf '%s\n' "${passed[@]}" | sort -t$'\t' -k3,3n)
  fi
  printf '%-32s %-6s %-8s %-6s %-6s %-4s %s\n' "域名" "结果" "延迟" "TLS13" "X25519" "H2" "证书"
  local -a ordered=()
  ordered=("${sorted[@]}" "${failed[@]}")
  for line in "${ordered[@]}"; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r -a cols <<<"$line"
    printf '%-32s %-6s %-8s %-6s %-6s %-4s %s%s\n' \
      "${cols[0]}" "${cols[1]}" "${cols[2]}ms" \
      "$( (( ${cols[3]:-0} )) && echo '✓' || echo '✗')" \
      "$( (( ${cols[4]:-0} )) && echo '✓' || echo '✗')" \
      "$( (( ${cols[5]:-0} )) && echo '✓' || echo '✗')" \
      "${cols[6]:-}" "${cols[7]:+（${cols[7]}）}"
    SNI_ROWS+=("$line")
  done
  if (( ${#sorted[@]} )); then
    SNI_BEST="${sorted[0]%%$'\t'*}"
    echo
    echo "通过全部验证：${#sorted[@]} 个 / 共 ${#rows[@]} 个；最快：$SNI_BEST"
  else
    echo
    echo "没有域名通过全部验证（共试了 ${#rows[@]} 个）。可换一个分类/地区，或用 --sni 手动指定。"
  fi
  return 0
}
sni_save_cache() {
  have jq || return 0
  [[ -d "$DATA" ]] || return 0
  (( ${#SNI_ROWS[@]} )) || return 0
  local tmp
  tmp="$(mktemp "$DATA/.sni-scan.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n' "${SNI_ROWS[@]}" | jq -R -s --arg region "${SNI_REGION:-}" --arg at "$(date -Iseconds 2>/dev/null || date)" '
      [split("\n")[] | select(length > 0) | split("\t")
       | {domain: .[0], result: .[1], latency_ms: ((.[2] | tonumber?) // 0),
          tls13: ((.[3] // "0") == "1"), x25519: ((.[4] // "0") == "1"), h2: ((.[5] // "0") == "1"),
          cert: (.[6] // ""), note: (.[7] // "")}]
      | {scanned_at: $at, region: $region, results: .}' >"$tmp" 2>/dev/null; then
    chmod 600 "$tmp"
    mv -f "$tmp" "$SNI_CACHE"
  else
    rm -f "$tmp"
  fi
}
sni_collect() {
  # 按 --file / --list / --category / --region 生成候选列表（每行一个域名），输出到 stdout
  local cat file lst region
  cat="$(optv category cat)"; file="$(optv file list-file)"; lst="$(optv list domains)"
  if [[ -n "$file" ]]; then
    [[ -r "$file" ]] || die "列表文件不可读：$file"
    sed -E 's/[,;、， ]+/\n/g' "$file"
  elif [[ -n "$lst" ]]; then
    printf '%s\n' "$lst" | sed -E 's/[,;、， ]+/\n/g'
  elif [[ -n "$cat" ]]; then
    sni_cat "$cat" | tr ' ' '\n' || die "未知分类：$cat（可选：$(sni_categories)）"
  else
    region="$(optv region)"
    [[ -n "$region" && "${region,,}" != auto ]] || region="$(sni_detect_region)"
    SNI_REGION="${region^^}"
    if [[ -n "$SNI_REGION" ]]; then
      echo "本机出口地区：$SNI_REGION" >&2
    else
      echo "没能识别本机出口地区，改用通用候选列表。" >&2
    fi
    { sni_cat big-tech; sni_cat cdn; sni_cat dev; sni_region_extra "$SNI_REGION"; } | tr ' ' '\n'
  fi
}
sni_need_openssl() {
  have openssl || die "缺少 openssl，无法验证 TLS。先运行：$(self_cmd) install"
  openssl s_client -help 2>&1 | grep -q -- '-groups' || die "当前 openssl 不支持 -groups，无法检查 X25519；请升级 openssl（OpenSSL 1.1.1 及以上）"
}
sni_run() {
  # 先收集候选，再在当前 shell 里扫描（避免管道子 shell 丢掉 SNI_ROWS / SNI_BEST）
  local cands
  cands="$(sni_collect)" || return 1
  if [[ -z "${cands//[[:space:]]/}" ]]; then echo "没有可扫描的域名。" >&2; return 1; fi
  sni_scan <<<"$cands"
}
sni_select() {
  # 从 SNI_ROWS 里选一个候选（回车用最快的）；$1 若为变量名则写入该变量，否则输出到 stdout
  local __var="${1:-}" line d ans i=0
  local -a pass=()
  for line in "${SNI_ROWS[@]+"${SNI_ROWS[@]}"}"; do
    [[ "$(cut -f2 <<<"$line")" == PASS ]] && pass+=("$line")
  done
  if (( ${#pass[@]} == 0 )); then
    prompt d "手动输入 Reality SNI（直接回车用 www.bing.com）" "www.bing.com"
  else
    echo
    for line in "${pass[@]}"; do
      i=$((i + 1))
      printf '  %d) %-32s %sms\n' "$i" "${line%%$'\t'*}" "$(cut -f3 <<<"$line")"
    done
    read -r -p "选择序号（回车用 1，也可直接输入域名）: " ans || ans=""
    ans="${ans//[[:space:]]/}"
    if [[ -z "$ans" ]]; then
      d="${pass[0]%%$'\t'*}"
    elif [[ "$ans" =~ ^[0-9]+$ ]] && (( 10#$ans >= 1 && 10#$ans <= ${#pass[@]} )); then
      d="${pass[$((10#$ans - 1))]%%$'\t'*}"
    elif valid_domain "$ans"; then
      d="$ans"
    else
      d="${pass[0]%%$'\t'*}"
      echo "编号无效，使用最快的 $d" >&2
    fi
  fi
  if [[ -n "$__var" ]]; then printf -v "$__var" '%s' "$d"; else printf '%s' "$d"; fi
}
sni_interactive() {
  # 添加 Reality 时选择 SNI：手动输入，或按地区 / 分类 / 自定义列表扫描后挑一个
  # $1：目标变量名（写入选中的域名，避免在命令替换 $() 中误捕获菜单输出）
  local __var="${1:-}" c cat l d=""
  echo "Reality SNI / 握手域名（伪装目标，需要支持 TLS 1.3 + X25519 + HTTP/2 的有效证书）："
  echo "1) 手动输入（默认 www.bing.com）"
  echo "2) 按本机出口地区自动扫描"
  echo "3) 按分类扫描（big-tech / cdn / dev / media / ecom）"
  echo "4) 自定义域名列表扫描（逗号分隔或文件路径）"
  read -r -p "选择 [1-4，默认 1]: " c || c=1
  case "${c:-1}" in
    1)
      prompt d "Reality SNI/握手域名" "www.bing.com"
      if [[ -n "$__var" ]]; then printf -v "$__var" '%s' "$d"; else printf '%s' "$d"; fi
      return 0 ;;
    3)
      echo "分类：1) big-tech 2) cdn 3) dev 4) media 5) ecom 6) all"
      read -r -p "选择 [1-6，默认 1]: " cat || cat=1
      case "${cat:-1}" in
        1) cat=big-tech ;; 2) cat=cdn ;; 3) cat=dev ;; 4) cat=media ;; 5) cat=ecom ;; *) cat=all ;;
      esac
      OPTS[category]="$cat" ;;
    4)
      prompt l "域名列表（逗号或空格分隔，也可以输入文件路径）" ""
      if [[ -f "$l" ]]; then OPTS[file]="$l"; else OPTS[list]="$l"; fi ;;
  esac
  sni_need_openssl
  sni_run
  sni_save_cache
  sni_select "$__var"
}
sni_auto_pick() {
  # 非交互：扫描后自动返回最快的可用域名；表格输出到 stderr，便于调用方取返回值
  local best
  sni_need_openssl
  sni_run >&2 || true
  sni_save_cache
  best="$SNI_BEST"
  if [[ -z "$best" ]]; then
    die "SNI 扫描没有找到通过 TLS 1.3 / X25519 / HTTP/2 / 证书 验证的域名，请用 --sni 手动指定"
  fi
  echo "已自动选择 SNI：$best" >&2
  printf '%s' "$best"
}
cmd_scan_sni() {
  sni_need_openssl
  sni_run
  sni_save_cache
  if opt_bool auto; then
    [[ -n "$SNI_BEST" ]] || exit 1
    printf '%s\n' "$SNI_BEST"
  fi
  if opt_bool json; then
    [[ -f "$SNI_CACHE" ]] && { echo "（完整结果已保存到 $SNI_CACHE）"; }
  fi
}

# ---------- 添加节点 ----------
add_reality() {
  local tag port sni uuid keys priv pub sid obj host fps
  echo "本项会在本机创建 VLESS + Reality + Vision 服务端入站；本机地址、UUID、Reality 密钥和 short_id 用于新建节点，不会复用示例链接里的远端服务器凭据。"
  echo "客户端 URI 参数 packetEncoding=xudp 属于出站侧设置，不是本机入站字段；sing-box 客户端默认使用 xudp。"
  ask_tag tag reality
  ask_port port "TCP 端口" "$(free_port 443 tcp)" tcp
  sni="$(optv sni)"
  if [[ -z "$sni" ]]; then
    if (( NONINT )); then sni="www.bing.com"; else sni_interactive sni; fi
  elif [[ "$sni" == auto || "$sni" == scan ]]; then
    sni="$(sni_auto_pick)"
  fi
  sni="${sni#"${sni%%[![:space:]]*}"}"; sni="${sni%"${sni##*[![:space:]]}"}"
  sni="${sni#https://}"; sni="${sni#http://}"; sni="${sni%%/*}"; sni="${sni%%:*}"
  [[ -n "$sni" ]] || die "Reality SNI 不能为空"
  valid_domain "$sni" || die "Reality SNI 必须是域名（不要带 https:// 或路径）：$sni"
  choose_fps fps chrome reality
  host="$(public_host)"
  uuid="$(new_uuid)"
  keys="$("$SB" generate reality-keypair)"
  priv="$(awk '/PrivateKey:/ {print $2; exit}' <<<"$keys")"
  pub="$(awk '/PublicKey:/ {print $2; exit}' <<<"$keys")"
  [[ -n "$priv" && -n "$pub" ]] || die "无法解析 sing-box reality-keypair 输出"
  sid="$(random_hex 8)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" \
    '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$sid]}}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg uuid "$uuid" --arg host "$host" --argjson port "$port" --arg sni "$sni" --arg pub "$pub" --arg sid "$sid" --argjson fps "$(fps_json "$fps")" \
    '{protocol:"VLESS + Reality",tag:$tag,server:$host,port:$port,uuid:$uuid,flow:"xtls-rprx-vision",security:"reality",sni:$sni,public_key:$pub,short_id:$sid,fps:$fps}')"
  echo "防火墙：请在系统防火墙和云安全组放行 TCP $port。"
}
add_vmess() {
  local tag port uuid obj host
  echo "本项会创建标准 VMess AEAD（alterId=0）TCP 入站，不启用 TLS；服务器地址和 UUID 会生成 VMess 分享链接。"
  ask_tag tag vmess
  ask_port port "TCP 端口" "$(free_port 10086 tcp)" tcp
  host="$(public_host)"
  uuid="$(new_uuid)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    '{type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{name:$tag,uuid:$uuid,alterId:0}]}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg uuid "$uuid" \
    '{protocol:"VMess",tag:$tag,server:$host,port:$port,uuid:$uuid,alter_id:0,security:"auto",network:"tcp"}')"
  echo "防火墙：请在系统防火墙和云安全组放行 TCP $port。"
}
add_hy2() {
  local tag port password obj host
  ask_tag tag hy2
  ask_port port "UDP 端口" "$(free_port 8443 udp)" udp
  host="$(public_host)"
  setup_tls "$tag"
  password="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" --arg cert "$TLS_CERT" --arg key "$TLS_KEY" \
    '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg password "$password" --arg sni "$TLS_HOST" --argjson ins "$TLS_INS" \
    '{protocol:"Hysteria2",tag:$tag,server:$host,port:$port,password:$password,sni:$sni,insecure:$ins}')"
  echo "防火墙：请在系统防火墙和云安全组放行 UDP $port。"
}
add_tuic() {
  local tag port uuid password obj host
  ask_tag tag tuic
  ask_port port "UDP 端口" "$(free_port 9443 udp)" udp
  host="$(public_host)"
  setup_tls "$tag"
  uuid="$(new_uuid)"
  password="$(openssl rand -hex 24)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --arg cert "$TLS_CERT" --arg key "$TLS_KEY" \
    '{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$password}],congestion_control:"bbr",tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --arg sni "$TLS_HOST" --argjson ins "$TLS_INS" \
    '{protocol:"TUIC",tag:$tag,server:$host,port:$port,uuid:$uuid,password:$password,sni:$sni,insecure:$ins}')"
  echo "防火墙：请在系统防火墙和云安全组放行 UDP $port。"
}
add_anytls() {
  local tag port password obj host fps
  ask_tag tag anytls
  ask_port port "TCP 端口" "$(free_port 10443 tcp)" tcp
  host="$(public_host)"
  setup_tls "$tag"
  choose_fps fps chrome
  password="$(openssl rand -hex 24)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" --arg cert "$TLS_CERT" --arg key "$TLS_KEY" \
    '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg password "$password" --arg sni "$TLS_HOST" --argjson ins "$TLS_INS" --argjson fps "$(fps_json "$fps")" \
    '{protocol:"AnyTLS",tag:$tag,server:$host,port:$port,password:$password,sni:$sni,insecure:$ins,fps:$fps}')"
  echo "防火墙：请在系统防火墙和云安全组放行 TCP $port。"
}
add_ss() {
  local tag port password method obj host
  ask_tag tag ss
  ask_port port "TCP 端口" "$(free_port 11443 tcp)" tcp
  method="$(optv method)"
  if [[ -z "$method" ]]; then
    if (( NONINT )); then method="aes-128-gcm"; else prompt method "加密方式" "aes-128-gcm"; fi
  fi
  case "$method" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) ;; *) die "暂不接受该加密方式；请使用 aes-128-gcm、aes-256-gcm、chacha20-ietf-poly1305 或对应的 2022-blake3 方法" ;; esac
  host="$(public_host)"
  case "$method" in
    2022-blake3-aes-128-gcm) password="$(openssl rand -base64 16 | tr -d '\n')" ;;
    2022-blake3-aes-256-gcm) password="$(openssl rand -base64 32 | tr -d '\n')" ;;
    *) password="$(openssl rand -hex 24)" ;;
  esac
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" --arg password "$password" \
    '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$password}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg method "$method" --arg password "$password" \
    '{protocol:"Shadowsocks",tag:$tag,server:$host,port:$port,method:$method,password:$password}')"
  echo "防火墙：请在系统防火墙和云安全组放行 TCP $port。"
}
add_trojan() {
  local tag port password obj host
  echo "本项创建 Trojan 入站（TLS + 密码，TCP）；默认给每个节点生成独立的自签证书。"
  ask_tag tag trojan
  ask_port port "TCP 端口" "$(free_port 20443 tcp)" tcp
  host="$(public_host)"
  setup_tls "$tag"
  password="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg pw "$password" --arg cert "$TLS_CERT" --arg key "$TLS_KEY" \
    '{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user",password:$pw}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg pw "$password" --arg sni "$TLS_HOST" --argjson ins "$TLS_INS" \
    '{protocol:"Trojan",tag:$tag,server:$host,port:$port,password:$pw,sni:$sni,insecure:$ins}')"
  echo "防火墙：请在系统防火墙和云安全组放行 TCP $port。"
}

# ---------- Argo（Cloudflare Tunnel / cloudflared） ----------
argo_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7*|armhf|armv6*|armel) echo arm ;;
    i386|i486|i586|i686|x86) echo 386 ;;
    *) return 1 ;;
  esac
}
argo_names() {
  # 由节点名生成服务名和日志/Token 路径，结果写入全局变量
  ARGO_SERVICE="cloudflared-$1"
  ARGO_UNIT="/etc/systemd/system/${ARGO_SERVICE}.service"
  ARGO_INIT="/etc/init.d/${ARGO_SERVICE}"
  ARGO_LOG_FILE="/var/log/${ARGO_SERVICE}.log"
  ARGO_TOKEN_FILE="$ARGO_DIR/$1.token"
}
argo_install_core() {
  local arch url tmp
  if [[ -x "$ARGO_BIN" ]]; then
    "$ARGO_BIN" --version >/dev/null 2>&1 || die "$ARGO_BIN 已存在但无法运行；为保护现有文件未覆盖"
    echo "已检测到 cloudflared：$ARGO_BIN（$("$ARGO_BIN" --version 2>/dev/null | head -n1)）"
    return 0
  fi
  [[ ! -e "$ARGO_BIN" ]] || die "$ARGO_BIN 已存在但不是可执行文件；为保护现有文件未继续"
  arch="$(argo_arch)" || die "Cloudflare Tunnel 官方程序暂不支持此架构：$(uname -m)"
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  tmp="$(mktemp)"
  echo "正在下载 cloudflared（linux-${arch}）……"
  if ! curl -fL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$tmp"; then
    rm -f "$tmp"
    die "下载 cloudflared 失败：$url"
  fi
  chmod 700 "$tmp"
  if ! "$tmp" --version >/dev/null 2>&1; then
    rm -f "$tmp"
    die "下载的 cloudflared 无法在本机运行"
  fi
  install -m 755 "$tmp" "$ARGO_BIN"
  rm -f "$tmp"
  echo "已安装 $ARGO_BIN（$("$ARGO_BIN" --version | head -n1)）"
}
argo_write_service() {
  # $1 节点名；$2 quick / token；$3 本地端口
  local tag="$1" mode="$2" port="$3" args
  argo_names "$tag"
  if [[ "$mode" == token ]]; then
    args="tunnel --no-autoupdate --logfile ${ARGO_LOG_FILE} run --token-file ${ARGO_TOKEN_FILE}"
  else
    args="tunnel --no-autoupdate --logfile ${ARGO_LOG_FILE} --url http://127.0.0.1:${port}"
  fi
  if [[ "$INIT_SYS" == systemd ]]; then
    if [[ -e "$ARGO_UNIT" ]] && ! grep -qxF "$ARGO_MARK" "$ARGO_UNIT" 2>/dev/null; then
      die "$ARGO_UNIT 已存在且不属于本脚本；为保护现有服务未覆盖"
    fi
    cat >"$ARGO_UNIT" <<UNIT
[Unit]
Description=Cloudflare Tunnel for sing-box manager node ${tag}
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ARGO_BIN} ${args}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
${ARGO_MARK}
UNIT
    chmod 644 "$ARGO_UNIT"
    touch "$ARGO_LOG_FILE" 2>/dev/null || true
    chmod 600 "$ARGO_LOG_FILE" 2>/dev/null || true
    systemctl daemon-reload
  elif is_openrc; then
    if [[ -e "$ARGO_INIT" ]] && ! grep -qxF "$ARGO_MARK" "$ARGO_INIT" 2>/dev/null; then
      die "$ARGO_INIT 已存在且不属于本脚本；为保护现有服务未覆盖"
    fi
    cat >"$ARGO_INIT" <<RC
#!/sbin/openrc-run
${ARGO_MARK}
name="${ARGO_SERVICE}"
description="Cloudflare Tunnel for sing-box manager node ${tag}"
supervisor="supervise-daemon"
command="${ARGO_BIN}"
command_args="${args}"
respawn_delay=5
respawn_max=0
RC
    chmod 755 "$ARGO_INIT"
    touch "$ARGO_LOG_FILE" 2>/dev/null || true
    chmod 600 "$ARGO_LOG_FILE" 2>/dev/null || true
  else
    die "没有找到 systemd 或 OpenRC，无法把 Argo 隧道安装成服务"
  fi
}
argo_active() {
  if [[ "$INIT_SYS" == systemd ]]; then
    [[ "$(systemctl is-active "$ARGO_SERVICE" 2>/dev/null)" == active ]]
  else
    rc-service "$ARGO_SERVICE" status >/dev/null 2>&1
  fi
}
argo_active_wait() {
  local i
  for ((i = 0; i < 20; i++)); do
    argo_active && return 0
    sleep 0.5
  done
  return 1
}
argo_start() {
  local tag="$1"
  argo_names "$tag"
  if [[ "$INIT_SYS" == systemd ]]; then
    systemctl reset-failed "$ARGO_SERVICE" >/dev/null 2>&1 || true
    systemctl enable "$ARGO_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$ARGO_SERVICE"
  else
    rc-update add "$ARGO_SERVICE" default >/dev/null 2>&1 || true
    rc-service "$ARGO_SERVICE" restart >/dev/null 2>&1 || rc-service "$ARGO_SERVICE" start
  fi
}
argo_wait_host() {
  # 快速隧道：从 cloudflared 日志里读 trycloudflare 域名（最长约 60 秒）；$2 可指定日志路径
  local tag="$1" i host log
  argo_names "$tag"
  log="${2:-$ARGO_LOG_FILE}"
  for ((i = 0; i < 60; i++)); do
    host="$(grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$log" 2>/dev/null | head -n1)"
    if [[ -n "$host" ]]; then printf '%s' "${host#https://}"; return 0; fi
    sleep 1
  done
  return 1
}
argo_remove_service() {
  local tag="$1"
  argo_names "$tag"
  if [[ "$INIT_SYS" == systemd ]]; then
    systemctl disable --now "$ARGO_SERVICE" >/dev/null 2>&1 || true
    if [[ -f "$ARGO_UNIT" ]] && grep -qxF "$ARGO_MARK" "$ARGO_UNIT" 2>/dev/null; then rm -f "$ARGO_UNIT"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    rc-service "$ARGO_SERVICE" stop >/dev/null 2>&1 || true
    rc-update del "$ARGO_SERVICE" default >/dev/null 2>&1 || true
    if [[ -f "$ARGO_INIT" ]] && grep -qxF "$ARGO_MARK" "$ARGO_INIT" 2>/dev/null; then rm -f "$ARGO_INIT"; fi
  fi
  rm -f "$ARGO_TOKEN_FILE" "$ARGO_LOG_FILE"
}
argo_meta_set_host() {
  local tag="$1" host="$2" f="$ARGO_DIR/$1.json"
  jq --arg h "$host" '.host = $h' "$f" >"$f.tmp" && install -m 600 "$f.tmp" "$f"
  rm -f "$f.tmp"
}
add_argo() {
  local tag proto port path uuid host="" mode token domain choice obj label had_inbound=0
  need_jq
  argo_install_core
  ask_tag tag argo
  proto="$(optv proto protocol)"; proto="${proto:-vmess}"; proto="${proto,,}"
  case "$proto" in vmess|vless) ;; *) die "--proto 只能是 vmess 或 vless" ;; esac
  ask_port port "本机 WebSocket 端口（只监听 127.0.0.1）" "$(free_port 18080 tcp)" tcp
  path="$(optv path)"; [[ -n "$path" ]] || path="/argo-$(random_hex 6)"
  xray_valid_path "$path" || die "WebSocket 路径必须以 / 开头且不能包含空白字符"
  token="$(optv token)"
  domain="$(optv domain hostname tunnel-host)"
  if [[ -n "$token" ]]; then
    mode=token
    if [[ -z "$domain" ]]; then
      (( NONINT )) && die "命名隧道需要同时用 --domain 指定 Cloudflare 里已映射到本机端口的域名"
      prompt domain "命名隧道的公网域名（Cloudflare 后台已映射到本机端口）" ""
    fi
  elif opt_bool quick || (( NONINT )); then
    mode=quick
  else
    echo "隧道方式："
    echo "1) 快速隧道（trycloudflare.com 临时域名，无需 Cloudflare 账号；域名会随重启变化）"
    echo "2) 命名隧道（Cloudflare 账号里的 Tunnel Token + 已映射的域名，适合长期使用）"
    read -r -p "选择 [1-2，默认 1]: " choice || choice=1
    if [[ "${choice:-1}" == 2 ]]; then
      mode=token
      prompt token "Tunnel Token（Cloudflare Zero Trust → Networks → Tunnels 里复制）" ""
      [[ -n "$token" ]] || die "Token 不能为空"
      prompt domain "命名隧道的公网域名（已映射到本机 127.0.0.1:$port）" ""
    fi
  fi
  if [[ "$mode" == token ]]; then
    valid_domain "$domain" || die "Argo 域名无效：$domain"
    echo "提醒：请在 Cloudflare 的隧道配置里把这个域名的 Public Hostname 指向 http://127.0.0.1:$port（路径 $path）。"
    host="$domain"
  fi
  uuid="$(new_uuid)"
  if [[ "$proto" == vmess ]]; then
    obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
      '{type:"vmess",tag:$tag,listen:"127.0.0.1",listen_port:$port,users:[{name:$tag,uuid:$uuid,alterId:0}],transport:{type:"ws",path:$path}}')"
    label="VMess + WS (Argo)"
  else
    obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
      '{type:"vless",tag:$tag,listen:"127.0.0.1",listen_port:$port,users:[{name:$tag,uuid:$uuid}],transport:{type:"ws",path:$path}}')"
    label="VLESS + WS (Argo)"
  fi
  mkdir -p "$ARGO_DIR"
  argo_names "$tag"
  [[ ! -e "$ARGO_DIR/$tag.json" ]] || die "已经有一个叫 $tag 的 Argo 节点"
  apply_json "$obj"
  had_inbound=1
  if [[ "$mode" == token ]]; then
    printf '%s\n' "$token" >"$ARGO_TOKEN_FILE"
    chmod 600 "$ARGO_TOKEN_FILE"
  fi
  jq -n --arg tag "$tag" --arg proto "$proto" --argjson port "$port" --arg path "$path" --arg mode "$mode" --arg host "${domain:-}" \
    '{tag:$tag,proto:$proto,local_port:$port,path:$path,mode:$mode,host:$host}' >"$ARGO_DIR/$tag.json"
  chmod 600 "$ARGO_DIR/$tag.json"
  argo_write_service "$tag" "$mode" "$port"
  if ! argo_start "$tag" || ! argo_active_wait; then
    argo_remove_service "$tag"
    rm -f "$ARGO_DIR/$tag.json" "$DATA/$tag.json"
    if (( had_inbound )) && jq -e --arg t "$tag" '[.inbounds[]? | select(.tag == $t)] | length > 0' "$CONF" >/dev/null 2>&1; then
      ( remove_by_tag "$tag" >/dev/null 2>&1 ) || true
    fi
    die "cloudflared 服务没能启动；已回滚本次添加的 Argo 节点。查看日志：tail -n 50 ${ARGO_LOG_FILE}"
  fi
  if [[ "$mode" == quick ]]; then
    echo "等待 Cloudflare 分配临时域名（最长约 60 秒）……"
    if ! host="$(argo_wait_host "$tag")"; then
      argo_remove_service "$tag"
      rm -f "$ARGO_DIR/$tag.json" "$DATA/$tag.json"
      if jq -e --arg t "$tag" '[.inbounds[]? | select(.tag == $t)] | length > 0' "$CONF" >/dev/null 2>&1; then
        ( remove_by_tag "$tag" >/dev/null 2>&1 ) || true
      fi
      die "没有从 cloudflared 日志里读到 trycloudflare 域名；已回滚。日志：tail -n 50 ${ARGO_LOG_FILE}"
    fi
    argo_meta_set_host "$tag" "$host"
  fi
  save_node "$tag" "$(jq -n --arg proto "$label" --arg tag "$tag" --arg host "$host" --arg path "$path" --arg uuid "$uuid" --arg mode "$mode" \
    '{protocol:$proto,tag:$tag,server:$host,port:443,ws_host:$host,path:$path,uuid:$uuid,tls:"tls",insecure:false,argo_mode:$mode}')"
  echo "Argo 节点已添加：$tag（$label，$mode）→ https://$host$path → 本机 127.0.0.1:$port"
  if [[ "$mode" == quick ]]; then
    echo "注意：快速隧道的域名不保证可用性，cloudflared 重启后会变。变了以后运行：$(self_cmd) argo url $tag"
  fi
  if [[ "$INIT_SYS" == systemd ]]; then
    echo "服务名：${ARGO_SERVICE}（systemctl status ${ARGO_SERVICE}）"
  else
    echo "服务名：${ARGO_SERVICE}（rc-service ${ARGO_SERVICE} status）"
  fi
}
argo_list() {
  local f any=0
  shopt -s nullglob
  local files=("$ARGO_DIR"/*.json)
  shopt -u nullglob
  ((${#files[@]})) || { echo "还没有 Argo 节点。"; return 0; }
  for f in "${files[@]}"; do
    any=1
    echo "===== $(jq -r .tag "$f") ====="
    echo "方式：$(jq -r .mode "$f")　域名：$(jq -r .host "$f")　本机端口：$(jq -r .local_port "$f")　路径：$(jq -r .path "$f")"
    if [[ -f "$DATA/$(jq -r .tag "$f").json" ]]; then print_link "$DATA/$(jq -r .tag "$f").json"; fi
    echo
  done
  ((any)) || true
}
argo_refresh() {
  local tag="${1:-}" host f
  if [[ -z "$tag" ]]; then argo_list; prompt tag "要刷新域名的 Argo 节点名称" ""; fi
  [[ -n "$tag" ]] || die "名称不能为空"
  valid_tag "$tag"
  f="$ARGO_DIR/$tag.json"
  [[ -f "$f" ]] || die "没有名为 $tag 的 Argo 节点"
  if [[ "$(jq -r .mode "$f")" != quick ]]; then
    echo "$tag 是命名隧道，域名固定为 $(jq -r .host "$f")，不用刷新。"
    return 0
  fi
  argo_start "$tag" >/dev/null 2>&1 || true
  if ! host="$(argo_wait_host "$tag")"; then
    argo_names "$tag"
    die "没有从日志里读到新的 trycloudflare 域名；查看：tail -n 50 ${ARGO_LOG_FILE}"
  fi
  argo_meta_set_host "$tag" "$host"
  if [[ -f "$DATA/$tag.json" ]]; then
    jq --arg h "$host" '.server = $h | .ws_host = $h' "$DATA/$tag.json" >"$DATA/$tag.json.tmp" && install -m 600 "$DATA/$tag.json.tmp" "$DATA/$tag.json"
    rm -f "$DATA/$tag.json.tmp"
  fi
  echo "新的 Argo 域名：$host"
  if [[ -f "$DATA/$tag.json" ]]; then print_link "$DATA/$tag.json"; fi
}
argo_log() {
  local tag="${1:-}" n="${2:-100}"
  if [[ -z "$tag" ]]; then argo_list; prompt tag "Argo 节点名称" ""; fi
  [[ -n "$tag" ]] || die "名称不能为空"
  valid_tag "$tag"
  argo_names "$tag"
  [[ "$n" =~ ^[0-9]+$ ]] || n=100
  if [[ -s "$ARGO_LOG_FILE" ]]; then tail -n "$n" "$ARGO_LOG_FILE"; else echo "暂无日志（$ARGO_LOG_FILE）"; fi
}
argo_remove() {
  local tag="${1:-}"
  if [[ -z "$tag" ]]; then argo_list; prompt tag "要删除的 Argo 节点名称" ""; fi
  [[ -n "$tag" ]] || die "名称不能为空"
  valid_tag "$tag"
  [[ -f "$ARGO_DIR/$tag.json" ]] || die "没有名为 $tag 的 Argo 节点"
  remove_by_tag "$tag"
}
cmd_argo() {
  case "${1:-add}" in
    add|node) prepare_manage; add_argo ;;
    list|ls) argo_list ;;
    url|refresh) argo_refresh "${2:-}" ;;
    log|logs) argo_log "${2:-}" "${3:-100}" ;;
    remove|del|rm) prepare_manage; argo_remove "${2:-}" ;;
    *) usage; exit 2 ;;
  esac
}

# ---------- Telegram 机器人 ----------
tg_conf_path() { printf '%s' "$DATA/tgbot.conf"; }
tg_valid_token() { [[ "$1" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{20,}$ ]]; }
tg_valid_chat() { [[ "$1" =~ ^-?[0-9]+$ ]] || [[ "$1" =~ ^@[A-Za-z0-9_]{4,}$ ]]; }
tg_load() {
  # 只读取本脚本写入的三个键，不 source 配置文件
  local f k v
  TG_BOT_TOKEN=""; TG_CHAT_ID=""; TG_AUTO_PUSH=0
  f="$(tg_conf_path)"
  [[ -f "$f" && -r "$f" ]] || return 1
  while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
    case "${k:-}" in
      TG_BOT_TOKEN) TG_BOT_TOKEN="${v:-}" ;;
      TG_CHAT_ID) TG_CHAT_ID="${v:-}" ;;
      TG_AUTO_PUSH) TG_AUTO_PUSH="${v:-0}" ;;
    esac
  done <"$f"
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]
}
tg_conf_write() {
  local f tmp
  mkdir -p "$DATA"
  f="$(tg_conf_path)"
  tmp="$(mktemp "$DATA/.tgbot.conf.XXXXXX")" || die "无法写入 Telegram 机器人配置"
  printf 'TG_BOT_TOKEN=%s\nTG_CHAT_ID=%s\nTG_AUTO_PUSH=%s\n' "$TG_BOT_TOKEN" "$TG_CHAT_ID" "${TG_AUTO_PUSH:-0}" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}
tg_api_json() {
  # $1 方法名；$2 JSON body（可空）；$3 超时秒数。Token 和内容都放在 600 权限的 curl 配置里，不出现在进程参数里
  local method="$1" body="${2:-}" tout="${3:-40}" cfg bf out rc=0
  [[ -n "$TG_BOT_TOKEN" ]] || die "还没有配置 Telegram Bot Token（运行 $(self_cmd) tg config）"
  cfg="$(mktemp)" || die "无法创建临时文件"
  chmod 600 "$cfg"
  printf 'url = "%s/bot%s/%s"\n' "$TG_API" "$TG_BOT_TOKEN" "$method" >"$cfg"
  if [[ -n "$body" ]]; then
    bf="$(mktemp)" || die "无法创建临时文件"
    chmod 600 "$bf"
    printf '%s' "$body" >"$bf"
    printf 'header = "Content-Type: application/json"\ndata-binary = "@%s"\n' "$bf" >>"$cfg"
  fi
  out="$(curl -sS --max-time "$tout" --config "$cfg" 2>&1)" || rc=$?
  rm -f "$cfg"
  [[ -z "${bf:-}" ]] || rm -f "$bf"
  if (( rc != 0 )); then
    printf '{"ok":false,"error":"curl %s: %s"}' "$rc" "${out//\"/\'}"
    return 1
  fi
  printf '%s' "$out"
}
tg_send_document() {
  # $1 chat；$2 内容；$3 文件名
  local chat="$1" content="$2" name="${3:-singbox-nodes.txt}" f cfg rc=0
  [[ -n "$TG_BOT_TOKEN" ]] || return 1
  f="$(mktemp)" || return 1
  chmod 600 "$f"
  printf '%s\n' "$content" >"$f"
  cfg="$(mktemp)" || { rm -f "$f"; return 1; }
  chmod 600 "$cfg"
  printf 'url = "%s/bot%s/sendDocument"\n' "$TG_API" "$TG_BOT_TOKEN" >"$cfg"
  curl -fsS --max-time 90 --config "$cfg" \
    -F "chat_id=${chat}" -F "document=@${f};filename=${name}" \
    -F "caption=singbox-manager 节点信息" >/dev/null 2>&1 || rc=$?
  rm -f "$f" "$cfg"
  (( rc == 0 )) || { echo "Telegram 文件发送失败" >&2; return 1; }
}
tg_send_message() {
  # $1 chat；$2 文本。超过 3800 字符分段，超过 12000 字符改发 txt 文件
  local chat="$1" text="$2" max=3800 rest piece resp
  [[ -n "$text" ]] || return 0
  if (( ${#text} > 12000 )); then tg_send_document "$chat" "$text"; return $?; fi
  rest="$text"
  while [[ -n "$rest" ]]; do
    piece="${rest:0:max}"
    rest="${rest:max}"
    resp="$(tg_api_json sendMessage "$(jq -n --arg c "$chat" --arg t "$piece" '{chat_id:(($c|tonumber?) // $c), text:$t, disable_web_page_preview:true}')" 20 || true)"
    if ! jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
      echo "Telegram 发送失败：${resp:0:200}" >&2
      return 1
    fi
  done
  return 0
}
tg_authorized() {
  local chat="$1" x
  local -a list=()
  IFS=',' read -r -a list <<<"$TG_CHAT_ID"
  for x in "${list[@]}"; do
    x="${x//[[:space:]]/}"
    [[ -n "$x" && "$x" == "$chat" ]] && return 0
  done
  return 1
}
tg_collect_links() {
  # $1 可选节点名；输出全部或该节点的分享链接
  local tag="${1:-}" f out found=0
  local -a files=()
  if [[ -n "$tag" ]]; then
    valid_tag "$tag"
    if [[ -f "$XRAY_DATA/$tag.json" ]]; then f="$XRAY_DATA/$tag.json"
    elif [[ -f "$DATA/$tag.json" ]]; then f="$DATA/$tag.json"
    else die "没有名为 $tag 的节点"; fi
    print_link "$f" | grep -E '^(vless|vmess|hysteria2|hy2|tuic|anytls|ss|trojan)://' || true
    return 0
  fi
  shopt -s nullglob
  files=("$DATA"/*.json "$XRAY_DATA"/*.json)
  shopt -u nullglob
  (( ${#files[@]} )) || { echo "还没有节点。"; return 0; }
  for f in "${files[@]}"; do
    jq -e '.protocol and .tag' "$f" >/dev/null 2>&1 || continue
    out="$(print_link "$f" | grep -E '^(vless|vmess|hysteria2|hy2|tuic|anytls|ss|trojan)://' || true)"
    [[ -n "$out" ]] || continue
    found=1
    printf '===== %s =====\n%s\n' "$(jq -r '.tag' "$f")" "$out"
  done
  (( found )) || echo "还没有可推送的分享链接。"
  return 0
}
tg_maybe_autopush() {
  # 新节点创建后，按配置自动推送该节点链接（失败不影响节点添加）；--tg-push 可临时强制推送一次
  local tag="$1" content force=0
  [[ -z "${TG_SUPPRESS_AUTOPUSH:-}" ]] || return 0
  opt_bool tg-push && force=1
  if ! tg_load >/dev/null 2>&1; then
    (( force )) && echo "提示：--tg-push 需要先配置机器人（$(self_cmd) tg config）。" >&2
    return 0
  fi
  [[ "${TG_AUTO_PUSH:-0}" == 1 || "$force" == 1 ]] || return 0
  content="$(tg_collect_links "$tag" 2>/dev/null || true)"
  [[ -n "${content//[[:space:]]/}" ]] || return 0
  if tg_send_message "$TG_CHAT_ID" "新节点：$tag
$content" >/dev/null 2>&1; then
    echo "已把 $tag 的分享链接推送到了 Telegram。"
  else
    echo "提示：推送失败，可用 $(self_cmd) tg test 检查配置。" >&2
  fi
  return 0
}
tg_push() {
  local tag="${1:-}" content
  need_jq
  tg_load || die "还没有配置 Telegram 机器人（运行 $(self_cmd) tg config --token ... --chat-id ...）"
  content="$(tg_collect_links "$tag")" || exit 1
  [[ -n "${content//[[:space:]]/}" ]] || die "没有可推送的分享链接"
  tg_send_message "$TG_CHAT_ID" "【$(hostname 2>/dev/null || echo sing-box)】节点分享链接
$content" || die "推送失败：请确认 chat_id 正确，且已先给机器人发过 /start"
  echo "已推送到 Telegram（chat_id=$TG_CHAT_ID）。"
}
tg_test() {
  local me
  if [[ -n "$(optv token)$(optv chat-id tg-chat chat)" ]]; then tg_config; fi
  tg_load || die "还没有配置 Telegram 机器人（运行 $(self_cmd) tg config）"
  me="$(tg_api_json getMe "" 20 || true)"
  if ! jq -e '.ok == true' <<<"$me" >/dev/null 2>&1; then
    die "Token 无效或网络不通：${me:0:200}"
  fi
  echo "机器人：@$(jq -r '.result.username // "?"' <<<"$me")（$(jq -r '.result.first_name // "?"' <<<"$me")）"
  tg_send_message "$TG_CHAT_ID" "singbox-manager 测试消息：机器人已连通。
服务器：$(hostname 2>/dev/null || echo '?')
时间：$(date '+%F %T')" || die "消息发送失败：请确认 chat_id 正确，且已先给机器人发过一条消息（/start）"
  echo "测试消息已发送到 chat_id=$TG_CHAT_ID。"
}
tg_config() {
  local token chat auto t
  token="$(optv token)"; chat="$(optv chat-id tg-chat chat)"; auto="$(optv auto-push)"
  tg_load >/dev/null 2>&1 || true
  if [[ -z "$token$chat$auto" ]]; then
    echo "Telegram 机器人配置（文件：$(tg_conf_path)，权限 600）"
    if [[ -n "$TG_BOT_TOKEN" ]]; then echo "当前 Token：${TG_BOT_TOKEN%%:*}:***（已配置）"; else echo "当前 Token：未配置"; fi
    echo "当前 chat_id：${TG_CHAT_ID:-未配置}"
    echo "自动推送：$(if [[ "${TG_AUTO_PUSH:-0}" == 1 ]]; then echo 开; else echo 关; fi)"
    echo "先给机器人发一条 /start，再运行 $(self_cmd) tg id 就能看到 chat_id。"
    read -r -p "Bot Token（回车保持当前）: " t || t=""
    token="${t:-$TG_BOT_TOKEN}"
    read -r -p "允许的 chat_id / user_id（回车保持当前 ${TG_CHAT_ID:-空}）: " t || t=""
    chat="${t:-$TG_CHAT_ID}"
    read -r -p "新节点创建后自动推送分享链接？[y/N]（回车保持当前）: " t || t=""
    case "${t,,}" in
      y|yes|1) auto=1 ;;
      n|no|0) auto=0 ;;
      *) auto="${TG_AUTO_PUSH:-0}" ;;
    esac
  fi
  token="${token:-$TG_BOT_TOKEN}"; chat="${chat:-$TG_CHAT_ID}"; auto="${auto:-${TG_AUTO_PUSH:-0}}"
  [[ -n "$token" ]] || die "Bot Token 不能为空"
  tg_valid_token "$token" || die "Token 格式不对（应形如 123456789:AAF...；请确认是从 @BotFather 复制完整 Token）"
  [[ -n "$chat" ]] || die "chat_id 不能为空"
  tg_valid_chat "$chat" || die "chat_id 只能是数字（可带负号）或 @频道名"
  case "${auto,,}" in 1|y|yes|on|true) auto=1 ;; *) auto=0 ;; esac
  TG_BOT_TOKEN="$token"; TG_CHAT_ID="$chat"; TG_AUTO_PUSH="$auto"
  tg_conf_write
  echo "已保存：$(tg_conf_path)（权限 600）"
  echo "运行 $(self_cmd) tg test 验证；需要机器人常驻请运行 $(self_cmd) tg enable"
}
tg_script_path() {
  local path
  path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  [[ -f "$path" && "$path" != /dev/fd/* && "$path" != /proc/* ]] || die "机器人服务需要从一个已保存的脚本文件启动"
  [[ ! "$path" =~ [[:space:]\"\\] ]] || die "脚本路径含空格或特殊字符，不能安全写入服务配置：$path"
  printf '%s' "$path"
}
tg_service_install() {
  local path
  tg_load >/dev/null 2>&1 || die "先配置机器人的 Token 和 chat_id：$(self_cmd) tg config"
  need_init
  path="$(tg_script_path)"
  if [[ "$INIT_SYS" == systemd ]]; then
    if [[ -e "$TG_UNIT" ]] && ! grep -qxF "$TG_MARK" "$TG_UNIT" 2>/dev/null; then
      die "$TG_UNIT 已存在且不属于本脚本；为保护现有服务未覆盖"
    fi
    cat >"$TG_UNIT" <<UNIT
[Unit]
Description=sing-box manager Telegram bot
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${path} tg poll
Restart=always
RestartSec=5
User=root
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
${TG_MARK}
UNIT
    chmod 644 "$TG_UNIT"
    systemctl daemon-reload
  elif is_openrc; then
    if [[ -e "$TG_INIT" ]] && ! grep -qxF "$TG_MARK" "$TG_INIT" 2>/dev/null; then
      die "$TG_INIT 已存在且不属于本脚本；为保护现有服务未覆盖"
    fi
    cat >"$TG_INIT" <<RC
#!/sbin/openrc-run
${TG_MARK}
name="${TG_SERVICE}"
description="sing-box manager Telegram bot"
supervisor="supervise-daemon"
command="/bin/bash"
command_args="${path} tg poll"
output_log="${TG_LOG}"
error_log="${TG_LOG}"
respawn_delay=5
respawn_max=0
RC
    chmod 755 "$TG_INIT"
    touch "$TG_LOG"
    chmod 600 "$TG_LOG"
  else
    die "没有找到 systemd 或 OpenRC，无法把机器人安装成服务"
  fi
}
tg_log_hint() { if is_openrc; then echo "tail -n 100 $TG_LOG"; else echo "journalctl -u $TG_SERVICE -n 100 --no-pager"; fi; }
tg_service_start() {
  tg_service_install
  if [[ "$INIT_SYS" == systemd ]]; then
    systemctl reset-failed "$TG_SERVICE" >/dev/null 2>&1 || true
    systemctl enable "$TG_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$TG_SERVICE" >/dev/null 2>&1 || true
    sleep 1
    if [[ "$(systemctl is-active "$TG_SERVICE" 2>/dev/null)" != active ]]; then
      die "机器人服务没能启动；查看：$(tg_log_hint)"
    fi
  else
    rc-update add "$TG_SERVICE" default >/dev/null 2>&1 || true
    rc-service "$TG_SERVICE" restart >/dev/null 2>&1 || rc-service "$TG_SERVICE" start >/dev/null 2>&1 || true
    sleep 1
    rc-service "$TG_SERVICE" status >/dev/null 2>&1 || die "机器人服务没能启动；查看：$(tg_log_hint)"
  fi
  echo "Telegram 机器人已启动（$TG_SERVICE），并已设为开机自启。发 /help 试试。"
}
tg_service_stop() {
  if [[ "$INIT_SYS" == systemd ]]; then
    systemctl stop "$TG_SERVICE" >/dev/null 2>&1 || true
  else
    rc-service "$TG_SERVICE" stop >/dev/null 2>&1 || true
  fi
  echo "已停止 $TG_SERVICE（节点服务不受影响）。"
}
tg_service_disable() {
  tg_service_stop >/dev/null 2>&1 || true
  if [[ "$INIT_SYS" == systemd ]]; then
    systemctl disable "$TG_SERVICE" >/dev/null 2>&1 || true
    if [[ -f "$TG_UNIT" ]] && grep -qxF "$TG_MARK" "$TG_UNIT" 2>/dev/null; then rm -f "$TG_UNIT"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo "已停用机器人并移除 $TG_UNIT。"
  else
    rc-update del "$TG_SERVICE" default >/dev/null 2>&1 || true
    if [[ -f "$TG_INIT" ]] && grep -qxF "$TG_MARK" "$TG_INIT" 2>/dev/null; then rm -f "$TG_INIT"; fi
    echo "已停用机器人并移除 $TG_INIT。"
  fi
}
tg_service_status() {
  if tg_load; then
    echo "机器人配置：$(tg_conf_path)"
    echo "  Token：${TG_BOT_TOKEN%%:*}:***（已配置）"
    echo "  chat_id：$TG_CHAT_ID"
    echo "  自动推送：$(if [[ "${TG_AUTO_PUSH:-0}" == 1 ]]; then echo 开; else echo 关; fi)"
  else
    echo "机器人配置：未配置（运行 $(self_cmd) tg config）"
  fi
  echo "=== 服务状态（${INIT_SYS}） ==="
  if [[ "$INIT_SYS" == systemd ]]; then
    systemctl --no-pager --full status "$TG_SERVICE" 2>/dev/null | head -n 12 || echo "未安装服务（运行 $(self_cmd) tg enable）"
  else
    rc-service "$TG_SERVICE" status 2>/dev/null || echo "未安装服务（运行 $(self_cmd) tg enable）"
  fi
}
tg_service_logs() {
  local n="${1:-100}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=100
  if is_openrc; then
    if [[ -s "$TG_LOG" ]]; then tail -n "$n" "$TG_LOG"; else echo "暂无日志（$TG_LOG）"; fi
  else
    journalctl -u "$TG_SERVICE" -n "$n" --no-pager 2>/dev/null || echo "暂无日志"
  fi
}
tg_help_text() {
  cat <<'TXT'
singbox-manager 机器人命令：
/status          服务状态和监听端口
/list            节点列表
/links [名称]    全部（或指定节点）的分享链接
/push [名称]     同 /links
/add <协议> [--port 8443 --sni auto ...]  新建节点（非交互）
/del 名称        删除节点
/scan [JP|dev]   Reality SNI 扫描
/argo list       Argo 隧道节点
/id              当前 chat_id
/ping            测试连通
/help            本帮助
TXT
}
tg_add_node() {
  # $1 协议；其余为 --选项
  local proto="${1:-}"
  [[ -n "$proto" ]] || die "用法：/add reality|hy2|tuic|anytls|trojan|ss|vmess|argo [--选项]"
  shift
  (
    TG_SUPPRESS_AUTOPUSH=1
    parse_opts "$@"
    NONINT=1
    prepare_manage >&2
    case "${proto,,}" in
      reality|vless) add_reality ;;
      hy2|hysteria2) add_hy2 ;;
      tuic) add_tuic ;;
      anytls) add_anytls ;;
      trojan) add_trojan ;;
      ss|shadowsocks) add_ss ;;
      vmess) add_vmess ;;
      argo) add_argo ;;
      *) die "不支持的协议：$proto" ;;
    esac
  )
}
tg_del_node() {
  local tag="${1:-}"
  [[ -n "$tag" ]] || die "用法：/del 节点名"
  ( NONINT=1; prepare_manage >&2; remove_by_tag "$tag" )
}
tg_scan() {
  local a1="${1:-}"
  case "${a1,,}" in
    "") ( NONINT=1; cmd_scan_sni ) ;;
    big-tech|bigtech|cdn|cnd|dev|media|ecom|all) ( NONINT=1; OPTS[category]="$a1"; cmd_scan_sni ) ;;
    [a-zA-Z][a-zA-Z]) ( NONINT=1; OPTS[region]="${a1^^}"; cmd_scan_sni ) ;;
    *) die "用法：/scan [地区代码，如 JP] 或 [分类：big-tech/cdn/dev/media/ecom/all]" ;;
  esac
}
tg_argo_cmd() {
  case "${1:-list}" in
    list|"") argo_list ;;
    url|refresh) argo_refresh "${2:-}" ;;
    add) shift; tg_add_node argo "$@" ;;
    *) die "用法：/argo [list | url 节点名 | add --proto vmess --quick]" ;;
  esac
}
tg_handle_update() {
  local upd="$1" chat text first cmd args out
  chat="$(jq -r '.message.chat.id // empty' <<<"$upd" 2>/dev/null || true)"
  [[ -n "$chat" ]] || return 0
  text="$(jq -r '.message.text // empty' <<<"$upd" 2>/dev/null || true)"
  if [[ -z "$text" ]]; then
    tg_send_message "$chat" "暂时只支持文字命令，发 /help 查看可用命令。" || true
    return 0
  fi
  if ! tg_authorized "$chat"; then
    tg_send_message "$chat" "未授权的 chat_id：$chat
请把该 id 写进 $(tg_conf_path) 的 TG_CHAT_ID，或在服务器上运行 $(self_cmd) tg config。" || true
    return 0
  fi
  first="${text%%[[:space:]]*}"
  cmd="${first%%@*}"
  if [[ "$text" == *[[:space:]]* ]]; then args="${text#*[[:space:]]}"; else args=""; fi
  case "${cmd,,}" in
    /start|/help) tg_send_message "$chat" "$(tg_help_text)" || true ;;
    /id) tg_send_message "$chat" "chat_id：$chat" || true ;;
    /ping) tg_send_message "$chat" "pong（$(date '+%F %T')）" || true ;;
    /status)
      if out="$(prepare_manage >&2; status 2>&1)"; then tg_send_message "$chat" "$out" || true
      else tg_send_message "$chat" "执行失败：
$out" || true; fi ;;
    /list)
      if out="$(prepare_manage >&2; list_nodes 2>&1)"; then tg_send_message "$chat" "$out" || true
      else tg_send_message "$chat" "执行失败：
$out" || true; fi ;;
    /links|/push|/nodes)
      if out="$(tg_collect_links "$args" 2>&1)"; then
        [[ -n "${out//[[:space:]]/}" ]] || out="没有可推送的分享链接。"
        tg_send_message "$chat" "$out" || true
      else
        tg_send_message "$chat" "执行失败：
$out" || true
      fi ;;
    /add)
      if out="$(tg_add_node "$args" 2>&1)"; then tg_send_message "$chat" "${out:-已完成}" || true
      else tg_send_message "$chat" "新建节点失败：
$out" || true; fi ;;
    /del)
      if out="$(tg_del_node "$args" 2>&1)"; then tg_send_message "$chat" "${out:-已完成}" || true
      else tg_send_message "$chat" "删除失败：
$out" || true; fi ;;
    /scan)
      if out="$(tg_scan "$args" 2>&1)"; then tg_send_message "$chat" "${out:-没有结果}" || true
      else tg_send_message "$chat" "扫描失败：
$out" || true; fi ;;
    /argo)
      if out="$(tg_argo_cmd "$args" 2>&1)"; then tg_send_message "$chat" "${out:-已完成}" || true
      else tg_send_message "$chat" "执行失败：
$out" || true; fi ;;
    *) tg_send_message "$chat" "不认识的命令：$cmd
$(tg_help_text)" || true ;;
  esac
  return 0
}
tg_lock_release() {
  local lock="$DATA/.tgbot.lock" pid
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  [[ "$pid" == "$$" ]] || return 0
  rm -f "$lock/pid"
  rmdir "$lock" 2>/dev/null || true
}
tg_lock_acquire() {
  local lock="$DATA/.tgbot.lock" pid
  mkdir -p "$DATA"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/pid"
    trap 'tg_lock_release' EXIT
    trap 'exit 0' INT TERM
    return 0
  fi
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    die "Telegram 机器人已经有一个实例在运行（PID $pid）；如需重启：$(self_cmd) tg start"
  fi
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null && printf '%s\n' "$$" >"$lock/pid" || die "无法取得机器人运行锁：$lock"
  trap 'tg_lock_release' EXIT
  trap 'exit 0' INT TERM
}
tg_bot_loop() {
  need_jq
  tg_load || die "还没有配置 Telegram 机器人（运行 $(self_cmd) tg config）"
  tg_lock_acquire
  local offset resp upd update_id
  offset="$(cat "$DATA/tgbot.offset" 2>/dev/null || true)"
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  echo "Telegram 机器人已启动：chat_id=$TG_CHAT_ID，offset=$offset"
  while true; do
    resp="$(tg_api_json getUpdates "$(jq -n --argjson o "$offset" '{offset:$o,timeout:50,allowed_updates:["message"]}')" 70 2>/dev/null || true)"
    if [[ -n "$resp" ]] && jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
      while IFS= read -r upd; do
        [[ -n "$upd" ]] || continue
        update_id="$(jq -r '.update_id // empty' <<<"$upd" 2>/dev/null || true)"
        [[ "$update_id" =~ ^[0-9]+$ ]] || continue
        offset=$((update_id + 1))
        printf '%s' "$offset" >"$DATA/tgbot.offset" 2>/dev/null || true
        tg_handle_update "$upd" || true
      done < <(jq -c '.result[]?' <<<"$resp" 2>/dev/null)
    else
      sleep 3
    fi
  done
}
tg_id_help() {
  tg_load >/dev/null 2>&1 || true
  [[ -n "$TG_BOT_TOKEN" ]] || die "还没有配置机器人 Token（运行 $(self_cmd) tg config）"
  echo "给机器人发一条消息后，用下面的接口读取最近的会话 id："
  local resp
  resp="$(tg_api_json getUpdates "$(jq -n '{timeout:0,allowed_updates:["message"]}')" 20 || true)"
  if jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
    jq -r '.result[]? | "chat_id=\(.message.chat.id)  名称：\(.message.chat.title // .message.chat.username // .message.chat.first_name // "-")"' <<<"$resp" | head -n 10
    echo "（如果为空：先在 Telegram 里给机器人发一条 /start，再重新运行）"
  else
    die "读取失败：${resp:0:200}"
  fi
}
tg_menu() {
  local c t
  while true; do
    echo
    echo "========== Telegram 机器人 =========="
    echo "1) 配置 Bot Token / chat_id / 自动推送"
    echo "2) 发送测试消息"
    echo "3) 推送全部节点分享链接"
    echo "4) 推送单个节点的分享链接"
    echo "5) 启动机器人服务（常驻，支持 /add /del /scan 等）"
    echo "6) 查看机器人服务状态"
    echo "7) 查看机器人日志"
    echo "8) 停止机器人服务"
    echo "9) 停用并移除服务文件与开机自启"
    echo "0) 返回"
    read -r -p "选择 [0-9]: " c || return 0
    case "${c:-}" in
      1) tg_config ;;
      2) tg_test ;;
      3) tg_push ;;
      4) prompt t "节点名称" ""; [[ -n "$t" ]] && tg_push "$t" ;;
      5) tg_service_start ;;
      6) tg_service_status ;;
      7) tg_service_logs 100 ;;
      8) tg_service_stop ;;
      9) tg_service_disable ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
    pause
  done
}
cmd_tg() {
  case "${1:-menu}" in
    config|set) tg_config ;;
    test|ping) tg_test ;;
    push|send|links) tg_push "${2:-}" ;;
    start|enable|on) tg_service_start ;;
    stop|off) tg_service_stop ;;
    disable|remove) tg_service_disable ;;
    restart) tg_service_stop >/dev/null 2>&1 || true; tg_service_start ;;
    status|show) tg_service_status ;;
    logs|log) tg_service_logs "${2:-100}" ;;
    id) tg_id_help ;;
    menu|bot) tg_menu ;;
    poll|run) tg_bot_loop ;;
    *) usage; exit 2 ;;
  esac
}

add_telegram_socks() {
  local tag port username password obj host local_name
  prompt port "TCP 端口" "$(free_port 1080 tcp)"
  check_port "$port" tcp
  port="$((10#$port))"
  host="$(public_host)"
  local_name="$(telegram_local_tag || true)"
  tag="$(telegram_auto_tag "$host")"
  if [[ -n "$local_name" ]]; then
    echo "根据本地 sing-box 入站名称自动生成 Telegram SOCKS5 节点名：$tag"
  else
    prompt tag "节点名称（可选自定义；直接回车使用自动名称）" "$tag"
    valid_tag "$tag"
    tag_exists "$tag" && die "节点名称 $tag 已存在，请重新运行并输入其他名称"
    echo "Telegram SOCKS5 节点名称：$tag"
  fi
  username="$(openssl rand -hex 6)"
  password="$(openssl rand -hex 18)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg username "$username" --arg password "$password" \
    '{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:$username,password:$password}]}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg username "$username" --arg password "$password" \
    '{protocol:"Telegram SOCKS5",tag:$tag,server:$host,port:$port,username:$username,password:$password}')"
}
add_all_protocols() {
  local confirm
  local created_files=()
  cat <<'TXT'
这会依次新增 8 类节点：VLESS + Reality、VMess、Hysteria2、TUIC、AnyTLS、Shadowsocks、Telegram SOCKS5、Xray VLESS + TLS（默认 XHTTP auto）。
每类节点都会沿用原有添加流程，逐项询问名称、端口或 TLS 参数并立即保存配置、显示分享链接；首次创建 Xray 节点时会安装独立 Xray sidecar。
各节点分别提交；若中途失败，之前成功创建的节点会保留，尚未执行的类型不会创建。端口仍需自行在防火墙和云安全组放行。
TXT
  read -r -p "确认开始批量新增全部协议节点？输入 y 继续 [y/N]: " confirm || confirm=""
  case "${confirm,,}" in y|yes) ;; *) echo "已取消，没有新增节点。"; return 0 ;; esac
  echo "[1/8] VLESS + Reality"
  add_reality
  created_files+=("$DATA/$LAST_TAG.json")
  echo "[2/8] VMess"
  add_vmess
  created_files+=("$DATA/$LAST_TAG.json")
  echo "[3/8] Hysteria2"
  add_hy2
  created_files+=("$DATA/$LAST_TAG.json")
  echo "[4/8] TUIC"
  add_tuic
  created_files+=("$DATA/$LAST_TAG.json")
  echo "[5/8] AnyTLS"
  add_anytls
  created_files+=("$DATA/$LAST_TAG.json")
  echo "[6/8] Shadowsocks"
  add_ss
  created_files+=("$DATA/$LAST_TAG.json")
  echo "[7/8] Telegram SOCKS5"
  add_telegram_socks
  echo "[8/8] Xray VLESS + TLS"
  xray_add_node
  created_files+=("$XRAY_DATA/$LAST_TAG.json")
  echo "全部 8 类节点均已创建，以上已逐项显示分享链接。"
  print_client_payload "v2rayNG" "${created_files[@]}"
  print_client_payload "NekoBox/sing-box" "${created_files[@]}"
  echo "Telegram SOCKS5 与 Xray VLESS + TLS/XHTTP 均未放入这两组：前者不纳入聚合；后者的自签证书 pcs pin 不能由 v2rayNG 当前导入流程可靠识别，NekoBox/sing-box 当前也无稳定的 XHTTP 支持。"
  echo "以上是本机终端中的 Base64 文本，不是公网订阅 URL；脚本不会创建或部署订阅地址。"
}

# ---------- 中转：解析落地节点分享链接 ----------
urldecode() { local s="${1//+/%2B}"; printf '%b' "${s//%/\\x}"; }
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }
b64d() {
  local s="${1//-/+}"; s="${s//_//}"
  while (( ${#s} % 4 )); do s+="="; done
  printf '%s' "$s" | base64 -d 2>/dev/null
}
declare -A LQ=()
L_SCHEME="" L_UI="" L_HOST="" L_PORT="" L_PATH="" L_QUERY=""
PARSED_OUT="" PARSED_DESC="" PARSED_PROTO="" L_VMESS_JSON=""
parse_share_link() {
  # 解析 vless / vmess / trojan / hysteria2 / hy2 / tuic / anytls / ss 链接，生成 sing-box 出站，结果放在 PARSED_OUT
  local link="$1" rest frag="" hp kv k v arr=() dec ui vmess_raw vmess_net vmess_tls vmess_security vmess_aid vmess_sni vmess_host vmess_ins vmess_path
  L_VMESS_JSON=""
  link="${link//[[:space:]]/}"
  [[ "$link" == *://* ]] || die "这不是分享链接（应以 vless:// vmess:// trojan:// hysteria2:// tuic:// anytls:// ss:// 开头）"
  L_SCHEME="${link%%://*}"; L_SCHEME="${L_SCHEME,,}"
  rest="${link#*://}"
  if [[ "$L_SCHEME" == vmess ]]; then
    # 标准 VMess 分享链接是 Base64(JSON)；支持 TCP 和 WebSocket 传输，可选 TLS（Argo 节点就是 VMess + WS + TLS）。
    rest="${rest%%#*}"
    vmess_raw="$(b64d "$rest")"
    jq -e 'type == "object" and ((.add | type) == "string" and (.add | length) > 0) and ((.id | type) == "string" and (.id | length) > 0) and (.port != null)' <<<"$vmess_raw" >/dev/null 2>&1 || die "无法解析 VMess 分享链接（应为 vmess://Base64(JSON)）"
    L_HOST="$(jq -r '.add' <<<"$vmess_raw")"
    L_PORT="$(jq -r '.port | tostring' <<<"$vmess_raw")"
    L_UI="$(jq -r '.id' <<<"$vmess_raw")"
    valid_host "$L_HOST" || die "VMess 链接里的服务器地址无效：$L_HOST"
    valid_port "$L_PORT" || die "VMess 链接里的端口无效：$L_PORT"
    L_PORT="$((10#$L_PORT))"
    vmess_net="$(jq -r '.net // "tcp" | ascii_downcase' <<<"$vmess_raw")"
    case "$vmess_net" in tcp|raw) vmess_net=tcp ;; ws) ;; *) die "VMess 中转只支持 tcp / ws 传输；该链接使用 net=$vmess_net" ;; esac
    vmess_tls="$(jq -r '.tls // "" | ascii_downcase' <<<"$vmess_raw")"
    case "$vmess_tls" in ""|none|tls) ;; *) die "不支持 VMess TLS 模式：$vmess_tls" ;; esac
    vmess_security="$(jq -r '.scy // .security // "auto" | ascii_downcase' <<<"$vmess_raw")"
    case "$vmess_security" in auto|none|zero|aes-128-gcm|chacha20-poly1305|aes-128-ctr) ;; *) die "不支持的 VMess 加密方式：$vmess_security" ;; esac
    vmess_aid="$(jq -r '.aid // .alterId // 0 | tostring' <<<"$vmess_raw")"
    [[ "$vmess_aid" =~ ^[0-9]+$ ]] || die "VMess 链接里的 alterId 无效"
    vmess_host="$(jq -r '.host // empty' <<<"$vmess_raw")"
    vmess_sni="$(jq -r '.sni // empty' <<<"$vmess_raw")"
    vmess_path="$(jq -r '.path // empty' <<<"$vmess_raw")"
    vmess_ins="$(jq -r 'if .allowInsecure == true or .allowInsecure == 1 or .allowInsecure == "true" then "true" else "false" end' <<<"$vmess_raw")"
    L_VMESS_JSON="$vmess_raw"
    PARSED_PROTO="VMess"
    [[ "$vmess_net" == ws ]] && PARSED_PROTO="VMess + WS"
    PARSED_OUT="$(jq -nc --arg server "$L_HOST" --argjson port "$L_PORT" --arg uuid "$L_UI" --arg security "$vmess_security" --argjson aid "$vmess_aid" --arg tls "$vmess_tls" --arg sni "$vmess_sni" --arg host "$vmess_host" --arg ins "$vmess_ins" --arg net "$vmess_net" --arg path "$vmess_path" '
      {type:"vmess",server:$server,server_port:$port,uuid:$uuid,security:$security,alter_id:$aid}
      + (if $net == "ws" then {transport:({type:"ws",path:(if $path == "" then "/" else $path end)} + (if $host != "" then {headers:{Host:$host}} else {} end))} else {} end)
      + (if $tls == "tls" then {tls:{enabled:true,server_name:(if $sni != "" then $sni elif $host != "" then $host else $server end),insecure:($ins == "true")}} else {} end)')"
    PARSED_DESC="$PARSED_PROTO $(uri_host "$L_HOST"):$L_PORT"
    return 0
  fi
  if [[ "$rest" == *"#"* ]]; then frag="${rest#*#}"; rest="${rest%%#*}"; fi
  : "$frag"
  L_QUERY=""
  if [[ "$rest" == *"?"* ]]; then L_QUERY="${rest#*\?}"; rest="${rest%%\?*}"; fi
  if [[ "$L_SCHEME" == ss && "$rest" != *@* ]]; then
    # 旧格式 ss://base64(method:password@host:port)
    dec="$(b64d "${rest%/}")"
    [[ "$dec" == *@* ]] || die "无法解析 ss 链接"
    L_UI="$(printf '%s' "${dec%@*}" | base64 | tr -d '\r\n')"
    rest="${L_UI}@${dec##*@}"
  fi
  [[ "$rest" == *@* ]] || die "链接里缺少 用户信息@地址:端口"
  L_UI="${rest%@*}"; hp="${rest##*@}"
  L_PATH=""
  if [[ "$hp" == */* ]]; then L_PATH="/${hp#*/}"; hp="${hp%%/*}"; fi
  if [[ "$hp" == \[*\]:* ]]; then
    L_HOST="${hp%%]*}"; L_HOST="${L_HOST#[}"; L_PORT="${hp##*]:}"
  else
    L_HOST="${hp%:*}"; L_PORT="${hp##*:}"
  fi
  valid_host "$L_HOST" || die "链接里的服务器地址无效：$L_HOST"
  valid_port "$L_PORT" || die "链接里的端口无效：$L_PORT"
  L_PORT="$((10#$L_PORT))"
  LQ=()
  if [[ -n "$L_QUERY" ]]; then
    IFS='&' read -r -a arr <<<"$L_QUERY"
    for kv in "${arr[@]}"; do
      [[ -n "$kv" ]] || continue
      k="${kv%%=*}"; v=""; [[ "$kv" == *=* ]] && v="${kv#*=}"
      LQ["$k"]="$(urldecode "$v")"
    done
  fi
  local sni="${LQ[sni]:-${LQ[peer]:-}}" ins="${LQ[insecure]:-${LQ[allowInsecure]:-${LQ[allow_insecure]:-0}}}" alpn="${LQ[alpn]:-}" fp="${LQ[fp]:-}"
  case "$L_SCHEME" in
    vless)
      local sec="${LQ[security]:-none}" net="${LQ[type]:-tcp}"
      [[ -z "${LQ[encryption]:-}" || "${LQ[encryption]}" == none ]] || die "不支持 VLESS encryption=${LQ[encryption]}"
      case "$net" in tcp|raw|ws|grpc|http|h2|httpupgrade) ;; *) die "不支持的 VLESS 传输方式：$net" ;; esac
      case "$sec" in none|tls|reality) ;; *) die "不支持的 VLESS security：$sec" ;; esac
      [[ "$sec" != reality || -n "${LQ[pbk]:-}" ]] || die "Reality 链接缺少 pbk（公钥）"
      case "$sec" in reality) PARSED_PROTO="VLESS + Reality" ;; tls) PARSED_PROTO="VLESS + TLS" ;; *) PARSED_PROTO="VLESS" ;; esac
      PARSED_OUT="$(jq -nc --arg server "$L_HOST" --argjson port "$L_PORT" --arg uuid "$(urldecode "$L_UI")" \
        --arg flow "${LQ[flow]:-}" --arg sec "$sec" --arg sni "$sni" --arg fp "$fp" --arg pbk "${LQ[pbk]:-}" --arg sid "${LQ[sid]:-}" \
        --arg ins "$ins" --arg alpn "$alpn" --arg net "$net" --arg path "${LQ[path]:-}" --arg hh "${LQ[host]:-}" --arg svc "${LQ[serviceName]:-}" '
        {type:"vless", server:$server, server_port:$port, uuid:$uuid}
        + (if $flow != "" then {flow:$flow} else {} end)
        + (if $sec == "reality" then
             {tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:(if $fp == "" then "chrome" else $fp end)},
                   reality:{enabled:true, public_key:$pbk, short_id:$sid}}}
           elif $sec == "tls" then
             {tls:({enabled:true, server_name:(if $sni == "" then $server else $sni end), insecure:($ins == "1" or $ins == "true")}
                   + (if $fp != "" then {utls:{enabled:true, fingerprint:$fp}} else {} end)
                   + (if $alpn != "" then {alpn:($alpn | split(","))} else {} end))}
           else {} end)
        + (if $net == "ws" then {transport:({type:"ws", path:(if $path == "" then "/" else $path end)} + (if $hh != "" then {headers:{Host:$hh}} else {} end))}
           elif $net == "grpc" then {transport:{type:"grpc", service_name:$svc}}
           elif $net == "http" or $net == "h2" then {transport:({type:"http"} + (if $path != "" then {path:$path} else {} end) + (if $hh != "" then {host:[$hh]} else {} end))}
           elif $net == "httpupgrade" then {transport:({type:"httpupgrade", path:(if $path == "" then "/" else $path end)} + (if $hh != "" then {host:$hh} else {} end))}
           else {} end)')" ;;
    hysteria2|hy2)
      PARSED_PROTO="Hysteria2"
      [[ -z "${LQ[obfs]:-}" || "${LQ[obfs]}" == salamander ]] || die "不支持的 Hysteria2 obfs：${LQ[obfs]}"
      PARSED_OUT="$(jq -nc --arg server "$L_HOST" --argjson port "$L_PORT" --arg pw "$(urldecode "$L_UI")" --arg sni "$sni" --arg ins "$ins" \
        --arg alpn "$alpn" --arg obfs "${LQ[obfs]:-}" --arg opw "${LQ[obfs-password]:-}" '
        {type:"hysteria2", server:$server, server_port:$port, password:$pw,
         tls:({enabled:true, server_name:(if $sni == "" then $server else $sni end), insecure:($ins == "1" or $ins == "true")}
              + (if $alpn != "" then {alpn:($alpn | split(","))} else {} end))}
        + (if $obfs == "salamander" then {obfs:{type:"salamander", password:$opw}} else {} end)')" ;;
    tuic)
      PARSED_PROTO="TUIC"
      ui="$(urldecode "$L_UI")"
      [[ "$ui" == *:* ]] || die "TUIC 链接应为 tuic://uuid:password@地址:端口"
      PARSED_OUT="$(jq -nc --arg server "$L_HOST" --argjson port "$L_PORT" --arg uuid "${ui%%:*}" --arg pw "${ui#*:}" --arg sni "$sni" --arg ins "$ins" \
        --arg alpn "${alpn:-h3}" --arg cc "${LQ[congestion_control]:-bbr}" --arg urm "${LQ[udp_relay_mode]:-}" '
        {type:"tuic", server:$server, server_port:$port, uuid:$uuid, password:$pw, congestion_control:$cc,
         tls:{enabled:true, server_name:(if $sni == "" then $server else $sni end), insecure:($ins == "1" or $ins == "true"), alpn:($alpn | split(","))}}
        + (if $urm != "" then {udp_relay_mode:$urm} else {} end)')" ;;
    anytls)
      PARSED_PROTO="AnyTLS"
      PARSED_OUT="$(jq -nc --arg server "$L_HOST" --argjson port "$L_PORT" --arg pw "$(urldecode "$L_UI")" --arg sni "$sni" --arg ins "$ins" '
        {type:"anytls", server:$server, server_port:$port, password:$pw,
         tls:{enabled:true, server_name:(if $sni == "" then $server else $sni end), insecure:($ins == "1" or $ins == "true")}}')" ;;
    ss)
      PARSED_PROTO="Shadowsocks"
      [[ -z "${LQ[plugin]:-}" ]] || die "不支持带 plugin 的 ss 链接"
      ui="$(urldecode "$L_UI")"
      [[ "$ui" == *:* ]] || ui="$(b64d "$L_UI")"
      [[ "$ui" == *:* ]] || die "无法解析 ss 链接的加密方式和密码"
      PARSED_OUT="$(jq -nc --arg server "$L_HOST" --argjson port "$L_PORT" --arg m "${ui%%:*}" --arg pw "${ui#*:}" \
        '{type:"shadowsocks", server:$server, server_port:$port, method:$m, password:$pw}')" ;;
    trojan)
      PARSED_PROTO="Trojan"
      local tnet="${LQ[type]:-tcp}" tpath="" thost="${LQ[host]:-}" tpw
      tpath="${LQ[path]:-${L_PATH:-}}"
      [[ -z "${LQ[plugin]:-}" ]] || die "不支持带 plugin 的 trojan 链接"
      case "$tnet" in tcp|raw) tnet=tcp ;; ws|grpc) ;; *) die "不支持的 Trojan 传输方式：$tnet" ;; esac
      tpw="$(urldecode "$L_UI")"
      [[ -n "$tpw" ]] || die "Trojan 链接缺少密码"
      PARSED_OUT="$(jq -nc --arg server "$L_HOST" --argjson port "$L_PORT" --arg pw "$tpw" --arg sni "$sni" --arg ins "$ins" \
        --arg net "$tnet" --arg path "$tpath" --arg host "$thost" --arg svc "${LQ[serviceName]:-}" --arg alpn "$alpn" '
        {type:"trojan", server:$server, server_port:$port, password:$pw,
         tls:({enabled:true, server_name:(if $sni == "" then $server else $sni end), insecure:($ins == "1" or $ins == "true")}
              + (if $alpn != "" then {alpn:($alpn | split(","))} else {} end))}
        + (if $net == "ws" then {transport:({type:"ws", path:(if $path == "" then "/" else $path end)} + (if $host != "" then {headers:{Host:$host}} else {} end))}
           elif $net == "grpc" then {transport:{type:"grpc", service_name:$svc}}
           else {} end)')" ;;
    *) die "暂不支持 $L_SCHEME:// 链接（支持 vless、vmess、trojan、hysteria2/hy2、tuic、anytls、ss）" ;;
  esac
  PARSED_DESC="$PARSED_PROTO $(uri_host "$L_HOST"):$L_PORT"
}
manual_landing() {
  # 手动填写落地节点，拼成分享链接后交给 parse_share_link
  local c h p a b c2 d e link vmess_json vmess_host
  echo "落地节点协议："
  echo "1) VLESS + Reality   2) Hysteria2   3) TUIC   4) AnyTLS   5) Shadowsocks   6) VMess TCP"
  echo "7) Trojan            8) VMess + WS/TLS（Argo / CDN）"
  read -r -p "选择 [1-8]: " c || die "没有选择协议"
  prompt h "落地服务器地址（IP 或域名）" ""
  h="${h#[}"; h="${h%]}"
  valid_host "$h" || die "地址无效"
  prompt p "落地端口" ""
  valid_port "$p" || die "端口无效"
  h="$(uri_host "$h")"
  case "$c" in
    1) prompt a "UUID" ""; prompt b "SNI（握手域名）" "www.bing.com"; prompt c2 "公钥 public_key（pbk）" ""; prompt d "short_id（sid，可留空）" " "
       d="${d// /}"
       link="vless://$(urlencode "$a")@${h}:${p}?encryption=none&security=reality&sni=$(urlencode "$b")&fp=chrome&pbk=$(urlencode "$c2")&sid=$(urlencode "$d")&type=tcp&flow=xtls-rprx-vision" ;;
    2) prompt a "密码" ""; prompt b "SNI（可留空）" " "; prompt d "允许不安全证书（自签证书选 y）[y/n]" "y"; b="${b// /}"
       link="hysteria2://$(urlencode "$a")@${h}:${p}/?sni=$(urlencode "$b")&insecure=$([[ "$d" == [yY]* ]] && echo 1 || echo 0)" ;;
    3) prompt a "UUID" ""; prompt c2 "密码" ""; prompt b "SNI（可留空）" " "; prompt d "允许不安全证书（自签证书选 y）[y/n]" "y"; b="${b// /}"
       link="tuic://$(urlencode "$a"):$(urlencode "$c2")@${h}:${p}?congestion_control=bbr&alpn=h3&sni=$(urlencode "$b")&allow_insecure=$([[ "$d" == [yY]* ]] && echo 1 || echo 0)" ;;
    4) prompt a "密码" ""; prompt b "SNI（可留空）" " "; prompt d "允许不安全证书（自签证书选 y）[y/n]" "y"; b="${b// /}"
       link="anytls://$(urlencode "$a")@${h}:${p}/?sni=$(urlencode "$b")&insecure=$([[ "$d" == [yY]* ]] && echo 1 || echo 0)" ;;
    5) prompt b "加密方式" "aes-128-gcm"; prompt a "密码" ""
       link="ss://$(printf '%s:%s' "$b" "$a" | base64 | tr -d '\r\n')@${h}:${p}" ;;
    6) prompt a "VMess UUID" ""
       vmess_host="${h#[}"; vmess_host="${vmess_host%]}"
       vmess_json="$(jq -nc --arg host "$vmess_host" --arg port "$p" --arg uuid "$a" \
         '{v:"2",ps:"relay",add:$host,port:$port,id:$uuid,aid:"0",scy:"auto",net:"tcp",type:"none",host:"",path:"",tls:"",sni:""}')"
       link="vmess://$(printf '%s' "$vmess_json" | base64 | tr -d '\r\n')" ;;
    7) prompt a "密码"; prompt b "SNI（证书域名，可留空）" " "; prompt d "允许不安全证书（自签证书选 y）[y/n]" "y"; b="${b// /}"
       link="trojan://$(urlencode "$a")@${h}:${p}?security=tls&sni=$(urlencode "$b")&type=tcp&allowInsecure=$([[ "$d" == [yY]* ]] && echo 1 || echo 0)" ;;
    8) prompt a "VMess UUID"; prompt b "SNI / Host（Argo 或 CDN 域名）"; prompt e "WebSocket path" "/"
       vmess_host="${h#[}"; vmess_host="${vmess_host%]}"
       [[ "$e" == /* ]] || die "WebSocket path 必须以 / 开头"
       vmess_json="$(jq -nc --arg host "$vmess_host" --arg port "$p" --arg uuid "$a" --arg hh "$b" --arg path "$e" \
         '{v:"2",ps:"relay",add:$host,port:$port,id:$uuid,aid:"0",scy:"auto",net:"ws",type:"none",host:$hh,path:$path,tls:"tls",sni:$hh}')"
       link="vmess://$(printf '%s' "$vmess_json" | base64 | tr -d '\r\n')" ;;
    *) die "无效选项" ;;
  esac
  parse_share_link "$link"
}
read_landing() {
  local link
  echo "落地节点：粘贴分享链接（vless / vmess（TCP 或 WS）/ trojan / hysteria2 / hy2 / tuic / anytls / ss），直接回车改为手动填写。"
  read -r -p "落地节点分享链接: " link || link=""
  if [[ -n "${link//[[:space:]]/}" ]]; then parse_share_link "$link"; else manual_landing; fi
  echo "落地节点：$PARSED_DESC"
}
tcp_reachable() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# ---------- 中转 / 端口转发 ----------
RELAY_DIR="$DATA/relays"
relay_add() {
  local c landing_host landing_port proto meta
  read_landing
  landing_host="$L_HOST"; landing_port="$L_PORT"; proto="$PARSED_PROTO"
  case "$PARSED_OUT" in
    *'"type":"vless"'*|*'"type":"vmess"'*|*'"type":"trojan"'*|*'"type":"anytls"'*|*'"type":"shadowsocks"'*)
      if tcp_reachable "$landing_host" "$landing_port"; then echo "落地端口 TCP 可以连通。"
      else echo "提示：从本机连不上落地 ${landing_host}:${landing_port}（TCP），请确认落地节点在运行、防火墙已放行。仍会继续添加。"; fi ;;
  esac
  echo
  echo "中转入口协议（客户端连接本机时用的协议）："
  echo "1) VLESS + Reality   2) Hysteria2   3) TUIC   4) AnyTLS   5) Shadowsocks"
  echo "6) Trojan            7) VMess TCP   8) Argo（Cloudflare Tunnel，本机出站也走 CF）"
  read -r -p "选择 [1-8，默认 1]: " c || c=1
  RELAY_OUT="$PARSED_OUT"; RELAY_DESC="$PARSED_DESC"; TAG_PREFIX="relay-"; LAST_TAG=""
  case "${c:-1}" in
    1) add_reality ;; 2) add_hy2 ;; 3) add_tuic ;; 4) add_anytls ;; 5) add_ss ;;
    6) add_trojan ;; 7) add_vmess ;; 8) add_argo ;;
    *) die "无效选项" ;;
  esac
  mkdir -p "$RELAY_DIR"
  meta="$RELAY_DIR/$LAST_TAG.json"
  jq -n --arg tag "$LAST_TAG" --arg desc "$RELAY_DESC" --arg lp "$proto" --arg lh "$landing_host" --argjson lport "$landing_port" \
    --argjson port "$(jq --arg t "$LAST_TAG" '.inbounds[] | select(.tag == $t) | .listen_port' "$CONF")" \
    --arg entry "$(jq -r '.protocol' "$DATA/$LAST_TAG.json")" \
    '{kind:"relay", tag:$tag, entry:$entry, listen_port:$port, landing:{protocol:$lp, server:$lh, port:$lport}, landing_desc:$desc, outbound:("to-" + $tag)}' >"$meta"
  chmod 600 "$meta"
  RELAY_OUT=""; RELAY_DESC=""; TAG_PREFIX=""
  echo
  echo "中转已添加：客户端 → 本机 ${LAST_TAG}（$(jq -r .entry "$meta")，端口 $(jq -r .listen_port "$meta")） → 落地 $(jq -r .landing_desc "$meta")"
  echo "只有这个入口的流量走落地，其他节点仍然直连。请在防火墙放行入口端口。"
}
forward_add() {
  local target thost tport net tag port obj meta link_mode=0 def_net="both" def_port
  echo "端口转发：本机端口收到的 TCP/UDP 流量原样转发到目标地址（不解密，适合转发任意节点）。"
  prompt target "转发目标（地址:端口，或者直接粘贴落地节点分享链接）" ""
  target="${target//[[:space:]]/}"
  [[ -n "$target" ]] || die "目标不能为空"
  if [[ "$target" == *://* ]]; then
    parse_share_link "$target"
    thost="$L_HOST"; tport="$L_PORT"; link_mode=1
    case "$L_SCHEME" in hysteria2|hy2|tuic) def_net=udp ;; vless|anytls|trojan) def_net=tcp ;; *) def_net=both ;; esac
  else
    if [[ "$target" == \[*\]:* ]]; then thost="${target%%]*}"; thost="${thost#[}"; tport="${target##*]:}"
    else thost="${target%:*}"; tport="${target##*:}"; fi
    valid_host "$thost" || die "目标地址无效：$thost"
    valid_port "$tport" || die "目标端口无效：$tport"
    tport="$((10#$tport))"
  fi
  prompt net "转发协议 tcp / udp / both" "$def_net"
  case "$net" in tcp|udp|both) ;; *) die "只能是 tcp、udp 或 both" ;; esac
  TAG_PREFIX=""
  ask_tag tag fwd
  def_port="$(free_port "$tport" "$net")"
  prompt port "本机监听端口" "$def_port"
  valid_port "$port" || die "端口无效"
  port="$((10#$port))"
  case "$net" in
    tcp) check_port "$port" tcp ;;
    udp) check_port "$port" udp ;;
    both) check_port "$port" tcp; port_free "$port" udp || die "端口 $port/udp 已被占用" ;;
  esac
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg h "$thost" --argjson tp "$tport" --arg net "$net" \
    '{type:"direct", tag:$tag, listen:"::", listen_port:$port, override_address:$h, override_port:$tp} + (if $net == "both" then {} else {network:$net} end)')"
  RELAY_OUT=""; RULE_TO="direct"
  apply_json "$obj"
  RULE_TO=""
  mkdir -p "$RELAY_DIR"
  meta="$RELAY_DIR/$tag.json"
  jq -n --arg tag "$tag" --argjson port "$port" --arg net "$net" --arg h "$thost" --argjson tp "$tport" --argjson lm "$link_mode" \
    --arg scheme "$L_SCHEME" --arg ui "$L_UI" --arg path "$L_PATH" --arg q "$L_QUERY" --arg vj "$L_VMESS_JSON" \
    '{kind:"forward", tag:$tag, listen_port:$port, network:$net, target:$h, target_port:$tp}
     + (if $lm == 1 then {link:({scheme:$scheme, userinfo:$ui, path:$path, query:$q}
                                    + (if $vj != "" then {vmess_json:$vj} else {} end))} else {} end)' >"$meta"
  chmod 600 "$meta"
  echo
  echo "端口转发已添加：本机 ${port}/${net} → $(uri_host "$thost"):${tport}"
  print_forward_link "$meta" "$(public_host)"
  echo "请在防火墙放行本机端口 ${port}（${net}）。"
}
print_forward_link() {
  # 转发目标是分享链接时：把原链接的地址和端口换成本机，生成给客户端用的新链接
  local f="$1" h="$2" port json
  jq -e '.link' "$f" >/dev/null 2>&1 || {
    echo "客户端用法：使用落地节点原来的配置，只把地址改成 $h、端口改成 $(jq -r .listen_port "$f")。"
    return 0
  }
  port="$(jq -r .listen_port "$f")"
  if [[ -n "$(jq -r '.link.vmess_json // empty' "$f" 2>/dev/null)" ]]; then
    # VMess 是 Base64(JSON)，直接重建 JSON 才能把地址和端口换成本机
    echo "分享链接（VMess，地址和端口已换成本机）："
    json="$(jq -r '.link.vmess_json' "$f" | jq -c --arg h "$(uri_host "$h")" --arg p "$port" '.add = $h | .port = $p')"
    printf 'vmess://%s\n' "$(printf '%s' "$json" | base64 | tr -d '\r\n')"
    return 0
  fi
  echo "分享链接（落地节点链接，地址已换成本机）："
  jq -r --arg h "$(uri_host "$h")" '"\(.link.scheme)://\(.link.userinfo)@\($h):\(.listen_port)\(.link.path)\(if .link.query != "" then "?" + .link.query else "" end)#\(.tag)"' "$f"
}
relay_list() {
  local f host kind any=0
  shopt -s nullglob
  local files=("$RELAY_DIR"/*.json)
  shopt -u nullglob
  ((${#files[@]})) || { echo "还没有中转或端口转发。"; return 0; }
  host="$(public_host)"
  for f in "${files[@]}"; do
    any=1
    kind="$(jq -r .kind "$f")"
    if [[ "$kind" == relay ]]; then
      echo "===== [中转] $(jq -r .tag "$f") ====="
      echo "客户端 → 本机 $(jq -r .entry "$f")（端口 $(jq -r .listen_port "$f")） → 落地 $(jq -r .landing_desc "$f")"
      if [[ -f "$DATA/$(jq -r .tag "$f").json" ]]; then
        if [[ "$(jq -r '.protocol' "$DATA/$(jq -r .tag "$f").json")" != *Argo* ]]; then
          jq --arg h "$host" '.server = $h' "$DATA/$(jq -r .tag "$f").json" >"$f.node.tmp"
          install -m 600 "$f.node.tmp" "$DATA/$(jq -r .tag "$f").json"; rm -f "$f.node.tmp"
        fi
        print_link "$DATA/$(jq -r .tag "$f").json"
      fi
    else
      echo "===== [端口转发] $(jq -r .tag "$f") ====="
      echo "本机 $(jq -r '"\(.listen_port)/\(.network)"' "$f") → $(uri_host "$(jq -r .target "$f")"):$(jq -r .target_port "$f")"
      print_forward_link "$f" "$host"
    fi
    echo
  done
  (( any )) || true
}
remove_by_tag() {
  # 删除入站，以及它对应的落地出站、路由规则、凭据和中转记录
  local tag="$1" out=""
  [[ -f "$XRAY_DATA/$tag.json" ]] && { xray_remove_node "$tag"; return 0; }
  jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONF" >/dev/null || die "未找到节点 $tag"
  [[ -f "$ARGO_DIR/$tag.json" ]] && argo_remove_service "$tag"
  [[ -f "$RELAY_DIR/$tag.json" ]] && out="$(jq -r '.outbound // empty' "$RELAY_DIR/$tag.json")"
  commit_jq --arg tag "$tag" --arg out "$out" '
    def inb: (.inbound // []) | if type == "string" then [.] else . end;
    .inbounds |= map(select(.tag != $tag))
    | (if $out != "" then .outbounds |= map(select(.tag != $out)) else . end)
    | (if (.route.rules? | type) == "array" then
         .route.rules |= (map(if (inb | index($tag)) != null then
                                 (if (inb | length) == 1 then empty else .inbound = (inb - [$tag]) end)
                               else . end))
       else . end)'
  rm -f "$DATA/${tag}.json" "$RELAY_DIR/${tag}.json" "$ARGO_DIR/${tag}.json"
  echo "已删除：$tag"
}
relay_remove() {
  local tag="${1:-}"
  if [[ -z "$tag" ]]; then
    relay_list
    prompt tag "要删除的中转/转发名称" ""
  fi
  [[ -n "$tag" ]] || die "名称不能为空"
  valid_tag "$tag"
  [[ -f "$RELAY_DIR/$tag.json" ]] || die "没有名为 $tag 的中转或端口转发"
  remove_by_tag "$tag"
}
relay_menu() {
  local c
  echo
  echo "========== 中转 / 端口转发 =========="
  echo "1) 添加中转（客户端用本脚本的协议连本机，流量转到落地节点）"
  echo "2) 添加端口转发（TCP/UDP 原样转发到目标地址:端口）"
  echo "3) 查看中转/转发和分享链接"
  echo "4) 删除中转/转发"
  echo "0) 返回"
  read -r -p "选择 [0-4]: " c || return 0
  case "$c" in
    1) relay_add ;;
    2) forward_add ;;
    3) relay_list ;;
    4) relay_remove ;;
    0) return 0 ;;
    *) echo "无效选项" ;;
  esac
}

# ---------- 修改节点指纹 ----------
node_fps() {
  # 输出节点当前的指纹列表（空格分隔）；AnyTLS 老节点没有 fp 时输出空
  jq -r 'if .fps then (.fps | join(" ")) elif .fp then .fp
         elif .protocol == "VLESS + Reality" then "chrome" else "" end' "$1"
}
fp_overview() {
  local f proto cur
  shopt -s nullglob
  local files=("$DATA"/*.json)
  shopt -u nullglob
  ((${#files[@]})) || { echo "还没有节点。"; return 0; }
  printf '%-24s %-18s %s\n' "名称" "协议" "指纹"
  for f in "${files[@]}"; do
    proto="$(jq -r .protocol "$f")"
    case "$proto" in
      "VLESS + Reality"|AnyTLS) cur="$(node_fps "$f")"; cur="${cur:-（未设置，链接不带 fp）}" ;;
      *) cur="-（不使用 uTLS）" ;;
    esac
    printf '%-24s %-18s %s\n' "$(jq -r .tag "$f")" "${proto// /}" "$cur"
  done
}
cmd_fp() {
  # 修改节点分享链接里的指纹；只改链接，不动 UUID、密钥、端口和 sing-box 配置
  local tag="${1:-}" arg="${2:-}" node proto cur new c tmp x keep
  if [[ -z "$tag" ]]; then
    fp_overview
    echo
    prompt tag "要修改指纹的节点名称" ""
  fi
  [[ -n "$tag" ]] || die "名称不能为空"
  valid_tag "$tag"
  node="$DATA/$tag.json"
  if [[ ! -f "$node" ]]; then
    [[ -f "$RELAY_DIR/$tag.json" ]] && die "$tag 是端口转发：流量原样转发、不解密，指纹由客户端决定，请在客户端里修改。"
    die "没有名为 $tag 的节点"
  fi
  proto="$(jq -r .protocol "$node")"
  case "$proto" in
    "VLESS + Reality"|AnyTLS) ;;
    *Argo*)
      echo "$tag 是 Argo 节点：TLS 由 Cloudflare 边缘提供，本机入站是明文 WebSocket，不使用 uTLS 指纹，无需设置。"
      return 0 ;;
    *) echo "$tag 是 ${proto}：Hysteria2、TUIC 走 QUIC，Shadowsocks 没有 TLS，Trojan 默认不使用 uTLS 指纹，都无需设置。"; return 0 ;;
  esac
  cur="$(node_fps "$node")"
  local mode=""
  [[ "$proto" == "VLESS + Reality" ]] && mode=reality
  if [[ -n "$arg" ]]; then
    new="$(parse_fps "$arg" "$mode")" || die "指纹选择无效"
  else
    echo "节点 $tag（$proto）当前指纹：${cur:-未设置}"
    echo "1) 添加指纹   2) 删除指纹   3) 重新选择全部指纹"
    read -r -p "选择 [1-3，默认 1]: " c || c=1
    case "${c:-1}" in
      1) echo "要添加的指纹："; show_fp_choices "$mode"
         read -r -p "添加: " x || x=""
         x="$(parse_fps "$x" "$mode")" || die "指纹选择无效"
         new="$(parse_fps "$cur $x" "$mode" 2>/dev/null)" ;;
      2) [[ -n "$cur" ]] || die "这个节点还没有设置指纹"
         read -r -p "要删除的指纹（当前：$cur）: " x || x=""
         x="$(parse_fps "$x")" || die "指纹选择无效"
         keep=""
         for c in $cur; do [[ " $x " == *" $c "* ]] || keep+="$c "; done
         [[ -n "${keep// /}" ]] || die "至少要保留一个指纹"
         new="$(parse_fps "$keep")" ;;
      3) choose_fps new "${cur// /,}" "$mode" ;;
      *) die "无效选项" ;;
    esac
  fi
  tmp="$node.tmp"
  jq --argjson fps "$(fps_json "$new")" --arg h "$(public_host)" '.server = $h | del(.fp) | .fps = $fps' "$node" >"$tmp" && install -m 600 "$tmp" "$node"
  rm -f "$tmp"
  if [[ "$new" == "$cur" ]]; then
    echo "指纹没有变化：$new"
  else
    echo "已把 $tag 的指纹改为：$new"
    echo "只改了分享链接，UUID、密钥、端口和服务端配置都没变，已经在用的客户端不受影响。"
  fi
  echo
  print_link "$node"
}

# ---------- 修改节点端口 ----------
inbound_net() {
  # 入站使用的传输层：tcp / udp / both
  jq -r --arg t "$1" '.inbounds[]? | select(.tag == $t) |
    if .type == "hysteria2" or .type == "tuic" then "udp"
    elif .type == "shadowsocks" then (.network // "both")
    elif .type == "direct" then (.network // "both")
    elif .type == "socks" then "tcp"
    else "tcp" end' "$CONF"
}
net_label() { case "$1" in tcp) echo TCP ;; udp) echo UDP ;; *) echo "TCP 和 UDP" ;; esac; }
is_local_addr() {
  # 地址是不是指向本机（中转/转发的目标是本机节点时需要跟着改端口）
  local a="${1#[}"; a="${a%]}"
  case "$a" in 127.*|::1|localhost|0.0.0.0|::) return 0 ;; esac
  [[ "$a" == "$(tr -d "[:space:]" <"$DATA/server-host" 2>/dev/null || true)" ]] && return 0
  ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$a"
}
port_owner() {
  # 输出配置里占用这个端口的入站名称
  jq -r --argjson p "$1" '[.inbounds[]? | select(.listen_port == $p) | .tag] | join(", ")' "$CONF"
}
cmd_port() {
  local tag="${1:-}" new="${2:-}" old net owner f kind fwd_tags=() relay_tags=() x is_fwd=0 meta host
  if [[ -z "$tag" ]]; then
    list_nodes
    prompt tag "要修改端口的节点名称（也可以是中转入口或端口转发）" ""
  fi
  [[ -n "$tag" ]] || die "名称不能为空"
  valid_tag "$tag"
  if [[ -f "$ARGO_DIR/$tag.json" ]]; then
    die "$tag 是 Argo 节点：本地端口由 cloudflared 隧道指向 127.0.0.1:$(jq -r .local_port "$ARGO_DIR/$tag.json")，不能直接改端口。请用 $(self_cmd) argo remove $tag 删除后用新端口重新添加。"
  fi
  if [[ -f "$XRAY_DATA/$tag.json" ]]; then xray_change_port "$tag" "$new"; return 0; fi
  old="$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .listen_port' "$CONF")"
  [[ -n "$old" && "$old" != null ]] || die "配置里没有名为 $tag 的节点"
  meta="$RELAY_DIR/$tag.json"
  [[ -f "$meta" && "$(jq -r .kind "$meta")" == forward ]] && is_fwd=1
  (( is_fwd )) || [[ -f "$DATA/$tag.json" ]] || die "找不到 $tag 的凭据文件 $DATA/$tag.json，无法重新生成分享链接"
  net="$(inbound_net "$tag")"
  echo "$tag 当前端口：$old（$(net_label "$net")）"
  if [[ -z "$new" ]]; then
    case "$net" in both) x="$(free_port $((old + 1)) both)" ;; *) x="$(free_port $((old + 1)) "$net")" ;; esac
    prompt new "新端口" "$x"
  fi
  valid_port "$new" || die "端口必须是 1-65535 的数字"
  new="$((10#$new))"
  [[ "$new" != "$old" ]] || { echo "新端口和当前端口相同（$old），没有改动。"; return 0; }
  owner="$(port_owner "$new")"
  [[ -z "$owner" ]] || die "端口 $new 已被本脚本的节点 $owner 使用，请换一个端口"
  case "$net" in
    tcp) port_free "$new" tcp || die "端口 $new/tcp 已被其他程序占用，请换一个端口（查看：ss -lntp | grep :$new）" ;;
    udp) port_free "$new" udp || die "端口 $new/udp 已被其他程序占用，请换一个端口（查看：ss -lnup | grep :$new）" ;;
    both) port_free "$new" tcp || die "端口 $new/tcp 已被其他程序占用，请换一个端口（查看：ss -lntp | grep :$new）"
          port_free "$new" udp || die "端口 $new/udp 已被其他程序占用，请换一个端口（查看：ss -lnup | grep :$new）" ;;
  esac

  # 本机上指向这个节点旧端口的端口转发 / 中转落地，跟着一起改
  shopt -s nullglob
  for f in "$RELAY_DIR"/*.json; do
    [[ "$(jq -r .tag "$f")" == "$tag" ]] && continue
    kind="$(jq -r .kind "$f")"
    if [[ "$kind" == forward ]] && [[ "$(jq -r .target_port "$f")" == "$old" ]] && is_local_addr "$(jq -r .target "$f")"; then
      fwd_tags+=("$(jq -r .tag "$f")")
    elif [[ "$kind" == relay ]] && [[ "$(jq -r .landing.port "$f")" == "$old" ]] && is_local_addr "$(jq -r .landing.server "$f")"; then
      relay_tags+=("$(jq -r .tag "$f")")
    fi
  done
  shopt -u nullglob
  local fj rj
  fj="$(printf '%s\n' "${fwd_tags[@]}" | jq -R . | jq -sc 'map(select(. != ""))')"
  rj="$(printf '%s\n' "${relay_tags[@]}" | jq -R . | jq -sc 'map(select(. != "")) | map("to-" + .)')"

  EXPECT_PORT="$new"; EXPECT_NET="$net"
  commit_jq --arg t "$tag" --argjson new "$new" --argjson fw "$fj" --argjson ro "$rj" '
    .inbounds |= map(
      if .tag == $t then .listen_port = $new
      elif (.tag as $x | $fw | index($x)) != null then .override_port = $new
      else . end)
    | if (.outbounds | type) == "array" then
        .outbounds |= map(if (.tag as $x | $ro | index($x)) != null then .server_port = $new else . end)
      else . end'

  host="$(public_host)"
  if [[ -f "$DATA/$tag.json" ]]; then
    jq --argjson p "$new" --arg h "$host" '.port = $p | .server = $h' "$DATA/$tag.json" >"$DATA/$tag.json.tmp" &&
      install -m 600 "$DATA/$tag.json.tmp" "$DATA/$tag.json"
    rm -f "$DATA/$tag.json.tmp"
  fi
  if [[ -f "$meta" ]]; then
    jq --argjson p "$new" '.listen_port = $p' "$meta" >"$meta.tmp" && install -m 600 "$meta.tmp" "$meta"
    rm -f "$meta.tmp"
  fi
  for x in "${fwd_tags[@]}"; do
    f="$RELAY_DIR/$x.json"
    jq --argjson p "$new" '.target_port = $p' "$f" >"$f.tmp" && install -m 600 "$f.tmp" "$f"; rm -f "$f.tmp"
  done
  for x in "${relay_tags[@]}"; do
    f="$RELAY_DIR/$x.json"
    jq --argjson p "$new" --arg o ":$old" --arg n ":$new" '.landing.port = $p | .landing_desc |= sub($o + "$"; $n)' "$f" >"$f.tmp" && install -m 600 "$f.tmp" "$f"; rm -f "$f.tmp"
  done

  echo
  echo "已把 $tag 的端口从 $old 改为 $new：配置已校验，sing-box 已重启。"
  if (( is_fwd )); then
    echo "UUID、密码等都没变（端口转发只改了本机监听端口）。"
    print_forward_link "$meta" "$host"
  else
    echo "UUID、密钥、密码和指纹都没变，只是端口变了。"
    print_link "$DATA/$tag.json"
    echo "已在用的客户端：重新导入上面的链接，或者在客户端里把端口改成 $new。"
  fi
  for x in "${fwd_tags[@]}"; do echo "本机端口转发 $x 原来指向这个节点的端口 $old，已同步改为 $new。"; done
  for x in "${relay_tags[@]}"; do echo "本机中转 $x 的落地原来是这个节点的端口 $old，已同步改为 $new。"; done
  echo
  echo "防火墙：请放行新端口 ${new}（$(net_label "$net")），旧端口 $old 不再使用，可以关闭。"
  case "$net" in
    tcp) echo "  UFW 示例：ufw allow ${new}/tcp" ;;
    udp) echo "  UFW 示例：ufw allow ${new}/udp" ;;
    both) echo "  UFW 示例：ufw allow ${new}/tcp; ufw allow ${new}/udp" ;;
  esac
  echo "  云服务商后台的安全组 / 防火墙也要放行。"
  echo "如果其他服务器上有中转或端口转发把这个节点当作落地（本机无法知道），要在那台机器上改成新端口：删除后用新链接重新添加中转。"
}

# ---------- 管理 ----------
traffic_configured() {
  jq -e '.experimental.clash_api | (.external_controller | type == "string") and (.secret | type == "string" and length > 0)' \
    "$CONF" >/dev/null 2>&1
}
traffic_fingerprint() {
  jq -c '[.experimental.clash_api.external_controller, .experimental.clash_api.secret]' "$CONF" |
    openssl dgst -sha256 | awk '{print $NF}'
}
traffic_config_owned() {
  local controller fingerprint
  [[ -f "$TRAFFIC_MARKER" && ! -L "$TRAFFIC_MARKER" ]] || return 1
  [[ "$(sed -n '1p' "$TRAFFIC_MARKER")" == "$TRAFFIC_MARK" ]] || return 1
  traffic_configured || return 1
  controller="$(jq -r '.experimental.clash_api.external_controller' "$CONF")"
  fingerprint="$(traffic_fingerprint)"
  [[ "$(sed -n '2p' "$TRAFFIC_MARKER")" == "$controller" &&
    "$(sed -n '3p' "$TRAFFIC_MARKER")" == "$fingerprint" ]]
}
traffic_script_path() {
  local path
  path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  [[ -f "$path" && "$path" != /dev/fd/* && "$path" != /proc/* ]] || die "流量统计服务需要从一个已保存的脚本文件启动"
  [[ ! "$path" =~ [[:space:]\"\\] ]] || die "脚本路径含空格或特殊字符，不能安全写入服务配置：$path"
  printf '%s' "$path"
}
traffic_path_owned_or_absent() {
  local path="$1"
  [[ ! -L "$path" ]] || die "统计服务目标是符号链接，为保护现有文件未操作：$path"
  if [[ -e "$path" ]] && ! grep -qxF -- "$TRAFFIC_MARK" "$path" 2>/dev/null; then
    die "统计服务目标已存在且不属于本脚本，为保护现有文件未覆盖：$path"
  fi
}
traffic_write_service_file() {
  local path="$1" content="$2" dir tmp
  dir="${path%/*}"
  traffic_path_owned_or_absent "$path"
  [[ ! -L "$dir" ]] || die "统计服务目录是符号链接，为保护现有文件未操作：$dir"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.${TRAFFIC_SERVICE}.XXXXXX")"
  if ! printf '%s\n' "$content" >"$tmp" || ! chmod 644 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    die "无法写入流量统计服务文件：$path"
  fi
}
traffic_systemd_text() {
  local path
  path="$(traffic_script_path)"
  cat <<UNIT
$TRAFFIC_MARK
[Unit]
Description=sing-box traffic statistics collector
After=network-online.target sing-box.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/bin/bash $path traffic-monitor
Restart=always
RestartSec=2
User=root
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
}
traffic_openrc_text() {
  local path
  path="$(traffic_script_path)"
  cat <<RC
#!/sbin/openrc-run
$TRAFFIC_MARK
name="$TRAFFIC_SERVICE"
description="sing-box traffic statistics collector"
supervisor="supervise-daemon"
command="/bin/bash"
command_args="$path traffic-monitor"
output_log="$TRAFFIC_LOG"
error_log="$TRAFFIC_LOG"
respawn_delay=2
respawn_max=0
depend() {
  need sing-box
  after net
}
RC
}
traffic_preflight_service() {
  need_init
  if [[ "$INIT_SYS" == systemd ]]; then traffic_path_owned_or_absent "$TRAFFIC_UNIT"
  else traffic_path_owned_or_absent "$TRAFFIC_INIT"; fi
}
traffic_install_service() {
  if [[ "$INIT_SYS" == systemd ]]; then
    traffic_write_service_file "$TRAFFIC_UNIT" "$(traffic_systemd_text)"
    systemctl daemon-reload
  elif is_openrc; then
    traffic_write_service_file "$TRAFFIC_INIT" "$(traffic_openrc_text)"
    chmod 755 "$TRAFFIC_INIT"
    touch "$TRAFFIC_LOG"
    chmod 600 "$TRAFFIC_LOG"
  else
    die "没有找到 systemd 或 OpenRC，无法安装流量统计监控服务"
  fi
}
traffic_start_service() {
  traffic_install_service
  if [[ "$INIT_SYS" == systemd ]]; then
    systemctl enable --now "$TRAFFIC_SERVICE"
  else
    rc-update add "$TRAFFIC_SERVICE" default >/dev/null 2>&1 || true
    rc-service "$TRAFFIC_SERVICE" start || rc-service "$TRAFFIC_SERVICE" restart
  fi
}
traffic_stop_service() {
  if [[ "$INIT_SYS" == systemd ]]; then
    [[ "$(systemctl is-active "$TRAFFIC_SERVICE" 2>/dev/null || true)" != active ]] || systemctl stop "$TRAFFIC_SERVICE"
  elif rc-service "$TRAFFIC_SERVICE" status >/dev/null 2>&1; then
    rc-service "$TRAFFIC_SERVICE" stop
  fi
}
traffic_init_total() {
  local now tmp
  [[ ! -L "$TRAFFIC_TOTAL" ]] || die "统计数据文件是符号链接，为保护数据未操作：$TRAFFIC_TOTAL"
  if [[ -f "$TRAFFIC_TOTAL" ]]; then
    jq -e 'type == "object" and (.up | type == "number" and . >= 0) and (.down | type == "number" and . >= 0)' \
      "$TRAFFIC_TOTAL" >/dev/null 2>&1 || die "累计流量数据文件无效，未重置：$TRAFFIC_TOTAL"
    return 0
  fi
  now="$(date -Iseconds)"
  tmp="$(mktemp "$DATA/.traffic-total.XXXXXX")"
  jq -n --arg now "$now" '{started_at:$now,updated_at:$now,up:0,down:0}' >"$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$TRAFFIC_TOTAL"
}
traffic_add_delta() {
  local line="$1" up down now tmp
  jq -e 'type == "object" and (.up | type == "number" and . >= 0) and (.down | type == "number" and . >= 0)' \
    <<<"$line" >/dev/null 2>&1 || return 0
  up="$(jq -r '.up | floor' <<<"$line")"
  down="$(jq -r '.down | floor' <<<"$line")"
  now="$(date -Iseconds)"
  tmp="$(mktemp "$DATA/.traffic-total.XXXXXX")"
  if ! jq --argjson up "$up" --argjson down "$down" --arg now "$now" \
      '{started_at:(.started_at // $now),updated_at:$now,up:((.up // 0)+$up),down:((.down // 0)+$down)}' \
      "$TRAFFIC_TOTAL" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$TRAFFIC_TOTAL"
}
traffic_lock_release() {
  local pid
  pid="$(cat "$TRAFFIC_LOCK/pid" 2>/dev/null || true)"
  if [[ "$pid" == "$$" ]]; then
    rm -f -- "$TRAFFIC_LOCK/pid"
    rmdir -- "$TRAFFIC_LOCK" 2>/dev/null || true
  fi
}
traffic_lock_acquire() {
  local attempt pid inode current_inode
  mkdir -p "$DATA"
  for attempt in 1 2 3; do
    if mkdir -- "$TRAFFIC_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" >"$TRAFFIC_LOCK/pid"
      trap 'traffic_lock_release' EXIT
      trap 'exit 0' INT TERM
      return 0
    fi
    [[ -d "$TRAFFIC_LOCK" && ! -L "$TRAFFIC_LOCK" ]] || die "流量监控锁路径异常：$TRAFFIC_LOCK"
    inode="$(stat -c '%i' "$TRAFFIC_LOCK" 2>/dev/null || true)"
    pid="$(cat "$TRAFFIC_LOCK/pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      die "流量统计采集器已经运行（PID $pid）"
    fi
    sleep 1
    current_inode="$(stat -c '%i' "$TRAFFIC_LOCK" 2>/dev/null || true)"
    [[ -n "$inode" && "$inode" == "$current_inode" ]] || continue
    pid="$(cat "$TRAFFIC_LOCK/pid" 2>/dev/null || true)"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$TRAFFIC_LOCK/pid"
      rmdir -- "$TRAFFIC_LOCK" 2>/dev/null || true
    fi
  done
  die "无法取得流量统计采集锁：$TRAFFIC_LOCK"
}
traffic_monitor() {
  local controller port secret auth_file
  traffic_config_owned || die "统计监控停止：当前 Clash API 配置与管理器记录不匹配"
  controller="$(jq -r '.experimental.clash_api.external_controller' "$CONF")"
  [[ "$controller" =~ ^127\.0\.0\.1:([0-9]{1,5})$ ]] || die "统计监控只允许连接本机回环地址"
  port="${BASH_REMATCH[1]}"
  secret="$(jq -r '.experimental.clash_api.secret' "$CONF")"
  [[ "$secret" =~ ^[A-Fa-f0-9]{64}$ ]] || die "统计 API 密钥格式无效"
  traffic_lock_acquire
  traffic_init_total
  auth_file="$DATA/.traffic-curl.conf"
  printf 'header = "Authorization: Bearer %s"\n' "$secret" >"$auth_file"
  chmod 600 "$auth_file"
  while true; do
    if curl -fsS --no-buffer --connect-timeout 5 --config "$auth_file" \
        "http://127.0.0.1:${port}/traffic" 2>/dev/null |
        while IFS= read -r line; do traffic_add_delta "$line"; done; then
      :
    fi
    sleep 2
  done
}
traffic_find_port() {
  local p
  for ((p=19090; p<=19190; p++)); do
    port_in_config "$p" && continue
    if [[ -f "$XRAY_CONF" ]] && xray_port_in_config "$p"; then continue; fi
    port_free "$p" tcp && { printf '%s' "$p"; return 0; }
  done
  return 1
}
traffic_enable() {
  local port controller secret marker_tmp backup had_total=0
  need_jq
  need_sb
  if traffic_config_owned; then
    traffic_init_total
    traffic_start_service
    return 0
  fi
  if jq -e '.experimental.clash_api? != null' "$CONF" >/dev/null 2>&1; then
    die "配置中已有 Clash API，未覆盖现有设置；请先自行确认并移除后再启用管理器统计"
  fi
  if jq -e '(.experimental.v2ray_api.listen? // "") != ""' "$CONF" >/dev/null 2>&1; then
    die "当前配置启用了 V2Ray API；为避免统计计数器冲突，未启用 Clash API 流量统计"
  fi
  port="$(traffic_find_port)" || die "没有找到可用的本机统计端口（19090-19190）"
  controller="127.0.0.1:$port"
  secret="$(openssl rand -hex 32)"
  traffic_preflight_service
  [[ ! -f "$TRAFFIC_TOTAL" ]] || had_total=1
  traffic_init_total
  # Clash API 只绑定回环地址并使用随机密钥，不会在公网开放管理接口。
  commit_jq --arg controller "$controller" --arg secret "$secret" \
    '.experimental = (.experimental // {}) | .experimental.clash_api = {external_controller:$controller,secret:$secret}'
  backup="$LAST_BACKUP"
  marker_tmp="$(mktemp "$DATA/.traffic-enabled.XXXXXX")"
  printf '%s\n%s\n%s\n' "$TRAFFIC_MARK" "$controller" "$(traffic_fingerprint)" >"$marker_tmp"
  chmod 600 "$marker_tmp"
  mv -f -- "$marker_tmp" "$TRAFFIC_MARKER"
  if ! traffic_start_service; then
    traffic_remove_service || true
    rm -f -- "$TRAFFIC_MARKER"
    (( had_total )) || rm -f -- "$TRAFFIC_TOTAL"
    if [[ -n "$backup" && -f "$backup" ]]; then
      cp -a "$backup" "$CONF"
      if check_config && reload_service && svc_healthy; then
        die "流量采集服务启动失败；已恢复 sing-box 原配置并保留节点，请检查 systemd/OpenRC 服务状态"
      fi
      die "流量采集服务启动失败；已写回原配置，但 sing-box 服务未能恢复，请检查日志：$(svc_log_hint)"
    fi
    die "流量采集服务启动失败；没有找到可用备份，需检查配置：$CONF"
  fi
  echo "已启用 sing-box 入/出流量累计统计；API 仅监听 127.0.0.1:$port，统计从现在开始。"
}
traffic_format_bytes() {
  awk -v bytes="$1" 'BEGIN { split("B KiB MiB GiB TiB PiB", u, " "); i=1; while (bytes >= 1024 && i < 6) { bytes /= 1024; i++ } if (i == 1) printf "%.0f %s", bytes, u[i]; else printf "%.2f %s", bytes, u[i] }'
}
traffic_show() {
  local started updated up down active
  traffic_enable
  started="$(jq -r '.started_at // "未知"' "$TRAFFIC_TOTAL")"
  updated="$(jq -r '.updated_at // "未知"' "$TRAFFIC_TOTAL")"
  up="$(jq -r '.up' "$TRAFFIC_TOTAL")"
  down="$(jq -r '.down' "$TRAFFIC_TOTAL")"
  if [[ "$INIT_SYS" == systemd ]]; then active="$(systemctl is-active "$TRAFFIC_SERVICE" 2>/dev/null || true)"
  else active="$(rc-service "$TRAFFIC_SERVICE" status >/dev/null 2>&1 && echo running || echo stopped)"; fi
  echo "sing-box 累计流量（Xray sidecar 流量不计入）"
  printf '  入站 / 客户端上传（up）：%s\n' "$(traffic_format_bytes "$up")"
  printf '  出站 / 客户端下载（down）：%s\n' "$(traffic_format_bytes "$down")"
  printf '  统计开始：%s\n  最近更新：%s\n  采集服务：%s\n' "$started" "$updated" "$active"
}
traffic_remove_service() {
  if [[ "$INIT_SYS" == systemd ]]; then
    systemctl disable --now "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    if [[ -f "$TRAFFIC_UNIT" ]] && grep -qxF -- "$TRAFFIC_MARK" "$TRAFFIC_UNIT"; then rm -f -- "$TRAFFIC_UNIT"; fi
    systemctl daemon-reload
  else
    rc-service "$TRAFFIC_SERVICE" stop >/dev/null 2>&1 || true
    rc-update del "$TRAFFIC_SERVICE" default >/dev/null 2>&1 || true
    if [[ -f "$TRAFFIC_INIT" ]] && grep -qxF -- "$TRAFFIC_MARK" "$TRAFFIC_INIT"; then rm -f -- "$TRAFFIC_INIT"; fi
  fi
  rm -f -- "$DATA/.traffic-curl.conf"
}
traffic_disable() {
  traffic_config_owned || die "当前流量统计配置不是管理器创建的，未修改任何设置"
  traffic_stop_service || die "无法停止流量采集服务，未移除 API 配置或统计数据"
  commit_jq 'del(.experimental.clash_api) | if (.experimental // null) == {} then del(.experimental) else . end'
  traffic_remove_service
  rm -f -- "$TRAFFIC_MARKER"
  echo "已停止流量采集并移除管理器添加的 Clash API；累计记录保留在 $TRAFFIC_TOTAL。"
}
cmd_traffic() {
  case "${1:-show}" in
    show|status|enable|on) traffic_show ;;
    disable|off) traffic_disable ;;
    *) die "用法：$(self_cmd) traffic [show|disable]" ;;
  esac
}

list_nodes() {
  echo "已配置的入站节点："
  jq -r '.inbounds[]? | [(.tag // "-"), .type, (.listen_port|tostring), (.listen // "0.0.0.0")] | @tsv' "$CONF" |
    awk 'BEGIN{printf "%-24s %-16s %-8s %s\n","TAG","协议","端口","监听地址"} {printf "%-24s %-16s %-8s %s\n",$1,$2,$3,$4}'
  if compgen -G "$XRAY_DATA/*.json" >/dev/null; then
    echo "Xray sidecar 节点："
    for f in "$XRAY_DATA"/*.json; do
      printf '%-24s %-16s %-8s %s\n' "$(jq -r .tag "$f")" "VLESS/TLS $(jq -r .transport "$f")" "$(jq -r .port "$f")" "::"
    done
  fi
  if compgen -G "$ARGO_DIR/*.json" >/dev/null; then
    echo "Argo（Cloudflare Tunnel）节点："
    for f in "$ARGO_DIR"/*.json; do
      printf '%-24s %-16s %-8s %s\n' "$(jq -r .tag "$f")" "Argo $(jq -r .proto "$f")" "$(jq -r .local_port "$f")" "$(jq -r .host "$f")"
    done
  fi
  echo
  echo "凭据文件（含敏感信息，权限仅 root 可读）：$DATA/*.json"
}
remove_node() {
  local tag
  list_nodes
  prompt tag "要删除的节点 tag" ""
  [[ -n "$tag" ]] || die "tag 不能为空"
  valid_tag "$tag"
  remove_by_tag "$tag"
}
show_links() {
  # sing-box 节点使用当前保存的服务器地址；Xray TLS 必须保留证书对应的 SNI 域名。
  local f host tls_host
  shopt -s nullglob
  local files=("$DATA"/*.json)
  shopt -u nullglob
  if ((${#files[@]} == 0)) && ! compgen -G "$XRAY_DATA/*.json" >/dev/null; then
    echo "尚无节点凭据文件。"
    return 0
  fi
  host="$(public_host)"
  for f in "${files[@]}"; do
    jq -e '.protocol and .tag' "$f" >/dev/null 2>&1 || continue
    # Argo 节点的连接地址是 Cloudflare 域名，不能改成本机公网地址
    if [[ "$(jq -r '.protocol // empty' "$f")" != *Argo* ]] && [[ "$(jq -r '.server // empty' "$f")" != "$host" ]]; then
      jq --arg h "$host" '.server = $h' "$f" >"$f.tmp" && install -m 600 "$f.tmp" "$f"
      rm -f "$f.tmp"
    fi
    echo "===== $(basename "$f" .json) ====="
    jq . "$f"
    print_link "$f"
    echo
  done
  if compgen -G "$XRAY_DATA/*.json" >/dev/null; then
    for f in "$XRAY_DATA"/*.json; do
      tls_host="$(jq -r '.sni // empty' "$f")"
      if valid_domain "$tls_host"; then
        if [[ "$(jq -r '.server // empty' "$f")" != "$tls_host" ]]; then
          jq --arg h "$tls_host" '.server=$h' "$f" >"$f.tmp" && install -m 600 "$f.tmp" "$f"
          rm -f "$f.tmp"
        fi
      else
        echo "警告：Xray 节点 $(basename "$f" .json) 的证书域名无效，未自动覆盖其连接地址。" >&2
      fi
      echo "===== $(basename "$f" .json) [Xray] ====="
      jq . "$f"
      print_link "$f"
      echo
    done
  fi
  if compgen -G "$RELAY_DIR/*.json" >/dev/null; then
    echo "端口转发和中转详情：$(self_cmd) relay list"
  fi
}
status() {
  echo "=== sing-box 版本 ==="
  if resolve_sb; then "$SB" version || true; else echo "未找到 sing-box 程序"; fi
  echo "=== 服务状态（${INIT_SYS}） ==="
  svc_status
  echo "=== 端口监听 ==="
  ss -lntup || true
}
firewall_help() {
  cat <<'TXT'
本脚本不会自动修改防火墙。请仅放行你实际使用的节点端口：
  Reality / AnyTLS / Shadowsocks / Telegram SOCKS5 / Trojan / Xray VLESS + TLS：TCP
  Hysteria2 / TUIC：UDP
  端口转发：按添加时选择的 tcp / udp / both 放行
  Argo（Cloudflare Tunnel）：本机 WebSocket 入站只监听 127.0.0.1，不需要对外放行端口；只需本机可以出站访问 Cloudflare

检查本机规则：
  ufw status verbose
  nft list ruleset
  iptables -S

如果使用 UFW，示例（按实际节点修改）：
  ufw allow 443/tcp
  ufw allow 8443/udp
  ufw allow 9443/udp
  ufw allow 10443/tcp
  ufw allow 11443/tcp
  ufw allow 1080/tcp  # Telegram SOCKS5 默认端口

Alpine 通常没有 UFW，默认也不拦截入站；如果自己配置了 iptables / nftables，用上面的命令检查。

同时检查 VPS 服务商后台的云防火墙/安全组。不要在 SSH 远程会话中盲目启用 UFW；
先确认 SSH 端口已放行，避免失去连接。
TXT
}
bbr_set_paths() {
  case "${1:-$INIT_SYS}" in
    systemd)
      BBR_SYSCTL_FILE="/etc/sysctl.d/99-singbox-manager-tcp-bbr.conf"
      BBR_MODULES_FILE="/etc/modules-load.d/99-singbox-manager-tcp-bbr.conf" ;;
    openrc)
      BBR_SYSCTL_FILE="/etc/sysctl.conf"
      BBR_MODULES_FILE="/etc/modules" ;;
    *) return 1 ;;
  esac
}
bbr_write_block() {
  local file="$1" content="$2" dir tmp begin_count=0 end_count=0 mode=600
  [[ ! -L "$file" ]] || { echo "拒绝修改符号链接配置：$file" >&2; return 1; }
  [[ ! -e "$file" || -f "$file" ]] || { echo "不是普通文件：$file" >&2; return 1; }
  dir="$(dirname -- "$file")"
  mkdir -p -- "$dir" || return 1
  if [[ -f "$file" ]]; then
    begin_count="$(grep -Fxc -- "$BBR_MARK_BEGIN" "$file" || true)"
    end_count="$(grep -Fxc -- "$BBR_MARK_END" "$file" || true)"
    [[ "$begin_count" == "$end_count" && ( "$begin_count" == 0 || "$begin_count" == 1 ) ]] || {
      echo "配置标记不完整或重复，拒绝改动：$file" >&2; return 1;
    }
    mode="$(stat -c '%a' "$file" 2>/dev/null || echo 600)"
  fi
  tmp="$(mktemp "$dir/.sb-bbr.XXXXXX")" || return 1
  if [[ -f "$file" ]]; then
    awk -v begin="$BBR_MARK_BEGIN" -v end="$BBR_MARK_END" '
      $0 == begin { inside=1; next }
      $0 == end { inside=0; next }
      !inside { print }
    ' "$file" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  [[ ! -s "$tmp" ]] || printf '\n' >>"$tmp"
  printf '%s\n%s\n%s\n' "$BBR_MARK_BEGIN" "$content" "$BBR_MARK_END" >>"$tmp"
  chmod "$mode" "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}
bbr_remove_block() {
  local file="$1" tmp begin_count=0 end_count=0 mode=600
  [[ -e "$file" ]] || return 0
  [[ ! -L "$file" && -f "$file" ]] || { echo "拒绝修改非普通文件：$file" >&2; return 1; }
  begin_count="$(grep -Fxc -- "$BBR_MARK_BEGIN" "$file" || true)"
  end_count="$(grep -Fxc -- "$BBR_MARK_END" "$file" || true)"
  [[ "$begin_count" == 0 && "$end_count" == 0 ]] && return 0
  [[ "$begin_count" == 1 && "$end_count" == 1 ]] || { echo "配置标记不完整或重复：$file" >&2; return 1; }
  mode="$(stat -c '%a' "$file" 2>/dev/null || echo 600)"
  tmp="$(mktemp "$(dirname -- "$file")/.sb-bbr.XXXXXX")" || return 1
  awk -v begin="$BBR_MARK_BEGIN" -v end="$BBR_MARK_END" '
    $0 == begin { inside=1; next }
    $0 == end { inside=0; next }
    !inside { print }
  ' "$file" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}
bbr_state_valid() {
  [[ -f "$BBR_STATE" && ! -L "$BBR_STATE" ]] && [[ "$(head -n1 "$BBR_STATE" 2>/dev/null)" == "$BBR_STATE_MARKER" ]]
}
bbr_state_value() { sed -n "s/^$1=//p" "$BBR_STATE" | head -n1; }
bbr_write_state() {
  local previous="$1" init="$2" tmp
  mkdir -p -- "$DATA" || return 1
  tmp="$(mktemp "$DATA/.tcp-bbr-state.XXXXXX")" || return 1
  printf '%s\nprevious=%s\ninit=%s\n' "$BBR_STATE_MARKER" "$previous" "$init" >"$tmp"
  if chmod 600 "$tmp" && mv -f -- "$tmp" "$BBR_STATE"; then return 0; fi
  rm -f -- "$tmp"
  return 1
}
cmd_bbr_status() {
  local available current
  [[ -r "$BBR_CC_FILE" && -r "$BBR_AVAILABLE_FILE" ]] || { echo "内核未提供 TCP 拥塞控制 sysctl 接口。"; return 0; }
  current="$(cat "$BBR_CC_FILE")"
  available="$(cat "$BBR_AVAILABLE_FILE")"
  echo "当前 TCP 拥塞控制算法：$current"
  echo "内核已注册算法：${available:-（无）}"
  if bbr_state_valid; then
    echo "管理器持久化：已启用（原算法：$(bbr_state_value previous)；init：$(bbr_state_value init)）"
  else
    echo "管理器持久化：未启用"
  fi
  if bbr_set_paths "$INIT_SYS" && [[ -f "$BBR_SYSCTL_FILE" ]] && grep -Fq -- "$BBR_MARK_BEGIN" "$BBR_SYSCTL_FILE"; then
    echo "BBR 配置位置：$BBR_SYSCTL_FILE"
  fi
  echo "默认队列规则未由管理器修改。"
}
cmd_bbr_apply() {
  local available current previous init_saved state_created=0 module_file sysctl_file answer
  need_root
  [[ -r "$BBR_CC_FILE" && -r "$BBR_AVAILABLE_FILE" ]] || { echo "内核未提供 TCP 拥塞控制接口；未作修改。"; return 0; }
  available="$(cat "$BBR_AVAILABLE_FILE")"
  if ! grep -qw -- bbr <<<"$available"; then
    echo "内核当前未注册标准 TCP BBR（bbr）；没有修改任何设置。"
    echo "内核已注册算法：${available:-（无）}"
    if grep -Eqw 'bbr2|bbr3' <<<"$available"; then echo "检测到非标准/定制 BBR 变体；自动模式不会擅自启用。"; fi
    return 0
  fi
  [[ "$INIT_SYS" == systemd || "$INIT_SYS" == openrc ]] || { echo "未识别 systemd/OpenRC；无法安全配置开机持久化。"; return 0; }
  current="$(cat "$BBR_CC_FILE")"
  if [[ -e "$BBR_STATE" ]]; then
    bbr_state_valid || { echo "BBR 状态文件存在但标记无效：$BBR_STATE"; return 0; }
    init_saved="$(bbr_state_value init)"
    [[ "$init_saved" == "$INIT_SYS" ]] || { echo "系统 init 与上次 BBR 设置不一致；请先使用原 init 环境执行 sb bbr reset。"; return 0; }
  else
    previous="$current"
  fi
  bbr_set_paths "$INIT_SYS" || { echo "无法确定 sysctl 配置位置。"; return 0; }
  sysctl_file="$BBR_SYSCTL_FILE"; module_file="$BBR_MODULES_FILE"
  echo "自动选择：内核已注册标准算法 bbr。"
  echo "当前算法：$current"
  echo "将把 tcp_congestion_control 设为 bbr，并写入开机配置：$sysctl_file"
  echo "将登记 tcp_bbr 模块以便启动时可用：$module_file"
  echo "不会修改队列规则、其他 sysctl、防火墙或 sing-box/Xray 服务。"
  if ! read -r -p "确认应用这项系统级 TCP 设置？[y/N]: " answer || [[ ! "${answer,,}" =~ ^(y|yes)$ ]]; then
    echo "已取消，系统设置未更改。"; return 0
  fi
  if ! bbr_state_valid; then
    bbr_write_state "$previous" "$INIT_SYS" || { echo "无法保存原算法状态；未继续。"; return 0; }
    state_created=1
  fi
  if ! bbr_write_block "$module_file" "tcp_bbr"; then
    (( state_created )) && rm -f -- "$BBR_STATE"
    echo "无法写入模块加载配置；未继续。"; return 0
  fi
  if ! bbr_write_block "$sysctl_file" "net.ipv4.tcp_congestion_control = bbr"; then
    if (( state_created )); then bbr_remove_block "$module_file" || true; rm -f -- "$BBR_STATE"; fi
    echo "无法写入 sysctl 配置；未继续。"; return 0
  fi
  if ! printf '%s\n' bbr >"$BBR_CC_FILE"; then
    if (( state_created )); then
      bbr_remove_block "$sysctl_file" || true; bbr_remove_block "$module_file" || true; rm -f -- "$BBR_STATE"
    fi
    echo "无法应用运行时算法；请检查内核权限和状态文件。"; return 0
  fi
  echo "TCP 拥塞控制已切换为 bbr，并已写入开机配置。运行 sb bbr status 查看，运行 sb bbr reset 恢复原算法。"
}
cmd_bbr_reset() {
  local previous saved_init available current answer
  need_root
  if ! bbr_state_valid; then
    [[ ! -e "$BBR_STATE" ]] && echo "没有由管理器创建的 BBR 状态；未作修改。" || echo "BBR 状态文件无效：$BBR_STATE"
    return 0
  fi
  previous="$(bbr_state_value previous)"; saved_init="$(bbr_state_value init)"
  [[ "$previous" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "备份的原算法名称无效；未作修改。"; return 0; }
  [[ "$saved_init" == systemd || "$saved_init" == openrc ]] || { echo "备份的系统类型无效；未作修改。"; return 0; }
  [[ -r "$BBR_CC_FILE" && -r "$BBR_AVAILABLE_FILE" ]] || { echo "内核未提供 TCP 拥塞控制接口；状态保留。"; return 0; }
  available="$(cat "$BBR_AVAILABLE_FILE")"; current="$(cat "$BBR_CC_FILE")"
  if ! grep -qw -- "$previous" <<<"$available"; then echo "原算法 $previous 当前不可用；未移除持久化设置，状态保留。"; return 0; fi
  bbr_set_paths "$saved_init" || { echo "无法识别原配置位置；状态保留。"; return 0; }
  echo "将恢复 TCP 算法：$current → $previous，并删除管理器添加的 BBR 配置块。"
  if ! read -r -p "确认恢复？[y/N]: " answer || [[ ! "${answer,,}" =~ ^(y|yes)$ ]]; then echo "已取消。"; return 0; fi
  if ! printf '%s\n' "$previous" >"$BBR_CC_FILE"; then echo "运行时算法恢复失败；状态保留。"; return 0; fi
  if ! bbr_remove_block "$BBR_SYSCTL_FILE"; then echo "无法移除 sysctl 配置；状态保留。"; return 0; fi
  if ! bbr_remove_block "$BBR_MODULES_FILE"; then echo "算法已恢复，但模块加载标记未移除；状态保留，请检查 $BBR_MODULES_FILE。"; return 0; fi
  rm -f -- "$BBR_STATE"
  echo "已恢复原 TCP 算法，并移除管理器的持久化配置。"
}
du_kib() {
  local path="$1" value
  if [[ -e "$path" || -L "$path" ]]; then
    value="$(du -sk -- "$path" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  else value=0; fi
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "$value"
}
sum_du_kib() {
  local total=0 path value
  for path in "$@"; do value="$(du_kib "$path")"; total=$((total + value)); done
  printf '%s' "$total"
}
format_du_kib() {
  awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.2f GiB (%.0f KiB)", k/1048576, k; else if (k >= 1024) printf "%.2f MiB (%.0f KiB)", k/1024, k; else printf "%.0f KiB", k }'
}
cmd_storage() {
  local script_path shortcut_path script_kib=0 service_kib sb_kib xray_kib backup_kib log_kib argo_kib total
  script_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  [[ -f "$script_path" ]] || script_path=""
  if [[ -z "$script_path" ]] && shortcut_is_ours; then script_path="$SHORTCUT"; fi
  script_kib="$(du_kib "$script_path")"
  if shortcut_is_ours; then
    shortcut_path="$(readlink -f "$SHORTCUT" 2>/dev/null || printf '%s' "$SHORTCUT")"
    [[ "$shortcut_path" == "$script_path" ]] || script_kib=$((script_kib + $(du_kib "$shortcut_path")))
  fi
  if [[ "$INIT_SYS" == systemd ]]; then
    service_kib="$(sum_du_kib /etc/systemd/system/sing-box.service /etc/systemd/system/singbox-xray.service)"
  else
    service_kib="$(sum_du_kib "$OPENRC_INIT" "$OPENRC_CONFD" "$XRAY_INIT")"
  fi
  script_kib=$((script_kib + service_kib))
  sb_kib="$(sum_du_kib "$CONF_DIR")"
  xray_kib=$(( $(du_kib "$XRAY_DIR") + $(du_kib "$XRAY_BIN") ))
  argo_kib=$(( $(du_kib "$ARGO_BIN") + $(du_kib "$ARGO_DIR") ))
  backup_kib="$(sum_du_kib "$BACKUP_DIR" "$XRAY_BACKUP_DIR")"
  log_kib="$(sum_du_kib "$SB_LOG" "$XRAY_LOG")"
  total=$((script_kib + sb_kib + xray_kib + argo_kib + backup_kib + log_kib))
  echo "管理器相关磁盘占用（du -sk，按已分配空间估算；只统计下列路径）："
  printf '  管理脚本、sb 快捷命令与服务文件：%s\n' "$(format_du_kib "$script_kib")"
  printf '  sing-box 配置、节点元数据与证书：%s\n' "$(format_du_kib "$sb_kib")"
  printf '  Xray sidecar 配置、节点元数据、证书与内核：%s\n' "$(format_du_kib "$xray_kib")"
  printf '  Argo（cloudflared 程序与隧道记录）：%s\n' "$(format_du_kib "$argo_kib")"
  printf '  管理器备份：%s\n' "$(format_du_kib "$backup_kib")"
  printf '  管理器日志文件：%s\n' "$(format_du_kib "$log_kib")"
  printf '  合计：%s\n' "$(format_du_kib "$total")"
  echo "此统计不扫描整个系统，不包括 sing-box 主程序、操作系统或未列出的文件，也不会删除或修改任何内容。"
}
watchdog_file_owned() { [[ -f "$1" && ! -L "$1" ]] && grep -qxF -- "$WATCHDOG_MARK" "$1"; }
watchdog_path_safe() {
  local path="$1" dir="${1%/*}"
  [[ ! -L "$dir" && ! -L "$path" ]] || { echo "看门狗路径是符号链接，为保护现有文件未操作：$path" >&2; return 1; }
  if [[ -e "$path" ]] && ! watchdog_file_owned "$path"; then
    echo "看门狗目标已存在且不属于本脚本，为保护现有文件未覆盖：$path" >&2
    return 1
  fi
}
watchdog_write_text() {
  local path="$1" content="$2" dir="${1%/*}" tmp
  watchdog_path_safe "$path" || return 1
  mkdir -p "$dir" || return 1
  [[ ! -L "$dir" ]] || { echo "看门狗目录是符号链接，为保护现有文件未操作：$dir" >&2; return 1; }
  tmp="$(mktemp "$dir/.singbox-manager-watchdog.XXXXXX")" || return 1
  if ! printf '%s\n' "$content" >"$tmp" || ! chmod 644 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}
watchdog_openrc_block_check() {
  local file="$OPENRC_CONFD" begin_count end_count
  [[ -e "$file" ]] || return 0
  [[ -f "$file" && ! -L "$file" ]] || { echo "OpenRC 配置不是普通文件或是符号链接：$file" >&2; return 1; }
  begin_count="$(grep -Fxc -- "$WATCHDOG_CONF_BEGIN" "$file" || true)"
  end_count="$(grep -Fxc -- "$WATCHDOG_CONF_END" "$file" || true)"
  [[ "$begin_count" == "$end_count" && ( "$begin_count" == 0 || "$begin_count" == 1 ) ]] || {
    echo "OpenRC 看门狗配置标记不完整或重复：$file" >&2; return 1;
  }
  if [[ "$begin_count" == 1 ]]; then
    awk -v begin="$WATCHDOG_CONF_BEGIN" -v end="$WATCHDOG_CONF_END" '
      $0 == begin { if (state != 0) bad=1; state=1; next }
      $0 == end { if (state != 1) bad=1; state=2; next }
      END { if (bad || state != 2) exit 1 }
    ' "$file" || { echo "OpenRC 看门狗标记顺序异常：$file" >&2; return 1; }
  fi
}
watchdog_openrc_block_present() {
  [[ -f "$OPENRC_CONFD" ]] && grep -Fqx -- "$WATCHDOG_CONF_BEGIN" "$OPENRC_CONFD" && grep -Fqx -- "$WATCHDOG_CONF_END" "$OPENRC_CONFD"
}
watchdog_write_openrc_override() {
  local file="$OPENRC_CONFD" dir="${OPENRC_CONFD%/*}" tmp mode=644
  watchdog_openrc_block_check || return 1
  mkdir -p "$dir" || return 1
  [[ ! -L "$dir" ]] || { echo "OpenRC 配置目录是符号链接：$dir" >&2; return 1; }
  if [[ -f "$file" ]]; then mode="$(stat -c '%a' "$file" 2>/dev/null || echo 644)"; fi
  tmp="$(mktemp "$dir/.singbox-manager-watchdog.XXXXXX")" || return 1
  if [[ -f "$file" ]]; then
    awk -v begin="$WATCHDOG_CONF_BEGIN" -v end="$WATCHDOG_CONF_END" '
      $0 == begin { inside=1; next }
      $0 == end { inside=0; next }
      !inside { print }
    ' "$file" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  printf '\n%s\nrespawn_delay=3\nrespawn_max=0\n%s\n' "$WATCHDOG_CONF_BEGIN" "$WATCHDOG_CONF_END" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod "$mode" "$tmp" && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}
watchdog_remove_openrc_override() {
  local file="$OPENRC_CONFD" dir="${OPENRC_CONFD%/*}" tmp mode
  [[ -f "$file" ]] || return 0
  watchdog_openrc_block_check || return 1
  watchdog_openrc_block_present || return 0
  mode="$(stat -c '%a' "$file" 2>/dev/null || echo 644)"
  tmp="$(mktemp "$dir/.singbox-manager-watchdog.XXXXXX")" || return 1
  awk -v begin="$WATCHDOG_CONF_BEGIN" -v end="$WATCHDOG_CONF_END" '
    $0 == begin { inside=1; next }
    $0 == end { inside=0; next }
    !inside { print }
  ' "$file" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod "$mode" "$tmp" && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}
watchdog_xray_managed() {
  if is_openrc; then [[ -f "$XRAY_INIT" ]] && grep -qxF -- "$XRAY_MARK" "$XRAY_INIT"
  else [[ -f "$XRAY_UNIT" ]] && grep -qxF -- "$XRAY_MARK" "$XRAY_UNIT"; fi
}
watchdog_singbox_ports_healthy() {
  local rows type port net
  [[ -r "$CONF" ]] || return 2
  rows="$(jq -r '.inbounds[]? | select((.listen_port | type) == "number" and .listen_port > 0) | [.type // "", .listen_port, (if .type == "hysteria2" or .type == "tuic" then "udp" elif .type == "shadowsocks" or .type == "direct" then (.network // "both") else "tcp" end)] | @tsv' "$CONF" 2>/dev/null)" || return 2
  [[ -n "$rows" ]] || return 0
  while IFS=$'\t' read -r type port net; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    port_listening "$port" "$net" || return 1
  done <<<"$rows"
}
watchdog_xray_ports_healthy() {
  local ports port
  [[ -r "$XRAY_CONF" ]] || return 2
  ports="$(jq -r '.inbounds[]? | select((.port | type) == "number" and .port > 0) | .port' "$XRAY_CONF" 2>/dev/null)" || return 2
  [[ -n "$ports" ]] || return 0
  while IFS= read -r port; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    ss -H -lnt "( sport = :$port )" 2>/dev/null | grep -q . || return 1
  done <<<"$ports"
}
watchdog_wait_singbox() {
  local i
  for ((i = 0; i < 20; i++)); do
    if svc_is_running && watchdog_singbox_ports_healthy; then return 0; fi
    sleep 0.5
  done
  return 1
}
watchdog_wait_xray() {
  local i
  for ((i = 0; i < 20; i++)); do
    if xray_service_active && watchdog_xray_ports_healthy; then return 0; fi
    sleep 0.5
  done
  return 1
}
watchdog_message() { [[ "$1" == 1 ]] || echo "$2"; }
watchdog_check_singbox() {
  local quiet="$1" rc
  if ! svc_is_running; then watchdog_message "$quiet" "sing-box 当前已停止，按设计跳过，不会自动启动"; return 0; fi
  if watchdog_singbox_ports_healthy; then watchdog_message "$quiet" "sing-box 进程与配置监听端口正常"; return 0; else rc=$?; fi
  if (( rc == 2 )); then echo "sing-box 看门狗无法读取或解析当前配置；未重启服务。"; return 1; fi
  echo "sing-box 服务仍处于运行状态，但至少一个配置端口未监听；正在尝试恢复。"
  if ! svc_is_running; then watchdog_message "$quiet" "检查期间 sing-box 已停止；未主动启动。"; return 0; fi
  svc_restart || { echo "sing-box 看门狗重启失败；请查看服务日志。"; return 1; }
  watchdog_wait_singbox || { echo "sing-box 已重启，但监听检查仍未通过；请检查配置、端口占用和日志。"; return 1; }
  echo "sing-box 已恢复，进程及配置监听端口正常。"
}
watchdog_check_xray() {
  local quiet="$1" rc
  watchdog_xray_managed && [[ -r "$XRAY_CONF" ]] || { watchdog_message "$quiet" "未检测到由本脚本管理的 Xray sidecar；跳过"; return 0; }
  if ! xray_service_active; then watchdog_message "$quiet" "Xray sidecar 当前已停止，按设计跳过，不会自动启动"; return 0; fi
  if watchdog_xray_ports_healthy; then watchdog_message "$quiet" "Xray sidecar 进程与配置 TCP 端口正常"; return 0; else rc=$?; fi
  if (( rc == 2 )); then echo "Xray 看门狗无法读取或解析当前配置；未重启服务。"; return 1; fi
  echo "Xray sidecar 仍处于运行状态，但至少一个配置 TCP 端口未监听；正在尝试恢复。"
  if ! xray_service_active; then watchdog_message "$quiet" "检查期间 Xray sidecar 已停止；未主动启动。"; return 0; fi
  xray_restart_service || { echo "Xray sidecar 看门狗重启失败；请查看服务日志。"; return 1; }
  watchdog_wait_xray || { echo "Xray sidecar 已重启，但监听检查仍未通过；请检查配置、端口占用和日志。"; return 1; }
  echo "Xray sidecar 已恢复，进程及配置 TCP 端口正常。"
}
cmd_watchdog_check() {
  local quiet=0 failed=0
  [[ "${1:-}" == --quiet ]] && quiet=1
  need_jq
  have ss || { echo "缺少 ss（iproute2），无法检查监听端口。" >&2; return 1; }
  watchdog_check_singbox "$quiet" || failed=1
  watchdog_check_xray "$quiet" || failed=1
  return "$failed"
}
cmd_watchdog_loop() {
  need_root
  sleep 30
  while :; do
    if have jq && have ss; then cmd_watchdog_check --quiet || true
    else echo "看门狗暂时缺少 jq 或 ss；本轮跳过端口检查。" >&2; fi
    sleep 60
  done
}
watchdog_systemd_preflight() {
  local exec_line exec_bin
  exec_line="$(systemctl cat "$SERVICE.service" 2>/dev/null | sed -n 's/^ExecStart=//p' | sed '/^[[:space:]]*$/d' | tail -n1 || true)"
  case "$exec_line" in
    "/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run") ;;
    *" run -c $CONF")
      exec_bin="${exec_line%% *}"; exec_bin="${exec_bin#[-@+!]}"
      [[ -x "$exec_bin" ]] && is_elf "$(readlink -f "$exec_bin" 2>/dev/null || printf '%s' "$exec_bin")" || { echo "sing-box.service 不是官方或本脚本管理的服务；为保护现有服务，未修改。" >&2; return 1; }
      ;;
    *) echo "找不到受支持的 sing-box.service；为保护现有服务，未修改。" >&2; return 1 ;;
  esac
  if [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]] && ! shortcut_is_ours; then echo "$SHORTCUT 已被其他程序占用；为保护现有文件，未启用看门狗。" >&2; return 1; fi
  watchdog_path_safe "$WATCHDOG_SINGBOX_DROPIN" || return 1
  watchdog_path_safe "$WATCHDOG_SYSTEMD_SERVICE" || return 1
  watchdog_path_safe "$WATCHDOG_SYSTEMD_TIMER" || return 1
  if watchdog_xray_managed; then watchdog_path_safe "$WATCHDOG_XRAY_DROPIN" || return 1; fi
}
watchdog_systemd_enable() {
  local answer dropin service timer
  watchdog_systemd_preflight || return 1
  read -r -p "启用看门狗：systemd 将在意外退出时自动重启服务，并每分钟检查 active 服务的节点监听端口；不会启动已停止的服务。继续？[y/N]: " answer || answer=""
  [[ "${answer,,}" =~ ^(y|yes)$ ]] || { echo "已取消，未修改看门狗配置。"; return 0; }
  if ! shortcut_is_ours; then install_shortcut; fi
  shortcut_is_ours || die "无法安全创建 $SHORTCUT；看门狗需要可持续调用的管理脚本"
  printf -v dropin '%s\n' '[Unit]' 'StartLimitIntervalSec=0' '' '[Service]' 'Restart=always' 'RestartSec=3' "$WATCHDOG_MARK"
  printf -v service '%s\n' '[Unit]' 'Description=sing-box manager node service health check' "$WATCHDOG_MARK" '' '[Service]' 'Type=oneshot' "ExecStart=$SHORTCUT watchdog check --quiet" 'TimeoutStartSec=120'
  printf -v timer '%s\n' '[Unit]' 'Description=Check active sing-box and Xray node listeners periodically' "$WATCHDOG_MARK" '' '[Timer]' 'OnActiveSec=30s' 'OnUnitActiveSec=60s' 'AccuracySec=15s' "Unit=$WATCHDOG_SERVICE.service" '' '[Install]' 'WantedBy=timers.target'
  watchdog_write_text "$WATCHDOG_SINGBOX_DROPIN" "$dropin" || die "无法安全写入 sing-box 看门狗 drop-in"
  if watchdog_xray_managed; then watchdog_write_text "$WATCHDOG_XRAY_DROPIN" "$dropin" || die "无法安全写入 Xray 看门狗 drop-in"; fi
  watchdog_write_text "$WATCHDOG_SYSTEMD_SERVICE" "$service" || die "无法写入看门狗 service"
  watchdog_write_text "$WATCHDOG_SYSTEMD_TIMER" "$timer" || die "无法写入看门狗 timer"
  systemctl daemon-reload
  systemctl enable --now "$WATCHDOG_TIMER"
  echo "看门狗已启用；节点服务未被重启。它只会在服务仍为 active、但配置端口缺失时尝试恢复。"
}
watchdog_openrc_init_text() {
  local text
  printf -v text '%s\n' '#!/sbin/openrc-run' "$WATCHDOG_MARK" "name=\"$WATCHDOG_SERVICE\"" 'description="sing-box manager node service health check"' 'supervisor="supervise-daemon"' "command=\"$SHORTCUT\"" 'command_args="watchdog loop"' "output_log=\"$WATCHDOG_LOG\"" "error_log=\"$WATCHDOG_LOG\"" 'respawn_delay=5' 'respawn_max=0' '' 'depend() {' '  after net dns' '}'
  printf '%s' "$text"
}
watchdog_openrc_preflight() {
  [[ -f "$OPENRC_INIT" ]] || { echo "找不到 OpenRC sing-box 服务文件：$OPENRC_INIT" >&2; return 1; }
  if ! is_our_script "$OPENRC_INIT" && ! openrc_is_official "$OPENRC_INIT"; then
    echo "sing-box OpenRC 服务不属于本脚本或官方软件包；为保护现有服务，未修改。" >&2; return 1
  fi
  watchdog_openrc_block_check || return 1
  watchdog_path_safe "$WATCHDOG_OPENRC_INIT" || return 1
  if [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]] && ! shortcut_is_ours; then echo "$SHORTCUT 已被其他程序占用；为保护现有文件，未启用看门狗。" >&2; return 1; fi
}
watchdog_openrc_enable() {
  local answer official=0 restart_singbox=0 conf_already=0
  watchdog_openrc_preflight || return 1
  if openrc_is_official "$OPENRC_INIT"; then
    official=1
    watchdog_openrc_block_present && conf_already=1
    if (( ! conf_already )) && svc_is_running; then restart_singbox=1; fi
  fi
  if (( restart_singbox )); then
    read -r -p "Alpine 官方 sing-box 服务需重启一次以应用无限重生设置，现有连接会短暂中断。继续启用？[y/N]: " answer || answer=""
  else
    read -r -p "启用 OpenRC 看门狗；它每分钟检查仍在运行的节点端口，不会启动已停止的服务。继续？[y/N]: " answer || answer=""
  fi
  [[ "${answer,,}" =~ ^(y|yes)$ ]] || { echo "已取消，未修改看门狗配置。"; return 0; }
  if ! shortcut_is_ours; then install_shortcut; fi
  shortcut_is_ours || die "无法安全创建 $SHORTCUT；看门狗需要可持续调用的管理脚本"
  if (( official )); then watchdog_write_openrc_override || die "无法安全写入 OpenRC respawn 配置"; fi
  watchdog_write_text "$WATCHDOG_OPENRC_INIT" "$(watchdog_openrc_init_text)" || die "无法安全写入 OpenRC 看门狗服务"
  touch "$WATCHDOG_LOG" && chmod 600 "$WATCHDOG_LOG"
  rc-update add "$WATCHDOG_SERVICE" default >/dev/null
  if (( restart_singbox )); then rc-service "$SERVICE" restart || die "已写入看门狗配置，但 sing-box 重启失败；请检查服务日志"; fi
  if ! rc-service "$WATCHDOG_SERVICE" status >/dev/null 2>&1; then rc-service "$WATCHDOG_SERVICE" start; fi
  echo "OpenRC 看门狗已启用；不会启动处于 stopped 状态的 sing-box/Xray 服务。"
}
cmd_watchdog_enable() {
  need_init
  need_jq
  have ss || die "缺少 ss（iproute2），无法检查监听端口；请先运行 sb install"
  if is_openrc; then watchdog_openrc_enable; else
    watchdog_systemd_enable
  fi
}
cmd_watchdog_status() {
  local unit active restart limit timer_state timer_enabled
  need_init
  echo "=== 节点服务看门狗 ==="
  if [[ "$INIT_SYS" == systemd ]]; then
    if watchdog_file_owned "$WATCHDOG_SYSTEMD_TIMER"; then
      timer_state="$(systemctl is-active "$WATCHDOG_TIMER" 2>/dev/null || true)"
      timer_enabled="$(systemctl is-enabled "$WATCHDOG_TIMER" 2>/dev/null || true)"
      printf '定时健康检查：状态=%s，开机启用=%s\n' "${timer_state:-unknown}" "${timer_enabled:-unknown}"
    else
      echo "定时健康检查：未启用"
    fi
    for unit in "$SERVICE.service" "$XRAY_SERVICE.service"; do
      [[ "$unit" == "$SERVICE.service" ]] || watchdog_xray_managed || continue
      systemctl cat "$unit" >/dev/null 2>&1 || continue
      active="$(systemctl is-active "$unit" 2>/dev/null || true)"
      restart="$(systemctl show "$unit" -p Restart --value 2>/dev/null || true)"
      limit="$(systemctl show "$unit" -p StartLimitIntervalUSec --value 2>/dev/null || true)"
      printf '  %s：状态=%s，Restart=%s，启动限速间隔=%s\n' "$unit" "${active:-unknown}" "${restart:-unknown}" "${limit:-unknown}"
    done
  else
    if watchdog_file_owned "$WATCHDOG_OPENRC_INIT" && rc-service "$WATCHDOG_SERVICE" status >/dev/null 2>&1; then echo "定时健康检查：运行中（每分钟检查）"
    else echo "定时健康检查：未启用或未运行"; fi
    if is_our_script "$OPENRC_INIT"; then echo "  sing-box 进程监督：本脚本服务配置为 supervise-daemon / respawn_max=0"
    elif openrc_is_official "$OPENRC_INIT"; then
      if watchdog_openrc_block_present; then echo "  sing-box 进程监督：官方 supervise-daemon，管理器覆盖为 respawn_max=0"
      else echo "  sing-box 进程监督：官方 supervise-daemon；当前使用发行版默认重生上限"; fi
    fi
    if watchdog_xray_managed; then echo "  Xray 进程监督：本脚本服务配置为 supervise-daemon / respawn_max=0"; fi
    if svc_is_running; then echo "  sing-box：运行中"; else echo "  sing-box：已停止"; fi
    if watchdog_xray_managed; then if xray_service_active; then echo "  Xray sidecar：运行中"; else echo "  Xray sidecar：已停止"; fi; fi
  fi
  echo "检查只针对仍处于运行状态的服务；已手动停止的服务不会被自动启动。"
}
cmd_watchdog_disable() {
  need_init
  if [[ "$INIT_SYS" == systemd ]]; then
    local path changed=0
    for path in "$WATCHDOG_SYSTEMD_TIMER" "$WATCHDOG_SYSTEMD_SERVICE" "$WATCHDOG_SINGBOX_DROPIN"; do watchdog_path_safe "$path" || return 1; done
    if [[ -e "$WATCHDOG_XRAY_DROPIN" ]]; then watchdog_path_safe "$WATCHDOG_XRAY_DROPIN" || return 1; fi
    if watchdog_file_owned "$WATCHDOG_SYSTEMD_TIMER"; then systemctl disable --now "$WATCHDOG_TIMER" >/dev/null 2>&1 || true; fi
    for path in "$WATCHDOG_SYSTEMD_TIMER" "$WATCHDOG_SYSTEMD_SERVICE" "$WATCHDOG_SINGBOX_DROPIN" "$WATCHDOG_XRAY_DROPIN"; do
      if watchdog_file_owned "$path"; then rm -f -- "$path"; changed=1; fi
    done
    rmdir "${WATCHDOG_SINGBOX_DROPIN%/*}" "${WATCHDOG_XRAY_DROPIN%/*}" 2>/dev/null || true
    if (( changed )); then systemctl daemon-reload; fi
    echo "看门狗已停用；现有 sing-box/Xray 节点服务不会被停止或重启。"
  else
    local restart_singbox=0 answer
    watchdog_path_safe "$WATCHDOG_OPENRC_INIT" || return 1
    watchdog_openrc_block_check || return 1
    if openrc_is_official "$OPENRC_INIT" && watchdog_openrc_block_present && svc_is_running; then
      restart_singbox=1
      read -r -p "停用将恢复 Alpine 官方 sing-box 原重生上限；需重启一次以应用，现有连接会短暂中断。继续？[y/N]: " answer || answer=""
      [[ "${answer,,}" =~ ^(y|yes)$ ]] || { echo "已取消，未修改看门狗配置。"; return 0; }
    fi
    if watchdog_file_owned "$WATCHDOG_OPENRC_INIT"; then
      rc-update del "$WATCHDOG_SERVICE" default >/dev/null 2>&1 || true
      rc-service "$WATCHDOG_SERVICE" stop >/dev/null 2>&1 || true
      rm -f -- "$WATCHDOG_OPENRC_INIT"
    fi
    watchdog_remove_openrc_override || die "无法安全移除 OpenRC 看门狗 respawn 配置"
    if (( restart_singbox )); then rc-service "$SERVICE" restart || die "看门狗配置已移除，但 sing-box 重启失败"; fi
    echo "OpenRC 看门狗已停用；节点服务未被停止。日志保留在 $WATCHDOG_LOG。"
  fi
}
watchdog_menu() {
  local choice
  while true; do
    echo
    echo "========== 节点服务看门狗 =========="
    echo "1) 启用/安装"
    echo "2) 查看状态"
    echo "3) 立即检查并尝试恢复监听异常"
    echo "4) 停用"
    echo "0) 返回"
    read -r -p "选择 [0-4]: " choice || return 0
    case "$choice" in
      1) cmd_watchdog_enable ;;
      2) cmd_watchdog_status ;;
      3) cmd_watchdog_check ;;
      4) cmd_watchdog_disable ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
    pause
  done
}
usage() {
  cat <<TXT
singbox-manager ${SCRIPT_VERSION}
用法：$(self_cmd) [命令]

  （不带命令）     打开管理菜单
  install          Linux 安装管理器；FreeBSD 使用 pkg 安装 sing-box（管理菜单仍不支持）
  menu             打开管理菜单
  5|ss|add-ss      直接添加 Shadowsocks 节点（安装后也可运行 sb5）
  tg               添加 Telegram SOCKS5 代理节点（不支持 MTProto）
  tg config        配置 Telegram 机器人（--token / --chat-id / --auto-push）
  tg test          给机器人发一条测试消息（同时验证 Token 和 chat_id）
  tg push [名称]   推送全部（或指定节点）分享链接到 Telegram
  tg id            查看给机器人发过消息的 chat_id
  tg enable|start  安装并启动常驻机器人服务（支持 /add /del /scan 等命令）
  tg stop|restart|status|disable|logs  机器人服务的停 / 重启 / 状态 / 停用 / 日志
  tgbot [菜单]     同 tg 机器人子命令（不带参数时打开机器人菜单）
  links            查看所有节点的参数和分享链接
  vmess|add-vmess  添加 VMess AEAD（TCP）节点
  trojan|add-trojan 添加 Trojan 节点（TLS + 密码）
  add <协议> [选项] 添加节点（可脚本化）：reality|vless-reality|hy2|tuic|anytls|trojan|ss|vmess|argo|tg|xray
  argo [add|list|url|log|remove]  管理 Argo（Cloudflare Tunnel）节点
  scan-sni [选项]  Reality SNI 扫描：--region 地区 / --category 分类 / --list 列表 / --file 文件 / --auto
  add-all          新增全部 8 类节点并输出 v2rayNG / NekoBox 两组 Base64 导入内容
  bbr [status|reset] 自动选用内核支持的标准 TCP BBR；status 查看，reset 恢复
  storage          统计管理脚本、节点数据、备份和日志的磁盘占用（只读）
  traffic [show|disable] 查看/启停 sing-box 入站与出站累计流量
  watchdog [enable|status|check|disable]  管理 sing-box / Xray 节点服务看门狗
  host             修改服务器地址（自动识别公网 IP），并重新生成分享链接
  relay            中转 / 端口转发菜单
  relay add        添加中转（本机入口 → 落地节点）
  relay forward    添加端口转发（TCP/UDP → 目标地址:端口）
  relay list       查看中转/转发和分享链接
  relay del [名称] 删除中转/转发
  port [名称] [新端口]  修改节点端口（UUID、密钥、密码、指纹都不变；支持 Xray 节点）
  xray [add|check|status|restart|log]  管理 Xray sidecar（首次 add 自动安装官方内核）
  fp [名称] [指纹] 修改节点的 TLS 指纹（可多个，如 chrome,firefox 或 all），每个指纹一条分享链接
  check            校验 sing-box 配置
  status           查看版本、服务状态和监听端口
  restart          重启 sing-box
  log [行数]       查看 sing-box 日志（默认最后 100 行）
  firewall         查看防火墙放行说明
  update           从 GitHub 下载最新版脚本并更新 sb
  shortcut         创建或刷新 sb 快捷命令
  remove-shortcut  删除 sb 快捷命令（不影响 sing-box 和节点）
  version          显示脚本版本

非交互选项（跟在上面的添加类命令后面）：
  -y, --yes, --non-interactive   不提问，没给的参数用默认值
  --tag / --name <名称>          节点名称（默认自动生成，如 reality-1）
  --port <端口>                  端口（默认自动选空闲端口）
  --sni <域名|auto>              Reality SNI；auto = 按出口地区扫描后自动选最快的
  --fps <chrome,firefox|all>     客户端 TLS 指纹（Reality / AnyTLS）
  --method <加密方式>            Shadowsocks 加密方式
  --domain / --tls-host <域名>   TLS 证书的域名或 IP（Trojan / Hysteria2 / TUIC / AnyTLS / Argo 命名隧道）
  --self-signed                  强制使用自签证书（默认就是自签）
  --cert <cert.pem> --key <key.pem>  使用已有证书（例如 acme.sh / Let's Encrypt）
  --proto <vmess|vless>          Argo 节点的 WebSocket 协议
  --quick                        Argo 快速隧道（trycloudflare.com）
  --token <TOKEN>                Argo 命名隧道 Token（配合 --domain）
  --tg-push                      创建节点后把它的分享链接推送到 Telegram（需要先 tg config）
  --path <路径>                  Argo 节点的 WebSocket 路径
  --region <US|JP|…>             SNI 扫描使用哪个地区的候选列表（默认按本机出口地区）
  --category <big-tech|cdn|dev|media|ecom|all>  SNI 扫描的分类
  --list <a.com,b.com> / --file <文件>  SNI 扫描的自定义域名列表
  --auto                         SNI 扫描后直接输出最快的域名
  --parallel <1-32>              SNI 扫描并发数（默认 6）

示例：
  $(self_cmd) add reality --sni auto --port 443 -y
  $(self_cmd) add trojan --domain vps.example.com --self-signed -y
  $(self_cmd) add hy2 --port 8443 -y
  $(self_cmd) add argo --proto vmess --quick -y
  $(self_cmd) add argo --proto vless --token <TOKEN> --domain argo.example.com -y
  $(self_cmd) scan-sni --region JP
  $(self_cmd) scan-sni --category dev --auto
TXT
}
add_single_inbound() {
  local choice
  echo "选择要添加的本机入站协议（直接回车默认 VLESS + Reality）："
  echo "1) VLESS + Reality 入站（Vision）[默认]"
  echo "2) Hysteria2"
  echo "3) TUIC"
  echo "4) AnyTLS"
  echo "5) Shadowsocks"
  echo "6) Telegram SOCKS5（不支持 MTProto）"
  echo "7) VLESS + TLS 入站（域名连接；Xray；默认 XHTTP auto）"
  echo "8) VMess AEAD 入站（TCP；alterId=0）"
  echo "9) Trojan（TLS + 密码）"
  echo "10) Argo（Cloudflare Tunnel + VMess/VLESS WS）"
  if ! read -r -p "选择 [1-10，默认 1]: " choice; then
    echo "没有选择，已取消。"
    return 0
  fi
  case "${choice:-1}" in
    1) add_reality ;;
    2) add_hy2 ;;
    3) add_tuic ;;
    4) add_anytls ;;
    5) add_ss ;;
    6) add_telegram_socks ;;
    7) xray_add_node ;;
    8) add_vmess ;;
    9) add_trojan ;;
    10) add_argo ;;
    *) echo "无效选项，没有添加入站。" ;;
  esac
}
menu() {
  while true; do
    echo
    echo "========== sing-box 多协议管理 ${SCRIPT_VERSION} =========="
    echo "Telegram: https://t.me/tuiji_channel"
    echo "1) 添加单个本机入站（默认 VLESS + Reality 入站，可切换其他协议）"
    echo "2) 添加 Hysteria2"
    echo "3) 添加 TUIC"
    echo "4) 添加 AnyTLS"
    echo "5) 添加 Shadowsocks"
    echo "6) 添加 Telegram SOCKS5（不支持 MTProto）"
    echo "7) 查看节点"
    echo "8) 查看节点参数/分享链接"
    echo "9) 删除节点"
    echo "10) 校验配置"
    echo "11) 重启服务"
    echo "12) 查看状态/监听端口"
    echo "13) 查看日志"
    echo "14) 防火墙检查说明"
    echo "15) 修改服务器地址（重新生成分享链接）"
    echo "16) 更新脚本"
    echo "17) 中转 / 端口转发"
    echo "18) 修改节点 TLS 指纹（多指纹分享链接）"
    echo "19) 修改节点端口"
    echo "20) 添加本机 VLESS + TLS 入站（域名连接；Xray；默认 XHTTP auto）"
    echo "21) 批量添加全部 8 类节点并输出 v2rayNG / NekoBox 两组 Base64"
    echo "22) 自动选择并启用服务器 TCP BBR（需要确认）"
    echo "23) 查看管理脚本/节点数据/备份/日志占用"
    echo "24) 节点服务保活/看门狗（启用/状态/检查/停用）"
    echo "25) 查看 sing-box 入/出累计流量"
    echo "26) 添加 VMess AEAD（TCP；alterId=0）"
    echo "27) 添加 Trojan（TLS + 密码）"
    echo "28) 添加 Argo 节点（Cloudflare Tunnel + VMess/VLESS WS）"
    echo "29) Reality SNI 扫描（按地区/分类/自定义列表验证 TLS1.3、X25519、证书与 HTTP/2）"
    echo "30) Telegram 机器人（配置 / 测试 / 推送 / 启停 / 日志）"
    echo "31) 推送节点分享链接到 Telegram（全部或单个）"
    echo "0) 退出"
    read -r -p "选择 [0-31]: " choice || exit 0
    case "$choice" in
      1) add_single_inbound ;;
      2) add_hy2 ;;
      3) add_tuic ;;
      4) add_anytls ;;
      5) add_ss ;;
      6) add_telegram_socks ;;
      7) list_nodes ;;
      8) show_links ;;
      9) remove_node ;;
      10) check_config ;;
      11) svc_restart && echo "已重启 sing-box。" ;;
      12) status ;;
      13) svc_logs 100 ;;
      14) firewall_help ;;
      15) cmd_set_host; compgen -G "$RELAY_DIR/*.json" >/dev/null && relay_list ;;
      16) cmd_update; echo "请重新运行 sb 以使用新版本。"; exit 0 ;;
      17) relay_menu ;;
      18) cmd_fp ;;
      19) cmd_port ;;
      20) xray_add_node ;;
      21) add_all_protocols ;;
      22) cmd_bbr_apply ;;
      23) cmd_storage ;;
      24) watchdog_menu ;;
      25) cmd_traffic show ;;
      26) add_vmess ;;
      27) add_trojan ;;
      28) add_argo ;;
      29) cmd_scan_sni ;;
      30) tg_menu ;;
      31) tg_push ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
    pause
  done
}
need_jq() { have jq || die "缺少 jq。先运行：$(self_cmd) install"; }
prepare_manage() {
  need_jq
  check_no_conflicts
  need_sb
  init_config
  if (( SAMPLE_REMOVED || LEFTOVER_SVC )); then
    check_config && reload_service
    (( LEFTOVER_SVC )) && echo "已写入本脚本的 sing-box 服务文件并重启服务。"
  fi
  [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]] || install_shortcut
  if shortcut_is_ours && [[ ! -e "$SS_SHORTCUT" && ! -L "$SS_SHORTCUT" ]]; then
    install_ss_shortcut
  fi
}
main() {
  if [[ "${0##*/}" == sb5 && $# -eq 0 ]]; then set -- add-ss; fi
  parse_opts "$@"
  if opt_bool help; then usage; exit 0; fi
  if (( ${#PARGS[@]} )); then set -- "${PARGS[@]}"; else set --; fi
  case "${1:-menu}" in
    -h|--help|help) usage; exit 0 ;;
    version|-v|--version) echo "singbox-manager ${SCRIPT_VERSION}"; exit 0 ;;
  esac
  need_root
  detect_init
  case "${1:-menu}" in
    install)
      if [[ "$(uname -s)" == FreeBSD ]]; then
        have pkg || die "没有找到 FreeBSD pkg；请先在系统上初始化 pkg 后重试"
        echo "正在通过 FreeBSD 官方软件包安装 sing-box……"
        pkg install -y sing-box
        need_sb
        "$SB" version
        cat <<'TXT'
FreeBSD sing-box 软件包已安装。该脚本的管理菜单目前仍只支持 Debian/Ubuntu、AlmaLinux 和 Alpine；
FreeBSD 软件包自带 rc.d 服务，名称为 singbox，默认配置路径为 /usr/local/etc/sing-box.json。
TXT
        exit 0
      fi
      [[ -r /etc/os-release ]] || die "无法识别系统"
      . /etc/os-release
      is_supported_install_os || die "此安装器目前支持 Debian/Ubuntu 系、AlmaLinux/RHEL 兼容系和 Alpine"
      install_deps
      detect_init
      need_init
      check_no_conflicts      # 有其他 sing-box 脚本时，在安装任何东西之前停下
      install_singbox
      init_config
      check_config
      reload_service
      install_shortcut
      if shortcut_is_ours; then
        echo "安装完成。输入 sb 打开管理菜单。"
      else
        echo "安装完成。运行：$(self_cmd) menu"
      fi
      alias_notice
      ;;
    menu) prepare_manage; menu ;;
    5|ss|shadowsocks|add-ss|sb5) prepare_manage; add_ss ;;
    vmess|add-vmess) prepare_manage; add_vmess ;;
    trojan|add-trojan) prepare_manage; add_trojan ;;
    add|add-node)
      prepare_manage
      case "${2:-}" in
        reality|vless-reality) add_reality ;;
        hy2|hysteria2) add_hy2 ;;
        tuic) add_tuic ;;
        anytls) add_anytls ;;
        trojan) add_trojan ;;
        ss|shadowsocks|5) add_ss ;;
        vmess) add_vmess ;;
        argo|cloudflared) add_argo ;;
        tg|telegram|socks5) add_telegram_socks ;;
        xray|vless-tls) xray_add_node ;;
        "") add_single_inbound ;;
        *) die "未知协议：${2}（可用：reality、hy2、tuic、anytls、trojan、ss、vmess、argo、tg、xray）" ;;
      esac ;;
    argo) cmd_argo "${2:-add}" "${3:-}" "${4:-}" ;;
    scan-sni|sni-scan|sni|scan) cmd_scan_sni ;;
    relay)
      prepare_manage
      case "${2:-menu}" in
        menu) relay_menu ;;
        add) relay_add ;;
        forward|fwd) forward_add ;;
        list|ls) relay_list ;;
        del|rm|remove) relay_remove "${3:-}" ;;
        *) usage; exit 2 ;;
      esac ;;
    tg)
      # 不带子命令时保持原来的行为：添加 Telegram SOCKS5 节点
      if [[ -n "${2:-}" ]]; then cmd_tg "${2:-}" "${3:-}" "${4:-}"; else prepare_manage; add_telegram_socks; fi ;;
    tgbot) cmd_tg "${2:-menu}" "${3:-}" "${4:-}" ;;
    telegram|socks5) prepare_manage; add_telegram_socks ;;
    xray) prepare_manage
      case "${2:-status}" in
        add|node) xray_add_node ;;
        check) xray_prepare; xray_check_config ;;
        status) xray_status ;;
        restart) xray_restart_service && echo "已重启 Xray sidecar。" ;;
        log|logs) xray_logs "${3:-100}" ;;
        *) usage; exit 2 ;;
      esac ;;
    fp|fingerprint) need_jq; cmd_fp "${2:-}" "${*:3}" ;;
    port) prepare_manage; cmd_port "${2:-}" "${3:-}" ;;
    links) need_jq; show_links ;;
    add-all) prepare_manage; add_all_protocols ;;
    bbr) case "${2:-apply}" in apply|auto) cmd_bbr_apply ;; status|show) cmd_bbr_status ;; reset|off|remove) cmd_bbr_reset ;; *) usage; exit 2 ;; esac ;;
    storage|disk) cmd_storage ;;
    watchdog) case "${2:-menu}" in menu) watchdog_menu ;; enable|on) cmd_watchdog_enable ;; status|show) cmd_watchdog_status ;; check|run) cmd_watchdog_check "${3:-}" ;; disable|off|remove) cmd_watchdog_disable ;; loop) cmd_watchdog_loop ;; *) usage; exit 2 ;; esac ;;
    traffic) prepare_manage; cmd_traffic "${2:-show}" ;;
    traffic-monitor) need_jq; traffic_monitor ;;
    host) need_jq; cmd_set_host; if compgen -G "$RELAY_DIR/*.json" >/dev/null; then relay_list; fi ;;
    check) need_jq; check_no_conflicts; need_sb; check_config ;;
    status) status ;;
    restart) need_sb; svc_restart && echo "已重启 sing-box。" ;;
    log|logs) svc_logs "${2:-100}" ;;
    firewall) firewall_help ;;
    update) cmd_update ;;
    shortcut) install_shortcut ;;
    remove-shortcut) cmd_remove_shortcut ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
