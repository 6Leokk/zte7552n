# 7552N 待办总表(2026-10-14 存档,后续按此推进)

> **为什么有这份文件**:2026-10-14 设备离线,目标里**所有要在真机上验证的事**都推不动。
> 这里把「还剩什么、各自为什么卡、设备一回来按什么顺序做、判据是什么、命令是什么」一次写清,
> 免得下次从零回忆,也免得把已经做完的东西重做一遍。
>
> 相关:[`README.md`](README.md) 是索引;[`screen-plan.md`](screen-plan.md)(内屏/按键/全功能自查)、
> [`sms-port.md`](sms-port.md)(短信上机四步)、[`mainline-6.18.md`](mainline-6.18.md)(6.18 试验线)、
> [`proxy.md`](proxy.md)(魔法 §7 安装 / §8 运行)、[`sipa-wedge.md`](sipa-wedge.md)(假死)、
> [`access.md`](access.md)(怎么连、口令、怎么重启)、[`debug-toolbox.md`](debug-toolbox.md)(调试工具箱)。

## 0. 当前唯一的阻塞:设备不在线(2026-10-14 现场快照)

> 以下读数是 2026-10-14 设备离线那一刻的现场快照;**此后设备状态可能已变**,行动前先用
> [`access.md`](access.md) §5.1 的 USB 信号(`adb.exe devices` / Windows NCM)重新判一遍在不在。

2026-10-14 实测(全部是读数,不是推测):

| 探针 | 读数 | 含义 |
|---|---|---|
| `/mnt/c/platform-tools/adb.exe devices` | 空 | 没有 USB 设备 |
| Windows 网卡(`Get-NetAdapter`) | 只有 WLAN / Mihomo / Realtek(断开) / Hyper-V / BT(断开) / Sangfor(断开) | **没有任何 NCM/USB 网卡** |
| WSL `ip -o -4 addr` | `eth0 192.168.5.42`、`eth3 198.18.0.1/30`、docker0、lo | 没有 `192.168.77.x` |
| Wi-Fi 扫描(`netsh wlan show networks`) | 只有 `ZTE-C523YE`(宿主自己连的那个) | **没有 `changxing60`** → 设备电台没在跑 |

**结论:设备没在跑 OpenWrt。** 因此「管理后台进不去」在当时**不是 LuCI 的问题**,是够不着设备;
用户随后自己在热点侧用 `192.168.8.1` 进去了,证实如此 —— 真正的问题变成**屏上印的地址是错的**,
已改,见 §5。

## 1. 已经做完、并且 2026-10-14 在主机上现场复跑过的

| 东西 | 复验方式 | 结果 |
|---|---|---|
| 背光五档 + 记忆 + 音量键单步 | `tools/screen/test.sh` | 全过(状态机 30 项 + QR 对拍 24 项) |
| 面板页脚的管理地址 | `tools/screen/test.sh`(test-lan) | 全过(5 个场景:热点优先 / 热点关→线缆 / 热点无地址→线缆 / 无命名接口→全表 / 全不可用→保持原值) |
| SMS PDU 编解码 | `tools/sms/test-pdu.sh` | 全过(独立实现对拍 + 3GPP 定标向量) |
| SMS 池 CLI | `tools/sms/test-cli.sh` | 全过(假 AT:sync/长短信拼接/幂等/import-pdu/send) |
| LuCI 短信页 + rpcd 后端 | `tools/sms/test-rpcd.sh` | 69 项两段全过(含真 `ubusd`/`rpcd`) |
| 6.18 试启镜像 | 抠 DTB 自解析 | see §1.1 |

### 1.1 6.18 那条链备着未用(已从**刷写镜像**里读出验证,不是只信 build 日志)

`bash mainline-7552n/build.sh all` → rc=0,产物:
`upstream/out/Image.lk`、`work/vendor_boot_b-7552n.img`、`work/boot-618-slotb.img`。
把 DTB 从 `vendor_boot_b-7552n.img` 里抠出来(魔数 `\xd0\x0d\xfe\xed`,偏移 `0x1678040`,170136 B)解析:

| 节点 | 镜像里的实际值 |
|---|---|
| `ufs@2000000` | `compatible = "sprd,ums9620-ufs\0sprd,ufshc"`、`reset-names` 追加 `controller\0device`、`resets` 4 项、`sprd,ufs-anlg-syscon = <0x12>`、`sprd,aon-apb-syscon = <0x02>` ✅ |
| `dummyphy` | `status = "disabled"` ✅(否则 dwc3 永远 `-EPROBE_DEFER`,没有 UDC) |
| `gpu@23140000` | `status = "okay"`、`gpu-supply = <0x17f>`、`compatible = "sprd,mali-natt"` ✅ |
| `DCDC_GPU`(=`0x17f`) | `regulator-name="vddgpu"`、`status="okay"`、200000–1600000 µV ✅ |

**GPU 供电链在镜像里是通的。** 26 项 `module-order.txt` 逐项存在,另有 `mali_kbase.ko` /
`changxing60_thermal.ko` / `sprd_pmic_wdt.ko`。

## 2. 设备一回来就做(严格按序)

### 0. ✅ 已完成(2026-10-16):"够不着的 OpenWrt"已经修好,USB 与热点都回来了

这一段原来写的是"设备卡在 slot b 的 OpenWrt 里、没有任何入口,先按下面的顺序把它弄回 Android"。
**它已经按那个顺序做完并复验过了**,留在这里只作记录(下次真再遇到同类现象,流程照抄):

1. **物理**:开机 ~70 秒内**连关两次**(软复位/断电都行)→ misc tries 2→1→0 → 第三次落 Android。
   别只关一次等它自己回去:`changxing60-post` 会在 uptime ≈70s 时把 slot b 重新装上。
2. **宿主**:`adb.exe devices` 一行(在 Android 上 ⇒ `slot_suffix=_a`),一条命令
   `tools/changxing60-back-to-openwrt.sh`,按**唯一安全的顺序**做三件事(每步有自己的 OK 标记,缺一个就停,
   绝不带着半成品重启):① `stage-adapt.sh --stage` 换适配 payload —— **必须在重启之前**,设备上那份
   02:42 快照的默认组里还带着会 `CFI failure (target: 0x0)` 的 `misc`;② `changxing60-dtb-fix.sh` 把
   `vendor_boot_b` 里 `dummyphy` 的 9 字节改回 `okay` 并给 slot b 一次机会;③ 重启 → 验 USB。
3. **结果**:`tools/changxing60-verify-usb.sh` → **`VERIFY-USB-OK (PASS=9)`**,重启复跑仍 9/9;
   路由器 + 蜂窝 + 热点 + LuCI 全部可用。根因与判据见 [`drivers.md`](drivers.md) §2.1,
   适配 payload 这一轮的验证结果见同文 §4.1 与 §8。

**下面 A 那十条现在够得着了** —— 只是其中的"起内屏/背光"等几项此前已交付,按各自文档的状态走。

### A. 5.4 侧(用户要的交付物都在这条,先做)

1. **连上**:USB 线 → `ssh root@192.168.77.1`(口令不进仓库,真值在主机 `~/.changxing60-secrets`;
   2026-10-16 起不再是空口令;
   也可用 `~/.ssh/id_changxing60` 免密,见 [`access.md`](access.md) §2.1);或热点 `changxing60` → `ssh root@192.168.8.1`。
   **宿主侧有一条命令把下面这一堆一次做完**:`tools/deploy-pending.sh --apply --wait` ——
   短超时反复重连(不靠长监视)等到设备,按内核版本选模块集,推送并在**设备上**逐项复验(服务启用 /
   `modprobe mali_kbase` + `/dev/mali0` / `cltest` / `power-policy status` / 背光记忆)。
   不给 `--apply` 就是纯 dry run。⚠ 别用"ssh 能不能连上 192.168.77.1"当设备在不在的判据,见
   [`access.md`](access.md) §5.1(TUN 劫持那条路由)。
2. **背光上机实测**:装新 `changxing60-screen`(见 §5),按电源键五档循环、重启后档位还记得
   (`cat /etc/changxing60/backlight`)。**不用手按** —— `deploy-pending.sh` 现在会用 `keyinject`
   (uinput 合成 KEY_POWER)自动压两次键并断言 `/etc/changxing60/backlight` 变了;人按只是复核观感。
3. **短信上机(四步,别跳)** —— [`sms-port.md`](sms-port.md):第 0 步只跑只读编解码 → 第 1 步加
   `changxing60-atd` **同时**把 `mobile-data` 的 AT 改走 `changxing60-at` → 第 1b 步拨号挪 nr2 → 第 2 步才开 `changxing60-smsd`。
   **`mobile-data` 现在独占 `/dev/stty_nr1`,`changxing60-atd` 也读它 = 双读者 = 数据面挂死。**
4. **LuCI 短信页 + rpcd 后端在真机上验**(两者都从未在设备上跑过)。
5. **热点 / 魔法 / IPv6 复验**:`utun` 在 + 某域名回 `198.18.x.x` = 魔法接管;热点真机客户端连一次。
6. **掉网/假死小时级复测**:`tools/changxing60-wedge-watch.sh` 跑小时级(观测窗 543~2955s,几十分钟的干净不算数)。
7. **通话**:从 vendor 分区捞 AGDSP 机器驱动(`sprd-audio-card` / `sprd_fe_dai` 的 `.ko`)——
   控制面走 AT 已清楚,声音面缺的就是这几个预编译模块。
8. **GPU 上机(新增,2026-10-15 host 侧已就绪)** —— [`gpu.md`](gpu.md) §5:`out/modules/mali_kbase.ko`
   已编好入库(110 个模块),上机只需装模块集 + `modprobe mali_kbase` + 看 `/dev/mali0` +
   `android-gpu-run /system/bin/cltest` 报 `OpenCL 3.0 v1.r40p0-01eac0`。
   **验收点是第 3 条(cltest),不是"模块 loaded"** —— 用户要的是 GPU 能用。
9. **省电策略上机(新增)** —— [`power.md`](power.md) §11:`power-policy status` / `apply`、
   空闲熄背光(`/etc/changxing60/panel-idle`)都只在宿主侧验过。
   **`panel-idle` 保持默认关**,直到断 USB、按 §8 的采样法量出省了多少再决定开不开。
10. **`extra-modules` 失败信息可读性(新增,小)**:已改成 stderr 为空时明说 `x.ko is probably
    not installed`,上机时顺带看一眼那 11 行是不是都有原因了。

### B. 6.18 试验线

11. 刷 `mainline-7552n/tools/flash-7552n.sh`(只刷 slot b 的 `vendor_boot_b` + `boot_b` + misc tries;
   `boot_a`/`vendor_boot_a` 不动),重启后从 Android 侧读
   `/sys/fs/pstore/console-ramoops-0`,看 `stage=rootfs` 与 `stage=udc` 两行是否转好。
12. 若 UFS 链路起不来 → 把厂商 `ufs_sprd_phy_init()` 里 SRAM 校准之后那长段
   `0x8116/0x8117/0x8118/0x8119/0x811c/0xd085` M-PHY 调参(用 `nvmem-cells = "ufs_cali_lane0/1"` 的 efuse 值)
   补进 `ufs-sprd.c`;那时**内核侧适配器**那条退路重新变成必须(recipe 见 `mainline-6.18.md`)。

## 3. 主机侧还能做、但还没做的

| 项 | 说明 | 状态 |
|---|---|---|
| `charge-fix` 对 6.18 重做 | 6.18 用主线 `bq256xx` 驱动,厂商 sqc 的 `device/registers` 直写路径很可能不存在(计划里 R2) | 未开工 |
| `sc27xx-adc` / `sc27xx-fgu` on 6.18 | 上游 `patches/0005`、`0006` 已带,但 7552N 的匹配要另验 | 未验 |
| 6.18 版 `changxing60-hw` 模块清单 | `extra-modules` 已做内核版本感知(6.18 走 `mali_kbase changxing60_thermal sprd_pmic_wdt`) | ✅ 已做 |
| **5.4 Mali `mali_kbase` 重编入库** | 根因=它**从来没被构建过**(三份清单都没有),且 `stage-modules.py` 把它当可选 → 静默跳过。已取源+重编(r40p0-01eac0,vermagic 对)、改成硬根、新增 `tools/build-mali-54.sh`。详见 [`gpu.md`](gpu.md) | ✅ 产物已入库,**上机未验** |
| **省电策略(`power-policy` + 空闲熄背光)** | governor(默认 `schedutil`)+ 内屏空闲熄背光(默认关)。`tools/power/test-policy.sh` 全过(并在过程中抓到 `status()` 返回值 bug);`tools/screen/test.sh` 全过 | ✅ 宿主侧验完,**真机未验** |
| **`android-run`/`android-gpu-run`/`android-vendor-start` 的 `mountpoint` PATH** | 不是缺 shim(shim 早就随 rootfs 发了),是三个脚本没把 `/opt/changxing60/busybox-bin` 放进 PATH → 6.18 上空转 60 s | ✅ 已修,**上机未验** |
| `cp_diskserver` 启动顺序(6.18) | 上游说它该**先**起,我们是 `sleep 12` 后起,方向相反;但 5.4 用同一顺序今天是好的,离线不可判 | ⏸ **故意不动**,待上机实测 |
| **`build-rootfs.sh` 的 rc.d 启用清单改成 glob** | 原来是**手写**的五项 `changxing60-vendor/hw/post/screen/ndp` —— 新加的 `changxing60-power` **不在里面**,会"装了但从不启用"(服务没启用**不报错**,只是永不运行)。已改成遍历 `etc/init.d/changxing60-*` 并校验 `START=`,新脚本不会再被漏掉。核对了本地那 6 个都有 `START=`,展开结果 S11/S12/S95/S96/S99/S99 全对 | ✅ 已修(宿主侧已验证展开结果) |
| **`deploy-pending.sh` 装错了目录(静默空转)** | 它把 `changxing60-screen` 装到 `/opt/changxing60/bin/`,而 `build-rootfs.sh`、`tools/screen/install-runtime.sh` 和 `/etc/init.d/changxing60-screen`(`procd_set_param command /usr/bin/changxing60-screen`)**都认 `/usr/bin/`** → 服务始终跑旧二进制,而"文件已更新"的检查照样通过。已改为 `/usr/bin/`。**同一个坑的推广**:部署脚本的落点必须对着**真正读这个文件的那个东西**核,不是对着"我以前放哪" | ✅ 已修(宿主侧 `bash -n` + 两段远端 payload `sh -n` 都过) |
| **背光"记忆"的自动验证(新增 `keyinject` 部署)** | `keyinject`(uinput 合成 KEY_POWER,设备树同款键码 116)原来**没在推送清单里**,所以目标⑤只能靠手按。已加进推送+安装,并加了一段设备侧断言:先起 `keyinject` 再 `restart changxing60-screen`(程序只在启动时扫一次 `/dev/input/event*`,顺序不能反),比较前后 `/etc/changxing60/backlight` | ✅ 已加,真机未跑 |
| Track C 内屏移植 | 把 vendor 6 个外部模块从 5.4 DRM API 搬到 6.18。**6.18 只有 `sharkl3` 驱动,`qogirn6pro` 一个都不绑 → 纯自研,没有先例可抄**(判决见 `mainline-6.18.md`) | 未开工,大块 |
| OpenClash 可复现性 | 见 §4 | **缺口** |

## 4. 存档缺口:OpenClash(和它的核心)根本不在仓库里

**现状(已实测,不是"装完就算")**:`luci-app-openclash 0.48.002` + mihomo 核心已装在**设备的 ext4 rootfs** 上,
`/etc/rc.d/S99openclash` 已 enable,并且**真的在跑**(`utun` 在、`ip rule fwmark 0x162 → table 354`、
nft DNS 劫持 + QUIC REJECT、实测国内直连/国外走 SG 节点、宿主 PC 未被牵连)—— 全部证据在
[`proxy.md`](proxy.md) §7/§8。

**缺口**:这些工件**一个都不在 git 里**:

| 工件 | 现在在哪 | 会被 git 收吗 |
|---|---|---|
| `luci-app-openclash-0.48.002.apk`(10,702,048 B,sha256 `f7ebbd43…`) | `changxing60-linux/work/openclash/` | ❌ `work/` 在 `.gitignore` |
| mihomo 核心(装成 `/etc/openclash/core/clash_meta`,v1.19.31) | `changxing60-linux/clash/bin/mihomo` | ❌ `clash/` 整个未纳入(untracked) |
| 另外 34 个依赖包(`dnsmasq-full`、`ruby` 全家、`luci-compat`+Lua 运行时、`curl`、`unzip`…) | 只存在于设备 | ❌ 安装时在线 apk 拉的 |

**后果**:**跑一次 `openwrt/build-rootfs.sh` 重建 rootfs,OpenClash 就没了**,而且装回去需要网络
(设备 WAN 本来就间歇假死)。§4 里 `dnsmasq-full` 顶掉 `dnsmasq` 这件事也会一起丢。

**已做的止血(2026-10-15)**:`openwrt/build-rootfs.sh` 在打包前**检查** rootfs 里有没有 OpenClash,
没有就打一个整屏的 WARNING 横幅并指回本节。**它不会自动修好**——只是**不再静默**。
真正的修法仍是下面第 1 种(把安装做进脚本),那需要设备在线把 34 个依赖捞下来。

**三种修法(选一,建议第 1 种)**:

1. **把安装做进 `build-rootfs.sh`**:把 `.apk` 放进 `openwrt/`(和现有 rootfs tarball 同级),
   在脚本里 `apk add --allow-untrusted`(离线可用,只要把 `dnsmasq-full` 等依赖也从本地
   `/var/cache/apk` 带上),核心从 `clash/bin/mihomo` 拷进 `/etc/openclash/core/clash_meta`。
   → 好处:重建即带 OpenClash;代价:rootfs 多做 ~50 MiB。
2. **只存档工件**:把 `.apk` + 核心 + 依赖包 `apk fetch` 下来,放进一个**不 gitignore** 的目录
   (如 `firmware/openclash/`,但注意 `.gitignore` 现在忽略 `*.apk` 之外还要看 `work/` 那条),
   并写一份 `install-openclash.sh`。
3. **只写文档**:在 `proxy.md §7` 补一句「重建 rootfs 会丢,按这些命令装回去」+ 记下版本与 sha256。
   → 最省事,但下次还是要联网。

**复核命令(设备在线时)**:

```sh
ssh root@192.168.8.1 'apk info -e luci-app-openclash dnsmasq-full ruby curl unzip'
ssh root@192.168.8.1 '/etc/openclash/core/clash_meta -v'          # Mihomo Meta v1.19.31 linux arm64
ssh root@192.168.8.1 '/etc/init.d/openclash enabled && echo enabled'
ssh root@192.168.8.1 'ip -br link show utun; ip rule | grep 0x162' # 这两个在 = 魔法确实接管了
```

## 5. 管理后台地址(2026-10-14 已改,待真机验)

用户报「管理后台进不去」,真因是**屏上印的地址不对**:面板写 `192.168.77.1`,而热点侧真正能用的是
`192.168.8.1`。改法:`changxing60-screen.c` 里给页脚挑地址的那段(`read_wan()` + 新助手 `lan_take()`)
从「先问 `br-lan`」改成「**先问 `br-wifi`**」,`br-lan` 退为第二顺位,最后才是全表兜底。
顺带修掉两处会让兜底失效的写法,新增主机侧回归 `tools/screen/test-lan.c`(5 个场景)。
完整理由与验证见 [`screen-plan.md`](screen-plan.md) 的「第五轮」。

**上机要验的三件事**:

1. 屏上页脚是 `LuCI http://192.168.8.1/`(而不是 `192.168.77.1`);
2. 手机连 `changxing60` → 浏览器打开那个地址 → **能进 LuCI**;
3. 走 USB 线的一侧仍能用 `192.168.77.1`(`br-lan` 是兜底,拔掉热点时面板应回落到它 —— 这条要**拔了热点
   再看一眼屏**,验证回落路径真的生效)。

## 6. 命令速查

```sh
# 设备在线判定(与网络层无关的两条先看)
/mnt/c/platform-tools/adb.exe devices
ip -o -4 addr show | grep 192.168.77.       # 或 192.168.8.(热点侧要到宿主的 WLAN 上才看得到)

# 卡在够不着的 OpenWrt 里 → 弄回 Android(开机 ~70s 内连关两次)后,一条命令按序做完:
#   换适配 payload(必须先,否则下次开机 CFI panic) → 改 DTB 9 字节 + 装 slot b → 重启 → 验 USB
tools/changxing60-back-to-openwrt.sh              # --dry-run 只干跑;--no-reboot 只写不重启

# 5.4 上机(屏/背光):只换面板二进制就够,先 stop 再覆盖 —— 服务在跑时直接覆盖会 Text file busy
ssh root@192.168.8.1 '/etc/init.d/changxing60-screen stop'
scp -O tools/screen/out/changxing60-screen root@192.168.8.1:/usr/bin/changxing60-screen   # 必须 -O:本 rootfs 无 sftp-server,普通 scp 会失败
ssh root@192.168.8.1 'chmod 755 /usr/bin/changxing60-screen; /etc/init.d/changxing60-screen start'
# 想连显示模块一起重推,用仓库里那条已验证的路(默认地址是 IPv6 fd96:b832:c98b::1,可覆盖):
#   CHANGXING60_HOST=192.168.8.1 bash tools/screen/install-runtime.sh

# 背光档位
ssh root@192.168.8.1 'cat /etc/changxing60/backlight'

# 假死小时级监视
ssh root@192.168.8.1 'cat > /root/wedge-watch.sh && chmod 755 /root/wedge-watch.sh' < tools/changxing60-wedge-watch.sh
ssh root@192.168.8.1 'setsid /root/wedge-watch.sh >>/root/wedge-watch.log 2>&1 </dev/null &'

# 6.18 试启
bash mainline-7552n/build.sh all
bash mainline-7552n/tools/flash-7552n.sh          # 只动 slot b
# 之后从 Android 侧读 /sys/fs/pstore/console-ramoops-0,找 stage=rootfs / stage=udc
```

> **铁律(别忘)**:adb 只用 Windows 侧 `/mnt/c/platform-tools/adb.exe`;二进制传输只走 `cp` + `adb pull`,
> **禁 `adb exec-out`**(CRLF 会毁数据);到设备**普通 `scp` 不可用**(rootfs 没有 sftp-server),
用 **`scp -O`**(legacy 协议,`tools/screen/install-runtime.sh` 就是这么干的)或 `ssh 'cat > 文件'`;**`boot_a` 全程不碰**;
> `rmmod sprd-drm` / `rmmod sprd_wlan_combo` 会挂死内核;**别在真实数据呼叫期间往 `/dev/stty_nr1` 灌 AT**;
> 触摸**未获单独确认不开**;**报成功前必须实测**。
