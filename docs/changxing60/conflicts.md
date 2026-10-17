# changxing60:OpenWrt 与底层的冲突扫描(2026-10-17)

> **问题**:我们的 OpenWrt 层是否和底层(厂商内核、chroot 里跑着的安卓侧服务、磁盘上的安卓分区)抢同一个东西?
> **方法**:同一台机、同一次开机(起始 uptime 52 418 s ≈ 14.6 h,收口时 54 415 s;`5.4.254-gb50db5b6224c`)上跑了 13 轮**只读**探针
> (`/tmp/conflict-scan{,2..10}.sh` → `/tmp/conflict-live{..10}.txt`,末尾三轮是复核 `saudio`/`sprd-dmaengine`/`bss_load`),外加两个只读子 agent 审开机顺序与资源占用。
> **纪律**:整场扫描没在设备上写过任何东西、没发过一条 AT、没动过一个 mixer;子 agent 的每一条结论都回原文/回设备抽查过,
> 抽查不通过的写法一律改掉或删掉(见 §8)。**我自己的两处引用也被抽查打掉了,记在 §6 E1 与 §8。**

---

## 1. 分级

| 级 | 含义 |
|---|---|
| 🔴 | 能让内核 panic(oops→panic→复位)。注意这台机上**两重**都成立:内核 `CONFIG_PANIC_ON_OOPS=y`,而且 `changxing60-linux/boot/init:85` 是**我们自己**在 `echo 1 > /proc/sys/kernel/panic_on_oops`(见 §6 E3 末尾) |
| 🟠 | 能让蜂窝/热点死到**只能重启**(CP 哑、SDIO carddump、AT 通道拆掉) |
| 🟡 | 降级但不死(某功能不工作、晚 30 s、ssh 抖一下) |
| ⚪ | 外观/日志刷屏/文档不符 |

---

## 2. 速览

| # | 冲突对 | 抢什么 | 触发条件 | 级 | 本次开机是否已发生 |
|---|---|---|---|---|---|
| A1 | 我们的 `charge-fix` ↔ 厂商 `charger-manager`/`policy` + bq2560x 驱动 | 同一颗充电芯片 | 一直存在 | 🟡⚪ | 存在(读数已分叉) |
| A2 | `packet_steering`(netifd 自带) ↔ 我们的热点路径 | wlan0 的 RPS | 每次开机 + 每次 firewall/interface 重载 | ⚪ | 存在(wlan0 钉在 CPU2)⇒ **裁定:留,记账**(§9 行 6;实测吞吐基线就是在这个状态下量的) |
| B1 | `uci-defaults/90-changxing60`(S10) ↔ `changxing60-hw`(S12) | `wireless.ap0` 这个 section | **只在全新刷机/清空后第一次开机** | 🟠 | 没有(carry-over 兜住了)⇒ **已修**(§9 行 1,chroot 新旧树对照) |
| B2 | `bootdiag`(cron) ↔ `vendor-modules load_good` | vendor 模块加载序列 | 每次开机,窗口 15 s | 🟡→🟠 | **还武装着**(标记文件没删)⇒ **已解除**(§9 行 2:设备 rm 标记+判据按 boot_id 拆窗) |
| B3 | `wififix`(开机 +35 s) ↔ `hotspot-watch`(+50 s 起每 30 s) | `wifi down/up` | 开机时 AP 正好坏 | 🟠 | 没有(两边都没动)⇒ **已加共锁**(§9 行 4,31+13 项主机测试) |
| B4 | `ndp-learn` ↔ `changxing60cell.sh` | bearer 的 IPv6 sysctl | 每次拨号缺 global 地址的窗口 | 🟡 | 条件性,未计时⇒ **已加门**(§9 行 5,setup 期间不碰 sysctl) |
| B5 | `10-changxing60-usb`(hotplug) ↔ `bootdiag usb_recover` ↔ `network` 配置 | gadget `UDC` 与 usb0 的桥成员 | 开机前 900 s | 🟡 | 未观测到抖动 |
| B6 | 注释/cron ↔ 镜像/carry-over | 那条"每分钟 charge-fix" | 每次刷机 | 🟡 | 设备有、镜像没有⇒ **已进镜像**(§9 行 3) |
| C1 | OpenClash ↔ dnsmasq ↔ fw4 | 全机 DNS、`inet fw4` 一张表 | OpenClash 被停而配置没回滚 | 🟡 | 现在健康(mihomo 活着)⇒ **关停手册已补还原步骤**(§9 行 7,watchers.md B 表) |
| E1 | 一次 `arecord` ↔ IRAM capture carve + `panic_on_oops` | `hw:0,0` 录音缓冲的映射边界 | 请求的 buffer > carve(实测 **7680 B**) | 🔴 | **已发生过**(2026-10-16;机制这次才记对);**已修**(2026-10-17 晚用户点头:`audio-pcm-prealloc-guard` 上机,dmesg 实测拒绝超限、内核存活 ⇒ §9 行 9) |
| E5 | `changxing60-audio`(S20)开机服务的 before-snapshot ↔ vbc 驱动的 NULL data 指针 | `/dev/vbc_turning0` 的整块读(>24 B 走 data 分支) | 开机后 audio_structure 还没进 kernel 时去读它 | 🔴 | **已发生过**(2026-10-17 boot X:panic→落 Android)⇒ **当天已修**(marker 门,§10) |
| E2 | `openwrt-wifi-config`(镜像)↔ `bss_load_update_period=0`(只在设备 uci) | hostapd 的 BSS-Load 行为 | 全新刷机 / 恢复出厂 | 🟠 | 没有(carry-over 兜住了)⇒ **已进镜像+每开机 re-pin**(§9 行 8;扫描漏网的 E2b `chan_util_avg_period` 一并) |
| E3 | 我们的 `cp_reset()` ↔ 厂商 `modem_control` | `modem_run()` 的 `run_state` | WAN 死透时按下的那一次 | 🟠 | 没有(本 boot 未触发) |
| D1 | `state-2026-10-17.md` §1 ↔ 实机 | "thermal-guard 在跑"这句话 | 已经不符 | ⚪ | 是(已改) |

**扫描当时没有新增 🔴**:E1 就是 2026-10-16 已经炸过的那一次,这轮只是把机制从错误的文件改到正确的文件,并没有引入新的触发条件。
已知会让内核 panic 的两条(大 buffer 的普通录音 FE、拿 veth 挂网桥当测试客户端)都不在这次的动作里,
而且这十三轮全程只读:ALSA 子流全关、DAPM 全 Off、`apipe-*`/`audio_*` 节点无人持有。
(**当晚 E1 上机过程中真新增了一条 🔴:E5,开机服务自己的快照读打死开机 —— 见 §10,当天修复。**）

---

## 3. A 类:OpenWrt ↔ 底层

### A1 充电:我们绕过驱动直接写寄存器,而厂商那套此刻是"睁眼瞎" 🟡⚪

**实测到的分叉**(同一时刻,`/tmp/conflict-live5.txt` + `live8.txt`):

```
/sys/class/power_supply/bq2560x_charger/device/registers   →  Reg[00]=0x0b  Reg[02]=0x90  Reg[03]=0x22  Reg[04]=0x80
   ↑ 这正是 charge-fix 钉的 IINLIM 1.2 A / ICHG 960 mA / VREG 4368 mV
/sys/class/power_supply/bq2560x_charger/input_current_limit        →  0
/sys/class/power_supply/bq2560x_charger/constant_charge_current    →  0
/sys/class/power_supply/bq2560x_charger/constant_charge_voltage    →  4368000     ← 只有这个是"看得到"的
/sys/class/power_supply/bq2560x_charger/status · online            →  Full · 1
/sys/class/power_supply/interface/{charge_control_limit,current_max,input_current_limit} → 0 · -22 · -1
```

**先纠正我自己一次引用**:上一版这里写的是 `drivers/power/supply/bq2560x-charger.c:1136-1158` —— **那不是在这台机上跑的那份**。
判据:设备上存在 `/sys/class/power_supply/bq2560x_charger/device/registers`,而全树 `DEVICE_ATTR(registers` 在四个 bq2560x 候选里
**只有 `drivers/vendor/common/sqc_v8/sqc_bq2560x.c` 有**(`drivers/power/supply/bq2560x-charger.c`、`sqc_v2/`、`sqc_base/` 都是 0 命中),
`arch/arm64/configs/U30Air_defconfig:5588` 也正好是 `CONFIG_VENDOR_SQC_BQ2560X=m` 而 `:2715 # CONFIG_CHARGER_BQ2560X is not set`。
下面一律按 **sqc_v8** 引用(行号已回原文核对)。

**为什么不是"缓存过期",而是"驱动认为根本没在充"**:`sqc_v8/sqc_bq2560x.c:1738-1748`(`CONSTANT_CHARGE_CURRENT`)
和紧随其后的 `INPUT_CURRENT_LIMIT` 分支都是 `if (!info->charging) { val->intval = 0; }` —— 读硬件的那条路只有
`info->charging==true` 时才走。`info->charging` 由 psy 写入侧翻,而翻它的是**安卓 charge HAL / sqc HAL 通过 psy 下下来的命令**;
OpenWrt 侧没人写 psy,所以我们是用芯片自己的 debug 节点(`…/device/registers`)把寄存器钉住,驱动的"是否在充电"永远停在 false。
(这条结论本身没变,**变的是它出自哪个文件**。)

**同时厂商的充电策略在跑但拿不到输入**:`logread` 每 15 s 一轮
`charger-manager: Can not to get board tempperature` / `policy: charger_policy_get_prop_by_name(): get dc psy failed!!` /
`Get dc present failed`,以及 `work_cycle = 15s`、`new_uisoc = 917`、`capacity orig: 917, new: 93`(千分比折算)。
最后这类日志是在 **[T32186]** 上下文打出来的,32186 就是 `changxing60-screen` —— **我们的状态页读库仑计,驱动的是厂商的策略线程**,
每 2 s 一行,纯刷屏(⚪)。

**后果与边界**:
- 电芯实际吃到什么,由**我们钉的寄存器 + 每分钟 cron** 决定;厂商的温度回退/输入限流闭环在这台机上**不成立**
  (它连板温都取不到)。硬件侧兜底只剩 bq2560x 内部热调节与芯片自己的 PRECHG/EOC 逻辑。
- **谁会反过来覆盖我们钉的那四个寄存器**(这里把子 agent 的一条结论打掉,再给出真的那条):
  - agent 说"驱动的 15 s 看门狗 work 会 re-limit REG_00" ⇒ **否证**:`bq2560x_feed_watchdog()`(:1199-1212)与
    `bq2560x_charger_feed_watchdog_work()`(:2189-2204,`schedule_delayed_work(..., HZ * 15)`)只对 **REG_01** 的 `WDT_RESET` 位做 RMW,
    `update_workfunc`(:1680-1695)写的也是看门狗超时位 —— **驱动的周期性写集合 = REG_01,与我们钉的 REG_00/02/03/04 不重叠**。
  - 真正能覆盖的路是 **整寄存器写**:`bq2560x_charger_set_limit_current()`(:1138-1155)是
    `bq2560x_write(info, BQ2560X_REG_00, reg_val)`,而 `reg_val` 只装了 IINLIM 那 5 位 ⇒ **顺带把 HIZ/充电使能那些位清成 0**。
    它的调用者是 sqc 的 HAL 表 `sqc_mp_set_aicr()`(:2721-2735)和 psy `INPUT_CURRENT_LIMIT` 的 set(:1856-1862)——
    **两条都要有人从用户态下命令**,不是自发周期行为。
  - 结构上的隐患还在:`bq2560x_store_registers()`(:3140-3175,就是我们写的那个 `registers`)**不拿 `info->lock`**,直接 `bq2560x_write`
    ⇒ 谁同时在 RMW 同一个寄存器就是 lost-update。今天不炸的原因只是"写集合不重叠",不是"有锁"。
  - 实测边界:整轮 uptime(14.6 h,复核时 15.1 h)寄存器仍是 charge-fix 那四个值;`logread` 里没有任何
    `set usb icl` / `disable HIZ` / `start charge` 痕迹(探针专门 grep 过)。厂商 `charger-manager` 每 15 s 都在报错
    —— 它的闭环根本没到芯片。**"驱动不会覆盖我们"这条是源码推的 + 一次开机实测,不是永久保证。**
- 最坏情形(未知写者/某个 AICR 命令把 VREG 顶到 4432 mV 那一次)的纠正窗口,取决于 B6 那条 cron 还在不在。

### A2 `packet_steering`:一个我们树里根本没有的东西,把 wlan0 的收包钉在 CPU2 ⚪

- 设备上 `/etc/init.d/packet_steering` = **S25**,已启用;`/lib/apk/db/installed` 里它和 `etc/init.d/network` 同属一条文件记录 ⇒ **随 netifd 包进来**。
- 主机侧 grep:`openwrt/`、`tools/`、根脚本里 **零命中** —— 不是我们写的,也从没进过任何文档。
- `network.globals` 里**没有** `packet_steering` 这个键(实测 `uci show network.globals`),脚本照样跑并照样排 RSS:
  `sipa_eth0=00 wlan0=04 br-wifi=00 usb0=01`。
- 它还注册了 `procd_add_reload_trigger "firewall"` 与 `procd_add_raw_trigger "interface.*"` ⇒ **我们每次 firewall reload / 每次接口翻动,它都重排一次 RSS**。
- 影响面:只碰 CPU 亲和,不碰规则;热点实测吞吐(1 流 ~20 M、4 流 ~90 M)是在它存在的情况下量出来的,所以**没有证据说它在伤害什么**。
  但它属于"第三方写者动我们热点路径的状态",要么显式留着并记一句话,要么 `uci set network.globals.packet_steering='0'` 关掉再测一次吞吐,别让它当暗桩。
- 裁定(→ §9 行 6,**2026-10-17:留,记账**,不改配置):实测逐口复核 —— 正主是 `/usr/libexec/network/packet-steering.uc`(**连字符**;谁要找 `packet_steering.uc`/`cpu_RPS` 谁就查空,我自己 10-17 就先错在这一手)。
  它在"空参数"下走 auto 档:按 /proc 负载把每个物理口的 rx 队列 RPS 钉到"最闲 CPU"并 taskset 它的 NAPI 线程;本机现值 `wlan0=04 usb0=01 sipa_eth0=00`。
  触发器每次 network/firewall reload + 每个 `interface.*` hotplug(去抖 1 s)。全部吞吐基线都是在这个状态下量出来的 ⇒ 关掉它对"已验收良好"是做减法,不做零收益的变更;要动它的人请先重测再动。

### A3 / A4 通道与节点:**已证实不抢**(排除项)

fd 全扫(探针 `live4`/`live8`)后的完整通道表:

| 持有者 | 节点 | | 
|---|---|---|
| `changxing60-atd` pid 5436 | `/dev/stty_nr1` | 我们的共享命令通道 |
| `changxing60-atd` pid 5477(**5436 的子进程**) | `/dev/stty_nr0` | URC 通道 |
| `/vendor/bin/modem_control` pid 32720 | `…/dev/sctl_ch`、`sctl_pm`、`spipe_nr2` | 安卓侧调制解调器控制 |
| `/vendor/bin/cp_diskserver` pid 32721 | `…/dev/snv_nr` | CP 日志落盘 |
| `/vendor/bin/refnotify` pid 32722 | `…/dev/spipe_nr8`、`sprd_time_sync`、`stime_ch` + **只读**打开 `…/backlight/sprd_backlight/actual_brightness` | 属性/时间通知 |

- **两个"看着像冲突"的都排掉了**:
  1. 一度以为 `changxing60-atd` 起了两份 = 双读者(会哑 modem)。实测 5477 的 `PPid` 是 5436,且它开的是 **nr0**,`/etc/init.d/changxing60-at` 的注释写明这是设计。
  2. `at-split` 开关(默认关,实测 `[ -e /etc/changxing60/at-split ]` 为空)如果哪天打开,第二个 atd 会去 `/dev/stty_nr2` —— 而 modem_control 持有的是 `/dev/spipe_nr2`。
     **`kernel-src/…/ums9620-modem.dtsi` 证明这两个是不同 channel**(`stty_nr: channel@6` vs `spipe_nr: channel@4`,都是 `compatible="sprd,spipe"`),
     所以打开 at-split 不会和安卓侧服务抢同一个节点。**但它仍然会抢 CP 侧语义 —— 那条没被这次扫描覆盖,别把它当"已验证安全"。**
- `refnotify` 只**读**背光:两侧读数一致(191 / 191,max 255),电源键改亮度不会被它写回打架。

### A5 磁盘上的安卓侧:只读一块,写只有 misc(排除项)

```
/dev/loop0        on /                                          ext4 (rw,noatime)     ← 我们的根(安卓分区里的那个 ext4)
/dev/loop0        on /dev/__properties__                        ext4 (rw,noatime)
/dev/loop0        on /opt/changxing60/android/dev/__properties__ ext4 (rw,noatime)
/dev/block/by-name/prodnv on /mnt/vendor                        ext4 (ro,relatime)    ← 出厂 MAC 的出处(wifimac.txt)
```

- **没有任何进程打开 `/dev/block/by-name/*`**(全盘 fd 扫描空),`modem_control`/`cp_diskserver`/`refnotify` 的 fd 里也没有裸盘。
  也就是说 OpenWrt 运行期间**不写安卓分区**,prodnv 还是只读挂的。
- 启动槽也没被动:`misc` 偏移 2048 那 32 字节实测
  `5f6200004243414201020000fe002f000000000000000000000000001c751554`,与
  `rescue/misc-blocks/misc-bc-slot-b-trial.bin` 以及**全部** `changxing60-linux/work/*.misc-slot-b-trial.bin` **逐字节相同**(slot-a 那份是 `_a`+`ff001e`)。

### A6 属性区:目录属主 1000 是假信号,`getprop` 是第二个假信号

- `/opt/changxing60/android/dev/__properties__` 显示 `drwx--x--x 1000:1000`,但那是 **bind 过来的目录本身的属主**;
  里面的 `properties_serial` / `property_info` / `u:object_r:*` 实测全是 `root:root` —— `android-vendor-start:26` 那句
  `chown 0:0 $A/dev-properties/*` 改的是文件,bionic 判定的也是文件。memory 里"属性区属主 1000 致 bionic 静默不 mmap"的教训**没有被违反**。
- 探针里 `getprop` 回 0 条,是**因为 `getprop` 根本不在 OpenWrt 的 PATH 里**(`which getprop` 空)。别拿它当判据。

---

## 4. B 类:我们自己的服务抢自己(OpenWrt 内部)

### B1 🔴→🟠 全新刷机第一次开机,整个 LAN 拆分**静默不生效**

链条(每一环都验过):

1. 镜像里**没有** `/etc/config/network`、`system`、`wireless` —— `tar tzf openwrt/changxing60-openwrt-rootfs.tar.gz | grep '^./etc/config/'` 只列出
   `uhttpd rpcd luci dhcp dropbear socat openssl firewall`。
2. `net-split` 开头就是 `set -e`(`rootfs/overlay/opt/changxing60/bin/net-split:22`),而它 `uci commit` 全在末尾(`:156-159`)。
3. **设备实测 uci 的语义**:`uci -q set 不存在的包.sec.opt=1` → **rc=1**;`uci -q set network.不存在的section.opt=1` → **rc=1**;且不落盘(探针专门查了,没有产生垃圾文件)。
4. `net-split:78` 是 `uci -q set wireless.ap0.network='wifi'`,而 `wireless`/`ap0` 是 **S12 的 `changxing60-hw:48 → openwrt-wifi-config`**(`:18 touch /etc/config/wireless`、`:29 set wireless.ap0=wifi-iface`)才创建的;
   `net-split` 由 `/etc/uci-defaults/90-changxing60:36` 调用,而 uci-defaults 在**原版 `S10boot`** 里跑 —— **早两个级别**。
5. 于是第一次开机 `net-split` 在第一条依赖上死掉,后面全丢:`network.brwifi/wifi`(:70-77)、`dhcp.wifi`(:90-102)、
   **把 br-wifi 放进防火墙 zone 的那三行**(:105-107)、`network.wan.ipv6='relay'`(:123)、以及 `dhcp.lan` 不发网关/DNS 的那几行(:83-87)。
   正好是文档里已经记录过的两种事故:**热点客户端关联成功、四次握手全过、就是拿不到地址**(fw4 落到 `jump handle_reject`),
   **以及 Windows 的 USB 网卡跃点 25 抢走电脑默认路由**。
6. **没有第二次机会**:全树 `net-split` 的唯一调用点就是 `90-changxing60`(grep 实证),而设备上 `/etc/uci-defaults/` 现在是空的 —— 第一次开机后就被原版逻辑删掉了。
   `90-changxing60:37` 的 `|| logger` 只留一行 syslog。

**为什么今天这台机是好的**:`tools/changxing60-carry-over.py:42-51` 的必带清单永远带 `etc/config/{wireless,network,firewall,system}`(那条清单的注释本身就是 2026-10-15 防火墙被重置那次事故换来的)。
**⚠ 恢复出厂/直接刷镜像 = 这条会发。** 2026-10-16 那次"热点拿不到地址"我们归因给 `net-split` 的 mode bit(那个修复是对的),但**顺序病留着**。

修法方向(→ §9 行 1:**已按三条腿落地**,2026-10-17):调用挪进 `changxing60-hw`(S12,`openwrt-wifi-config` 之后、netifd S20 之前,不带 --apply 所以无竞态)+ `net-split` 自己种子(文件不存在先 touch、section 不存在先建)+ `90-changxing60` batch 前种 `network/system`。
解剖 flash tarball 时还发现比"ap0 顺序"更深一层:**镜像的 `/etc/config` 里根本没有 `network`/`system`/`wireless` 这三个文件**,而上游的 `90-defaultconfig` 没进这个 rootfs —— 所以光补 wireless 那一条腿,`90-changxing60` 自己的 batch 在 virgin 装上照样全灭。chroot 假根对照实验:OLD 树零产出复现 B1,NEW 树 rc=0 且逐字等于现网状态。

### B2 🟡→🟠 vendor-bisect 还武装着,而它的判据和 `load_good` 的 15 s 窗天然打架

- 设备上 `/etc/changxing60/vendor-bisect` **还在**(0 字节,Oct 15 22:13),`vendor-candidates` 11 批、`BISECT_WINDOW=20` ⇒ **每次开机** `bootdiag`(cron 每分钟)都会
  spawn 一次完整走查(实测 `/tmp/.bisect-ran` 存在,时间戳 = 本次开机 10-16),白跑 ~220 s 的后台 insmod 序列。
- 更要紧的是判据:`vendor-modules:bisect_verdict()`(:109-129)= "日志里最后一个 `TRYING X` 后面没有配对的 `OK|SKIPPED` ⇒ X 杀了内核",
  而 `load_good()`(:95-105)**自己就是** `TRYING good-set` → `sleep 15` → `OK good-set`。
  `bootdiag:133-134` 在 cron 里、在后台 spawn `bisect`,`bisect()` 第一件事就是 `bisect_verdict` —— **cron 的第一拍如果落进那 15 s**,
  它就把"没写完的好集合"当成"杀内核的集合",**从 `vendor-good` 删掉最后一行、并写进 `vendor-bad` 永久拉黑一个驱动**。
- 本次开机运气好:`/root/vendor-bisect.log` 最后一段是 `TRYING sensorhub / OK sensorhub / BISECT-DONE`,配对完整;`/etc/changxing60/vendor-bad` **空**。
- 为什么算 🟠:被拉黑的可能是 `smartpa_stat`/`board_state`/`apsys-dvfs` 这一类(实测 `apsys-dvfs`、`ledtrig-pattern` 这次就不在 `/proc/modules` 里 —— 这一条我**没**查明原因,只记现象)。
- 处理(→ §9 行 2:**已做**,2026-10-17):设备上 `rm /etc/changxing60/vendor-bisect`(bootdiag 的门就是 `[ -e ]`,删文件=彻底解除);`vendor-modules` 的判据同时拆弹 —— `load_good()` 先写 `=== boot $(cat /proc/sys/kernel/random/boot_id)` 再 TRYING,`bisect_verdict()` 只对**本 boot 标记之前**的历史行判决,15 s 窗不再能被当成"没配对"。

### B3 🟠 两条 `wifi down/up` 驱动,开机窗口重叠且没有共同锁

- `changxing60-post:57-58` → `sleep 35; exec /opt/changxing60/bin/wifi-fix`,`wifi-fix:16-21` 判 hostapd 没有 bssid 就 `wifi down; wifi up`。
- `hotspot-watch:31` 每 30 s 一轮、`:112` grace 50 s,repair 也是 `wifi down`(:74)/`wifi up`(:76)。
- 两边 **都没有锁**(grep `lock` 各为空),而 AP 坏的时候往往正在重下固件(`hotspot-watch:23` 的注释自己写明恢复=重下固件)。
- 已记录的单向门:**反复 power-off 会让 SDIO 卡在 carddump(-110),只有重启能救**。
- 本次开机两边**都没动**(logread grep 空),所以这是时序上没撞,不是"不会撞"。
- 处理(→ §9 行 4:**已做**,2026-10-17):`/var/run/changxing60-wifi.lock`(mkdir+pid+死主接管,mobile-data 同款),wifi-fix 与 hotspot-watch `repair()` 两边共拿;输的一方整轮不行动也**不烧 MAX_REPAIR 阶梯**
  (跳过≠失败)。`hotspot-watch` 的 50 s grace 保留但注释降级为 warmup(防的是"hostapd 还没起好"而不是"撞 wififix"——互斥不再依赖计时)。
  主机 harness:`tools/hotspot-watch/test-repair.sh` 31 项、`tools/wifi-fix/test-wifi-fix.sh` 13 项(活锁/死锁/健康 AP 三态全断言)。

### B4 🟡 bearer 的 IPv6 sysctl 有两个写者,其中一个明确会取消另一个的 RS

- `changxing60cell.sh:80-92`(relay 分支)写 `accept_ra=2 → disable_ipv6=1 → sleep 1 → =0`,并且注释说这条顺序是量出来的:**"再写一次 accept_ra 会取消待发的 solicitation"**。
- `ndp-learn:139-144` 跑**同一个循环**,条件是"bearer 还没有 scope global 地址",每 10 s 一轮 ⇒ 正好覆盖 `up()` 等 CEREG 的那 120 s。
- 两边都是我们的进程,没有协调。后果是 IPv6 晚起来(约再等一轮 RS),不伤 IPv4。
- 处理(→ §9 行 5:**已做**,2026-10-17):`ndp-learn` 加了 `bearer_setting_up()` 门 —— attach 锁存在**且其 pid 活着**(死主残留不算,否则 re-solicit 会被永久饿死)或 netifd `"pending": true`(照 `wan_pending` 同款 grep)时,整段 accept_ra/disable_ipv6 翻转跳过,一个 setup 窗口只记一行日志。`changxing60cell.sh` 侧不动(它是那个 flip 的正主)。harness `tools/ndp-learn/test-setting-up.sh` 8 项,含"锁死残留/无 pid 文件/无 ubus"三个不许饿死的反例。

### B5 🟡 USB gadget 的 `UDC` 有三个写者

- `etc/hotplug.d/iface/10-changxing60-usb:12-19`:每次 lan ifup 就 `echo "" > $g/UDC` 再 `echo "$udc" > $g/UDC`(自己用 20 s 时间戳去重)。
- `bootdiag:61` `usb_recover()` 也写 `$G/UDC`,还顺手 `ip link set usb0 master br-lan` + `up`(:70-71),门是 `MAXUPTIME=900`(:20,:128)——**开机前 900 s 每分钟都可能来一次**。
- 而 usb0 的桥成员同时由 `network` 配置管着(`90-changxing60` 里 `add_list network.$dev.ports='usb0'`)。
- 三者两两无锁。后果是最多 ssh 抖几秒。
- 顺带把 mode bit 的疑虑排掉:`git ls-files -s` 里这个 hotplug 脚本是 **100644**,但 `sbin/hotplug-call` 是 `. $script`(**source**,实测第 16 行),不需要执行位 —— 这条** immunity 来自 source,不是来自打包**,build-rootfs.sh 的 chmod 循环(169-175)没覆盖 `hotplug.d`。

### B6 🟡 "charge-fix 每分钟"在镜像里不存在 —— 它是这台机的手改

- 设备实测 `/etc/crontabs/root` 三行:`charge-fix`、`bootdiag`、`openclash.sh`。
- 树里**只有** `changxing60-hw:18-20` 装 `bootdiag` 那一行(而且它自己的注释就写着"this rootfs' crontab is hand-edited")。
- 但 `changxing60-post:47` 和 `charge-fix:56,71,94` 的注释都断言"crontab 每分钟重跑"。
- `carry-over.py` 的必带清单不含 `/etc/crontabs` ⇒ **刷机后回到"只在开机钉一次"**。和 A1 叠加:那个把 VREG 顶到 4432 mV 的未知写者再出现时,
  纠正窗口从 ≤60 s 变成"到下次重启为止"。
- 处理(→ §9 行 3:**已做**,2026-10-17):`changxing60-hw` 现在与 bootdiag 同一段装 charge-fix 那行(grep 去重再 append);设备现 crontab 的三行与该逻辑逐一吻合,刷机后不再丢。

---

## 5. C 类:配置耦合(不是 bug,是必须知道的依赖)

- **全机 DNS 的单点 = mihomo**:`/var/etc/dnsmasq.conf.cfg01411c` 实测两行有效内容 `bind-dynamic` + `server=127.0.0.1#7874`,
  而设备自己的 `/tmp/resolv.conf` 是 `nameserver 127.0.0.1`。`openclash.config.enable_redirect_dns='1'`。
  ⇒ OpenClash 被停掉而 `dhcp.@dnsmasq[0].server` 没回滚时,**设备自己 + br-lan + br-wifi 的解析一起挂**。现在健康(mihomo 2 个进程在跑)。
  建议:把"关 OpenClash 之后要不要顺手还原 dnsmasq 的 server"写进 `watchers.md` 的关停手册。**→ 已写**(§9 行 7,附核对与还原命令;`server=127.0.0.1#7874` 在 2026-10-17 设备快照的 `/etc/config/dhcp` 里实证)。
- **防火墙只有一张表**:`nft list tables` 只有 `inet fw4`,OpenClash 的 DNS 劫持(`redirect to :53`,已计数 34 898 pkts)和 QUIC REJECT
  都在 `fw4` 的 `dstnat`/`forward` 里 ⇒ `fw4 reload` 与 OpenClash reload 是**互相覆盖写者**;另外 `network.@globals` 没键也照样跑的 packet_steering(A2)也注册了 firewall reload 触发。
  验收判据仍然是那条:`nft list chain inet fw4 input` 里有 `iifname "br-wifi"`(实测在)。
- dnsmasq 绑在 WAN 地址上(`10.67.131.73:53`),靠 `localservice` + fw4 wan zone 默认 drop 兜着 —— 不是冲突,记一句免得下次当异常查。

---

## 6. E 类:内核层与镜像层的三个"放大器"

它们不制造新冲突,但会把别人的冲突升级成整机事故,或者把"今天能跑"变成"刷机后必炸"。

### E1 🔴 一次普通录音就能打穿映射 —— 而 `audio-oops.md` 之前把机制记错了文件

**撤回**:`audio-oops.md` §3 原先写"机制指向厂商 `saudio.c:543`"。**不是它。**

- `saudio.ko` 确实在 `/proc/modules`(`saudio 53248 0` ⇒ **引用计数 0**),而且它**是我们自己编进去的**
  (`kernel/build-audio.sh:118` 的目录清单含 `sprd_audio/saudio`)—— 所以"grep 模块表看到 saudio"一定会骗人。
  决定性证据是绑定关系:`/sys/bus/platform/drivers/saudio/` 里**只有 `bind`/`unbind`/`module`/`uevent` 四个文件、一个设备都没绑**,
  `/proc/device-tree` 里 `unisoc,saudio` 兼容节点 0 命中 ⇒ **注册了驱动却没有设备可绑,它一次都没 probe**。
- 反面对照(同一份 listing):`/sys/bus/platform/drivers/sprd-pcm-audio/` 下**绑着 `sprd-pcm-audio` 和 `sprd-pcm-iis` 两个设备**,
  而 `sprd-dmaengine-pcm.c:1771` 的 driver `.name` 正是 `"sprd-pcm-audio"`、`:1458` 是 `static struct snd_pcm_ops sprd_pcm_ops`
  ⇒ `00-00: FE_ST_NORMAL_AP01`(= `hw:0,0`)的 ops 归 `sprd_dmaengine_pcm`(refcount 1,`snd_soc_sprd_card` 的依赖)。
  源码就是我们编 audio ko 用的那棵树:`changxing60-linux/tools/build-audio-54.sh:13` 写明来源
  `realme … kernel_modules/kernel5.4/audio_driver`,`tools/audio/test-built.sh:44` 的清单里就有 `sprd-dmaengine-pcm`。
  (`saudio.c:543` 里那个同形状的 `runtime->dma_bytes = size;` **是真的存在**,只是它服务的是另一张从没生成的卡。)

链条四段,每段都回原文/回设备核过(路径均为 `kernel-src/realme-unisoc-5.4/kernel_modules/kernel5.4/…`):

1. **缓冲来源**:`sprd/platform/dmaengine_pcm/sprd-dmaengine-pcm.c` 的 `sprd_pcm_preallocate_dma_ddr32_buffer()`
   对 `FE_DAI_ID_NORMAL_AP01` + `SNDRV_PCM_STREAM_CAPTURE` + `is_normal_cap_use_iram()` 走
   `audio_mem_alloc(IRAM_NORMAL_C_DATA, &size)` —— **一块 IRAM 固定 carve**,不是按请求分配的 `DDR32` 分支。
2. **这条路默认开着**:`:64 static int test_normal_cap_use_iram = 1;`;设备实测
   `cat /proc/asound/card0/sprd-dmaengine` → `test_normal_cap_use_iram 0x1`。
   `FE_DAI_ID_NORMAL_AP01 = 0`(`sprd-platform-pcm-routing.h:20`)⇒ 就是 `hw:0,0`,`/proc/asound/pcm` 里叫 `FE_ST_NORMAL_AP01`。
3. **`dma_bytes` 被写成请求值**:`sprd_pcm_hw_params():1135 runtime->dma_bytes = totsize;`,
   `totsize = params_buffer_bytes(params)`(:1068)是**上层要多少**,而 `snd_pcm_hardware.buffer_bytes_max = 228 KiB`(:55/:158)
   advertised 得比 carve 大得多 ⇒ ALSA 自己的 hw_params 约束不会拦。
4. **core 拿它去 memset**:`sound/core/pcm_native.c:746-752`(`_snd_pcm_hw_params` 末尾防内核信息泄漏)
   `size = runtime->dma_bytes; if (info & MMAP) size = PAGE_ALIGN(size); memset(runtime->dma_area, 0, size);`
   ⇒ 请求 > carve 就是**线性写穿 vmap**。

和崩溃现场严丝合缝:`pc: __memset`、`lr: snd_pcm_hw_params`、`pte=0`、故障地址 = 基址 + 恰好 2 页,
而 `audio-oops.md:44` 当时已经量到"前 8192 字节映射着、`dma_bytes` 声称 40896"。

**所以结论要改写**:并发两个 ALSA 客户端**从来不是必要条件** —— 单个 `arecord` 走 `hw:0,0` 且把 buffer 要到比 carve 大,就够了。
"card 0 上不并发"仍是好纪律(AGDSP/VBC 侧的并发风险并没有被这次分析排除),但**不能再拿它当"单跑就安全"的依据**。
放音方向不受这条影响(那个分支要求 `stream == CAPTURE`)。
可复用的**只读**判据:`cat /proc/asound/card0/sprd-dmaengine`(读安全,写才改行为)。carve 的确切字节数这台机没独立读过,~8 KiB 是从崩溃现场反推的。

### E2 🟠 治 CP2「BSS-Load 断言」的那一行只活在设备 uci 里,镜像里没有

- 设备实测两层都在:`/etc/config/wireless:19 option bss_load_update_period '0'` → 生成的
  `/var/run/hostapd-phy0.conf:38 bss_load_update_period=0`(**确实透到 hostapd**,不是写了个没人认的键)。
- 树里 grep `bss_load` 的唯一命中是 `tools/changxing60-carry-over.py:43` 的**注释**;
  `rootfs/overlay/opt/changxing60/bin/openwrt-wifi-config` 的 uci batch(:21-37)只写 band/channel/htmode/country/disabled + ap0 七项,**没有它**。
- 后果接在 B1 同一个场景上:全新刷机 → `openwrt-wifi-config` 生成一份不带 `bss_load_update_period=0` 的 `wireless` →
  hostapd 每 6 s 改写 BSS-Load beacon → WCN 命令超时 → `cp_asserted` 锁死 → **射频全死,只有重启能救**
  (机制见 `hotspot-stability` 的记录 / `docs/changxing60/` 里的热点那条)。
- 上游通路本来就在:`usr/share/ucode/wifi/ap.uc:56` 与 `usr/share/schema/wireless.wifi-iface.json:176` 都列了这个键,
  所以在 `openwrt-wifi-config` 里加一行 `set wireless.ap0.bss_load_update_period='0'` 即可,**不用碰 netifd/ucode**。
- 今天这台机靠 carry-over 必带 `etc/config/wireless` 活着 —— **和 B1/B6 是同一根病:镜像不自洽,靠搬运兜。**
- **E2b(修的时候才发现的同族第二例)**:设备上 ap0 还独改了一个 `chan_util_avg_period '0'` —— hostapd 每 **50 s** 改写 channel-utilization
  element,和 BSS-Load 每 6 s 那次改写是同一个断言族(命令超时 → `cp_asserted`)。这条**任何文档/扫描都没提过**,仓库零覆盖,纯设备手改。
- 处理(→ §9 行 8:**已做**,2026-10-17):`openwrt-wifi-config` 的 batch 现在同时写 `bss_load_update_period='0'` 与 `chan_util_avg_period='0'`(chroot 验证两者都透到
  `/var/run/hostapd-phy0.conf`),`changxing60-hw` 再加**每开机 re-pin 循环**(兜住比这行更早的安装、以及日后 LuCI 重写丢键 —— 与 macaddr 的 pin 同构)。

### E3 🟠 `modem_run()` 无锁,而它有两个写者(其中一个是我们)

- `kernel-src/zte-ums9620-kernel-5.4.254/drivers/unisoc_platform/modem_loader/sprd_modem_loader.c:806-820`:
  `modem_run()` 全文对状态只有一句非原子的 `if (b_restrict && modem->run_state == b_run) return -EINVAL;`
  然后 `modem->run_state = b_run;` → `soc_modem_start()/soc_modem_stop()`。
  **这个文件里唯一的 mutex 是 `rd_mutex`/`wt_mutex`(:645-696,spipe 读写用),不在这条路上。**
- 入口是 ioctl:`MODEM_STOP_CMD`(:967-968)、`MODEM_START_CMD`(:970-972)、`MODEM_UNCONDITIONAL_STOP_CMD`(:994-995)——
  三条**都没有 comm 门禁**;有门禁的只有 `MODEM_ASSERT_CMD`(:974-976 `strcmp(current->comm,"modem_control") → -EPERM`)。
  这与 `cptl-and-boot.md` §4.2"assert 是唯一有 comm 门禁的"一致 —— 也正因如此,我们的 `cp_reset()` 才**能**打到这条路。
- 也就是说:我们 `mobile-data` 的 `cp_reset()`(同一对 stop/start ioctl)和厂商 `modem_control` 自己的 CP 起停
  是**两个完全不加锁的写者**,TOCTOU 窗口就是 `run_state` 那一句。
- 现状边界:本次开机没撞过(`/root/selfheal.log` 本 boot 无记录),而且 `cp_reset()` 已经被收紧成"最后手段 + 每 boot 一次"。
  这条**不建议**在代码里去"抢锁"(我们改不动厂商的 `modem_control`),它唯一正确的用法就是现在的策略:**WAN 死透才按一次**。
- 顺带记一个自伤放大器(和 E1 是配套的):`changxing60-linux/boot/init:85` 是**我们自己**在
  `echo 1 > /proc/sys/kernel/panic_on_oops`(`:10` 还 `echo 7 > /proc/sys/kernel/printk`,后来被 `quiet-console` 钉回 `4 4 1 4`)。
  ⇒ 任何一次 oops 在这台机上都**必然**变成 panic → 复位:好处是不带伤运行,代价是"驱动小 bug = 整机重启 + pstore 只有一份"。
  这是刻意的设计,**不动它**;但下次遇到"设备自己关机"要先想到这里。

---

## 7. D 类:文档 ≠ 实机

- **D1 ⚪ `thermal-guard` 不在跑,而且是它自己选择不跑。** 实测:`procd` 确实按 `changxing60-post:35-38` 起了 `thermalguard` 实例,
  但脚本 `thermal-guard:21-23` 一发现任一 thermal_zone 有 `trip_point_0_temp` 就 `exit 0`("The 5.4 vendor kernel throttles itself, so this exits there")。
  设备上 27 个 zone 里 `thermal_zone4 = soc-thmzone` **确实有 trip**(探针逐个列过)⇒ 它按设计自我禁用。
  `state-2026-10-17.md` §1 那句"3 个守护在跑 … thermal-guard"已改为如实描述。CPU 现在跑 `schedutil`,
  `policy0 max=2002000 / policy4,7 max=2210000`,没有任何外部封顶。

---

## 8. 假信号与已排除项(下次别再当成问题查)

| 一度像冲突的东西 | 实测结论 |
|---|---|
| "两个 `changxing60-atd` = 双 AT 读者(会哑 modem)" | 5477 是 5436 的**子进程**,开的是 `/dev/stty_nr0`(URC),设计如此 |
| "modem_control 占着 `spipe_nr2` ⇒ 打开 `at-split` 会撞车" | DTS 证明 `stty_nr`(channel@6)与 `spipe_nr`(channel@4)**是两个不同 channel** |
| "`refnotify` 读我们写的背光" | 只读 fd;两侧读数一致(191/191) |
| "`getprop` 0 条 ⇒ 属性区又坏了" | OpenWrt 的 PATH 里**根本没有** `getprop`;bind 过来的文件是 `root:root` |
| "`__properties__` 目录属主 1000" | 那是目录,bionic 判的是文件 |
| "`bq2560x` psy 报 0 ⇒ 驱动缓存过期、随时会覆盖我们" | 在跑的 sqc_v8 那份 `:1738-1748` 是 `!info->charging` 时**恒返回 0**;15 h 内寄存器没被动过 |
| "驱动的 15 s 看门狗 work 会 re-limit REG_00"(子 agent 的结论) | **否证**:`:1199-1212` 与 `:2189-2204` 只对 **REG_01** 的 `WDT_RESET` 位做 RMW,不碰我们钉的四个寄存器 |
| "`saudio.c:543` 把 `dma_bytes` 覆盖成请求值"(我自己在 `audio-oops.md` 里的结论) | **撤回**:`saudio.ko` 虽在 `/proc/modules`,但 refcount **0**、无 platform device、DT 里 `unisoc,saudio` 零命中;真正的当事模块是 `sprd_dmaengine_pcm`(见 §6 E1) |
| "音频 oops 需要**并发**两个 ALSA 客户端"(我从 2026-10-16 那次推出来的纪律) | **必要条件不成立**:carve + 请求值 memset 一个 `arecord` 就能触发(§6 E1)。"不并发"仍是好纪律,但别再当"单跑安全"的依据 |
| "`/etc/config/socat` + S99socat ⇒ 可能桥了 AT 通道" | 只有上游示例段 `enable='0'`,无进程,监听表里没有 8000 |
| "QUIC reject 丢了"(我自己的探针) | 我的 grep 打在 `output` 链上,规则在 `forward` 链 —— 是探针错,不是设备错 |
| "`ls --time-style` 回空 ⇒ 文件不存在"(我自己的探针) | busybox `ls` 不认这个选项,报错进 stderr 了 |
| "音频测试残留" | MDG `1024,1024` / DG `64,64` 还在内核缓存里(SHUTDOWN 族参数,**重启才清**);子流全关、DAPM 全 Off、`apipe-*`/`audio_*` 无人持有 ⇒ **对网络零影响** |
| 镜像里的 `rootfs/overlay/opt/changxing60/bin/__pycache__/*.pyc` | 97 KB 的编译缓存随 `cp -a` 进每个镜像(`build-rootfs.sh:159`),纯垃圾,`.gitignore` 的 `__pycache__/` 只挡住了 git 没挡住打包 |

**子 agent 结论里被我校验/修正的部分**:`net-split` 的 rc 依赖(agent 说"约定俗成但未证")⇒ 已上机实测 rc=1,坐实;
agent 给的 `hotplug.d` 脚本 644"无害"⇒ 已回 tarball 验 `hotplug-call` 是 `. $script`(无害的理由成立,但理由要说对);
agent 说 bootdiag 走查会"永久拉黑好模块"⇒ 判据已回原文核对(`bisect_verdict` 与 `load_good` 的 TRYING/OK 配对),成立,但**今天还没发**,
所以按"已武装、未触发"写。`/tmp/conflict-live*.txt` 十份都在主机上。

---

## 9. 建议动作(2026-10-17 用户点头"本地和机器上都改好"后,1–5/7/8 **已执行**;6 已裁定;9 见 §6 E1)

| 优先 | 动作 | 状态(2026-10-17) |
|---|---|---|
| 1 | `net-split` 改由 `changxing60-hw` 在 `openwrt-wifi-config` 之后调用(一次性标记) | **已做**。`changxing60-hw` boot() 末尾直接 `sh net-split`(不带 --apply,无竞态:它 S12,netifd S20 还没读 uci);同时 `net-split` 自己补了"文件/section 不存在就先建"的独立种子,`90-changxing60` 在 batch 前种 `network/system` —— 因为对 flash tarball 的解剖证明**镜像里连 `network`/`system`/`wireless` 都没有**(不止 ap0 顺序问题),`uci set` 对不存在的包直接 rc=1。三条腿一起修。验证:chroot 里 OLD 树复现 B1 零产出、NEW 树 rc=0 且落盘内容与现网逐字一致;幂等复跑产物字节相同 |
| 2 | 删掉设备上的 `/etc/changxing60/vendor-bisect`(或给 bootdiag 加门) | **已做**。设备侧 `rm /etc/changxing60/vendor-bisect`(bootdiag 的门是 `[ -e ]`,删文件=彻底解除);另外把 `vendor-modules` 的 `load_good()` 加了 `=== boot $(boot_id)` 标记、`bisect_verdict()` 只对**本次开机标记之前**的行下判决 —— 15 s 窗的先天打架从判据上拆掉。下次刷机起生效(设备上已推送,md5 一致) |
| 3 | 把 charge-fix 那行 crontab 写进 `changxing60-hw`(和 bootdiag 同一段) | **已做**。与 bootdiag 同 idiom(grep 去重再 append),B6 的"镜像里不存在"就此闭合;现设备 crontab 三行(charge-fix/bootdiag/openclash)与写入逻辑一致 |
| 4 | `wififix` 与 `hotspot-watch` 共用一把 mkdir 锁(照 `mobile-data` 的 `ATTACH_LOCK` 写法) | **已做**。`/var/run/changxing60-wifi.lock`(mkdir+pid+死主接管),两边同路径;拿不到锁的一方**本轮完全不行动、不计入 MAX_REPAIR 阶梯**(跳过≠失败)。`hotspot-watch` 原来那句"50 s grace 防 wififix"降级为纯 warmup,互斥改由锁保证。主机测试:`tools/hotspot-watch/test-repair.sh` 31/31、新加的 `tools/wifi-fix/test-wifi-fix.sh` 13/13(含"活锁持有者赢/死锁被接管/健康 AP 零动作") |
| 5 | `ndp-learn` 加"bearer 正在 setup 就不动 sysctl"的门 | **已做**。`bearer_setting_up()` = attach 锁(查 pid 活性,kill -9 残留不背锅)**或** netifd `"pending": true`(照 mobile-data `wan_pending` 同款);setup 期间整个 accept_ra/disable_ipv6 翻转跳过,每次 setup 窗口只记一行日志。新 harness `tools/ndp-learn/test-setting-up.sh` 8/8(含三个"不许饿死 re-solicit"的反例)。设备上 ndp-learn 重启方式=kill 进程让 respawn(`3600 10 0`)自己拉活,不走 `/etc/init.d/changxing60-post restart`(那会连带 wififix 重跑) |
| 6 | 决定 `packet_steering` 的去留 | **已裁定:留,记账**。实测 `rps_cpus`:wlan0=`04`(CPU2)、usb0=`01`、sipa_eth0/br-wifi=`00` —— 之前扫描里"cpu_RPS 查询为空"是**探针用错节点名**(`cpu_RPS` 应为 `queues/rx-*/rps_cpus`),钉在 CPU2 是真的。netifd 随包脚本(`S25`,`/usr/libexec/network/packet-steering.uc`),每次 network/firewall reload 与接口翻动重排;只碰 CPU 亲和,不碰规则/固件/AT 通道。热点全部实测吞吐(1 流 ~20 M、4 流 ~90 M)都是在它存在的情况下量的 ⇒ 关掉=对已验良好行为做无收益变更。不动 |
| 7 | 关停手册补一句"关 OpenClash 要还原 dnsmasq 的 server" | **已做**,写进 `watchers.md` B 表 OpenClash 行:OpenClash 在跑时 `dhcp.@dnsmasq[0].server` 被改成 `127.0.0.1#7874`(mihomo 自己的 DNS,2026-10-17 设备快照实证);干净 stop 会撤,kill/崩溃/只 disable 就重启则留着 ⇒ dnsmasq 把每个查询转发到已关死的端口,热点 DNS 全灭而其他一切照常。附了核对与还原命令 |
| 8 | `openwrt-wifi-config` 的 uci batch 里补 `set wireless.ap0.bss_load_update_period='0'`(E2) | **已做**,并顺带补了扫描没发现的 **E2b:同族第二个设备独改 `chan_util_avg_period='0'`**(hostapd 每 50 s 改写 channel-utilization beacon,同 CP2 断言族)—— 两处都进镜像 batch,`changxing60-hw` 还加了每开机 re-pin 循环(兜住先于这行存在的安装与日后 LuCI 覆写)。下次刷机起 virgin 装也干净 |
| 9 | 以后**任何**录音动作前,先按 §6 E1 判:只用 `hw:0,0` 以外的小 buffer,或干脆不在 normal capture FE 上录 | **已落地(2026-10-17 晚,用户点头"打上应聘的那个内核补丁,我同意了")**。补丁 `kernel/patches/audio-pcm-prealloc-guard.patch` 进 `kernel/build-audio.sh` 注册表(排在 period-timer/pointer 之后,同文件叠放);ko `sprd-dmaengine-pcm.ko` md5 `1ee9ed78…` 上机(旧件备份 `/root/sprd-dmaengine-pcm.ko.pre-guard` = `e1fcb1db…`),`out/modules` 经 `stage-modules.py` 重 strip 保持一致,装载=一次重启(用户点头范围内)。实测:`arecord -B 20000`(19200 B > carve)在 dmesg 得到 `buffer_bytes 19200 exceeds preallocated 7680 (FE_DAI_ID_NORMAL_AP01 Captrue), refusing` + `hw params failed: -22`,**内核存活**;carve 确切字节数就此定案 **7680**(拒绝消息 + DT `sprd,normal-captue-data` = 0x1e00 双证)。附带发现:`hw:0,0` normal capture 在 ≤carve 的尺寸上也过不了厂商驱动后面的约束(拒绝消息不出现、走到 DMA 配置才失败)⇒ **guard 没有夺走任何本来能用的功能**。装载那次重启撞上的 boot X panic 与本补丁无关(新 ko 在 201.6 s 正常返回,203 s 崩在另一条链)⇒ §10/E5 |

**执行边界**:以上全部不需要重启当量;唯一需要的设备侧动作是 `deploy-pending.sh --apply` 推送 +
`kill` 两个 respawn 型守护(`hotspot-watch`/`ndp-learn`)让新代码上岗(一次 wifi 动作都没触发,
uptime 未断)。刷机验证(1/8)按行 1/8 的方式(假根 chroot)已提前做掉,不欠着。

## 10. E5:开机服务自己的 before-snapshot 打死开机(2026-10-17 晚,E1 上机当晚撞出,当天修复)

E1 的 guard ko 装载要重启;第一次重启后设备**没回 OpenWrt,落进了 Android**。pstore 取证
(`rescue/dumps/2026-10-17-guard-boot-panic/`:console-ramoops-0、dmesg-ramoops-0/1、pmsg)显示
新 ko 在 201.6 s `initcall … returned 0` 正常装载,**203 s 崩的是另一条链,与本补丁无关**:

- 链条:`changxing60-audio`(S20,符号链接 10-17 16:52 才建,boot X 是**第一次真正跑到它**)→
  `changxing60-vbc-load` 开头的 `snap "$TMP/before"`(为了幂等比较)→ `changxing60-vbc-dump` 对
  `/dev/vbc_turning0` 发一整个 262144 B 的读 → 此时 audio_structure 从没加载,
  `vbc_turning_structure_read`/`vbc_turning_ndp_read` **对 NULL data 指针没有判空**(对比 turning1–3:判了,答
  `-ENOMEM`,实测安全)→ fault address 0x18(`Comm: dd`,PID 6713)→ `panic_on_oops=1` → panic #2 → 落 slot a。
- **两个此前记错的事**:(a) vbc-dump 头注释把"未加载 ⇒ ENOMEM"泛化到全部四个 turning 节点 —— 对 turning0 **为假**,
  而且正是这句假话让 before-snap 看起来无害;(b) ≤24 B 的读走 header 分支,不碰 data 指针,所以 voice-audio 自检测里
  那个 24 B 探针是安全的 —— 致命的只有"未加载 + 大读"这一组合。`vbc-load:153` 的 after-snap 是**同型第二处潜在点**
  (audio_structure 没写进去时照样读)。
- **修法(marker 门,已落地)**:`/tmp/changxing60-vbc-loaded` 每-boot 标记。`vbc-load` 只在该标记存在时才 snap;
  audio_structure **写成功那一刻** touch 标记(不等到 verify 结束,否则 after-snap 自己被门死);标记不存在时
  before/after 两处 snap 全部跳过(幂等比较退化为"全量重写",写入路径 10-16 实测安全)。`vbc-dump` 独立运行时同样
  门住 turning0(1–3 照常),`CHANGXING60_VBC_ALLOW_UNLOADED=1` 是给 Android 侧 dump 流程的显式越权
  (Android 上造不出这个标记)。顺手改了 vbc-dump 的 README:回写示例原来教 `bs=65536` —— 那正是 10-16 记录过的
  "124728 B 的 dsp_vbc 被切成两次 write、第二次无 magic 被拒"的坑,改成"bs ≥ 文件大小、单一 write()"。
  两脚本另加 `CHANGXING60_VBC_DEV_PREFIX` 覆盖点(照 voice-audio 的 `…TURNING` 先例),纯粹为了能在主机上测。
- **验证**:主机 `tools/voice/test-vbc-load.sh` **31/31**(冷启动只读一次/热启动零写/--check 零读/structure 没落地时
  标记不置位且 after-snap 也不发生/真 dump 解析器对 40 B 合成 profile 全过);设备侧实测:独立跑 vbc-dump ⇒
  turning0 `refused`、1/2/3 `Out of memory`(与预判逐字一致)、`vbc-load --check` ⇒ 三条 would-load + 日志
  `snap: skipped`、标记仍不存在、**uptime 未断、dmesg 零新增 oops**;仓库↔设备 md5 一致(`e3f5dfb5…`/`2fb7bb94…`)。
  `check-scripts` 收口 **193/0**。
- **当前姿态**:设备上三个音频脚本(vbc-load/vbc-dump/voice-audio)保持 **644** = 通话音频挂起裁定的开关
  (`[ -x ]` 守卫就是为此写的);boot X 那次 panic 的前提(S20 首次真跑)不会再以崩溃形态复发 —— 即使日后 chmod +x 或
  重编镜像把 755 带回来,冷启动路径也已经是"跳读→写→置标→回读→验证"。恢复音频时从这条链开始,不再欠验证。
- **救回过程**(可复用):Android 侧 root 下取 pstore → 用 `tools/android-mount-changxing60root.sh` 的思路手工
  losetup/mount(注意:该脚本判 `fs label=changxing60root`,本机 label 仍是 **`mu300root`** 会直接中止,需手工做);
  **OpenWrt 根嵌套在挂载点的 `openwrt/` 下**,不是根目录;把 vbc-load/vbc-dump/voice-audio chmod 644 解除武装;
  misc@2048 写回 slot-b 状态(`work/boot-linux-slotb.img` 同批的 `.misc-slot-b-trial.bin`,八份逐字节相同)→ `adb reboot`。
  细节与"任何重启都回 OpenWrt"的落点规则见 [[changxing60-reboot-boot-slot]] 与 access.md。
