# singbox

一个面向 Debian 13（systemd）的 sing-box 多协议节点管理脚本：一键安装 sing-box 内核，通过交互菜单添加、查看、删除节点，并自动生成客户端分享链接。

## 支持的协议

| 菜单 | 协议 | 传输 | 默认端口 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | VLESS + Reality | TCP | 443 | flow 为 `xtls-rprx-vision`，默认握手域名 `www.cloudflare.com`，自动生成 Reality 密钥对和 short_id |
| 2 | Hysteria2 | UDP | 8443 | 使用自签证书 |
| 3 | TUIC | UDP | 9443 | 拥塞控制 `bbr`，ALPN `h3`，使用自签证书 |
| 4 | AnyTLS | TCP | 10443 | 使用自签证书 |
| 5 | Shadowsocks | TCP | 11443 | 支持 `aes-128-gcm`（默认）、`aes-256-gcm`、`chacha20-ietf-poly1305`、`2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm` |

UUID、密码、密钥等凭据全部在添加节点时随机生成，脚本里没有写死任何密码。

## 系统要求

- Debian 13（脚本也接受其他 Debian / Ubuntu 系发行版）
- systemd
- root 权限（先执行 `sudo -i`）

## 安装

```bash
curl -fsSL -o singbox-manager.sh https://raw.githubusercontent.com/bossangs/singbox/main/singbox-manager.sh
chmod +x singbox-manager.sh
./singbox-manager.sh install
```

`install` 会依次完成以下步骤：

1. 用 apt 安装依赖：`ca-certificates curl jq openssl iproute2`
2. 如果还没有 sing-box，通过官方安装脚本 `https://sing-box.app/install.sh` 安装内核
3. 生成初始配置 `/etc/sing-box/config.json`（只有 direct / block 出站，没有入站）
4. 校验配置，并启用、启动 `sing-box` systemd 服务

## 使用

安装完成后打开管理菜单：

```bash
./singbox-manager.sh menu
```

```
========== sing-box 多协议管理 ==========
1) 添加 VLESS + Reality
2) 添加 Hysteria2
3) 添加 TUIC
4) 添加 AnyTLS
5) 添加 Shadowsocks
6) 查看节点
7) 查看节点凭据/分享参数
8) 删除节点
9) 校验配置
10) 重启服务
11) 查看状态/监听端口
12) 查看日志
13) 防火墙检查说明
0) 退出
```

### 添加节点的流程

1. 选择协议（1-5），输入节点名称（tag，只能用字母、数字、下划线、短横线，最长 40 个字符）和端口。脚本会检查端口是否已被占用。
2. Reality 需要填写 SNI / 握手域名；Hysteria2、TUIC、AnyTLS 需要填写证书使用的域名或服务器 IP；Shadowsocks 需要选择加密方式。
3. 第一次添加节点时，脚本会询问 VPS 的公网 IP 或域名，用来生成分享链接。答案保存在 `/etc/sing-box/manager/server-host`，之后不再询问。
4. 脚本先备份当前配置，再写入新节点并用 `sing-box check` 校验。校验失败会自动恢复最近一次备份；校验通过则重启服务。
5. 屏幕上会输出节点参数和分享链接，同一份参数保存在 `/etc/sing-box/manager/<tag>.json`。之后随时可以用菜单 7 查看。

### 命令行参数

| 命令 | 作用 |
| --- | --- |
| `./singbox-manager.sh install` | 安装依赖、sing-box 内核和 systemd 服务 |
| `./singbox-manager.sh menu` | 打开交互菜单（不带参数时默认也是这个） |
| `./singbox-manager.sh check` | 校验 sing-box 配置 |
| `./singbox-manager.sh status` | 查看 sing-box 版本、服务状态和监听端口 |
| `./singbox-manager.sh firewall` | 查看防火墙放行说明 |

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

- **自签证书**：Hysteria2、TUIC、AnyTLS 共用一张自签证书（`/etc/sing-box/certs/`，RSA 2048，有效期 825 天），证书只在第一次需要时生成。客户端需要开启“允许不安全证书 / insecure”，分享链接里已经带上这个参数。
- **AnyTLS 链接格式**：不同客户端对 `anytls://` 链接的参数要求可能不一样，导入前请对照客户端文档。
- **凭据文件**：`/etc/sing-box/manager/*.json` 包含节点密码等敏感信息，只有 root 可读，请勿外传。
- **自动备份**：每次添加或删除节点前，旧配置都会备份到 `/var/backups/sing-box-manager/config-时间戳.json`。

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/etc/sing-box/config.json` | sing-box 主配置 |
| `/etc/sing-box/manager/` | 节点凭据和服务器地址 |
| `/etc/sing-box/certs/` | 自签证书 |
| `/var/backups/sing-box-manager/` | 配置备份 |
| `/etc/systemd/system/sing-box.service` | systemd 服务（只在官方安装包没有提供时才由脚本创建） |

## 常用排查命令

```bash
systemctl status sing-box          # 服务状态
journalctl -u sing-box -n 100      # 最近日志
sing-box check -c /etc/sing-box/config.json   # 校验配置
ss -lntup                          # 监听端口
```
