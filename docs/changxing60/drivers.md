# 驱动适配 —— 用 Android 侧当参照,把 OpenWrt 缺的驱动补齐

> **状态(2026-10-16,已上机复验)**:第一轮已上机。25 个模块已装进 rootfs 并随启动加载;
> 其中 **crypto / usbnet 在默认组,而 misc 那 13 个走 `/etc/changxing60/vendor-good`(默认路径的
> `load_good()` 每 boot 照装)** —— 组开关仍关着,别被它骗了,来龙去脉见 §4.1 的 CFI 事故 + 自动二分。
> 触摸三个模块**已装但不加载**(策略见 §6)。缺口表、`vendor-modules` / `touch-ctl` / `bootdiag`
> 三个脚本与 `changxing60-hw` 的挂钩都在 `changxing60-linux/openwrt/overlay/` 里(源码即真相);
> **设备上跑的已经是这份仓库现算的字节**(`--stage` 于 10-16 做过,流程见 §4.2)。
>
> **2026-10-16 USB 断线已修好并复验(本文件 §2.1)**:不是驱动缺口,也不是 `sipa_dele` 回归,而是
> **我们自己给 6.18 打的 DTB 补丁把 `dummyphy` 关掉了**,而 `vendor_boot_b` 里那棵 DTB 是
> **5.4 OpenWrt 启动也照读的同一棵** → 没有 usb2.0 phy provider → 没有 UDC → 每次开机都
> "起来了但连不上"。修法是 9 字节原地改回 `okay`(`mainline-7552n/tools/vendor-dtb-status.py`
> + `tools/changxing60-dtb-fix.sh`),**不用重打包、不用刷整镜像**。已做:`changxing60-verify-usb.sh`
> **`VERIFY-USB-OK (PASS=9)`**,重启复跑仍 9/9。
>
> **验证结果集中在 §8**(25 个模块逐条落定 + "别当成回归"的已知噪声清单)。触摸仍是"装上 + 不加载",
> **没有真的开过**(§6)。

## 1. 先说结论

- **DTB 不用为"缺驱动"而改**。跑着的设备树就是厂商给的那棵(§2),触摸、传感器、充电、显示等节点都在,
  `status=okay`。缺的从来不是"设备树里没有",而是**我们自编内核没把对应驱动编出来 / 没装进 rootfs**。
  **唯一的例外正是 §2.1**:我们自己给 6.18 打的补丁把 `dummyphy` 关成了 `disabled`,连带废掉 5.4 的 USB;
  那 9 字节已改回 `okay`。换句话说——"不改 DTB"这句对"补驱动"成立,**对"我们自己留下的改动"不成立**。
- Android 侧实测加载了 **199** 个模块;OpenWrt 两套模块集(initramfs `/linux-modules` 94 个 +
  rootfs `/lib/modules/<rel>` 117 个)合起来覆盖 **115** 个 → **85 个驱动 Android 有、OpenWrt 没有**。
- 这 85 个里:**25 个我们树里已经编好了**(这一轮补上);**若干能编但配置没开**(§5,要重编内核模块);
  **其余本树没有源码**(§5、§6,补不了)。

## 2. 为什么是"不用改 DTB"

设备树不从 boot_b 来——`boot_b` 里只有 kernel + ramdisk(实测:ramdisk 里没有 `.dtb`,
kernel 段内也没有 `d00dfeed` 魔数)。**DT 由 LK 从 `vendor_boot_b` / `dtbo_b` 按
`androidboot.dtbo_idx=0` 取**,Android 和 OpenWrt 走的是同一个 bootloader、同一个 dtbo_idx。

**但这句话只到"同一套取法",不到"同一棵树"**(2026-10-16 修正,见 §2.1):
LK 按 **slot** 取 `vendor_boot_a` / `vendor_boot_b`,而 Android 在 slot a、OpenWrt 在 slot b ——
所以**两边读的是两个不同分区里的两棵 DTB**。`vendor_boot_a` 一直是原厂的,
`vendor_boot_b` 被我们为 6.18 mainline 改过(`patch-vendor-dtb.py`)。

实测方法(Android 侧,只读):

```
find /sys/firmware/devicetree/base -name compatible   # 每个节点的 compatible
find /sys/firmware/devicetree/base -name status       # 113 个 status,其中 40 个 disabled
```

- 触摸节点在:`soc/ap-apb/spi@70000/touch_spi@0`,`compatible = "axs15205,axs15205_touch"`,
  **没有 disabled**(即 okay)。
- 40 个 `disabled` 节点是**厂商自己在 dts 里关的**(6 个 I2C 控制器、`spi@80000`、
  `mipi-csi-phy0..3`、`iommu@3C000000`、`dptx@31890000`、PMIC 里几路 DCDC/LDO……)。
  想开它们就得改 dtbo 分区(重编 overlay + 刷 `dtbo_b`)——**这台机器现在只有内屏和 USB 两条
  管理通路,不值得为它们冒险**,列为不做。
- 另一条独立证据:initramfs 的 persist 区(`boot_b` 56 MiB 处 4 MiB 窗口,进 Android 可读)里
  的内核日志显示 DPU/DSI/PMIC/gpio/i2c 都在正常 probe,DT 显然是对的。

> 顺带记住那条老教训:**Android 出厂 `.ko` 不能装到我们内核上**。Android 侧
> `uname -r` = `5.4.254-android12-9-gd5a8ab235157`,我们跑的是自编 `5.4.254-gb50db5b6224c`,
> vermagic 不同直接拒载;符号 CRC 也不保证。所以"适配"= **在本树里编出来**,不是从
> `/vendor/lib/modules` 拷(那 150 个里能用的只有源码重编的部分)。

## 2.1 DTB 回归:vendor_boot_b 是两个内核共用的(2026-10-14 → 10-16)

**现象**:OpenWrt 每次都正常起来,但 USB 死活不出现 —— `adb devices` 空、Windows 侧没有 NCM
网卡、`192.168.77.1` 打不开;而蜂窝/SIPA 一切正常。也就是说**机器在跑,只是没有任何入口**。

**根因链**(内核日志逐环):

```
soc/ipa-apb/dummyphy 在 DTB 里被 6.18 补丁设成 status="disabled"
  → of_platform_default_populate_init 不给它建 platform device
  → phy_sprd_dummy 驱动注册了但永远不 probe(initcall 328 µs 返回 0、refcount 0)
  → 没有任何 usb_phy 为这个节点注册
  → dwc3-sprd glue 的 devm_usb_get_phy_by_phandle(dev,"usb-phy",0) 失败
     ("dwc3-sprd 25100000.usb3: unable to get usb2.0 phy device")
  → 没有 /sys/class/udc → configfs gadget 永不上挂 → 没有 usb0
```

判据(**看状态,不看日志** —— 上面这条不是修辞,见下表倒数第二行):

| 项 | 好启动(09-18 / 10-12 / 10-16 修好之后) | 坏启动(10-16 修好之前) |
|---|---|---|
| `soc:ipa-apb:dummyphy` 的 driver 软链 | `→ /sys/bus/platform/drivers/sprd-dummy-phy` | 没有软链(驱动注册着,但永远不 probe) |
| `/proc/modules` 里 `phy_sprd_dummy` 的引用数 | `phy_sprd_dummy <size> 2`(被 dwc3 glue 持有) | `… 0` —— 节点 disabled ⇒ 无设备 ⇒ 无人持有 |
| UDC | `udc=25100000.dwc3` | `udc=none available=` |
| 谁先 taint(第一条 OOT 模块) | `phy_sprd_dummy` | `sipa_dele` |
| ~~`sprd_dummy_phy_probe enter`、`probe of soc:ipa-apb:dummyphy returned 1`~~ | —— | —— **不再当判据**。它们是 debug print,而 2026-10-16 08:12 那次**真正把 USB 修好**的开机里两条都没有;照原表判,会把一台好机器判成坏的 |

最后一行是这次踩的坑:这两个 print 之所以消失,是因为那次开机根本没走"重新 probe"这条路
(节点在 boot 时就是 okay 的),而不是因为它坏了。**判据要取状态(软链 / 引用数 / UDC),
日志里的 print 只在你恰好重放同一个现场时才对得上。** `tools/changxing60-verify-usb.sh` 就是照
上表前两行判的,9 项全 PASS 才算过。

**源码级证据(为什么只能改 DTB,模块侧绕不过去)**:5.4 这棵树里,
`drivers/usb/phy/phy.c:52` 的 `__of_usb_find_phy()` 第一件事就是判可用性 ——

```c
static struct usb_phy *__of_usb_find_phy(struct device_node *node)
{
	if (!of_device_is_available(node))
		return ERR_PTR(-ENODEV);          // ← disabled 的节点在这里就被挡掉,根本不走下面的链表
	list_for_each_entry(phy, &phy_list, head) { if (node != phy->dev->of_node) continue; return phy; }
```

而 `dwc3-sprd.c:1382` 的 glue 把它当致命错误(`ret = PTR_ERR(...)`, `goto err_ipa_clk`)。
更要紧的是 `phy.c:513` 还要求 `try_module_get(phy->dev->driver->owner)` —— **phy 的设备必须真被
某个 driver 绑上**。这两条合起来意味着:任何"我们自己造一个 usb_phy 挂上去"的模块级绕法都无效
(节点 disabled 时连链表都不查),**唯一的杠杆就是 DTB 里那一位**。

**时间线**(决定性):所有 USB 正常的启动日志都是 2026-09-18 和 10-12 的;
`work/vendor_boot_b-7552n.img`(带 6.18 DTB)**造于 10-14 05:12**;10-14 之后唯一一份
可读的启动日志 `work/lastboot/persist4.txt`(10-16)是 `probe=0 / udc=none`。
前/后分界干净。

**为什么查了两轮才到**:第一轮只比"启动镜像",结论是"唯一差异 = `linux-modules/sipa-dele.ko`
40464→41344",于是怀疑是我们自己重编的 SIPA 补丁 —— **方向错了**;第二轮怀疑模块顺序/竞态,
也错。差异其实在**另一个分区**(`vendor_boot_b`),不在 boot 镜像里;而 `sipa_dele` 那条
"谁先 taint"的线索只是它恰好在这个窗口里被替换过(`intree=Y` 标记没了,所以它抢到了第一条
taint),与 USB 无关。**教训:内核日志里的"唯一不同"必须按分区/按证据面摊开,不能只摊开机镜像。**

**修法(9 字节,原地)**:`disabled\0` 是 9 字节、`okay` 是 5 字节,值都按 4 字节对齐,所以把
**值写成 `"okay\0\0\0\0\0"`(长度字段仍是 9)**就恰好占满原来那 12 字节的 slot ——
blob 大小、dtb_table_entry、AVB 全都不用动,也不经 dtc 往返。内核侧 `of_device_is_available()`
只做 `strcmp(value,"okay")`,遇到第一个 NUL 就停 = 与 `"okay"` 完全等价。

```
mainline-7552n/tools/vendor-dtb-status.py --image <vendor_boot_b.img> --node dummyphy --show
mainline-7552n/tools/vendor-dtb-status.py --image <in> --node dummyphy --set okay --prep <dir>
tools/changxing60-dtb-fix.sh          # Android 侧走 adb 全自动(备份→比对 sha→写 9 字节→全分区 sha 回验→装 slot b)
tools/changxing60-back-to-openwrt.sh  # 一把做完三件事:重装适配 payload(§4.2,必须最先)→ 上面这套 → 重启 → 验 USB
```

**顺序不是随口排的**:当时设备上那份 `vendor-modules` 还是 02:42 的快照(默认组含 `misc`),先重启就会
在装上 DTB 修法的同一次开机里撞 `CFI failure` —— 所以"重装 payload"必须排在"重启"之前,
`changxing60-back-to-openwrt.sh` 就是照这个顺序钉的(每步按自己的 OK 标记放行,缺一个就停,绝不半成品重启)。
**这条顺序不只是当时的权宜**:只要设备上那份 payload 落后于仓库,同样的陷阱就还在。
这条顺序**已于 2026-10-16 按序执行完**:payload 先换成仓库现算的那份(默认组 `crypto usbnet`),
再写 DTB 9 字节 + 装 slot b,再重启,没有再撞 CFI。

**已实测(2026-10-16)**:`tools/changxing60-verify-usb.sh` → **`VERIFY-USB-OK (PASS=9)`**;
之后又**重启一次复跑**,仍然 9 项全 PASS(`work/verify-usb-20261016-0854/device.txt`),
adb 空 + NCM gadget 在(在 OpenWrt 而非 Android)、宿主拿到 `192.168.77.199`。
所以 §2.1 这条到今天就闭合了:**DTB 是唯一的杠杆,而它已经扳回来了。**

反方向(`okay` → `disabled`,6.18 要用)塞不进 padding,**必须**回到 `patch-vendor-dtb.py` 重打包;
`flash-7552n.sh` 里已经写了这条提醒。**别再把 `vendor_boot_b` 当成"只影响 6.18"的分区。**

```
find /sys/firmware/devicetree/base -name compatible   # 每个节点的 compatible
find /sys/firmware/devicetree/base -name status       # 113 个 status,其中 40 个 disabled
```

- 触摸节点在:`soc/ap-apb/spi@70000/touch_spi@0`,`compatible = "axs15205,axs15205_touch"`,
  **没有 disabled**(即 okay)。
- 40 个 `disabled` 节点是**厂商自己在 dts 里关的**(6 个 I2C 控制器、`spi@80000`、
  `mipi-csi-phy0..3`、`iommu@3C000000`、`dptx@31890000`、PMIC 里几路 DCDC/LDO……)。
  想开它们就得改 dtbo 分区(重编 overlay + 刷 `dtbo_b`)——**这台机器现在只有内屏和 USB 两条
  管理通路,不值得为它们冒险**,列为不做。
- 另一条独立证据:initramfs 的 persist 区(`boot_b` 56 MiB 处 4 MiB 窗口,进 Android 可读)里
  的内核日志显示 DPU/DSI/PMIC/gpio/i2c 都在正常 probe,DT 显然是对的。

> 顺带记住那条老教训:**Android 出厂 `.ko` 不能装到我们内核上**。Android 侧
> `uname -r` = `5.4.254-android12-9-gd5a8ab235157`,我们跑的是自编 `5.4.254-gb50db5b6224c`,
> vermagic 不同直接拒载;符号 CRC 也不保证。所以"适配"= **在本树里编出来**,不是从
> `/vendor/lib/modules` 拷(那 150 个里能用的只有源码重编的部分)。

## 3. 缺口表怎么算的

参照面(Android 侧,只读采集;脚本 `changxing60-linux/work/gather-dt.sh`、`gather-bind.sh`):

1. `/proc/modules` → **199 个实际加载的模块名**(内部名,不是文件名)。
2. `/sys/bus/{platform,spi,i2c}/devices/*/` 的 `of_node` + `driver/module` 软链 →
   **节点 → 驱动 → 模块** 的绑定表(396 行),这样才知道每个模块管的是 DT 里哪个节点。
3. `/vendor/lib/modules/{modules.alias,modules.dep}` + `firmware-list.txt` + `/proc/config.gz`。

对照面:OpenWrt 的 `linux-modules/`(ramdisk,`/etc/module-order` 94 个)+ 设备上实际装着的
`/openwrt/lib/modules/5.4.254-gb50db5b6224c`(117 个)。

比对时必须**按模块内部名**(`.modinfo` 的 `name=`)对齐:同一批源码里文件名有连字符
(`spi-sprd.ko`)、内部名是下划线(`spi_sprd`),直接比文件名会凭空多出几十个"缺口"。

## 4. 这一轮补上的 25 个(已上机)

装法是 rootfs 就地补文件(Android 侧挂 ext4 写,一条命令 `tools/stage-adapt.sh --stage`:现算 payload →
推 → 装 → 回验设备上的字节,见 §4.2),每个 `.ko` 落盘后按 sha256 回验,启动加载由
`/opt/changxing60/bin/vendor-modules` 负责,挂在 `changxing60-hw`(S12)里,每次加载 `timeout 15` 兜底。

| 组 | 模块 | 为什么 |
|---|---|---|
| **crypto**(默认加载) | `aes-neon-blk` `aes-ce-ccm` `ghash-ce` `sha1-ce` `arc4` `twofish_common` `twofish_generic` | 把 AES/GHASH/SHA1 交给 CPU 指令(PMULL/CE)。不 probe 硬件、不建设备节点,只是让内核 crypto API 变快 —— WPA 握手、OpenVPN、Clash 的 TLS 都吃这个 |
| **usbnet**(默认加载) | `asix` `ax88179_178a` | OTG 口插 USB 网卡时可用;没插就是零动作 |
| **misc**(组开关仍关着,**但这 13 个照装**) | `virt-dma` `sprd-dma` `apsys-dvfs` `sprd_map` `misc_sprd_uid` `ion_ipc_trusty` `ion_cma_heap` `zte_bootreason` `zte_stats_info` `board_state` `smartpa_stat` `ledtrig-pattern` `sensorhub` | Android 开机就加载的厂商胶水:传感器 hub、ION 堆、DMA 引擎、AP/DPU/GSP DVFS、uid/stats/bootreason、状态灯 pattern。**没有它们网络也照样跑**,所以放在 S12 而不是 initramfs(那儿加载失败=开不了机)。2026-10-16 第一次整体加载时某个模块注册完约 3 秒后内核 `CFI failure (target: 0x0)`(定时器回调是 NULL)当场死机,元凶未定 —— 于是做了 bisect。**bisect 已收敛(同日):13 个全进 `/etc/changxing60/vendor-good`,`vendor-bad` 空**,而 `vendor-good` 是默认路径的一部分(`load_good()`),**所以每个开机照装**。注意别被"组开关是关的"骗了:关的只是 `group_misc()`,不是这些模块 |
| **touch**(装了,**不加载**) | `spi-sprd` `lcd_state_notify` `zte_tpd` | 见 §6 |

顺序有讲究的地方(脚本里写死了):`virt-dma` 在 `sprd-dma` 前、`ion_ipc_trusty` 在 `ion_cma_heap` 前、
`spi-sprd` 在 `zte_tpd` 前、`lcd_state_notify` 在 `zte_tpd` 前。其余依赖(`zlog_common_dlkm`、
`kfifo_buf`、`sipc-core`、`sprd_soc_id`、`sprd_systimer`、`trusty-ipc`)启动模块集里已经有了。

### 4.1 CFI 事故 + 自动二分(以及第一版二分"判对过、也判错过")

2026-10-16 第一次把 misc 整组装上,内核在最后一个模块注册后约 3 秒 `CFI failure (target: 0x0)`
死机(某驱动 arm 了一个回调为 NULL 的定时器)。**谁干的还不知道**,而这类"加载后几秒才炸"没法
靠单次启动分辨,所以做成了设备自收敛的二分:

```
touch /etc/changxing60/vendor-bisect        # 开一次标志,下次启动 bootdiag 会拉起
vendor-modules bisect                 # 或者手动跑
vendor-modules status                 # 看默认组 / 已装 / vendor-good / vendor-bad / 日志尾巴
```

`bisect` 按 `/etc/changxing60/vendor-candidates` 一批一批来(每批一个 20 秒窗口,**加载前**先往
`/root/vendor-bisect.log` 写 `TRYING <批>`),活下来的模块追加进 `/etc/changxing60/vendor-good`
(默认路径之后就会加载它们);哪一批把内核打死,那条 `TRYING` 后面就没有 `OK`,下次启动
`bisect_verdict` 把它记进 `/etc/changxing60/vendor-bad` 并跳过 —— **一批一个重启,自己收敛到最大安全集**。
`apsys-dvfs` 排第一批,因为它自己的 probe 就报过 `No matching driver data found`,
这正是"驱动最终拿着一个没装好的回调"的典型长相。

#### 4.1.1 第一版二分把 13 个"没装进去的模块"判成了安全(2026-10-16)

`load()` 用 `timeout 15 insmod` 兜底,而 **`timeout(1)` 不在 OpenWrt 的 busybox 里** —— 它来自
`/opt/changxing60/busybox-bin`。`changxing60-hw`(启动路径)自己 `export PATH`,那边一直是对的;而 **`bootdiag`
是从 cron 拉起 `vendor-modules bisect` 的,cron 的 PATH 是 `/usr/sbin:/usr/bin:/sbin:/bin`**。
于是那一轮每个模块只回一句:

```
FAILED apsys-dvfs.ko: /opt/changxing60/bin/vendor-modules: line 51: timeout: not found
OK apsys-dvfs
```

而当时 bisect 的判据是"**熬过 20 秒窗口、内核还活着**" —— 内核当然活着。**13 个模块一个都没装,
13 条 `OK`,全部写进 `vendor-good`**。而 `vendor-good` 的定义正是"默认路径之后会加载它们",
所以这份假的"安全集"会被下一轮当成真的用。日志就摆在 `/root/vendor-bisect.log` 里,
`FAILED` 和紧邻的 `OK` 肉眼可见 —— 但没人会去读它,**因为脚本报的是 `OK`**。

修法两条,都对着这个病:

- **一个脚本一个 PATH**:`vendor-modules` 开头自己
  `PATH="$PATH:/opt/changxing60/busybox-bin:/opt/changxing60/bin"`,不再取决于谁调它(注释原话:
  "this must not depend on who calls it")。同一个坑在 §35 里害过另一批脚本(mode bit),
  但那次至少还回了 `Permission denied`;**"命令找不到"连一句抱怨都没有**。
- **判据从"内核没死"改成"模块真在 `/proc/modules` 里"**:每批窗口结束逐个查 `loaded()`,缺任何一个就写
  `SKIPPED <批> : not loaded:<模块> —— nothing proven`,**不进 `vendor-good`**。`SKIPPED` 和 `OK`
  一样算"这批有结论",所以 `bisect_verdict` 不会把它误当成"内核死在窗口里"而把批次记黑。

**收敛结果(2026-10-16,重启复跑)**:11 个批次全部 `already loaded … OK`
(默认路径 `load_good()` 已经把它们装上了,`/proc/modules` 是实话),
`/tmp/changxing60-vendor-modules.log` 里 **0 条 `FAILED` / `timeout: not found`**,
`dmesg | grep -c "CFI failure"` = **0**,`/etc/changxing60/vendor-bad` **不存在**,`status` 逐个报 `up`。
`vendor-good` 那 13 行的第一版确实是假 OK 写进去的,但此后每一轮开机都用 `/proc/modules` 重新确认过
—— **现在这份"安全集"是实的**。顺带:`apsys-dvfs` 作为"第一批嫌疑人"被排在最前面,结果它是清白的。

> 教训和 §35 同一条:一个只读**日志/退出码**的判据,能把"什么都没发生"判成"一切正常"。
> 判据要读**状态**(`/proc/modules`、软链、寄存器),而且不能依赖调用者的环境(cron 的 PATH
> 和 login shell 的不是一回事)。

**故意不加载的**(脚本注释里也写了原因):

- `sprd_u_ether`、`sprd_usb_f_rndis` —— UDC 归 initramfs 的 configfs gadget 管,Android 那套
  function 驱动会和它抢控制器。
- `spi_sprd`/`zte_tpd`(触摸,§6)、`gnss_*`(要 modem 那边配合)、`trusty-tui`(要 TEE 会话)。

### 4.2 payload 由仓库现算:不再有"快照"

第一轮的 25 个 `.ko` 和四个脚本是**手工攒在 `work/adapt/` 里**再推上去的(02:42)。等再回头看设备时,
仓库里的 overlay 已经往前走(03:10-03:13):`vendor-modules` 的默认组去掉了 `misc`(CFI 那条)、
`bootdiag` 长出 `usb_recover()` 与二分钩子 —— 而设备上跑的还是旧字节,**因为所有校验都是拿快照比快照**。
哈希只能证明"文件到了",证明不了"文件是对的"。所以那批快照已删(`work/adapt/` 连同两个一次性脚本,
后者留了三行墓碑),改成每次现算:

```
tools/stage-adapt.sh              # 组装 + 自检(不需要设备,什么都不推)
tools/stage-adapt.sh --manifest   # 只看清单
tools/stage-adapt.sh --stage      # 组装 → 推 → 在 Android 上装进 ext4 → 回验设备字节 == 仓库字节
tools/stage-adapt.sh --verify-log <存档日志>   # 事后判断"设备上跑的是不是这份仓库的字节"
tools/changxing60-back-to-openwrt.sh    # 一把回 OpenWrt:本步(必须最先)→ §2.1 的 DTB 修法 → 重启 → 验 USB
```

- **模块从 `out-linux/` 取**(跑在板子上的那棵构建),逐个验 `vermagic=5.4.254-gb50db5b6224c`,
  对不上直接拒装 —— 换了构建没重编内核,在这里就会撞墙而不是在设备上 `insmod` 失败;
- **四个脚本从 `openwrt/overlay/` 取**(源码即真相),宿主机 `sh -n` 预检;
  ⚠ 这份"真相"曾经只活在工作区(该树新增的部分整个未被 git 跟踪),已于 2026-10-16 落盘 ——
  见 §8 最后一条;
- **`opt/manifest.tsv` 由装载器反读**:分组与顺序都照 `vendor-modules` 的 `group_*()` 与 `touch-ctl`
  的 `LOAD=`(misc 组顺序是承重的:virt-dma 在 sprd-dma 前、ion_ipc_trusty 在 ion_cma_heap 前),
  再与工具里的期望清单比集合 —— 谁改了一边没改另一边,宿主机上就报错;
- 三条**按内容**的断言(哈希查不出这些):默认组必须是 `crypto usbnet`;`bootdiag` 必须带
  `usb_recover` 与二分钩子;除 `touch-ctl` 外没有任何启动/cron 路径能碰到触摸模块;
- **`openwrt/overlay/` 与 `rootfs/overlay/` 两棵树**:`build-rootfs.sh` 先铺后者再铺前者,所以前者赢。
  凡是"盒子最终跑什么"的判断,读的都是赢家(如 `extra-modules`/`display-modules` 只在旧树里,
  但仍是启动路径的一部分)。

设备侧那半(`tools/changxing60-android-stage-adapt.sh`)除了落盘回验,还查一件哈希永远查不出的事:
**同一个脚本在 `/opt/changxing60/bin` 之外还有没有一份、且真被谁调用** —— 这才是"服务跑的是旧的而检查
照样通过"的正主(只多一份没人调用的,只警告)。

> 这套断言不是第一次跑在设备上:设备脚本在宿主机上用**假 rootfs + stub `mount`/`getenforce`**
> 整场排练过 —— 清洁路径报 `CHANGXING60-ADAPT-OK`;六种坏法各自报对自己那条错(改名 `usb_recover`、
> 去掉二分钩子、默认组塞回 `misc`、丢 `bisect_verdict`、`extra-modules` 里加载 `zte_tpd`、
> payload 少模块);重跑幂等(crontab 不会写第二行 `bootdiag`)。`--verify-log` 拿真报告验过,
> 也能点名"设备上还是 02:42 那版 `vendor-modules`"。

## 5. 补不上 / 还没补的

**能编但配置没开**(源码在本树,要改 `kernel/changxing60-linux.fragment` + 重编 + 再 stage):

| 模块 | 源码位置 | 说明 |
|---|---|---|
| `sprd_sensor` | `drivers/vendor/common/sensor` | 传感器 hub 的 I2C 侧(`sensor_main`/`sensor_sub`)。`sensorhub` 这一轮装了,但没有它就只有 hub 没有器件 |
| `flash_ic_*`、`sprd_flash_drv` | `drivers/vendor/leds` 等 | 手电/闪光灯 |
| `zte_lcdbl_vsp_vsn` 之外的 `zte_lcdbl` 变体 | `drivers/vendor/zte_lcdbl` | 显示偏压,现有那份够用 |

**本树根本没有源**(要么只在 mainline 6.18 树里,要么在别的厂商仓库):

- **蓝牙 `sprdbt_tty`** —— 只有 mainline 6.18 版(`vermagic 6.18.56`),5.4 树里没有对应的 tty 驱动,
  所以 `bluetooth-start` 这条路在 5.4 上仍然走不通(与既有结论一致)。
- **音频整栈**:`snd_soc_sprd_*`、`audio_pipe`、`audio_sipc`、`audio_mem`、`sprd_apipe`、
  `sprd_audcp_boot/dvfs`、`voice_trigger_irq`、`mcdt_hw_r2p0`(5.4 树里 `sound/soc/sprd` 只剩
  mcdt/pcm 几个文件)。
- **相机/视频/NPU**:`sprd_camera`、`sprd_cpp`、`vpu`、`jpg`、`sprd_vdsp`、`npu_img_vha`、
  `sprd_camsys_pw_domain`、`mmdvfs`。
- **其它**:`sprd_ion`、`sprd_gsp`、`sprd_fm`、`agdsp_access`、`audio_dsp_dump`。

这些不是"没配好",是那份 5.4 源码树本身就没有(F50 那份 config 是给无屏无音频的机型裁的)。

## 6. 触摸:可以适配,默认关

**这一轮做的事**:把 `spi-sprd`(AP SPI 控制器)、`lcd_state_notify`、`zte_tpd`(ZTE TPD 框架 +
`axs15205` 控制器驱动)三个模块**装进 rootfs**,但**没有任何启动路径加载它们**:

- `vendor-modules` 的三组里没有它们;
- `extra-modules` / `display-modules` 里也没有(后者的注释本来就这么写着);
- 唯一的触发点是 `/opt/changxing60/bin/touch-ctl`,而它只在**显式调用**或
  `/etc/changxing60/touch` 里写着 `on` 时才动 `/etc/changxing60/touch` —— 那个文件默认不存在。

要开(自己确认面板/触摸没问题时):

```sh
touch-ctl on              # 现在加载(重启即恢复关闭)
touch-ctl on --persist    # 同时写 /etc/changxing60/touch,以后每次启动都加载
touch-ctl status          # 看模块在不在、输入层有没有 axs_ts
touch-ctl off             # 卸载并清掉 persist 标志
```

触摸固件不用担心:`axs_firmware_*.bin` 是**编进内核**的(`CONFIG_EXTRA_FIRMWARE`,见
`kernel/build-linux.sh` 那份 config / `out-linux/drivers/base/firmware_loader/builtin/`),
rootfs 里不需要 `/lib/firmware` 副本。

判据:加载成功时 `/proc/bus/input/devices` 会出现 `Name="axs_ts"`;失败看
`dmesg | grep -i tpd`。

## 7. 再加一个驱动:五步

1. **找源**:先看本树有没有 —— `docker run --rm -v changxing60-kernel:/src:ro busybox sh -c 'find /src/zte-u30air -name "<关键词>*"'`。
2. **开配置**:改 `kernel/changxing60-linux.fragment`(加 `CONFIG_XXX=m`),重跑 `kernel/build-linux.sh`
   (容器 `changxing60-kbuild`,见脚本头),产物落在 `out-linux/`。被 Kconfig 拒的项会写进 `kernel/fragment-rejected.txt`。
3. **对依赖**:用 `tools/stage-modules.py` 的 `modinfo()` 读 `depends=`,闭包补齐;
   依赖必须也在同一棵构建里(vermagic 一致)。
4. **装到设备**:把模块名加进 `tools/stage-adapt.sh` 的期望清单(它会和 `vendor-modules` 的
   `group_*()`/`touch-ctl` 的 `LOAD=` 比集合,对不上就拒装),然后 `tools/stage-adapt.sh --stage`。
   它自己挂 rootfs(`tools/android-mount-changxing60root.sh`,**会在挂载期间把 SELinux 置 permissive、
   卸载时还原**——ext4 日志重放是 loop kworker 以 `u:r:kernel:s0` 发的写,不放宽就被拒,而
   `mount` 只会报 I/O error)→ 拷进 `/openwrt/lib/modules/5.4.254-gb50db5b6224c/` → 逐个回验 sha256。
5. **加载策略**:进 `vendor-modules` 的某一组(带 `timeout 15`),或者只在 `touch-ctl` 那样的
   显式开关后面。**别进 initramfs 的 `/etc/module-order`**:那里加载失败=开不了机。

## 8. 验证 / 未验证

- ✅ 25 个 `.ko` 上机落盘 + sha256 回验;`vendor-modules` / `touch-ctl` / `bootdiag` 在设备侧用
  它自己的 busybox `ash -n` 过了语法;`changxing60-hw` 两个挂钩在位(`vendor-modules` 调用 +
  bootdiag 的 cron 行)。
- ✅ `touch` 三条路径都不被启动加载(grep 过 `extra-modules`/`display-modules`/`vendor-modules`/`bootdiag`)。
- ✅ `tools/stage-adapt.sh` 的组装 + 断言链(§4.2):宿主机排练清洁路径与六种坏法、重跑幂等;
  `--verify-log` 能用存档报告点名"设备上是哪一版字节"(对 02:42 那版 sha 实测报错)。
- ✅ **`--stage` 已做完(2026-10-16),且排在改 DTB 的那次重启之前** —— 这正是 §2.1 要求的顺序,
  那一次开机没有 panic。设备上跑的 `vendor-modules` 已是仓库现算的那份(默认组 `crypto usbnet`,
  不再是 02:42 那个含 `misc` 的快照)。
- ✅ **DTB 那条链设备上也跑过了(2026-10-16)**:`tools/changxing60-verify-usb.sh` → **`VERIFY-USB-OK (PASS=9)`**,
  **重启后再跑一遍仍然 9/9**(`work/verify-usb-20261016-0854/device.txt`)。判据见 §2.1 的表。
- ✅ **13 个 misc 模块的实际加载结果(2026-10-16 重启复核,U≈450s)**:
  `status` 逐个 `up`(137 个来自 stage 目录的模块在跑);`/tmp/changxing60-vendor-modules.log` 里
  **0 条 `FAILED` / `timeout: not found`**;bisect 11 批全部 `already loaded … OK` 后 `BISECT-DONE`;
  `/etc/changxing60/vendor-bad` 不存在;`dmesg | grep -c "CFI failure"` = **0**。
  日志与逐批记录:`/root/vendor-bisect.log`;bootdiag 的 `/root/diag/*.log`(每分钟一份,前 15 分钟)。
- ✅ **同一轮重启顺带证的**(细节在 `FINDINGS.md` §35 与 [`README.md`](README.md) 的铁律):模式位修好后,
  `hotspotwatch`/`chargefix` 等 6 个 procd 实例由启动路径自己起来(不再需要手工 `nohup`),
  `hotspot-watch`/`ndp-learn` 都是启动早期的低 pid;`charge-fix` 的四个钉住值在
  (`Reg[00]=0x0b 02=0x90 03=0x22 04=0x80`);`quiet-console` 写的 `printk = 4 4 1 4` 在位;
  `br-wifi` 仍在 `lan` zone,运营商 /64 的 **metric 128** 回程路由按**新前缀**重新学到
  (`2409:894a:32d:807::/64`,重启前是 `2409:8947:…`)。
- ⏳ `sensorhub` 装上后能不能真的出 `/dev/iio:device*`(**暂时算"不能"**):`probe of sprd-sensorhub
  returned 1`、`sipc_sensorhub_id=9`,hub 本身是活的;但 `/dev/iio:device0`、`iio:device1` 的属主是
  **`sc27xx-adc`(PMIC ADC)**(`/sys/bus/iio/devices/iio:device0/driver → …/spi4.0/sc27xx-adc/`),
  **不是传感器器件**。原猜测(缺 `sprd_sensor` ⇒ 只有 hub 没有器件)成立。
- ⏳ 触摸只到"装好、不加载";**真开一次**是另一件事,要单独确认。
- ✅ **仓库侧也落盘了(2026-10-16,`changxing60-linux@7117348`)** —— 这条本来是缺口,现在闭合:
  - 适配 payload 的"源码即真相"`openwrt/overlay/`(含 `opt/changxing60/bin/` 13 个文件、`etc/changxing60/`、`www/`、
    `usr/share/`、`etc/init.d/changxing60-power`)此前**从未被跟踪**,该提交把它连同 `changxing60-hw`/`changxing60-ndp`/
    `90-changxing60` 的修改一起入库。
  - §35 那 9 个 x 位里,6 个被跟踪的此前在 HEAD 仍是 `100644`(**改的只是工作区、`git diff` 看不出来**),
    该提交把 9 个全部置成 `100755` —— 这才是"修好了"在 git 里的定义。
  - **判据是 `git ls-files -s`,不是 `ls -l`**:磁盘、设备、`git diff` 在那一天里三者都是对的,只有索引还写着
    旧模式。同批源码提交的还有 `tools/`、`mainline-7552n/`、`container/`、`clash/` 的脚本与 `upstream/`
  的 mali 源码树(共 642 项、7.8 MiB)。
  - **仍未入库的**(按 `.gitignore` 既有口径,二进制/构建产物不收):`clash/bin/mihomo`、`clash/ui/dist`
    面板产物、`container/overlay/opt/changxing60/bin/sing-box`、`tools/modem-ioctl`(3 KB,可由
    `tools/build-modem-ioctl.sh` 重建);`container/*.tar.gz` 本来就被 `*.tar.gz` 忽略。

**已知噪声(别当成本轮适配的回归)**:同一份 dmesg/开机日志里还有一串东西,都**早于**这一轮、每次都出现 ——

| 现象 | 位置/时机 | 是什么 |
|---|---|---|
| 10 条 `WARNING … device_create_file+0x94` / `sysfs_create_file_ns+0xa4`,`Comm: insmod` | t=4~15s | 启动模块集那批 insmod 重复注册 sysfs 属性。既有,无害 |
| 3 条 `BUG: Bad page state … nonzero mapcount`,`page dumped because: nonzero mapcount` | t≈201s,紧跟 `[drm] free logo memory addr:0xb0000000` | 显示栈(`sprd-drm`,S95)释放开机 logo 内存时的 mapcount 记账问题。**每次开机都 3 条**(上一次开机的 `/root/diag/00433s.log` 里同样是 3 条),屏照常亮,不致命 |
| `mmc2: sprd-sdhci: CMD52/CMD5 Error 0x00018001 …` | 启动早期成片 | SDIO/WCN 卡初始化重试噪声,既有 |
| `sprd-vpu-pd … regmap fail` / `[drm] dpu_context_init read … failed, use default` | t≈201s(S95 显示栈装载期) | DT 缺可选节点,驱动打一行后走默认值。无害 |
| `policy: charger_policy_get_prop_by_name(): get dc psy failed!!`(+`check_usb_present`) | 全程每几秒一对 | conflicts.md §A1 已定案:在跑的 sqc_v8 那份 psy 在 `!info->charging` 时恒返回 0,厂商 charger-manager 取不到板温/dc 就周期报错;实际在干活的是我们钉的四值 + cron,与本条无关 |
| `/tmp/changxing60-extra-modules.log`:`FAILED zte_sar: no message from modprobe` | t≈200s,一行 | `zte_sar` 的 ko 本来就没装进镜像;kmodloader **立刻返回、不产生等待**(紧后面 `mali_kbase` 就 `loaded` 了)。纪律照旧:`FAILED` 那行本身不算证据(当年 `mali_kbase` 的 FAILED 是另一回事,判据是清单) |

## 8.1 开机耗时基线:post 落笔 = uptime 202 s(2026-10-17 两次独立开机对账)

用户问过"开机这么久是不是撞了报错"。**不是——慢是结构性的,而且两次开机的节奏逐秒一致。**

- **锚点**:`changxing60-post` 往 `/etc/changxing60/boot-history` 写的那行,boot Z 记 `uptime=202`
  (13:08:11)、E1/E5 验收那次也记 `uptime=202`(14:08:58);ssh 首次可用约 **240 s**。
- **时间都花在哪**(dmesg 环 + bootdiag 首快照还原):
  - 0–30 s:U-Boot → 内核 → trusty/PMIC;
  - 30–195 s:安卓 init → modem_control(chroot,`rstoff@32.5s`)→ switch_root → OpenWrt rc 服务链。
    这段内核环里**只有 `sprd_wdt_fiq` 每 8 s 的心跳行**;142→197 s 连续 55 s 零输出——是脚本在推进,
    **不是错误驱动的等待**(内核静默≠卡住,用户态动作不进 dmesg);
  - 195–204 s:尾段模块集中装载(phy0 @197.6 s、音频/guard ko @201.6 s、显示栈 @201.7 s)
    + netifd/hostapd/post 收尾。syslogd 要到这一拍才上岗,所以 50–195 s **不会有服务日志**——别把
    "logread 里没启动过程"当成"没发生"。
- **三条对账**(怀疑"这次开机异常慢"就按这个顺序查,全干净即回到基线):
  ① `boot-history` 末行 `uptime≈202`;② `/tmp/changxing60-*.log` 五份(display/extra/net-split/vendor/
  wifi-start)repair/retry/assert 计数为 0;③ bootdiag 首快照(本 boot 约 `002xxs.log`)里只有上表噪声。
  **开机显著超过 202 s 才值得怀疑错误驱动等待**,头号嫌疑有两个先例可查:mobile-data attach 静默卡
  (`do_select`,见 sipa-wedge.md)与 wifi-fix 修复阶梯(会往 `/tmp/changxing60-wifi-start.log` 写动作)。

相关: [`screen-plan.md`](screen-plan.md)(内屏与 display-modules)、[`debug-toolbox.md`](debug-toolbox.md)
(bootdiag 与 changxing60-diag)、[`backlog.md`](backlog.md)(还有哪些没做)。
