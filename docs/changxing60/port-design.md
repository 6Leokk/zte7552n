# changxing60-linux → ZTE 7552N 移植:Phase 1–4 详细设计

> **⚠ 已归档(2026-10-10 放弃)**:本方案已正式终止推进,本文转为只读档案。
> 终止决定、放弃理由与"5.4 网络更稳"误判纠正见 [`docs/changxing60/README.md`](README.md)。
> 当前设备形态:纯 Android + APatch root + 8 模块(非此方案)。

> 前置文档:`docs/changxing60/port-checklist.md`(可行性核对)。
> 本文基于 2026-09-18 对仓库(本地 clone `changxing60-linux/`)与本机(adb+su)的逐项实测。
> **已决定跳过 Phase 0(SPD 救砖通道)**——缓解措施见 §0.2,接受残余风险后开工。

## 0. 总览

```
Phase 1 内核构建 ──► Phase 2 最小试启动 ──► Phase 3 重分区+完整安装 ──► Phase 4 功能验收
   (零风险)          (只写 boot_b+misc,      (唯一动分区表的一步,       (调 modem/WiFi/BT/
                      LK 自动回滚兜底)         需恢复出厂,风险最高)       LuCI/双系统切换)
```

- 每个 Phase 有明确的**准入条件 / 验收标准 / 回滚方案**,未过验收不进下一阶段。
- Phase 2 的成功定义比较特殊:**Linux 起来后发现 rootfs 区域不存在 → 走 init 的
  rescue 路径(telnet + 自动恢复 slot a + 300s 自动重启回 Android)= 完全成功**。
  它验证了 LK 放行、内核能跑、USB/看门狗/modem chroot 全链路,只差存储。
- Phase 3 才动分区表,是整个移植唯一不可逆点(userdata 清空)。

### 0.1 全局环境结论(已实测)

| 项 | 状态 |
|---|---|
| 宿主 | WSL2 Debian 13,systemd 可用,16 核,876G 空闲 |
| docker | **无**(Windows/WSL 两侧都没有)→ Phase 1 第一项工作 |
| python3/git | ✅ | 
| lz4 | **缺**,`apt install lz4` |
| adb | 只有 `/mnt/c/platform-tools/adb.exe`;仓库脚本裸调 `adb` → 需要 PATH shim(见 §2.1-A6) |
| 设备侧 | root(Magisk)、slot _a、boot_b/vendor_boot_b/dtbo_b 原厂有效、uevent 含 PARTNAME、`/proc/config.gz` 可取、uboot_log 分区有 LK 环形日志 |

### 0.2 无 SPD 的风险缓解(代替 Phase 0)

写坏 boot_b / GPT 的恢复路径,全部**不依赖** SPD:

1. **boot_b**:写前 dump 原厂 boot_b 到 PC(sha256 前缀 `7479f4ec…`,64MiB)。
   任何时刻从 Android root 一条 dd 恢复。LK 对启动失败的 slot b 自动回滚 slot a。
2. **GPT**:主/备 GPT 已有备份(rescue/dumps/)。只要 Android(或 recovery)还能起,
   root 下 dd 回写即恢复。
3. **boot_a / spl(sdb/sdc)/ super**:整个流程**永不触碰**(boot_a-magisk.img、
   boot_ori.img、sdb_spl.bin、sdc_spl.bin 均已备份到 PC)。
4. **recovery**:7552N 是 recovery-as-boot(无独立 recovery 分区),recovery 在 boot_a
   ramdisk 里 → boot_a 不动则 recovery 永远可用,且有屏幕可手动操作。
5. 残余风险(接受):LK 本身被写坏 / UFS 固件层出问题 → 无 SPD 即砖。
   本流程不写 LK、不写 spl,该场景仅由硬件故障或误操作触发。

### 0.3 备份矩阵(现有 + 待补)

| 内容 | 位置 | 状态 |
|---|---|---|
| boot_ori.img(原厂 boot_a) | PC `rescue/dumps/` + 设备 /data/local/tmp | ✅ sha256 `cfe593a3…` |
| boot_a-magisk.img(当前在用) | PC `rescue/dumps/` | ✅ |
| misc.bin / gpt_main / gpt_backup | PC `rescue/dumps/` | ✅(Phase 3 前重拉一次,校验字节数) |
| spl(sdb/sdc 整盘) | PC `rescue/dumps/sdb_spl.bin` `sdc_spl.bin` | ✅ |
| 7552n-stock.config(.gz) | PC `rescue/dumps/` | ✅ |
| **boot_b 原厂镜像** | — | ⬜ Phase 2 写前必做 |
| **vendor_boot_a/b** | — | ⬜ Phase 2 前(100MiB×2) |
| **/data 有价值内容**(Magisk APK、模块 zip:changxing60_v4.zip 等、LSPosed 配置、热点 XML、frida-server、脚本) | — | ⬜ Phase 3 重分区前,清单见 §3.1 |

---

## Phase 1:内核构建(宿主机,零设备风险)

### 1.1 构建环境

仓库 Docker 环境是 **arm64 原生**(ubuntu:20.04 + clang-12,对齐 Android clang 12.0.5)。
宿主是 x86_64,两种路线:

| 路线 | 做法 | 预计耗时 | 风险 |
|---|---|---|---|
| **A. 交叉编译(推荐)** | x86_64 容器 + clang-12 + `CROSS_COMPILE=aarch64-linux-gnu-`,改 build-linux.sh 一行 | 1–2h(含 ThinLTO) | 与作者脚本有偏差,需验证产物 |
| B. qemu 模拟 arm64 | `--platform linux/arm64` 原生跑作者的 Dockerfile | 6–15h | 慢但零改动 |

决定:**内核用 A,rootfs 组装必须用 arm64 模拟**(chroot 内跑 depmod/apk,无法交叉)。
16 核模拟可接受(一次性,20–60min/个)。

步骤:

```sh
# 1) docker(WSL Debian 内,systemd 已开)
sudo apt-get update && sudo apt-get install -y docker.io lz4 qemu-user-static binfmt-support
sudo systemctl enable --now docker
docker run --rm --platform linux/arm64 arm64v8/alpine uname -m   # 期望输出 aarch64
# wsl.conf 已有 protectBinfmt=true,binfmt 注册不会被 WSL 清掉;
# 若上一行失败: docker run --rm --privileged multiarch/qemu-user-static --reset --persistent

# 2) 内核构建镜像(路线 A:x86_64 版)
cd ~/code/zte7552n/changxing60-linux
docker build -t changxing60-kbuild kernel/          # 若走路线 B 直接用
# 路线 A 另建: 基于 ubuntu:20.04 amd64,装 clang-12 lld-12 llvm-12 gcc-aarch64-linux-gnu
#   binutils-aarch64-linux-gnu build-essential bc bison flex libssl-dev libelf-dev python3 lz4
#   (即 kernel/Dockerfile 加 gcc/binutils-aarch64-linux-gnu,去掉 --platform arm64)

# 3) 源码
git clone https://github.com/dikeckaan/zte-ums9620-kernel-5.4.254   # U30 Air GPL, ~200MB
docker volume create changxing60-kernel
docker run --rm -v changxing60-kernel:/src -v "$PWD/zte-ums9620-kernel-5.4.254":/tree changxing60-kbuild \
  cp -a /tree /src/zte-u30air
```

**外部驱动源码(realme C51/C53 AndroidT kernel_modules,GPL)——已定位** ✅:
GitHub `Seuj09/kernel_unisoc-5.4`(realme unisoc-5.4 树镜像,`kernel_modules/` 是普通目录非子模块;
wlan_combo 除一次无关 defconfig 提交外未被社区改动;备选镜像 `maxsteeel/kernel_unisoc-5.4`,已归档)。
已浅克隆到 `kernel-src/realme-unisoc-5.4`,下表三个目录实测齐全:

| 用途 | 路径 | 必须? |
|---|---|---|
| WiFi `sprd_wlan_combo` | `kernel_modules/kernel5.4/wcn/wlan/wlan_combo` → `/src/ext-wlan_combo` | **是**(ZTE 树里的 wlan_combo 缺 AP 修复) |
| 蓝牙 `sprdbt_tty` | `kernel_modules/kernel5.4/wcn/bluetooth/driver/tty-pcie`(`BSP_BOARD_UNISOC_WCN_SOCKET=pcie`) | 蓝牙要则必须 |
| GPU mali r40p0 | `kernel_modules/kernel5.4/gpu/natt/mali`(master 分支) → `/src/ext-mali` | 可选(OpenCL) |

> 原降级方案(ZTE 树自带 wlan_combo)已不需要;ZTE 树 `drivers/unisoc_platform/wlan/sc2355`
> 留作对照排查用。

### 1.2 config 与补丁

```sh
cp ~/code/zte7552n/rescue/dumps/7552n-stock.config kernel/device.config   # 替代 f50-stock-B09.config
cd zte-ums9620-kernel-5.4.254   # (在 docker volume /src/zte-u30air 内操作,下同)
# 勘误:仓库补丁不是 format-patch mbox 格式(无 From: 作者头),git am 会报
# "empty ident name";改用 git apply --index + 手动 commit(消息取补丁首段)。
# 勘误:of-reserved-mem-skip.patch 的第二个 diff 头被上游截坏
# ("drivers/of/fd" → 应为 drivers/of/fdt.c),已在 7552n-port 分支修复(commit 93bd919)。
for p in bluetooth-marlin3-link-policy of-reserved-mem-skip regdb-wens-certificate; do
  git apply --index ../changxing60-linux/kernel/patches/$p.patch
  git commit -m "$(awk '/^diff --git|^--- /{exit} {print}' ../changxing60-linux/kernel/patches/$p.patch)"
done
echo -gb50db5b6224c > .scmversion     # 保持 KREL=5.4.254-gb50db5b6224c
```

要点:
- **`.scmversion` 沿用作者值** → `uname -r` = `5.4.254-gb50db5b6224c`,与
  rootfs/assemble.sh、openwrt/build-rootfs.sh 里硬编码的 KREL 一致,那两个脚本零改动。
- 本机 stock config 已验证含 `BLK_DEV_LOOP=y EXT4_FS=y PSTORE_RAM=y BLK_DEV_INITRD=y`,
  fragment(systemd/nftables/命名空间等)照旧 merge。
- build-linux.sh 会强开 ThinLTO;交叉编译若 LTO 报错,去掉 `--enable THINLTO` 两行重跑
  (F50 开 LTO 只为省时间,功能无关)。
- 构建后检查 `/work/fragment-rejected.txt`(依赖不满足被拒的选项),
  重点确认 nftables/loop/ext4/configfs/usb gadget(ecm,acm)/uds 没被拒。

### 1.3 构建与产物

```sh
# 路线 A 的 build-linux.sh 改动: M="make O=$OUT ARCH=arm64 LLVM=1 LLVM_IAS=1 \
#   CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld -j14"
docker run --rm -v changxing60-kernel:/src -v "$PWD/changxing60-linux/kernel":/work changxing60-kbuild \
  bash /work/build-linux.sh
# WiFi 驱动(realme 树就位后):
docker run --rm -v changxing60-kernel:/src -v "$PWD/changxing60-linux/kernel":/work changxing60-kbuild \
  bash /work/build-wlan.sh
# 产物收集 → out/:Image、modules/*.ko(flatten + llvm-strip --strip-debug)、
#   modules.builtin、modules.builtin.modinfo
```

**模块清单核对(已实测)**:F50 的 86 个 module-order 与本机 lsmod 对比,
仅 `bq2560x_charger` 本机没有(本机用 ZTE 变体 `sqc_bq2560x`,功能等价、非启动必需;
init 对 insmod 失败只记日志不中断 → **module-order.txt 原样保留**)。
本机多出的 ~110 个模块(audio/camera/display/gnss/npu/mali/zte_*)headless 路由器均不需要,
LED/热管理等由 `changxing60-extra-modules.service` 二次加载,名单 Phase 4 再对。

### 1.4 验收标准(2026-09-18 全部达成 ✅)

- [x] `out-linux/arch/arm64/boot/Image` 存在(31,992,320 B),`file` 显示 ARM aarch64 kernel
- [x] `out/modules/*.ko` = 86 个(module-order 85 + sprd_wlan_combo),module-order.txt 每个名字都能找到
      (勘误 E8:bq2560x-charger.ko 从 module-order 移除,7552N 用 sqc_ 变体)
- [x] `modinfo ufs-sprd-qogirn6pro.ko pcie-sprd.ko sprd_wlan_combo.ko`:
      vermagic = `5.4.254-gb50db5b6224c SMP preempt mod_unload modversions aarch64`
      (勘误 E10:原预期串少了 `preempt modversions`;kernel.release 与 .scmversion 精确一致)
- [x] fragment-rejected 仅剩良性项(CGROUP_HUGETLB/KCMP/ZSWAP/Z3FOLD 缺、ZRAM=m);
      BBR 三项已修入(勘误 E9:fragment 需补 `CONFIG_TCP_CONG_ADVANCED=y`+`CONFIG_NET_SCH_FQ=y`)

---

## Phase 2:最小试启动(写 boot_b + misc;LK 回滚兜底)

### 2.1 代码适配(diff 清单)

| # | 文件 | 改动 |
|---|---|---|
| A1 | `boot/init` L103/L122/L247 | 分区扫描 glob `mmcblk*p*` → 通用:`for u in /sys/class/block/*/uevent`(UFS 分区名 sdaN 无 "p";已实测 uevent 含 `PARTNAME=`) |
| A2 | `boot/init` L124-131/L174 | **不再手工 sed**:分支已直接改好(commit f9788f1)。rootdisk 由 boot_b 的 sysfs 父设备推导(7552N→sda,F50→mmcblk0);`ROOT_OFFSET=77858865152` 用本机真值——Phase 3 前该偏移落在 f2fs userdata 内,ext4 magic 校验失败(只读探测,无损)→ 走 rescue 路径,**这是预期行为**;Phase 3 后同一 init 直接挂上 rootfs |
| A3 | `boot/build-boot-image.py` | misc 字节重推导,见 §2.2;`--stock-boot` 用 **boot_ori.img**(原厂,AVBf footer 已验证;若 LK 拒收再试 boot_a-magisk.img 的 header) |
| A4 | `boot/flash-trial.sh` | live 校验值随 A3 自动正确(比对 json 的 `misc_slot_a_hex`);`adb` → shim |
| A5 | 全部脚本的 `adb exec-out … > file` 二进制拉取 | **WSL interop 会损坏二进制 stdout(已实测:config.gz 经 exec-out 多 137 字节)** → 一律改 `cp 到 /data/local/tmp + adb pull`(pull 已验证二进制安全) |
| A6 | adb 调用方式 | ~~系统级 /usr/local/bin/adb shim~~ **实测被 PATH 遮蔽**(WSL 的 `~/Android/Sdk/platform-tools` 排在 /usr/local/bin 之前,且记忆规则禁止改系统 PATH)→ 改为**项目本地 shim** `rescue/bin/adb`(内容 `exec /mnt/c/platform-tools/adb.exe "$@"`),跑仓库脚本时 `PATH=/home/kk/code/zte7552n/rescue/bin:$PATH <script>` 前缀注入;仍是 Windows adb server,符合项目规则 |

### 2.2 misc bootloader_control 字节(本机专用,已解码)

布局(由 `changxing60-next-boot` 注释确证):`info_byte = prio(bit0-3) | tries(bit4-6) | successful(bit7)`

| 状态 | suffix | A(byte12) | B(byte14) | 含义 |
|---|---|---|---|---|
| **本机 live(=恢复块)** | `_a` | `0xff` | `0x0f` | A: prio15 tries7 succ1;B: prio15 tries0 succ0 |
| **trial 块(写入后重启进 slot b)** | `_b` | `0xfe` | `0x2f` | A 降 prio14;B: prio15 **tries2** succ0(LK 减到 1 启动;失败下次自动回滚 A) |

> 已落地:`rescue/tools/gen-misc-blocks.py`(带 live 状态断言,输出 `rescue/misc-blocks/`);
> `build-boot-image.py` 的 `bootloader_control()` 也已改为**从 --misc-head 现场推导**
> (校验 BCAB+CRC+suffix=_a;恢复块=live 原样;trial 块按上式),
> 用模拟 F50 live(0x9f/0x1e)回归可精确复现原作者的 0x9e/0x2f(分支 commit f9788f1)。
> 推导式(两实现一致):

```python
# gen-misc-blocks.py — 输入 rescue/dumps/misc.bin,输出两个 32B 块
import struct, zlib
bc = bytearray(open('misc.bin','rb').read()[0x800:0x820])
assert bc[4:8] == b'BCAB' and zlib.crc32(bytes(bc[:28])) == struct.unpack('<I', bc[28:])[0]
slot_a = bytes(bc)                                     # 恢复块 = live 原样
t = bytearray(bc)
t[0:4] = b'_b\0\0'
t[12]  = (bc[12] & 0xf0) | 0x0e                        # A: succ/tries 不动,prio→14 => 0xfe
t[14]  = 0x2f                                          # B: prio15 tries2 succ0
t[28:32] = struct.pack('<I', zlib.crc32(bytes(t[:28])))
open('misc-bc-slot-a.bin','wb').write(slot_a)
open('misc-bc-slot-b-trial.bin','wb').write(bytes(t))
```

> 注意:F50 的值(0x9f/0x1e、0x9e/0x2f)**不能照抄**——那是 F50 的 live 派生值;
> 本机一律用上面的脚本/函数从自己的 misc dump 推导。

### 2.3 构建 boot 镜像

```sh
# 1) android vendor chroot 子集(设备侧提取,已验证全部文件存在)
android-vendor/extract-subset.sh work/android-subset
python3 android-vendor/gen-ueventd-perms.py work/android-subset/vendor/etc/ueventd.rc \
  <(adb shell "su -c 'cat /vendor/etc/init/*.rc'") > android-vendor/ueventd-perms.sh
# 2) 固件(路径 /odm/firmware 已验证;拉全变体,注意用 adb pull 不用 exec-out)
#    wcnmodem.bin gnssmodem.bin wifi_board_config{,_aa}{,.xpe}.ini
#    bt_configure_{pskey,rf}{,_aa}{,.xpe}.ini fm_board_config*.ini
# 3) busybox + logdw(README §3 原命令,docker arm64 模拟)
# 4) 镜像(init 已在分支适配完毕:A1 通用扫描 + A2 rootdisk 推导 + ROOT_OFFSET 真值;
#    Phase 2 里该偏移落在 f2fs userdata → ext4 校验失败 → rescue 路径,无需再 sed)
python3 boot/build-boot-image.py --stock-boot rescue/dumps/boot_ori.img \
  --misc-head rescue/dumps/misc.bin --kernel out/Image --modules out/modules \
  --init boot/init --busybox work/busybox --logdw work/tools/logdw/logdw \
  --ueventd-perms android-vendor/ueventd-perms.sh \
  --android-subset work/android-subset --out work/boot-linux-slotb.img
```

镜像约束:总大小 < 48MiB(48MiB 起是 boot_b 内的持久日志区,脚本会自动检查);
ramdisk 必须 `lz4 -l` legacy(脚本内置)。

### 2.4 写入与重启

```sh
# 0) 先备份原厂 boot_b!(当前 sha256 前缀 7479f4ec)
adb shell "su -c 'dd if=/dev/block/by-name/boot_b of=/data/local/tmp/boot_b.img'" && \
  adb pull /data/local/tmp/boot_b.img rescue/dumps/
# 1) 写入(flash-trial.sh 全流程带哈希校验;misc 用 §2.2 的 trial 块)
boot/flash-trial.sh work/boot-linux-slotb.img
```

### 2.5 观测与判定

时间线(预期):重启 → LK 选 slot b(tries 2→1)→ 自研内核 → init 加载 85 模块 →
USB(ECM+ACM)→ rootfs 探测失败(OFF 真值落在 f2fs userdata,ext4 magic 不匹配)→
**rescue:恢复 slot a misc + telnetd/httpd
@192.168.77.1 + modem chroot** → 300s 后自动重启 → LK 见 slot a → Android 正常。

PC 侧:`ip a` 出现 192.168.77.2 → `telnet 192.168.77.1`(sh)看 `/run/stages`、dmesg。

| 检查点 | 通过标准 |
|---|---|
| LK 放行改过的 boot_b | 主机看到 USB ECM 网卡(说明自研内核起来了) |
| 模块加载 | stages 里 `modules-done loaded≥80 failed≤个位数` |
| PM 看门狗解除 | 设备**持续运行 >290s 不断电**(rescue 的 300s 定时重启前);stages 有 `pmic-wdt-rstoff-ready` |
| modem 起 | `/run/modem_control.log` 有 `Modem Alive` |
| slot 回滚 | 自动重启后回 Android,`getprop ro.boot.slot_suffix` = `_a`,misc live 块 = 原样 |
| 日志链 | Android 下 `tools/collect-logs.sh`:boot_b@48MiB 持久日志 + pstore + **uboot_log 分区(LK 环形日志,已验证可读)** |

**失败分诊**:

| 现象 | 原因假设 | 动作 |
|---|---|---|
| 重启直接回 Android,USB 无 ECM | LK 拒绝 boot_b(签名/槽位字节) | 读 uboot_log 看 LK 决策;换 boot_a-magisk.img 做 --stock-boot 重试;核对 trial 字节 |
| USB 有枚举但无 DHCP/ECM | init 早期挂(模块/UDC) | boot_b@48MiB 持久日志逐 stage 定位 |
| ~290s 断电重启 | modem_control chroot 没跑起来(看门狗未解除) | 查 /run/modem_control.log;ueventd-perms 是否漏节点 |
| 卡死无日志 | 内核/DTB 不兼容 | pstore(console-ramoops)从 Android 读;怀疑 U30 Air 树与 7552N DTB 差异时对比 dmesg 的 board 名 |

### 2.6 回滚

任何时刻 Android 下:
`dd if=boot_b_backup.img of=/dev/block/by-name/boot_b` + `dd if=misc-bc-slot-a.bin of=/dev/block/by-name/misc bs=1 seek=2048 conv=notrunc`。
(什么都不做也会回滚:tries=2 一次性试启动 + init 主动恢复,双保险。)

---

## Phase 3:重分区 + 完整安装(唯一不可逆步骤)

### 3.1 /data 备份清单(恢复出厂会清空!)——**已执行 2026-09-18,详见 rescue/data-backup/MANIFEST.md**

```sh
# 全部 adb pull 到 rescue/data-backup/(二进制一律走 pull,禁 exec-out)
/data/local/tmp/:  changxing60_v4.zip Surfing.zip frida-server 及自编脚本(np_*.sh 等)   # ✅ 整目录 841MB/64 文件
/data/adb/:        ~~Magisk~~ APatch 全目录(E24:root 实为 APatch/KPM)+ 8 模块          # ✅ 设备侧 tar → data-adb.tgz 75MB
~~Magisk~~ APatch APK、LSPosed APK(+dirtysepolicy)、SodaReward/MoonHook APK            # ✅ apks/×5(SodaReward 设备上是签名 release,与项目 unsigned 构建不同,以设备副本为准)
/data/misc/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml(热点配置)               # ✅ bk-softap.xml
相册/文档等 /sdcard 内容按需                                                             # ⚠️ 阻塞:CE 加密+图案锁,须用户解锁屏幕一次才能 pull(≈1.6GB,恢复出厂不可逆销毁)
```

> ~~Magisk 本体在 boot_a(不动)~~ **E24:root 方案实为 APatch(KPatch 内核补丁 + KPM +
> zygisksu),非 Magisk**;逻辑相同且更简单——内核补丁在 boot_a(全程不动)→ 恢复出厂后
> 重装 `me.bmax.apatch.apk`(已备份)即恢复 su;模块(LSPosed、unlock_hotspot_limit、
> netproxy 等 8 个)从 data-adb.tgz 解回或重刷 zip。

### 3.2 分区几何(精确值,参数:userdata 64GiB)

> **勘误 E7:本盘 UFS LBA = 4096 B(不是 512 B)。** 下表已按实测 GPT dump
> (gpt_main.bin/gpt_backup.bin,CRC 全通过、主备互洽)重写;字节级 OFF/SIZE 结论不变。

| 项 | LBA(4096B) | 字节 |
|---|---|---|
| 磁盘总量 | 31,240,192 | 127,959,826,432 |
| GPT 头/条目 | 主:头 LBA1,条目 LBA2–5;FirstUsable=6,LastUsable=31,239,679 | — |
| userdata(条目 #75,即 sda76)start | 2,230,784 | 9,137,291,264 |
| userdata 旧 end(含) | 31,239,679(= LastUsable,110.66GiB) | — |
| **userdata 新 end(含)** | **19,007,999**(= start + 16,777,216 − 1,64GiB) | — |
| 备份 GPT | 条目 LBA 31,240,187–31,240,190,头 LBA 31,240,191;dump 取 LBA 31,240,158 起 34 个 | — |
| **changxing60root 区起点 OFF** | 19,008,512(新 end 后留 2MiB 间隙) | **77,858,865,152** |
| **changxing60root 区终点(含)** | 31,239,167(距 LastUsable 还有 2MiB,不碰备份 GPT) | — |
| **SIZE** | 12,230,656 | **50,096,766,976(≈46.7GiB)** |

> 64GiB 是建议值(当前 /data 仅用 18G);改 `NEW_GIB` 一个参数即可,
> OFF/SIZE 由脚本重算并打印。

### 3.3 GPT 重写脚本(主备两份都改,CRC 重算)

已落地为 **`rescue/tools/gpt-shrink-userdata.py`**(commit 见外层仓库;设计稿原内联
512B 版本作废,勘误 E7)。要点:

- 全程 4096B LBA;主 dump 34 LBA(头在 file-LBA1、条目 file-LBA2),备 dump 34 LBA
  (条目 file-LBA29、头 file-LBA33);
- 断言:userdata 条目唯一、extent 精确等于 `2230784..31239679`、备份头 EntryLBA ==
  `31240192-5`;任何不符立即退出(绝不出产物);
- 重算条目数组 CRC(头 offset 88)与头 CRC(头内 CRC 字段清零再算);
- 宿主机 dry-run + 独立字节级复核已通过:仅条目 #75 变化,差异 LBA 主=[1,4]、
  尾=[31,33],其余头字段逐字节不变;产物在 `rescue/gpt-new/g.new.{main,tail}`。

写入(设备 root;dd 参数已按 4096B LBA 修正):

```sh
# 重拉干净的主/备 GPT(pull,二进制安全;各 34 LBA = 139264 B,字节数必须精确)
adb shell "su -c 'dd if=/dev/block/sda of=/data/local/tmp/g.bak.main bs=4096 count=34; \
  dd if=/dev/block/sda of=/data/local/tmp/g.bak.tail bs=4096 skip=31240158 count=34'"
adb pull /data/local/tmp/g.bak.main && adb pull /data/local/tmp/g.bak.tail
python3 rescue/tools/gpt-shrink-userdata.py g.bak.main g.bak.tail g.new.main g.new.tail
adb push g.new.main /data/local/tmp/ && adb push g.new.tail /data/local/tmp/
# 主:只需回写前 6 LBA(MBR+头+条目);备:整 34 LBA 回写原位
adb shell "su -c 'dd if=/data/local/tmp/g.new.main of=/dev/block/sda bs=4096 count=6 conv=notrunc && \
  dd if=/data/local/tmp/g.new.tail of=/dev/block/sda bs=4096 seek=31240158 conv=notrunc && sync'"
```

### 3.4 清空 userdata:走原厂 recovery(最确定路径)

```sh
# misc 写 BCB: command="boot-recovery"(offset 0)→ 重启进 recovery UI(设备有屏,手动选)
adb shell "su -c 'printf \"boot-recovery\" | dd of=/dev/block/by-name/misc bs=1 count=13 conv=notrunc; sync'"
adb reboot
# recovery 里选 恢复出厂/wipe data → 重启 → 全新 Android(userdata=64G,FBE 密钥由 recovery 重建)
```

- **为什么不靠 fstab `formattable` 自动格式化**:路径存在(init 挂载失败→格式化),
  但 metadata-encryption + checkpoint 时序不如 recovery 的 wipe 流程确定;recovery 是
  ZTE 自己天天走的路。自动格式化留作 recovery 不可达时的备胎(抹 sda76 头 16MiB 重启)。
- **逃生分析**:boot_a(含 recovery)全程未动 → recovery 永远可达;若极端情况 Android
  起不来:recovery 手动 wipe 一次;仍不行 → ~~重装 Magisk APK~~ **重装 APatch APK(E24)**拿回 root
  → dd 回写 g.bak.main/tail 恢复原 GPT(此时 /data 已清,但设备复活)。
- 恢复出厂后:~~重装 Magisk APK~~ **重装 me.bmax.apatch.apk(已备份于 rescue/data-backup/apks/)**
  → `su -c id` 确认 root → 按需重刷模块(非本流程必需,安装脚本只需要 su)。

### 3.5 改造版 install.sh 跑完整安装

适配点(在 §2.1 基础上追加):

| # | 位置 | 改动 |
|---|---|---|
| B1 | install.sh L31 | ✅ 机型白名单加 `*7552N*|*P720S20*` |
| B2 | install.sh L34-53 | ✅ 空闲区扫描整段替换:直接 `OFF=77858865152 SIZE=50096766976`(或 env 注入);existing 探测的候选偏移 27762098176 → 本机 OFF;越界校验改 512B 扇区公式(`disk-40`) |
| B3 | install.sh L85-92 | ✅ boot_a/misc 拉取改 pull 流(§2.1-A5);**--stock-boot 用 boot_ori.img**(预置 die 守卫防误用 APatch 补丁版);固件列表加拉 `_aa`/`.xpe` 变体 + 缓存跳过 |
| B4 | tools/android-install.sh L20-25/L34/L38 | ✅ `mmcblk0`→`sda`;越界校验公式同步(**LBA=4096**:备份 GPT dump 起点 LBA 31240158,LastUsable 31239679;`-34`→`-40`) |
| B5 | tools/android-mount-changxing60root.sh | ✅ 默认 OFF/SIZE 改本机值;`/dev/block/mmcblk0`→`/dev/block/sda`(两处,含 backing_file 校验双拼写容忍) |
| B6 | boot/init L174 | ✅ `ROOT_OFFSET=77858865152` 分支已是真值(commit f9788f1);install.sh 注入 sed 实测命中(L138 无 no-op) |
| B7 | rootfs/assemble.sh、openwrt/build-rootfs.sh | ✅ **零改动**(KREL 已由 .scmversion 对齐;arm64 模拟下跑;openwrt 脚本自带 `--platform linux/arm64`) |
| B8 | rootfs/overlay/opt/changxing60/bin/{android-vendor-start,early-recorder} | ✅(补漏)两处硬编码 `/sys/class/block/mmcblk0p*` 扫描改全量 `/sys/class/block/*`(PARTNAME 过滤,UFS sdaN/eMMC 通用)。**试启镜像看不到此路径,装机后才暴露** —— by-name 软链与 persist 录制会在 UFS 上失效,提前修掉 |
| B9 | rootfs/overlay/.../ueventd-perms.sh + install.sh L155 | ✅ overlay 内 F50 静态版替换为 gen-ueventd-perms.py 生成的 7552N 版(56421B,含 modem/pmsys/sctl_pm/trusty 节点);install.sh 优先取 `work/ueventd-perms.sh` |
| B10 | install.sh L116-120 + kernel/Dockerfile.cross | ✅(2026-09-18 预构建时抓到)**宿主是 x86_64,上游默认在 arm64 Mac 上跑**:不带 `--platform` 的 `docker build` 会产出 amd64 镜像(首次预构建实际发生:busybox/logdw 全部 x86-64)。修复:rootfs 镜像构建加 `--platform linux/arm64`;helper 二进制改走 `changxing60-kbuild-cross` + `aarch64-linux-gnu-gcc -static`(免模拟、秒级);Dockerfile.cross 补 `libc6-dev-arm64-cross`(Phase-1 笔记早有预言,当时没落盘);install.sh 增加 arm64 断言循环(file\|grep -qi aarch64 \|\| die) |

B1-B10 全部落在 changxing60-linux 分支 7552n-port(B1-B6+B8+B9 = ab07a86;B10 = 本次提交)。
GPU/cltest 块(L121-127,用 changxing60-kbuild + clang-12)本次跳过(无 android-gpu-subset),Phase-4 再按需处理。

**预构建状态(2026-09-18,纯宿主侧)✅ 完成**:`work/prebuild-rootfs.sh` 全流程走通
(arm64 镜像层缓存命中后仅 ~10min)——产物:
- `work/changxing60-ubuntu.tar.gz` **89,602,355 B**,sha256 `ea221c8a…`:KREL=`5.4.254-gb50db5b6224c`
  目录、95 ko、modules.builtin/modules.dep、systemd+init;**B8 通用块扫描 / B9 ueventd-perms 已烙进**;
- `work/changxing60-openwrt.tar.gz` **14,732,827 B**,sha256 `143477f1…`:95 ko 平铺
  `/lib/modules/$KREL/`(ubox kmodloader 约定,**OpenWrt 侧上游本就不跑 depmod、无 modules.dep**)、
  busybox-bin applets、openwrt_release、B8 android-vendor-start。
- 构建期两条告警均良性:depmod 缺 modules.order(仅影响 dep 内排序,dep 已生成;上游 out/ 布局同样没有);
  openwrt postinst "Failed to connect to ubus"(离线 chroot 无 procd,常态)。
正式跑 install.sh 时以 `CHANGXING60_REUSE_BUILD=1` 复用,设备在场时间缩到最短。
install.sh 为交互式(ask + 读密码 + "Type INSTALL" 确认),届时按 **§3.7 runbook** 管道喂答案。
**第二个预构建实抓**:Phase-1 flatten 把 `modules.builtin{,.modinfo}` 落在 `out/modules/` 里层,
顶层 `out/modules.builtin` 缺失,install.sh L115 的 `cp ... 2>/dev/null || true` 静默跳过 →
assemble.sh `cp /kout/modules.builtin` 硬失败(exit 1)。已从内核构建目录 `out-linux/` 补齐到
`out/` 与 `work/out/`(Image sha 03d50fec 与 trial v5-v9 内核一致,确认是同一次构建的产物)。

流程:docker 构建 Ubuntu/OpenWrt rootfs(arm64 模拟,各 20–60min)→ 设备侧
android-install.sh 建 ext4 `changxing60root`(mke2fs 走 bounded loop,脚本已防双挂载)→
解包两套 rootfs → 写 boot_b + misc trial → 重启。

### 3.6 验收标准

- [ ] Android 恢复出厂后正常,`/data` 容量 ≈64G,root 恢复
- [ ] 重启进入 Linux(默认 Ubuntu):`ssh ubuntu@192.168.77.1`
- [ ] `changxing60-os openwrt` + `reboot` → OpenWrt 起,LuCI `http://192.168.77.1`
- [ ] `changxing60-next-boot android` → 回 Android 且驻留;`changxing60-next-boot linux` → 默认 Linux,
      连续重启不掉(boot-ok rearm 机制)
- [ ] Linux 启动失败演练:删掉 rootfs 里 /sbin/init 再重启 → 自动回 Android(可选,胆大再做)

### 3.7 门日 runbook(用户在场,按序执行;每步验证通过才走下一步)

> 前置:双 rootfs 已预构建(§3.5,CHANGXING60_REUSE_BUILD=1 复用);电量 ≥60%;USB 直连;
> 宿主一律走 `rescue/bin` shim(adb.exe/docker);rescue/dumps/ 五件套齐全
> (boot_ori/boot_b/misc/gpt_main/gpt_backup)。

**门 1 —— /sdcard 备份(唯一不可逆操作之前)**
1. 用户解锁屏幕(图案)并保持亮屏;`adb shell ls /sdcard` 能列出明文文件名 = CE 已解密。
2. `adb pull /sdcard rescue/data-backup/sdcard/`(≈1.6GB);抽验大文件 + 计数,登记 MANIFEST.md。
3. 用户确认无遗漏 → 此后 /sdcard 才允许被销毁。**未过门 1 绝不执行 §3.4。**

**GPT 缩容(§3.3,可逆:原盘 gpt_main/backup.bin 在 dumps)**
4. push `rescue/gpt-new/g.new.main|g.new.tail` → `/data/local/tmp/`,设备侧 sha256sum 与宿主比对。
5. su 执行:主表 `dd if=... of=/dev/block/sda bs=4096 count=6 conv=notrunc`;
   备表 `dd ... bs=4096 seek=31240158 conv=notrunc`(34 LBA 全量);`sync`。
6. **不停留**:立即写 misc boot-recovery BCB(§3.4 机制)→ `adb reboot recovery`。
   (避免任何时刻以普通方式重启进"GPT=64G/f2fs=110G"不一致态)

**门 2 —— recovery 恢复出厂(屏幕手动)**
7. 用户在 recovery 选 wipe data / factory reset(若要求图案确认,由用户输入)。
8. 重启进 Android 首启向导(跳过账号)→ 验证:`df /data` ≈64G、设置-存储一致、无异常弹窗。
9. root/APK 恢复(**E26 三关**):`adb push <apk> /data/local/tmp/` → `settings put system
   adb_install_enabled 1`(UI 开关拨上即弹回,只能 settings put)→ `pm install -r
   /data/local/tmp/<apk>`(源必须在 /data/local/tmp,SELinux 拒 /sdcard)→ 手机点一次确认。
   实测:KPatch 在 boot_a,**APK 装回前 su 就已可用**(uid 0);装回后 `su -c id`=uid 0 ✓。
   **LSPosed 勿手动装 APK(E27)**:模块从 data-adb.tgz 解回,加载时自装 manager。
9a. 模块/热点/sdcard 恢复(全 root):push data-adb.tgz/bk-softap.xml/sdcard.tar →
   `su tar -xzf data-adb.tgz -C /data && restorecon -R /data/adb`(合并进 self-init 的
   /data/adb,同版本覆盖安全)→ `su cp bk-softap.xml /data/misc/apexdata/com.android.wifi/
   WifiConfigStoreSoftAp.xml`(chown system:system、chmod 600、restorecon)→
   `su tar -xf sdcard.tar -C /data/media/0` + restorecon(root tar 保 numeric owner;
   Android/data 内 app 私有目录是 wipe 前旧 uid,重装 app 的新 uid 不匹配属预期,
   只影响 app 私有缓存,不影响用户文件)→ 重启 → 用户开 APatch 输 superkey。
   注:**热点 XML 先于 install.sh 恢复** → 步 10 热点导入直接拿真 SSID/PSK,无需事后手改。

**安装(§3.5 改造版 install.sh)**
10. 喂答案跑交互脚本(顺序 = choice/BOOT_OS/默认Linux/热点导入/GPU/密码×2/INSTALL):
    `printf '3\nubuntu\nyes\nyes\nno\nPASS\nPASS\nINSTALL\n' | CHANGXING60_REUSE_BUILD=1 ./install.sh`
    - GPU 答 no(Mali/cltest 块未适配 x86 宿主,Phase-4 再开)
    - 热点导入 yes:若 9a 已先恢复 bk-softap.xml,导入即真 SSID/PSK;否则拿到的是
      恢复出厂默认值,装完按 `bk-softap.xml` 手改
11. 脚本自动:push tarballs → android-install.sh(bounded loop 建 ext4 changxing60root + 解包双系统)
    → 写 boot_b(哈希双验)+ misc trial → reboot。
12. 按 §3.6 验收(ssh ubuntu@192.168.77.1 / changxing60-os 切换 / LuCI / boot-ok rearm)。

**失败中止点**
- 步 4/11 哈希不符 → 停,不写盘,查传输。
- 步 8 Android 起不来 → recovery 再 wipe 一次;仍不行 → 重装 APatch APK 拿 root →
  `dd` 回写 dumps/gpt_{main,backup}.bin 恢复原 GPT(§3.4 逃生路径,此时 /data 已清但设备复活)。
- 步 11 无 CHANGXING60-INSTALL-OK → boot_b/misc 未被触碰,重启照旧进 Android;查
  work/device-install.log 修复后重跑(CHANGXING60_REUSE_BUILD=1 秒回安装步)。
- 任意步骤断电/卡死 → misc 早恢复 + LK 自动回滚兜底(Phase-2 九轮实战验证)。

---

## Phase 4:功能验收(对照 F50 状态表逐项打勾)

### 4.1 验证矩阵

| 子系统 | 操作 | 通过标准 | 7552N 特有关注点 |
|---|---|---|---|
| PM 看门狗 | Linux 常驻 >1h | 无 ~290s 断电;`pmic-wdt rstoff` 日志 | 同 F50 机制(pm_sys+modem_control chroot) |
| modem | `mobile-data status` | `Modem Alive`;AT 口 `/dev/stty_nr1` | 基带版本不同(23A_W24.25.5),AT 兼容 |
| 蜂窝数据 | `mobile-data up <APN>` | sipa_eth0 拿到 IP,ping 通,测速 | APN 按运营商(cmnet/uninet…);参考值 ~75/10 Mbps |
| 断线自愈 | 拨号后 `mobile-data watch` 在跑 | 模拟 modem 复位后 60s 内重连 | — |
| WiFi STA | `iw dev wlan0 scan` | 出结果 | 板配 ini:realme 驱动对未知项目回退 `wifi_board_config_hulk.ini`(FINDINGS #21)→ 看 dmesg 确认加载的是哪个 ini,不对则用 `wlan_combo-default-board-config.patch` 思路指到 `_aa`/`.xpe` |
| 热点 5G | hotspot-start(BAND=5) | `AP-ENABLED`,手机能连能上网 | DS Parameter Set 补丁已在仓库(必须用 realme 树+补丁的 wlan_combo) |
| 热点导入 | /etc/changxing60/hotspot.conf | SSID/PSK 与 Android 一致 | XML 路径已验证存在 ✅ |
| NAT 共享 | PC 走 usb0 / 手机走 wlan | 热点客户端出网;USB 侧只作管理口,不下发网关/DNS | br-lan(usb0)192.168.77.1 + br-wifi(wlan0)192.168.8.1 |
| 蓝牙 | `bluetoothctl scan on` | hci0 扫描出设备 | bt_configure ini 变体同 WiFi 问题 |
| LED | 拨号成功 | 蓝灯亮(leds-sc27xx-bltc,本机 Android 已加载该驱动) | extra-modules 名单核对 |
| 温度 | 压测 30min | thermal-guard 生效,降频不关机 | sprd_soc_thm + cpu_cooling |
| **充电/电池** | Linux 下充电 1h | 电量上升,不断电 | **F50 未覆盖的差异点**:本机充电 IC 是 `sqc_charger/charger_policy_service`(ZTE 变体)。充电策略在 pm_sys 协处理器固件里,预期无需内核驱动;若 Linux 下不充电 → 对照 Android 补加载 sqc_* / 保持 pm_sys 常开 |
| OpenWrt APN | LuCI 网络接口 wan | `proto changxing60cell` + option apn | — |
| sysupgrade 防护 | `owut` 不存在 | 官方整盘升级路径已移除 | build-rootfs.sh 已处理 ✅ |
| 双系统持久化 | 日常用一周 | Android↔Linux 切换稳定 | — |

### 4.2 调试工具链

- `tools/collect-logs.sh`(Android 侧收集 boot_b 持久日志/pstore/uboot_log)
- `tools/changxing60-serial.py` / `changxing60-sh.py`(USB ACM 串口控制台,ttyGS0)
- LK 层:`dd if=/dev/block/by-name/uboot_log`(已验证有内容)
- Linux 层:journalctl / `/run/stages` / dmesg

### 4.3 日常使用形态(目标态)

- 默认启动 Android(现状不变),需要时 `changxing60-next-boot linux` 切换 —— 或反过来,
  默认 Linux、Android 兜底(F50 作者日常形态)。
- OpenWrt 作为主路由固件,Ubuntu 作为调试/扩展环境,`changxing60-os` 互切,共享同一 ext4 盘。
- 汽水奖励/MoonHook 等 Android 侧玩法不受影响(Android 完整保留)。

---

## 5. 风险登记册

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | **无 SPD 救砖** | 低(本流程不碰 LK/spl/boot_a) | 致命 | §0.2 四层恢复路径;永不写 spl/super/boot_a |
| R2 | LK(7552N MyOS 版)槽位语义与 F50 不同 | 中 | 试启动失败 | Phase 2 专测;uboot_log 取证;字节可迭代(A=0xfe 不行试 0x9e) |
| R3 | 校验绕过不覆盖 boot_b | 低(Magisk 改 boot_a 能 green 运行,绕过应在 LK/vbmeta 层) | Phase 2 失败 | 换 boot_a-magisk.img 做 --stock-boot 再试 |
| R4 | U30 Air 内核树与 7552N DTB 不匹配(调压器/时钟差异) | 中 | 内核挂/驱动 probe 失败 | pstore+持久日志定位;必要时找 7552N 自己的 GPL 源码(ZTE 有发布义务) |
| R5 | recovery 对改小 GPT 的 userdata 格式化失败 | 低 | bootloop | recovery 重试;Magisk 重装拿 root 回滚 GPT |
| R6 | WSL interop 损坏二进制流 | **已发生** | 静默数据损坏 | 铁律:二进制一律 `adb pull`;所有拉取后校验字节数/sha256 |
| R7 | qemu 模拟构建极慢/异常 | 中 | 工期 | 内核走交叉编译;rootfs 一次性忍受 |
| R8 | WiFi 板配 ini 变体选错(_aa/.xpe/hulk) | 中 | WiFi 弱/无 5G | 全变体带上,dmesg 确认,必要时补丁指定 |
| R9 | Linux 下充电异常(sqc_* 充电栈差异) | 中 | 续航/安全 | Phase 4 专项;不行则 Android 侧充满再用/长期插电场景影响小 |
| R10 | 恢复出厂丢模块生态(LSPosed 等) | 确定发生 | 麻烦 | §3.1 备份矩阵;重装流程用户已熟悉 |

## 6. 工作清单(执行时逐项勾)

**Phase 1**(完成 ✅ 2026-09-18)
- [x] apt: docker.io lz4 qemu-user-static;docker arm64 自检(`aarch64` ✅;systemd-binfmt 服务报错无害,WSL 已自行注册 qemu-aarch64)
- [x] adb shim → **勘误落地为 `rescue/bin/adb`**(系统级被 PATH 遮蔽,见 A6)
- [x] clone U30 Air 内核树(HEAD=b50db5b6224c,与 KREL 精确一致);realme 树已定位并克隆(Seuj09/kernel_unisoc-5.4)
- [x] device.config = 7552n-stock.config(sha256 a1f89b94 已验证);3 个补丁已打(git apply 方式,见 §1.2 勘误);.scmversion 已设
- [x] 交叉编译 Image+193 ko(538s,ThinLTO 无 OOM)+ sprd_wlan_combo.ko(4 补丁 0 rej);
      验收 §1.4 全过;产物 flatten+strip 到 `out/modules`(86 ko,7.5M)+ `out/Image`(31M)

**Phase 2**
- [x] gen-misc-blocks.py 生成本机 slot 块(`rescue/misc-blocks/`,hex 见 §2.2);
      build-boot-image.py 改为 live 推导 + F50 回归单测通过;flash-trial.sh xxd→od(commit f9788f1)
- [x] init 适配(通用 uevent 扫描 + rootdisk 推导 + ROOT_OFFSET 真值;bash -n 过,commit f9788f1)
- [x] dump boot_b/vendor_boot_a/b/init_boot_b 到 PC(哈希与设备侧逐一比对一致;
      boot_b=7479f4ec… 与既有记录吻合;vendor_boot_a==b;init_boot_b 全零→E14)
- [x] extract-subset.sh(改 device-tar+pull,commit 2c5308a)→ work/android-subset(52M);
      gen-ueventd-perms.py → work/ueventd-perms.sh(646 行,modem/pmsys/sctl_pm/trusty 9 处命中)
- [x] 固件全变体 16 个 cp+pull → rescue/firmware/fw/(wcnmodem/gnssmodem sha 与设备侧一致)
- [x] busybox-static-arm64(1.36.1,arm64 容器)+ logdw(交叉编译,static arm64;
      镜像需补 libc6-dev-arm64-cross)
- [x] 构建 boot 镜像 v1(85 模块,37.9M<48M,footer/AVB/cmdline 复核全过)→ **trial-1 实测:
      LK 放行、内核起、80/85 模块、看门狗解除、300s 回滚全过;唯 USB 因 zlog 级联失败(E13)**
- [x] module-order +zlog×2(E13,commit 5ddcabd)→ 镜像 v2(87 模块,sha e1a82264…)
- [x] trial-2~9 八轮迭代排障(勘误 E14~E23 + §7 各轮记录):zlog 级联→fw_devlink/vddvbus→
      dummy-phy(E19)→gadget 函数缺失(E20)→MS OS 描述符(E21)→Windows 28000 RNDIS 已死/NCM
      转向(E22)→httpd 守护化空转(E23)
- [x] **trial-9(2026-09-18 06:15)Phase-2 验收 PASS——全自动闭环**:NCM 网卡自动绑定
      (usbncm)→ httpd/telnetd/udhcpd 自动监听 192.168.77.1 → 宿主 curl.exe 拿 index+503KB
      dmesg(uptime ~34s)→ 300s 自动重启回 Android(第 9 次干净回滚);三层安全网全部实战验证;
      日志归档 work/logs-trial7/8/9(镜像谱系 v5→v9,见 §7 Trial-9 节)

**Phase 3**
- [x] /data 备份(DE 侧)全部 pull → rescue/data-backup/ + MANIFEST.md(E24:root=APatch)
- [x] **门 1 已过(2026-09-18 22:05)**:用户解锁 → root 设备侧 tar /data/media/0(1.73GB,
      sha `1b76047e…` 两端一致;adb pull 直拉会因个别 app 私有文件 denied 整体中止在 39%)→
      tar -tf 完整 + 解包 7576 文件 + 抽查内容哈希匹配 → **/sdcard 可安全销毁**;
      登记 MANIFEST.md"CE 侧备份完成"节
- [x] 重拉 GPT 主/备(与 dumps 字节一致,零漂移)→ gpt-shrink-userdata.py 产物逐字节复现
- [x] **GPT 缩容回写 + recovery 引导完成(2026-09-18 22:37)**:预检盘面零漂移(主 85c9b8a3/
      备 d7d12c8b 与 dumps 一致)→ push 哈希互证(167ed422/90686369)→ 主表前 6 LBA + 备表
      34 LBA dd 回写 + sync → 读回 sha256 全等(主前 6 LBA a9bf3704)→ misc offset 0 写 13B
      "boot-recovery"(BCB 读回验证;0x800 bootloader_control 未触碰)→ `adb reboot recovery`。
      盘面已是 64G 布局(仍可逆:原盘在 dumps,dd 回即恢复)
- [x] **门 2 完成(2026-09-18 22:38 首启)**:用户 recovery 手动 wipe data/factory reset →
      向导走完 → 重开 USB 调试并授权;实测 `df /data` **= 64G**(dm-38 f2fs 2.6G used)✓、
      /sdcard 全新骨架、/data/local/tmp 清空(设备侧 sdcard.tar/g.new.* 随 wipe 消失,宿主有验证副本)
- [x] **root 恢复(2026-09-19 00:0x)**:me.bmax.apatch.apk 按 E26 三关序列装回
      (settings put adb_install_enabled 1 → /data/local/tmp → pm install -r → 手机点确认;
      versionName 9a63e0f)→ **manager 装回前 `su -c id` 就已是 uid 0**(KPatch 在 boot_a,
      wipe 杀不掉;context u:r:shell:s0)。SodaReward 同法装回
- [ ] 模块/热点/sdcard 恢复(E27 序列):data-adb.tgz 解回 /data/adb + restorecon →
      bk-softap.xml 回 WifiConfigStoreSoftAp.xml(chown system:system/600/restorecon)→
      sdcard.tar 解回 /data/media/0 → 重启验证模块加载/LSPosed manager 自装
- [ ] APatch UI 绑定:用户开 app 输 superkey(内核 superkey 未变,wipe 不影响)
- [x] install.sh 适配 **B1-B10**(changxing60-linux@7552n-port:ab07a86 + B10 提交 d8fc164)
- [x] 双 rootfs 预构建完成(work/prebuild-rootfs.sh,纯宿主侧零设备风险):
      `work/changxing60-ubuntu.tar.gz` 89.6MB sha `ea221c8a`(KREL 目录/95ko/modules.dep/systemd/
      B8+B9 已烙进)、`work/changxing60-openwrt.tar.gz` 14.7MB sha `143477f1`(95ko 平铺供 kmodloader/
      busybox-bin/openwrt_release/B8 已烙进)。正式安装用 `CHANGXING60_REUSE_BUILD=1` 复用
- [x] **boot 镜像干跑验证**(build-boot-image.py,零设备写):`work/boot-linux-slotb.img` 64MB
      sha `f29977e3`,kernel 03d50fec、94 模块;misc trial 块 `fe002f00`(slot-b 有限次自动回滚)、
      recovery 块 `ff000f00…96b18d84`(=本机 live slot-a,CRC 与 trial-9 回滚一致)。
      init 带真值 ROOT_OFFSET → 重分区后直接挂 ext4 changxing60root(不再落 rescue)。
      证明 B10(arm64 busybox/logdw)+B9(ueventd-perms 56421B)全链路可打包
- [ ] 安装(过门 1+门 2 后按 §3.7 runbook)→ §3.6 验收

**Phase 4**
- [ ] §4.1 矩阵逐项;WiFi ini/BT ini 变体确认;充电专项
- [ ] OpenWrt LuCI + APN + 双系统切换日常化
- [ ] 一周稳定性 soak

---

## 7. 执行日志与勘误(边做边记)

### 2026-09-18 Phase 1 开工

| # | 发现/纠错 | 处置 |
|---|---|---|
| E1 | 上游 `kernel/patches/of-reserved-mem-skip.patch` diff 头被截坏:`drivers/of/fd`(应为 `fdt.c`) | 7552n-port 分支修复(commit 93bd919),hunks 未动 |
| E2 | 仓库补丁均**非** format-patch mbox 格式(无 From: 作者头)→ `git am` 报 "empty ident name" | 改用 `git apply --index` + 手动 commit;内核树 3 补丁 commit:d77340fed / 3b7c933f2 / e6007e5d1 |
| E3 | 系统级 adb shim(/usr/local/bin/adb)被 WSL PATH 里的 `~/Android/Sdk/platform-tools/adb` 遮蔽,而记忆规则禁改系统 PATH | 项目本地 `rescue/bin/adb`,调用时 PATH 前缀注入;`adb version` 不拉起 server,无 5037 冲突发生 |
| E4 | `rescue/dumps/7552n-stock-config.gz`(38851B)确认为 exec-out 损坏产物(gunzip format violated) | 改名 `*.CORRUPT-exec-out` 隔离;构建只用 `config-7552n.gz`(38714B)与其解压产物 `7552n-stock.config`(sha256 a1f89b94 一致) |
| E5 | systemd-binfmt.service 启动失败("Read-only file system") | 无害:WSL 已预注册 qemu-aarch64(protectBinfmt);docker arm64 实测输出 aarch64 |
| E6 | git am 失败残留 `.git/rebase-apply` 导致后续 am 全部被拒 | `rm -rf .git/rebase-apply` + `git reset --hard` 后重来(内核树是浅克隆,无本地未推送内容,reset 安全) |
| E7 | **设计稿 §3.2/3.3 假设 512B 扇区——实测本盘 UFS LBA=4096**(GPT 头在 LBA1=4096 偏移;备份头 LBA 31240191)。原内联脚本/dd 参数全部错位 | §3.2 表、§3.3 脚本与 dd 已按 4096 重写;正式工具 `rescue/tools/gpt-shrink-userdata.py`(带唯一性/extent/EntryLBA 断言),dry-run+独立字节级复核通过;字节级 OFF/SIZE 结论不变 |
| E8 | module-order.txt 含 `bq2560x-charger.ko`,但 7552N 充电是 sqc_bq2560x 变体,该 ko 不存在;build-boot-image.py 对缺失 ko **硬失败**(init 本身容忍 insmod 失败) | 从 module-order 移除(85 模块,commit 86041e8);Phase 4 充电专项再核 sqc_* 加载 |
| E9 | fragment 的 `CONFIG_TCP_CONG_BBR=y` 被 olddefconfig 静默丢弃(stock config `# CONFIG_TCP_CONG_ADVANCED is not set` 隐藏了符号) | fragment 补 `CONFIG_TCP_CONG_ADVANCED=y`+`CONFIG_NET_SCH_FQ=y`,重编后三项全 =y(commit 86041e8) |
| E10 | §1.4 预期 vermagic 串不完整:实际为 `5.4.254-gb50db5b6224c SMP preempt mod_unload modversions aarch64`(多 `preempt modversions`) | 以实测串为准更新 §1.4;抽查 ufs/pcie/wlan_combo 三 ko 全部精确一致 |
| E11 | flash-trial.sh 用 `xxd -p` 读 misc 十六进制,Debian 无 xxd | 改 `od -An -tx1 -v | tr -d ' \n'`(文本经 adb shell 输出,interop 安全,commit f9788f1) |
| E12 | `sda_gpt_main/backup.bin`(17409B,签名在 4097 偏移)确认为 exec-out 字节移位损坏 | 改名 `*.CORRUPT-exec-out` 隔离;GPT 一律用 pull 重拉的 `gpt_main.bin`/`gpt_backup.bin`(139264B=34×4096,主备 CRC 互洽) |
| E13 | **Trial-1 实测:5 模块 insmod 级联失败**(loaded=80/85)。根因:7552N stock 的 `zlog_common_dlkm` 是独立模块,`sc27xx_typec` 依赖其 `zlog_{register_client,client_record,client_notify}`,而 F50 module-order 没有 zlog → typec→dwc3-sprd→musb_sprd 级联挂掉 → **无 UDC、USB 全灭**;charger 三件套缺 `zte_power_supply_*`/`sqc_*`/`zlog_*`/`cm_notify_event` | zlog_exception_dlkm.ko + zlog_common_dlkm.ko 插到 sc27xx_typec.ko 之前(commit 5ddcabd,87 模块);**USB 链路修复只需 zlog**(dwc3_sprd_core/musb_hdrc/phy 全家 trial-1 已加载成功)。charger 链推迟 Phase 4:zte_power_supply/zte_misc/charger_policy_service/sqc_v8 三件套均已构建为 ko,但 sc27xx_fuel_gauge 还需 `cm_notify_event`(charger-manager-sqc 变体未构建,需 config+重编) |
| E14 | init_boot_a/b 分区**全零占位**(8MiB 无任何内容,sha 一致);stock boot.img 自带 1.4MB ramdisk(hdr v4) | 与 F50 同构,LK 不走 init_boot;作者"kernel+ramdisk 全放 boot_b"方案直接适用,无需适配 |
| E15 | Trial-1 其余机制**全部验证通过**:LK 放行自写 boot_b;rootdisk=sda/boot_b=sda40 推导正确;misc 62s 即恢复 slot a;android chroot 四节点齐(/dev/modem,pmsys,sctl_pm,trusty-ipc-dev0);**modem_control 起且 `pmic-wdt-rstoff-ready t=4`(看门狗解除,F50 最难关卡一次过)**;存活 291s 到定时重启,回 Android 后 slot=_a | Phase 2 判定表除 USB 外全绿;USB 修复后复测(trial-2) |
| E16 | **Trial-2 根因:`probe of X returned 1` 是成功不是失败**(本内核 really_probe 尾部 `driver_bound(dev); ret = 1;` + "ret > 0 means positive match");真正的失败是 KERN_WARNING `probe of %s failed with error %d`。`25100000.usb3 returned -517 after 2 usecs` 这种**微秒级静默 defer** 来自 fw_devlink 的 `device_links_check_suppliers()`(dd.c:524,在 drv->probe 之前),supplier 链不满足即返回,不打任何驱动日志。**Trial-3 补充勘误:`returned 0` 也是失败**——dd.c probe_failed 分支对 -ENODEV/-ENXIO 仅 pr_debug、其他错误 KERN_WARNING,然后 `ret = 0`("Ignore errors returned by ->probe")。三态判读:**1=成功,0=probe 失败(defer 被吞),-517=supplier 门(未进 probe)** | 误判 sipa-sys/phy 失败浪费一轮排查;以 `returned 1`=OK 重新对账,trial-2 里 clocks/pd_ipa_sys/extcon/hsphy/ssphy 全部已 OK |
| E17 | **Trial-2 USB 全灭真凶**:`usb3` 的 `vbus-supply = <&vddvbus>`,`vddvbus` 是 i2c 客户端 `bq2560x_chg@6b`(compatible `ti,bq2560x_chg`)的子节点,驱动 = **sqc_bq2560x.ko**,而 module-order 里没有它(E8 只删了错误的 bq2560x-charger.ko,没补 sqc 变体)→ regulator 从未注册 → usb3 supplier link 永远不 AVAILABLE → dwc3 glue 静默 -517 → musb_sprd 被 `dwc3_sprd_probe_finish()` 门住 → 无 UDC。中兴 5.4 内核 fw_devlink 的 `of_supplier_bindings[]` 含 `-supply` 后缀匹配(regulators) | 补全充电链 6 ko(见 trial-3);备用手段:cmdline 加 `of_devlink=0`(property.c core_param)整体关闭 supplier link;dwc3_sprd_probe 对 vbus 缺失本就容忍(dev_warn+NULL,仅影响 host 模式) |
| E18 | 依赖分析陷阱:`grep -F` 子串匹配制造假依赖(`device_unregister`⊂`npu_cooling_device_unregister`、`regmap_read`⊂`wcn_regmap_read`),nm -u 也含被丢弃 section 的幻影引用 | 真依赖 = readelf -r 重定位引用 ∩ nm -u,再对 Module.symvers **精确字段**匹配;结论:zte_power_supply 零模块依赖、fuel_gauge 不需 wcn_bsp(12MB+NFS/PCIe 全家,弃)、sqc_charger 不需 rpmb(line 14 已有) |
| E19 | **Trial-3 USB 真凶(与 E17 不同层)**:live 7552N DT 的 `usb3` 节点 `usb-phy = <0x60 0x24>`——0x60 = `/soc/ipa-apb/dummyphy`(compatible `sprd,usb-dummy-phy`),0x24 = ssphy@25310000;GPL 参考 dtsi 是 `<&ssphy>,<&ssphy>`。dwc3-sprd glue 的 `devm_usb_get_phy_by_phole(dev,"usb-phy",0)` **失败是致命的**(`goto err_ipa_clk`,仅 vbus 容忍),而 `__of_usb_find_phy` 对不在 usb phy_list 的节点返回 -EPROBE_DEFER → glue 永久 defer(`returned 0`,见 E16 补充)→ `dwc3_probe_finish` 不置位 → musb_sprd 35µs 静默 defer → 无 UDC。**GPL zte 树没有 dummy-phy 驱动**(ZTE 未开源该文件),但 realme-unisoc-5.4 树有 `drivers/usb/phy/phy-sprd-dummy.c`,stock vendor 也有 phy-sprd-dummy.ko + `sprd-dummy-phy` 驱动目录 | 用 realme 树源码按外部模块法(build-dummyphy.sh,同 build-wlan.sh)编出 phy-sprd-dummy.ko(vermagic 精确、零模块依赖),插 module-order #84(dwc3-sprd #87 之前)→ 94 模块。**Trial-4 实证**:glue 打出 `sprd dwc3 probe finish!`、`probe of 25100000.usb3 returned 1 after 81229 usecs`,UDC `25100000.dwc3` 注册成功 |
| E20 | **Trial-4 新根因(gadget 层)**:7552N stock config **无任何网络 gadget 函数**(`CONFIG_USB_CONFIGFS_{ECM,RNDIS,NCM}` 全 not set;Android 用 F_FS+UEVENT),而 F50 stock config 带 ECM——作者 init 原样可用的前提在我们这不成立。init `mkdir functions/ecm.usb0` ENOENT(未检查返回值)→ f1 链接失败 → 绑成**只含 ACM 的空 gadget**:Windows 完整枚举并 SET_CONFIGURATION(`configfs-gadget: high-speed config #1: c`、`USB_STATE=CONFIGURED`)但设备侧 usb0 永不存在 → 无救援网络。**且救援宿主是 Windows**(build 28000:有 rndismp6/usb8023*,无 usbncm.sys,从无 ECM 原生驱动)——即便编上 ECM 也不通 | fragment 补 `USB_CONFIGFS_{RNDIS,NCM,ECM}=y`+`USB_F_{RNDIS,NCM,ECM}=y`+`USB_U_ETHER=y`(三函数全启,树内 f_{ecm,ncm,rndis}.c 均在);init 改为按可用性择一:rndis→ncm→ecm(全部只建一个 usb%d=usb0),并加 usb0 出现等待+`stage=usb-netfn`/`stage=usb0-netdevs` 日志。教训:**configfs 函数 mkdir 必须校验返回值**,否则静默绑空 gadget |
| E21 | **Trial-5 宿主侧最后一环**:设备侧全绿(`stage=usb-netfn rndis`、usb0 存在、bind rc=0、宿主 SET_CONFIGURATION)但 Windows 不建网卡——**Windows 只对 MS OS 1.0 扩展兼容 ID `RNDIS` 绑定 rndismp**(f_rndis 接口类是 comm/ACM/vendor-proto 0xff,类匹配永不触发),而 configfs 默认 `os_desc/use=0` 且 `qw_sign` 为空(kzalloc,无默认值)。更隐蔽:**Windows 按 VID/PID/序列号缓存 OS 描述符探测结果**——trial-4/5 的 `0525:a4a1/CHANGXING60LINUX` 已被记成"无 OS 描述符",trial-5 日志里宿主**根本没再发 0x3EE 字符串请求** | init 在 UDC bind 前设置:`functions/<fn>.usb0/os_desc/interface.<fn>/compatible_id`=RNDIS(store 剥尾部换行,已核源码 configfs.c:1175)、`os_desc/qw_sign`=MSFT100、`b_vendor_code`=0x1、`use`=1(四者在 UDC store 时拷入 cdev,顺序不可后,configfs.c:1385);**idProduct 改 0xa4a2** 打新设备实例、破 Windows 缓存。~~仅 rndis 有 os_desc/interface.* 目录~~(**此判断错,f_ncm 也注册 → 见 E22**,守卫必须锁 netfn=rndis) |
| E22 | **Trial-6 宿主侧败因:legacy RNDIS 在 Windows build 28000 已死**。设备侧描述符链全绿(`stage=usb-osdesc on`、0x3EE 应答、compat-ID C0/0x01/wIndex=4、ext-props C1/0x01/wIndex=5、"Get System is Windows"、CONNECTED→CONFIGURED @26.1s),Windows 也建了 `USB\VID_0525&PID_A4A2&MI_00` 节点,但**没绑任何驱动**:`DEVPKEY_Device_Service` 空、Class 空、ProblemCode 空、ConfigFlags=64。DriverStore 实测:**无 rndismp6.inf**(24H2 后 legacy RNDIS 移除),仅 `rndiscmp.inf_amd64_5a1e0df7b49dac27`(弃用后兼容驱动,本轮未匹配上);而 **`usbncm.inf`+`usbncmum.inf` 在库** → NCM 可类匹配绑定。**教训:查 Windows 驱动看 DriverStore FileRepository,不是 System32\drivers**(早前"无 usbncm.sys→NCM 不可行"的误判即源于此);ACM 兜底已证明(MI_02→usbser→COM15,宿主发 SET_LINE_CODING) | Trial-7 **NCM 转向**:init netfn 优先级 `rndis ncm ecm`→`ncm rndis ecm`;**连带修 E21 隐患**——f_ncm 也注册 os_desc/interface.ncm(f_ncm.c:1436,1653 `usb_os_desc_prepare_interf_dir`),`-d` 守卫会对 ncm 误触发、把 RNDIS compat-ID 写进 NCM 函数(可能引开 Windows 的 usbncm 类匹配),守卫改为 `[ "$netfn" = rndis ]`;**PID a4a2→a4a3**(a4a2 的 MI_00 是"有节点无驱动"脏状态,打全新设备实例);rescue 路径加 **ttyGS0 串口控制台** respawn 循环(驱动无关的救援访问) |
| E23 | **Trial-7/8 真凶既非 NCM 也非 Windows:开机守护化的 busybox httpd 变成无 socket 的 100%-CPU 空转进程**。trial-7 http 4 分钟不可达(当时误判 DHCP/数据路径);trial-8 三通道 live 验尸:usb0 UP RUNNING、IP 正确、ARP 双向、PING 通、udhcpd/telnetd 正常且 **telnet 全程可达**(observer v3 只测 http,漏报 95s),唯 httpd(pid 1639)无监听 socket:/proc/fd 只有 0,1,2→/dev/null,State R,utime+stime≈570s≈进程全寿命=出生即空转(poll POLLNVAL 忙循环特征)。**同一 cmdline 手动从 shell 跑即刻 bind :80**,随后 WSL curl/telnet、Windows curl.exe 全通——救援网络 trial-8 时实际已打通,唯一故障点是 httpd 自启。疑似 bb_daemonize 在 PID1/无孤儿控制台环境下的竞态,机制未深挖(watchdog 已覆盖) | init v9(commit a93b3fc):httpd 改 **`-f` 前台 + respawn 循环**(完全绕开 bb_daemonize)+ **5s 监听 watchdog**(查 /proc/net/tcp state 0A 的 `:0050`/`:0017`;http 缺→`killall httpd` 让循环重拉,telnet 缺→重拉 telnetd)。trial-9 实证:**watchdog 0 次出手,-f 循环首试即 bind**。连带教训:①观察者必须 telnet+http 同探(observer v4);②Windows DHCP lease 跨重启缓存复用(trial-8 直接用 trial-7 拿到的 .4;Dhcp-Client/Admin 事件通道默认禁用,"无事件≠没 DHCP");③stats awk 必须锚定 `$1=="usb0:"`(否则匹配 sipa_usb0 全零行);④WSL→救援网可达性不可靠(trial-9 设备 ARP 表里有 WSL IP 192.168.43.72=SYN 到达,但 Windows 不把回包转发回 WSL)——**权威宿主验证通道 = Windows curl.exe** |
| E24 | **root 方案实为 APatch(KPatch/KPM + zygisksu),不是 Magisk**:pm list packages -3 无任何 Magisk 包(实装 me.bmax.apatch);/data/adb 为 APatch 布局(ap/、apd、zygisksu/、metamodule→meta-overlayfs、lspd/、tricky_store/+8 模块:WorkSettingPro、auditpatch、meta-overlayfs、netproxy、tricky_store、unlock_hotspot_limit、zygisk_lsposed、zygisksu);/data/local/tmp/shf.kpm=KPM 模块。Phase-0 调研"Magisk 可用"与本文档 §3.1/§3.4 措辞作废(rescue/dumps/boot_a-magisk.img 命名保留,实为 KPatch-patched boot_a,与今日 boot_a.img 哈希一致 8dd1141d) | 恢复逻辑不变且更简单:内核补丁在 boot_a(永不触碰)→ 恢复出厂后重装 me.bmax.apatch.apk 即恢复 su,模块从 data-adb.tgz 解回或重刷。备份已按 §3.1 执行完毕 → **rescue/data-backup/MANIFEST.md**(DE 侧全齐;/sdcard CE 侧被图案锁阻塞,见 §7 Phase-3 准备节) |
| E25 | **x86 宿主裸 `docker build` 产出 amd64 镜像(上游默认 arm64 Mac)**:首次 rootfs 预构建(照抄 install.sh L116-120 命令)`changxing60-kbuild`/`changxing60-ubuntu:26.04` 全建成 amd64 → logdw/bt-init/busybox 清一色 x86-64 且**覆盖了 Phase-1 的 arm64 旧件**(work/ 不进 git,无旧版可回);第二个雷:`mktemp -d work/...` 相对路径被 `docker run -v` 当卷名拒绝(exit 125),歪打正着没让 amd64 busybox 进 assemble。openwrt/build-rootfs.sh 自带 `--platform linux/arm64` 所以唯独 OpenWrt 路径天然免疫 | B10 修复:install.sh 的 rootfs 镜像构建加 `--platform linux/arm64`;helper 改 `changxing60-kbuild-cross` + `aarch64-linux-gnu-gcc -static`(免模拟);Dockerfile.cross 补 `libc6-dev-arm64-cross`(E-Phase1 笔记早有预言未落盘,裸 cross gcc 缺 arm64 glibc 头 `bits/libc-header-start.h`);install.sh/prebuild 均加 `file\|grep -qi aarch64 \|\| die` 断言;mktemp 一律 `$PWD` 绝对路径。arm64 镜像重建 + 双 rootfs 预构建重新后台执行 |
| E26 | **MyOS 恢复出厂后 adb 装 APK 有三道关卡**(apatch.apk 安装实录):① 开关卡——UI"USB安装"拨上即弹回(logcat 见用户 22:43-22:47 反复拨 `enable_adb_install`),真身是 `settings system adb_install_enabled`,UI 开不了但 `adb shell settings put system adb_install_enabled 1` 直接生效;关=0 时 PMS 对 shell uid 硬拒 `reject adb install`;② 路径关卡——`pm install /sdcard/...` 被 SELinux 拒(system_server 无 fuse 读权,"Consider using a file under /data/local/tmp/"),源文件必须在 /data/local/tmp;③ **每装必弹一次人工确认框**(ZTE 框架装后广播 `zte.android.action.adb_install_result`,安全设计,无 settings 旁路) | 实操序列:`adb push <apk> /data/local/tmp/` → `settings put system adb_install_enabled 1` → `pm install -r /data/local/tmp/<apk>` → 手机点一次确认;开关打开后宿主侧 `adb install`(流式)也放行。**根因性对策(E27):能走模块自装就不手动装 APK** |
| E27 | **LSPosed 是 APatch 模块不是独立 APK**(用户纠正):manager(org.lsposed.manager)由 zygisk_lsposed 模块加载时自动装回;手动 `adb install` manager/dirtysepolicy 属方法错误。同理 8 个模块"在 APatch 里安装"的实际操作 = 从 data-adb.tgz 解回 `/data/adb/modules/` + 重启(恢复出厂后的 /data/adb 已被新装 self-init 重建出 ap/+apd,同版本覆盖合并安全) | 恢复序列:push data-adb.tgz → `su tar -xzf … -C /data` → `restorecon -R /data/adb` → 重启 → apd/zygisksu 自动加载 8 模块 → LSPosed manager 应自动出现(缺则从 /sdcard/Download 已推的 APK 手动点装兜底);dirtysepolicy 同理 |
| E28 | **deploy.sh 引号错:宿主 bash 吃掉单引号**:`"$ADB" shell su -c 'rm -rf … && mkdir …'` 中单引号被宿主 shell 消耗,远端实际执行 `su -c rm`(仅第一条以 root 跑),`&& mkdir` 落回 shell 用户 → Permission denied。adb 的参数拼接会让"引号层级"比直觉少一层 | 远端多命令一律 `adb shell "su -c '…'"`(外双引内单引),或推脚本文件上设备执行 |
| E29 | **官方 armsr rootfs 的默认 rc.d 自启服务对 Android 宿主有实害**(2026-09-20 审计):S20network(netifd,共享 netns 内建接口配 IP)、S35odhcpd(IPv6 RA/DHCPv6 与 Android 热点栈打架)、S25packet_steering(改共享内核 RPS sysctl)、S98sysntpd(settimeofday 拨共享时钟)、S94gpio_switch(死重)。**chroot ≠ 隔离,netns/内核参数是共享的** | container/build-rootfs.sh 构建期 `rm -f rc.d/*{network,odhcpd,packet_steering,sysntpd,gpio_switch}`;rc.d 最终只剩 chroot 内部服务(dnsmasq/uhttpd/rpcd/logd/cron/changxing60-vpn) |
| E30 | **容器 tarball 带 sysupgrade/owut/LuCI attendedsysupgrade = 一键毁机**:chroot 里跑 sysupgrade 会向"固件盘"(即手机 /dev/sda)整盘 dd。原生版 openwrt/build-rootfs.sh 早做了 `apk del`,容器版漏了——同一坑在不同构建脚本里重复踩,因为两脚本独立演进 | container/build-rootfs.sh 补齐删除(sysupgrade/owut 二进制、LuCI 菜单/acl/js 资源、uci-defaults、apk 元数据)。**规矩:凡 OpenWrt rootfs 构建脚本,危险物清单(sysupgrade/owut/attendedsysupgrade)必须逐项核对,不许复制遗漏** |
| E31 | **OpenWrt 25.12 ubus socket 路径 = `/var/run/ubus/ubus.sock`(带子目录)**:目录不存在时 ubusd **静默死**(exit 255,无任何报错);旧版才是 /var/run/ubus.sock。另 /var→/tmp 符号链接下这些运行时目录全在 tmpfs,重启即失,每次启动必须 mkdir | service.sh 启动前置 `mkdir -p /var/run/ubus /var/run/dnsmasq …`。**同类教训:静默退出且无日志的服务,先查它写的文件/目录路径是否存在,再查二进制本身** |
| E32 | **chroot 内命令继承 adb/su 的 Android PATH(无 /bin、/usr/bin)**:`chroot $ROOT /bin/sh -c 'mkdir …'` 报 `mkdir: not found`,且此假象曾两次误导排障方向(readlink not found 让人以为 rootfs 损坏);二进制其实都在,只是 busybox applet 符号链接不在 PATH 里 | chroot 执行一律 `chroot $ROOT /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c '…'`;**排障时"command not found"先 echo $PATH 再怀疑文件系统** |
| E33 | **procd 非 PID-1 时不执行 rc.d 启动序列**(容器核心架构问题):`chroot /sbin/init` 在无 PID namespace 的 Android 内核上(CONFIG_PID_NS not set,不可用 unshare --pid)只能得到一个空转 epoll 的 procd——不 spawn ubusd、不跑 rc.d。上游 container/service.sh 的设计**从未被实测过** | 可用序列(实测通过):`ubusd &` → `procd &`(注册 ubus service 对象)→ `for S in /etc/rc.d/S*; do $S start; done`(服务经 procd spawn+respawn)。**规矩:引入新架构的服务管理链路,先读内核 config 确认依赖的 namespace/capability,再写脚本;未经设备实测的脚本 = 不存在的脚本** |
| E34 | **dnsmasq init 硬编码 procd_add_jail(ujail 沙箱)**:ujail 依赖 CAP_PERFMON(38),Android 5.4 内核不认 → dnsmasq exit 5 崩溃循环。原生版早用 `apk del procd-ujail procd-seccomp` 处理(§6 已记载),**容器版重复踩同一坑** | container/build-rootfs.sh 构建期 `sed -i '/procd_add_jail/d' /etc/init.d/dnsmasq`(sysntpd 的 jail 随 rc.d 移除)。与 E30 合并为同一条规矩:两份 rootfs 构建脚本的坑清单必须同步维护 |
| E35 | **【事故】stop 的 umount 静默失败 + rm -rf 穿透 bind mount = 删光 Android 宿主 /dev**:容器进程(uhttpd 等)仍持有 /dev 句柄 → `umount $ROOT/dev 2>/dev/null` 失败但被吞 → dev bind 仍挂着 → `rm -rf /data/openwrt` 顺着挂载点**把宿主 /dev tmpfs 的设备节点全删**(urandom/random/binder/__properties__/ptmx,仅剩挂载点目录)。直接症状:dnsmasq "failed to seed RNG"(系统级,非容器级!被误判)、adb "failed to create pty master"、reboot 命令发不出。恢复:重启即愈(ueventd 重建 /dev),/data 无损 | 三条铁律:①**bind 宿主 /dev = rm 会穿透**,容器 /dev 必须用独立 tmpfs + mknod 白名单节点(null/zero/random/urandom/ptmx/pts/net/tun),永不再 bind 宿主;②umount 必须检查返回值,失败要中止后续操作并报错,禁止 `2>/dev/null` 吞错;③rm -rf 容器根目录前必须 `grep <root> /proc/mounts` 确认零挂载。**排障教训:症状在容器,病根可能在宿主——dnsmasq RNG 报错时先 ls 宿主 /dev 确认节点健在** |
| E36 | **重启后卡 boot(sys.boot_completed 空,只见开机画面)**:容器模块(changxing60_openwrt)开机 late_start 自启后系统未完成启动;此前 8 个原厂模块在上次 wipe 后重启正常过 → 疑凶指向容器模块(其 service.sh 开机执行痕迹:日志"container started"但进程与挂载随后全部消失,行为不干净)。**根因未及确诊,用户决策放弃容器路线** | 用户恢复出厂(第三次 wipe)→ 8 模块重新解回后未再复现(未重启验证,待观察)。**教训:新模块先 disable 状态试装,首个重启不通过立即移除;卡 boot 时 adb 往往还活着,应第一时间 getprop sys.boot_completed + logcat crash 取证再动** |
| E37 | **本项目对"干净回滚"的验收标准不完整**:回滚当时只验证了"写入内容与备份一致"(GPT/boot_b/misc 读回哈希全绿),没验证"系统行为恢复"——容器事故暴露后,用户的"恢复默认状态"诉求实际需要的是**行为级回归**(重启后 boot_completed、模块加载、热点配置、日常 app 全部如常),而非字节级 | 回滚/恢复出厂后验收清单补三项:getprop sys.boot_completed=1、pm list 用户包符合预期、/data 残留目录清点。已补进本文档"恢复速查"与 MANIFEST.md |

**环境落地**:docker.io 26.1.5(server OK)/ lz4 1.10 / qemu-user-static;镜像 `changxing60-kbuild-cross`
(amd64,clang 12.0.0 + aarch64-linux-gnu 工具链)= `kernel/Dockerfile.cross`(分支新增)。

**git 布局**:外层 `~/code/zte7552n` 新建仓库(main,commit 4bc559b:docs+config+shim;
忽略 *.img/*.bin/dumps 大文件、changxing60-linux、kernel-src、soda-reward);
`changxing60-linux` 在分支 `7552n-port`(基线 294deb8 + 适配提交);内核树/realme 树在 `kernel-src/`(gitignored)。

**进行中**:内核交叉编译(后台,预计 1–2h;ThinLTO 开启,内存 13G 可用属边缘,
OOM 则按 §1.2 关 LTO 重跑)。日志:`changxing60-linux/out-linux/build.log`(注意脚本内
`grep|tail -40` 有缓冲,构建中期日志安静属正常)。

### 2026-09-18 Phase 1 完成 + Phase 2 宿主机侧就绪

- **内核**:实际仅 538s(ThinLTO 未 OOM)。`kernel.release = 5.4.254-gb50db5b6224c`
  (与 .scmversion 精确一致);Image 31,992,320B;193 ko;fragment-rejected 仅剩
  5 项良性(E9 修复后 BBR 三项全 =y)。
- **WiFi**:realme 树 wlan_combo 4 补丁全应用(0 rej;`default-board-config` 一个
  fuzz-1 hunk → Phase 4 dmesg 观察项);`sprd_wlan_combo.ko` 2,205,904B,vermagic 精确。
- **产物收集**:85 module-order ko + wlan_combo → `changxing60-linux/out/modules/`
  (llvm-strip --strip-debug,共 7.5M),`out/Image` 就位;missing=0。
- **Phase 3 预演**:GPT 缩容在宿主机 dry-run 完成(勘误 E7 的 4096-LBA 修正版),
  产物 `rescue/gpt-new/g.new.{main,tail}`,独立复核:仅 userdata 条目变化、
  双 CRC 有效、备份 EntryLBA 断言过。
- **Phase 2 代码**:misc BC 双实现互证(gen-misc-blocks.py ≡ build-boot-image.py
  的 live 推导;F50 回归复现原作者字节);init 通用化;三文件已提交分支(f9788f1)。
- **下一步(设备侧,写入前)**:备份 boot_b(sha256 前缀 7479f4ec)/vendor_boot_a/b →
  extract-subset + ueventd-perms → 固件全变体 cp+pull → busybox/logdw → 组装镜像 → flash-trial。

### 2026-09-18 Trial-1:核心机制全绿,USB 因 zlog 级联失败 → Trial-2

- 备份矩阵补齐:boot_b(7479f4ec 与设备侧一致)/vendor_boot_a==b(b737bcfe)/
  init_boot_b(全零,E14)全部 pull 并哈希比对。
- extract-subset(586MB tar 走 pull,52M subset)、ueventd-perms(646 行)、固件 16 件、
  busybox 1.36.1、logdw 全部就绪;镜像 v1 = 37.9MiB,footer/AVB/cmdline 逐项复核通过
  (注:hdr v4 的 cmdline 在 offset **44**;AVBf 在 len-64,footer 数据在其后 44B 内)。
- **Trial-1 结果(03:02 写入→03:17 自动回滚,全程无砖)**:
  - ✅ LK 放行自写 boot_b;自研内核启动;init 全 stage 走通
  - ✅ 模块 80/85;persist-target=rootdisk sda/boot_b sda40(通用扫描正确)
  - ✅ rootfs-unavailable(Phase 3 前预期)→ misc 62s 恢复 slot a → usb0/网络失败(见下)
  - ✅ android chroot:modem/pmsys/sctl_pm/trusty 节点齐;modem_control 启动;
    **`pmic-wdt-rstoff-ready t=4`(t≈70s)→ 设备存活 291s 无断电,300s 定时重启干净回 Android**
  - ❌ `/sys/class/udc` 为空:dwc3-sprd/musb_sprd insmod 失败(E13 zlog 级联)
  - 日志归档:work/logs-trial1/(persist 8M + pstore + uboot_log 16M)
- 修复:module-order 插 zlog_exception_dlkm/zlog_common_dlkm(commit 5ddcabd);
  nm 验证 zlog_common_dlkm 导出 sc27xx_typec 所需全部 3 符号,自身仅依赖内核核心符号。
- 镜像 v2(87 模块,sha e1a82264…)已写入,trial-2 观测中。
- Phase 4 待办新增:充电链补全(见下 trial-2/3 勘误:`cm_notify_event` 实为
  sprd-charger-manager **自身导出**,无需 charger-manager-sqc 变体、无需重编内核)。

### 2026-09-18 Trial-2:机制再绿,USB 仍灭 → 根因锁定 fw_devlink/vddvbus → Trial-3

- **Trial-2 结果(03:12 写入→03:31 自动回滚,全程无砖,loaded=85/87 failed=2)**:
  - ✅ LK/自研内核/init 全 stage、misc 恢复、chroot 四节点、`pmic-wdt-rstoff-ready t=4` 复现
  - ✅ zlog 修复生效:sc27xx_typec/dwc3-sprd-core/phy 全部 `returned 1`(=成功,见 E16)
  - ❌ `/sys/class/udc` 仍空:`25100000.usb3 returned -517 after 2 usecs`(静默 defer)
  - ❌ sprd-charger-manager / sc27xx_fuel_gauge insmod 失败(缺 zte_*/sqc_*/cm_notify_event)
  - 日志:work/logs-trial2/(persist 540KB 文本段)
- **根因链(E17)**:usb3 `vbus-supply=<&vddvbus>` → vddvbus 属 i2c 6-006b bq2560x_chg →
  驱动 sqc_bq2560x.ko 不在 module-order → fw_devlink `device_links_check_suppliers` 永久 -517 →
  dwc3 glue 不 probe → musb_sprd 被 `dwc3_sprd_probe_finish()` 门住 → 无 UDC。
- **精确依赖分析(E18 方法)得出插入序**(→ = 先于):
  `sprd_battery_info → sprd_tcpm → zlog_exception → zlog_common → zte_power_supply →
  zte_misc → charger_policy_service → sqc_netlink → sqc_charger → sqc_bq2560x →
  sprd-charger-manager → sc27xx_fuel_gauge`;链尾仍在 sc27xx_typec → dwc3-sprd → musb_sprd 之前。
  fuel_gauge 真实依赖仅 battery_info/charger-manager/zte_power_supply(wcn_bsp 为假象,不引入)。
- **Trial-3 实施**:6 ko(zte_power_supply/zte_misc/charger_policy_service/sqc_netlink/
  sqc_charger/sqc_bq2560x)llvm-strip --strip-debug 入 out/modules;zlog 两行从 77/78 前移;
  module-order 93 项;镜像 v3 sha `8ae51024…`,ramdisk 7.84MB,BC 块与 trial-2 逐字节一致;
  flash-trial 全链哈希校验通过,03:5x 写入 reboot,observe-trial.sh v2 观测中。
- 判定标准:`http://192.168.77.1/` httpd 起 = UDC+gadget 全通;failed 模块数应 ≤0
  (fuel_gauge 预期这次能装载);回滚后 slot=_a、misc=96b18d84 尾。

### 2026-09-18 Trial-3:充电链全绿,USB 新根因 dummy-phy(E19)→ Trial-4

- **Trial-3 结果(03:5x 写入→04:32 自动回滚,全程无砖,loaded=93/93 failed=0)**:
  - ✅ 充电链 6 ko 全部生效:`probe of 6-006b returned 1 after 351737 usecs`
    (sqc_bq2560x 成功,实际芯片 **upm6910h** 非 bq2560x,驱动兼容);vddvbus 注册;
    sprd-charger-manager/sc27xx_fuel_gauge/zte_power_supply 全装载(E18 的"fuel_gauge
    不需 wcn_bsp"实证)。
  - ✅ 机制第三次全绿:misc 恢复、chroot 四节点、`pmic-wdt-rstoff-ready t=4` @73.03s。
  - ❌ USB 仍灭,但形态变了:`probe of 25100000.usb3 returned 0`(×4,配 dev_err
    "unable to get usb2.0 phy device")+ `probe of 64a00000.usb returned 0 after 35 usecs`;
    ssphy/hsphy 本身都 `returned 1`。
  - 日志:work/logs-trial3/(persist 611KB 文本段)。
- **根因(E19)**:live DT usb3 `usb-phy=<0x60(dummyphy),0x24(ssphy)>`,GPL 树无
  `sprd,usb-dummy-phy` 驱动 → glue `devm_usb_get_phy_by_phole(...,0)` 永久 -EPROBE_DEFER
  (失败路径 `goto err_ipa_clk`,仅 vbus 容忍)→ `dwc3_probe_finish` 不置位 → musb 被门住。
- **修复**:realme-unisoc-5.4 树 `drivers/usb/phy/phy-sprd-dummy.c`(GPL、自包含、
  compatible 精确匹配)按外部模块法编出 phy-sprd-dummy.ko(kernel/build-dummyphy.sh,
  vermagic 精确、零模块依赖),module-order #84 插入(dwc3-sprd #87 前)→ 94 模块;
  镜像 v4 sha `b485399c…`。commit changxing60-linux 2e2c9f8。

### 2026-09-18 Trial-4:UDC 通了!gadget 空绑(E20)→ Trial-5

- **Trial-4 结果(04:49 写入→04:55 自动回滚,第 4 次无砖,loaded=94/94 failed=0)**:
  - ✅ **E19 修复完全生效**:`dwc3-sprd 25100000.usb3: sprd dwc3 probe finish!`、
    `probe of 25100000.usb3 returned 1 after 81229 usecs`、`b_sess_vld` →
    `dwc3_sprd_otg_start_peripheral: turn on gadget dwc3-gadget` → `peripheral state`;
    musb-hdrc.1.auto 也 probe 完成(host 侧,USB bus 1 注册)。
  - ✅ **`stage=udc udc=25100000.dwc3`** —— UDC 首次出现;usb-bind rc=0(trial-3 是 rc=1);
    Windows 宿主完整枚举:GET_DESCRIPTOR 序列→`USB_STATE=CONNECTED`→SET_CONFIGURATION→
    `configfs-gadget gadget: high-speed config #1: c`→`USB_STATE=CONFIGURED` @25.04s。
  - ❌ 但 `stage=usb0 ifconfig: Device not found`:usb0 网络设备不存在 → httpd/telnet 无载体。
  - 日志:work/logs-trial4/(persist 600KB + observer.log)。
- **根因(E20)**:stock ZTE config 无 `CONFIG_USB_CONFIGFS_{ECM,RNDIS,NCM}`(Android 用
  F_FS+UEVENT)→ init 的 `mkdir functions/ecm.usb0` ENOENT 未校验 → 绑成只含 ACM 的
  **空 gadget** → 宿主枚举正常但无任何网络接口。F50 stock 带 ECM,作者 init 才能原样跑;
  且本宿主是 **Windows**(build 28000,有 rndismp6/usb8023*,无 usbncm.sys,从无 ECM
  原生驱动)——单补 ECM 也不通,**必须 RNDIS**。
- **Trial-5 实施**:
  - fragment 补 `USB_CONFIGFS_{RNDIS,NCM,ECM}=y` + `USB_F_{RNDIS,NCM,ECM}=y` +
    `USB_U_ETHER=y`;重编内核 120s(增量+LTO relink),Image 32,002,560B(sha `03d50fec…`);
    kernel.release 不变 `5.4.254-gb50db5b6224c`;**Module.symvers 仅 +31 个新符号
    (gether_*/rndis_*/ncm_*),既有 CRC 零变化** → 94 个 vendor ko 全部继续兼容,无需重编。
  - init:gadget 函数改为按可用性择一 `rndis→ncm→ecm`(configfs mkdir 成功即选中,
    netdev 都是第一个绑定者 usb0);新增 `stage=usb-netfn`/`stage=usb0-netdevs` 日志;
    bind 后加 usb0 出现等待循环(10×1s)。
  - 镜像 v5 sha `52a65a32…`,ramdisk 7,843,692B,94 模块,BC 块同前;05:1x 写入 reboot。
- 判定标准:httpd@192.168.77.1 可达(Windows 侧 RNDIS 适配器 DHCP 拿 192.168.77.2-9);
  `stage=usb-netfn rndis`;dmesg 有 rndis 枚举(宿主会发 RNDIS OID 消息而非 ECM 通知)。

### 2026-09-18 Trial-5:设备侧全绿(rndis+usb0),宿主差 MS OS 描述符(E21)→ Trial-6

- **Trial-5 结果(05:09 写入→05:15 自动回滚,第 5 次无砖,loaded=94/94 failed=0)**:
  - ✅ `stage=usb-netfn rndis`;usb0 存在(HWaddr 02:50:00:00:77:01),`configfs-gadget:
    HOST MAC/MAC`(rndis function bind 成功);bind rc=0;宿主 SET_ADDRESS→描述符→
    SET_CONFIGURATION 全套走完,设备侧 udhcpd/telnetd/httpd 全部拉起。
  - ❌ Windows 侧无网卡:宿主**未再发 0x3EE**(MS OS 字符串)请求——trial-4 已把
    `0525:a4a1/CHANGXING60LINUX` 缓存为"无 OS 描述符";且本轮本来也没配 os_desc → rndismp 不绑。
  - 日志:work/logs-trial5/。
- **修复(E21)**:init 补 `os_desc/{use=1,qw_sign=MSFT100,b_vendor_code=0x1}` +
  `functions/rndis.usb0/os_desc/interface.rndis/compatible_id=RNDIS`(全部先于 UDC bind);
  idProduct 0xa4a1→**0xa4a2** 破 Windows 设备实例缓存。内核无需再动(rndis 已内置,
  f_rndis 自带 os_desc_table,composite 在 use_os_string 时自动应答 0xEE+vendor 请求)。
- 镜像 v6 sha `403d614d…`(仅 init 变化,ramdisk 7,844,272B),05:2x 写入;
  判据同前:httpd@192.168.77.1 可达;附加验证 `stage=usb-osdesc on` 与宿主 0x3EE 请求回归。

### 2026-09-18 Trial-6:描述符链全绿,但 Windows 28000 无 RNDIS 驱动可绑(E22)→ Trial-7 NCM 转向

- **Trial-6 结果(05:18 枚举→~05:23 自动回滚,第 6 次无砖;persist 635KB:work/logs-trial6/)**:
  - ✅ 设备侧全绿:`stage=usb-osdesc on`、`stage=usb-netfn rndis`、usb0 up、udhcpd/telnetd/httpd 起;
    宿主 0x3EE MS OS 字符串请求**回归**(PID a4a2 破缓存生效)、compat-ID(C0/0x01/wIndex=4)与
    ext-props(C1/0x01/wIndex=5)全部服务、"Get System is Windows"、CONNECTED→CONFIGURED @26.1s。
  - ❌ Windows 侧:PnP 建 `VID_0525&PID_A4A2` MI_00/MI_02 节点(Kernel-PnP 400/410/430 @05:18:32),
    MI_02 绑 usbser=**COM15 成功**;**MI_00 无驱动**(Service/Class 空、ConfigFlags=64、
    ProblemCode 空——不是绑定失败,是根本没有 INF 匹配)。
  - 宿主取证(work/win-rndis-deep.ps1):DriverStore **无 rndismp6**;有 rndiscmp(未匹配)、
    **usbncm.inf+usbncmum.inf 在库** → legacy RNDIS 死路,**NCM 类匹配是正解**(E22)。
- **Trial-7 实施(镜像 v7 sha `3fe6bdaa…`,仅 init 变:内核 03d50fec 不动,ramdisk 7,845,085B,94 模块)**:
  - netfn 优先级 **ncm→rndis→ecm**;os_desc 块锁死 `[ "$netfn" = rndis ]`(E22 修正:f_ncm 也有
    os_desc/interface.ncm,原 `-d` 守卫会给 NCM 错写 RNDIS compat-ID);PID **a4a2→a4a3**;
    rescue 路径新增 **ttyGS0 串口控制台**(busybox 无 getty,`/bin/sh -i` respawn 循环)。
  - 观察者升级(work/observe-trial.sh v3):双通道探测(WSL curl 每 2s + Windows curl.exe 每 6s,
    防 NCM 适配器防火墙/NAT 造成假阴性);HTTPD UP 且 WSL 可达时自动 telnet `touch /run/stay`
    钉住会话(rescue 路径已先 restore_slot_a、misc=slot-a 活跃,停留安全,断电也回 Android)。
  - 判据:Windows 出 NCM 适配器(usbncm 绑 MI_00)→ DHCP 拿 192.168.77.2-9 → httpd/telnet 可达;
    设备侧 `stage=usb-netfn ncm`(无 `usb-osdesc` 行属正常)。

### 2026-09-18 Trial-7:usbncm 绑定成功(E22 验证通过)!但 http 不可达(E23 首现)→ Trial-8

- **Trial-7 结果(05:42 flash→05:48 自动回滚,第 7 次无砖;persist 7359 行:work/logs-trial7/)**:
  - ✅ 设备侧全绿:`stage=usb-netfn ncm`、bind rc=0、宿主 SET_CONFIGURATION @25.1s、usb0 carrier、
    `ttyGS0-console on`、pmic-wdt-rstoff t=4;os_desc 块按设计未触发(无 `usb-osdesc` 行 = 正确)。
  - ✅ **Windows 侧突破**:`VID_0525&PID_A4A3&MI_00 → Class=Net, Service=UsbNcm,
    DriverInfPath=usbncm.inf, ProblemCode=0`——usbncm 按接口类匹配绑定,E22 判断完全验证;
    MI_02→usbser→COM16。
  - ❌ 适配器 4 分钟寿命内 http 始终不可达(观察者只测了 http);当时误判为 DHCP/数据路径问题,
    trial-8 证明:httpd 无 socket 空转(E23),而 telnetd 其实全程可达、DHCP 也早已成功
    (Windows 缓存了 trial-7 拿到的 192.168.77.4 lease)。

### 2026-09-18 Trial-8:live 验尸——救援网实际已通,唯一故障点 = httpd 空转(E23 定位)→ Trial-9

- **Trial-8(镜像 v8 sha `c2fa09e4…`,+ usb0-stats 5s 记录器;三通道观察:WSL observer +
  Windows watcher(Get-NetAdapter/DHCP/静态回退/TCP/curl/ping)+ COM16 串口控制台)**。
- 05:57:28 适配器现身即 Up@426Mbps、**192.168.77.4/24(PrefixOrigin=Dhcp,trial-7 缓存 lease)**;
  PING 持续 ok;TCP:80 WSL/Windows 均不可达。
- **串口控制台首次实战**(E22 加的兜底立刻立功):COM16 钉住 /run/stay → live 验尸:
  usb0 UP RUNNING、IP 正确、ARP `.4↔02:50:00:00:77:02`、RX/TX 双向流包;三守护进程俱在;
  netstat 唯 :23 在听——**httpd(1639)无监听 socket、State R、fd 仅 0,1,2→/dev/null、
  utime+stime≈全寿命**;同 cmdline 手动 `-v` 跑即刻 bind :80。
- 手动修复后 **Phase-2 判据全部 live 通过**:WSL curl 首页、Windows curl.exe、WSL telnet 拿 shell、
  拉回 734KB live dmesg + modules(work/logs-trial8/)。
- telnet `sync; reboot -f` 回 Android:slot `_a`、misc `96b18d84`——第 8 次循环干净。
- **Trial-9 实施(镜像 v9 sha `c588bec4…`,init commit a93b3fc)**:httpd `-f` respawn 循环 +
  :23/:80 watchdog + stats awk 锚定;observer v4 telnet+http 同探。

### 2026-09-18 Trial-9:httpd 自启修复验证通过——**Phase-2 救援网络收官(全自动闭环)** ✅

- **Trial-9(06:13 flash→06:20 自动回滚,第 9 次无砖)**:
  - 06:14:41 observer v4 开始轮询 → **06:15:12 HTTPD UP(Windows curl.exe)**——设备 uptime ~34s
    (27.3s `stage=ready`)即自动服务,**全程零人工**。
  - index.html(v9 横幅)+ **503,285B live dmesg** 拉取成功;设备侧 tx 计数 530,544B 与之吻合。
  - persist9(7438 行,work/logs-trial9/)取证:`httpd-watchdog-respawn` **0 次**——`-f` 循环首试
    即 bind,watchdog 纯兜底;`usb0-stats`×53(锚定修复生效);stage 级联完整;ARP 表记录了
    WSL 宿主 IP(192.168.43.72)——WSL 的 SYN 到达过设备,回程 Windows 不转发回 WSL,
    故本轮 WSL 侧不可达属宿主网络拓扑问题(E23 教训④),非设备故障。
  - leases=[] 全程 = Windows 继续用缓存 lease(与 trial-7/8 行为一致,DHCP 本身 trial-7 已证明可用)。
  - 300s 计时自动重启 → **第 9 次干净回滚**(slot `_a`,misc `5f61…96b18d84`)。
- **Phase-2 验收结论:PASS(全自动形态)**——刷入 trial 镜像后不碰键鼠:NCM 网卡自动绑定 →
  httpd/telnetd/udhcpd 自动监听 192.168.77.1 → 宿主 curl 拿日志/shell → 300s 自动回 Android。
  安全网三层全部实战验证:misc 前置恢复(断电安全)、LK 自动回滚、ttyGS0 串口控制台(驱动无关)。
  9 个循环 0 砖。镜像谱系:v5 `52a65a32`→v6 `403d614d`→v7 `3fe6bdaa`→v8 `c2fa09e4`→
  v9 `c588bec4`(内核 03d50fec 自 v5 起未变,94 模块)。
- 下一步:**Phase 3(重分区)**——先按 §3.1 备份 /data 贵重物,再 GPT 重写 + recovery 恢复出厂。

### 2026-09-18 Phase-3 备份与准备完成(卡两道人工门,等用户)

- **§3.1 备份执行完毕**(06:30–06:40,rescue/data-backup/ + MANIFEST.md,payload 不进 git):
  /data/local/tmp 整目录 841MB/64 文件(boot 镜像哈希与 rescue/dumps 全一致,双份互证);
  /data/adb 设备侧 tar → data-adb.tgz 75MB/343 条目(**E24:root 实为 APatch**,8 模块全在);
  APK×5(APatch manager、LSPosed manager+dirtysepolicy、SodaReward 签名 release、injecttest);
  WifiConfigStoreSoftAp.xml。
- **GPT 零漂移验证**:主/备 34 LBA 重拉,与 rescue/dumps/gpt_*.bin 字节一致(main 85c9b8a3、
  backup d7d12c8b)→ 重跑 gpt-shrink-userdata.py → **rescue/gpt-new/ 产物逐字节复现**
  (userdata →2230784..19007999=64GiB;OFF=77858865152 SIZE=50096766976)。
- **门 1(数据,阻塞)**:/sdcard≈1.6GB 为 CE 加密(root 只见 fscrypt 密文文件名,
  `ls /sdcard` 在 shell 命名空间不存在),**手机设图案锁**(dumpsys lock_settings:
  CredentialType=Pattern)且 trial-9 回滚重启后无人解锁;root 注入 wake+swipe/dismiss-keyguard
  均无效 → **须用户解锁屏幕一次**才能备份;恢复出厂不可逆销毁该数据,备份前绝不进 §3.4。
- **门 2(操作)**:§3.4 recovery 恢复出厂需屏幕手动选择(recovery 可能还要求图案确认)。
- GPT 回写(§3.3,可逆——原盘在 dumps,dd 回写即恢复)安排在**两道门都有用户在场时**紧贴执行,
  避免手机长时间处于"GPT=64G / f2fs=110G"的不一致中间态(意外重启会 mount 失败→bootloop 观感)。
- 等待期间可自动推进:§3.5 的 ~~B1-B6~~ **B1-B10** 脚本适配(✅ 已提交)+ docker arm64 构建双
  rootfs(✅ 进行中,纯宿主侧,零设备风险)。**B10 教训(2026-09-18 预构建实抓)**:x86 宿主上
  上游"裸 docker build"产出 amd64 镜像 —— 首次预构建的 busybox/logdw/bt-init 全是 x86-64,
  assemble 因 mktemp 相对路径先行报错才没污染到底。修复见 §3.5 B10 行;arm64 断言已进 install.sh,
  同类错误以后会在源头 die。

### 2026-09-20 GPT 回滚(恢复全容量) + OpenWrt 容器尝试与放弃(用户决策)

**背景**:用户要求放弃 changxing60root 分区方案、恢复手机原厂全容量,改走
`container/`(OpenWrt chroot 常驻 Android)路线。执行过程中发生 E35 /dev 损伤事故
与 E36 卡 boot,最终用户拍板:**不折腾 OpenWrt,纯 Android + root + 8 模块日常形态**。

**A. 存储层回滚(全部读回验证通过,与 §3.3 缩容写入完全对称)**
- 预检:盘面确认为缩小版 GPT(entries md5 c6f0e433 = g.new.main、备表 43a71d89 = g.new.tail)
- push + 双端 sha256 互证 → 主表前 6 LBA dd(读回 03e96b6d=原厂)、备表 34 LBA @ seek=31240158
  (读回 d7d12c8b=原厂)、boot_b 原厂镜像 64MiB(读回 7479f4ec)、misc 控制块 32B(dcb99da1)
  + BCB `boot-recovery` → recovery 手动 wipe → **/data 111G 全容量恢复,原厂 f2fs 重建**
- 注意:回滚时 changxing60root ext4 从未建过(LBA 19008512 起全零)→ 回滚零数据纠缠,时机最干净

**B. OpenWrt 容器部署与调试全程(E28-E36 勘误对应)**
- 顺利:rootfs 构建加固(E29 移除 netns/内核级危险服务、E30 移除 sysupgrade 家族)、
  部署、ubusd→procd→rc.d 链路打通(E31-E33 修通)、uhttpd LuCI :80 监听成功
- 事故:E35(/dev 删光,重启即愈)→ 重新部署;E36 重启卡 boot → 用户决策放弃
- 容器代码状态:container/ 的 build-rootfs.sh(3 处安全加固)与 service.sh(重写版)
  留在 changxing60-linux@7552n-port 分支封存;**未经二次实测,视为实验品**;若重启此路线,
  必须先落实 E35 铁律(容器 /dev 独立 tmpfs 白名单节点、umount 验证、rm 前查挂载)

**C. 最终形态(2026-09-20,用户验收"装完 APatch 和模块后就不动了")**
- 系统:原厂 111G 全容量;GPT/boot_b/misc 全部原厂验证态;boot_a = KPatch(root 来源,保留)
- 三次 wipe 时间线:①22:37 缩容 64G → ②09-20 01:xx 回滚原厂+全容量 wipe
  → ③09-20 02:xx 放弃容器后 wipe(本次)
- 已恢复:adb_install_enabled=1、APatch APK + superkey 绑定(su=uid0 ✓)、
  8 模块解回 /data/adb/modules/ + restorecon(WorkSettingPro、auditpatch、meta-overlayfs、
  netproxy、tricky_store、unlock_hotspot_limit、zygisk_lsposed、zygisksu)
- 未恢复(按"不动"原则,PC 备份在 rescue/data-backup/ 随时可解):bk-softap.xml(热点配置)、
  sdcard.tar(1.7G 用户数据)、SodaReward 等 APK
- 待观察:模块生效需重启一次;上次同批模块在 wipe 后重启正常(E36 记录了疑凶是容器模块),
  重启后应验证 LSPosed manager 自装(E27)

### 2026-10-08 上游 v2026.10.10/11 重评:维持现状 + 显示实验立项(Phase-D)

**上游动态(与移植相关的增量)**
- **Magisk flashable zip 全矩阵**(openwrt/ubuntu × k5.4/6.18/7.2,配 SHA256SUMS-magisk)——为
  F50/U30 Air 而编,7552N **不可直刷**(充电芯片 bq25601≠本机 upm6910h/sqc_bq2560x、WiFi 固件
  变体 _ab≠本机 _aa/.xpe、misc slot 字节 0x9f/0x1e≠本机 0xff/0x0f)。格式通道现成,自建 zip
  走 7552n-port 分支按同格式打包即可。
- **SD 卡安装路线对 7552N 无效**:实测 DT mmc1 节点带 cd-gpios/sd-hotplug-*/UHS 属性(焊盘预留),
  但实机**无物理卡槽**(用户确认)。上游"eMMC 只写 boot_b+32B misc、rootfs 落 SD"的零损伤路径不可用,
  存储仍只有 GPT 缩容 userdata 一条(需 wipe)。
- FINDINGS §37(2026-10-06/07):**mainline 6.18 系统 suspend 已通**——PSCI SYSTEM_SUSPEND,
  AP 睡/modem 醒,DDR 保留,rtcwake 20s 实测正常;修正"Linux 常醒"旧判断(mainline 路径)。
  5.4 vendor 路径(本移植所走)未见 userspace suspend 触发器(无 powerHAL/autosleep)→ 推断仍常醒。
- mainline 充电本周才修通(patches 0009-0011:bq256xx 驱动+UMP9620 充电检测+FGU 保存电量),
  **仅覆盖 U30 Air 的 bq25601**;本机 sqc/upm6910h 走 mainline 需自适配。全项目**无 mAh 续航实测**。
- v2026.10.11:LuCI 46 语言、面板电池磁贴(含瞬时瓦数)、6.18/7.2 上 KVM+WireGuard+SQM+
  PPTP/L2TP/6in4/GRE/VXLAN/USB 网卡/文件系统/容器等 ~360 内核模块全集、Tailscale 过隧道。

**重评结论:维持现状(~80% 不必要)**
- 存储无新路径;身份冲突未解:汽水挂机需 Android 在线,双启动同一时刻二选一,Linux 时长=停赚时长
- NetProxy 已带规则分流(docs/modules/netproxy.md:"规则集质量与订阅同级")→ OpenWrt 增量仅剩
  SQM/每客户端统计/防火墙精细度/包生态(后者 Termux+root 亦可覆盖)
- 7552N **无可用 LED**(/sys/class/leds 仅 mmc0::/1::/2:: 哑触发)→ 无显示=纯黑箱,
  电量唯一入口=LuCI 面板磁贴(luci-app-changxing60,连热点后浏览器 192.168.x.1)
- 翻盘信号(出现任一再重评):①汽水停跑/换机 ②SQM 治上行、端口映射、按客户端策略成真需求
  ③MyOS 模块生态崩坏(system_server 更新杀 root/模块互踩) ④纯项目兴趣

**显示实验立项(Phase-D)——证据链与步骤**

证据链:
1. kernel/build-display.sh(upstream bd29424c/9f3cfb4a,2026-09-17):GPL 树 drivers/gpu/drm/sprd
   的 Unisoc DRM 栈**外部模块**构建配方(为 F50 USB-C DisplayPort/HDMI + labwc 桌面服务);
   DPU0/DSI 一并编入,仅因 F50 无 panel DT 节点而不 probe——**本机有 panel 节点,正好补位**。
2. 7552N stock config `# CONFIG_DRM_SPRD is not set`,但 Android 屏幕正常 → 显示驱动在
   /vendor/lib/modules 以外部模块形态存在(外部模块的构建配置不进 /proc/config.gz);
   与本移植 94 模块同一提取-加载方法论,显示模块此前从未被枚举。
3. stock config 框架内建:DRM=y / DRM_MIPI_DSI=y / DRM_PANEL=y / DRM_KMS_HELPER=y;
   BACKLIGHT_PWM=m、PWM_SPRD=m(模块,可提取)。
4. 本机 DT(手机原厂 DTB)有 dpu/dsi/panel 节点;LK 开机点屏(boot logo)→ panel 时序已被
   bootloader 初始化,内核只需接管。
5. trial-9 实测 dmesg 无任何 DPU/panel probe(仅 mipi_dsi_bus_init 空转)——从未加载,预期内。

步骤(设备连回后):
- D1 枚举:Android `lsmod` + `ls /vendor/lib/modules | grep -iE "dpu|dsi|panel|disp"` → 模块名与依赖
- D2 提取(cp+adb pull 铁律)→ 依赖分析(readelf -r 引用 ∩ Module.symvers,勿用 grep -F)→
  追加 module-order(充电链之后;显示可能依赖 regulator/PMIC 链,已加载)
- D3 试启:看 /dev/dri/ 与 /dev/fb0;出 fb0 后 fbcon 或最小渲染器上状态屏(电量/信号/IP/负载)
- D4 兜底:vendor 模块缺 panel 驱动 → 按 build-display.sh 配方从 GPL 树编 DPU0+DSI 外部模块;
  再不行从 vendor dtsi 抄 panel init 序列自写

风险与工作量:
- 依赖链拖未知模块(中;方法论已验证) / panel 驱动缺失(低中;配方+自写兜底) /
  点亮但花屏闪屏(中;不阻塞"能显示"结论) / 显示驱动与 Android 服务隐性耦合(低;fbdev 路径自包含)
- 首亮半天(结果不确定)→ 稳定状态屏 1-2 天。成功则"黑箱"no-go 理由消失,
  并可继承上游 labwc 桌面路线(其 USB-C HDMI 目标共享同一 DRM 栈)。

---

**路线 B 详细设计**:见 `docs/changxing60/display-design.md`(Phase-D 技术展开:显示栈分层澄清
"原生 Linux 不缺驱动"、阶段 1 trial 回退安全、§3.1 对 D3 的 fb0→DRM/KMS 硬修正、耗电预算、
D1-D5 分步、§6 为何不走路线 A 嵌套 Android、§9 试启执行计划)。状态:设计稿,未执行。

### 2026-10-10 终止:正式放弃归档

**决定:移植方案终止,本目录转为只读档案。** 归档索引与完整放弃理由见
[`docs/changxing60/README.md`](README.md)。当前形态不变:纯 Android + APatch root + 8 模块。

**网络优势误判纠正(别再把假优势当真)**:此前推进 5.4 的核心论据之一"5.4 用 Android 量产
验证网络栈故比 7.2 稳"= 假。`kernel/build-linux.sh`(`cd /src/zte-u30air` + `$M Image modules`)
证明 94 模块是**源码重编**非出厂二进制;`docs/FINDINGS.md` 行 194 sprd_wlan_combo 来自 realme
C51/C53 drop、行 203 符号 CRC 约束须重编 → 与上游 mainline 模块同源,不自动继承 Android 量产光环。
U30 Air 最坏 WiFi 问题(§31m 明确 "under 6.18" = mainline 专属;§31a DMA sync = 前向移植回归特征)
结构上偏 mainline 路径,但**9 trial 只证基础起网、从未压测 WiFi** → 5.4 网络稳无实证。
5.4 站得住的优势收窄为:显示原生 + boot 已证 + 原始驱动源码(非前向移植);不含"网络已证稳"。

**重启前置**:`changxing60-linux@7552n-port` 落后 `origin/main` 497+ commits 需 rebase;
先读 README 纠正版,别以"5.4 网络更稳"为默认前提;充电 sqc/upm6910h、显示 Phase-D 仍是未解项。
