# 音频路径内核 oops(2026-10-16)——设备"自己关机"的真因

## 0. 一句话

2026-10-16 本地 23:28 设备失联**不是**断电、不是看门狗喂狗超时、不是 `mobile-data` 兜底重启,
而是**一次内核 oops**,故障进程是 **`arecord`**、故障点在 ALSA PCM 的 `snd_pcm_hw_params()`;
本机内核编了 `CONFIG_PANIC_ON_OOPS=y`(而且 `changxing60-linux/boot/init:85` 是我们自己在写
`echo 1 > /proc/sys/kernel/panic_on_oops`),oops 于是直接升级为 panic 并复位。
当时现场有我们自己的音频测试(`arecord` 与第二个 `aplay` 同时在 card 0 上开流),但 **2026-10-17 把机制查清后:
并发不是必要条件** —— 是 `sprd-dmaengine-pcm` 把 `runtime->dma_bytes` 写成"上层请求值",而 `hw:0,0` 的录音缓冲
其实是一块**固定 IRAM carve**(本机 `test_normal_cap_use_iram=0x1`,实测),core 拿请求值去 `memset` 就写穿映射(见 §3)。

> ⚠ 这条路径现在是**已知会把整机打重启**的:card 0 上**不要并发开两个 ALSA 客户端**;
> 而且**单个 `arecord` 走 `hw:0,0` 也不安全** —— 只要请求的 buffer 大于那块 carve。放音不受这条影响(机制里写清楚了)。

## 1. 时间线(本地时间 = 设备时间 + 5 h)

| 本地 | 设备 | 事件 | 证据 |
|---|---|---|---|
| 18:58:37 | 13:58:37 | mobile-data 触发 CP 复位 → 记录 "rebooting" | `/root/selfheal.log` 末条 |
| 18:58:58 | 13:58:58 | boot0.5 启动 | `/root/diag/00243s.log` |
| 19:49:51 | 14:49:51 | boot1 启动(**无日志解释这次的复位**) | `/root/diag/00249s.log` |
| 19:53 | 14:53 | boot1 载入 27 个音频模块 | `/root/audio-load.log` |
| 20:45 / 21:20 | 15:45 / 16:20 | boot1 内载 VBC profile、跑 voice-audio | `/root/vbc-load.log`、`/root/voice-audio.log` |
| **23:27:46** | 18:27:46 | 音频测试开始(单放两轮 + 第三轮并发) | 本次作业记录 |
| **23:28:02** | 18:28:02 | **内核 oops(arecord)→ panic → 复位** | pstore + uptime 两路反推一致 |
| 23:28:26 | 18:28:26 | 当前这次启动的内核起点 | `uptime 297.74` @ `18:33:24 +03` |
| 23:31 | 18:31 | OpenWrt 起来,音频 27 模块重载完 | `/root/audio-load.log` 18:31:49 |

oops 时刻算了两遍互证:boot1 起点 14:49:51 + `uptime 13091.03` = 18:28:02,
而 `dmesg-ramoops-0` 的 mtime **正好** `2026-10-16 18:28:02 +0300`。

## 2. 核心证据(归档件 `rescue/dumps/2026-10-16-audio-oops/dmesg-ramoops-0`)

```
<1>[13091.030973] Unable to handle kernel paging request at virtual address ffffffc013d8d000
<1>[13091.039758]   ESR = 0x96000047            # DFSC=0x07 = Translation fault, level 3; WnR=1 = 写
<1>[13091.047454] [ffffffc013d8d000] pgd=…e003, pud=…e003, pmd=…b003, pte=0000000000000000
<0>[13091.057662] Internal error: Oops: 96000047 [#1] PREEMPT SMP
<4>[13091.108115] CPU: 7 PID: 16866 Comm: arecord Tainted: G S  B   WC OE  5.4.254-gb50db5b6224c #3
<4>[13091.108125] pc : __memset+0x16c/0x188
<4>[13091.124557] lr : snd_pcm_hw_params+0x428/0x54c
<4>[13091.757121]  snd_pcm_common_ioctl+0x330/0xe3c
```

寄存器把"越界"这件事钉死了:`x0`(memset 目标)= `ffffffc013d8b000`、`x2`(长度)= `0x9fc0` = 40896,
而**故障地址 `x8` = `ffffffc013d8d000` = x0 + 0x2000** —— memset 走过了**恰好 2 个页**才踩空,
`pte=0`。**前 8192 字节是映射着的、之后不是**,说明该缓冲实际只有约 8 KiB,而 `dma_bytes` 声称 40896。

同一瞬间的另一路(CPU4 / PID 16868,即第二次 `aplay`):
```
[ASoC: PCM ] sprd_pcm_open FE_DAI_ID_MM_P Open Playback      # plughw:0,55
[Audio:MEM] audio_mem_alloc mem_type=5 addr = 0xaf725000, size=0x20000
[ASoC: PCM ] sprd_pcm_preallocate_dma_ddr32_buffer, buf->area(virt)=0xffffffc01381f000, size=131072
```
`FE_DAI_ID_MM_P` 就是 `/proc/asound/pcm` 里的 `00-55: FE_ST_MM_P`。

## 3. 机制(定位到源码行,但触发条件二选一)

ALSA core 在 `snd_pcm_hw_params()` 末尾有一段"清零缓冲区防内核信息泄漏"的 `memset`:

`kernel-src/zte-ums9620-kernel-5.4.254/sound/core/pcm_native.c:747`
```c
	/* clear the buffer for avoiding possible kernel info leaks */
	if (runtime->dma_area && !substream->ops->copy_user) {
		size_t size = runtime->dma_bytes;
		if (runtime->info & SNDRV_PCM_INFO_MMAP)
			size = PAGE_ALIGN(size);
		memset(runtime->dma_area, 0, size);      /* ← 崩在这里 */
	}
```

而厂商的 FE PCM 驱动把 `dma_bytes` 写成了 **"上层要多少"**,而不是 **"预分配缓冲真实有多大"**。

> **⚠ 2026-10-17 勘误(当事人不是我原先写的那个)**
> 本节原先归因给 `audio_driver/sprd_audio/saudio/saudio.c:543` 的 `saudio_pcm_lib_malloc_pages()`。**那份代码在这台机上不是当事者**:
> `saudio.ko` 虽然加载了(`/proc/modules` 那行是 `saudio 53248 0` ⇒ **引用计数 0**),但**从没 probe**:
> 而且会看错是有原因的 —— `saudio.ko` 是**我们自己编进镜像的**(`changxing60-linux/kernel/build-audio.sh:118` 的目录清单含 `sprd_audio/saudio`),
> 所以 `grep /proc/modules` 必然命中它。决定性证据是绑定关系:`/sys/bus/platform/drivers/saudio/` 里只有
> `bind`/`unbind`/`module`/`uevent` 四个文件、**一个设备都没绑**;反面对照 `/sys/bus/platform/drivers/sprd-pcm-audio/`
> **绑着 `sprd-pcm-audio` 与 `sprd-pcm-iis` 两个设备**,而 `sprd-dmaengine-pcm.c:1771` 的 driver `.name` 正是 `"sprd-pcm-audio"`。
> —— 设备 `/proc/device-tree` 里 `unisoc,saudio` 兼容节点零命中、`/sys/devices/platform/*saudio*` 不存在,`arch/arm64/boot/dts/sprd/` 里
> `unisoc,saudio` 只出现在 `sharkl3.dtsi`。它加载了却没绑到任何卡。
> 崩溃那次开的是 `hw:0,0` = `/proc/asound/pcm` 里的 `00-00: FE_ST_NORMAL_AP01`,这个 FE 的 ops 属于
> **`sprd_dmaengine_pcm`**(refcount 1,`snd_soc_sprd_card` 的依赖;源码就是我们编 audio ko 的那棵树,
> `tools/build-audio-54.sh:13` 写明 realme `kernel_modules/kernel5.4/audio_driver`,`tools/audio/test-built.sh:44` 含 `sprd-dmaengine-pcm`)。

真正的链条是这四段(路径均为 `kernel-src/realme-unisoc-5.4/kernel_modules/kernel5.4/audio_driver/sprd/…`):

1. **缓冲来自一块固定的 IRAM carve**,不是按请求分配:
   `platform/dmaengine_pcm/sprd-dmaengine-pcm.c` 的 `sprd_pcm_preallocate_dma_ddr32_buffer()` 里,
   `FE_DAI_ID_NORMAL_AP01` + `SNDRV_PCM_STREAM_CAPTURE` + `is_normal_cap_use_iram()` 三者同时成立时走
   `buf->addr = audio_mem_alloc(IRAM_NORMAL_C_DATA, &size)`(对照 `else` 分支才是 `DDR32`)。
2. **这条路默认开着,而且是本机的实测值**:
   `:64 static int test_normal_cap_use_iram = 1;` ⇒ `is_normal_cap_use_iram()` 返回它;设备上
   `cat /proc/asound/card0/sprd-dmaengine` → **`test_normal_cap_use_iram 0x1`**(读这个 proc 是安全的,写才改行为)。
   `FE_DAI_ID_NORMAL_AP01 = 0`(`platform/platform_routing/sprd-platform-pcm-routing.h:20`)⇒ 就是 `hw:0,0`。
3. **`dma_bytes` 被写成请求值**:`sprd_pcm_hw_params()` 的 `:1135 runtime->dma_bytes = totsize;`,
   `totsize = params_buffer_bytes(params)`(:1068)是上层要的字节数;而 `snd_pcm_hardware.buffer_bytes_max`
   是 `DEEPBUFFER_PLAYBACK_BUFFER_BYTES_MAX = 228 KiB`(:55/:158)—— advertised 远大于 carve,所以 ALSA 的约束不会拦。
4. 于是 §3 那段 core 的 `memset(dma_area, 0, PAGE_ALIGN(dma_bytes))` **线性写穿 vmap**:
   本文件 §2 量到的"前 8192 字节映射着、`dma_bytes` 声称 40896"正好是它的签名(fault 在基址 + 恰好 2 页、`pte=0`)。

即:**复用了固定 carve,却把 `dma_bytes` 改成请求值**;当"请求 > carve 实际"时 core 那次 memset 就写穿。
(若纯粹是并发 `vfree` 掉一整块缓冲,页表应整段清空、应当 fault 在 `x0` 而不是 `x0 + 0x2000`。这条反证仍然成立,而且现在有了更具体的机制。)

**不确定性收窄了,但没消除**:原先的 (B) "双客户端互相干扰"这一支**不再是解释的必要假设** ——
机制上单个 `arecord` 请求一个比 carve 大的 buffer 就足够炸。但"那一次到底是 (A) 尺寸不匹配、还是并发里第二个客户端
把 buffer 换成了别的 region"仍然没有受控复现证明过。carve 确切字节数**已于 2026-10-17 晚定案 = 7680 B**:
guard 补丁上机后的拒绝消息打出 `exceeds preallocated 7680`(驱动自己报的 `dma_buffer.bytes`),
与 DT `sprd,normal-captue-data` = `0x1e00` 互证(此前 "~8 KiB" 是从崩溃现场反推的)。
**结论(音频 oops 导致重启)不变;代码层修复也已同日落地,见 §7 第 4 条的收口。**

## 4. 为什么"console 里没有 Kernel panic 字样"不算反证

`oops_exit()` 的顺序决定了 console 快照**不可能**含 banner:
```c
void oops_exit(void) {
	do_oops_enter_exit();
	print_oops_end_marker();      /* 打 "---[ end trace … ]---" */
	kmsg_dump(KMSG_DUMP_OOPS);    /* console-ramoops 的快照取在这一刻 */
}
/* arch/arm64/kernel/traps.c: 紧接着才 */
	if (panic_on_oops) panic("Fatal exception");
```
实测 `panic_on_oops=1`、`panic=3`、`panic_on_warn=0`;build 配置
`sprd_qogirn6pro_defconfig:6202 CONFIG_PANIC_ON_OOPS=y`(原厂行为,仓库里没有脚本设它)。

## 5. 排除掉的候选

| 候选 | 判定 | 依据 |
|---|---|---|
| 音频路径 oops(`arecord`,在 `snd_pcm_hw_params` 的 memset) | **确认** | 调用栈 + `Comm: arecord` + 时刻秒级吻合 + `panic_on_oops=1` |
| PMIC 手按断电 | **排除** | 存在 oops 现场;且 `bootcause="Reboot into ap watchdog"` |
| `mobile-data` 兜底重启 | **排除** | 进程在跑,但 `selfheal.log` 在 18:58 之后一片空白(未触发) |
| CP/SIPA 楔死 + `cp-reset` 自愈 | **排除** | 同上;当前 `run_state: 1`。console 里的 `sipa_eth: fail to send, ret -115` 是背景噪声 |
| 看门狗**喂狗超时** | **排除** | `sprd_wdt_fiq` 每 8 s 一次一直到 `13087.88`,oops 在其后 **3.15 s** |
| "pstore 无 panic ⇒ 干净断电" | **不成立** | pstore **有** oops(见 §4) |

`bootcause` 是**按次生成**的(`/proc/cmdline`),仓库备份里同一字段出现过
`bootcause="Reboot into normal"`(`rescue/data-backup/data-local-tmp/dm_head.log:86`),
所以不是镜像里写死的串。`pwroffcause="device power down"` **不是**断电证据——那份普通启动的备份里也有。

## 6. 纪律(立刻生效)

1. **card 0 上绝不并发两个 ALSA 客户端**(仍然照做)。但 **2026-10-17 按 §3 的勘误补一句:并发不是这次崩溃的必要条件**——
   本次唯一与崩溃同秒的动作确实是 "后台 `arecord` + 同时 `aplay -D plughw:0,55`",而机制上**单个 `arecord` 在 `hw:0,0`
   把 buffer 要到比那块 IRAM carve 大就够炸**。**单跑** `aplay -D plughw:0,55` 与 `aplay -D plughw:0,0` 两轮 rc=0
   **不构成反证**:carve 那条分支要求 `stream == SNDRV_PCM_STREAM_CAPTURE`,**放音根本不走它**。
   (**2026-10-17 晚状态更新:"超限就炸"这条已由 guard 补丁堵死——现在超限得到 `-EINVAL`;但"别在 card 0 并发、
   别把 hw:0,0 当可用录音口"仍然照做,前者是卫生、后者是厂商约束根本没打算让这条路能用。**)
2. 设备 busybox **没有 `timeout`**、`sleep` 不收小数:包装命令要用宿主机侧的 `timeout`,
   否则 "根本没跑" 会被管道尾的 `$?=0` 读成 "跑过了"。
3. 想在真机上做音频验证,先想清楚**会不会开出第二个客户端**;声学回环(边放边录)天然是两路,
   在这台机器上**属于高危动作**,别默认当无损。**新增一条(§3 勘误的直接后果):录 `hw:0,0` 之前先 `cat
   /proc/asound/card0/sprd-dmaengine` 看 `test_normal_cap_use_iram`——是 `0x1` 就说明录音缓冲是那块固定 carve,
   那么 `buffer_time`/`period_time` 要的总字节必须留足余量(崩溃那次要的是 40896,而映射只有约 8192);
   读这个 proc 是安全的,写才改行为。**

## 7. 留档

`rescue/dumps/2026-10-16-audio-oops/`(从设备 `/sys/fs/pstore/` 原样读出,未写入未清理):
```
2007fc5d8ede20511cb0fac6e758753dc681fc4f683955a576d6bdd4ecd2721c  console-ramoops-0
af7c24d7dc9603185c40d2c6269f10998273a25b6388343ca01ffc7efc0efd9a  dmesg-ramoops-0
c448bdb61d4cce881b43a7e32c682052659dff88601132379bb8464e3937e892  pmsg-ramoops-0
```
**pstore 每个区域只保留一条记录**(只有 `-0`),下一次 oops 会顶掉这份现场 —— 所以先归档。

## 8. 两个未解之谜(诚实标注)

1. **本地 19:49:51 那次重启没有任何日志解释**:`mobile-data` 的 reboot 只解释了 18:58:58 那次启动;
   19:49:51 这次既无 selfheal 记录也无 panic 记录,**现场已被 18:28 的 oops 顶掉**。
   可疑但非结论:boot0.5 结束前 4m55s 有人跑过 VBC dump(`/root/changxing60-vbc-dump`,14:44:56),
   重启后 `vbc-load.log` 说 `audio_structure`/`dsp_vbc` "already loaded" —— **这条线也指向音频,但证据没了**。
2. **23:28:02 → 23:28:26 只隔 24 秒**:`panic=3` 后应立刻复位,24 s 更像 panic 路径里
   `sprd-sysdump` 落 minidump 的开销 + bootloader。所以**很可能是内核自己复位的**,但也不能排除
   人恰好手按。两种读法都不改变根因。

## 9. 下一步(尚未执行)

1. **补上缺失的证据通道(性价比最高)**:`bootcause` 就在 `/proc/cmdline` 且按次生成。
   在 `changxing60-post` 里**只追加**一行到持久文件(如 `/etc/changxing60/boot-history`):
   本 boot 的 `date`、`grep -o 'bootcause="[^"]*"' /proc/cmdline`、上一 boot 的结束时刻。
   这一行能同时回答"19:49 那次是什么"和"23:28 那次是不是 panic"。
2. **`bootdiag` 的采样窗口**:`MAXDUMPS=10`/`MAXUPTIME=900` 让崩溃前 3 小时是盲区。
   要覆盖"崩前一分钟"应改**环形**(保留每个 boot 最后 N 份),而不是"头 10 分钟"。
3. **若要定案 (A) vs (B)**:按 §3 勘误后,(B)"双客户端互相干扰"**已不是必要假设**,所以这条实验的价值降低了;
   还想要的话需要一次**受控**复现,且必须先征求用户同意(复现会顶掉当前唯一的 oops 现场;原始件已归档于 §7)。
4. **代码层**:原先写的 `saudio.c:558` **换人**——要审的是 `sprd-dmaengine-pcm.c:1135` 的
   `runtime->dma_bytes = totsize;`。同一形状的写法在 `saudio.c:543` 也确实存在,但那份代码在本机没有设备可绑、
   从没 probe(见 §3 勘误)。正确写法两种都一样:取预分配缓冲的真实大小(`dmab->bytes`/`buf->private_size`)或
   `min(size, 实际)`,并对超限请求返回 `-EINVAL`。这条**不需要设备**就能在源码上推进(改的是我们自己编的 ko)。
   **已落地(2026-10-17 晚,用户点头)**:`kernel/patches/audio-pcm-prealloc-guard.patch`(超限打 dmesg 一次并
   `return -EINVAL`,不改 ≤carve 的任何行为)进 `kernel/build-audio.sh` 注册表(排在 period-timer/pointer-agcp 之后),
   ko 上机重启装载,实测拒绝消息在 dmesg、内核存活、`-B` 超限从"炸整机"变成 `-22`。
   一个诚实的补充:**guard 不是"修好了 hw:0,0 录音"** —— 在 ≤7680 的尺寸上厂商驱动后续约束照样不让开
   (无 guard 消息、走到 DMA 配置才失败),这个 FE 本来就录不了;guard 修的是"录一下会把板子打重启"。
   同晚装载重启撞出的 boot X panic 与本补丁无关(是 S20 开机服务自己的 before-snap 读未加载的 turning0,
   vbc 驱动 NULL 解引用 ⇒ conflicts.md **E5/§10**,当天也用 marker 门修掉了)。

相关:[`telephony.md`](telephony.md)(音频/通话栈)、[`vbc-profile.md`](vbc-profile.md)、
[`amp-aw87xxx.md`](amp-aw87xxx.md)、[`watchers.md`](watchers.md)。
