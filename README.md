# xray-cf-lite

最小化 xray + Cloudflare 节点部署脚本。一个 Bash 脚本，无需面板。

## 适用场景

- NAT 小鸡（端口映射环境）
- Alpine / LXC 容器
- 低配机器（256MB 内存即可）

## 前置条件

- Linux（Debian/Ubuntu/Alpine/CentOS），root 权限，Bash 4+
- 脚本自动安装 `curl` / `jq` / `unzip` / `openssl`，并自动下载 xray-core
- 支持 **systemd** 与 **OpenRC**（Alpine）
- Cloudflare：域名已托管 + 账号邮箱 + **Global API Key**
- 严格 SSL 模式会自动生成 CF Origin 证书（需 `SSL and Certificates: Edit` 权限）

## 安装

两个版本，按需选择：

### 版本 A：DNS + Origin Rules（需公网 IP）

```bash
apk add bash curl jq
bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/xray_cf_lite.sh)
```

快捷命令：`x`

### 版本 B：Cloudflare Tunnel（无需公网 IP / 端口映射）

```bash
apk add bash curl jq
bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/xray_cf_tunnel.sh)
```

快捷命令：`xt`

| | 版本 A | 版本 B |
|---|---|---|
| 接入方式 | DNS + Origin Rules | cloudflared 隧道 |
| 公网 IP | 需要 | 不需要 |
| 端口映射（NAT） | 需要 | 不需要 |
| 快捷命令 | `x` | `xt` |

## 功能

```
1. 安装节点        部署 xray + 配置 CF（DNS/SSL/Origin Rules）+ 生成节点链接
2. 卸载            停止 xray + 回滚 CF 配置 + 清理本地状态/凭据/证书
3. 查看节点        查看节点链接 / 生成优选订阅
4. 修改配置        修改 UUID / 端口 / WS 路径
5. 查看当前配置    显示域名、UUID、端口映射、xray 状态、节点链接
6. 更新外部端口    NAT 换端口专用：只更新 CF Origin Rules，不重启 xray
```

## 可选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| 域名 | 绑定到 CF 的域名/子域名 | 必填 |
| CF 凭据 | 邮箱 + Global API Key | 首次必填，之后自动复用 |
| 协议 | vless | vless |
| UUID | 节点身份标识 | 自动生成 |
| 端口 | xray 监听端口 | 随机（直连）/ 手动映射（NAT） |
| WS 路径前缀 | WebSocket 路径 | `/{UUID前8位}` |
| SSL 模式 | 严格 Full Strict / 灵活 Flexible | 严格 |

## SSL 模式

| 模式 | CF → 源站 | 源站证书 | 说明 |
|------|-----------|---------|------|
| **严格 Full Strict**（默认） | HTTPS + 校验证书 | 脚本自动生成 CF Origin 证书（15 年免续期） | 更安全，推荐 |
| 灵活 Flexible | HTTP 明文 | 不需要 | 配置更简单 |

严格模式全程自动：生成 key + CSR → CF API 签发 Origin 证书 → 配置到 xray（TLS）→ CF SSL 设为 `strict`。

## 工作原理

```
客户端 → CF CDN (443/TLS) → Origin Rules → 源站外部端口 → NAT → xray 内部端口
```

- 输出**单个 VLESS 节点链接**，直连域名（走 CF 橙云 + Origin Rules）
- xray 崩溃自动重启（systemd / OpenRC）

## 注意事项

- 安装时自动关闭 Bot Fight Mode / Security Level / Browser Check，卸载时恢复原值
- 卸载会完整回滚 CF 配置（DNS / SSL / Origin Rules），并清理本地状态、凭据、证书
- CF 凭据只存在服务器本地，不会上传
- 一台服务器同时只支持一组部署（再次安装需先卸载）

---

思路参考 [xui-cf-deployer](https://github.com/byJoey/xui-cf-deployer)。
