# xray-cf-lite

最小化代理节点 + Cloudflare 部署脚本，两个版本按需选择：

- **版本 A**：xray + Origin Rules（走公网 IP，NAT 环境也支持）
- **版本 B**：sing-box + Argo 隧道（临时 / 固定，无需公网 IP）

## 适用系统

- **Debian / Ubuntu / Alpine**，root 权限（其他发行版不保证）

## 前置依赖

按系统先装这几条，其余依赖（xray-core / sing-box / cloudflared 等）脚本自动安装：

**Debian / Ubuntu**

```bash
apt-get update && apt-get install -y curl jq bash
```

**Alpine**

```sh
apk add bash curl jq
```

Cloudflare 需要**域名已托管**：

- 版本 A：邮箱 + **Global API Key**
- 版本 B：临时隧道零配置；固定隧道用同样的邮箱 + Global API Key（隧道 / DNS 全自动创建）

## 快速开始

### 版本 A：DNS + Origin Rules（需公网 IP）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/xray_cf_lite.sh)
```

安装后自动创建快捷命令 `x`（任何系统可直接 `x` 调起最新版）。

### 版本 B：sing-box + Argo 隧道（无需公网 IP / 端口映射）

```bash
(curl -LfsS https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/singbox-lite_tunnel.sh -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/singbox-lite_tunnel.sh -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb
```

快捷命令：`sb`

### 两版本对比

| | 版本 A | 版本 B |
|---|---|---|
| 内核 | xray-core | sing-box |
| 接入方式 | DNS + Origin Rules（CF 主动连入站） | cloudflared 隧道（全出站） |
| 公网 IP / NAT | 需要 | 不需要 |
| 协议 | VLESS-WS | VLESS-WS / Trojan-WS |
| 平台防火墙 | **需放行节点端口**（如 AWS 安全组） | 无需放行 |
| 快捷命令 | `x` | `sb` |

## 版本 A（xray_cf_lite.sh）

### 主菜单

```
1. 安装节点        部署 xray + 自动配置 CF（DNS/SSL/Origin Rules）+ 生成节点链接
2. 删除节点        停止 xray + 精确清理本节点的 DNS / 证书 / Origin Rules（不碰全局配置）
3. 查看节点        节点链接 / 优选订阅
4. 修改配置        UUID / 端口 / WS 路径
5. 查看当前配置    域名、UUID、端口、xray 状态、节点链接
6. 更新外部端口    NAT 专用：只更新 CF Origin Rules，不重启 xray
7. 重启 xray       / 8. 切换网络模式(直连/NAT)
0. 卸载脚本        红字入口：自动删除已部署节点 -> 停止服务 -> 自删脚本文件
```

### 工作原理

```
客户端 → CF CDN (443/TLS) → Origin Rules（目标=源站外部端口）→ 源站 → xray
```

- 默认 **full strict**：自动生成 15 年免续期的 CF Origin CA 证书（也可选 flexible 明文模式）
- 输出单个 VLESS 节点链接；xray 崩溃自动重启（systemd / OpenRC）
- 支持直连公网 IP 与 NAT 端口映射两种网络模式

### 删除节点 / 卸载脚本清理范围

只清理**该节点自身**：本机 xray 配置、精确删除该二级域名的 DNS 解析、吊销该域名的 Origin CA 证书（新装节点按证书 ID，旧节点按 hostnames 兜底）、移除 Origin Rules 中引用该域名的规则、删本地证书文件。

**不碰任何 zone 级全局配置**（SSL 模式 / Security Level / Browser Check / Bot Fight），不影响同域名下其他节点。

## 版本 B（singbox-lite_tunnel.sh）

### 主要能力

- **临时隧道**：零配置，随机 `trycloudflare.com` 域名，重启失效
- **固定隧道**：邮箱 + Global API Key 全自动部署——隧道名 = 二级域名前缀、ingress 统一 `http://127.0.0.1:8080`、自动创建 DNS CNAME，删除/卸载时自动清理云端隧道与 DNS
- VLESS-WS / Trojan-WS 双协议；节点查看 / 删除 / 重启 / 日志
- 后台守护（Watchdog）每分钟自愈失效隧道；sing-box 核心安装带 SHA-256 校验与回滚
- systemd / OpenRC / direct 三种服务管理；`x86_64` `arm64` `armv7l`

### 主菜单

```
1. Argo 隧道节点管理（临时/固定）      5. 查看服务状态 / 日志
2. 安装/更新 sing-box 核心            6. 检查配置文件
3. 重启 sing-box 服务                 7. 更新脚本 / 8. 卸载脚本
4. 重启 Argo 隧道                     0. 退出
```

`[1]` 节点管理内含：创建 VLESS / Trojan 节点、查看节点信息 / 隧道日志、删除节点、卸载 Argo 服务。

### 数据位置

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/sb`、`/usr/local/bin/sing-box`、`/usr/local/bin/cloudflared` | 快捷命令与核心 |
| `/usr/local/etc/sing-box/config.json` | 主节点配置 |
| `/usr/local/etc/sing-box/cf_account.json` | CF 凭据（固定隧道自动部署/清理用） |
| `/usr/local/etc/sing-box/argo_metadata.json` | 节点元数据与分享链接 |
| `/var/log/sing-box.log`、`/var/log/singbox_argo_*.log` | 日志 |

## 注意事项

- **平台防火墙**：版本 A 走「CF 主动连入站」，AWS/GCP 等安全组默认全关的平台必须放行节点端口；版本 B 隧道全出站，无需放行
- 版本 A 安装时会临时调整 Bot Fight Mode / Security Level / Browser Check（zone 级全局设置）
- 一台服务器同时只支持一组部署（再次安装需先删除节点）
- AWS EC2 用「停止再启动」会更换公网 IP，绑 Elastic IP 才不变；IP 变化后重跑一次「删除节点 → 安装节点」即可重建解析
- 两个版本的状态文件均可能包含 UUID、密码、Token，请勿公开上传

