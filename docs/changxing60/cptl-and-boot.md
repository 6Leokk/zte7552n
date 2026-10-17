# 只读解剖安卓启动镜像:`/proc/cptl` 到底在不在,厂商靠什么复位 CP

> **状态(2026-10-16)**:设备现场实测(全部**只读**,分区一个字节没写)。起因是回答「要不要把安卓的
> `cptl` 驱动搬到 OpenWrt,给厂商 `modem_control` 补上 `/proc/cptl/modemassert` 这个抓手」。
> **答案:搬不了 —— 安卓自己也没有。** 顺带把**真正的 assert/alive 通道**和**我们缺的那一环**钉清楚了。
> 复现命令与诚实边界见 §6/§7。

## 0. 结论先行(四条)

1. **`cptl` 不在 boot_a 里**,也不在 vendor_boot 的 165 个模块、不在 `/vendor_dlkm/lib/modules` 的
   150 个模块、不在安卓实机的 199 个已加载模块、不在 DTB 里。**整个安卓侧没有这个驱动**——
   所以没有东西可以"从安卓搬过来"。
2. `modem_control` 里那串 `/proc/cptl/*` 是**通用代码里的死分支**(它自带容错:
   `open %s unsupport watchdog, errno: %s`)。这台机器(ums9620_2h10_feimao)上,
   assert/alive 走的是 **`/dev/spipe_nr2` 字符设备**,由属性点名(§3)。
3. **我们真正缺的不是 cptl,是 `@modemd` 的应答者**:厂商 `modem_control` 复位 CP 前会等抽象 socket
   `@modemd` 回一句 `SLOGMODEM DUMP COMPLETE`,没人答就死等;而我们盒子上
   **没有任何进程监听 `@modemd`**(§4)。这才是"CP 侧救不回来"的结构性原因。
   ⚠ **方向别搞错**(2026-10-16 由读 `e5-modemd.c` 逐行勘正):**`modem_control` 才是服务端**
   ——是它自己建 `@modemd` 的 listen/accept 线程(它的错误串原文就是
   `Failed to create modemd listen accept thread`),安卓侧 `slogmodem`、上游的 `e5-modemd`
   都是**连上去的客户端**。所以我们眼前有两条互斥的可能,得先分清:
   **(一) `modem_control` 根本没建出这个 socket**(检查时它可能没在跑、或那条线程失败了);
   **(二) socket 建了但没人当客户端应答**。第一步只是开机后重看一眼 `/proc/net/unix` 有没有
   `@modemd`,两条路的修法完全不同(见 [`e5-linux.md`](e5-linux.md) §5(a) 与 §5(b) B5)。
4. boot_a 的内核事实顺手钉下(**与我们的内核是两个 commit**,见 [`drivers.md`](drivers.md)):
   `5.4.254-android12-9-gd5a8ab235157`,构建者 `zte@ironic-r5300-b0113-09`,2024-09-20 15:03:11 CST。

## 1. 怎么读的(方法,可复跑)

```sh
# 设备上(只读:if= 是分区,of= 是 tmpfs)
dd if=/dev/block/by-name/boot_a        of=/tmp/boot_a-ro.img bs=1M     # 64 MiB
dd if=/dev/block/by-name/vendor_boot_a of=/tmp/vb_a-ro.img   bs=1M     # 100 MiB
md5sum /tmp/*.img
# 宿主:scp -O 拉回,md5 对齐后本地解析;分析件在 changxing60-linux/work/boot_a-probe/
```

- **boot_a 是标准 Android boot 头 v4**(`ANDROID!`、`header_size=1584`、`page_size=4096`):
  `kernel_size=40,283,264`、`ramdisk_size=1,488,489`。
  **内核是未压缩的 arm64 Image**(偏移 4096 处 56 字节有 `ARMd` 魔数)——
  这才使得"直接 `grep` 内核字符串"成为有效手段。
- **vendor_boot_a 也是 v4**:`vendor_ramdisk_size=23,552,746`(LZ4 **legacy** 帧,`02 21 4c 18`)、
  `dtb_size=170,052`、ramdisk 表只有 1 段且全 0(ZTE 没用分片表)。解开后是 newc cpio:
  `lib/modules/` 下 **165 个 `.ko`** + `first_stage_ramdisk/` + `prop.default` + `sepolicy`。

## 2. cptl 的搜索证据(含"搜索本身有效"的自检)

| 载体 | 大小 | `cptl` | 自检串(应当有) |
|---|---|---|---|
| boot_a 内核 Image | 40.3 MiB | **0** | `sprd` 363、`modem` 10、`mali` 11 |
| boot_a ramdisk | 1.5 MiB | **0** | — |
| boot_a 整份镜像 | 64 MiB | **0** | — |
| vendor_boot vendor_ramdisk(165 ko) | 55.9 MiB 解压 | **0** | `sipa_dele` 87、`sipa_eth` 71、`sprd_modem_loader` 8 |
| vendor_boot 里的 DTB | 170 KB | **0** | — |
| `/vendor/lib/modules`(150 个文件名) | — | **0** | 有 `wlan_combo` 等 |
| 安卓实机 `/proc/modules`(199 个) | — | **0** | `sipa_dele`/`sipa_eth`/`sprd_modem_loader` 都在 |

**唯一两处命中,都不是驱动**:

- `sepolicy` 5 处 → 全是 **`/cptl/mem`、`/cptl/aon-iram`、`/cptl/mini_dump`、`/cptl/pubcp-iram`**
  (CP 内存 dump 节点,与 `modemassert` 无关);
- `prop.default` 1 处 → 属性名,不是节点。

→ 结论:平台策略里**有** `/cptl/*` 这个概念(内存 dump 用),但**没有** `modemassert`/`start`/`stop`
那套 —— `modem_control` 访问它们的代码在这台机器上**从来不会成功**,它自己也只是打一行
`unsupport watchdog` 就换路走。

## 3. 那它到底靠什么?(prop.default 里点名了)

同一份 `prop.default`(vendor_boot 的 vendor_ramdisk 里,43 KB)写着:

```
ro.vendor.modem.assert=/dev/spipe_nr2      # assert / alive 通道(C 字符设备)
ro.vendor.modem.alive=/dev/spipe_nr2
persist.vendor.sys.modemreset=1            # 复位是开着的
persist.vendor.sys.wcnreset=1
ro.vendor.modem.eth=sipa_eth
```

设备上核对:`/dev/spipe_nr2` **存在**(`crw-rw---- 1000:1000 494,2`)。此外 `modem_control`
二进制里内嵌了第三条路:`echo 1 > /sys/devices/platform/soc/soc:ipa-apb/soc:ipa-apb:sipa-dele/sipa_dele_reset`
(`sipa_dele_reset` 这个 sysfs 节点我们的 5.4 上是**有**的)。

也就是说,厂商这套复位/看护有**至少三条候选通路**,`/proc/cptl/*` 只是其中一条,而且是最不常用的那条。

## 4. 我们真正缺的一环:`@modemd` 应答者(治本候选)

`modem_control` 里的字符串(全部来自 `work/android-subset/vendor/bin/modem_control`):

```
/proc/cptl /proc/cptl/ldinfo /proc/cptl/modemassert /proc/cptl/start /proc/cptl/stop
open %s unsupport watchdog, errno: %s
SLOGMODEM DUMP BEGIN / SLOGMODEM DUMP COMPLETE / SLOGMODEM DUMP ONGOING
%s: client cnct to modemd num = %d, buf = %s
Failed to create modemd listen accept thread
reset_md_thread wait dump complete...
dump complete, Write Prepare Reset to modem_control.
```

即:**复位 CP 之前,它要等日志侧回一句 `SLOGMODEM DUMP COMPLETE`**(安卓上由 `slogmodem` 发),
等不到就一直等(上游 e5-linux 实测这一等是 **300 s**)。

而我们的盒子上:

```
/proc/net/unix → 只有 /dev/socket/logdw(我们自己的 zlog 桥)
                 **没有 @modemd 监听者,没有 slogmodem**
```

→ 厂商自带的 CP 复位链在我们这里**没有应答者**。这解释了为什么"CP 侧不动、只能重启整机"。

### 4.1 谁监听、谁应答(2026-10-16 读上游源码勘正)

上表的字符串里有 `Failed to create modemd listen accept thread` 和
`%s: client cnct to modemd num = %d` —— 两句都出自 `modem_control` 自己,说明
**建监听、accept、把状态流推给客户端的是 `modem_control`**;回 `SLOGMODEM DUMP COMPLETE` 的那一方
是**连进来的客户端**(安卓上是 `slogmodem`)。上游 `e5-modemd.c`(160 行,抽象 AF_UNIX/SOCK_STREAM、
地址 `\0modemd`、滚动 64 字节窗口做增量匹配以容忍任意切包)扮演的正是这个客户端角色。

所以 `/proc/net/unix` 里没有 `@modemd` 这件事**可能指两件不同的事**,别混:
**(一)** 我们的 `modem_control` 压根没建出监听 socket(它没跑起来 / 那条 accept 线程建失败);
**(二)** socket 建了、只是没人连上去应答。
**先做零成本的区分**(开机 `android-vendor-start` 起来后 `grep modemd /proc/net/unix`),
因为两条路的修法不同:前者是查 chroot 环境(上游 e5 有四要素清单),后者才是移植 `e5-modemd`。

上游 [`e5-linux`](e5-linux.md) 有一份 **160 行的 `e5-modemd.c`** 专治后者:
它连上 `modem_control` 的 `@modemd`,收到 assert 类状态就回 `SLOGMODEM DUMP COMPLETE`,
把 assert→Reset→Alive 从 300 s 压到 **4–5 s**,而且**不用重启整机**;还带一个 `blocked` 子命令,
可以**按需**触发一次 CP 复位(专治"AT 服务器挂了但不 assert"——正是我们的形态)。
这是目前最有希望的治本候选(详见 [`e5-linux.md`](e5-linux.md) §4.1 与 §5a)。

### 4.2 结案(2026-10-16):答案是**(一)**,已修;但**通知门在这台机器上不会开**

**先答 §4.1 那个二选一:是(一) —— `modem_control` 压根没建出 socket。** 根因不在 chroot
四要素,在**安卓属性区的属主**:

`modem_control` 只在 `property_get("ro.vendor.radio.modemtype")` **≠ `"not_find"`** 时才建 listen
线程(判据函数 `0xbc60`,`"not_find"` 常量 `0xbcec`,真实型号分支落到 `0xbd90: mov w0, wzr` → 返回 0 →
建线程)。而解包出来的 `/opt/changxing60/android/dev-properties/*` 属主是 `1000:1000`,bionic 的
`PropertyInfoAreaFile::LoadPath` 从 `fstat` 取 `st_uid|st_gid`、**两者必须都是 0**(且拒绝 group/world
可写),不合就**打开→fstat→关闭、从不 mmap,全程静默** ⇒ 每个 vendor 守护进程的每次属性读都拿到默认值。

修法一行(已在 `rootfs/overlay/opt/changxing60/bin/android-vendor-start`,bind-mount 之后):

```sh
chown 0:0 $A/dev-properties/* 2>/dev/null || true
```

实测:改前 `getprop` **0** 条、`modemtype=not_find`;改后 **1756** 条、`= nr`。重启
`changxing60-vendor` 后 `@modemd` **立刻出现**(`/proc/net/unix` 里 `00010000` = listen、
SOCK_STREAM),`modem_control` 线程数 **1 → 7**;重启后复验仍在(属性区仍 `root:root`)。

**客户端已移植并常驻**:`changxing60-modemd`(源码 `changxing60-linux/tools/modem/changxing60-modemd.c`,
构建 `tools/modem/build.sh`,装机 `openwrt/overlay/etc/init.d/changxing60-modemd`,START=12、procd respawn)。
线上格式是**实测**的(设备自带 python3 连上去 dump 原始字节),不是抄 e5 的:

```
b'Modem State: Offline\x00CH State: CH OFFLINE\x00'      ← 一连上就收到
```

**NUL 分隔、两个字段**(AP 视角 + CP 视角)。e5 的表里**没有 `Modem State: Offline`、也完全没有 CH
字段** —— 第一版照抄 e5 的滚动窗口客户端因此**一个 token 都匹配不上、却看起来和"modem 空闲"一模一样**。
已改为按 NUL 切消息 + 从本机二进制 `strings` 出的完整 14 条词表 + 不认识的短可打印消息原样打印。

#### ⚠ 关键发现:客户端**收不到** assert 通知 —— 4–5 s 的收益在这台机器上拿不到

`modem_control` 只有 **一个** 地方把状态字符串写给客户端 fd,而且它**紧跟在 `accept()` 后面**
(反汇编 `modem_control`,地址为文件内 vaddr):

| 位置 | 做什么 |
|---|---|
| `0x7874` | `socket_local_server("modemd", 0, SOCK_STREAM)` —— 确认抽象命名空间(和我们的客户端一致) |
| `0x7940` | `accept()`;把新 fd 存进 **20 个客户端槽**表(`0x14790 + 4n`,`-1` = 空闲),日志 `fill<fd> to client[<槽>]` |
| `0x7c30` / `0x7c50` / `0x7c34` | 取 AP 状态变量 `0x147e0`:0→`Modem State: Offline`、1→`…Alive`、其余→`…Assert`;CH 视角另有一张 4 项表 |
| `0x7c7c` / `0x7cdc` | `write(fd, 状态串, strlen+1)` —— **连 NUL 一起写**,这正是实测到的 NUL 分帧 |
| `0x6ea0` | `process_message(len, msg)`(**广播**给所有客户端;日志格式 `process_message(%d) : %s`) |
| `0x80f0`–`0x8104` | 断言处理:仅当 AP 状态变量 **== 1(Alive)** 才置 2 并广播 `Modem Blocked` |
| `0x6f44`/`0x6f7c` | `process_message` 里 `strstr(msg, "Modem Alive")` 命中才把状态变量置 **1** |

**所以状态机的形状是**:`Modem Alive` → 状态变量 = 1 → 断言时门开 → 广播 `Modem Blocked` 给所有客户端
→ 客户端回 `SLOGMODEM DUMP COMPLETE` → 复位立刻走。

**而这台机器上状态变量一直是 0**:客户端一连上收到的就是 `Modem State: Offline`。变量是 0 时那个
`== 1` 的门**永远不开**,所以**已连接的客户端在断言时一个字都收不到**。两次现场观测都一致:客户端
在「真 CP 断言(smsg.c line 168)」和「`changxing60-vendor restart`」两种事件下都**只收到连接时那一份
fill**,之后静默(两次 WAN 都还在 `10.34.151.15` 上跑,证明"没收到通知"不是"客户端没连上")。

⇒ **结论(诚实版)**:移植是忠实的、进程在跑、属性根因已修且跨重启有效、respawn 环已验;
但 **e5 那个"300 s → 4–5 s"的收益在本机通过这条协议拿不到**,因为通知门被 AP 侧状态变量卡在 0。
`changxing60-modemd` 目前是**惰性但无害**的:它只在连接时记录一次状态;一旦哪天 `Modem Alive` 那条路
通了(状态变量能到 1),它会立刻开始工作。**不要再把"压缩 300 s"当成已经拿到的东西写进别处。**

#### ⚠ `blocked` 子命令在本机是危险动作(实测一次,已记录)

上游把 `e5-modemd blocked` 文档成"按需复位 CP"。**本机不要这么用。** 在健康链路上试了一次:
`modem_control` 确实读到了(`read cnt= 14, str= Modem Blocked`),**同一秒** CP 断言
(`PS CP assert in file smsg.c line 168 exp=FALSE info=[], [dfs=6] from modem!`)、SIPA 数据面拆掉
(`PROD` 0→2→0)、AT 通道全哑。`run_state` **始终是 1** ⇒ modem_control 根本没复位 CP,读完就回去等。
之后 `modem-ioctl stop/start`(cp-reset.sh dry,run_state 1→0→1)**也救不回来**,只有整机重启才行。
**是不是这条消息"引起"了断言并未证实**(本机本来就会自发断言),但两种可能下它都不该上自动路径
⇒ 只留作诊断。**副产品:`smsg.c line 168` 断言是 stop/start 治不了的**(和 08:06 那次 SIPA 假死同一结论),
`mobile-data` 的最后手段重启是唯一解 —— 这次它自己触发了,自愈链条是通的。

## 5. 与我们内核的对照(为什么"搬驱动"这条思路本身走不通)

- 安卓内核 = `5.4.254-android12-9-gd5a8ab235157`;我们自编 = `5.4.254-gb50db5b6224c`(同族不同 commit)。
- 安卓这套是**瘦内核 + 驱动全做模块**:`sipa`/`smsg`/`sprd_drm`/`wlan_combo`/`bq2560x` 在内核 Image 里
  **一处都没有**,它们都在 vendor_ramdisk 的 165 个 `.ko` 里。
- 所以"从 boot_a 里抠驱动"在方法上就错位了 —— 要抠也该去 vendor_boot;而 cptl 在**两处都没有**。

## 6. 复现命令(下次要查同一件事)

```sh
# 1) 只读抓取(设备)
dd if=/dev/block/by-name/boot_a of=/tmp/boot_a-ro.img bs=1M
# 2) 宿主解析(boot v4:内核在 4096,未压缩 arm64 Image)
python3 - <<'PY'
import struct; d=open('boot_a-ro.img','rb').read()
print(struct.unpack_from('<2I',d,8))            # (kernel_size, ramdisk_size)
print(d[4096+56:4096+64])                        # b'ARMd' ⇒ 未压缩,可直接 grep
PY
grep -abo cptl boot_a-kernel.Image | head        # 0 处
# 3) vendor_boot:vendor_ramdisk 在 page 1,lz4 legacy
lz4 -d -c vb-ramdisk.bin > vb-ramdisk.cpio && grep -abo cptl vb-ramdisk.cpio | head
```

## 7. 诚实边界

- **属性值没有读回来**:chroot 里的 `getprop` 跑不起来(安卓子集里没有 `/usr/bin/env`,动态链接器
  路径也不全),所以 §3 的值来自 **`prop.default` 原文**(那是"出厂默认值",不是"运行时现值")。
  键名与设备节点两者都在设备上核对过;值本身未经运行时验证。
- **`super` 里的逻辑分区没挂**:GPT 里没有 `vendor_a` —— 安卓 13 的 `/system`、`/vendor` 都在
  `super` 动态分区内。§2 里那份 150 个文件名的清单来自**安卓运行时对
  `/vendor/lib/modules -> /vendor_dlkm/lib/modules` 的 `ls` 记录**(`work/lastboot/dt/`),
  不是我这轮重新挂载得到的。
- **没有在安卓实机里 `ls /proc/cptl` 验证"不存在"**:那是靠两条独立证据推出来的
  (内核里没有该字符串 + 199 个已加载模块里没有能创建它的驱动),对"内核态不存在"是充分的,
  对"绝对不存在"仍属强推断。
- 我们自己的 142 个模块也 `grep` 过:`cptl`/`modemassert` **零命中**(与"厂商源码树里就没有"一致)。
