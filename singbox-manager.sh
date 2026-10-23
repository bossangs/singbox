#!/usr/bin/env bash
# sing-box-manager.sh — Debian 13 / systemd sing-box multi-protocol manager
# Supports VLESS + Reality, Hysteria2, TUIC, AnyTLS, Shadowsocks.
# Existing configs are backed up before each change. Firewall rules are not changed automatically.

set -Eeuo pipefail
umask 077

APP="singbox-manager"
CONF="/etc/sing-box/config.json"
DATA="/etc/sing-box/manager"
CERT_DIR="/etc/sing-box/certs"
BACKUP_DIR="/var/backups/sing-box-manager"
SERVICE="sing-box"

die() { echo "错误：$*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo -i"; }
have() { command -v "$1" >/dev/null 2>&1; }
pause() { read -r -p "按回车继续..." _ || true; }
random_hex() { openssl rand -hex "${1:-8}"; }
new_uuid() { sing-box generate uuid; }
prompt() { local __var="$1" __label="$2" __default="${3:-}"; local __v; if [[ -n "$__default" ]]; then read -r -p "$__label [$__default]: " __v; __v="${__v:-$__default}"; else read -r -p "$__label: " __v; fi; printf -v "$__var" '%s' "$__v"; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_tag() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || die "节点名称仅允许字母、数字、下划线和短横线，最长 40 字符"; }
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
  if ! have sing-box; then
    echo "正在通过 sing-box 官方安装脚本安装内核……"
    curl -fsSL https://sing-box.app/install.sh -o /tmp/sing-box-install.sh
    bash /tmp/sing-box-install.sh
    rm -f /tmp/sing-box-install.sh
  fi
  have sing-box || die "未找到 sing-box，请检查官方安装是否成功"
  sing-box version
}
init_config() {
  mkdir -p "$(dirname "$CONF")" "$DATA" "$CERT_DIR" "$BACKUP_DIR"
  if [[ ! -f "$CONF" ]]; then
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
  fi
  jq -e '.inbounds | type == "array"' "$CONF" >/dev/null || die "$CONF 不是预期的 sing-box 配置（inbounds 数组缺失）"
}
check_config() {
  sing-box check -c "$CONF"
}
reload_service() {
  if systemctl list-unit-files "${SERVICE}.service" --no-legend 2>/dev/null | grep -q "${SERVICE}.service"; then
    systemctl enable "$SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE"
  else
    cat >/etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$SERVICE"
  fi
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
  prompt TLS_HOST "证书中的域名或服务器 IP（自签证书，客户端将使用 insecure）" ""
  [[ -n "$TLS_HOST" ]] || die "域名/IP 不能为空"
  local san
  if [[ "$TLS_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
add_reality() {
  local tag port sni uuid keys priv pub sid obj
  prompt tag "节点名称" "reality-1"
  valid_tag "$tag"
  prompt port "TCP 端口" "443"
  check_port "$port" tcp
  prompt sni "Reality SNI/握手域名" "www.cloudflare.com"
  uuid="$(new_uuid)"
  keys="$(sing-box generate reality-keypair)"
  priv="$(awk '/PrivateKey:/ {print $2; exit}' <<<"$keys")"
  pub="$(awk '/PublicKey:/ {print $2; exit}' <<<"$keys")"
  [[ -n "$priv" && -n "$pub" ]] || die "无法解析 sing-box reality-keypair 输出：$keys"
  sid="$(random_hex 8)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" \
    '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$sid]}}}')"
  apply_json "$obj"
  jq -n --arg tag "$tag" --arg uuid "$uuid" --arg host "$(public_host)" --arg port "$port" --arg sni "$sni" --arg pub "$pub" --arg sid "$sid" \
    '{protocol:"VLESS + Reality",tag:$tag,server:$host,port:($port|tonumber),uuid:$uuid,flow:"xtls-rprx-vision",security:"reality",sni:$sni,public_key:$pub,short_id:$sid}' | tee "$DATA/${tag}.json"
  echo "分享链接（标准 VLESS Reality URI）："
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
    "$uuid" "$(public_host)" "$port" "$sni" "$pub" "$sid" "$tag"
}
add_hy2() {
  local tag port password obj
  prompt tag "节点名称" "hy2-1"
  valid_tag "$tag"
  prompt port "UDP 端口" "8443"
  check_port "$port" udp
  ask_tls_host
  password="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" \
    '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}],tls:{enabled:true,certificate_path:"/etc/sing-box/certs/server.crt",key_path:"/etc/sing-box/certs/server.key"}}')"
  apply_json "$obj"
  jq -n --arg tag "$tag" --arg host "$(public_host)" --argjson port "$port" --arg password "$password" --arg sni "$TLS_HOST" \
    '{protocol:"Hysteria2",tag:$tag,server:$host,port:$port,password:$password,sni:$sni,insecure:true}' | tee "$DATA/${tag}.json"
  printf '分享链接（自签证书，客户端需允许不安全证书）：\nhysteria2://%s@%s:%s/?insecure=1&sni=%s#%s\n' \
    "$password" "$(public_host)" "$port" "$TLS_HOST" "$tag"
}
add_tuic() {
  local tag port uuid password obj
  prompt tag "节点名称" "tuic-1"
  valid_tag "$tag"
  prompt port "UDP 端口" "9443"
  check_port "$port" udp
  ask_tls_host
  uuid="$(new_uuid)"
  password="$(openssl rand -hex 24)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" \
    '{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$password}],congestion_control:"bbr",tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/server.crt",key_path:"/etc/sing-box/certs/server.key"}}')"
  apply_json "$obj"
  jq -n --arg tag "$tag" --arg host "$(public_host)" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --arg sni "$TLS_HOST" \
    '{protocol:"TUIC",tag:$tag,server:$host,port:$port,uuid:$uuid,password:$password,sni:$sni,insecure:true}' | tee "$DATA/${tag}.json"
  printf '分享链接（自签证书，客户端需允许不安全证书）：\ntuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=%s#%s\n' \
    "$uuid" "$password" "$(public_host)" "$port" "$TLS_HOST" "$tag"
}
add_anytls() {
  local tag port password obj
  prompt tag "节点名称" "anytls-1"
  valid_tag "$tag"
  prompt port "TCP 端口" "10443"
  check_port "$port" tcp
  ask_tls_host
  password="$(openssl rand -hex 24)"
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" \
    '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user",password:$password}],tls:{enabled:true,certificate_path:"/etc/sing-box/certs/server.crt",key_path:"/etc/sing-box/certs/server.key"}}')"
  apply_json "$obj"
  jq -n --arg tag "$tag" --arg host "$(public_host)" --argjson port "$port" --arg password "$password" --arg sni "$TLS_HOST" \
    '{protocol:"AnyTLS",tag:$tag,server:$host,port:$port,password:$password,sni:$sni,insecure:true}' | tee "$DATA/${tag}.json"
  printf '分享链接（不同客户端 URI 参数可能不同，请核对客户端文档）：\nanytls://%s@%s:%s/?insecure=1&sni=%s#%s\n' \
    "$password" "$(public_host)" "$port" "$TLS_HOST" "$tag"
}
add_ss() {
  local tag port password method obj
  prompt tag "节点名称" "ss-1"
  valid_tag "$tag"
  prompt port "TCP 端口" "11443"
  check_port "$port" tcp
  prompt method "加密方式" "aes-128-gcm"
  case "$method" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) ;; *) die "暂不接受该加密方式；请使用 aes-128-gcm、aes-256-gcm、chacha20-ietf-poly1305 或对应的 2022-blake3 方法" ;; esac
  case "$method" in
    2022-blake3-aes-128-gcm) password="$(openssl rand -base64 16 | tr -d '\n')" ;;
    2022-blake3-aes-256-gcm) password="$(openssl rand -base64 32 | tr -d '\n')" ;;
    *) password="$(openssl rand -hex 24)" ;;
  esac
  obj="$(jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" --arg password "$password" \
    '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$password}')"
  apply_json "$obj"
  jq -n --arg tag "$tag" --arg host "$(public_host)" --argjson port "$port" --arg method "$method" --arg password "$password" \
    '{protocol:"Shadowsocks",tag:$tag,server:$host,port:$port,method:$method,password:$password}' | tee "$DATA/${tag}.json"
  local userinfo
  userinfo="$(printf '%s' "${method}:${password}" | base64 -w0)"
  printf '分享链接：\nss://%s@%s:%s#%s\n' "$userinfo" "$(public_host)" "$port" "$tag"
}
public_host() {
  local h
  h="$(cat "$DATA/server-host" 2>/dev/null || true)"
  if [[ -z "$h" ]]; then
    read -r -p "请输入 VPS 公网 IP 或域名（用于生成分享链接）: " h
    [[ -n "$h" ]] || h="YOUR_SERVER_IP"
    printf '%s' "$h" >"$DATA/server-host"
    chmod 600 "$DATA/server-host"
  fi
  printf '%s' "$h"
}
list_nodes() {
  echo "已配置的入站节点："
  jq -r '.inbounds[]? | [.tag, .type, (.listen_port|tostring), (.listen // "0.0.0.0")] | @tsv' "$CONF" |
    awk 'BEGIN{printf "%-24s %-16s %-8s %s\n","TAG","协议","端口","监听地址"} {printf "%-24s %-16s %-8s %s\n",$1,$2,$3,$4}'
  echo
  echo "凭据文件（含敏感信息，权限仅 root 可读）：$DATA/*.json"
}
remove_node() {
  local tag
  list_nodes
  prompt tag "要删除的节点 tag" ""
  valid_tag "$tag"
  [[ -n "$tag" ]] || die "tag 不能为空"
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
  local f
  shopt -s nullglob
  local files=("$DATA"/*.json)
  ((${#files[@]})) || { echo "尚无节点凭据文件。"; return; }
  for f in "${files[@]}"; do
    echo "===== $(basename "$f") ====="
    jq . "$f"
  done
}
status() {
  echo "=== sing-box 版本 ==="
  sing-box version || true
  echo "=== systemd 状态 ==="
  systemctl --no-pager --full status "$SERVICE" || true
  echo "=== 端口监听 ==="
  ss -lntup
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
menu() {
  while true; do
    echo
    echo "========== sing-box 多协议管理 =========="
    echo "1) 添加 VLESS + Reality"
    echo "2) 添加 Hysteria2"
    echo "3) 添加 TUIC"
    echo "4) 添加 AnyTLS"
    echo "5) 添加 Shadowsocks"
    echo "6) 查看节点"
    echo "7) 查看节点凭据/分享参数"
    echo "8) 删除节点"
    echo "9) 校验配置"
    echo "10) 重启服务"
    echo "11) 查看状态/监听端口"
    echo "12) 查看日志"
    echo "13) 防火墙检查说明"
    echo "0) 退出"
    read -r -p "选择 [0-13]: " choice
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
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
    pause
  done
}
main() {
  need_root
  case "${1:-menu}" in
    install)
      [[ -r /etc/os-release ]] || die "无法识别系统"
      . /etc/os-release
      [[ "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]] || die "此安装器目前面向 Debian/Ubuntu 系"
      install_deps
      install_singbox
      init_config
      check_config
      if ! systemctl list-unit-files "${SERVICE}.service" --no-legend 2>/dev/null | grep -q "${SERVICE}.service"; then
        cat >/etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target
[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
      fi
      systemctl enable --now "$SERVICE"
      echo "安装完成。运行：$0 menu"
      ;;
    menu) have sing-box || die "未安装 sing-box。先运行：$0 install"; have jq || die "缺少 jq。先运行：$0 install"; init_config; menu ;;
    check) check_config ;;
    status) status ;;
    firewall) firewall_help ;;
    *) echo "用法：$0 {install|menu|check|status|firewall}"; exit 2 ;;
  esac
}
main "$@"
