# 魔法(透明代理)选型调研:OpenClash vs PassWall(2026-10-13)

> 需求原话:「调研看看魔法建议用openclash或者是passwall」。
> 结论:**选 OpenClash(+ mihomo 核心)** —— 理由见 §4。
> 全部 GitHub 事实用 `gh` 查证(本项目规则:不用 WebFetch),命令附在 §5。

## 1. 先确认这台机器扛不扛得住

| 项 | 状态 | 出处 |
|---|---|---|
| nftables | ✅ `CONFIG_NF_TABLES=y` + `NFT_TPROXY` / `NFT_SOCKET` / `NF_NAT_REDIRECT` | `out-linux/.config` |
| iptables TPROXY | ✅ `NETFILTER_XT_TARGET_TPROXY=y`、`XT_MATCH_SOCKET=y` | 同上 |
| 策略路由/BPF | ✅ `NET_CLS_ACT` / `NET_CLS_BPF` / `NET_ACT_BPF` / `NET_SCH_INGRESS` | 同上 |
| TUN | ✅ `CONFIG_TUN=y` | 同上 |
| IPv6 NAT | ❌ `IP6_NF_NAT` 未开 | 同上 |

**要点:这些全是内建 `=y`,所以一个 kmod 包都不用装。**
这条很关键 —— 本机内核是自编 **5.4.254**,而 OpenWrt 25.12 源里的 kmod 全是给 **6.12.94**
编的;一旦自动代理去拉 `kmod-nft-*`,轻则装不上、重则装上去把网络搅坏。

内存/磁盘:6G RAM,ext4 rootfs 45.2G —— 富余,OpenClash 全套 ~50–100MB。

**已知短板:`IP6_NF_NAT` 没开。** 所以魔法只走 **IPv4**;IPv6 那条路继续用现有的
`masq6 + ndp-learn`(见 `ipv6.md`),**不要在 OpenClash 里开 IPv6 TPROXY/NAT**。

## 2. 两者都**不在**官方源里(实测)

```
# apk search openclash   → 无
# apk search passwall    → 无
```
所以只能从各自 GitHub Release 装 `.apk`,或加第三方 feed。别指望 `apk add openclash`。

## 3. 各家的发布物(`gh` 查证)

| 项目 | 最新 | 25.12 可用的产物 | 内核/核心 |
|---|---|---|---|
| **OpenClash** `vernesong/OpenClash` | v0.48.002 | `luci-app-openclash-0.48.002.apk`(10.7MB,单一 .apk) | 自带 mihomo(clash.meta) |
| **PassWall** `Openwrt-Passwall/openwrt-passwall` | 26.10.4-1 | `25.12+_luci-app-passwall-26.10.4-r1.apk` + `luci-i18n-passwall-zh-cn-26.10.4.apk` | **发布物里只有 luci+i18n,没有核心二进制**;核心另在 `openwrt-passwall-packages` |
| **PassWall2** `Openwrt-Passwall/openwrt-passwall2` | 26.10.1-2 | luci/i18n 的 `.apk`,**外加** `packages_apk_aarch64_generic.zip` | 核打包在依赖 zip 里(xray/sing-box 等) |

两个 PassWall 都给了 **i18n 的 zh-cn 包**,OpenClash 界面本身也有中文。

> ⚠️ PassWall 的 `.ipk` 老包别混用 —— 本机是 **apk**(OpenWrt 25.12 起),要装 `.apk`。

## 4. 结论与理由

**推荐 OpenClash。** 理由按重要性:

1. **它跟 mihomo,不跟 xray。** mihomo 是 Go 静态编译,musl/aarch64 无坑;本项目已经
   验过一份 mihomo(`clash/bin/mihomo`, `Mihomo Meta v1.19.31 linux arm64, statically linked`,
   那套是 2026-09-19 给**安卓侧**做的 TUN 方案,见 `changxing60-linux/clash/`,可复用二进制)。
2. **装起来最简单**:一个自包含 `.apk`,`apk add --allow-untrusted` 就完事;
   PassWall 还得自己去凑核心和依赖包版本。
3. **它自带 DNS 接管与 fake-ip**,对"魔法的 DNS 泄漏"这种最常见翻车点有成熟方案。
4. 生态最大、文档最全,出问题好搜。

**选 PassWall2 的场合**:你要用 xray/sing-box 的特有协议(REALITY、Hysteria2 等)或
需要它的分流编排。那就装 PassWall2 的 `.apk` + `packages_apk_aarch64_generic.zip`
(架构正好对口)。

## 5. 落地的两个前置坑(装之前先处理)

1. **本机装的是 `dnsmasq`(2.93),不是 `dnsmasq-full`。**
   OpenClash 的部分 DNS 模式要 `dnsmasq-full`(需要 ipset/nftset 支持)。
   两条路:装 `dnsmasq-full` 顶掉,或让 OpenClash 用自己的 DNS 不碰 dnsmasq。
   **装 `dnsmasq-full` 会短暂断 DNS,要挑时候做。**
2. **别让 apk 自动拉 kmod**:见 §1,源里的 kmod 是 6.12.94 的,与本机内核不匹配。
   装 OpenClash 时如果它声明 `kmod-*` 依赖,要拦下来手工确认。

## 6. 复核命令(全部 `gh`)

```sh
gh release view --repo vernesong/OpenClash --json tagName,assets --jq '{tag:.tagName,names:[.assets[].name]}'
gh release list --repo Openwrt-Passwall/openwrt-passwall --limit 1 --json tagName --jq '.[0].tagName'
gh release view --repo Openwrt-Passwall/openwrt-passwall 26.10.4-1 --json assets --jq '[.assets[].name]'
gh release view --repo Openwrt-Passwall/openwrt-passwall2 26.10.1-2 --json assets --jq '[.assets[].name]'
gh search repos passwall --limit 8        # 注意:用户/组织已改名成 Openwrt-Passwall,旧的 xiaorouji/ 解析不到

# 本机内建特性(不必 gh,直接看自编内核配置)
grep -E '^CONFIG_(NF_TABLES|NFT_TPROXY|NETFILTER_XT_TARGET_TPROXY|NET_CLS_ACT|TUN|IP6_NF_NAT)' \
    changxing60-linux/out-linux/.config
```

## 7. 安装记录(2026-10-13,已装完并实测到界面)

按 §4 的结论装了 **OpenClash 0.48.002 + mihomo**。**核心二进制走本机已有的那份**,不在设备上下载
(设备 WAN 会间歇假死,别把安装押在它身上)。

### 7.1 做了什么

```sh
# 宿主机:取包(gh,不用 WebFetch)
gh release download v0.48.002 --repo vernesong/OpenClash \
    --pattern 'luci-app-openclash-0.48.002.apk' --clobber
sha256 = f7ebbd43f9be15c5e6df26e5d0c03d50d0bb8f7fa4cc0d2c2bf048b08c0b155b   (10,702,048 B)

# 推包(ssh cat >,不用 scp/adb)后装
scp 不可用;ssh root@192.168.77.1 'cat > /root/luci-app-openclash-0.48.002.apk' < ...apk
apk update                                   # 必须先做,否则依赖全是 "no such package"
apk add --allow-untrusted /root/luci-app-openclash-0.48.002.apk

# 核心:把本机 clash/bin/mihomo 放进 core 目录(init 脚本要的就是这个名字)
ssh root@192.168.77.1 'cat > /etc/openclash/core/clash_meta && chmod 755 /etc/openclash/core/clash_meta' \
    < changxing60-linux/clash/bin/mihomo
```

结果:**35 个包 / 共 183 包 / 51.4 MiB**。依赖实况(和 §5 预判一致):
`curl`、**`dnsmasq-full`(顶掉 `dnsmasq`)**、`luci-compat` + `lua`/`luci-lua-runtime` + `luci-lib-*`、
`ruby 3.4.9` 全家(psych/yaml/bigdecimal/…)、`unzip`、`libcurl4`;
外带两个 kmod —— **`kmod-tun` 和 `kmod-nf-conntrack-netlink`,都是 `6.12.94-r1`**。
它们只是被丢进 `/lib/modules/6.12.94/`,本机跑的是 **5.4.254**,`/lib/modules/5.4.254-gb50db5b6224c/`
才是真的,**这些文件永远不会被读到**(TUN 在本机是 `=y` 内建,本来也不需要)。没有连带拉 `kernel` 包。
→ §5 第 2 条那个坑**实测存在但无害**;真要说风险,是别哪天照 `modules.dep` 去 modprobe 它们。

**它是 Lua 版 LuCI 应用**(装的是 `/usr/lib/lua/luci/controller/openclash.lua` + `model/cbi/openclash/*.lua`
+ `view/openclash/*.htm`),不是 ucode 版 —— 25.12 上靠 `luci-compat` 跑,所以上面那一串 Lua 运行时是**必需**的,
别以为能省。也因此 `/usr/share/luci/menu.d/` 里**不会**有它的 json(菜单是 Lua 控制器自己注册的),别拿这个当"没装上"。

### 7.2 实测到的证据(不是"装完就算")

- 核心能跑:`/etc/openclash/core/clash_meta -v` →
  `Mihomo Meta v1.19.31 linux arm64 with go1.26.8 … Use tags: with_gvisor`(md5 `674f34b4b33d3cbca6c71fcf48dbcd54`)。
- 界面**真的渲染出来了**,且是中文:

```
POST /cgi-bin/luci/  luci_username=root&luci_password=   → 302 + Set-Cookie: sysauth_http=…
GET  /cgi-bin/luci/admin/services/openclash  (带该 cookie) → **200**, 121,248 B,
     <title>changxing60 | 运行状态</title>, 正文含「运行状态 / 插件设置 / 配置文件订阅」
```

- 顺带证到:`dnsmasq-full` 顶掉 `dnsmasq` 后 **DNS 仍然正常**(`nslookup openwrt.org` 有应答),进程仍是 1 个。

> **鉴权细节(踩过)**:没登录时该页面回 **403 + `x-luci-login-required: yes`**,正文是登录页
> ——这是"要登录",**不是"应用坏了"**。另外 `ubus call session login` 拿到 SID 后**直接塞进
> `Cookie: sysauth=…` 是 403 的**(25.12 的 cookie 名是**按 scheme 分的** `sysauth_http`/`sysauth_https`,
> 而且得走浏览器那套表单 POST 才会下发),必须用上面那个 POST 流程,别再用 ubus SID 直连。

### 7.3 还没做的(有意留的)

> **2026-10-13 补记:用户随后自己填了订阅(`/etc/openclash/91code.yaml`)并把服务起起来了,
> 本节第 1、2 条的"没订阅/没冒烟"已经过期** —— 实际运行状态见 **§8**,那里有实测证据。

- **没有订阅/配置**,所以**没启动过服务** —— `openclash` 服务是 `enabled`,但没有配置文件,起了也没用。
  订阅地址要在界面「配置文件订阅」里填(用户的数据)。
- **没做"起了看一眼"的冒烟测试**,是有意为之:OpenClash 启动会往防火墙里插 nft 重定向规则,
  而这台机器的 WAN 本来就间歇假死,**万一规则不对,宿主电脑(在 br-lan 上)会跟着断网** ——
  已知风险,不想在没订阅的情况下先动它。要冒烟就等填完订阅,一次到位地看 7890/7892 有没有在听。
- §1 那条 IPv6 短板仍在:魔法只走 IPv4,**别在 OpenClash 里开 IPv6 TPROXY/NAT**。

### 7.4 复查命令

```sh
ssh root@192.168.77.1 'apk info -e luci-app-openclash dnsmasq-full ruby curl unzip'
ssh root@192.168.77.1 '/etc/openclash/core/clash_meta -v'
ssh root@192.168.77.1 '/etc/init.d/openclash enabled && echo enabled'
ssh root@192.168.77.1 'ls -l /etc/openclash/core/ /etc/openclash/config/ /etc/openclash/history/'   # history = 在界面上跑过的配置
```

## 8. 运行实录(2026-10-13,订阅填好、服务跑起来之后的全栈核对)

这节是**设备上真的跑起来之后**的现场读数(不再只是"装完了")。触发点:用户报"看看网络栈有没有问题",
于是把从 WAN 到代理的每一层都过了一遍。

### 8.1 进程与配置

```
14616 root  /etc/openclash/clash -d /etc/openclash -f /etc/openclash/91code.yaml
14624 root  {openclash_watch} /bin/sh /usr/share/openclash/openclash_watchdog.sh
/etc/init.d/openclash status → running
/etc/rc.d/S99openclash → 已 enable(开机自启)
mihomo: v1.19.31   mode: rule   enhanced-mode: fake-ip   external-controller: 0.0.0.0:9090
```

### 8.2 它接管了什么(全部实测)

| 面 | 读数 |
|---|---|
| TUN 接口 | `utun` up,`198.18.0.1/30`(fake-ip 段) |
| 策略路由 | `ip rule: 1888: from all fwmark 0x162 lookups 354`;table 354 = `default dev utun` + 对 `0/8`、`10/8`、`100.64/10`、`127/8`、`169.254/16`、`172.16/12`、`192.168/16` 全 `throw`(**内网/运营商网段不会被卷进隧道**,这条是它对"别把 LAN 搞断"的关键保护) |
| DNS | dnsmasq 上游被改成 `server=127.0.0.1#7874`(`no-resolv`),即 dnsmasq → mihomo 的 DNS;国内域名回真 IP,国外域名回 `198.18.x.x` fake-ip |
| nft | `openclash_mangle` / `openclash_mangle_output` 两跳;`OpenClash DNS Hijack`(`dport 53 → redirect to :53`);`OpenClash QUIC REJECT`(`udp 443` 且目标不在 `china_ip_route` 时 reject);`OpenClash TUN Input/Forward` accept |
| IPv6 | **没被接管**(符合 §1 的短板预期):魔法只走 v4,IPv6 仍是原生 RA 直出 |

### 8.3 实测(不是看规则,是真跑流量)

- **国内**:`www.qq.com` → 真 IP `111.30.185.195`,`wget` 拉回 **134,186 B** —— 直连没被绕。
- **国外**:`www.debian.org` → `wget` 拉回 **15,864 B**(正文开头 `<!DOCTYPE html>…<title>Debian`),
  mihomo 日志同时给出物证:`[TCP] … --> www.debian.org:443 match Match using 🌍 全球加速[🇸🇬 SG 私人线路-v4]`。
- **规则命中**:日志里能看到国产域名走 `RuleSet(cn-ip) using 🇨🇳 国内直连[DIRECT]`
  (如 `configuration.ls.apple.com`)、国外走 `🌍 全球加速`。
- **宿主电脑没被牵连**:`br-lan 192.168.77.1/24` 仍只发地址(无网关/DNS),PC 自己的出口没被改。
  这是本轮专门盯的一条 —— §7.3 担心的"规则不对会把宿主搞断网",**这次没有发生**。

### 8.4 留个心眼

- **开机顺序**是"先落 nft 规则、后起核心"。万一哪天宿主电脑突然没网,第一件事
  `/etc/init.d/openclash stop`,而不是怀疑 LAN。
- **`utun` 存在 + DNS 回 `198.18.x.x` = 魔法确实接管了**;这两个信号比"界面显示运行中"可靠。
- 想临时直连(不折腾配置文件):`/etc/init.d/openclash stop && /etc/init.d/openclash disable`,再 `wifi reload` 一下让客户端重取 DNS。
- 仍未验的还是 §1 那条:**IPv6 不走魔法**(本机 `IP6_NF_NAT` 没编,别在里面开 v6 TPROXY/NAT)。

