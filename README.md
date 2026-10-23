# singbox

一个面向 Debian 13（systemd）的 sing-box 多协议节点管理脚本：一键安装 sing-box 内核，通过交互菜单添加、查看、删除节点，自动识别服务器公网 IP 并生成客户端分享链接。安装后输入 `sb` 就能打开管理菜单。

> 下面所有代码块里的命令都可以整行复制直接运行，不需要去掉任何序号或提示符。请先切换到 root：

```bash
sudo -i
```

## 安装

```bash
curl -fsSL -o singbox-manager.sh https://raw.githubusercontent.com/bossangs/singbox/main/singbox-manager.sh
chmod +x singbox-manager.sh
./singbox-manager.sh install
```

装好后打开管理菜单：

```bash
sb
```

`install` 会做这些事：

- 用 apt 安装依赖：`ca-certificates curl jq openssl iproute2`
- 先检查服务器上有没有其他 sing-box 一键脚本（见下文“已装过其他 sing-box 脚本”），有的话直接停下，不改动任何文件
- 如果还没有 sing-box，通过官方安装脚本 `https://sing-box.app/install.sh` 安装内核
- 生成初始配置 `/etc/sing-box/config.json`；如果官方安装包带了示例节点，会先备份再移除（见“注意事项”）
- 校验配置，启用并启动 `sing-box` systemd 服务
- 创建快捷命令 `sb`（`/usr/local/bin/sb`）

## 支持的协议

| 菜单 | 协议 | 传输 | 默认端口 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | VLESS + Reality | TCP | 443 | flow 为 `xtls-rprx-vision`，默认握手域名 `www.cloudflare.com`，自动生成 Reality 密钥对和 short_id |
| 2 | Hysteria2 | UDP | 8443 | 使用自签证书 |
| 3 | TUIC | UDP | 9443 | 拥塞控制 `bbr`，ALPN `h3`，使用自签证书 |
| 4 | AnyTLS | TCP | 10443 | 使用自签证书 |
| 5 | Shadowsocks | TCP | 11443 | 支持 `aes-128-gcm`（默认）、`aes-256-gcm`、`chacha20-ietf-poly1305`、`2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm` |

UUID、密码、密钥等凭据全部在添加节点时随机生成，脚本里没有写死任何密码。

## 管理菜单

```
========== sing-box 多协议管理 ==========
1) 添加 VLESS + Reality
2) 添加 Hysteria2
3) 添加 TUIC
4) 添加 AnyTLS
5) 添加 Shadowsocks
6) 查看节点
7) 查看节点参数/分享链接
8) 删除节点
9) 校验配置
10) 重启服务
11) 查看状态/监听端口
12) 查看日志
13) 防火墙检查说明
14) 修改服务器地址（重新生成分享链接）
15) 更新脚本
0) 退出
```

### 添加节点的流程

- 选择协议（1-5），输入节点名称（只能用字母、数字、下划线、短横线，最长 40 个字符）和端口。脚本会检查端口是否已被占用。
- 第一次添加节点时，脚本会**自动识别服务器公网 IP**（依次尝试多个 IPv4 查询服务，失败再试 IPv6，最后看本机网卡），并显示为默认值：直接回车就用这个 IP，也可以输入你的域名。地址会保存下来，之后不再询问。
- Reality 需要填写 SNI / 握手域名；Hysteria2、TUIC、AnyTLS 需要填写证书使用的域名或 IP（默认就是上一步的服务器地址）；Shadowsocks 需要选择加密方式。
- 脚本先备份当前配置，再写入新节点并用 `sing-box check` 校验。校验失败会自动恢复最近一次备份；通过则重启服务。
- 屏幕上会显示节点参数和分享链接，参数同时保存在 `/etc/sing-box/manager/<节点名>.json`。之后随时可以用菜单 7 或 `sb links` 再看。

### 服务器地址

查看所有节点的分享链接：

```bash
sb links
```

换了 IP、想改用域名、或者分享链接里的地址不对时，运行下面这条命令。它会重新识别公网 IP（回车确认，或输入域名），然后用新地址重新生成所有节点的分享链接：

```bash
sb host
```

IPv6 地址会自动在链接里加上方括号，例如 `vless://...@[2001:db8::1]:443`。

## 命令一览

| 命令 | 作用 |
| --- | --- |
| `sb` | 打开管理菜单 |
| `sb links` | 查看所有节点的参数和分享链接 |
| `sb host` | 修改服务器地址并重新生成分享链接 |
| `sb check` | 校验 sing-box 配置 |
| `sb status` | 查看 sing-box 版本、服务状态和监听端口 |
| `sb firewall` | 查看防火墙放行说明 |
| `sb update` | 从本仓库下载最新版脚本并更新 `sb` |
| `sb shortcut` | 创建或刷新 `sb` 快捷命令 |
| `sb remove-shortcut` | 删除 `sb` 快捷命令（不影响 sing-box 和节点） |
| `sb version` | 显示脚本版本 |
| `sb help` | 显示帮助 |

如果 `/usr/local/bin/sb` 已经被别的程序占用，脚本不会覆盖它，会提示你改用 `./singbox-manager.sh` 加上面的命令，例如 `./singbox-manager.sh links`。

## 更新脚本

```bash
sb update
```

## 从旧版本升级（已经装过本脚本的服务器）

旧版本没有 `sb`，而且如果当时在 IP 提示处直接回车，分享链接里会是 `YOUR_SERVER_IP`。下载新版并重新运行一次 `install` 就会：创建 `sb`、清理官方示例节点、保留你已有的节点（服务会重启一下）：

```bash
curl -fsSL -o singbox-manager.sh https://raw.githubusercontent.com/bossangs/singbox/main/singbox-manager.sh
chmod +x singbox-manager.sh
./singbox-manager.sh install
```

然后重新生成分享链接。脚本发现保存的是 `YOUR_SERVER_IP` 会自动重新识别公网 IP，回车确认即可：

```bash
sb links
```

## 已装过其他 sing-box 脚本

如果服务器上已经装过别的 sing-box 一键脚本（例如 233boy 的 sing-box 脚本，它也会占用 `sing-box` 和 `sb` 这两个命令），本脚本会停下并列出发现的痕迹，**不会自动删除任何东西**。两个脚本不能同时管理同一个 sing-box。

想继续用原来的脚本，就不要运行本脚本。要换成本脚本，请先确认旧节点已不再需要（清理后旧节点全部失效），然后按下面的顺序操作。

先备份，这一步不删除任何东西：

```bash
B=/root/old-singbox-$(date +%Y%m%d-%H%M%S).tar.gz
tar czf "$B" --ignore-failed-read /etc/sing-box /var/log/sing-box /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box@.service /lib/systemd/system/sing-box.service /usr/local/bin/sing-box /usr/local/bin/sb /root/.bashrc
chmod 600 "$B"
ls -lh "$B"
```

确认上面显示出了备份文件，再清理旧脚本：

```bash
systemctl disable --now sing-box
dpkg -s sing-box >/dev/null 2>&1 && apt-get purge -y sing-box
rm -rf /etc/sing-box /var/log/sing-box
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box@.service /lib/systemd/system/sing-box.service /usr/local/bin/sing-box /usr/local/bin/sb
sed -i.bak -e '\#^alias sb=/usr/local/bin/sing-box$#d' -e '\#^alias sing-box=/usr/local/bin/sing-box$#d' /root/.bashrc
systemctl daemon-reload
unalias sb sing-box 2>/dev/null; hash -r
```

然后在 `singbox-manager.sh` 所在目录重新安装：

```bash
./singbox-manager.sh install
```

说明：`tar` 提示某些文件 “Cannot stat” 是正常的，表示这台机器上本来就没有那个文件。`sed` 那一行只删除 233boy 脚本加进 `/root/.bashrc` 的两条别名，原文件另存为 `/root/.bashrc.bak`。

如果 233boy 脚本还装了 Caddy（存在 `/etc/caddy/233boy` 目录），它通常占用 80/443 端口，会和 Reality 默认的 443 冲突。确定不再需要时，先备份再停用：

```bash
C=/root/old-caddy-$(date +%Y%m%d-%H%M%S).tar.gz
tar czf "$C" --ignore-failed-read /etc/caddy /lib/systemd/system/caddy.service /usr/local/bin/caddy
systemctl disable --now caddy
```

## 防火墙

脚本**不会**自动修改防火墙，你需要只放行实际使用的端口：

- Reality / AnyTLS / Shadowsocks：TCP
- Hysteria2 / TUIC：UDP

使用 UFW 时的示例（按你实际的节点端口修改）：

```bash
ufw allow 443/tcp
ufw allow 8443/udp
ufw allow 9443/udp
ufw allow 10443/tcp
ufw allow 11443/tcp
```

别忘了同时检查 VPS 服务商后台的云防火墙 / 安全组。通过 SSH 远程操作时，先确认 SSH 端口已经放行，再启用 UFW，以免把自己锁在外面。

## 注意事项

- **官方示例节点**：sing-box 官方安装包会附带一个示例配置，里面有一个监听 8080 端口的 Shadowsocks 节点，密码是公开的。本脚本在安装和打开菜单时会先备份配置，再把这个示例节点移除。
- **自签证书**：Hysteria2、TUIC、AnyTLS 共用一张自签证书（`/etc/sing-box/certs/`，RSA 2048，有效期 825 天），只在第一次需要时生成。客户端需要开启“允许不安全证书 / insecure”，分享链接里已经带上这个参数。
- **AnyTLS 链接格式**：不同客户端对 `anytls://` 链接的参数要求可能不一样，导入前请对照客户端文档。
- **凭据文件**：`/etc/sing-box/manager/*.json` 包含节点密码等敏感信息，只有 root 可读，请勿外传。
- **自动备份**：每次添加或删除节点前，旧配置都会备份到 `/var/backups/sing-box-manager/config-时间戳.json`。

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/sb` | 快捷命令（本脚本的副本） |
| `/etc/sing-box/config.json` | sing-box 主配置 |
| `/etc/sing-box/manager/` | 节点凭据和服务器地址（`server-host`） |
| `/etc/sing-box/certs/` | 自签证书 |
| `/var/backups/sing-box-manager/` | 配置备份 |
| `/etc/systemd/system/sing-box.service` | systemd 服务（只在官方安装包没有提供时才由脚本创建） |

## 常用排查命令

```bash
systemctl status sing-box
```

```bash
journalctl -u sing-box -n 100 --no-pager
```

```bash
sing-box check -c /etc/sing-box/config.json
```

```bash
ss -lntup
```
