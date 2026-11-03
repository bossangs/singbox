# sing-box 管理脚本：Xray / XHTTP 安装说明

## 安装包内容

压缩包包含更新后的 `singbox-manager.sh`、项目 `README.md`、本说明和 SHA-256 校验清单。安装包不含任何服务器配置、数据库、节点凭据、证书或私钥；Xray 内核在首次添加节点时按服务器 CPU 架构从官方发布页下载，并核验官方 `.dgst` 中的 SHA-256。脚本会先检测 `unzip`：Debian/Ubuntu 使用 `apt-get` 安装，Alpine 使用 `apk` 安装；若包索引过期，会刷新索引后重试。

## 安装或更新管理脚本

支持 Debian / Ubuntu 系和 Alpine Linux（OpenRC）。先把安装包传到服务器，再执行：

```bash
unzip singbox-manager-xray-xhttp-2026.11.03.3.zip -d singbox-xray-package
cd singbox-xray-package
sha256sum -c SHA256SUMS.txt
chmod +x singbox-manager.sh
sudo ./singbox-manager.sh install
```

已有本脚本的服务器重新运行 `install` 即可更新快捷命令 `sb`；原有 sing-box 节点和配置会保留。若 `/usr/local/bin/sb` 被其他程序占用，使用 `sudo ./singbox-manager.sh menu`，或在后续命令中以 `sudo ./singbox-manager.sh ...` 代替 `sb ...`。

## 添加默认 XHTTP 节点

运行：

```bash
sudo sb xray add
```

也可以打开 `sb` 管理菜单，选“添加 VLESS + TLS”。输入节点名称、TCP 端口和证书域名/IP；默认会尝试识别公网 IP。确认域名解析到本机后，可把证书名称改成自己的域名。传输选择菜单默认是 **XHTTP / auto**；路径和 Host 可直接使用脚本提供的默认值。其他选择包括 RAW/TCP、WebSocket、gRPC、HTTPUpgrade。Xray 上游已将后三种传输标记为弃用，因此优先推荐 XHTTP。

节点建好后，脚本会打印 VLESS 链接。请在系统防火墙和 VPS 云安全组放行屏幕显示的 **TCP 端口**；脚本不会自动改防火墙。传输协议、TLS 域名、XHTTP path 或 Host 改动后，客户端也必须使用相同参数。

Alpine/OpenRC 上 Xray 以专用非 root 用户运行，因此端口需选择 1024 或以上；默认端口符合要求。Debian/Ubuntu 的 systemd 服务配置了绑定低端口所需能力。

## 自签证书如何验证

每个 Xray 节点会生成一张独立 RSA 2048 自签证书，有效期 825 天。链接包含证书 SHA-256 指纹 pin（Xray URI 提案中的 `pcs` 参数）。这是校验指定证书指纹，不是关闭证书验证，也不需要把私钥发给客户端。

客户端必须能导入 `pcs` 参数，或允许手动填写同一证书指纹。若客户端忽略该字段，连接会因自签证书不受信任而失败；请改用支持 pin 的客户端，或在客户端配置受信任证书。不要仅为让连接成功而无条件启用 `insecure`。重建证书后指纹会改变，旧分享链接也需要重新导入。

## 管理与排查

```bash
sudo sb links                  # 查看所有 sing-box 与 Xray 节点及分享链接
sudo sb port 节点名称 新端口     # 修改 Xray 或 sing-box 节点端口
sudo sb xray status            # 查看 Xray 版本、服务及监听端口
sudo sb xray check             # 校验 Xray 配置
sudo sb xray restart           # 重启 Xray sidecar
sudo sb xray log 100           # 查看最后 100 行日志
sudo sb                           # 菜单中删除节点；Xray 删除会一并删除对应证书
```

Xray 节点配置变更前会在 `/var/backups/singbox-xray/` 留备份。若服务没有起来，可查看 `sb xray log`；Debian / Ubuntu 也可执行 `journalctl -u singbox-xray -n 100 --no-pager`，Alpine 可查看 `/var/log/singbox-xray.log`。

## 与已有 Xray / sing-box 的隔离

Xray sidecar 使用专用二进制 `/usr/local/bin/singbox-xray`、服务 `singbox-xray`、服务账号 `singbox-xray`、配置 `/etc/singbox-xray/config.json` 和独立证书目录。它不会覆盖 `/usr/local/bin/xray`、`xray.service`、`/usr/local/etc/xray/` 或 sing-box 主配置。若 sidecar 的同名服务文件已由其他程序占用，脚本会停止并保留原文件。

生成的 Xray `streamSettings` 只写 `network`：`xhttp`、`raw`、`ws`、`grpc` 或 `httpupgrade`，不同时写 `method`。Xray 官方解析器接受 `network`，但两者都存在时 `method` 会覆盖 `network`，因此只写一个字段可避免传输选择被意外覆盖。

Xray 节点和原有 sing-box 节点分别管理、分别备份，但都能通过 `sb links` 查看，也可用 `sb port` 和菜单删除。防火墙放行仍需手动完成。

## 本地版本更新说明

本包中的 Xray 改动仅在本地交付，没有推送到公开仓库。`sb update` 检测到远端脚本版本低于当前本地版本时会拒绝降级；保留 Xray 功能请继续从对应安装包更新，等公开版本包含该功能后再使用在线更新。
