# singbox

一个 sing-box 多协议节点管理脚本，支持 **Debian / Ubuntu（systemd）** 和 **Alpine Linux（OpenRC）**：一键安装 sing-box 内核，通过交互菜单添加、查看、删除节点，自动识别服务器公网 IP 并生成客户端分享链接，还可以把一台 VPS 设置成**中转**（流量转到落地服务器）或做**端口转发**。安装后输入 `sb` 就能打开管理菜单。

> 下面所有代码块里的命令都可以整行复制直接运行，不需要去掉任何序号或提示符。请先切换到 root：

```bash
sudo -i
```

## 安装

### Debian / Ubuntu

```bash
curl -fsSL -o singbox-manager.sh https://raw.githubusercontent.com/bossangs/singbox/main/singbox-manager.sh
chmod +x singbox-manager.sh
./singbox-manager.sh install
```

### Alpine Linux

Alpine 默认没有 bash 和 curl，先装上这两个，其余步骤一样：

```bash
apk add bash curl
curl -fsSL -o singbox-manager.sh https://raw.githubusercontent.com/bossangs/singbox/main/singbox-manager.sh
chmod +x singbox-manager.sh
./singbox-manager.sh install
```

装好后打开管理菜单：

```bash
sb
```

`install` 会做这些事：

- 安装依赖。Debian / Ubuntu 用 apt 装 `ca-certificates curl jq openssl iproute2`；Alpine 用 apk 装 `bash ca-certificates curl jq openssl iproute2 coreutils findutils tar grep sed openrc`（Alpine 自带的是精简版工具，脚本需要完整版）
- 先检查服务器上有没有其他 sing-box 一键脚本（见下文“已装过其他 sing-box 脚本”），有的话直接停下，不改动任何文件
- 如果还没有 sing-box，安装最新版内核，最新版本号直接从 GitHub 发布页读取，不受 GitHub API 次数限制：
  - Debian / Ubuntu：用官方安装脚本 `https://sing-box.app/install.sh` 装官方 deb 包；没装成时改用官方发布的压缩包
  - Alpine：依次尝试官方发布的压缩包（musl 版，装到 `/usr/bin/sing-box`）→ 官方 apk 包 → Alpine 软件源里的 sing-box。官方 apk 包在 Alpine 3.21 等较老版本上会报 `IO ERROR`，所以优先用压缩包。每一步装完都会实际运行一次 sing-box 确认能用，才算成功
  - 如果 `/usr/bin/sing-box` 已经存在（例如你自己从官方压缩包装好的），就直接使用它，只创建配置、服务和 `sb`
- 生成初始配置 `/etc/sing-box/config.json`；如果官方安装包带了示例节点，会先备份再移除（见“注意事项”）
- 校验配置，设置开机自启并启动 `sing-box` 服务（Debian 用 systemd，Alpine 用 OpenRC）
- 创建快捷命令 `sb`（`/usr/local/bin/sb`）

## 支持的协议

| 菜单 | 协议 | 传输 | 默认端口 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | VLESS + Reality | TCP | 443 | flow 为 `xtls-rprx-vision`，默认握手域名 `www.cloudflare.com`，自动生成 Reality 密钥对和 short_id；可选多个 TLS 指纹 |
| 2 | Hysteria2 | UDP | 8443 | 使用自签证书 |
| 3 | TUIC | UDP | 9443 | 拥塞控制 `bbr`，ALPN `h3`，使用自签证书 |
| 4 | AnyTLS | TCP | 10443 | 使用自签证书；可选多个 TLS 指纹 |
| 5 | Shadowsocks | TCP | 11443 | 支持 `aes-128-gcm`（默认）、`aes-256-gcm`、`chacha20-ietf-poly1305`、`2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm` |
| 6 | Telegram SOCKS5 | TCP | 1080 | sing-box SOCKS5 入站，自动生成用户名和密码；**不支持 MTProto** |

UUID、密码、密钥等凭据全部在添加节点时随机生成，脚本里没有写死任何密码。
Telegram 内置代理支持 SOCKS5 和 MTProto；本脚本只通过 sing-box 提供兼容的 SOCKS5，不会把它称作 MTProto。

## 管理菜单

```
========== sing-box 多协议管理 ==========
Telegram: https://t.me/o2oyww
1) 添加 VLESS + Reality
2) 添加 Hysteria2
3) 添加 TUIC
4) 添加 AnyTLS
5) 添加 Shadowsocks
6) 添加 Telegram SOCKS5（不支持 MTProto）
7) 查看节点
8) 查看节点参数/分享链接
9) 删除节点
10) 校验配置
11) 重启服务
12) 查看状态/监听端口
13) 查看日志
14) 防火墙检查说明
15) 修改服务器地址（重新生成分享链接）
16) 更新脚本
17) 中转 / 端口转发
18) 修改节点 TLS 指纹（多指纹分享链接）
19) 修改节点端口
0) 退出
```

### 添加节点的流程

- 选择协议（1-6）并设置端口，脚本会检查端口是否已被占用。Telegram SOCKS5 名称会自动从本地 sing-box 入站 tag 生成；没有合适 tag 时回退到服务器地址/主机名，并可选自定义名称（直接回车使用自动名称）。其他协议仍按提示输入名称。
- 第一次添加节点时，脚本会**自动识别服务器公网 IP**（依次尝试多个 IPv4 查询服务，失败再试 IPv6，最后看本机网卡），并显示为默认值：直接回车就用这个 IP，也可以输入你的域名。地址会保存下来，之后不再询问。
- Reality 和 AnyTLS 会让你选择客户端 TLS 指纹，可以选多个或 `all`，直接回车就是 `chrome`（见下文“TLS 指纹”）。
- Reality 需要填写 SNI / 握手域名；Hysteria2、TUIC、AnyTLS 需要填写证书使用的域名或 IP（默认就是上一步的服务器地址）；Shadowsocks 需要选择加密方式。
- Telegram SOCKS5 会生成随机用户名和密码，并输出 Telegram 官方 `https://t.me/socks?...` 与 `tg://socks?...` 一键添加链接，同时保留手动参数。
- 脚本先备份当前配置，再写入新节点并用 `sing-box check` 校验。校验失败会自动恢复最近一次备份；通过则重启服务。
- 屏幕上会显示节点参数、分享链接或手动配置字段，参数同时保存在 `/etc/sing-box/manager/<节点名>.json`。之后随时可以用菜单 8 或 `sb links` 再看。

### Telegram 内置代理（SOCKS5）

添加节点：

```bash
sb tg
```

默认无需手动填写节点名称：管理器优先读取本机现有 sing-box 入站 tag，自动生成唯一的 Telegram 节点名；没有可用 tag 时，会用服务器地址或主机名生成，并提供可选的自定义输入，直接回车即可使用自动名称。自动名称重合时会递增。Telegram 手机端通常在“设置 → 数据和存储 → 代理设置 → 添加代理 → SOCKS5”中填写管理器显示的服务器地址、端口、用户名和密码；不同 Telegram 客户端的菜单位置可能略有区别。请在防火墙和云安全组中放行该节点的 TCP 端口（默认 `1080/tcp`）。脚本不会自动开放端口。

添加节点后，终端会显示 `https://t.me/socks?...` 和 `tg://socks?...` 两种官方 SOCKS5 深链。之后运行 `sb links`，找到 Telegram SOCKS5 节点，点击 HTTPS 链接或复制到 Telegram 打开并确认添加；也可以使用 `tg://` 应用深链，或按下方字段手动填写。若终端没有自动识别为可点击链接，直接复制整行即可。

两种一键链接都包含服务器地址和登录凭据；请像密码一样保管，不要公开粘贴或转发给不信任的人。参数已按 URL 编码，Telegram 打开链接后会自动解析。

此功能是 sing-box 的 SOCKS5 服务端，不是 Telegram 的 MTProto 代理；若你需要 MTProto，本脚本当前无法创建该类型节点。SOCKS5 凭据可使用于其他支持 SOCKS5 的客户端，也应按敏感信息保管。

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

## TLS 指纹（多指纹分享链接）

VLESS + Reality 和 AnyTLS 节点可以设置一个或多个客户端 TLS 指纹（uTLS `fp`），每个指纹生成一条分享链接，名称是 `节点名-指纹`，例如 `reality-1-chrome`、`reality-1-firefox`。只选一个指纹时，链接名称就是节点名本身。

可选的指纹：`chrome`、`firefox`、`safari`、`ios`、`android`、`edge`、`360`、`qq`、`random`、`randomized`（每次连接随机）。

- **Reality 不支持 `android` 和 `360`**：这两个指纹没有 Reality 需要的 TLS 1.3 X25519 密钥交换，客户端会连不上（sing-box 报 `nil ecdheKey`）。选了也会被自动跳过，`all` 对 Reality 是可用的 8 种。
- **AnyTLS** 10 种都可以用。
- **Hysteria2、TUIC、Shadowsocks** 不使用 uTLS 指纹（前两个走 QUIC，Shadowsocks 没有 TLS），无需设置。

添加节点时会直接让你选。已有的节点随时可以修改，**只改分享链接，UUID、密钥、端口和服务端配置都不变**，正在使用的客户端不受影响。

查看所有节点的指纹并选择要修改的节点：

```bash
sb fp
```

打开某个节点的指纹菜单（添加 / 删除 / 重新选择）：

```bash
sb fp reality-1
```

直接把一个节点设成几个指纹（覆盖原来的列表）：

```bash
sb fp reality-1 chrome,firefox,safari,ios
```

一个节点输出所有可用指纹的链接：

```bash
sb fp reality-1 all
```

改完后查看每个指纹的分享链接：

```bash
sb links
```

老节点没有设置过指纹时：Reality 链接按 `chrome` 显示（和以前一样），AnyTLS 链接不带 `fp`。

## 修改节点端口

已有节点可以直接换端口，**UUID、密钥、密码和指纹都不变**，只是端口变了。中转入口和端口转发也可以这样改。

查看节点后按提示选择节点和新端口（直接回车使用推荐的空闲端口）：

```bash
sb port
```

直接把一个节点改到指定端口，例如把 `reality-1` 改成 `2443`：

```bash
sb port reality-1 2443
```

改完后查看新的分享链接：

```bash
sb links
```

脚本会自动做这些事：

- 检查新端口是 1-65535 的数字，没有被本脚本的其他节点、中转、端口转发占用，也没有被其他程序占用。按协议检查对应的端口类型：Reality / AnyTLS 查 TCP，Hysteria2 / TUIC 查 UDP，Shadowsocks 查 TCP 和 UDP。
- 先备份配置，用 `sing-box check` 校验，再重启 sing-box，并确认 sing-box 真的在新端口上监听。任何一步失败都会恢复原配置，节点继续用原来的端口。
- 改完后输出新的分享链接（多指纹节点每个指纹一条），并提醒放行新端口（TCP 或 UDP）。
- 如果本机有端口转发或中转指向这个节点的旧端口，会一起改成新端口。

改完端口后还需要你自己做：

- 在防火墙和云服务商的安全组里放行新端口，例如 `ufw allow 2443/tcp`（Hysteria2 / TUIC 用 `/udp`）。旧端口可以关闭。
- 正在使用的客户端重新导入新链接，或者把客户端里的端口改成新端口。
- 如果**其他服务器**上有中转或端口转发把这个节点当作落地，脚本无法知道，需要在那台机器上删除旧中转，再用新链接重新添加。

## 中转和端口转发

在**中转机**（客户端连接的那台 VPS）上运行本脚本。落地机可以是任何 sing-box / Xray 节点，也可以是另一台装了本脚本的服务器。打开中转菜单：

```bash
sb relay
```

```
========== 中转 / 端口转发 ==========
1) 添加中转（客户端用本脚本的协议连本机，流量转到落地节点）
2) 添加端口转发（TCP/UDP 原样转发到目标地址:端口）
3) 查看中转/转发和分享链接
4) 删除中转/转发
0) 返回
```

### 中转：客户端 → 中转机 → 落地机

中转机上新建一个入口节点，这个入口收到的流量全部从落地节点出去；**其他节点不受影响，仍然从中转机直连**。

```bash
sb relay add
```

操作流程：

- **粘贴落地节点的分享链接**。支持 `vless://`（Reality / TLS / 无加密，tcp / ws / grpc / http / httpupgrade）、`hysteria2://` 或 `hy2://`、`tuic://`、`anytls://`、`ss://`，本脚本生成的链接都能直接用。在落地机上运行 `sb links` 就能看到它的链接。
- 没有链接时直接回车，改为**手动填写**：选择落地协议，再填地址、端口、UUID / 密码等。
- 落地是 TCP 协议（VLESS、AnyTLS、Shadowsocks）时，脚本会测试从中转机能不能连上落地端口，连不上只提示，不会阻止添加。
- 选择**中转入口协议**（客户端连接中转机用的协议，1-5，和添加普通节点一样），填写名称和端口。名称默认是 `relay-reality-1`、`relay-hy2-1` 这样的格式。
- 脚本先备份配置，再添加入口、落地出站和只针对这个入口的路由规则，用 `sing-box check` 校验，失败自动恢复。
- 屏幕上会显示**给客户端用的分享链接**，地址是中转机的公网 IP。客户端导入这个链接即可。

### 端口转发：中转机端口 → 目标地址:端口

把中转机某个端口收到的 TCP / UDP 流量原样转发到目标，不解密，适合转发任意节点或服务。

```bash
sb relay forward
```

- 目标可以填 `地址:端口`（例如 `1.2.3.4:443`，IPv6 写成 `[2001:db8::1]:443`），也可以**直接粘贴落地节点的分享链接**。
- 选择转发协议 `tcp`、`udp` 或 `both`。粘贴链接时会自动给出默认值：Hysteria2 / TUIC 用 `udp`，VLESS / AnyTLS 用 `tcp`，Shadowsocks 用 `both`。
- 本机监听端口默认和目标端口相同（被占用时自动换一个空闲端口）。
- 粘贴的是分享链接时，脚本会生成**换成中转机地址和端口的新链接**，客户端直接导入；填的是 `地址:端口` 时，客户端使用落地节点原来的配置，只把地址和端口改成中转机的。

### 查看和删除

查看所有中转、转发以及客户端分享链接：

```bash
sb relay list
```

删除一个中转或转发（会同时删除它的入口、落地出站和路由规则，不影响其他节点）：

```bash
sb relay del relay-reality-1
```

不带名称时会先列出所有中转/转发，再让你输入名称：

```bash
sb relay del
```

记得在中转机的防火墙放行入口端口：中转按入口协议放行（见“防火墙”），端口转发按添加时选择的 `tcp` / `udp` / `both` 放行。落地机上对应的端口也要允许中转机访问。

## 命令一览

| 命令 | 作用 |
| --- | --- |
| `sb` | 打开管理菜单 |
| `sb tg` | 添加 Telegram SOCKS5 节点（不支持 MTProto） |
| `sb links` | 查看所有节点的参数和分享链接 |
| `sb host` | 修改服务器地址并重新生成分享链接 |
| `sb relay` | 中转 / 端口转发菜单 |
| `sb relay add` | 添加中转（本机入口 → 落地节点） |
| `sb relay forward` | 添加端口转发（TCP/UDP → 目标地址:端口） |
| `sb relay list` | 查看中转/转发和分享链接 |
| `sb relay del 名称` | 删除中转/转发 |
| `sb port` | 修改节点端口（按提示选择） |
| `sb port 名称 新端口` | 直接把节点改到新端口，UUID、密钥、密码、指纹都不变 |
| `sb fp` | 查看并修改节点的 TLS 指纹 |
| `sb fp 名称 chrome,firefox` | 把节点设为这几个指纹，每个指纹一条分享链接（`all` 表示全部可用指纹） |
| `sb check` | 校验 sing-box 配置 |
| `sb status` | 查看 sing-box 版本、服务状态和监听端口 |
| `sb restart` | 重启 sing-box |
| `sb log` | 查看 sing-box 日志（默认最后 100 行，例如 `sb log 300`） |
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

### 旧脚本已经删掉，只剩残留：自动清理

如果你已经卸载或手动删掉了旧脚本（例如 233boy 的 sing-box 脚本），但还留着下面这些东西，`install` 和打开菜单时会**先备份、再自动清理**，然后继续安装，不需要你手动处理：

- 失效的 `/usr/local/bin/sing-box`、`/usr/local/bin/sb` 链接（指向已经不存在的旧脚本）
- `/root/.bashrc` 里旧脚本加的 `alias sb=/usr/local/bin/sing-box` 和 `alias sing-box=/usr/local/bin/sing-box`（它们会让 `sb` 报 “No such file or directory”）
- 启动程序已经不存在的 sing-box 服务文件（systemd 的 `sing-box.service`，或 Alpine 的 `/etc/init.d/sing-box`）。清理后脚本会写入自己的服务文件并重启服务
- 旧脚本留下的空目录 `/etc/sing-box/sh`、`bin`、`conf`

备份保存在 `/root/singbox-leftovers-时间戳.tar.gz`。你的节点配置不会被改动。

如果清理掉了别名，当前这个终端里旧别名可能还在生效，运行下面这一行（或者重新登录 SSH）后再用 `sb`：

```bash
unalias sb sing-box 2>/dev/null; hash -r
```

### 旧脚本还在使用：脚本会停下

如果旧脚本还在使用（它的程序目录、节点目录、管理命令、服务或配置还在），本脚本会停下并列出发现的痕迹，**不会自动删除任何东西**。两个脚本不能同时管理同一个 sing-box。想继续用原来的脚本，就不要运行本脚本。

要换成本脚本，按屏幕上打印的命令操作。脚本会按你的系统（systemd 或 OpenRC）打印对应的命令，下面是 Debian 上的例子。第一段只做备份，不删除任何东西：

```bash
B=/root/old-singbox-$(date +%Y%m%d-%H%M%S).tar.gz
tar czf "$B" --ignore-failed-read /etc/sing-box /var/log/sing-box /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box@.service /lib/systemd/system/sing-box.service /usr/local/bin/sing-box /usr/local/bin/sb /root/.bashrc
chmod 600 "$B"
ls -lh "$B"
```

Alpine 上备份命令里的服务文件是 `/etc/init.d/sing-box /etc/conf.d/sing-box`，停止服务用 `rc-service sing-box stop`，卸载用 `apk del sing-box`，以屏幕上打印的为准。

接下来分两种情况，脚本会自动判断并打印对应的命令：

**`/etc/sing-box/config.json` 已经是本脚本的格式**（例如你已经用本脚本加过节点）：会保留这份配置和你的节点，只删除旧脚本的部分。打印出的命令类似这样（具体路径以屏幕上为准）：

```bash
systemctl stop sing-box
rm -rf /etc/sing-box/sh /etc/sing-box/bin /etc/sing-box/conf /usr/local/bin/sing-box /usr/local/bin/sb
sed -i.bak -E '\#^alias (sb|sing-box)=/usr/local/bin/sing-box$#d' /root/.bashrc
unalias sb sing-box 2>/dev/null; hash -r
./singbox-manager.sh install
```

**配置还是旧脚本的格式**：旧脚本的节点会全部失效，请先确认不再需要，然后运行：

```bash
systemctl disable --now sing-box
dpkg -s sing-box >/dev/null 2>&1 && apt-get purge -y sing-box
rm -rf /etc/sing-box /var/log/sing-box
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box@.service /lib/systemd/system/sing-box.service /usr/local/bin/sing-box /usr/local/bin/sb
sed -i.bak -E '\#^alias (sb|sing-box)=/usr/local/bin/sing-box$#d' /root/.bashrc
systemctl daemon-reload
unalias sb sing-box 2>/dev/null; hash -r
./singbox-manager.sh install
```

说明：`tar` 提示某些文件 “Cannot stat” 是正常的，表示这台机器上本来就没有那个文件。`sed` 那一行只删除旧脚本加进 `/root/.bashrc` 的两条别名，原文件另存为 `/root/.bashrc.bak`。

如果 233boy 脚本还装了 Caddy（存在 `/etc/caddy/233boy` 目录），它通常占用 80/443 端口，会和 Reality 默认的 443 冲突。确定不再需要时，先备份再停用：

```bash
C=/root/old-caddy-$(date +%Y%m%d-%H%M%S).tar.gz
tar czf "$C" --ignore-failed-read /etc/caddy /lib/systemd/system/caddy.service /usr/local/bin/caddy
systemctl disable --now caddy
```

## 防火墙

脚本**不会**自动修改防火墙，你需要只放行实际使用的端口：

- Reality / AnyTLS / Shadowsocks / Telegram SOCKS5：TCP
- Hysteria2 / TUIC：UDP
- 端口转发：按添加时选择的 `tcp` / `udp` / `both` 放行

使用 UFW 时的示例（按你实际的节点端口修改）：

```bash
ufw allow 443/tcp
ufw allow 8443/udp
ufw allow 9443/udp
ufw allow 10443/tcp
ufw allow 11443/tcp
ufw allow 1080/tcp
```

Alpine 通常没有 UFW，默认也不拦截入站。如果你自己配置了 iptables / nftables，可以用下面的命令查看现有规则：

```bash
iptables -S
```

```bash
nft list ruleset
```

别忘了同时检查 VPS 服务商后台的云防火墙 / 安全组。通过 SSH 远程操作时，先确认 SSH 端口已经放行，再启用防火墙，以免把自己锁在外面。

## 注意事项

- **官方示例节点**：sing-box 官方安装包（deb 和 apk 都一样）会附带一个示例配置，里面有一个监听 8080 端口的 Shadowsocks 节点，密码是公开的。本脚本在安装和打开菜单时会先备份配置，再把这个示例节点移除。
- **自签证书**：Hysteria2、TUIC、AnyTLS 共用一张自签证书（`/etc/sing-box/certs/`，RSA 2048，有效期 825 天），只在第一次需要时生成。客户端需要开启“允许不安全证书 / insecure”，分享链接里已经带上这个参数。
- **AnyTLS 链接格式**：不同客户端对 `anytls://` 链接的参数要求可能不一样，导入前请对照客户端文档。
- **凭据文件**：`/etc/sing-box/manager/*.json` 包含节点密码等敏感信息，只有 root 可读，请勿外传。中转记录里也保存了落地节点的信息。
- **自动备份**：每次添加或删除节点、中转、转发前，旧配置都会备份到 `/var/backups/sing-box-manager/config-时间戳.json`。
- **Alpine 日志**：OpenRC 下 sing-box 的日志写在 `/var/log/sing-box.log`，超过 20MB 时，重启服务会只保留最后 5000 行。

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/sb` | 快捷命令（本脚本的副本） |
| `/etc/sing-box/config.json` | sing-box 主配置 |
| `/etc/sing-box/manager/` | 节点凭据和服务器地址（`server-host`） |
| `/etc/sing-box/manager/relays/` | 中转和端口转发记录 |
| `/etc/sing-box/certs/` | 自签证书 |
| `/var/backups/sing-box-manager/` | 配置备份 |
| `/etc/systemd/system/sing-box.service` | Debian：systemd 服务（只在官方安装包没有提供时才由脚本创建） |
| `/etc/init.d/sing-box` | Alpine：OpenRC 服务（优先使用官方 apk 包自带的，没有时由脚本创建） |
| `/etc/conf.d/sing-box` | Alpine：OpenRC 服务设置（脚本在这里加上日志文件位置） |
| `/var/log/sing-box.log` | Alpine：sing-box 日志 |

## 常用排查命令

不分系统都能用：

```bash
sb status
```

```bash
sb log
```

```bash
sb check
```

```bash
ss -lntup
```

Debian / Ubuntu：

```bash
systemctl status sing-box
```

```bash
journalctl -u sing-box -n 100 --no-pager
```

Alpine：

```bash
rc-service sing-box status
```

```bash
tail -n 100 /var/log/sing-box.log
```
