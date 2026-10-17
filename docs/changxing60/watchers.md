# 后台检测/看门狗清单:位置、周期、怎么关(省电用)

> **状态(2026-10-16)**:清单来自设备现场核对(设备文件 md5 与仓库逐个比对一致,见文末),不是凭记忆写的。
> 目的:用户要「后面关闭并降低功耗」,所以要能一眼看清**每个周期任务在哪、多久跑一次、关掉的准确命令、
> 以及关掉会失去什么**。省电量的**实测**在 [`power.md`](power.md)(整机纯电池 ~215 mA ≈ 0.8 W);
> 本文**不含任何单项电流数字**——一个都没测过,理由见文末「诚实边界」。

路径约定:`tools/...`、`openwrt/...`、`rootfs/...` 都是 `changxing60-linux/` 子仓库下的路径(见 [`README.md`](README.md))。
设备上的路径单列一列,两边**同名不同根**,别混。

## 0. 现场快照(关停前的基线)

2026-10-16 05:28 设备时间(+03),uptime 2735 s,蜂窝 WAN `10.187.5.46` UP、`ping 223.5.5.5` 0% 丢包:

| 在跑 | pid | 类型 |
|---|---|---|
| `mobile-data watch`(procd 实例 `cellwatch`) | 26969 | 30 s 循环 |
| `hotspot-watch`(实例 `hotspotwatch`) | 6969 | 30 s 循环 |
| `/usr/bin/changxing60-screen` | 6717 | 2 s tick |
| `/opt/changxing60/bin/ndp-learn` | 6912 | 10 s 循环 |
| `clash -d /etc/openclash -f 91code.yaml` + `openclash_watchdog.sh` | 9338 / 9343 | 常驻 |
| `logdw /dev/socket/logdw`(zlog 桥) | 3723 | 常驻 |
| `hostapd` / `wpa_supplicant` / `dnsmasq` / `odhcpd` / `uhttpd` / `dropbear` / `ntpd` | — | 系统基线 |

**没在跑**(别去找):`thermal-guard`(在 5.4 上按设计自己退出,见 A7)、`charge-fix`(短命,每分钟由 cron 重来)、
`early-recorder`、`wedge-watch`、`wan-keepalive`(已拆)、`socat`(`/etc/config/socat` 里 `enable=0`)、SMS/AT 栈。

## A. 我们自己加的周期任务

| # | 组件 | 仓库位置 | 设备路径 | 谁拉起 | 周期 / 每次做什么 | **关掉** | 关掉的代价 |
|---|---|---|---|---|---|---|---|
| A1 | **cellwatch**<br>(`mobile-data watch`) | `rootfs/overlay/opt/changxing60/bin/mobile-data` | `/opt/changxing60/bin/mobile-data` | procd 实例 `cellwatch`,在 `/etc/init.d/changxing60-post`(`S99changxing60-post`) | `CHANGXING60_WATCH_INTERVAL` 默认 **30 s**;每 tick 1 个 ICMP 探针 + 读计数器;坏够久就 ifdown → CP 停/起 → 90 s 无果则**重启整机** | `ubus call service delete '{"name":"changxing60-post","instance":"cellwatch"}'` | **这是「网又没了」唯一会自己救的东西**。关掉=没有自愈、没有最后手段重启,WAN 楔死就只能人肉重启(见 [`sipa-wedge.md`](sipa-wedge.md))。省电时**最后再动它** |
| A2 | **hotspotwatch**<br>(`hotspot-watch`) | `rootfs/overlay/opt/changxing60/bin/hotspot-watch` | `/opt/changxing60/bin/hotspot-watch` | procd 实例 `hotspotwatch`,同一个 `/etc/init.d/changxing60-post` | `CHANGXING60_HOTSPOT_INTERVAL` 默认 **30 s**,启动后先 grace 50 s;每 tick 走 **`atcmd` 属性探活**(射频要醒),失败则 `wifi down/up` | `ubus call service delete '{"name":"changxing60-post","instance":"hotspotwatch"}'` | 热点**静默死亡**不再自愈——hostapd/ubus 照样报 ENABLED、客户端也关联不上,只能手动救(WCN assert 后 `reset_dump=dump` 只 dump 不 reset ⇒ `cp_asserted` 永久为 1,射频全死而软件层看不出来) |
| A3 | **chargefix**<br>(`charge-fix`) | `rootfs/overlay/opt/changxing60/bin/charge-fix` | `/opt/changxing60/bin/charge-fix` | ①procd 实例 `chargefix`(脚本钉完参数就退出,不是常驻)**②`/etc/crontabs/root` 里 `* * * * *`** | 每分钟一次:读 SOC + **i2c 读写 bq2560x 寄存器**(ITERM/IINLIM/ICHG/VREG + charge-cap) | 注释掉 crontab 那一行(`/etc/crontabs/root`)+ `ubus call service delete '{"name":"changxing60-post","instance":"chargefix"}'`,然后 `/etc/init.d/cron restart` | 充电参数不再被重钉:**USB 重插/重新上电后可能回落到芯片 POR 默认**(ITERM 960 mA → 94% 就停充、输入限流按 USB 检测),表现为「充到 94% 不动了」或充电变慢。一天 1440 次 i2c,单次很短,但会持续唤醒 |
| A4 | **bootdiag** | `openwrt/overlay/opt/changxing60/bin/bootdiag` | `/opt/changxing60/bin/bootdiag` | `/etc/crontabs/root` 里 `* * * * *` | 每分钟一次,但**只在 uptime < 900 s 时**;每次往 `/root/diag/<uptime>s.log` 写 **~330 KB**(logread 120 KB + dmesg 200 KB + modules/ps/ip rule),并且在前 900 s 里每 tick 试一次 USB 恢复;`MAXDUMPS=10`/每 boot、`MAXKEEP=30` 份 | 注释掉 crontab 那一行,`/etc/init.d/cron restart` | 失去**重启后的现场取证**(dmesg 不跨重启、console 只收 ERR 及以上,见 [`sipa-wedge.md`](sipa-wedge.md) §6.7)。注意它**开机 15 分钟后自己就停了**,稳态不耗电 |
| A5 | **内屏状态页** | `tools/screen/changxing60-screen.c` → `rootfs/overlay/usr/bin/changxing60-screen` | `/usr/bin/changxing60-screen` | procd `/etc/init.d/changxing60-screen`(`S95changxing60-screen`) | **2 s 一次 select tick**;熄屏(`screen_on=0` 或空闲熄背光)时只跳过读数与重绘,**tick 本身还在**;背光当前 **255/255(全亮)** | `/etc/init.d/changxing60-screen stop; /etc/init.d/changxing60-screen disable` | 内屏状态页没了、**电源键切背光/熄屏也没了**(按键功能在这个程序里);面板保留最后一帧。**这是稳态里最值得先关的一项**(背光 + 2 s 唤醒 + 每次重绘的 DRM page flip 都是纯开销,且不服务网络) |
| A6 | **ndp-learn** | `rootfs/overlay/opt/changxing60/bin/ndp-learn` | `/opt/changxing60/bin/ndp-learn` | procd `/etc/init.d/changxing60-ndp`(`S99changxing60-ndp`),**仅当 `uci get network.wan.ipv6` = `relay`** | **10 s** 循环:跟着承载的前缀给 `br-wifi` 装/撤 metric 128 的路由 | `/etc/init.d/changxing60-ndp disable` + `stop`(stop 会自己撤掉它装的路由) | 失去 **IPv6 中继**(热点下游没有公网 v6);IPv4 不受影响。只跑 IPv4 的场景可以关 |
| A7 | **thermal-guard** | `rootfs/overlay/opt/changxing60/bin/thermal-guard` | `/opt/changxing60/bin/thermal-guard` | procd 实例 `thermalguard`,同一个 `/etc/init.d/changxing60-post` | 设计是 **5 s** 一读热区;但脚本**第一件事**就是「内核自带 trip point 就退出」,**5.4 厂商内核正是如此** ⇒ **现在没在跑**(实测:无进程、logread 无记录) | 想彻底消除就删 `/etc/init.d/changxing60-post` 里那段实例 | 没有代价(它在 5.4 上本来什么都不做)。它是给**没有 trip point 的 6.18 主线**用的安全网 |
| A8 | `wififix` / `bootok` | `rootfs/overlay/opt/changxing60/bin/wifi-fix`、`changxing60-next-boot` | 同路径 | 两个一次性 procd 实例(同一个 init) | `sleep 35` 后跑 `wifi-fix`;`sleep 30` 后 `changxing60-next-boot --rearm` | 不用关 | 稳态零耗电(跑完就退)。⚠ 但**重启 `changxing60-post` 会让它们再跑一遍**:`wifi-fix` 会真去 down/up 一次 AP,热点抖一下 |
| A9 | **power-policy** | `openwrt/overlay/opt/changxing60/bin/power-policy` | `/opt/changxing60/bin/power-policy` | `/etc/init.d/changxing60-power`(`S96changxing60-power`) | **一次性**:按 `/etc/changxing60/power.conf` 钉 governor。现场实测 `policy0/scaling_governor` = **`schedutil`** | `CHANGXING60_POWER_GOVERNOR=performance /opt/changxing60/bin/power-policy apply` 可现场改;不推荐关 | 关掉=回到厂商默认调速策略。这不是耗电项,是**省电项**,别关 |
| A10 | 采样/调试工具 | `tools/changxing60-wedge-watch.sh`、`tools/changxing60-wan-keepalive.sh`、`tools/changxing60-diag.sh`、`tools/changxing60-cp-reset.sh`、`tools/net-*-test.sh`、`tools/modem-ioctl.c` | `/opt/changxing60/bin/` 同名 | **没有任何服务拉起** | 只有你**手动**跑才耗电。`wan-keepalive` 已拆除(实验结论:防不住假死);`wedge-watch` 未在跑 | 不跑就不耗电 | 无。需要取证时手动起,用完 kill |

## B. 系统基线(不是我们写的,但同样是耗电项)

| 组件 | 谁拉起 | 说明 | 关掉 |
|---|---|---|---|
| **OpenClash**(`clash` 核心 1.3 GB VSZ 常驻 + `openclash_watchdog.sh` + cron `0 0 * * *`) | `/etc/init.d/openclash`(`S99openclash`) | **稳态最大的一个**:TUN + fake-ip,全部流量过用户态 | `/etc/init.d/openclash stop; disable`(魔法断掉)。不用魔法时这是首选省电档。⚠ **关完必须还原 dnsmasq 的上游**:它在跑的时候把 `dhcp.@dnsmasq[0].server` 改成 `127.0.0.1#7874`(mihomo 自己的 DNS,设备快照 2026-10-17 实测就在),干净 stop 会撤;但 kill/崩溃/只 disable 就重启时这行留着 ⇒ dnsmasq 把每个查询转发到已关死的端口,**热点客户端 DNS 全灭,而其他一切照常**。核对:`uci get dhcp.@dnsmasq[0].server` 不该再有 `127.0.0.1#7874`,有就 `uci del_list dhcp.@dnsmasq[0].server='127.0.0.1#7874'; uci commit dhcp; /etc/init.d/dnsmasq restart` |
| `hostapd` + `wpa_supplicant` | `wpad`(S19) | 热点本体 + 释放 radio | 别关(产品功能) |
| `dnsmasq` / `odhcpd` | S19 / S35 | LAN 的 DHCP/DNS + RA | 关掉=下游拿不到地址/v6 |
| `uhttpd` / `dropbear` / `rpcd` | S50 / S19 / S12 | LuCI / SSH / ubus 后端 | 按需:离家部署可以关 uhttpd + dropbear(省一点点,风险是失去远程入口) |
| `ntpd`(`sysntpd`) | S98 | 周期 NTP 查询(每小时级) | `/etc/init.d/sysntpd disable`,省极少;失去时间同步(日志时间戳会飘) |
| `cron` | S50 | 每分钟 tick,**上面 A3/A4 都靠它** | 关 cron = 同时关掉 charge-fix 重钉 + bootdiag |
| `logdw`(+ zlog_* 模块) | 启动期 | Android 侧日志桥,常驻 | 未评估,别动(可能与 vendor 侧通信有关) |
| `socat` | rc.d 里有 `S99socat` | `/etc/config/socat` 里 `enable=0` ⇒ **实际没跑** | 无需处理 |

## C. 关停方法(三种,别混用)

1. **单个 procd 实例**:`ubus call service delete '{"name":"changxing60-post","instance":"cellwatch"}'`
   —— 立即生效、**只影响那一个**、重启后照旧拉起(适合"先量一下差多少")。
   ⚠ **不要**用 `/etc/init.d/changxing60-post restart` 代替:那会把 `wififix` 一起重跑 → `wifi-fix` 真去 down/up 一次 AP。
2. **整个服务**:`/etc/init.d/<name> stop` + `/etc/init.d/<name> disable`(会同时删 `S??`/`K??` 软链,重启后不再起)。
3. **crontab 行**:编辑 `/etc/crontabs/root` 注释掉对应行,然后 `/etc/init.d/cron restart`。

**铁律:要永久省电就改仓库**(`changxing60-linux/...` 下的 overlay 源文件)。设备上手改能立刻验证,但下一次
`tools/deploy-pending.sh --apply` / 重刷镜像就会**被覆盖回去**,而且这种"改了又回来"极难在设备上看出来。

## D. 建议的低功耗档(按机制排序,**不是**按实测收益排序)

1. **内屏 `changxing60-screen`**(A5):背光 255/255 + 2 s tick + DRM 翻转,是稳态里唯一"不服务网络还在耗电"的部件。
   闲置时不想失去按键/状态页,可以先只配空闲熄背光(`/etc/changxing60/panel-idle`,目前**默认关**)。
2. **OpenClash**(B):不用魔法时关掉,省一个常驻用户态转发进程。
3. **bootdiag**(A4):只在开机前 15 分钟耗,收益小;但它写的是 ext4,内存卡/闪存寿命意义上也值得注意。
4. **ntpd**(B)、**ndp-learn**(A6,只跑 v4 时)。
5. **cellwatch / hotspotwatch**(A1/A2):耗电本身很小,**它们是保险**——「网没了」和「热点静默死」都只有它们会救。
   要关的话,请在接受"这两类故障今后要人肉发现并重启"之后再关。

## E. 诚实边界

- **本文没有一个单项电流数字。** 唯一实测是整机:纯电池 6 h 53 m、平均 ~215 mA ≈ 0.8 W(满电约 13 h),
  大头是**蜂窝 + 热点 + 魔法**,不是 AP 跑得快 —— 方法与陷阱见 [`power.md`](power.md) §1–§5
  (插着充电器**测不到**系统功耗;只有库仑计;必须断 USB 走电池)。
- 想量化「关掉某项省多少」,只能断 USB 用库仑计做 A/B(`power.md` §8 的采样工具)。
  逐项 A/B 有个现实困难:整机平均 215 mA 里,单项的差异可能被蜂窝/热点的波动淹没,**要么长时间平均,要么成对切换**。
- 设备侧核对(2026-10-16,md5 与仓库逐个一致 ⇒ 本文的路径与行为就是设备上的):
  `mobile-data`、`bootdiag`、`hotspot-watch`、`charge-fix`、`thermal-guard`、
  `/etc/init.d/changxing60-post`、`changxing60-screen`、`changxing60-ndp`、`changxing60-power`。
