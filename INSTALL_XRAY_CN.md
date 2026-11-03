# sing-box 管理脚本：Xray / XHTTP 安装说明

## 安装包内容

压缩包包含更新后的 `singbox-manager.sh`、项目 `README.md`、本说明和 SHA-256 校验清单。安装包不含任何服务器配置、数据库、节点凭据、证书或私钥；Xray 内核在首次添加节点时按服务器 CPU 架构从官方发布页下载，并核验官方 `.dgst` 中的 SHA-256。脚本会先检测 `unzip`：Debian/Ubuntu 使用 `apt-get` 安装，Alpine 使用 `apk` 安装；若包索引过期，会刷新索引后重试。

## 安装或更新管理脚本

支持 Debian / Ubuntu 系和 Alpine Linux（OpenRC）。先把安装包传到服务器，再执行：

```bash
unzip singbox-manager-xray-xhttp-2026.11.03.7.zip -d singbox-xray-package
cd singbox-xray-package
sha256sum -c SHA256SUMS.txt
chmod +x singbox-manager.sh
sudo ./singbox-manager.sh install
```

已有本脚本的服务器重新运行 `install` 即可更新快捷命令 `sb`；原有 sing-box 节点和配置会保留。本版本包含双客户端 Base64 汇总、服务器级 BBR、空间统计及**可选的节点服务看门狗**。看门狗不会在安装或创建节点时自动启用；需要时从管理菜单选 **24**，或运行 `sudo sb watchdog enable`。若 `/usr/local/bin/sb` 被其他程序占用，使用 `sudo ./singbox-manager.sh menu`，或在后续命令中以 `sudo ./singbox-manager.sh ...` 代替 `sb ...`。

## 添加默认 XHTTP 节点

运行：

```bash
sudo sb xray add
```

也可以打开 `sb` 管理菜单，选“添加 VLESS + TLS”。输入节点名称、TCP 端口和证书域名/IP；默认会尝试识别公网 IP。确认域名解析到本机后，可把证书名称改成自己的域名。传输选择菜单默认是 **XHTTP / auto**；路径和 Host 可直接使用脚本提供的默认值。其他选择包括 RAW/TCP、WebSocket、gRPC、HTTPUpgrade。Xray 上游已将后三种传输标记为弃用，因此优先推荐 XHTTP。

节点建好后，脚本会打印 VLESS 链接。请在系统防火墙和 VPS 云安全组放行屏幕显示的 **TCP 端口**；脚本不会自动改防火墙。传输协议、TLS 域名、XHTTP path 或 Host 改动后，客户端也必须使用相同参数。

若要一次添加脚本支持的全部协议节点，可在管理菜单选择 **21**，或运行 `sudo sb add-all`。脚本会逐项执行各协议的原有交互流程，依次添加 VLESS + Reality、Hysteria2、TUIC、AnyTLS、Shadowsocks、Telegram SOCKS5 和 Xray VLESS + TLS（默认 XHTTP auto），并在每项创建成功后显示分享链接。此操作会先要求输入 `y` 确认；节点分别提交，若中途失败，已成功创建的节点会保留，后续步骤停止。全部成功后，脚本输出两条按客户端分组的 Base64 导入内容：**v2rayNG** 包含 VLESS + Reality 和 Shadowsocks；**NekoBox/sing-box** 包含 VLESS + Reality、Hysteria2、TUIC、AnyTLS 和 Shadowsocks。Reality 与 Shadowsocks 会重复出现在两组中。Telegram SOCKS5 与 Xray VLESS + TLS/XHTTP 均排除，避免导入到不兼容的客户端。它们只是终端里的可复制文本，不是公网 URL，不会创建订阅服务。防火墙端口仍需手动放行。

Alpine/OpenRC 上 Xray 以专用非 root 用户运行，因此端口需选择 1024 或以上；默认端口符合要求。Debian/Ubuntu 的 systemd 服务配置了绑定低端口所需能力。

## 自签证书如何验证

每个 Xray 节点会生成一张独立 RSA 2048 自签证书，有效期 825 天。链接包含证书 SHA-256 指纹 pin（Xray URI 提案中的 `pcs` 参数）。这是校验指定证书指纹，不是关闭证书验证，也不需要把私钥发给客户端。

客户端必须能导入 `pcs` 参数，或允许手动填写同一证书指纹。若客户端忽略该字段，连接会因自签证书不受信任而失败；请改用支持 pin 的客户端，或在客户端配置受信任证书。不要仅为让连接成功而无条件启用 `insecure`。重建证书后指纹会改变，旧分享链接也需要重新导入。

## 管理与排查

```bash
sudo sb links                  # 查看所有 sing-box 与 Xray 节点及分享链接
sudo sb add-all                # 新增全部 7 类节点，最后输出 v2rayNG / NekoBox 两组 Base64
sudo sb port 节点名称 新端口     # 修改 Xray 或 sing-box 节点端口
sudo sb bbr                    # 服务器级 TCP BBR；内核支持时先确认再应用
sudo sb bbr status             # 查看 TCP 算法与 BBR 状态
sudo sb bbr reset              # 确认后恢复原算法并移除 BBR 配置
sudo sb storage                # 只读统计管理脚本、节点数据、备份与日志占用
sudo sb watchdog status        # 查看看门狗和服务监督状态
sudo sb watchdog enable        # 明确启用；OpenRC 官方服务可能提示短暂重启
sudo sb watchdog check         # 立即检查并尝试恢复 active 但监听异常的服务
sudo sb watchdog disable       # 停用看门狗；不删除节点、证书或密钥
sudo sb xray status            # 查看 Xray 版本、服务及监听端口
sudo sb xray check             # 校验 Xray 配置
sudo sb xray restart           # 重启 Xray sidecar
sudo sb xray log 100           # 查看最后 100 行日志
sudo sb                           # 菜单中删除节点；Xray 删除会一并删除对应证书
```

Xray 节点配置变更前会在 `/var/backups/singbox-xray/` 留备份。若服务没有起来，可查看 `sb xray log`；Debian / Ubuntu 也可执行 `journalctl -u singbox-xray -n 100 --no-pager`，Alpine 可查看 `/var/log/singbox-xray.log`。

## TCP BBR 与空间统计

菜单 **22** / `sudo sb bbr` 是服务器级 TCP 设置，不绑定任何节点。脚本只选择内核当前已注册的标准 `bbr`；若未注册，则不改动算法，也不安装第三方模块。确认应用后会保存当前算法，并分别在 systemd 或 OpenRC 的 sysctl 配置中持久化；`sudo sb bbr status` 查看，`sudo sb bbr reset` 可确认恢复。该功能不修改 qdisc、防火墙或 sing-box/Xray 服务。不同网络路径的最佳算法不一定相同；此自动模式只检查内核支持情况，不代表跑过测速或保证普遍最优。[Linux 上游 BBR 代码](https://github.com/torvalds/linux/blob/master/net/ipv4/tcp_bbr.c)说明可用 `fq` 队列调度器配合 BBR，但不使用时 TCP 会采用内部 pacing；脚本保留现有队列规则，避免扩大系统改动。

菜单 **23** / `sudo sb storage`（别名 `sudo sb disk`）按 `du -sk` 汇总管理脚本/快捷命令/服务文件、`/etc/sing-box`、Xray sidecar 与其内核、两处备份目录及日志文件。它只统计列出的管理器相关路径，不扫描整个系统，不包括 sing-box 主程序和操作系统文件，且不会清理任何内容。

## 节点服务保活/看门狗

看门狗是**手动选择的可选功能**：不会因安装脚本或新增节点而自动开启。管理菜单选 **24**，再选择启用、查看状态、立即检查或停用；也可运行 `sudo sb watchdog enable|status|check|disable`。

启用后，每分钟检查 sing-box 与本脚本管理的 Xray sidecar。只有服务仍处于运行状态、但配置中的一个或多个节点监听端口丢失时，才会尝试重启并复核。配置无法读取时不会盲目重启；管理员已手动停止的服务不会被自动拉起。此检查验证本机服务和端口，不代表公网连通，也不代替防火墙、安全组或 DNS 检查。

- **systemd**：启用后为现有 sing-box/Xray 服务增加 `Restart=always`、取消启动频率上限，并运行每分钟健康检查 timer；启用或停用不会重启节点服务。`systemctl stop` 手动停服仍有效。
- **OpenRC**：启用独立的健康检查服务。对 Alpine 官方 sing-box 服务，启用时会把 `respawn_max=0`（无限重生）写入 `/etc/conf.d/sing-box` 的专属管理块；该服务若正在运行，脚本会提示并征求同意，重启一次以应用设置。停用会移除管理器创建的服务和配置块；若要恢复官方原有重生限制，可能提示短暂重启。

若配置错误导致服务无法启动，systemd/OpenRC 的自动重试可能持续发生。先修复配置，或运行 `sudo sb watchdog disable` 停用看门狗；停用不会删除节点、证书或密钥。

看门狗无法防止主机断电、内核或整个服务管理器故障，也不一定能修复无效配置或端口被别的程序占用。相关依据：[systemd 服务重启语义](https://www.freedesktop.org/software/systemd/man/systemd.service.html)、[systemd 启动频率限制](https://www.freedesktop.org/software/systemd/man/systemd.unit.html)、[OpenRC supervise-daemon 指南](https://github.com/OpenRC/openrc/blob/master/supervise-daemon-guide.md)。

## 与已有 Xray / sing-box 的隔离

Xray sidecar 使用专用二进制 `/usr/local/bin/singbox-xray`、服务 `singbox-xray`、服务账号 `singbox-xray`、配置 `/etc/singbox-xray/config.json` 和独立证书目录。它不会覆盖 `/usr/local/bin/xray`、`xray.service`、`/usr/local/etc/xray/` 或 sing-box 主配置。若 sidecar 的同名服务文件已由其他程序占用，脚本会停止并保留原文件。

生成的 Xray `streamSettings` 只写 `network`：`xhttp`、`raw`、`ws`、`grpc` 或 `httpupgrade`，不同时写 `method`。Xray 官方解析器接受 `network`，但两者都存在时 `method` 会覆盖 `network`，因此只写一个字段可避免传输选择被意外覆盖。

Xray 节点和原有 sing-box 节点分别管理、分别备份，但都能通过 `sb links` 查看，也可用 `sb port` 和菜单删除。防火墙放行仍需手动完成。

## 版本更新说明

`sb update` 检测到远端脚本版本低于当前本地版本时会拒绝降级，以免丢失功能。公开版本包含所需功能后，可以使用在线更新；否则请从对应安装包更新。
