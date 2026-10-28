#!/usr/bin/env bash
# @bossangs-singbox-manager
# singbox-manager.sh — sing-box multi-protocol manager for Debian/Ubuntu (systemd) and Alpine (OpenRC)
# https://github.com/bossangs/singbox
# Supports VLESS + Reality, Hysteria2, TUIC, AnyTLS, Shadowsocks, Telegram SOCKS5, relays and port forwarding.
# Existing configs are backed up before each change. Firewall rules are not changed automatically.
# If another sing-box one-click script is detected, nothing is changed; cleanup steps are printed instead.

set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2026.10.28.2"
MARK="# @bossangs-singbox-manager"
RAW_URL="https://raw.githubusercontent.com/bossangs/singbox/main/singbox-manager.sh"
SHORTCUT="/usr/local/bin/sb"
CONF_DIR="/etc/sing-box"
CONF="$CONF_DIR/config.json"
DATA="$CONF_DIR/manager"
CERT_DIR="$CONF_DIR/certs"
BACKUP_DIR="/var/backups/sing-box-manager"
SERVICE="sing-box"
# sing-box 官方 deb/rpm 包自带示例配置里的 Shadowsocks 密码（公开的，不能留在线上）
OFFICIAL_SAMPLE_PW="Gn1JUS14bLUHgv1cWDDp4A=="
SB=""
OPENRC_INIT="/etc/init.d/sing-box"
OPENRC_CONFD="/etc/conf.d/sing-box"
SB_LOG="/var/log/sing-box.log"
INIT_SYS=""   # systemd / openrc / none

die() { echo "错误：$*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo -i"; }
have() { command -v "$1" >/dev/null 2>&1; }
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
fetch_latest() {
  # 下载最新脚本到 $1，并做语法和身份检查
  local dest="$1"
  curl -fsSL --max-time 30 "$RAW_URL" -o "$dest" || { rm -f "$dest"; die "下载失败：$RAW_URL"; }
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
  echo "已创建快捷命令：sb（$SHORTCUT）。以后直接输入 sb 打开管理菜单。"
  if grep -qE '^[[:space:]]*alias[[:space:]]+sb=' /root/.bashrc 2>/dev/null; then
    echo "注意：/root/.bashrc 里有 alias sb=...，会覆盖 sb 快捷命令。请删除那一行后重新登录。" >&2
  fi
}
cmd_update() {
  local tmp new_ver
  shortcut_is_foreign && die "$SHORTCUT 已被其他程序占用，未更新。"
  tmp="$(mktemp)"
  fetch_latest "$tmp"
  new_ver="$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$tmp" | head -n1)"
  install -m 755 "$tmp" "$SHORTCUT"
  rm -f "$tmp"
  echo "已更新 sb：${SCRIPT_VERSION} -> ${new_ver:-未知}。运行 sb 打开管理菜单。"
}
cmd_remove_shortcut() {
  if shortcut_is_ours; then
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
  # Debian 13 是 usr 合并布局：/lib 就是 /usr/lib，dpkg 里两种路径都可能出现
  local c
  if have apk && ! have dpkg; then
    apk info -q --who-owns "$1" >/dev/null 2>&1
    return
  fi
  have dpkg || return 1
  for c in "$1" "$(readlink -f "$1" 2>/dev/null || true)" "/usr${1#/usr}" "${1#/usr}"; do
    [[ -n "$c" ]] && dpkg -S "$c" >/dev/null 2>&1 && return 0
  done
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
    purge_cmd="dpkg -s sing-box >/dev/null 2>&1 && apt-get purge -y sing-box"
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
    apk add bash ca-certificates curl jq openssl iproute2 coreutils findutils tar grep sed openrc
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq openssl iproute2
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
ask_tls_host() {
  # $1：默认值（服务器地址）
  prompt TLS_HOST "证书中的域名或服务器 IP（自签证书，客户端将使用 insecure）" "${1:-}"
  [[ -n "$TLS_HOST" ]] || die "域名/IP 不能为空"
  local san
  if valid_ipv4 "$TLS_HOST" || valid_ipv6 "$TLS_HOST"; then
    san="IP:${TLS_HOST}"
  else
    san="DNS:${TLS_HOST}"
  fi
  if [[ ! -s "$CERT_DIR/server.crt" || ! -s "$CERT_DIR/server.key" ]]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
      -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
      -subj "/CN=${TLS_HOST}" -addext "subjectAltName=${san}" >/dev/null 2>&1
    chmod 600 "$CERT_DIR/server.key"
    chmod 644 "$CERT_DIR/server.crt"
  fi
}
tag_exists() {
  jq -e --arg t "$1" '[.inbounds[]?, .outbounds[]? | select(.tag == $t)] | length > 0' "$CONF" >/dev/null 2>&1 || [[ -e "$DATA/$1.json" ]]
}
next_tag() {
  local base="$1" n=1
  while tag_exists "${base}-${n}"; do n=$((n + 1)); done
  printf '%s-%s' "$base" "$n"
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
    "VLESS + Reality")
      if (( $(jq '(.fps // [.fp // "chrome"]) | length' "$f") > 1 )); then
        echo "分享链接（标准 VLESS Reality URI，每个指纹一条）："
      else
        echo "分享链接（标准 VLESS Reality URI）："
      fi
      jq -r --arg h "$h" '(.fps // [.fp // "chrome"]) as $fps | $fps[] as $fp
        | "vless://\(.uuid)@\($h):\(.port)?encryption=none&security=reality&sni=\(.sni)&fp=\($fp)&pbk=\(.public_key)&sid=\(.short_id)&type=tcp&flow=xtls-rprx-vision#\(.tag)\(if ($fps | length) > 1 then "-" + $fp else "" end)"' "$f" ;;
    Hysteria2)
      echo "分享链接（自签证书，客户端需允许不安全证书）："
      jq -r --arg h "$h" '"hysteria2://\(.password)@\($h):\(.port)/?insecure=1&sni=\(.sni)#\(.tag)"' "$f" ;;
    TUIC)
      echo "分享链接（自签证书，客户端需允许不安全证书）："
      jq -r --arg h "$h" '"tuic://\(.uuid):\(.password)@\($h):\(.port)?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=\(.sni)#\(.tag)"' "$f" ;;
    AnyTLS)
      echo "分享链接（不同客户端 URI 参数可能不同，请核对客户端文档）："
      jq -r --arg h "$h" '(.fps // (if .fp then [.fp] else [""] end)) as $fps | $fps[] as $fp
        | "anytls://\(.password)@\($h):\(.port)/?insecure=1&sni=\(.sni)\(if $fp != "" then "&fp=" + $fp else "" end)#\(.tag)\(if ($fps | length) > 1 then "-" + $fp else "" end)"' "$f" ;;
    Shadowsocks)
      userinfo="$(jq -j '"\(.method):\(.password)"' "$f" | base64 -w0)"
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
save_node() {
  # $1：节点 tag；$2：凭据 JSON。保存后显示参数和分享链接
  local f="$DATA/$1.json"
  jq --arg r "$RELAY_DESC" 'if $r != "" then . + {relay_to: $r} else . end' <<<"$2" >"$f"
  chmod 600 "$f"
  LAST_TAG="$1"
  jq . "$f"
  print_link "$f"
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

# ---------- 添加节点 ----------
add_reality() {
  local tag port sni uuid keys priv pub sid obj host fps
  ask_tag tag reality
  prompt port "TCP 端口" "$(free_port 443 tcp)"
  check_port "$port" tcp
  prompt sni "Reality SNI/握手域名" "www.cloudflare.com"
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
}
add_hy2() {
  local tag port password obj host
  ask_tag tag hy2
  prompt port "UDP 端口" "$(free_port 8443 udp)"
  check_port "$port" udp
  host="$(public_host)"
  ask_tls_host "$host"
  password="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" \
    '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}],tls:{enabled:true,certificate_path:"/etc/sing-box/certs/server.crt",key_path:"/etc/sing-box/certs/server.key"}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg password "$password" --arg sni "$TLS_HOST" \
    '{protocol:"Hysteria2",tag:$tag,server:$host,port:$port,password:$password,sni:$sni,insecure:true}')"
}
add_tuic() {
  local tag port uuid password obj host
  ask_tag tag tuic
  prompt port "UDP 端口" "$(free_port 9443 udp)"
  check_port "$port" udp
  host="$(public_host)"
  ask_tls_host "$host"
  uuid="$(new_uuid)"
  password="$(openssl rand -hex 24)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" \
    '{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$password}],congestion_control:"bbr",tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/server.crt",key_path:"/etc/sing-box/certs/server.key"}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --arg sni "$TLS_HOST" \
    '{protocol:"TUIC",tag:$tag,server:$host,port:$port,uuid:$uuid,password:$password,sni:$sni,insecure:true}')"
}
add_anytls() {
  local tag port password obj host fps
  ask_tag tag anytls
  prompt port "TCP 端口" "$(free_port 10443 tcp)"
  check_port "$port" tcp
  host="$(public_host)"
  ask_tls_host "$host"
  choose_fps fps chrome
  password="$(openssl rand -hex 24)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" \
    '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user",password:$password}],tls:{enabled:true,certificate_path:"/etc/sing-box/certs/server.crt",key_path:"/etc/sing-box/certs/server.key"}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg password "$password" --arg sni "$TLS_HOST" --argjson fps "$(fps_json "$fps")" \
    '{protocol:"AnyTLS",tag:$tag,server:$host,port:$port,password:$password,sni:$sni,insecure:true,fps:$fps}')"
}
add_ss() {
  local tag port password method obj host
  ask_tag tag ss
  prompt port "TCP 端口" "$(free_port 11443 tcp)"
  check_port "$port" tcp
  prompt method "加密方式" "aes-128-gcm"
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
}

add_telegram_socks() {
  local tag port username password obj host
  ask_tag tag tg-socks5
  prompt port "TCP 端口" "$(free_port 1080 tcp)"
  check_port "$port" tcp
  port="$((10#$port))"
  host="$(public_host)"
  username="$(openssl rand -hex 6)"
  password="$(openssl rand -hex 18)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg username "$username" --arg password "$password" \
    '{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:$username,password:$password}]}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg username "$username" --arg password "$password" \
    '{protocol:"Telegram SOCKS5",tag:$tag,server:$host,port:$port,username:$username,password:$password}')"
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
PARSED_OUT="" PARSED_DESC="" PARSED_PROTO=""
parse_share_link() {
  # 解析 vless / hysteria2 / hy2 / tuic / anytls / ss 链接，生成 sing-box 出站，结果放在 PARSED_OUT
  local link="$1" rest frag="" hp kv k v arr=() dec ui
  link="${link//[[:space:]]/}"
  [[ "$link" == *://* ]] || die "这不是分享链接（应以 vless:// hysteria2:// tuic:// anytls:// ss:// 开头）"
  L_SCHEME="${link%%://*}"; L_SCHEME="${L_SCHEME,,}"
  rest="${link#*://}"
  if [[ "$rest" == *"#"* ]]; then frag="${rest#*#}"; rest="${rest%%#*}"; fi
  : "$frag"
  L_QUERY=""
  if [[ "$rest" == *"?"* ]]; then L_QUERY="${rest#*\?}"; rest="${rest%%\?*}"; fi
  if [[ "$L_SCHEME" == ss && "$rest" != *@* ]]; then
    # 旧格式 ss://base64(method:password@host:port)
    dec="$(b64d "${rest%/}")"
    [[ "$dec" == *@* ]] || die "无法解析 ss 链接"
    L_UI="$(printf '%s' "${dec%@*}" | base64 -w0)"
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
    *) die "暂不支持 $L_SCHEME:// 链接（支持 vless、hysteria2/hy2、tuic、anytls、ss）" ;;
  esac
  PARSED_DESC="$PARSED_PROTO $(uri_host "$L_HOST"):$L_PORT"
}
manual_landing() {
  # 手动填写落地节点，拼成分享链接后交给 parse_share_link
  local c h p a b c2 d link
  echo "落地节点协议："
  echo "1) VLESS + Reality   2) Hysteria2   3) TUIC   4) AnyTLS   5) Shadowsocks"
  read -r -p "选择 [1-5]: " c || die "没有选择协议"
  prompt h "落地服务器地址（IP 或域名）" ""
  h="${h#[}"; h="${h%]}"
  valid_host "$h" || die "地址无效"
  prompt p "落地端口" ""
  valid_port "$p" || die "端口无效"
  h="$(uri_host "$h")"
  case "$c" in
    1) prompt a "UUID" ""; prompt b "SNI（握手域名）" "www.cloudflare.com"; prompt c2 "公钥 public_key（pbk）" ""; prompt d "short_id（sid，可留空）" " "
       d="${d// /}"
       link="vless://$(urlencode "$a")@${h}:${p}?encryption=none&security=reality&sni=$(urlencode "$b")&fp=chrome&pbk=$(urlencode "$c2")&sid=$(urlencode "$d")&type=tcp&flow=xtls-rprx-vision" ;;
    2) prompt a "密码" ""; prompt b "SNI（可留空）" " "; prompt d "允许不安全证书（自签证书选 y）[y/n]" "y"; b="${b// /}"
       link="hysteria2://$(urlencode "$a")@${h}:${p}/?sni=$(urlencode "$b")&insecure=$([[ "$d" == [yY]* ]] && echo 1 || echo 0)" ;;
    3) prompt a "UUID" ""; prompt c2 "密码" ""; prompt b "SNI（可留空）" " "; prompt d "允许不安全证书（自签证书选 y）[y/n]" "y"; b="${b// /}"
       link="tuic://$(urlencode "$a"):$(urlencode "$c2")@${h}:${p}?congestion_control=bbr&alpn=h3&sni=$(urlencode "$b")&allow_insecure=$([[ "$d" == [yY]* ]] && echo 1 || echo 0)" ;;
    4) prompt a "密码" ""; prompt b "SNI（可留空）" " "; prompt d "允许不安全证书（自签证书选 y）[y/n]" "y"; b="${b// /}"
       link="anytls://$(urlencode "$a")@${h}:${p}/?sni=$(urlencode "$b")&insecure=$([[ "$d" == [yY]* ]] && echo 1 || echo 0)" ;;
    5) prompt b "加密方式" "aes-128-gcm"; prompt a "密码" ""
       link="ss://$(printf '%s:%s' "$b" "$a" | base64 -w0)@${h}:${p}" ;;
    *) die "无效选项" ;;
  esac
  parse_share_link "$link"
}
read_landing() {
  local link
  echo "落地节点：粘贴分享链接（vless / hysteria2 / hy2 / tuic / anytls / ss），直接回车改为手动填写。"
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
    *'"type":"vless"'*|*'"type":"anytls"'*|*'"type":"shadowsocks"'*)
      if tcp_reachable "$landing_host" "$landing_port"; then echo "落地端口 TCP 可以连通。"
      else echo "提示：从本机连不上落地 ${landing_host}:${landing_port}（TCP），请确认落地节点在运行、防火墙已放行。仍会继续添加。"; fi ;;
  esac
  echo
  echo "中转入口协议（客户端连接本机时用的协议）："
  echo "1) VLESS + Reality   2) Hysteria2   3) TUIC   4) AnyTLS   5) Shadowsocks"
  read -r -p "选择 [1-5，默认 1]: " c || c=1
  RELAY_OUT="$PARSED_OUT"; RELAY_DESC="$PARSED_DESC"; TAG_PREFIX="relay-"; LAST_TAG=""
  case "${c:-1}" in
    1) add_reality ;; 2) add_hy2 ;; 3) add_tuic ;; 4) add_anytls ;; 5) add_ss ;;
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
    case "$L_SCHEME" in hysteria2|hy2|tuic) def_net=udp ;; vless|anytls) def_net=tcp ;; *) def_net=both ;; esac
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
    --arg scheme "$L_SCHEME" --arg ui "$L_UI" --arg path "$L_PATH" --arg q "$L_QUERY" \
    '{kind:"forward", tag:$tag, listen_port:$port, network:$net, target:$h, target_port:$tp}
     + (if $lm == 1 then {link:{scheme:$scheme, userinfo:$ui, path:$path, query:$q}} else {} end)' >"$meta"
  chmod 600 "$meta"
  echo
  echo "端口转发已添加：本机 ${port}/${net} → $(uri_host "$thost"):${tport}"
  print_forward_link "$meta" "$(public_host)"
  echo "请在防火墙放行本机端口 ${port}（${net}）。"
}
print_forward_link() {
  # 转发目标是分享链接时：把原链接的地址和端口换成本机，生成给客户端用的新链接
  local f="$1" h="$2"
  jq -e '.link' "$f" >/dev/null 2>&1 || {
    echo "客户端用法：使用落地节点原来的配置，只把地址改成 $h、端口改成 $(jq -r .listen_port "$f")。"
    return 0
  }
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
        jq --arg h "$host" '.server = $h' "$DATA/$(jq -r .tag "$f").json" >"$f.node.tmp"
        install -m 600 "$f.node.tmp" "$DATA/$(jq -r .tag "$f").json"; rm -f "$f.node.tmp"
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
  jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONF" >/dev/null || die "未找到节点 $tag"
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
  rm -f "$DATA/${tag}.json" "$RELAY_DIR/${tag}.json"
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
    *) echo "$tag 是 ${proto}：Hysteria2、TUIC 走 QUIC，Shadowsocks 没有 TLS，都不使用 uTLS 指纹，无需设置。"; return 0 ;;
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
list_nodes() {
  echo "已配置的入站节点："
  jq -r '.inbounds[]? | [(.tag // "-"), .type, (.listen_port|tostring), (.listen // "0.0.0.0")] | @tsv' "$CONF" |
    awk 'BEGIN{printf "%-24s %-16s %-8s %s\n","TAG","协议","端口","监听地址"} {printf "%-24s %-16s %-8s %s\n",$1,$2,$3,$4}'
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
  # 显示每个节点的参数和分享链接；服务器地址统一使用当前保存的地址
  local f host
  shopt -s nullglob
  local files=("$DATA"/*.json)
  shopt -u nullglob
  ((${#files[@]})) || { echo "尚无节点凭据文件。"; return 0; }
  host="$(public_host)"
  for f in "${files[@]}"; do
    if [[ "$(jq -r '.server // empty' "$f")" != "$host" ]]; then
      jq --arg h "$host" '.server = $h' "$f" >"$f.tmp" && install -m 600 "$f.tmp" "$f"
      rm -f "$f.tmp"
    fi
    echo "===== $(basename "$f" .json) ====="
    jq . "$f"
    print_link "$f"
    echo
  done
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
  Reality / AnyTLS / Shadowsocks / Telegram SOCKS5：TCP
  Hysteria2 / TUIC：UDP
  端口转发：按添加时选择的 tcp / udp / both 放行

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
usage() {
  cat <<TXT
singbox-manager ${SCRIPT_VERSION}
用法：$(self_cmd) [命令]

  （不带命令）     打开管理菜单
  install          安装依赖、sing-box、系统服务（systemd 或 OpenRC）和 sb 快捷命令
  menu             打开管理菜单
  tg               添加 Telegram SOCKS5 代理节点（不支持 MTProto）
  links            查看所有节点的参数和分享链接
  host             修改服务器地址（自动识别公网 IP），并重新生成分享链接
  relay            中转 / 端口转发菜单
  relay add        添加中转（本机入口 → 落地节点）
  relay forward    添加端口转发（TCP/UDP → 目标地址:端口）
  relay list       查看中转/转发和分享链接
  relay del [名称] 删除中转/转发
  port [名称] [新端口]  修改节点端口（UUID、密钥、密码、指纹都不变）
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
TXT
}
menu() {
  while true; do
    echo
    echo "========== sing-box 多协议管理 ${SCRIPT_VERSION} =========="
    echo "1) 添加 VLESS + Reality"
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
    echo "0) 退出"
    read -r -p "选择 [0-19]: " choice || exit 0
    case "$choice" in
      1) add_reality ;;
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
}
main() {
  case "${1:-menu}" in
    -h|--help|help) usage; exit 0 ;;
    version|-v|--version) echo "singbox-manager ${SCRIPT_VERSION}"; exit 0 ;;
  esac
  need_root
  detect_init
  case "${1:-menu}" in
    install)
      [[ -r /etc/os-release ]] || die "无法识别系统"
      . /etc/os-release
      [[ "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* || "${ID:-}" == "alpine" ]] || die "此安装器目前支持 Debian/Ubuntu 系和 Alpine"
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
    tg|telegram|socks5) prepare_manage; add_telegram_socks ;;
    fp|fingerprint) need_jq; cmd_fp "${2:-}" "${*:3}" ;;
    port) prepare_manage; cmd_port "${2:-}" "${3:-}" ;;
    links) need_jq; show_links ;;
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
