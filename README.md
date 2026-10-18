# xray-cf-lite

最小化代理节点 + Cloudflare 部署脚本。含两个版本：**版本 A（xray + Origin Rules，需公网 IP）** 与 **版本 B（sing-box + Argo 隧道，无需公网 IP）**。

## 适用场景

- NAT 小鸡（端口映射环境）
- Alpine / LXC 容器
- 低配机器（256MB 内存即可）

## 前置条件

- Linux（Debian/Ubuntu/Alpine/CentOS），root 权限，Bash 4+
- 脚本自动安装 `curl` / `jq` / `unzip` / `openssl` 等依赖，并自动下载对应核心（xray-core 或 sing-box / cloudflared）
- 支持 **systemd** 与 **OpenRC**（Alpine）
- Cloudflare：域名已托管
  - 版本 A：需账号邮箱 + **Global API Key**
  - 版本 B：临时隧道无需任何配置；固定隧道需 Cloudflare **邮箱 + Global API Key**（隧道/DNS 全自动创建）

## 安装

两个版本，按需选择：

### 版本 A：DNS + Origin Rules（需公网 IP）

```bash
apk add bash curl jq
bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/xray_cf_lite.sh)
```

快捷命令：`x`

### 版本 B：sing-box + Argo 隧道（无需公网 IP / 端口映射）

```bash
(curl -LfsS https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/singbox-lite_tunnel.sh -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/singbox-lite_tunnel.sh -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb
```

快捷命令：`sb`

- 内核 **sing-box**，协议 VLESS-WS / Trojan-WS
- 支持 **临时隧道**（随机域名，重启失效）与 **固定隧道**（邮箱 + Global API Key，全自动部署，自定义域名，持久）
- 固定隧道部署全自动：自动创建隧道（隧道名 = 二级域名前缀）、云端入口统一 `http://127.0.0.1:8080`、自动添加 DNS 解析；删除/卸载时自动清理
- 后台守护（Watchdog）自动修复失效隧道

| | 版本 A | 版本 B |
|---|---|---|
| 内核 | xray-core | sing-box |
| 接入方式 | DNS + Origin Rules | cloudflared 隧道（Argo） |
| 公网 IP | 需要 | 不需要 |
| 端口映射（NAT） | 需要 | 不需要 |
| 监听端口 | 随机 / 手动 | 随机（临时）/ 8080 固定（固定隧道） |
| 协议 | VLESS | VLESS-WS / Trojan-WS |
| 快捷命令 | `x` | `sb` |

## 版本 B 详细说明（sing-box + Argo 隧道）

> 脚本需要 root 权限。请仅在拥有管理权或明确授权的服务器和网络中使用。

### 主要能力

- **Argo 临时隧道**：无需配置，随机 `trycloudflare.com` 域名，不稳定，重启失效。
- **Argo 固定隧道**：只需 Cloudflare 邮箱 + Global API Key，全自动部署——自动创建命名隧道（隧道名 = 二级域名前缀，如 `abc.example.com` → `abc`）、云端 ingress 统一指向 `http://127.0.0.1:8080`、自动创建 DNS CNAME（橙云 proxied），稳定持久，重启不失效。
- 支持 VLESS-WS 与 Trojan-WS 两种节点协议。
- 节点查看、删除、重启、日志查看。
- 删除节点 / 卸载 Argo / 卸载脚本时，自动同步删除 Cloudflare 云端隧道与 DNS 记录。
- 后台守护（Watchdog）：每分钟检查并自动修复失效隧道。
- 临时域名 DNS 发布校验、Early Data 同步、分享链接生成与持久化。
- 前置支持：依赖安装、sing-box 核心安装（SHA-256 校验 + 失败回滚）、cloudflared 安装、systemd / OpenRC / direct 三种服务管理、配置初始化与自愈。

### 重点支持

- Debian / Ubuntu：systemd
- Alpine Linux：OpenRC
- 无 systemd/OpenRC 的精简环境：direct 后台模式
- CPU：`x86_64/amd64`、`aarch64/arm64`、`armv7l`

### 主菜单

首次启动会安装基础依赖并初始化状态文件。请按需使用主菜单 `[2]` 安装/更新 sing-box 核心。

| 分类 | 编号 | 功能 |
| --- | ---: | --- |
| 隧道节点 | 1 | Argo 隧道节点管理（临时/固定） |
| 前置支持 | 2 | 安装/更新 sing-box 核心 |
|  | 3 | 重启 sing-box 服务 |
|  | 4 | 查看服务运行状态 |
|  | 5 | 查看实时日志 |
|  | 6 | 检查配置文件 |
| 脚本管理 | 7 | 更新脚本 |
|  | 8 | 卸载脚本 |
| 退出 | 0 | 退出脚本 |

`[1]` 进入 Argo 隧道节点管理：

| 分类 | 编号 | 功能 |
| --- | ---: | --- |
| 创建节点 | 1 | 创建 VLESS-WS + Argo 节点 |
|  | 2 | 创建 Trojan-WS + Argo 节点 |
| 节点管理 | 3 | 查看 Argo 节点信息 |
|  | 4 | 查看 Argo 隧道日志 |
|  | 5 | 删除 Argo 节点 |
| 隧道控制 | 6 | 卸载 Argo 服务 |
|  | 7 | 重启 Argo 隧道 |

创建节点时可选隧道模式：

- **临时隧道**：无需配置，随机域名，不稳定，重启失效。
- **固定隧道**：输入 Cloudflare 邮箱 + Global API Key + 绑定域名，脚本自动完成全部部署（创建隧道、写入口 `http://127.0.0.1:8080`、添加 DNS 解析），稳定持久，重启不失效。删除或卸载时自动删除隧道的 DNS 记录。

### 配置与数据位置

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/sb` | 主脚本快捷命令 |
| `/usr/local/bin/sing-box` | sing-box 核心 |
| `/usr/local/bin/cloudflared` | cloudflared 核心 |
| `/usr/local/etc/sing-box/config.json` | sing-box 主节点配置 |
| `/usr/local/etc/sing-box/relay.json` | 中转配置 |
| `/usr/local/etc/sing-box/clash.yaml` | Clash/Mihomo 客户端配置 |
| `/usr/local/etc/sing-box/argo_metadata.json` | Argo 节点元数据与分享链接 |
| `/usr/local/etc/sing-box/cf_account.json` | Cloudflare 凭据（邮箱 / Global API Key，用于固定隧道自动部署与卸载清理） |
| `/var/log/sing-box.log` | sing-box 日志 |
| `/var/log/singbox_argo_*.log` | Argo 隧道日志 |

状态文件可能包含 UUID、密码、Token 和分享链接，请不要公开上传服务器上的配置目录。

## 功能（版本 A）

> 以下为 **版本 A（xray_cf_lite.sh）** 的功能；版本 B 的功能见上文「版本 B 详细说明」。

```
1. 安装节点        部署 xray + 配置 CF（DNS/SSL/Origin Rules）+ 生成节点链接
2. 删除节点        停止 xray + 精确删除本节点 DNS 解析与本地证书（不碰 SSL / Origin Rules / 安全规则等全局配置）
3. 查看节点        查看节点链接 / 生成优选订阅
4. 修改配置        修改 UUID / 端口 / WS 路径
5. 查看当前配置    显示域名、UUID、端口映射、xray 状态、节点链接
6. 更新外部端口    NAT 换端口专用：只更新 CF Origin Rules，不重启 xray
7. 重启 xray       / 8. 切换网络模式(直连/NAT)
0. 卸载脚本        红字入口：自动删除已部署节点 -> 停止服务 -> 自删脚本文件
```

## 可选项（版本 A）

| 选项 | 说明 | 默认值 |
|------|------|--------|
| 域名 | 绑定到 CF 的域名/子域名 | 必填 |
| CF 凭据 | 邮箱 + Global API Key | 首次必填，之后自动复用 |
| 协议 | vless | vless |
| UUID | 节点身份标识 | 自动生成 |
| 端口 | xray 监听端口 | 随机（直连）/ 手动映射（NAT） |
| WS 路径前缀 | WebSocket 路径 | `/{UUID前8位}` |
| SSL 模式 | 严格 Full Strict / 灵活 Flexible | 严格 |

## SSL 模式（版本 A）

| 模式 | CF → 源站 | 源站证书 | 说明 |
|------|-----------|---------|------|
| **严格 Full Strict**（默认） | HTTPS + 校验证书 | 脚本自动生成 CF Origin 证书（15 年免续期） | 更安全，推荐 |
| 灵活 Flexible | HTTP 明文 | 不需要 | 配置更简单 |

严格模式全程自动：生成 key + CSR → CF API 签发 Origin 证书 → 配置到 xray（TLS）→ CF SSL 设为 `strict`。

## 工作原理（版本 A）

```
客户端 → CF CDN (443/TLS) → Origin Rules → 源站外部端口 → NAT → xray 内部端口
```

- 输出**单个 VLESS 节点链接**，直连域名（走 CF 橙云 + Origin Rules）
- xray 崩溃自动重启（systemd / OpenRC）

## 注意事项

- 版本 A 安装时会暂时调整 Bot Fight Mode / Security Level / Browser Check
- 版本 A 删除节点 / 卸载脚本只清理该节点自身：停止 xray、删本机配置、精确删除该二级域名的 DNS 解析、自动**吊销该域名的 CF Origin CA 证书**（新装节点按证书 ID 精确吊销，旧节点按 hostnames 匹配兜底，多域名的证书绝不会动）、删本地证书文件；**完全不碰 zone 级全局配置（SSL 模式 / Origin Rules / 安全规则），不影响同域名下其他节点**
- 版本 A 删除节点时会保留 Origin Rules 中该节点自己的那条规则（内置的恢复/重写规则表操作已取消，避免影响其他节点），如需清理可到 CF 后台手动删除
- 一台服务器同时只支持一组部署（再次安装需先删除节点）
- 两个版本的状态文件均可能包含 UUID、密码、Token，请勿公开上传

---

思路参考 [xui-cf-deployer](https://github.com/byJoey/xui-cf-deployer)。
