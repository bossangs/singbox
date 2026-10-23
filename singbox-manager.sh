#!/usr/bin/env bash
# @bossangs-singbox-manager
# singbox-manager.sh — Debian 13 / systemd sing-box multi-protocol manager
# https://github.com/bossangs/singbox
# Supports VLESS + Reality, Hysteria2, TUIC, AnyTLS, Shadowsocks.
# Existing configs are backed up before each change. Firewall rules are not changed automatically.
# If another sing-box one-click script is detected, nothing is changed; cleanup steps are printed instead.

set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2026.10.23.2"
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

die() { echo "错误：$*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo -i"; }
have() { command -v "$1" >/dev/null 2>&1; }
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
CLEANED_ALIAS=0
OTHER_NAME="另一个 sing-box 一键脚本"
OTHER_CADDY=0
OLD_ALIAS_RE='^alias (sb|sing-box)=/usr/local/bin/sing-box$'
is_dangling() { [[ -L "$1" && ! -e "$1" ]]; }
dir_has_files() { [[ -d "$1" ]] && [[ -n "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]]; }
conf_is_ours() { [[ -f "$CONF" ]] && jq -e '.inbounds | type == "array"' "$CONF" >/dev/null 2>&1; }
pkg_owns() {
  # Debian 13 是 usr 合并布局：/lib 就是 /usr/lib，dpkg 里两种路径都可能出现
  local c
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
    rm -f "$f"
    [[ "$f" == *.service ]] && LEFTOVER_UNIT=1
  done
  for d in "${LEFTOVER_DIRS[@]}"; do rmdir "$d" 2>/dev/null || true; done
  if (( LEFTOVER_ALIAS )); then
    sed -i -E "\#${OLD_ALIAS_RE}#d" /root/.bashrc
    CLEANED_ALIAS=1
  fi
  (( LEFTOVER_UNIT )) && systemctl daemon-reload
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
  local item self keep=0 n=0 q
  self="./singbox-manager.sh"
  if conf_is_ours; then keep=1; n="$(jq '.inbounds | length' "$CONF")"; fi
  cat >&2 <<TXT

==================== 检测到其他 sing-box 脚本 ====================
这台服务器上还装着：${OTHER_NAME}
它和本脚本的配置格式、程序位置、systemd 服务都不一样，两个脚本不能同时管理同一个 sing-box。
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
tar czf "\$B" --ignore-failed-read /etc/sing-box /var/log/sing-box /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box@.service /lib/systemd/system/sing-box.service /usr/local/bin/sing-box /usr/local/bin/sb /root/.bashrc
chmod 600 "\$B"
ls -lh "\$B"

TXT
  if (( keep )); then
    q=""
    for item in "${FOREIGN_RM[@]}"; do q+=" $(printf '%q' "$item")"; done
    cat >&2 <<TXT
$CONF 已经是本脚本的格式（${n} 个节点），清理时会保留它，只删除其他脚本的部分。
确认上面显示出了备份文件，再运行：

systemctl stop sing-box
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

systemctl disable --now sing-box
dpkg -s sing-box >/dev/null 2>&1 && apt-get purge -y sing-box
rm -rf /etc/sing-box /var/log/sing-box
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box@.service /lib/systemd/system/sing-box.service /usr/local/bin/sing-box /usr/local/bin/sb
sed -i.bak -E '\#${OLD_ALIAS_RE}#d' /root/.bashrc
systemctl daemon-reload
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
check_port() {
  local p="$1" proto="$2"
  valid_port "$p" || die "端口必须是 1-65535 的数字"
  port_free "$p" "$proto" || die "端口 $p/$proto 已被占用，请换一个端口"
}
backup_config() {
  mkdir -p "$BACKUP_DIR" "$DATA" "$CERT_DIR"
  if [[ -f "$CONF" ]]; then
    cp -a "$CONF" "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"
  fi
}
install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq openssl iproute2
}
install_singbox() {
  if ! resolve_sb; then
    echo "正在通过 sing-box 官方安装脚本安装内核……"
    curl -fsSL https://sing-box.app/install.sh -o /tmp/sing-box-install.sh
    bash /tmp/sing-box-install.sh
    rm -f /tmp/sing-box-install.sh
  fi
  resolve_sb || die "未找到 sing-box 程序，请检查官方安装是否成功"
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
reload_service() {
  # 没有服务文件，或服务文件里的启动程序不是可用的 sing-box 时，写入本脚本的服务文件
  local exec_bin
  exec_bin="$(systemctl cat "${SERVICE}.service" 2>/dev/null | sed -n 's/^ExecStart=//p' | sed '/^[[:space:]]*$/d' | tail -n1 | awk '{print $1}' || true)"
  exec_bin="${exec_bin#[-@+!]}"
  if [[ -z "$exec_bin" ]] || ! is_elf "$(readlink -f "$exec_bin" 2>/dev/null || echo "$exec_bin")"; then
    write_unit
  fi
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"
}
apply_json() {
  local obj="$1"
  backup_config
  jq --argjson obj "$obj" '.inbounds += [$obj]' "$CONF" >"${CONF}.tmp"
  install -m 600 "${CONF}.tmp" "$CONF"
  rm -f "${CONF}.tmp"
  if ! check_config; then
    echo "配置校验失败，正在恢复备份。"
    local latest
    latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
    [[ -n "$latest" ]] && cp -a "$latest" "$CONF"
    die "sing-box 配置校验失败；已尝试恢复最近备份"
  fi
  reload_service
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

# ---------- 分享链接 ----------
print_link() {
  # 根据节点凭据文件生成分享链接（服务器地址取文件里的 server 字段）
  local f="$1" proto h userinfo
  proto="$(jq -r '.protocol' "$f")"
  h="$(uri_host "$(jq -r '.server' "$f")")"
  case "$proto" in
    "VLESS + Reality")
      echo "分享链接（标准 VLESS Reality URI）："
      jq -r --arg h "$h" '"vless://\(.uuid)@\($h):\(.port)?encryption=none&security=reality&sni=\(.sni)&fp=chrome&pbk=\(.public_key)&sid=\(.short_id)&type=tcp&flow=xtls-rprx-vision#\(.tag)"' "$f" ;;
    Hysteria2)
      echo "分享链接（自签证书，客户端需允许不安全证书）："
      jq -r --arg h "$h" '"hysteria2://\(.password)@\($h):\(.port)/?insecure=1&sni=\(.sni)#\(.tag)"' "$f" ;;
    TUIC)
      echo "分享链接（自签证书，客户端需允许不安全证书）："
      jq -r --arg h "$h" '"tuic://\(.uuid):\(.password)@\($h):\(.port)?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=\(.sni)#\(.tag)"' "$f" ;;
    AnyTLS)
      echo "分享链接（不同客户端 URI 参数可能不同，请核对客户端文档）："
      jq -r --arg h "$h" '"anytls://\(.password)@\($h):\(.port)/?insecure=1&sni=\(.sni)#\(.tag)"' "$f" ;;
    Shadowsocks)
      userinfo="$(jq -j '"\(.method):\(.password)"' "$f" | base64 -w0)"
      echo "分享链接："
      jq -r --arg h "$h" --arg u "$userinfo" '"ss://\($u)@\($h):\(.port)#\(.tag)"' "$f" ;;
    *) echo "（未知协议 $proto，无法生成分享链接）" ;;
  esac
}
save_node() {
  # $1：节点 tag；$2：凭据 JSON。保存后显示参数和分享链接
  local f="$DATA/$1.json"
  printf '%s\n' "$2" >"$f"
  chmod 600 "$f"
  jq . "$f"
  print_link "$f"
}

# ---------- 添加节点 ----------
add_reality() {
  local tag port sni uuid keys priv pub sid obj host
  prompt tag "节点名称" "reality-1"
  valid_tag "$tag"
  prompt port "TCP 端口" "443"
  check_port "$port" tcp
  prompt sni "Reality SNI/握手域名" "www.cloudflare.com"
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
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg uuid "$uuid" --arg host "$host" --argjson port "$port" --arg sni "$sni" --arg pub "$pub" --arg sid "$sid" \
    '{protocol:"VLESS + Reality",tag:$tag,server:$host,port:$port,uuid:$uuid,flow:"xtls-rprx-vision",security:"reality",sni:$sni,public_key:$pub,short_id:$sid}')"
}
add_hy2() {
  local tag port password obj host
  prompt tag "节点名称" "hy2-1"
  valid_tag "$tag"
  prompt port "UDP 端口" "8443"
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
  prompt tag "节点名称" "tuic-1"
  valid_tag "$tag"
  prompt port "UDP 端口" "9443"
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
  local tag port password obj host
  prompt tag "节点名称" "anytls-1"
  valid_tag "$tag"
  prompt port "TCP 端口" "10443"
  check_port "$port" tcp
  host="$(public_host)"
  ask_tls_host "$host"
  password="$(openssl rand -hex 24)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" \
    '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user",password:$password}],tls:{enabled:true,certificate_path:"/etc/sing-box/certs/server.crt",key_path:"/etc/sing-box/certs/server.key"}}')"
  apply_json "$obj"
  save_node "$tag" "$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg password "$password" --arg sni "$TLS_HOST" \
    '{protocol:"AnyTLS",tag:$tag,server:$host,port:$port,password:$password,sni:$sni,insecure:true}')"
}
add_ss() {
  local tag port password method obj host
  prompt tag "节点名称" "ss-1"
  valid_tag "$tag"
  prompt port "TCP 端口" "11443"
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
  jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONF" >/dev/null || die "未找到节点 $tag"
  backup_config
  jq --arg tag "$tag" '.inbounds |= map(select(.tag != $tag))' "$CONF" >"${CONF}.tmp"
  install -m 600 "${CONF}.tmp" "$CONF"
  rm -f "${CONF}.tmp" "$DATA/${tag}.json"
  check_config
  reload_service
  echo "已删除节点：$tag"
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
}
status() {
  echo "=== sing-box 版本 ==="
  if resolve_sb; then "$SB" version || true; else echo "未找到 sing-box 程序"; fi
  echo "=== systemd 状态 ==="
  systemctl --no-pager --full status "$SERVICE" || true
  echo "=== 端口监听 ==="
  ss -lntup || true
}
firewall_help() {
  cat <<'TXT'
本脚本不会自动修改防火墙。请仅放行你实际使用的节点端口：
  Reality / AnyTLS / Shadowsocks：TCP
  Hysteria2 / TUIC：UDP

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

同时检查 VPS 服务商后台的云防火墙/安全组。不要在 SSH 远程会话中盲目启用 UFW；
先确认 SSH 端口已放行，避免失去连接。
TXT
}
usage() {
  cat <<TXT
singbox-manager ${SCRIPT_VERSION}
用法：$(self_cmd) [命令]

  （不带命令）     打开管理菜单
  install          安装依赖、sing-box、systemd 服务和 sb 快捷命令
  menu             打开管理菜单
  links            查看所有节点的参数和分享链接
  host             修改服务器地址（自动识别公网 IP），并重新生成分享链接
  check            校验 sing-box 配置
  status           查看版本、服务状态和监听端口
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
    echo "6) 查看节点"
    echo "7) 查看节点参数/分享链接"
    echo "8) 删除节点"
    echo "9) 校验配置"
    echo "10) 重启服务"
    echo "11) 查看状态/监听端口"
    echo "12) 查看日志"
    echo "13) 防火墙检查说明"
    echo "14) 修改服务器地址（重新生成分享链接）"
    echo "15) 更新脚本"
    echo "0) 退出"
    read -r -p "选择 [0-15]: " choice || exit 0
    case "$choice" in
      1) add_reality ;;
      2) add_hy2 ;;
      3) add_tuic ;;
      4) add_anytls ;;
      5) add_ss ;;
      6) list_nodes ;;
      7) show_links ;;
      8) remove_node ;;
      9) check_config ;;
      10) systemctl restart "$SERVICE" ;;
      11) status ;;
      12) journalctl -u "$SERVICE" -n 100 --no-pager ;;
      13) firewall_help ;;
      14) cmd_set_host ;;
      15) cmd_update; echo "请重新运行 sb 以使用新版本。"; exit 0 ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
    pause
  done
}
need_jq() { have jq || die "缺少 jq。先运行：$(self_cmd) install"; }
main() {
  case "${1:-menu}" in
    -h|--help|help) usage; exit 0 ;;
    version|-v|--version) echo "singbox-manager ${SCRIPT_VERSION}"; exit 0 ;;
  esac
  need_root
  case "${1:-menu}" in
    install)
      [[ -r /etc/os-release ]] || die "无法识别系统"
      . /etc/os-release
      [[ "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]] || die "此安装器目前面向 Debian/Ubuntu 系"
      install_deps
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
    menu)
      need_jq
      check_no_conflicts
      need_sb
      init_config
      if (( SAMPLE_REMOVED )); then check_config && reload_service; fi
      [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]] || install_shortcut
      menu
      ;;
    links) need_jq; show_links ;;
    host) need_jq; cmd_set_host ;;
    check) need_jq; check_no_conflicts; need_sb; check_config ;;
    status) status ;;
    firewall) firewall_help ;;
    update) cmd_update ;;
    shortcut) install_shortcut ;;
    remove-shortcut) cmd_remove_shortcut ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
