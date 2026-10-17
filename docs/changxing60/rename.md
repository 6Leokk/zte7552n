# 命名:mu300 → changxing60

> **状态(2026-10-16)**:**已全量落地并上机实测**。仓库侧、设备 rootfs 侧、**启动镜像侧**三处都已改名,
> 重启后逐项复验通过(§5)。设备上只剩 4 处**故意保留**的字符串,全部是别人的名字(§6)。
>
> 这台机器是 **ZTE 7552N / P720S20,board `changxing60`**。工程早期沿用了上游那套 `mu300` 的名字
> (上游项目面向的是 F50/MU300,同一颗 UMS9620)。用户 2026-10-16 的要求是
> 「我们是 changxing60,我希望你这次也给所有的都纠正好」——本文件是这件事的全记录。

## 1. 改名规则

一条规则,三种写法:

| 旧 | 新 | 用在哪 |
|---|---|---|
| `mu300` | `changxing60` | 路径、文件名、服务名、uci 值、日志前缀、散文 |
| `MU300_` | `CHANGXING60_` | 我们自己设的环境变量(如 `CHANGXING60_HOST`) |
| `MU300` | `changxing60` | 散文里的裸写(不保留全大写) |

**故意不动**的四类(见 §6):`kanoqwq/mu300-linux`、`dikeckaan/mu300-linux`(上游仓库 slug,改了就不是引用了)、
`mu300dash`(上游的 LuCI 面板,评论里拿它做对照)、`MU300_ZYV1.0.0B09`(厂商固件型号串,它命名的是硬件不是我们)。

替换用**占位符**做,不是 `\x01` 转义:busybox sed 不认那些转义,而占位符本身不能含 `mu300`
(否则会被后面的替换再改一遍)。`tools/rename-device.remote` 里是 `__CX60A__`…`__CX60D__`。

## 2. 为什么是**两件**东西,而不是一件

这是这次唯一真正花时间的地方。**rootfs 和启动镜像是两个独立工件**:

- **rootfs** 在 ext4 上(`/` 就是 `/mnt/<disk>/openwrt` 的 bind mount),由 `tools/rename-device.sh` 改。
- **启动镜像**在 `boot_b` 分区里,由 `boot/init` + 内核 + ramdisk 组成,`boot/build-boot-image.py` 生成。
  它**先于** rootfs 运行,rootfs 里改什么都影响不到它。

`boot_b` 里那份 init 带走了这些旧名字:

| 位置 | 旧值 | 可见性 |
|---|---|---|
| `mkdir /run/mu300` + 两个 BC 文件 | `/run/mu300/` | 设备上 `ls /run` 直接看得见 |
| `mount --move /disk /newroot/mnt/mu300-disk` | `/mnt/mu300-disk` | `mount` / `df` 看得见 |
| `cat /newroot/etc/mu300/default-boot` | 见 §3 | **不是外观问题,是安全问题** |
| `echo MU300LINUX > .../serialnumber` | USB 序列号 | **Windows 设备管理器看得见** |
| `echo "MU300 Linux USB Ethernet" > .../product` | USB 产品名 | **Windows 网络适配器名字就是它** |
| `hostname mu300-linux` | 主机名 | 被 rootfs 覆盖成 `changxing60`,看不到 |
| `MU300-PERSIST-BEGIN` / `MU300-LINUX:` | boot_b 里的持久日志 | 取证时才看 |
| `cat /disk/.mu300/boot-os` | 磁盘上的配置目录 | `ls /mnt/changxing60-disk` 看得见 |

所以**只改 rootfs 是不完整的**,而且其中一条会咬人。

## 3. 那个会咬人的地方:`default-boot` 与 `restore_slot_a`

`boot_b` 里那份 init 在 `switch_root` 之前判断:

```sh
if [ "$(cat /newroot/etc/mu300/default-boot 2>/dev/null)" = linux ]; then
    log "stage=default-boot-linux (slot a restore skipped)"
else
    restore_slot_a          # dd if=/etc/misc-bc-slot-a.bin of=$misc bs=1 seek=2048
fi
```

`restore_slot_a` 把 **slot A(安卓)的 bootloader_control 写进 misc**。文件在 = 跳过;文件不在 = 写。
rootfs 一改名,`/etc/mu300/default-boot` 就没了(它变成 `/etc/changxing60/default-boot`),于是
**每一次开机都会把 misc 指向安卓**。

它**不会当场把你踢进安卓**:那次开机照常进 Linux,然后 `changxing60-post` 在 S99 用
`changxing60-next-boot --rearm` 把 slot b 写回去。但中间那段(约 70 s)是**敞着的**——
掉电、PMIC 看门狗、任何一次意外断电,下次就从安卓起来。

> 判据:从**设备上**把 boot_b 抽出来看,不要从仓库推。当时仓库里的 `boot/init` 已经是改好的版本,
> 而设备里跑的是旧的,两者的差别只有把 initramfs 解出来 `diff` 才看得见:
>
> ```sh
> dd if=$(readlink -f /dev/block/by-name/boot_b) of=/root/boot_b-live.img bs=1M
> # 拉回宿主,Android boot header v4:kernel 在 4096,ramdisk 在 4096+页对齐(kernel_size)
> lz4 -d -c ramdisk | cpio -idm      # 里面只有一个文件带旧名字:init
> ```

## 4. 怎么做(顺序很重要)

### 4.1 改 rootfs

```sh
changxing60-linux/tools/rename-device.sh              # 干跑,看要动什么
changxing60-linux/tools/rename-device.sh --apply      # 改
```

它做的事:`/opt/mu300`→`/opt/changxing60`(chroot 有活挂载,先挪开再挪回)、`/etc/mu300`→`/etc/changxing60`、
`www/luci-static/resources/view/mu300sms`→`changxing60sms`、按名字重命名各目录下的文件、**只对文本文件**做内容替换
(busybox 的 `grep -I` 不跳二进制,判据是 NUL 字节:`tr -d '\0' < f | cmp -s - f`)、重建 `/etc/rc.d`
(START 编码在符号链接名里,几个服务的 START 变了)、`network.wan.proto` 改成 `changxing60cell`
(netifd 按**文件名**找协议处理脚本,不改就没有 WAN)。

原件全在设备 `/root/rename-changxing60.backup/`(`files.tgz` + `paths-before.txt`),每步都可手改回去。

**这一步做完不要重启**——先做 §4.2。

### 4.2 重编并烧 boot_b

`boot/repack-ramdisk.py` 是为此写的:它**从一个已经能启动的镜像出发**,只换 ramdisk 里的文件,
内核 30 MiB 一个字节都不动。相比 `build-boot-image.py`(要从零备齐 kernel Image / modules /
busybox / android-subset 整套工具链),这里改的只有 `/init` 一个文件。

```sh
cd changxing60-linux
python3 boot/repack-ramdisk.py --base work/boot_b-live.img --set init=boot/init \
        --out work/boot-linux-slotb.img
tools/flash-boot-b.sh --image work/boot-linux-slotb.img --reboot
```

**先自证工具是忠实的**:拿设备上原样的 init 回填一遍,输出必须与输入**逐字节相同**
(2026-10-16 实测 `cmp` 通过)。不通过就说明 cpio 解析/回写有损,别往下走。

镜像布局与 `build-boot-image.py` 一致(它产出的镜像设备已经在跑):header v4 → 内核 → ramdisk(各自页对齐)
→ AVB 块挪到 body 末尾 → 64 字节 AVB footer 里 `original_image_size` 重写成 AVB 块的新位置。
镜像 body 必须停在 56 MiB 之前(boot_b 的尾部是持久日志区),超了直接报错退出而不是悄悄盖掉。

一处与 `build-boot-image.py` **故意不同**:镜像尾部(日志区)是**原样带过去**的,不清零。
`build-boot-image.py` 从零构建,清零合理;repack 是在改一个**已经被启动过**的镜像,
把上一轮的持久日志抹掉就是把这个日志存在的意义抹掉。

### 4.3 为什么要用 `tools/flash-boot-b.sh` 而不是现成的两个

- `boot/flash-trial.sh` 要求设备停在**安卓** slot a 上、走 adb + su。
- `tools/changxing60-slot-b.sh` 是 6.18 试验线用的,它**同时写 boot_b + vendor_boot_b + misc**
  ——因为换内核必须连 vendor_boot_b 一起换(那里有 DTB)。
- 这次内核没换,**只写 boot_b**,`vendor_boot_b` 和 `misc` 一律不碰。

`flash-boot-b.sh` 会先把现有 boot_b 存成 `/root/changxing60-boot-b.old.img`(已有则跳过,
所以跑第二次不会把好副本覆盖成可疑副本),写完 `sync` 后**回读分区算 sha256 比对**,不匹配就
拒绝让你重启并明确说 boot_a 没动过。

## 5. 实测结果(2026-10-16,重启后)

| 项 | 期望 | 实测 |
|---|---|---|
| 内核 | 不变 | `5.4.254-gb50db5b6224c` ✅ |
| `/run` | `changxing60*`,无 `mu300` | `changxing60 changxing60-cmdline.android changxing60-early.txt` ✅ |
| 挂载 | `/mnt/changxing60-disk` | 是;`/mnt/mu300-disk` 连目录都不在了 ✅ |
| 主机名 | `changxing60` | ✅ |
| USB 序列号 | `CHANGXING60LINUX` | ✅(configfs 里读) |
| USB 产品名 | `changxing60 Linux USB Ethernet` | ✅ |
| rc.d | 7 个 `changxing60-*` | bootpaths/vendor/hw/screen/power/ndp/post ✅ |
| WAN | 通 | `proto=changxing60cell`、`up: true`、ping 223.5.5.5 3/3、DNS 解出 baidu.com ✅ |
| chroot | 在,modem 活 | 6 个挂载、`modem_control` 1 个进程 ✅ |
| misc | slot b,tries 2 | `5f6200004243414201020000fe002f00…` ✅ **rearm 生效** |
| 持久日志 | `CHANGXING60-LINUX:` | 21 个 stage 全是新名,**`stage=default-boot-linux`**、旧名行数 **0** ✅ |
| SMS 后端 | 新名下可用 | `ubus list` 有 `changxing60sms`,`list` 返回正常 ✅ |
| 全盘扫旧名 | 只剩 §6 那 4 个 | ✅ |

`/etc/init.d/changxing60-bootpaths`(S00)现在两个分支都是 no-op —— 新 init 自己就建
`/run/changxing60`、挂 `/mnt/changxing60-disk`。**保留它**,因为它是「先改 rootfs、后烧 boot_b」
这个顺序能成立的原因,也是别人在一台没重编过 boot_b 的机器上重跑这套时的安全网。

## 6. 还剩什么(故意的)

设备上 `grep` 旧名还能命中的,只有这 4 处,全部是**别人的名字**:

```
/opt/changxing60/bin/changxing60-sms:   mu300dash              # 上游的 LuCI 面板,评论里做对照
/opt/changxing60/bin/ndp-learn:         dikeckaan/mu300-linux  # 上游仓库 slug
/opt/changxing60/bin/changxing60-at:    kanoqwq/mu300-linux    # 上游仓库 slug
/usr/share/rpcd/ucode/changxing60sms.uc: mu300dash             # 同上
```

另有一处**不算名字、算历史**:`boot_b` 的 48 MiB 处躺着**上一版镜像**写的持久日志(当前日志在 56 MiB),
里面全是 `MU300-LINUX:` 行。那是过去某次开机的记录,没有任何东西再读它;下一次
`build-boot-image.py` 从零构建会把它清零。**没有为了 grep 干净去抹掉一份取证记录**——
真要抹,`dd if=/dev/zero of=$bootb bs=4096 seek=12288 count=2048`。

仓库侧还剩 121 个被跟踪文件提到 `mu300`/`MU300`,其中 108 个在 `upstream/`(vendored 的上游树,
含 ARM Mali kbase 驱动里 `mu300_vm_flags_*` 这类第三方标识符)。分类与逐文件结论见
[`naming-audit.md`](naming-audit.md)。

## 7. 回滚

三层,各自独立:

1. **boot_b**:`dd if=/root/changxing60-boot-b.old.img of=$(readlink -f /dev/block/by-name/boot_b) bs=4M && sync && reboot`
   (旧镜像 sha256 `5e30f3ee…`)。注意它是**改名前的 init**,所以回滚后 §3 那个 `default-boot` 问题
   会回来 —— 那正是 `changxing60-bootpaths` 存在的理由。
2. **rootfs**:`tar xzf /root/rename-changxing60.backup/files.tgz -C /`,再按 `paths-before.txt` 把名字改回去。
3. **落进安卓了**:`tools/changxing60-back-to-openwrt.sh`(顺序是换 payload → 改 DTB 9 字节 +
   装 slot b → 重启 → 验 USB;payload 必须先换)。见 [`mainline-6.18.md`](mainline-6.18.md) 与
   [`access.md`](access.md)。

## 8. 相关

- [`access.md`](access.md) —— 怎么连进去、三态判定(adb 有行=安卓 / adb 空但有 PnP gadget=OpenWrt)、
  重启纪律(任何重启都回 OpenWrt;开机 70 s 内连关两次会掉进安卓)。
- [`drivers.md`](drivers.md) §2.1 —— `vendor_boot_b` 是 5.4 与 6.18 共用的 DTB,9 字节改动方向相反,
  所以**这次一行都没碰它**。
- `changxing60-linux/tools/rename-device.sh` / `.remote`、`boot/repack-ramdisk.py`、
  `tools/flash-boot-b.sh` / `.d/device.sh`、`openwrt/overlay/etc/init.d/changxing60-bootpaths`。
