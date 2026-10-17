# USB 链路:管理口 / 共享口

> **状态(2026-10-16)**:**已上机实测双向通过**。设备侧模式切换、rpcd 后端、LuCI 页都已在设备上跑通;
> 宿主机侧用真机路由表逐项验过(§5)。用户要求是「USB 口保留只管理的 br-lan 192.168.77.1,
> **另外加一个可单独切换的共享模式**」——本文件是这件事的全记录。

## 1. 两种模式

USB 线插在电脑上,这条链路可以是**管理线**,也可以是**上行**:

| | `manage`(默认) | `share` |
|---|---|---|
| PC 拿到的地址 | 192.168.77.100-249 | 同左 |
| DHCP option 3(路由器) | **发空的** | 192.168.77.1 |
| DHCP option 6(DNS) | **发空的** | 192.168.77.1 |
| IPv6(br-lan) | `ra=disabled` `dhcpv6=disabled` | `ra=relay` `dhcpv6=relay` |
| 租期 | 12h | **5m** |
| PC 会不会走这台机器上网 | 不会,保留自己的上行 | 会 |

地址段、接口、防火墙 zone 两边**完全一样**,变的只有决定「客户端愿不愿意把流量交出来」的那两项。

## 2. 为什么默认是 manage(这是实测,不是洁癖)

DHCP 回包里**省略** option 3 并不会让客户端删掉它已有的默认路由——Windows 尤其会把旧的留着。
所以「不告诉它网关」不等于「它不会走你」,得**显式发一个长度为零的 option 3** 才是 DHCP 里
「这里没有路由器」的说法。

2026-10-13 实测过代价:br-lan 和热点还共用一个 scope、所以也共用一个 router option 的时候,
UsbNcm 网卡的默认路由(经 192.168.77.1,**接口跃点 25**)压过了本机真正的 Wi-Fi 上行(跃点 30),
于是本机代理没认领的每一个公网目的地都被送进了这台手机的蜂窝网。**没有任何现象**:
线照通用、AP 照工作、PC 的流量悄悄换了路。

> 这台机器的实测跃点(2026-10-16,`Get-NetIPInterface`):
> `以太网 54`(USB)= **25**,`WLAN` = **45**。USB 确实更优——所以 share 模式是真的会生效,
> 不是"配了但没用"。

## 3. share 模式做了什么

`changxing60-usb-mode share` 只写 `dhcp.lan` 的四个选项 + 重启 dnsmasq/odhcpd:

- `dhcp_option='3,192.168.77.1' '6,192.168.77.1'` —— 网关和 DNS 都指向本机。
- `ra='relay'` `dhcpv6='relay'` —— 和 br-wifi 一模一样。**没有前缀可以委派**(运营商只在 RA 里
  给,`+CGCONTRDP` 的 prefix 字段是 0,见 [`ipv6.md`](ipv6.md)),所以是**中继**运营商的通告,
  PC 从运营商的 /64 里 SLAAC 出自己的地址,回程由 wan zone 上的 NAT66 改写。
- 租期 **5m**(见 §6)。

**防火墙一行都不用改**。br-lan 两种模式下都在 `lan` zone 里,而 `lan→wan` 的 forwarding 本来就是
ACCEPT、masq 本来就在 wan zone 上。所以 share 能通不需要加规则,manage 安全也不需要加规则——
这也是它敢做成一个开关的原因。

## 4. 怎么切

```sh
# 设备上
changxing60-usb-mode              # 看当前
changxing60-usb-mode state        # key=value,给 rpcd 后端读
changxing60-usb-mode share        # 切成共享口
changxing60-usb-mode manage       # 切回管理口

# 网页
LuCI → 服务 → USB link         (/cgi-bin/luci/admin/services/changxing60usb)
# 背后是 ubus 对象 changxing60usb 的 status / set

# 宿主机侧(让 PC 立刻换过来,而不是等租期)
tools/win/usb-share.sh            # 看 PC 的流量现在往哪走
tools/win/usb-share.sh --renew    # 换租约
tools/win/usb-share.sh --test     # 再补一个 tracert
```

**两个方向都不会把自己关在门外**:192.168.77.1 始终 on-link,不管模式是什么、也不管 PC 的路由表
乱成什么样,ssh 和 LuCI 都还在。这正是它做成一个页面而不是一个 ssh 上改的配置文件的原因。

## 5. 实测(2026-10-16)

| 项 | 期望 | 实测 |
|---|---|---|
| `manage` 基线 | PC 上没有经 USB 的默认路由 | 只有 `WLAN 192.168.100.1` ✅ |
| 切 `share` | PC 拿到网关 + DNS | `Default Gateway 192.168.77.1`,DNS `{192.168.77.1}` ✅ |
| IPv6 中继 | PC 拿到运营商前缀的地址 | `2409:8947:389:8a0:dc64:2fd1:f5d9:1ab2`(临时地址也有)✅ |
| **转发真的通** | 强制走 USB 网卡能出网 | `curl --interface 192.168.77.199 http://223.5.5.5/` → **HTTP 404,`local=192.168.77.199`** ✅ |
| 切回 `manage` | 路由消失 | 只剩 `WLAN`;DNS 变空 ✅ |
| 幂等 | 同模式重跑 / 连切四次 | 四次 `rc=0`,状态正确 ✅ |
| LuCI 页 | 200 | `/admin/services/changxing60usb` → 200;不存在的路径 → 404(判据有效)✅ |

那条 404 是关键证据:回包来自 **223.5.5.5 这台外部主机**,而连接的源地址是 USB 网卡的
192.168.77.199 —— 包确实从 PC 穿过了这台手机、走了蜂窝 WAN 出去再回来。

## 6. 不能自动的那一半:PC 的租约

设备侧切完,**PC 不会自己知道**。DHCP 没有 Windows 认的服务端主动续约——RFC 3203 的
FORCE_RENEW 在报文没做认证时会被忽略——所以切换只改了「下一份租约」,改不了「手上这份」。

因此:

- share 模式把租期压到 **5m**(T1 = 2.5m),两个方向都能**在几分钟内自己收敛**,不至于让一台
  切回 manage 的 PC 抱着默认路由 12 小时。
- 要立刻生效就跑 `tools/win/usb-share.sh --renew`。

**`--renew` 走的是 `release` + `renew`,不是单 `renew`**。2026-10-16 实测:从 share 切回 manage 后,
单跑 `ipconfig /renew` **默认路由还在**(Windows 不会因为续约里的 option 3 是空的就把已经有的网关删掉);
`release` 丢掉租约、路由随之消失,后面的 `renew` 再把地址拿回来(实测还是同一个 192.168.77.199)。
切**进** share 是容易的那一半,单 renew 就够;切**回**来才是需要这一下的。

脚本会在 renew 之后检查地址有没有回来——没有地址就没有到 192.168.77.0/24 的路由,管理链路会一起没。
本机没发生过,但这是唯一值得当场说出来的结果,所以它被写进了输出。

## 7. 「配了」和「真的走了」是两件事

share 模式是**把路由给出去**,不是**抢**。PC 用不用,取决于它自己还有什么:

这台机器上跑着宿主侧的 Mihomo TUN,它装的是**分裂默认路由**(`192.0.0.0/2`、`0.0.0.0/3`、
`32.0.0.0/5`),比 `0.0.0.0/0` 更具体,**永远赢**,和跃点无关。所以:

- Mihomo 在跑 → PC 的默认路径仍然走它自己的代理,USB 默认路由挂着但轮不到它。
  (`Find-NetRoute 223.5.5.5` → `src 198.18.0.1 via ifIndex 77 (Mihomo)`。)
- Mihomo 停了 → USB(25)压过 WLAN(45),PC 就走这台手机了。

这不是缺陷,是「谁的默认路由更具体谁说了算」。`tools/win/usb-share.sh` 每次都会把
**路由表原样打出来并指出 USB 那条在不在**,而不是替读者下结论。

> 另一个要知道的相互作用:share 模式下 PC 的 DNS 是 192.168.77.1 → 本机 dnsmasq →
  OpenClash(127.0.0.1#7874)。国内域名实测回**真实 IP**(`www.baidu.com` → 39.156.70.46),
> 没问题;但如果某个域名回的是 fake-ip(198.18.x.x),而 PC 自己也有一个占着 198.18.0.0/30 的
> TUN,**PC 会把它送进自己的 TUN 而不是这台手机**。真遇到就手动把 PC 的 DNS 指到公网解析器。

## 8. 工件

| 文件 | 作用 |
|---|---|
| `rootfs/overlay/opt/changxing60/bin/changxing60-usb-mode` | 唯一读写 `dhcp.lan` 的地方;`show`/`state`/`manage`/`share` |
| `openwrt/overlay/usr/share/rpcd/ucode/changxing60usb.uc` | ubus 对象 `changxing60usb`:`status` / `set` |
| `openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60usb.json` | 页面的 ACL |
| `openwrt/overlay/usr/share/luci/menu.d/luci-app-changxing60usb.json` | 菜单项(服务 → USB link) |
| `openwrt/overlay/www/luci-static/resources/view/changxing60usb/usb.js` | 页面 |
| `tools/win/usb-share.ps1` + `tools/win/usb-share.sh` | 宿主机侧:看路由 / 换租约 / 验证 |

模式状态**不另存一份**:它就是 `dhcp.lan` 的选项,由 `changxing60-usb-mode` 一家读写,
rpcd 后端跑那个脚本并解析它的 `state` 输出,页面只读后端。所以页面、终端和正在跑的 dnsmasq
不可能对「现在是哪个模式」有三种说法。

## 9. 两个踩过的坑

1. **`uci delete` 在选项不存在时返回 1**,而脚本头上有 `set -e` —— 一个没加 `|| true` 的
   `uci delete` 会当场结束整个脚本。`net-split` 里已经为同一件事写过注释(它第一次跑就是这么死的),
   这里又踩了一次。实测 `uci -q delete dhcp.lan.ra_flags` 在选项**存在**时也回 1,所以这不是
   「只防不存在」的问题,是**每一个 delete 都要护**。
2. **rpcd 的 ucode 插件要 `import { popen, readfile } from 'fs'`**。少 import 一个不会在加载时报错
   ——`ubus -v list` 照样列出方法,只有真正**调用**时才抛 `Reference error`,而 ubus CLI 只回一句
   `Unknown error`。判据是 `ubus call` 真调一次,不是 `ubus -v list`。

## 10. 相关

- [`access.md`](access.md) —— 三态判定与「宿主的 OpenClash TUN 会把 `ssh 192.168.77.1` 的失败
  伪装成成功」,和 §7 是同一类陷阱。
- [`ipv6.md`](ipv6.md) —— 为什么只能 relay 不能 delegate,NAT66 为什么必须开。
- `rootfs/overlay/opt/changxing60/bin/net-split` —— 当初把 br-lan 拆出来的那个脚本,
  §2 那段实测就是它的由来;share 模式是它的反向开关。
