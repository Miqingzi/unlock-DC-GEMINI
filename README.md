# WARP Google/Gemini 双栈解锁脚本

原功能来源于 https://github.com/vps8899/warp-google-unlock

创建目的仅自己使用ᓚᘏᗢ

一个面向 VPS 的系统级分流脚本，用 Cloudflare WARP 解锁 Google Gemini、Google 搜索、Google Play/商店，以及可选的 YouTube、OpenAI 和常见流媒体服务。

脚本使用 `warp-cli` 的 SOCKS5 代理模式配合 `redsocks`、`iptables` 和 `ip6tables` 做透明转发，不需要修改 Xray、Sing-box、Hysteria2、TUIC 或 SSH 的配置文件。

## 适合解决的问题

* VPS 原生 IP 被 Google 标记，Gemini 无法访问或 Google 搜索频繁验证码。
* 代理程序已经部署好，但不想在每个服务里单独维护 Google 分流规则。
* 希望只让 Gemini/Google 搜索走 WARP，同时尽量保留 YouTube 直连。
* 需要 Gemini 同时支持 IPv4 和 IPv6 访问，不再通过黑洞 IPv6 的方式“规避”问题。
* 需要一套可启动、停止、切换模式、查看状态和卸载的管理命令。

## 功能特点

### 系统级自动分流

脚本在系统 NAT 表中写入规则，命中的 TCP 流量会自动转发到 WARP 本地 SOCKS5 代理。应用层无需额外配置。

### Gemini IPv4/IPv6 双栈解锁

脚本会同时维护 IPv4 和 IPv6 规则：

* IPv4 使用 `iptables`。
* IPv6 使用 `ip6tables`。
* 模式 1 会对 Gemini、Google 搜索、Google Play/商店等关键域名同时解析 A 和 AAAA 记录。
* 模式 2/3 会加入 Google 常见 IPv4/IPv6 地址段。

### 三种分流模式

1. **Gemini/搜索/商店模式，推荐**
   仅代理 Gemini、Google Search、Google Play、Google Store 和相关登录/接口域名。由于 YouTube 与 Google 共享部分地址资源，本模式通过域名动态解析尽量减少对 YouTube 的影响。
2. **Google 全家桶模式**
   代理 Google 常见 IPv4/IPv6 地址段，适合原生 IP 对 YouTube 或其他 Google 服务限制严重的场景。
3. **扩展流媒体模式**
   在 Google 规则基础上加入 Netflix、OpenAI 和常见流媒体 IPv4 规则；IPv6 侧保留 Google 双栈规则。

### 管理命令

安装完成后可使用：

```bash
warp status
warp start
warp stop
warp restart
warp mode 1
warp mode 2
warp mode 3
warp test
warp uninstall
```

## 一键安装

支持系统：Ubuntu / Debian / CentOS / RHEL / Rocky Linux / AlmaLinux / Fedora

要求：root 权限，系统可访问 Cloudflare WARP 软件源。

```bash
bash <(curl -sL https://raw.githubusercontent.com/Miqingzi/unlock-DC-GEMINI/main/warp-google.sh)
```

也可以下载后运行：

```bash
chmod +x warp-google.sh
./warp-google.sh install
```

## 常用操作

查看状态：

```bash
warp status
```

测试直连 IP、WARP IPv4、WARP IPv6 和 Gemini HTTP 状态：

```bash
warp test
```

切换为 Google 全家桶模式：

```bash
warp mode 2
```

卸载脚本与清理分流规则：

```bash
warp uninstall
```

## 注意事项

* IPv6 双栈解锁依赖系统内核与 `ip6tables` NAT 支持；如果宿主机或容器禁用了 IPv6 NAT，IPv4 规则仍可正常工作。
* 模式 1 通过域名解析生成规则，域名 IP 变化后可执行 `warp restart` 刷新。
* 脚本不再黑洞 Google IPv6 地址段，避免破坏 Gemini 的 IPv6 访问能力。
* `warp uninstall` 会删除脚本、服务和规则，但不会自动卸载系统软件包。如需移除软件包，请手动执行 `apt remove cloudflare-warp redsocks` 或对应的 `yum/dnf remove`。
