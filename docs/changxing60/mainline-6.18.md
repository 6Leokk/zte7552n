# 主线 6.18 迁移(Track B)—— 锚点、构建、待办

对应已批准的计划(Track B:B0 取基线 → B1 构建 → B2 试启 → B3 硬件门禁 → B4 蜂窝 → B5 楔死复测 → B6 集成)。

## B0 锚点(已核实,2026-10-14)

我们的 `origin` 就是 `github.com/dikeckaan/mu300-linux`(=上游),所以 `origin/main` 就是上游 main:

```
$ git rev-parse origin/main
4106772aae5e5318436826d24b4270d5166e8bdb     # 2026-10-13 "Merge pull request #223 from dikeckaan/web-installer-e2e"
```

- **快照锚点 = `4106772aae5e`**;`upstream/` 整目录即取自这个提交(整目录替换,**不 merge 历史**,
  避开浅克隆边界 `294deb8`)。
- 分支 `mainline-6.18`(我们的 OpenWrt 层提交都在其上,含 2026-10-16 的 `7117348`)。**`upstream/` 的整目录
  替换此前长期只是 staged、未提交,已于该提交落盘**(同一提交还入库了 `openwrt/overlay/` 那棵适配树、
  `tools/` 与 9 个脚本的 x 位 —— 见 [`drivers.md`](drivers.md) §8)。
- 用途:以后挑上游的 sipa/CP 修复,就对着这个 sha 找(上游还在动,所以钉 sha 而不是跟 main)。

## B1 构建 6.18.56

**结论(2026-10-14 改):不跑 qemu,直接交叉编译。** 上游是 **arm64 原生**构建 ——
`build.sh` / `build-modules.sh` 里 `CROSS_COMPILE` 一处都没有(全仓 grep 为空),
而 `Dockerfile` 是 `FROM ubuntu:26.04` 不带 `--platform`,所以在 amd64 上照 README 跑就退化成
qemu-user 仿真(实测约慢一个数量级)。**但 build.sh 每条 make 都写了 `ARCH=arm64`** ——
交叉编译缺的只有 `CROSS_COMPILE`,而 GNU make 会直接从环境变量取它,**不用改上游任何文件**:

```sh
docker build -t changxing60-cross -f tools/Dockerfile.mainline-cross changxing60-linux/
docker run --rm -e CROSS_COMPILE=aarch64-linux-gnu- \
       -v changxing60-mainline:/src -v "$PWD/upstream":/work changxing60-cross bash /work/build.sh
```

`tools/Dockerfile.mainline-cross` = 上游 Dockerfile 的包单 + `gcc-aarch64-linux-gnu`
(+`libc6-dev-arm64-cross`);**交叉 gcc 与 arm64 镜像里那只是同一个 Ubuntu 26.04 `gcc 15.2.0`**,
所以 vermagic / 模块 ABI 两种编法完全一致。实测:同一台 Ryzen 7 7840HS(16 线程),
qemu 那份跑了 ~5 分钟才刚过 config 阶段,交叉这份 45 秒就 361 个 `.o`、2.5 分钟 1224 个,
**几分钟出 Image**(原方案是小时级)。

> **为什么不在设备上(7552N,真 arm64 8 核)编**:思路本身不荒谬(原生肯定快过仿真),
> 但三条否决理由 —— ①OpenWrt rootfs 里**没有任何编译器**,得先 bootstrap 一套 Ubuntu arm64
> userland(~1 GB)再 chroot;②**它正是楔死实验的观测对象**,`-j8` 满载跑半小时会污染现场
> (§6.1 已经有过"一次楔死与 8 线程满载同时发生、触发源无法归因"的先例);
> ③`mobile-data` 的最后手段重启能在编译中把它干掉。而交叉编译这几个问题一个都没有。
> 原 qemu 命令(仅作存档):`docker run --platform linux/arm64 …`。

```sh
docker volume create changxing60-mainline     # 源码树与 O= 都在这里;/src/out-$KV 由 build.sh 定死,换编法前先删
docker run --rm -e CROSS_COMPILE=aarch64-linux-gnu- -v changxing60-mainline:/src -v "$PWD/upstream":/work changxing60-cross bash /work/build.sh
docker run --rm -e CROSS_COMPILE=aarch64-linux-gnu- -v changxing60-mainline:/src -v "$PWD/upstream":/work changxing60-cross bash /work/build-modules.sh
```

> `O=/src/out-$KV` 是 **build.sh 里写死的**(`OUTDIR` 只决定产物去 `/work/out*`,不影响 `O`),
> 所以**两种编法不能同时跑**,换编法前 `rm -rf /src/out-6.18.56`(源码树 `/src/linux-6.18.56` 可复用,
> 补丁循环是幂等的)。

- `build.sh` 产 `upstream/out/{Image, ums9620-mu300.dtb, modules.builtin, modules.builtin.modinfo}`;
  数据源是 `cdn.kernel.org` 的 `linux-6.18.56.tar.xz`(带 sha256 校验),下载进 volume `changxing60-mainline` 缓存。
- `build-modules.sh` 产 `upstream/out/modules/*.ko`(外置 vendor 模块 wcn_bsp / sprd_wlan_combo /
  sprdbt_tty / sprd_modem / sprd_pmic_wdt / mali / mu300_thermal + 内核自己的 `=m`)。
  ⚠ `mu300_thermal` **不是改名的漏网**——它是上游那棵树里模块自己的名字(`upstream/modules/mu300_thermal/`,
  `obj-m += mu300_thermal.o`,取自 kanoqwq 的项目),也就是 .ko 文件名,改名必须绕开它。2026-10-16 的改名
  曾在 `rootfs/overlay/opt/changxing60/bin/extra-modules` 里把它改成过 `changxing60_thermal`,
  那会让 6.18 侧 modprobe 一个两边内核都不存在的模块(已修回)。
- `build.sh` 会**硬失败**在四件事上,别绕过:补丁既不适用也非已应用、config 项 Kconfig 不接受
  (除非列在 `config-ignored.txt`)、port 编辑锚点移动、模块 vermagic 与内核不符。
- 7.2 顺带验:`KV=7.2.10 OUTDIR=out-7.2` 跑同样两条命令到 `upstream/out-7.2`(**只编不装**)。
- `upstream/make-bundle.sh` 是**上游 release 路径**(还要求一份 5.4 bundle 供 busybox/logdw,`release/` 我们这儿没有),
  **我们不走它** —— 走下面 B2 的自研机制。

## B2 试启镜像(走我们自己的机制)

1. **LK 包装是必须的**:LK 固定把内核拷到 `0x80080000`;6.18 的 `text_offset=0`(5.8 起),
   直接用会挂 → 先 `upstream/wrap-image.py upstream/out/Image upstream/out/Image.lk`(加跳转 stub 跑到 `0x80200000`)。
2. `boot/build-boot-image.py` **自己不做 LK 包装**(`grep text_offset` 无命中),所以 `--kernel` 要传 **`Image.lk`**。
   输入沿用 5.4 那套(实测文件都在):
   `--stock-boot work/dumps/boot_ori.img --misc-head work/dumps/misc-head.bin --busybox work/busybox
   --logdw tools/logdw/logdw --ueventd-perms android-vendor/ueventd-perms.sh --android-subset work/android-subset`
   (`--modules` 指 `upstream/out/modules`,`--module-order upstream/module-order.txt`,`--init boot/init`。)
3. 刷:`boot/flash-trial.sh`(只刷 **slot b** + 32 字节 misc tries;`boot_a` 全程不动;tries 兜底 → 回落 Android)。

## 坑 / 待办(开工前先读)

1. **`openwrt/build-rootfs.sh` 把主线模块目录写死成 `/lib/modules/6.18.52`** —— 得跟着 `uname -r`(6.18.56),
   否则设备上 kmodloader 找不到模块。
2. **模块要落进 ext4 rootfs 的 `/lib/modules/<6.18.56>/`**:path A 的 boot 镜像里**不含 rootfs**
   (init 挂 ext4;ramdisk 段只带 boot/init + busybox + logdw [+ 模块,5.4 时 94 个])。所以 B2 之前要把 6.18 模块
   写进 ext4 —— 走 Android 侧 `losetup -o 77858865152`,**且必须先 `setenforce 0`**(写 loop 的 kworker 以
   `u:r:kernel:s0` 发出,SELinux 禁写 ufs_device),**dd 的 rc 不可信,要看 dmesg**。
3. **Track C(内屏)是最大自研块**:vendor `drivers/gpu/drm/sprd` 要手移植到 6.18 DRM API,没有先例可抄
   (C1 调研结论)。先通 B 再攻 C。
4. **R2**:6.18 用主线 `bq256xx` 驱动 → `charge-fix`(厂商 sqc 的 `device/registers` 直写路径)很可能要重做。

## B2 试启结果(2026-10-14 01:0x,第一次)

**一句话:内核进去了,init 跑起来了,26/26 模块全部 insmod 成功;拿不到 rootfs 也没有 USB 网口,
ramdisk 自带的 5 分钟保险丝于是重启,LK 按 tries 回落到 Android。boot_a 全程没动。**

### 怎么看到的(关键取证手法)

试启镜像**没有屏幕**(Track C 未做),USB 网口又没起来 → 本来是个"盲启"。但 `boot/init` 把每一步
都写 `/dev/kmsg` + `/dev/pmsg0`,而那两处落在 **pstore/ramoops** 里,Android 起来后直接在
`/sys/fs/pstore/{console,pmsg}-ramoops-0` 里读到了完整的一次启动。**以后盲启都靠这条通道取证。**

```
[   2.325261] CHANGXING60-LINUX: stage=modules-done loaded=26 failed=0      <- module-order 26 个全过
[  23.4 ] stage=usb-configfs / usb-netfn ncm / usb-wait-udc
[  63.5 ] stage=udc udc=none available=                               <- 没有 UDC
[  74.6 ] stage=rootfs-unavailable losetup: /dev/sda: No such file or directory   <- 没有 UFS
[  74.6 ] stage=misc-NOT-FOUND                                        <- 连带扫不到分区表
[  75.8 ] stage=android-chroot-ready / modem_control-started pid=835   <- 厂商守护居然起来了
[ 300.6 ] stage=timer-reboot -> reboot: Restarting system              <- init 的 5 分钟保险丝(设计如此)
```

即:**内核、SMP、时钟、GIC、console、devtmpfs、模块加载、厂商 modem_control 全部 OK**;
坏的只有存储与 USB 两个子系统 → 挂不上 ext4 rootfs → 没有用户态 → 保险丝重启 → 回落 Android。

### 根因(已用真机 DT 对过,不是猜)

DT 来源:boot 镜像里**没有 DT**(`build-boot-image.py` 不接收 dtb),`dtb_a`/`dtb_b` 两个分区
**全是 0** → DT 由 LK 提供,内容就是厂商 Android 那份。把它从 Android 侧拉出来解码
(`su -c cp /sys/firmware/fdt …` + `adb pull` + `dtc -I dtb -O dts`)对着主线驱动一比,
两个 compatible 不匹配:

| 子系统 | 厂商 DT 里写的 | 6.18 主线驱动要的 | 结果 |
|---|---|---|---|
| UFS | `sprd,ufshc` | `sprd,ums9620-ufs`(`drivers/ufs/host/ufs-sprd.c:409`) | 不绑 |
| UFS 配置 | — | `CONFIG_SCSI_UFSHCD` **未开**(`# not set`);6.18 树里明明有 `ufs-sprd.c`,只是没编 | 双重不成立 |
| USB UDC | 胶水 `sprd,qogirn6pro-dwc3` + 子节点 `snps,sprd-dwc3` + `sprd,qogirn6pro-ssphy` | **三个都认得**:`dwc3-of-simple.c:174` 匹配 `sprd,qogirn6pro-dwc3`;dwc3 core 匹配 `snps,sprd-dwc3`(`core.c:2825`);`phy-sprd-ums9620-ssphy.c:829` 匹配 `sprd,qogirn6pro-ssphy` | **能绑**(见下面的更正) |

> 顺带排除一个误判:上游 `mu300-mainline.config` 是给 **eMMC** 板(F50/MU300/U30 Air)的,
> 所以它 `CONFIG_MMC_SDHCI_SPRD=y` 而 UFS 全关 —— 我们 7552N 是 **UFS**,这是板型差量,
> 正是计划里 R1 预判的那条。

### 下一轮要做的(先更正上一版的两个结论)

**更正一:USB 不是"驱动缺失"。** 上一版写"父节点没驱动 → 子节点不 probe",**查错了**。逐个核对 6.18 树:
`dwc3-of-simple.c:174` 的 match 表里**正好有** `sprd,qogirn6pro-dwc3`(我们的胶水节点),
dwc3 core 认 `snps,sprd-dwc3`,`drivers/usb/phy/phy-sprd-ums9620-ssphy.c:829` 认 `sprd,qogirn6pro-ssphy`
—— 厂商 DT 的**三个 compatible 主线全都认得**,所以"父节点没驱动"这个说法确实错了,USB **不需要写任何驱动**。

**但 `udc=none` 的原因我这一版猜错了(2026-10-14 晚更正)。** 我写的是"没有 rootfs → 没有 `changxing60-usb`
去设 dwc3 角色",**不对** —— `dwc3` 压根没 probe 成功过。真实原因是**同一份 DTB 里的第三个节点**:

`dwc3@25100000` 的 `usb-phy = <0x60 0x24>`(index 0 = `dummyphy`,index 1 = `ssphy@25310000`),
主线 `dwc3_core_get_phy()` 用老的 usb_phy 框架 `devm_usb_get_phy_by_phandle()` 取,**而
`__of_usb_find_phy()`(`drivers/usb/phy/phy.c:66`)的返回是二值的**:节点 `status != okay` → `-ENODEV`
(被刻意当作"没配 phy",非致命);否则找不到已注册的 usb_phy → **`-EPROBE_DEFER`,永远 defer**。
index 1 的 `ssphy` 没问题(上游移植的驱动注册的就是真 usb_phy);index 0 的 `dummyphy`
(`compatible = "sprd,usb-dummy-phy"`)**在 6.18 全树搜不到任何 driver,节点却是 `status = "okay"`**
→ 永远 defer → dwc3 永不 probe → 没有 UDC。**改法是把 `dummyphy` 的 status 改成 `"disabled"`**(节点留着),
那次查找就返回 `-ENODEV`——正是这份 DT 在主线的正确含义(`usb2_phy = NULL`、`usb3_phy = ssphy`)。

这一条已经做进 `mainline-7552n/tools/patch-vendor-dtb.py`(见下"UFS 那节"),**与 UFS 是同一份 DTB 上的增量修改**。
教训:同一个 DTB 上的缺口要一起看,我上一版只盯着 compatible 就下了"USB 应该自己会好"的结论,太早。

> ⚠️ **代价(2026-10-16 补):这条改动把 5.4 OpenWrt 的 USB 也一起关掉了。**
> `vendor_boot_b` 那一份 DTB 不只喂 6.18 —— **slot b 上的 5.4 OpenWrt 启动读的是同一棵**
> (LK 按 slot 取 `vendor_boot_a`/`vendor_boot_b`,Android 在 a、OpenWrt 在 b)。在 5.4 那边
> `dummyphy` 恰恰是 `phy_sprd_dummy` 赖以 probe 的设备节点,关掉它 = 没有 usb_phy provider =
> `dwc3-sprd ... unable to get usb2.0 phy device` = 没有 UDC = 每次开机都"起来了但连不上"。
> 10-14 刷下去之后,10-15/10-16 的 OpenWrt 启动全部没有 USB,还被误判成 `sipa_dele.ko` 回归
> (详见 [`drivers.md`](drivers.md) §2.1)。
>
> **回 5.4 之前必须把这一位改回来(2026-10-16 已做,设备上现在就是 `okay`)**:
> `mainline-7552n/tools/vendor-dtb-status.py --node dummyphy --set okay`
> (9 字节原地写,不改 blob 大小、不用重打包)+ `tools/changxing60-dtb-fix.sh`(Android 侧走 adb 自动做)。
> `flash-7552n.sh` 里也印了这条提醒。**反方向(okay → disabled)依然只能重跑 `patch-vendor-dtb.py` 重打包。**
>
> **推论(别漏):`vendor_boot_b` 只有一份,所以这两个需求是互斥的,切一次就得改一次。**
> 当前它是 **5.4 的形状(`okay`)** —— 想再起 6.18,要先重打包把这一位改回 `disabled`,别指望直接沿用。
> 也就是说:在"6.18 与 5.4-OpenWrt 共用 slot b"这个前提下,**"5.4 有 USB"和"6.18 起得来 USB"不能
> 同时成立**,每次切换都要重写这一位。两条线怎么共存(各占一个 slot?还是切换时改 DTB?)目前**没做,也没定**。

**更正二:UFS 不是"加一行 compatible"。** 加了 compatible 也起不来 —— 驱动还要按**它自己的名字**取
reset 与 syscon,而厂商 DT 给的是另一套名字:

| 驱动要的(`ufs-sprd.c`) | 取的函数 | 厂商 DT 实际给的 | 结果 |
|---|---|---|---|
| compatible | of_match | `sprd,ufshc`(861 行) | 驱动只列 `sprd,ums9620-ufs`(409 行)→ 不绑 |
| reset `"controller"` / `"device"` | `devm_reset_control_get(dev, name)` | `reset-names = "ufs_soft_rst", "ufsdev_soft_rst"` | 名字对不上 → probe 失败 |
| syscon `sprd,ufs-anlg-syscon` / `sprd,aon-apb-syscon` | `syscon_regmap_lookup_by_phandle()` | 没有这两个属性(厂商用自己的 `aon_apb_ufs_clk_en = <phandle off mask>` 直接写寄存器) | -ENODEV → probe 失败 |
| reg `"vdd-mphy"` | `devm_regulator_get()` | `vdd-mphy-supply` | ✅ 对得上 |

所以 UFS 有两条路,都不小:

1. **驱动侧补一个"厂商 compatible"变体**:`n6_ufs` 旁边再加一个 priv(名字用 `ufs_soft_rst`/`ufsdev_soft_rst`、
   不要 syscon,改成认厂商那几个 `*_en = <phandle off mask>` 原始属性)。这是**厂商 DT 风格**的适配器,
   要重新推 ufs-sprd 的初始化序列要不要厂商那套(厂商节点里还有 `phy_sram_ext_ld_done`、
   `nvmem-cells = "ufs_cali_lane1/0"` 等校准项)。
2. **给 7552N 编一份自己的 DTB**(上游有 `mkvendorboot.py` + `sprd,sc-id` 选择机制,放进 `vendor_boot`)。
   好处是顺手把显示/音频节点也写对;风险是上游试过自编最小 DT 并在 `setup_machine_fdt` 挂住
   (LK 的 dtbo 合并与 fixup 之后),**这条要真机迭代**。

**顺带一条 5.4 的旁证**:我们 5.4 上跑得好好的 UFS,用的正是厂商那套驱动 —— 所以路线 1 等于
"把 5.4 上层已经验证过的寄存器操作,按 6.18 的 ufs-sprd 框架重讲一遍"。

### 下一步(顺次)

1. ~~读 `ufs_sprd_n6_init` / `sprd_ufs_n6_hce_enable_notify` 的寄存器动作,与厂商 DT 的 `*_en`
   属性逐个对上~~ —— **已做(2026-10-14),结论见下节:逐个都对得上,而正解是做在 DTB 侧**。
2. ~~开 `CONFIG_SCSI_UFSHCD=y` / `SCSI_UFSHCD_PLATFORM=y` / `SCSI_UFS_SPRD=y`~~ —— **已做(2026-10-14)**,
   但**位置在 `mainline-7552n/config-7552n.config`**(它本来就有,带注释说明 7552N 是 UFS 板、
   上游 `mu300-mainline.config` 是 eMMC 板的;包的 `build.sh` 把两份 `cat` 成 `merged-7552n.config`)。
   (我曾在 `upstream/mu300-mainline.config` 里也加过一遍,**已回滚** —— `upstream/` 要保持原样。)
   产物 `.config` 里三项都在,`Image` 已重出。**注意这只是前提,不是修好**:驱动仍不认厂商 compatible(上表),
   所以现在重刷还是卡在同一步 —— 要等第 1 条定了再重刷才有意义。
3. 重刷 slot b 重试(构建/刷写链条已通):看 `stage=rootfs` 与 `stage=udc` 两行是否转好。
   (`wrap-image.py` 出 `Image.lk` 是单独一步,别忘。)

## UFS:正确的做法是 DTB 侧(`mainline-7552n/`),内核一行不改(2026-10-14 定)

我把上一节那条"逐个对上"做了,结论与仓库里**早就写好**的 `mainline-7552n/README.md` **完全一致** ——
两条路独立走到同一张表,可以互相印证。**但正确做法是 DTB 那条**,我一开始改错了地方(见下)。

厂商驱动把每个 `*_en` 读成 **`<phandle reg mask>` 三元组**(它自己的 `struct syscon_ufs { regmap, reg, mask }`),
所以属性本身就带 off/mask —— 与 6.18 的硬编码值逐条对上:

| 厂商 DT 属性 | phandle | reg / mask | 6.18 驱动里的对应物 | 结果 |
|---|---|---|---|---|
| `phy_sram_init_done` | `0x12` | `0xc` / `0x1` | `ufs_sprd_n6_phy_init` 读 `SPRD_UFS_ANLG` `0xc` 位 0 | **同** |
| `phy_sram_ext_ld_done` | `0x12` | `0xc` / `0x2` | `sprd_ufs_n6_hce_enable_notify` 写 `0xc` 位 1 | **同** |
| `phy_sram_bypass` | `0x12` | `0xc` / `0x4` | 同上,写 `0xc` 位 2 | **同** |
| `ufsdev_refclk_en` | `0x02` | `0xce8` / `0x2` | `APB_UFSDEV_REG` / `APB_UFSDEV_REFCLK_EN`(`ufs-sprd.h`) | **同** |
| `usb31pllv_ref2mphy_en` | `0x02` | `0xcfc` / `0x1` | `APB_USB31PLL_CTRL` / `APB_USB31PLLV_REF2MPHY` | **同** |
| `aon_apb_ufs_clk_en` | `0x02` | `0xc14` / `0xc0` | **6.18 里没有** | 见下 |

两个 phandle 都是 syscon 节点(`0x12`=`syscon@64380000`、`0x02`=`syscon@64900000`,都是
`"sprd,ums9620-glbregs","syscon"`);复位名 `controller`≡`ufs_soft_rst`、`device`≡`ufsdev_soft_rst`;
`vdd-mphy` 本来就对得上。

### 为什么走 DTB 而不是改内核

`mainline-7552n/` 是我们**唯一**改动上游的地方(上游 `upstream/` 整目录原样留着,便于整目录 re-sync)。
`tools/patch-vendor-dtb.py` **纯增量**地改**厂商 DTB**(改的是 `vendor_boot_b` 里那一份 —— 因为 LK 的 DT 从
vendor_boot 的 DT 表来,`dtb_a`/`dtb_b` 分区全是 0;上游试过**替换**成自写的最小 DTB,**挂在
`setup_machine_fdt`**,因为 LK 自己要解析它;**加属性不是**):

| 属性 | 厂商原值 | 补成 | 为什么 |
|---|---|---|---|
| `compatible` | `"sprd,ufshc"` | `"sprd,ums9620-ufs", "sprd,ufshc"` | 主线 match 表只认前者,**厂商值留在表里 → 5.4 仍绑得上** |
| `reset-names` | `"ufs_soft_rst","ufsdev_soft_rst"` | 追加 `"controller","device"` | 主线按**名字**查;厂商名留在前面,5.4 按老名字仍命中 |
| `resets` | 2 项 | 同一对**复制**成 4 项 | 与上面名字一一对应(顺序即索引) |
| `sprd,ufs-anlg-syscon` | 无 | `<0x12>` | 见上表 |
| `sprd,aon-apb-syscon` | 无 | `<0x02>` | 见上表 |

**一份 vendor_boot 同时喂两个内核** —— 这是它比改内核强的地方。

> **我一开始走的是内核侧,已撤掉**:加一个 `sprd,ufshc` 的 priv(`vendor_ufs`)+
> `ufs_sprd_get_syscon_reg()` 里一条"从厂商属性取 phandle"的查找路,n6 的每个 op 原样复用。它编译过了
> (rc=0、`Image` 里两个 compatible 都在),**但那是第二套机制**(与 DTB 路线重复),而且补丁放进
> `upstream/` 违反了"upstream 保持原样"的约定 —— 已删,内核树已回滚。留着这段记录是因为:**若 DTB 路线
> 失败,它就是现成退路**(内核侧不碰 boot 链,风险更低)。

### 同一份 DTB 上顺手修了 USB 与 GPU

`mainline-7552n/build.sh dtb` 的实际输出(2026-10-14):

```
ufs@2000000: replaced compatible / added sprd,ufs-anlg-syscon / added sprd,aon-apb-syscon
ufs@2000000: replaced reset-names / replaced resets
dummyphy: replaced status                          <- USB,见上一节"更正一"
DCDC_GPU: replaced status
gpu@23140000: added status / added gpu-supply      <- Mali(目标①)
verify: phandles and properties ok
```

### 仍开着的风险(下次上机看 `diag` 的 dmesg)

1. **`aon_apb_ufs_clk_en`(`<0x02 0xc14 0xc0>`,UFSHC 的 PCLK|HCLK 使能)主线从不碰**。厂商驱动也只在
   `ufs_sprd_exit()` 里清它、从不置位 —— 即**由 LK 在进内核前打开**。若 LK 没开,UFS 不响应。
   (我内核版方案同样是这个结论,两边都没绕开这条。)
2. **厂商那套更长的 M-PHY 调参没有对应物**。厂商 `ufs_sprd_phy_init()`(~200 行)在 SRAM lane 校准之后
   还有一大段 `0x8116/0x8117/0x8118/0x8119/0x811c/0xd085` 的写,并用 `nvmem-cells = "ufs_cali_lane0/1"`
   的 **efuse 校准值**;主线 n6 只做 `0x40/0x41` 两个 SRAM lane 写(与厂商 `ufs_sprd_phy_sram_init_done()`
   **逐字相同**)。这是**"驱动一行都不用改"最可能不成立的地方** —— 若链路起不来,下一步就是把这段补进
   `ufs-sprd.c`,那时内核侧那条路就重新变成必须的。
3. `freq-table-hz` 厂商给 10 个 0,主线时钟解析可能嫌弃,未验。

### 现在的状态:整条链已备好,**未刷**

`bash mainline-7552n/build.sh all` → **rc=0**:
- `upstream/out/Image.lk`(内建 UFS;26 个模块)
- `work/vendor_boot_b-7552n.img`(补过的厂商 DTB,DTB 表 170200 B,phandle 校验通过)
- `work/boot-618-slotb.img`(kernel sha256 `e2b8e81e…`,ramdisk 6560479 B)

刷写 `mainline-7552n/tools/flash-7552n.sh`(只刷 slot b 的 `vendor_boot_b` + `boot_b` + misc tries;
`boot_a`/`vendor_boot_a` 不动,原厂 `vendor_boot_b` 已备份)。

**是从刷写镜像里读出来验的,不是只信 build 日志**(2026-10-14):把 DTB 从
`work/vendor_boot_b-7552n.img` 里抠出来(`\xd0\x0d\xfe\xed` 魔数扫,偏移 `0x1678040`,170136 B)自己解析:

| 节点 | 镜像里的实际值 |
|---|---|
| `ufs@2000000` | `compatible = "sprd,ums9620-ufs\0sprd,ufshc"`(厂商值留在后面)、`reset-names = "ufs_soft_rst\0ufsdev_soft_rst\0controller\0device"`、`resets` 4 项 `0d04 1104 5d0d…`、`sprd,ufs-anlg-syscon = <0x12>`、`sprd,aon-apb-syscon = <0x02>` ✅ |
| `dummyphy` | `compatible = "sprd,usb-dummy-phy"`、**`status = "disabled"`** ✅ |
| `gpu@23140000` | **`status = "okay"`**、`gpu-supply = <0x17f>`、`compatible = "sprd,mali-natt"` ✅ |
| `DCDC_GPU`(=`0x17f`) | `regulator-name = "vddgpu"`、**`status = "okay"`**、200000–1600000 µV ✅ |

即 **GPU 供电链在镜像里是通的**(`gpu@23140000` → `gpu-supply` → `DCDC_GPU/vddgpu`),三处改动都在真正要刷的那个文件里。

> **一条我写错又改回来的**:我曾据"厂商两个 SDIO 节点都是 `sprd,sdhci-r11`,而 6.18 的
> `sdhci_sprd_of_match` 本来就有这条"断定 `0100-mm-sdhci-sprd` 补丁不用写。**错**:被拒的不是
> compatible,是**节点上的 `sprd,name` 过滤**。这块板子有**三个** SDIO host,第三个
> `sdio@22220000` 是 `sprd,name = "sdio_wifi"`(扛 SC2355 WCN),既非 `non-removable` 也不是 `sdio_sd`
> → 上游那句 `if (!non-removable && name != "sdio_sd") return -ENODEV;` 把它整条拒掉 → **没有 wlan0**、
> WCN 报 "sdio dev get drv data failed"。补丁把 `sdio_wifi` 一并放行,**是需要的**。
> (我在 `upstream/patches/` 下删掉的那个 `0100` 是**放错层的 0 字节副本**;真件在
> `mainline-7552n/patches/`,仍在。)

## Track C(内屏):判决 —— 6.18 上**没有** qogirn6pro 的显示驱动,内屏要自研

**结论:主线 6.18 的 `drivers/gpu/drm/sprd/` 只支持 `sharkl3`(= UMS512 那一代、更简单的 DPU),
而 7552N 是 `qogirn6pro` 的 dpu-r6p0,两者不匹配。** 所以"从安卓那边移植显示驱动"在 6.18 上
**没有可抄的先例**,内屏只能把我们自己那套 vendor DRM 搬上去。

证据(2026-10-14 核对):

| 显示节点 | 厂商 DT(`work/dumps/live-fdt.dts`,qogirn6pro) | 6.18 主线 `drivers/gpu/drm/sprd/` | 结果 |
|---|---|---|---|
| DPU | `sprd,qogirn6pro-dpu` @`0x31000000`(1251 行) | `sprd,sharkl3-dpu`(`sprd_dpu.c:845`) | 不绑 |
| DSI host | `sprd,qogirn6pro-dsi-host` @`0x31300000`(1333 行) | `sprd,sharkl3-dsi-host`(`sprd_dsi.c:1026`) | 不绑 |
| DSI phy | `sprd,qogirn6pro-dsi-phy`(1424)/ `-dsi1-phy`(1462) | 无独立 phy 驱动 | 不绑 |
| display-subsystem | `sprd,display-subsystem`(7732 行) | 同名(`sprd_drm.c:157`) | **绑得上(但下面没孩子)** |

即:顶层 `display-subsystem` 能 probe,四个子节点一个都绑不上 → 没有 CRTC/encoder/connector → 无显示。

顺带说明厂商 DT 里显示部分有多大(不是"加一行 compatible"能了事的):除 DPU/DSI/phy 外还有 `dpuvsp`、
`compatible = "unisoc,iommuvaul6p-dispc"` 的 IOMMU、`sprd,hwdvfs-dpuvsp-qogirn6pro` 的 DVFS,
以及 `sprd,backlight` / `sprd,logo-memory` 等一堆厂商胶水。

**要把内屏弄上 6.18,工作量 = 把 vendor 那 6 个外部模块从 5.4 的 DRM API 手搬到 6.18**(计划 C2:
`kernel/build-internal-display.sh` + `drm-skip-unbuilt-display-components.patch` + `dpu_dvfs_stub.c` 是起点,
机械改写用 `upstream/tools/port54.py`)。5.4 与 6.18 之间 DRM 的 atomic/bridge 接口改动很大,
这是**独立于 Track B 的一大块自研**,不是顺手能带的。

**另一条更省的路(值得先试)**:内屏这套在 **5.4 上已经完整可用**(点屏、状态页、电源键切背光、
双缓冲页翻转治闪屏,见 [`screen-plan.md`](screen-plan.md));而用户要的最终产物是"**按键调亮度 + 亮度记忆 +
合理的电源键 + 展示页**"——这些 5.4 全都有。6.18 的价值在 `sipa`/CP 那侧(Track B),
不必为了让屏幕好看而陪着把显示再搬一遍。

## 判决(2026-10-14,对着用户那句"做不到就说出来,回 5.4 便是")

| 用户要的 | 5.4(现状) | 6.18(现状) |
|---|---|---|
| 移植驱动让 GPU 等正常 | Mali 等已在跑 | 6.18 能编出 mali 模块,但**内核还没进到用户态**(B2:UFS/USB 未通) |
| 之前的展示页 | 已实现(自绘 DRM 状态页 + LuCI 二维码) | **无显示驱动,要自研移植(上一节)** |
| 热点没问题 | 5G ch36 VHT80 已在跑 | 未到这一步 |
| 按键调亮度 + 亮度记忆 + 电源键 | 已实现(记忆在 `/etc/changxing60/backlight`) | 同上,无显示 |
| 通话 / 短信 | 短信栈已移植(未上机);通话待剥 AGDSP | 无 |

**结论:目标 ②③⑤(展示页 / 热点 / 亮度记忆 + 电源键)应当并且只能先在 5.4 上交付;
6.18 继续作为"治 SIPA 假死"的试验线,按上面 B2 的待办先把它起到能进用户态为止。**
两条线不冲突:ext4 rootfs 与内核版本无关,来回切只动 `boot_b`。

## 2026-10-15:6.18 已进用户态,CP 首次拉起,卡在数据通路

推翻上一节表格里 "UFS/USB 未通" 的旧状态 —— 6.18 **已经进用户态**(OpenWrt 25.12.5),而且 **CP 第一次 Alive**。

**CP 之所以能起来:**
`boot/init` 补回了 5.4 的 ext4 阶段 `modem_control` 块(我们仓库的 init 之前把它丢了 —— HEAD 只留了 rescue 路径那段)。
真正起作用的机制不是"ramdisk 里那个 daemon 活着",而是块里的 **`cp -a "$A/dev/__properties__" /dev/__properties__`**:
它把真实的属性文件铺进 ramdisk 的 `/dev`,而 `/dev` 最后是 **`mount --move`** 进 rootfs 的(不是 umount),
所以切根之后 rootfs 侧 S11 的 `modem_control` 也能读到属性 → CP 起来。ramdisk 那个实例随后被 kill 也无所谓
(CP 一旦起来自己跑)。也就是说:**修的是 rootfs 的属性区,不是靠 ramdisk 守候进程。**

**两个检测坑(教训,别再犯):**
1. **ping `192.168.77.1` 判"启动成功"不可靠**:该地址要先由 Windows 侧 NCM 拿到 DHCP 才有;而且新版 init 的 CP 块
   会等最多 120 s,boot 总计 ~132 s —— 查早了必然假阴性(还先测到重启前的旧系统,假阳性)。
   正解:轮询 `ssh … uname -r`,并**先等它掉线、再等它上线**两段式。
2. **init 里 grep `/run/modem_control.log` 找 "Modem Alive" 是错的**:`modem_control` 的日志走 **logcat**(经 logdw socket),
   `modem_control.log` 恒为 0 字节。要 grep 的是 `/run/logcat.txt`。因此 init 里 `ext4-modem-NOT-alive` 是**误报**。

**6.18 现状(实测):**
- 起得来:USB NCM(管理口 192.168.77.1)+ 热点 `br-wifi 192.168.8.1` + OpenClash `utun 198.18.0.1` 都在。
- `sipa_eth0` UP,**拿到运营商 IP `10.182.161.73`**,默认路由也在 —— 但 **下行 rx 恒为 0**(假活),
  dmesg 报 `sipa 25220000.sipa: sipa overflow on ep:1 evt = 0x10000` + `node transfer err = 2 retry_cnt = 10`。
  上游源码注释点题:`sipa_skb_send.c` 里那行是 **"while the delegate is not up yet"** 的限速日志;sipa-dele 上游本就**故意不加载**。
- `dmesg` 还有 `ums9620-ipa-sys-pd soc:aon:sipa-sys: sync_state() pending due to soc:ipa-apb:sipa-dele`。

**两个待修 bug(定位到了,尚未修 —— 先回 5.4 做假死实验):**
1. **`cp_diskserver` 根本没运行**(procd 实例 `running=false`,`refnotify` 也 false,只有 `modem_control` true)。
   logcat 里 `modem_control` 想用 Android 属性 `ctl.start vendor.cp_diskserver` 拉它,没有 property 服务 → `errno=2` 失败。
   我们的 `/etc/init.d/changxing60-vendor` 本来用 `sleep 12; exec android-run cp_diskserver` 起它,但没起来。
   上游 README:第 145 行明说 **"`cp_diskserver` is started first,`modem_control` about 8 s later"**。
2. ~~**`android-run` 用了 OpenWrt 上不存在的 `mountpoint`**~~ → **已修(2026-10-15,host 侧)**。
   `android-run: line 6: mountpoint: not found`,于是 `for n in seq 1 60; do mountpoint -q $A/dev && break; sleep 1; done`
   **空转 60 s** 才 exec,procd 侧一直不算 running。
   - 修法**不是**把那行换成 `grep -q " $A/dev " /proc/mounts`:仓库里**早就有**一个 `mountpoint` shim
     (`openwrt/overlay/opt/changxing60/busybox-bin/mountpoint`,读 `/proc/mounts`),它**已经在 rootfs 里**
     —— 那正是为什么 5.4 上这套能跑、6.18 上不跑。真因是**三个脚本都没把 `/opt/changxing60/busybox-bin`
     放进 PATH**,而 OpenWrt 自己的 busybox 把 `mountpoint` 这个 applet 编掉了。
   - 所以修在 `android-run` / `android-gpu-run` / `android-vendor-start` 三处各加一行
     `export PATH="$PATH:/opt/changxing60/bin:/opt/changxing60/busybox-bin"` —— 一个机制,不是两个。
     `android-vendor-start` 里那两处 `mountpoint -q … || mount …` 守卫**本来也是坏的**(永远走 `|| mount`
     那半边,每次运行都把 `/dev` `/proc` `/sys` 重挂一遍),同一行修掉。
   - **仍未上机验证**(设备不在 USB 上);宿主侧只做了 `sh -n`。
3. **`cp_diskserver` 启动顺序:故意不重构**。上游 README 说 "`cp_diskserver` is started first,`modem_control`
   about 8 s later",而我们 `changxing60-vendor` 是 `sleep 12; exec android-run cp_diskserver`,方向相反。
   但:**5.4 用同一套顺序今天是工作的**,而 6.18 上 CP 确实起来了(§上「起得来」),把启动序盲改一遍
   是在一个还跑得通的设置在赌博,且**离线不可验证**。留到设备上线、6.18 能实测 `cp_diskserver` 是否
   真的该先起时再动。记在这里,不是遗漏。

**下一步(6.18):** 上机验 `mountpoint` 那处 PATH 修复(期望:`android-run` 不再空转 60 s、三个实例
`running=true`)→ 再看 `sipa_eth0` 下行是否恢复 → 若通,再上 wedge-watch 小时级复测。
