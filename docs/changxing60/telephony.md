# 7552N:通话 / 音频 / 三键 移植(2026-10-16 勘查)

> **状态(2026-10-16)**:**全部为设备离线时的只读勘查**(DTB / Android 侧记录 / 上游源码),
> **尚无任何一条上机实测**。本文回答"打电话这件事在我们这台机器上到底可不可做、缺什么、
> 从哪里拿",并给出分阶段计划。**结论是:硬件齐全、驱动源码可拿到、DT 已描述完整 —— 比上游条件好得多;
> 但上游自己也没让音频真正流动起来,所以这一块仍是攻坚项,不是照抄就能成。**
>
> 关联:[`sms-port.md`](sms-port.md)(短信栈 + 通话控制面的通道冲突)、
> [`e5-linux.md`](e5-linux.md)(参照项目)、[`screen-plan.md`](screen-plan.md)(内屏)、
> [`cptl-and-boot.md`](cptl-and-boot.md)(安卓侧只读解剖)。
>
> **已落地的部分(2026-10-16)**:通话**网页拨号层**已在主机侧落地并测试通过
> (LuCI 拨号页 + rpcd ucode 后端 + 脱手拨号 job + 119+82 条主机断言)——即 §5 第 4 步的
> 网页一半,详见 §8。仍未上机:真调制解调器的 ATD/ATA 行为、**音频**(§6 的攻坚项)、
> 浏览器里的页面渲染。

## 0. 结论先行(六条)

1. **三个按键真实存在,而且安卓侧三个都在上报** —— 不是"只有一个电源键"。我们
   `tools/screen/changxing60-screen.c` 头部那句"the only key the board has"**是错的/过时的**,见 §1.1。
2. **音频硬件齐全**:AW87xxx 喇叭功放 + UMP9620 PMIC codec + VBC 语音引擎 + BT-SCO I2S,
   DT 的 routing 里 `Ext Spk/SPK Pin`(喇叭)与 `Ext Ear/EAR Pin`(听筒)都接着,见 §1.2/§1.3。
3. **设备有 `l_agdsp` 固件分区**(6 MiB,开机由 bootloader 载到 `0xafa00000`)——
   这正是上游缺、只能让用户自己提供的那块固件(他们的 F50 板子没有这个分区)。见 §1.4。
4. **音频驱动源码拿得到**:就是**我们已经在用的那棵 realme C51/C53 树**、**同一个 commit**
   (`4381465c…`),路径 `kernel_modules/kernel5.4/audio_driver`。见 §2。
5. **我们的 DT 把这些都描述好了**:`sound@0`(16 条 dai-link)、`unisoc,agdsp-access`、
   `audio-mem@af700000`+`audiodsp-mem@afa00000` 两块 reserved-memory、以及 5 个 `sprd,shmaddr-*` ——
   **上游因为自己板子没描述这两块内存而打的 `audio-mem-fixed-region.patch`,我们不需要**。见 §3。
6. **但必须诚实说清**:上游把驱动都载起来了、DSP 也能应答命令,**音频却始终没有真正流动**
   ("every scene takes exactly one buffer and then stops",其 FINDINGS §24)。我们条件更好(有固件分区、
   有喇叭),但这仍是**未验证的攻坚项**。见 §6。

## 1. 硬件盘点(证据都在本仓库里)

### 1.1 三个按键:DT 声明了,安卓也在上报

`work/dumps/live-fdt.dts:124-150` 的 `gpio-keys` 声明了**三个**键:

| 节点 | GPIO 控制器 | 线 | 极性 | code | 名字 |
|---|---|---|---|---|---|
| `key-power` | `phandle 0x6e` = `sprd,ump96xx-eic`/`sc27xx-eic`(PMIC EIC) | 1 | 1(低有效) | `0x74`=**116** | KEY_POWER |
| `key-volumeup` | 同上(PMIC EIC) | 4 | 0(高有效) | `0x73`=**115** | KEY_VOLUMEUP |
| `key-volumedown` | `phandle 0x0c` = `sprd,qogirn6pro-gpio`@`0x170000`(SoC GPIO) | 7 | 1(低有效) | `0x72`=**114** | KEY_VOLUMEDOWN |

**安卓实机的 `/proc/bus/input/devices` 记录**(`work/lastboot/dt/input-devices.txt`)证明三个**全在上报**
—— `gpio-keys`(event0)的 `B: KEY=1c000000000000 0` 解码出来正是 **114 / 115 / 116** 三个键:

```
key code 114 KEY_VOLUMEDOWN
key code 115 KEY_VOLUMEUP
key code 116 KEY_POWER
```

⇒ 三个键占同一个 `gpio-keys` 设备。**这直接推翻了 `changxing60-screen.c` 第 9-11 行那句
"the only key the board has"** —— 那句话大概来自某一轮只载了部分 gpio/pinctrl 驱动的启动。
(尚未在 OpenWrt 侧实测确认;见 §5 第 0 步。)

安卓侧同一份记录里还有:`sc27xx:vibrator`(event1)、
**`sprdphone-sc2730 Headset Jack`(event2)** 与 **`… Headset Keyboard`(event3)**
—— 后者说明**安卓那边 `sprdphone-sc2730` 这张声卡是活的**,且耳机插孔检测/线控都能用。

### 1.2 音频器件(DT 里逐个都在)

| 器件 | DT 节点 | 位置 |
|---|---|---|
| 喇叭功放 | `compatible = "awinic,aw87xxx_pa"` | `work/dumps/live-fdt.dts:1174` |
| PMIC 音频 codec | `compatible = "unisoc,ump9620-audio-codec"/"sprd,sc27xx-audio-codec"` | 同文件 `:3051` |
| 语音基带 codec | `compatible = "unisoc,qogirn6pro-vbc"` | 同文件 `:3915` |
| 蓝牙 SCO I2S | `sprd,dai_name = "i2s_bt_sco0"` | 同文件 `:884` |
| 声卡(机器驱动) | `sprd-audio-card,name = "sprdphone-sc2730"` | `work/factory.dts:5726` |

`work/factory.dts:5730` 的 routing 原文里,这两段说明**喇叭和听筒都是接好的**:

```
Ext Spk / SPK Pin        ← 喇叭
Ext Ear / EAR Pin        ← 听筒
HeadPhone Jack / HP Pin  ← 耳机
HPMIC Pin / HP Mic Jack、MIC Pin / Mic Jack、MIC2/MIC3 …   ← 麦克风(三路)
```

⇒ **与上游 MU300(F50)最本质的差别**:那块板子 ZTE 出厂就是"没有喇叭"的配置,
`changxing60-audio-dsp` 头部原话 "ZTE built this board without a speaker";**我们这台是带屏幕、带喇叭、
带听筒、带麦克风的真手机**。

### 1.3 声卡与 16 条 dai-link

`work/factory.dts:5726` 起:`sound@0` 下有 **`dai-link@0` … `dai-link@15`**(16 条),
`work/dtc-warn.txt` 里那 16 条 "node has a unit name, but no reg property" 警告就是它们。
`memory-region = <0xf5 0xf6>`(`factory.dts:5094`)与 5 个 `sprd,shmaddr-*`(`:5082-5086`):

```
sprd,shmaddr-aud-str     = <0xaf980e10 0x400>
sprd,shmaddr-dsp-vbc     = <0xaf981210 0x1400>   ← 上游 FINDINGS 引用的同一个地址
sprd,shmaddr-nxp         = <0xaf982610 0x400>
sprd,shmaddr-dsp-smartpa = <0xaf982a10 0x1000>
sprd,shmaddr-reg-dump    = <0xaf983a10 0x400>
```

### 1.4 AGDSP 固件分区(上游没有,我们有)

`work/logs-trial2/uboot_log.txt`(设备自己的启动日志)原文:

```
[00002745] load l_agdsp to addr 0xafa00000, size = 0x600000
[00002745] partition:l_agdsp,size:0x600000
[00002749] vboot_verify_info->img_name :l_agdsp.
[00002777] partion l_agdsp, verify_ret:0x0
[00002972] enter read_from_partition, partition_name = l_agdsp_a
```

⇒ 设备上有一个 **`l_agdsp_a` 分区**(6 MiB),每开机由 bootloader 校验并载到 `0xafa00000`。
上游 `changxing60-audio-dsp install` 那一整套"请你自备一个 AGDSP 镜像"的机制,
**在我们这里可以直接从自己设备上取**。

## 2. 驱动源码从哪来(与我们已有的 mali 完全同源)

上游 `kernel/build-audio.sh` 头部写得很清楚,并且**钉的就是我们已经在用的那个仓库和 commit**:

```
MODULES_REPO=https://github.com/realme-kernel-opensource/realme_C51_C53_Narzo-N53-AndroidT-kernel-source.git
MODULES_REV=4381465ccaf87fcf3215b9cd42f4a685df40e5e0
M=kernel_modules/kernel5.4
git sparse-checkout set $M/wcn/wlan/wlan_combo $M/wcn/bluetooth/driver $M/gpu/natt/mali $M/audio_driver
A=/src/ext-audio
```

—— 与我们的 `tools/build-mali-54.sh` **同一个仓库、同一个 commit**,只是多取一个 `audio_driver` 目录。
它给出三条"每条花了一个晚上"的坑(原话):

1. **顺序 + 要多遍**:`audio_sipc` 需要 `agdsp_access` 的符号、DAI 需要 platform、card 需要所有人;
   靠"反复编、把每轮产出的 `Module.symvers` 喂给下一轮"来解。
2. **失败后必须先清**:残留 `.o` 二次链接会报 `duplicate symbol: __this_module`,与真因无关。
3. **UMP9620 codec 只在 `BSP_KERNEL_DEFCONFIG=sprd_qogirn6pro_defconfig` 下能编** ——
   它的 Kbuild 把 `-DCONFIG_SND_SOC_UNISOC_CODEC_UMP9620` 藏在那个条件后面,
   否则报的是几百行以外一个 `TO_STRING` 隐式声明。**注意 `qogirn6pro` 正是我们的平台**。

它还说明有两个目录**永远编不过、也不该编**:`dmaengine_2stage_pcm` 与 `i2s`(给更老的
Unisoc SoC 用的,我们这代用 VBC v4)。

## 3. 我们比上游多出来的三点(少打三个补丁)

| | 上游 F50 | 我们 7552N |
|---|---|---|
| DT 描述音频内存 | **没有**,靠 `audio-mem-fixed-region.patch` 硬编码 | **有**:`audio-mem@af700000`(0x300000) + `audiodsp-mem@afa00000`(0x600000),正好等于上游硬编码的那两个值 ⇒ **该补丁不需要** |
| AGDSP 固件 | 设备上**没有**,要用户自备 | **`l_agdsp_a` 分区 6 MiB**,开机自动载入 |
| 喇叭/听筒/麦克风 | **没有**(ZTE 出厂即无喇叭) | **都有**(AW87xxx PA + 三路 MIC + 耳机孔) |

另:上游还有 `audio-mem-shm-shift.patch`(把 shm 绝对地址挪到另一个板子的镜像)与一条 MCDT 时钟
补丁(`mcdt_hw_r2p0` 的 enable 位没人置,它跳过所有寄存器写)—— **这两条是否要抄,取决于我们自己的
实测**,不预设。

## 4. 我们内核配置的现状(已查 `kernel/device.config`)

```
CONFIG_SND=y                              ← 有
CONFIG_SND_SOC=y                          ← 有
CONFIG_SND_SOC_GENERIC_DMAENGINE_PCM=y    ← 有
CONFIG_SND_SOC_COMPRESS=y                 ← 有
CONFIG_SND_SOC_TOPOLOGY=y                 ← 有
CONFIG_SPRD_DMA=m                         ← 有(上游说这是他们当初失败的全部原因)
# CONFIG_SND_SOC_SPRD is not set           ← ❌ 需要改成 =m
```

⇒ 框架全在,`SPRD_DMA` 已经是模块(上游当年 `/sys/class/dma` 是空的、`sprd-pcm-audio` 因为要不到
DMA 通道而 defer、最后 `snd_soc_register_card` 以 `failed to init link FE_NORMAL_AP01: -517` 放弃
—— 这一步我们已经天然跨过去了)。**唯一缺的是 `CONFIG_SND_SOC_SPRD=m` 及它的子项。**

## 5. 分阶段计划(依赖关系从上到下)

> **总闸**:设备离线,下面每一步的"实测"都做不了。但 1–3 步的**代码与构建可以现在就做完**。

**第 0 步(零风险,上机第一件事)**:`cat /proc/bus/input/devices` + `evtest`,确认 OpenWrt 侧
三个键是否都上报。若只有 KEY_POWER,则查 `gpio-sprd`/`sc27xx-eic`(pinctrl)驱动是否都载了 ——
**DT 是对的,缺的只可能是驱动**。这一步决定"三键设计"能不能做。

**第 1 步:AT 通道重构**(`sms-port.md` 的第 1/1b 步)。这是**所有通话/短信/状态功能的总前提** ——
现在的 `mobile-data` 独占 `/dev/stty_nr1`,而短信栈与通话控制都要这条通道。
做法:上 `changxing60-atd` 做唯一持有者,`mobile-data` 改走 `changxing60-at`;更彻底的是数据挪 `nr2`、命令留 `nr1`。

**第 2 步:音频驱动构建**(与 mali 同一套路,可纯主机完成)。
- 新增 `tools/build-audio-54.sh`(照 `build-mali-54.sh` 的形状):sparse clone 同仓库同 commit,
  取 `kernel_modules/kernel5.4/audio_driver` → volume `/src/ext-audio`;
- 打开 `CONFIG_SND_SOC_SPRD=m` 及子项;**注意 `# CONFIG_SND_SOC_SPRD is not set` 是我们 config 里
  仅有的拦路石**;
- 按上游那三条坑施工(多遍编译喂 symvers、先清后编、`sprd_qogirn6pro_defconfig`);
- 产出模块集 → `stage-modules.py` 硬根(像 mali 那样,编不出来就 exit 1,不许静默跳过)。

**第 3 步:移植上游音频用户态**(可直接 vendoring 的现成资产):
`changxing60-audio-dsp`(365 行)、`changxing60-audio`(init)、`kernel/build-audio.sh`、
`tools/vbc-profile`(从厂商参数 XML 生成 `/lib/firmware/{audio_structure,dsp_vbc,cvs}`)、
`tools/ctlset`(amixer 会把模式值钳掉,必须写完整 32 位)。
**改动点**:固件从我们自己的 `l_agdsp_a` 分区取(而非"让用户自备")。

**第 4 步(依赖 1+2+3):通话控制面 + 网页拨号**:
控制面就是 AT(`ATA`/`ATD`/`AT+CHUP`/`AT+CLCC`),没有新依赖。网页拨号照抄我们已有的
SMS 页面那套(rpcd ucode 后端 + 脱手 job + LuCI 页),把方法换成 `dial/answer/hangup/status`。
**→ 网页一半已完成并测试,见 §8;控制面本身(§5 第 1 步的 AT 通道重构)仍是前提。**

**第 5 步:内屏来电显示 + 三键接听/挂断**:扩展 `changxing60-screen.c`。
数据源是 AT 的 `RING`/`+CLIP` URC(用户名/号码)与 `+CLCC`。按键需要一套**上下文相关**的映射
(通话中来电时:某键接听、某键挂断;平时仍走现在的背光/音量),**电源键长按必须留给 PMIC 关机**
(现有代码已明确不许 shadow 它)。具体映射待定,见下。

**第 6 步(与上面并行,较独立)**:AT 状态页 —— 信号强度(`AT+CSQ`/`CESQ`)、频段、流量统计。
上游 `mu300dash` 有现成实现(另一个 agent 正在整理清单)。

## 6. 诚实边界(必须写清,别把"能建"当"能用")

- **本文全部是离线勘查**,没有任何一条在设备上验证过。
- **上游的音频从来没真正流动起来**。`changxing60-audio-dsp` 自己写着:驱动都载起来了、DSP 也会应答命令
  (`dsp_alive` 通过),但 **"every scene takes exactly one buffer and then stops"**(其 FINDINGS §24)。
  他们能跑通的是**语音 PCM 那一对路由**(`S_VOICE_PCM_P`/`S_VOICE_P_CODEC`/`S_VOICE_C_CODEC`,
  不经喇叭、直通 modem)——这恰好是"打电话"要的那条,但**他们也没验证它在真实通话里出声**。
- 我们"条件更好"(有固件分区、有喇叭、DT 完整)**只是把失败概率降低,不等于成功**。
  真正决定成败的是 DSP 参数文件(`audio_structure`/`dsp_vbc`/`cvs`)与我们这块板子的匹配度,
  而那需要上机试。
- `sprd-audio-card,dai-link@*` 里的 BE 链路(`BE_FAST_P_SMART_AMP` 等)在上游的板子上会对一个
  不存在的功放 defer 到天荒地老,上游用 `dummy_on_defer=1` 兜;**我们有 aw87xxx,链路是真的**,
  但这也意味着**我们的 dai-link 组合与上游不同,`dummy_on_defer` 该不该带要实测**。
- 按键映射、来电显示的具体交互设计**尚未定**,见下一节。

## 7. 设计决策(**2026-10-16 已定,用户拍板;下面是定稿与设备实测**)

> 这一节原来是"待定"。用户已经选定,设备侧也已按此实测(见本节末尾的实测记录)。

1. **三键在通话中的语义**(已定,已实测):
   - 来电振铃中:`音量上` = **接听**;
   - 通话中(含振铃中):`音量下` = **挂断**;
   - 平时:维持现状(电源键五档背光循环、音量键单步增减,带记忆);
   - 通话中按 `音量上`:不是接听(没什么可接的),**落回原本的背光步进**;
   - **电源键长按仍是 PMIC 关机**,屏里故意不碰长按。

   实现位置:`tools/screen/changxing60-screen.c` 的 `handle_key()`——通话相关分支
   排在"按键唤醒背光"分支**之前**(接听那一按必须就是接听,而不是"把屏点亮"),
   其余落回原有背光逻辑。判据是 `/run/changxing60-voice/state` 里的 `state=`:
   只有 `ringing` 时 `音量上` 才等于接听。

   **设备实测(2026-10-16,`CHANGXING60_SCREEN_DRYRUN=1` + `keyinject`,七次按键)**:

   | 按键 | 通话状态 | 期望 | 实测 |
   |---|---|---|---|
   | 音量上(115) | ringing | 接听 | `dry run: changxing60-voice answer`,背光 75→75 ✅ |
   | 音量下(114) | ringing | 挂断 | `dry run: ... hangup`,背光不动 ✅ |
   | 音量上(115) | active | 不接听,落回背光 | 只有 `backlight 100%`,无 voice 命令 ✅ |
   | 音量下(114) | active | 挂断 | `dry run: ... hangup` ✅ |
   | 音量上(115) | idle | 只调背光 | `backlight 100%`(已在顶档) ✅ |
   | 音量下(114) | idle | 只调背光 | `backlight 75%` ✅ |
   | 电源(116) | idle | 只调背光 | `backlight 50%` ✅ |

   真机 `gpio-keys`(event0)的位图是 `KEY=1c000000000000` = bit 114/115/116,
   与注入器发的三个键码**完全一致**——所以上表的结论就是真按键的结论。

   **顺带修掉一个真 bug**:`input_scan()` 原来只加不减,设备节点消失再出现(注入器就是
   这样,任何驱动 rebind 也一样)会永远打不开——那个槽位留着一个死 fd,按键发给没人读的
   设备,而且 `select()` 会一直把它报成可读,空转到 100% CPU。现在 `read()` 拿到 `ENODEV`
   就把该设备丢掉(`input_drop()`),下一拍重扫就能重新打开。修完实测:连按四个注入器
   设备全部被处理,5 秒 CPU 时间只涨 5 tick(死 fd 空转会是 ~500)。

2. **USB 口的定位**:现在 `br-lan`(192.168.77.1)是**管理口**,故意不发网关/DNS
   (否则 Windows 上 USB 网卡的默认路由会压过真出口,把电脑弄断网,见 `README.md`)。
   "USB 网络共享"(让电脑经这台手机上网)是**另一个语义**,需要单独设计(例如另开一个接口/网段,
   或加一个显式开关),否则会复现那个"电脑断网"的坑。
   **用户已定:保留管理口语义,另外加一个可切换的共享模式** —— 见 `docs/changxing60/usb-mode.md`。

## 8. 网页拨号:已完成并测试的部分(2026-10-16,主机侧)

> 这就是第 4 步的网页一半。全部主机侧完成,**没有一条上机验证过**;下面先说建了什么,
> 再说哪些只能在设备上验证。

### 8.1 建了什么

涉及文件(都在 `changxing60-linux/` 下;`rootfs/overlay` 里已有的 `changxing60-voice`/`changxing60-voiced`
/`voice.sh` 未改动,后端只是壳):

| 文件 | 作用 |
|---|---|
| `openwrt/overlay/www/luci-static/resources/view/changxing60voice/voice.js` | 页面(自包含,风格对齐 `changxing60sms/sms.js`,鼠标+键盘可用) |
| `openwrt/overlay/usr/share/rpcd/ucode/changxing60voice.uc` | 后端,12 个方法,壳到 `changxing60-voice` |
| `openwrt/overlay/opt/changxing60/bin/changxing60-voice-job` | 脱手拨号的另一半(`claim/start/run/state/reply`,仿 `changxing60-sms-job`) |
| `openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60voice.json` | 读写 ACL(`state/dialjob/log/contacts` 只读,其余需写权限) |
| `openwrt/overlay/usr/share/luci/menu.d/luci-app-changxing60voice.json` | 菜单项,路径 `changxing60voice/voice` |
| `tools/voice/fake-at` | 假 AT(测):应答 ATD/ATA/CHUP/VTS/CMUT/CLCC,环境变量控制延迟与失败 |
| `tools/voice/test-rpcd-voice.sh` | 测试入口:镜像内两阶段(rpcd-check 85 项 + rpcd-ubus-check 34 项) |
| `tools/voice/test-voice.sh`(已有) | CLI 82 项,未减弱,仍通过 |

**LuCI 页面** `voice.js` 的内容:

- 拨号盘(0-9 `*` `#`,长按 0 = `+`)、号码输入框、呼叫按钮;鼠标点击和键盘输入都能用;
- 通话中:计时、DTMF 拨号盘(0-9 `*` `#` A-D)、静音、挂断;
- 振铃时:醒目的接听/挂断两个大按钮;
- 顶部通话状态横幅,每秒轮询 `state`(**状态是 modem 说的,页面不能改**——拨号成功≠接通,
  是否真的在通话只有 `state` 有资格回答);
- 通话记录(来自 `log`)和联系人(来自 `contacts`),点击回填号码框;保存带名字的号码表单。

**rpcd 后端** `openwrt/overlay/usr/share/rpcd/ucode/changxing60voice.uc`,完全照抄 SMS 页面那套
(`changxing60sms.uc` / `changxing60-sms-job` / `test-rpcd.sh`),12 个方法:
`state` / `dial` / `dialjob` / `answer` / `hangup` / `dtmf` / `mute` / `log` / `logclear` /
`contacts` / `contact_add` / `contact_del`。

**拨号失败怎么办(为什么 dial 走 job、其他不走)**:

- **一切碰 modem 的调用都不能在一个 web 请求里同步完成**:rpcd 30 秒掐断请求,而
  `changxing60-at` 光等锁就可能等 90 秒(数据attach 每次占锁 10-20 秒),所以全部调用都是
  `setsid` 脱手,页面轮询。
- **dial 比其他多一层**(`openwrt/overlay/opt/changxing60/bin/changxing60-voice-job`,仿
  `changxing60-sms-job`):被 modem 拒绝的拨号会留下一个诚实的 idle 状态文件——和没按按钮之前
  一模一样——只盯 `state` 的页面会永远显示"拨号中"或什么都不显示。job 把 `changxing60-voice`
  打印的内容(modem 的 ERROR、锁超时)存下来,`dialjob` 交给页面。
- **answer/hangup/dtmf/mute 不走 job**:它们每一个都会在 state 里留下可见变化
  (振铃→通话中、忙→空闲),失败后"还在振铃"就是真相,页面如实说,而不是再做一个假装
  "第二意见"的文件。
- **卡死的 modem 显示为可见失败,不是无限转圈**:无响应/ERROR → `dialjob` 返回
  `{"error": "Dial failed", "detail": ...}`;锁忙 → `{"busy": 1}`;坏了的 job 安装
  (目录建不出来)→ 明确报错,不会误报成"modem 忙"。同一时间只允许一个拨号(job 的 claim 机制)。

### 8.2 测试(全部真实运行过)

- `tools/voice/test-rpcd-voice.sh`(新写,仿 `tools/sms/test-rpcd.sh`):两个阶段都在
  镜像 `changxing60-openwrt-base:25.12.5` 里跑——阶段1 用 `tools/sms/rpcd-harness.uc` 逐方法
  调后端(85 条断言),阶段2 装上真的 ubusd+rpcd 从 ubus 调(34 条断言),共 119 条全过。
  覆盖:每个方法的返回形状;越界请求(非数字序号、未知号码、空号码、带字母号码、超长号码、
  带 `|`/控制字符的名字);拨号/接听/挂断已脱手(6 秒延迟的 fake modem,请求 ≤4 秒返回);
  第二个并发拨号被拒;假 modem 无响应/ERROR/忙三种情况的可见失败;ACL 与菜单精确列出
  后端的 12 个方法。
- `tools/voice/test-voice.sh`(已存在的 CLI 测试,82 条断言)依然全过,没有减弱。
- `tools/voice/fake-at`(新):响应 ATD/ATA/CHUP/VTS/CMUT/CLIP/CLCC 的假 AT,用环境变量
  控制延迟和失败模式,把收到的命令写进文件供断言。

### 8.3 验证状态(2026-10-16 更新:控制面已上机实测,音频仍未通)

**已上机验证的**(设备侧,真实 ubus/HTTP 路径):

- 三个 rpcd 对象 `changxing60sms` / `changxing60usb` / `changxing60voice` 全部注册,
  `ubus -v list changxing60voice` 列出 12 个方法;ACL、menu、`voice.js` 均已部署;
- `state` / `contacts` / `dialjob` / `log` 读路径全部返回正确结构;
- **`dial` 的控制面端到端跑通了**:一次真实 `ATD` 被 modem 接受,
  `changxing60-voice-job` 起了 job,`dialjob` 回 `dialling ...`(号码打码),
  通话状态机走到 `out` 方向,挂断后落 `idle`,通话记录写下 `out|failed|<num>|0`,
  job 目录清干净,AT 通道事后 `AT+CLCC` 仍正常。
  > **诚实记录:这条是"意外"验到的。** 我在测号码长度边界时,把
  > `12345678901234567890`(20 位,语法合法)喂给了 `dial`,于是**真的发起了一次
  > 外呼**——那是个不存在的号码,modem 未接通(记录为 `failed`),我在 1–2 秒内
  > 挂断并复验状态回到 `idle`。没有人被叫到,但网络确实处理了一次呼叫尝试。
  > 教训:**`dial` 的参数校验测试不能用"语法合法"的号码**,要么用会被拒的,
  > 要么在假 AT 上做。`/etc/changxing60/call-log` 里因此留了一条测试记录,
  > 页面上的"清空记录"可以删掉它。

**仍未验证的(诚实边界)**:

- **音频**:控制面通了,**但通话没有声音**——VBC profile 还没人写,见 §9.8。
  控制面通了不等于能通话。
- **真机响铃/接听的 modem 行为**:`ATA`、来电 URC 时序、`+CLCC` 的完整语义
  还没有真实来电跑过(需要一个真打进来的电话)。
- **浏览器渲染**:页面通过了 JS 语法检查、也在真 HTTP 上取到了,但没在任何浏览器里
  打开过;轮询节奏、布局、键盘输入这些要人在真机上看。
- ~~部署~~ → 已部署(2026-10-16)。
- ~~三键接听/挂断与内屏来电显示~~ → 已实测,见 §7 第 1 条那张表。

## 9. 音频驱动移植(2026-10-16,W3 落地:驱动构建已通、声卡起来了、**用户态语音通路也已实测跑通**)

> 本节是 §5 第 2 步的完成记录 + §4 结论的一处**勘误**。状态:**28 个音频模块全部编译成功**,
> vermagic、modversions CRC、依赖闭包、depmod 四类主机侧检查全过(85 条断言);
> **尚未上机**(设备被别的 worker 占用,且音频上机本就排在 AT 通道重构之后)。

### 9.1 §4 的勘误:`CONFIG_SND_SOC_SPRD` 根本不用开

§4 说"唯一缺的是 `CONFIG_SND_SOC_SPRD=m` 及它的子项"——**错**。把 Android 的
`vendor_dlkm` 拉出来对过之后,结论反转:**Android 自己的 5.4 内核也是 `SND_SOC_SPRD=n`,
全套音频驱动都是树外模块**(`KO_MODULE_NAME` 那套 Kbuild,`make M=<dir> modules`),
由 `init.insmod.sh`/vendor init 从 `/vendor_dlkm/lib/modules` 装载。我们也不开,用同一条路。
所以**内核不用重编,不存在"改配置触发整机重build"的风险**。

### 9.2 Android 的音频模块在哪,为什么不能直接抄

两个位置,内容 diff 为空(逐文件比对过):

- **`vendor_boot_a` ramdisk** `/lib/modules/`(GKI 早启加载的 165 个 .ko 的一部分);
- **`vendor_dlkm_a` 分区**(`/vendor/lib/modules` 的真身),EROFS,`dd if=/dev/sda49
  skip=4997513216` 即得,解析脚本在 `changxing60-linux/work/audio/parse-super.py`
  (这台机器 LP 元数据 quirk:52 字节分区描述符/24 字节 extent)。

音频相关的共 **26 个**(`agdsp_access`、`audio_sipc`、`audio_mem`、`mcdt_hw_r2p0`、
`sprd_audcp_boot`、`sprd_audcp_dvfs`、`audio-dsp-dump`、`audio-pipe`、`sprd_apipe`、
`voice_trigger_irq`、`smartpa_stat`、`snd-soc-aw87xxx`、UMP9620 codec 三件套、
`snd-soc-sprd-{dai,vbc-v4,vbc-fe,card,dummy-codec,pdm-r2p0,tdm}`、`snd-soc-unisoc-dp-codec`、
`sprd-dmaengine-pcm`、`sprd-compr-2stage-dma`、`sprd-platform-pcm-routing`)。

**但它们不能直接 insmod 进我们的内核**,判据是 `modprobe --dump-modversions` 对
`out-linux/Module.symvers` 的逐符号比对(方法学用 mali 验证过:我们的 mali 重编 335/335 全中,
Android 原装 mali 166/335 对不上):

- vermagic 是 `5.4.254-android12-9-gd5a8ab235157`,我们是 `5.4.254-gb50db5b6224c`;
- 以 vbc-fe 为例,21 个 modversion 导入:7 个 CRC 不一致(含 `module_layout` 本身),
  10 个(全部 `mcdt_*`/`agdsp_access_*`)在我们的内核里**不存在**——它们是音频模块之间
  互相导出的符号,Android 上由同批模块自己提供,必须同内核重编。

⇒ **结论:必须从源码编**,而源码就是 §2 说的那棵 realme C51/C53 树的
`kernel_modules/kernel5.4/audio_driver`,与我们 mali 用的**同一仓库同一 commit**
(`4381465c…`,已按此 commit 落地构建)。

### 9.3 已落地的构建(`kernel/build-audio.sh` + `tools/build-audio-54.sh`)

形状同 `tools/build-mali-54.sh`:把 sparse checkout 挂进 `changxing60-kernel` 卷
(`/src/ext-audio`),在 `changxing60-kbuild-cross`(clang-12)里对 `/src/out-linux` 做树外
`modules` 编译,产出落 `work/audio-modules/` + `out-linux/`(让 `stage-modules.py` 看见)。
编译期三件套(BSP_KERNEL_DEFCONFIG=sprd_qogirn6pro_defconfig / 3 遍编译 / 失败先清 .o)
与 §2 引的上游经验一致,**本机构建 1 分 34 秒**。

产出 **28 个模块**:Android 26 个里的 24 个 + 2 个 Android 没有的
(`snd-soc-sprd-vaudio`、`snd-soc-sprd-pa-ucp1301`,DT 里没有对应节点,装载了也无害)+
2 个 Android 有但我们源码树里没有的(见 §9.5)。**补丁 5 个**,已 vendoring 进
`kernel/patches/audio-*.patch`(打点顺序要求:`audio-pcm-period-timer` 必须先于
`audio-pcm-pointer-agcp-access`,后者的 hunk#1 依赖前者的结构体字段):

| 补丁 | 作用 |
|---|---|
| `audio-mcdt-enable-clock` | MCDT 的 agcp 时钟使能位没人置时跳过所有寄存器写 |
| `audio-pcm-period-timer` | AGCP DMA 中断上不来,period 事件改 hrtimer |
| `audio-pcm-pointer-agcp-access` | AGCP 电源域睡着时不读 DMA 位置 |
| `audio-fe-dai-formats` | DSP 前端只报 DSP 支持的格式;补主机侧需要的 |
| `audio-sprd-card-dummy-on-defer` | 等不来的 codec 不许拖死整卡 |

**上游的 `audio-mem-fixed-region`/`audio-mem-shm-shift` 不打**(§3 的结论维持):
我们的 DT 有 `memory-region=<0xf5 0xf6>`(`audio-mem@af700000`+`audiodsp-mem@afa00000`)
与 5 个 `sprd,shmaddr-*`,`audio_mem.ko` 的字符串里确认它读的就是 `memory-region`/
`sprd,shmaddr-dsp-vbc` 这些属性。固件同理:**音频 .ko 里没有任何 `request_firmware` 文件名**
(AGDSP 固件由 bootloader 从 `l_agdsp_a` 分区载到 `0xafa00000`,不需要 /lib/firmware)。

### 9.4 主机侧验证全过(`tools/audio/test-built.sh --staged`,85 条断言)

1. **清单**:Android 26 个里 24 个已建,2 个 absent 且**有理由**(`smartpa_stat`、
   `snd-soc-aw87xxx`,§9.5);2 个 Extra 声明在案;
2. **vermagic**:28/28 = `5.4.254-gb50db5b6224c`(Android 预编译做不到的那条);
3. **CRC 闭包**:每个导入要么对上内核 `Module.symvers`,要么对上其他音频模块自己的导出,
   **0 失配 0 未解析**(Android 预编译是 7 失配 + 10 不存在);对每个模块自己的
   `Module.symvers` 再核一遍,导出方之间 0 分歧;
4. **depends 闭包**:每个 `depends=` 都能在 28 个模块 ∪ 内核 out-linux 的 .ko ∪ built-in
   里找到(`sipc-core`/`unisoc-mailbox`/`sprd_power_manager` 来自内核自身,已确认在编);
5. **装载顺序**:依赖图无环,depmod 对 staged 集合 `-e -E Module.symvers` 零告警;
6. **负测试**:坏一个 .ko → 23 项 fail、exit 1;坏一个 CRC → 被第 3 条抓到。
   (测试自己也被抓过一次 bug:期望清单先写成 27,被计数守卫拦下 ——守卫留着。)

### 9.5 喇叭功放 aw87xxx:源码**已找到、已编过**(2026-10-16 晚更新;详见 [`amp-aw87xxx.md`](amp-aw87xxx.md))

> 本节原先写"唯一在任何可得源码树中都找不到源码的"——**那条已作废**:源码找到了,而且
> **在 5.4.254 上编过了**(vermagic 逐字匹配、77 个 `cfi_jt`)。完整记录在
> [`amp-aw87xxx.md`](amp-aw87xxx.md),这里只留结论。

**源码**:`Enceka/kernel_sprd_ums9158` 的 `sound/soc/sprd/unisoc/codec/aw87xxx/`(14 个文件)。
判据是硬的:它的 `compatible = "awinic,aw87xxx_pa"` 与我们 DT 节点**逐字相同**,固件名
`aw87xxx_acf.bin` 也相同,导出符号集与 Android 预编译 `.ko` 完全一致。
我们已有的树(realme C51/C53、zte-ums9620)**确实都没有** —— 只有 `aw881xx`/`aw883xx`,另代芯片。
**芯片是 AW87390/AW87391,不是 AW87566**(从 `acf.bin` 里的 profile 名读出,推翻了早先按
Android `.ko` 产品表做的推断;驱动用寄存器 0x00 自动探测,所以对代码无影响)。

**编译/装载**:`tools/build-aw87xxx-54.sh` 一键重编(源码 pinned、vermagic 与 `cfi_jt` 双校验),
产物 `work/aw87xxx-modules/snd-soc-sprd-pa-aw87xxx.ko`,`depends:` 为空 —— 它不依赖任何 sprd 头文件。

**出声仍然受影响,而且原因和原先写的不完全一样**:加载驱动只是让 i2c 器件被认领
(现场实测 `/sys/bus/i2c/devices/6-0058/` 里 `modalias` 匹配、**但没有 `driver` 符号链接**,
即从来没有驱动绑过)。真正卡住的是机器卡 `sprd-asoc-card-utils-hook.c` 把 i2c-PA 那条路
包在 `#if 0` 里,而现在生效的那条(`extral-iic-pa = <2>`)会退回 GPIO 查找、死在
`gpio is invalid!`(我们 DT 没有 `sprd,spk-ext-pa-gpio`)。**所以"把 `#if 0` 打开"是错的**:
那段代码用 `kallsyms_lookup_name` 找 `aw87xxx_i2c_pa` / `aw87xxx_audio_scene_load`,两个符号
Android 预编译版和 E5 源码都没导出。修法是 E5 那条的形状:写 `hook_general_spk_for_aw87xxx()`
调**已导出**的 `aw87xxx_set_profile(0, "Music"/"Off")` 并跳过 GPIO 查找
(已核对 `"Music"`=id 0、`"Off"`=id 11 都是我们 `acf.bin` 里真实存在的 profile 名)。

**听筒/耳机/麦克风/BT-SCO 不经 aw87xxx,不受影响** —— 所以**通话音频本身不依赖这个功放**,
它卡的是外放/铃声/媒体。固件(`aw87xxx_acf.bin` 1888 B)与 DT 节点(`aw87xxx@58`)都在手里。

> **一句话:卡住"用喇叭听"的只剩机器卡那个钩子(还没写);驱动本身已经能编能装了。**
> 而"通话有没有声音"是另一条路(§9.8),不等这个钩子。

### 9.6 上机路径(2026-10-16 **已上机,声卡起来了**)

> **本节已从"计划"变成"记录"。** 27 个模块全部上机装载成功,`/proc/asound/cards` 出现
> `card 0: sprdphone-sc2730`,16 条 dai-link 全部 `mapping ok`,AGDSP 被唤醒,重启后自恢复。
> 下面第 1–3 条保留原样(它们仍是装载形状的依据),第 4 条起是实测结果与踩到的坑。

1. `stage-modules.py` 的 `ROOTFS_ROOTS` 已加音频硬根(6 个核心 + 逐个点名的叶子服务,
   共 27 个;`snd-soc-sprd-pa-ucp1301` 故意不 stage——板上没有 ucp1301 PA)。
   **注意一个结构性教训**:`depends=` 闭包**拉不动**"依赖了栈但没被栈依赖"的叶子
   (codec/boot/dump/saudio/tdm/pdm 都只被点名、不被依赖);Android 用 modules.load
   显式列表的原因即此,stage-modules 照抄了这个形状。
2. 装载顺序(依赖序,host 侧已算出):`agdsp_access, audio_mem, mcdt_hw_r2p0, saudio,
   snd-soc-sprd-card, …(leafs)…, audio_sipc, …, sprd-dmaengine-pcm, audio-dsp-dump,
   audio-pipe, snd-soc-sprd-dai, snd-soc-sprd-pdm-r2p0, snd-soc-sprd-vbc-v4,
   sprd-compr-2stage-dma, sprd_audcp_boot, sprd_audcp_dvfs, snd-soc-sprd-vbc-fe`。
3. 验收标准(到了设备侧才作数):`/proc/asound/cards` 出现 `sprdphone-sc2730`;
   `cat /proc/asound/card*/pcm*p/sub*/hw_params` 在 aplay 时有值;AGDSP 一路
   (`audcp_boot` 加载 + `audio_sipc` 与 DSP 的 smsg 通道)通;然后才是
   `changxing60-audio`/`ctlset`/`vbc-profile` 那套用户态(§5 第 3 步,还没有移植)。

4. **装载脚本已写并已上机**:`rootfs/overlay/opt/changxing60/bin/changxing60-audio-load`
   (+ `openwrt/overlay/etc/init.d/changxing60-audio`,START=20,在 `changxing60-voiced`
   (S21)之前、`changxing60-hw`(S12)之后)。它是**幂等**的(已在 `/proc/modules` 里的
   跳过;依赖没齐的留到下一趟),这正是 §9.7 那条"装载到一半重启"要求的形状。
   `--check` 只报不动手,`--verbose` 逐个点名;进度写 `/root/audio-load.log`,
   因为 console 钉在 ERR 以上,装载失败在 pstore 里一个字都看不到。

5. **踩到的坑(值得记,因为它伪装成"模块全坏")**:内核在 `/proc/modules` 里记的是模块
   自己的 `name` 字段,**连字符全部换成下划线**——文件叫 `snd-soc-sprd-card.ko`,
   内核里叫 `snd_soc_sprd_card`。第一版 `loaded()` 拿文件名去 grep,于是 27 个里
   "只有 10 个装上、17 个失败",而实际上**27 个全装上了**,那 17 条是 EEXIST
   (`busybox insmod` 会说 `File exists`;rootfs 的 `/sbin/insmod` 是 `kmodloader` 的软链,
   它对失败**一声不吭**,所以只看到一个空的错误串)。判据必须是 `/proc/modules` 里的
   下划线名,`tools/screen` 那类"用文件名找模块"的检查同理。

6. **`modinfo -F depends` 在设备上是空转的**:本 rootfs 的 `modinfo` 是 kmodloader 的,
   `-F` 不认识,一律吐空。所以设备侧真正撑住装载的是**脚本里那份写死的顺序**,
   `depends=` 自检只在 host 侧(`tools/audio/test-built.sh`)才算数——脚本里已注明。

7. **实测结果(2026-10-16,重启后复验)**:

   | 判据 | 结果 |
   |---|---|
   | `/proc/asound/cards` | `0 [sprdphonesc2730]: sprdphone-sc2730` ✅ |
   | 27 个模块 | 开机 S20 全部装载,`/root/audio-load.log` 记 `complete: 27 modules loaded` ✅ |
   | dai-link | 16 条全部 `mapping ok`(VBC/voice/BT/FM/dump/codec-test 全在) ✅ |
   | AGDSP | `agdsp_access_enable ... (wake up done)` ✅ |
   | 声卡 probe | `probe of sound@0 returned 1 after 485711 usecs` ✅ |
   | 重启自恢复 | 软重启后 boot_id 变化,声卡与 27 个模块照常起来 ✅ |
   | 耳机 | `input: sprdphone-sc2730 Headset Jack / Headset Keyboard` 注册 ✅ |
   | PCM | `00-05 FE_ST_VOICE`(play+cap)、`00-53 FE_ST_VOICE_PCM_P`、`00-09 FE_ST_VOICE_C`、`00-00 FE_ST_NORMAL_AP01`、`00-49 FE_ST_TEST_CODEC` 等 28 个节点 ✅ |
   | 控制面节点 | `/dev/vbc_turning0..3`、`/dev/audio_pipe_voice`、`/dev/audio_pipe_trigger_{rx,tx}`、`/dev/audio_dsp_{pcm,mem,call_info,log}`、`/dev/sipc_smsg` ✅ |

8. **加载时机是安全的**:`sprd_audcp_boot`(启 AGDSP)排在 S20,早于蜂窝 WAN 起来。
   实测重启后 WAN 照常(`sipa_eth0` 拿到 `100.38.21.247/8` + 默认路由,ping 通,
   0% 丢包),**没有**和 modem 抢 SIPC 的迹象。
   (查的时候别被 `+CSQ: 99,99` 骗到——这台 modem 的 `+CSQ` 恒回 99,信号要看
   `changxing60-net-status`:本次实测 NR band 28 / arfcn 152650 / rsrp −67.2 dBm。
   另外 WAN 的接口名是 **`sipa_eth0`**,不是 `wwan0`。)

### 9.7 与 §6 的诚实边界对账

- ~~本节所有结论都是**主机侧**的~~ → **2026-10-16 起,§9.6 第 7 条那张表是设备侧实测**。
  仍然诚实的部分:声卡**起来了**不等于**出声了**——"驱动在你的硬件上真的出声"是
  用户态那一步(§5 第 3 步:`changxing60-voice-audio`),它还没有,所以通话双方仍然
  听不见任何声音。见 §9.8。
- **装载到一半重启**已按 §9.7 的要求处理:装载脚本幂等(§9.6 第 4 条),实测重启复跑 rc=0。
- 一个没有补偿的风险:我们的内核编译走 ThinLTO(`module_layout` CRC 与 Android 不同
  正源于此),将来内核若重编,CRC 会整体漂移 ——**音频测试必须跟着内核一起重跑**,
  这正是把 CRC 检查留在 tools/audio/ 里的原因。

### 9.8 还差什么才能真的听见(2026-10-16 晚更新:**用户态那半已写好并实测**,诚实的下一步)

> **本节原标题是"要写的是 `changxing60-voice-audio`"——那已经过时。** 它现在**写好了、上机了、
> 37 条断言全过**(`tools/voice/test-voice-audio.sh`,2026-10-16 独立复跑确认)。下面是当前的真实状态。

**已经能证明的**(都在无通话状态下实测,`work/voice/` 留了 selftest 输出与前后 mixer 快照):

| 事 | 证据 |
|---|---|
| 卡上 e5 要的控件**一个不缺** | `selftest` 报 PASSED,**51 个控件与每个 enum 项都在**,卡 `sprdphone-sc2730`,共 319 个控件 |
| 语音 PCM 真的开起来了 | 两个 PCM `state: RUNNING`,`hw_params` 恰好 `S16_LE/1ch/8000/period 640/buffer 1280`,`appl_ptr: 1280`(**FORWARD 成功**) |
| AGDSP 真的在动 | dmesg 有 `vbc_dg_put VBC_DG_DAC1 l:24 r:24`,无 assert |
| 收尾是干净的 | `stop` 后 **319 个控件逐字节与开始时相同**(前后 dump diff,验了两次),无残留进程/文件 |
| 钩子接上了 | `changxing60-voiced` 在 S21 启用,`start`/`stop` 就是它调的形状 |

**三个只有实测才会知道的坑**(都是"看起来像代码坏了"的那种):

1. **`python3-light` 没有 `ctypes`** —— 第一次 selftest 直接 `ModuleNotFoundError` 死掉。
   已加 `python3-ctypes`(3.11→3.13.15-r1,带 `libffi`);`_thread`/`threading`/`fcntl`/`select` 本来就有。
2. **`amixer` 会静默截断 Select 词,raw ioctl 不会** —— 实测 `0x1C1C0005` 经 amixer 变成
   `0x0FFFFFFF`,而 raw ioctl 原样送进去。**所以蓝牙那几个模式(≥16)必须走 raw ioctl。**
   注意边界:手头/免提那几个词(`0x07070005`、`0x00000005`)**低于**声明的 max,amixer 也能过 ——
   一开始把这条说宽了,已按实测收窄,测试现在**两个方向都断言**。
3. **`SYS_IIS0` 在 IIS 时钟空闲时拒绝任何写入(EINVAL,每个值都拒)** —— 于是第一版守护进程
   **每次 stop 都记一条 "restoring the mixer on stop failed",而实际上恢复得完美无缺**。
   修法是跳过无变化的写(`stop` 现在在 `finally` 里关 mixer)。
   **副作用要记住:蓝牙那条路由按现在的写法根本推不动这个 mux。**

**还没证明的(别当成已完成)**:

- **模式号仍未证实。** 手头 `(0,2,4,5)` 峰值 917/817/5157/8173 —— 模式 2 略**低于**模式 0,不是单调升;
  免提 `(7,9,11,12)` 1631/2053/2584/32536 是升的;蓝牙平。**唯一的真测试是拿第二部手机打一次真实通话。**
- **没有任何声音被听见过。** 我听不到。**喇叭预期是哑的**——AW87xxx 功放驱动还差机器卡钩子
  (见 [`amp-aw87xxx.md`](amp-aw87xxx.md))。**但听筒不经过那个功放**,所以通话音频本身不依赖它。
- **`/dev/audio_pipe_voice` 监听线程从没收到过真消息** —— 只验过 start/关停。
- `VBC_VOLUME` 的档位映射与所有 `gain-ear-*` 默认值**都是 e5 的,未标定**。
- **蓝牙做不了**(mux 只读 + BT 源采样率读回 0)。

设备侧控制面(一直在,未变):

- `/dev/vbc_turning0..3`(char 479:0..3)——按 profile id 分四个 minor
  (`SND_VBC_PROFILE_AUDIO_STRUCTURE` / `_DSP` / `_NXP` / `_IVS_SMARTPA`),
  `write()` 就是装载 profile,`read()` 是回读;
- `/dev/audio_pipe_voice`、`/dev/audio_pipe_trigger_{rx,tx}`——语音通路的触发;
- `/dev/audio_dsp_call_info`——通话信息通道。

驱动侧源码在 `kernel-src/realme-unisoc-5.4/.../vbc/v4/vbc_dai/vbc-dai.c`。ABI 与 profile
数据的出处见 [`vbc-profile.md`](vbc-profile.md)。

**落库的工件**:`rootfs/overlay/opt/changxing60/bin/changxing60-voice-audio`(守护进程)、
`rootfs/overlay/etc/changxing60/voice-audio.conf`(标定模板,所有键都注释着)、
`tools/build-alsa.sh`(设备侧装/验那两个运行时依赖,**规范路径是 `build-rootfs.sh` 里的 `apk add` 那行**)、
`tools/voice/test-voice-audio.sh`(37 条端到端)。

### 9.9 profile 怎么拿到:**从设备自己回读**(2026-10-16 设备实测,工具已落库)

四个 profile 的**数据**在 OpenWrt rootfs 里没有、在我们手上的 vendor 镜像里没有、在任何分区转储里
也没有——所以没有"拷贝过来"这条路。但**内核手里有**:Android 每次开机都由它自己的 audio HAL 把
profile 写进 `/dev/vbc_turningN`,而同一个节点**可读**(`vbc_turning_profile_get`),读出来就是
`write()` 进去的那串字节。所以办法是:**让 Android 装载一次,然后回读**。

**已落库的工具**:`changxing60-linux/tools/voice/changxing60-vbc-dump`(POSIX sh,Android 与
OpenWrt 两边都能跑)。它在设备上逐个读 `/dev/vbc_turning0..3`,按 header 校验后存成
`<name>.bin`——**那就是要写回同一个节点的字节串**。

**ABI(读源码 + 设备实测)**:

| 节点 | id | 名字 | header 之后 |
|---|---|---|---|
| `turning0` | 0 | `audio_structure` | `num_mode × len_mode` 字节 |
| `turning1` | 1 | `dsp_vbc` | 同 |
| `turning2` | 2 | `cvs` | 同 |
| `turning3` | 3 | `dsp_smartamp` | 同 |

header 24 字节 = `magic[16]`(必须是 `"audio_profile"`)+ `u32 num_mode` + `u32 len_mode`。

**设备实测(2026-10-16,合成 profile 走完整来回)**:

- 写:把 424 字节(`num_mode=4,len_mode=100`)的合成 profile `dd` 进 `/dev/vbc_turning0`
  → 驱动日志 `vbc_turning_profile_loading, return 0` / `load eq from turning success`。
- 读:`changxing60-vbc-dump` 读出 **424 字节、md5 与写进去的逐字节相同**
  (`ec84c5d414982fe068cc5683a3d4d5aa`),正确报出 `num_mode=4 len_mode=100`,rc=0。
- 未装载的节点(turning1..3)报 `nothing loaded`,rc=1——**不是**节点坏了。

**三个坑,都实测踩过**:

1. **必须一次大读**。`dd bs=1 count=64` 是 64 次 1 字节读,每次 `profile_size=1 ≤ 24` 都落进
   驱动的"只给 header"分支,结果是 64 个 0,看起来跟"profile 全零"一模一样。用 `bs=262144 count=1`。
2. **本机 busybox 没有 `od`**。`od` 缺失在命令替换里是**静默空串**,不是报错——第一版工具因此
   在一个读得好好的 profile 上报 `cannot read num_mode`。已改用 `hexdump`(busybox 与 toybox 都有)。
3. **驱动返回的长度 ≠ 缓冲区长度**。`copy_to_user` 拷满请求长度(尾部是零),但 `read()` 只返回
   `24 + num_mode×len_mode`,而 `dd` 写的是 `read()` 的返回值——所以**文件本来就是对的长度**,
   header 用来**交叉校验**而不是裁剪;两者不符就丢弃。

**在 OpenWrt 上的现状**:四个节点都在(479:0..3),但 `data[id]` 全是 `NULL`——没人装载过,
`/lib/firmware/` 里也没有那四个名字(只有 WCN/BT/GNSS 的 blob)。这是**预期**的,不是故障。

**拿到 blob 的确切步骤 —— 2026-10-16 已执行完毕,而且没开安卓。** 关键发现是
**odm_a 分区是 EROFS,我们自己的 5.4 内核 `/proc/filesystems` 里就有 `erofs`**,直接
`mount -t erofs -o loop,ro /mnt/changxing60-disk/odm_a.img /tmp/odm` 就能读到
`/etc/audio_params/sprd/{audio_structure,dsp_vbc,cvs}.xml`(根元素名与驱动要的固件名逐字相同,
`audioparam_config.xml` 里写着 `CodeType="ump9620"`,就是这颗 codec)。于是走 **XML 路线**,
**一次安卓开机都不需要**——这很重要,因为来回一趟安卓正是会翻 misc slot 的操作。

```sh
# 主机侧:XML -> blob -> firmware/(build-rootfs.sh 会拷进 /lib/firmware)
tools/voice/make-vbc-profiles.sh
# 设备侧:写 /dev/vbc_turningN 并回读比对(init.d/changxing60-audio 在模块加载后自动调)
/opt/changxing60/bin/changxing60-vbc-load
```

**结果(真机逐字节验过)**:

| profile | num_mode | len_mode | 大小 | md5(写入 = 读回) |
|---|---|---|---|---|
| `audio_structure` | 67 | 730 | 48,934 | `238c36a07aef0a7cc097b1689c2cec6f` |
| `dsp_vbc` | 72 | 1732 | 124,728 | `bfe6097b66ed4dac3ba0d31ffe4c0265` |
| `cvs` | 67 | 828 | 55,500 | `76e6b2b32e2682becf8075898054c078` |

**回读路线(read-back)没有作废,但降级了**:它现在是两边对不上时的仲裁手段,不再是必经之路。
合成 profile 的来回验证(上面那张 424 字节的)仍然成立,`changxing60-vbc-dump` 仍然是设备侧
读 profile 的唯一工具——`changxing60-vbc-load` 就是调它来做校验的。

**又踩到一个坑(第四个)**:`dd` 的块大小**必须 ≥ blob 大小**。驱动把每一次 `write()` 当成一整份
profile 并在开头校验 magic,所以 `bs=65536` 会把 124,728 字节的 `dsp_vbc` 拆成两次写,第二次
没有 magic → `Invalid argument`。两份小的在同一个块大小下都正常,**只有 dsp_vbc 坏**——正是会被
误判成"blob 不对"的形状。loader 的块大小是按文件大小算的。

**为什么非回读校验不可**:驱动只看 magic,没有长度/校验和/版本号。当天用一个改了一字节的 cvs
实验,**驱动照样收下了**(内核里 md5 变成 `47d0f01f…`),是回读比对抓出来并重写的。

**诚实边界**:①三份 profile 的**装载与验证**已经做完(§9.5 的 ABI 与 §9.9 的结果);
②blob 与 XML 都是**这块板子的厂商固件**,`firmware/` 与 `work/` 都在 `.gitignore` 里,**不入库**;
③**还剩两步离线做不了**:Select 词要扫 mode 号(现在知道是 67/72/67,但哪个号对应哪个场景
只能真机试听),以及守护进程本身——它依赖 `libasound.so.2`,而本 rootfs 没有、feeds 也没有
(细节见 [`vbc-profile.md`](vbc-profile.md) §5);
④`aw87xxx` 喇叭功放**仍然没有源码**(§9.5),所以**喇叭**依旧不出声——能救的是听筒/耳机/麦克风那条路。
   *(此行已过时:§9.5 当天晚些时候就找到了源码并编过,见 [`amp-aw87xxx.md`](amp-aw87xxx.md);
   喇叭不出声的真实原因见下面 §10.4。)*

## 10. 2026-10-17 攻坚:三条"根因猜想"被实测打掉,通话音频按用户决定挂起

**结论先行。** 到 2026-10-17 07:4x 为止,`文档里所有单点根因猜想`全部被设备实测否掉:AGDSP 是活的、
CP 语音确实使能过、数字增益标度虽然算错但纠正到 0 dB 之后**耳朵仍然什么都听不见**。剩下唯一没排除的
是"模拟/换能器那半"。**用户 2026-10-17 裁定:这部分记录下来,暂时不再适配**,冻结版
[`state-2026-10-17.md`](state-2026-10-17.md) 的行为不变(本节只记录,没有任何改动上机)。

### 10.1 被否掉的猜想一:"AGDSP 里根本没有固件"

`/etc/init.d/changxing60-audio`(S20)只做两件事——装 27 个模块 + 灌三份 VBC profile,**没有** e5 那套
`stop → dd of=$BOOT/agdsp → start`。看起来像 smoking gun,实际上这台机不需要:

- **uboot 每开机就把镜像载好了**。本节 §1.4 早记录过启动日志
  `load l_agdsp to addr 0xafa00000, size = 0x600000` / `partition:l_agdsp` / `verify_ret:0x0`;
  现在 `/dev/block/by-name/l_agdsp_a → /dev/sda29`(共 76 个 by-name)也还在。
- `ldinfo` 解出来是 `name=agdsp addr=0xafa00000 room=6291456`(=0x600000),和 uboot 那句逐字节对得上。
- `status` 不是文本,是**三个 u32**:`core=7 sys=7 sleep=0`。e5 的注释说清了这为什么不算证据——
  *"一个已加载、健康、空闲的 DSP 也读 7,和从没启动的一模一样"*。**别再用文本方式读它**(我第一次就读成"空")。
- 真正的凭据在 dmesg:`[Audio:SIPC] aud_send_cmd out,cmd =9 id:10 ret-value:0,**repeat_count=1**`——
  这就是 e5 `dsp_alive()` 定义的"第一次就答上了"。`agdsp_access_enable … (wake up dsp) val = 0x20`
  在开流时反复出现。
- 设备上没有 `od`(busybox 精简),解结构要用 `python3 -c 'struct.unpack("<III", …)'`。

### 10.2 被否掉的猜想二:"CP 从没把语音接进 DSP"

`/dev/audio_pipe_voice` 是 **DSP 通知我们的单向监听通道**,不是控制口——**e5 也只 `os.read` 它,从不写**
(`e5-call-audio.py:631`)。我们的监听器工作正常,归档日志里
`cmd=0x35 channel=2` 一共 9 条,其中 **`CP voice enabled=True (mask=0x10)` 出现过两次**
(04:54:27、04:55:33)。所以 §state-2026-10-17 §6 里"`mask=0x0` = CP 说语音没使能"**不能再当全貌读**:
使能过,只是不稳/晚到(短通话里普遍是 `False`,长通话才有 `True`)。

顺带否掉的两个:`hw:0,5`(`FE_ST_VOICE`)**没有 DMA**——`get_dma_data_params` 返回 NULL,platform 打
`no dma` 之后流照样 rc=0 成功,所以日志里 `VOICE-RUNNING hw:0,5` **不证明任何数据在动**;
`DL/UL mute` 空闲时都是 `disable`(=`enable_disable_txt` 里 `disable` 才是**不静音**),不是我们把它锁住了。

### 10.3 数字增益标度:**当天先得出错误结论,又被厂商表推翻**(错因一并保留)

`amixer -c 0 cget` 直接给出了这颗 kcontrol 自己的音量律(numid 14/15/16/18):

```
min=0 max=127 | dBscale-min=-94.50dB, step=1.50dB, mute=1
0 = MUTE   1 = -94.5 dB   24 = -60.0 dB   34 = -45.0 dB   64 = 0.0 dB
```

**⚠ 这条律是装饰性的,不能拿它判定"24 是静音"。** 厂商 `audio_pga.xml`(2026-10-17 从 odm 落到
`work/audio/vendor-xml/`,见 §10.6)里 **`Handset/NB1`、`NB2`、`WB1`、`WB2`、`SWB1`、`FB1`、`VOIP1`
和全部 `Handsfree/*` 场景,`VBC DAC1 DG Set` 的 `volume0` 一律写 `0x18 = 24`,`VBC ADC2 DG Set`
一律 `0x18`;高音量档才是 `0x19`(听筒)/ `0x1a`(喇叭);音乐侧 `VBC DAC0 DG Set`
Handset `0x19`、Headset `0x1c`、**Handsfree `0x21 = 33`**。
**24 就是这块板子的标称值,不是接近静音的值。** 于是:

- ❌ 撤销:"我们从 e5 抄的 24 是 −60 dB,是静音根因之一"。**错**。
- ❌ 撤销:"把 `VBC DAC0 DG Set` 从 34 改成 64(0 dB)再听"——**那次听测本身是脏的**(见 §10.7 的 MDG),
  所以"顶到 0 dB 仍然全哑"**不能**当作"模拟/功放那一半坏了"的证据。
- ✅ 仍然成立的实测事实(值多少都算):`ADC_1 Gain ADC_1 Capture Volume` 空闲 `0`,而厂商每个通话场景写
  `0x07`(该控件 `0..7 / 3 dB 步进 / mute=0`,即 **+21 dB 满档**)——**上行比厂商少 21 dB,这一条是真的**。
- ❌ 撤销:"内核侧另有一套标度 `vbc_dai_dg_value_get()` 用 `100 + value/8`、`DG_MAX_GAIN 0x50 = 80` 是满值"。
  **这两个符号在整个工作区不存在** —— `grep -rn -e DG_MAX_GAIN -e dg_value` 在 `kernel-src/`、e5 参照、厂商 XML
  里**零命中**,命中的只有我自己今天写下的两处(本节旧版 + `tools/voice/tone-test.sh`)。它是 subagent
  报告里的一句话,我当时标了"未决"却又半采信进正文 —— §10.9 那个教训**同一天在我自己身上重演了一次**。
  源码里真实的情况是**内核完全不做换算**:`vbc_dg_put`(`vbc-dai.c:611-637`)把 u32 原样存进
  `vbc_codec->dg[id].dg_left/right`,再 `dsp_vbc_dg_set(id, val1, val2)` 原样打包
  `struct vbc_dg_para{vbc_startup_reload, dg_id, dg_left, dg_right}` 走
  `aud_send_cmd(AMSG_CH_VBC_CTL, SND_KCTL_TYPE_DG, …, SND_VBC_DSP_IO_KCTL_SET)`(`vbc-phy-v4.c:701-718`),
  上限只有 ALSA 那侧的 `DG_MAX_VAL = 0x7f`(7 bit)。旁证:`dsp_vbc.xml` blob 里
  `voice_dg_l/voice_dg_r` 也是 `bits="7"`、`val="0x18"`(我在 `odm-xml/dsp_vbc.xml:4106-4112` 查过)。
  **⇒ 数值单位是 AGDSP 闭源固件的事,源码层面无法确定,别再编一个公式出来。**
  但有一个可操作的推论:`dsp_vbc_dg_set` 无论 SIPC 成败都 **`return 0`** ——
  **`cset` 报成功只证明"发过",不证明 DSP 收了**。

同一颗卡上增益律**不统一**,别再顺手类推:`DAC Gain` 天花板只有 −13.5 dB,`EAR Gain` `mute=1`
而 `AO Gain` `mute=0`。`VBC_VOLUME` 报成 `min=0 max=-1` 是 `SOC_SINGLE_EXT(..., MAX_32_BIT, ...)`
在 `snd_ctl_elem_info` 里 `(int)(0xffffffff - 0)` 溢出成 −1(`sound/soc/soc-ops.c:181-202`),
**不是坏控件**:它的 put 真会 `dsp_vbc_set_volume(value)` 推给 DSP(`vbc-dai.c:3576-3590`)。
- ❌ 撤销:"空闲时返回 EPERM,**任何值都不行**"。源码给了一个不需要"空闲"参与的解释:
  `vbc_volume_put` 结尾是 **`return value;`**,而 `snd_ctl_elem_write`
  (`sound/core/control.c:915-918`)把**负返回值直接当 errno** —— 写 `0xffffffff`(就是开机回读到的那个值)
  时 `value` 作 int 是 −1 = **−EPERM**。也就是说**那次 EPERM 很可能就是我们把回读值原样写了回去**,
  而不是卡有状态门禁。当时并没有逐值试过(写 7 会走通是源码推论,**未实测**),留作续做时一条便宜的验证。

### 10.4 现在最像断点的地方,和唯一没做的免耳朵测量

- **上行(对方听不到)**:`ADC_1 Mixer MIC1PGA_1 Switch` 从来没被任何我们拥有的代码写过
  (`Mic Function` 只是 machine 层的 **DAPM pin**,`sprd-asoc-card-utils-legacy.c:105-129,495`,
  而 pin 通了不等于**路由开关**通了)。实测:写下去之后整条录音链**第一次全部 On**
  (MIC Pin/MICBIAS1/ADC_1 Mixer/Gain/Switch/CLK/ADie Digital ADCL Switch/Digital ADC In Sel/
  Digital ADCL Switch/ADC/ADC_IBIAS/ADC_VREF_BUF/Normal-Capture-AP01)。**但样本仍然没到 AP**:
  `arecord` 起来后 `state=RUNNING`、`hw_ptr=0 delay=0 avail=0`,随即
  `read error: I/O error`,WAV 只剩 44 字节头,**audio 驱动一条内核消息都没打**。
  这个"绿色但冻结"的形状和下行音乐**一模一样**,而 `VBC_MUX_ADC0_SOURCE`(空闲 `ADC_SOURCE_IIS`)、
  `VBC ADC0 DG Set 32,32`、`VBC_IIS_MST_SEL_1_TYPE=INTERNAL`、ADC0 的 IIS 端口轮询**都没能救它**。
- **下行/音乐(听不见)**:DAPM 全上电、profile 已灌、DSP 应答、`CP voice enabled=True` 出现过,仍然无声。
  **但"模拟/功放那一半是断点"这个结论还没成立**——2026-10-17 那次把 DG 顶到 64 的听测是**脏的**:
  同一个脚本往 `VBC DAC0 DSP MDG Set` 写了 `1024,1024`,而那颗控件的 **value[0] 是 mute 字段**
  (见 §10.7)。剩下没排除的才是功放/听筒本身(`amp-aw87xxx.md`:源码找到并编过,但**是否在 DT 里
  被正确 instantiate、使能脚接谁**仍未证实)。
- **免耳朵的下一步(未做)**:`VBC_DAC*_DP_EN` **不是**"通路使能",它是厂商的 **audio dump** 选择
  (`vbc-dai.c:7434`,且 `:5925` 只在 DSP log dump 场景打开),设成 1 会把流改道进诊断转储。
  反过来用:让 tone 走 dump,再把转储出来的样本读回来测 peak——**这能在不等耳朵的情况下判断
  "数字音频到底有没有走到 DAC 级"**。谁续做这件事,从这里开始最省。
- **另外两个还没做的判据**:①插**耳机**再测(`HeadPhone Function` 那条路不经过功放,能把
  "codec 坏了"和"功放/喇叭坏了"分开);②一通 **≥2 分钟**的真通话,同时采样计数器——只有长通话
  出现过 `CP voice enabled=True`。
- **今天残留的 mixer 状态**(重启即回 probe 默认):`VBC_IIS_MASTER_ENALBE=enable`、
  `VBC_IIS_MST_SEL_0_TYPE=VBC_MASTER_INTERNAL`、`VBC DAC0 DG Set 64,64`、`ADC0/ADC2 DG 0,0`、
  `ADC_1 Mixer MIC1PGA_1 Switch off`(mic-test 结尾按"as-found"还原)。
- **一次误判记录**:后台听测的 ssh 报 `Connection timed out`(rc=255),我以为设备掉了;
  重连后 `uptime=47270s`——**13.1 小时没重启过**,只是 NCM 链路瞬时不响应。失联 ≠ 重启。
- **一次工具缺陷**:`tone-test.sh` 的 `hw_ptr` 差分打印出 `-28160 bytes` 这类负数,是因为第二次采样
  时流已 `closed`(`status` 里没有 `hw_ptr` 行,awk 取空)。**那行数字作废,别拿它当"没消费 FIFO"的证据**;
  要测消费速率必须在流还开着的时候两次采样(`mic-test.sh` 的 `watch_stream()` 是这个写法)。

### 10.5 挂起清单(续做时从这里接)

1. 先做 10.4 的 dump 测量或耳机测试,把"codec/DSP 侧"与"功放/换能器侧"切开——**在不需要耳朵的前提下**。
   顺带做**唯一能一次定死 DG 数值单位的那个扫描**(始终没做):通话中钉住 `VBC_VOLUME` 与所有
   MDG/mute 不动,只把 `VBC DAC1 DG Set` 扫 `{1,24,64,127}`,逐档录下行幅度
   (`VBC_DAC*_DP_EN` 的 audio dump,或 `KCTL_GET` / ap-vbc proc 回读 DSP 侧寄存器)。
   一趟同时回答两件事:**dB/档是多少** + **写了到底落不落的进去**(§10.8 的 B 族说它发得出,
   但 `dsp_vbc_dg_set` 吞 SIPC 错、Profile Select 又会盖回来,这两条要靠这趟判)。
2. ~~把 DG 全族的值按 10.3 改成 64~~ —— **作废**,10.3 已被厂商表推翻(24 是标称值)。
   要补的是 `ADC_1 Gain ADC_1 Capture Volume = 0x07`(厂商每场景都是满档,我们现在留 0 = 少 21 dB)
   和 `ADC_1 Mixer MIC1PGA_1 Switch on`;两者都在 2026-10-17 改过又 `git checkout` 回退了
   (未验证不上机),原文在当时的 diff 里、结论在这节。
3. 取表这一步**已完成**(§10.6,`work/audio/vendor-xml/` 七份都在);**没做的是把表用起来** ——
   `changxing60-voice-audio` 的 `GAIN_DEFAULTS`(102)与 `MODES` 表仍是猜的,要按
   `audio_pga.xml` / `codec.xml` / `audio_structure.xml`(15 档 Q12 律,§10.6)重写,别再类推。
   ⚠ 记住厂商用户态**根本不写 `VBC DAC*/ADC* DG Set`**(只写 `OFFLOAD DG Set`,见 §10.7),
   所以照抄这些值时要清楚:我们是在**覆盖 blob**,不是在复刻安卓行为。
4. 三颗 dev-change(`VBC_CUSTM_DEV_CHANGE`/`VBC_SYSTEM_DEV_CHANGE`/`VBC_CUSTM_VOL_CHANGE`)和
   `VBC_DSP_VOICE_CAPTURE_TYPE`/`VOICE_PCM_PLAY_MODE` 空闲全在 `0`(`TYPE_INIT` /
   `VOICE_CAPTURE_DOWNLINK`),**厂商 HAL 每通电话都写它们**(`vbc-dai.c:2534-2660`),我们一个没写;
   其中 capture type 与 play mode 的 put **只写缓存不推 DSP**,必须在场景 startup 之前落
   (`vbc-dai.c:4296-4360`,打包点 `:6215-6216`)。
5. 二分实验(只停音频半: `chmod -x /opt/changxing60/bin/changxing60-voice-audio`)仍然欠着——
   它回答的是"接通 ~8 秒被拆线是不是我们造成的",和"没声音"是两个问题。
   ⚠ 绝不停 `changxing60-atd`:两个进程同读 `/dev/stty_nr1` 会把 modem 弄哑到重启。

### 10.6 厂商真值表已落地(2026-10-17;下面的数**都是我自己在文件里查过的**)

odm 的参数表第一次被完整取出,落在 `changxing60-linux/work/audio/vendor-xml/`(`work/` 在
`.gitignore` 里,**不入库**):`audio_pga.xml` `608ffda1a12070cbe41ddf24c10715e8`、
`codec.xml` `e5058d8e8d1d8521d7a23eee7114a95d`、`audio_structure.xml` `f8f551fae51f4d4d4662d342565cc71a`、
`audio_process.xml` `ec8ae756bc69a1bf1b6e713762f71f4f`、`audioparam_config.xml` `2ba946cac4723dcac1133f55d73b449c`、
`cvs.xml` `275e284a9d91a6601f3d0249a68567c7`、`dsp_vbc.xml` `2102ff51ae69e1aa67fc19c930092a2e`。
**取法注意:`odm_a` 没有 by-name 链接**(它在 `super` 动态分区里,只有 `vbmeta_odm_a → /dev/sda64`),
用的是 2026-10-16 已经躺在设备上的镜像 `/mnt/changxing60-disk/odm_a.img`(354 MiB),`mount -t erofs -o loop,ro` 只读挂。

`audio_pga.xml`(唯一一份直接写 **kcontrol 名字** `ctl="…"` 的表,值就是往控件里写的原始数)**只含 7 颗控件**:
`VBC ADC0/ADC2/ADC3/DAC0/DAC1/FM/ST DG Set`。模拟增益在 `codec.xml`,MDG 在 `dsp_vbc.xml`:

| 场景 | `VBC DAC1 DG Set` | `VBC ADC2 DG Set` | `VBC DAC0 DG Set`(音乐) |
|---|---|---|---|
| `Handset/NB1`、`WB1`、`VOIP1` | `0x18`=**24**(高档 `0x19`=25) | **24** | Handset `0x19`=25 |
| `Handset/NB2`、`WB2`、`SWB1`、`FB1` | 全程 `0x18` | 24 | Headset/Headfree `0x1c`=28 |
| `Handsfree/NB1`、`WB1` | **24**(高档 `0x1a`=26) | 24 | **Handsfree `0x21`=33** |
| `Handsfree/VOIP1` | 24(高档 25) | 24 | TypeC_Digital `0x19` |

`codec.xml`:`adc1/adc2/adc3/adcv_capture_volume` 在 `Handset/NB1` **和** `Handsfree/NB1` 都是 **`0x07`**
——这颗控件 `0..7 / 3 dB / mute=0`,所以厂商是 **+21 dB 满档**,我们空闲实测 `0`。
`audio_structure.xml`:音量律是**每场景 15 档**(`max_volume=0x0f`,`dl_dgain_volume1..15`,**Q12,unity=0x1000**);
`Handset/NB1` = `0xcd,0x102,0x145,0x1cc,0x243,0x2d8,0x395,0x65f,0xa18,0x1000×6`,第 7 档 = −13.0 dB。
⇒ 监视器的 `VOLUME_CURVE_OFFSET=0x244 / 7 条目` **不是这张表**(它把 audio_structure 的字节当曲线读),
`VBC_VOLUME` 写 7 只到 −13 dB 档;这两处要按 15 档重做才能谈校准。

### 10.7 新头号嫌疑:`VBC * DSP MDG Set` 的 value[0] 是 **mute 字段**

`vbc_mdg_put` 自己的调试行就把语义写死了(`vbc-dai.c:486-504`):
`"%s %s mute:%02d, step:%02d"` —— `value[0] → mdg[id].mdg_mute`,`value[1] → mdg_step`,
两者一起 `dsp_vbc_mdg_set(id, val1, val2)`。厂商 `dsp_vbc.xml` 是
`*_mtdg_ctl=0x1, *_mtdg_en_l/r=0x1, **_mtdg_step=0x8`。对照我们写的:

- `ROUTES` 里 `'VBC DAC1 DSP MDG Set': '1,1024'`(从 e5 抄):step 是厂商的 **128 倍**;
- `apply_volume()` 在没静音时写 `'0,1024'`(=mute 0,勉强对),静音时写 `'1,1024'`;
- `tools/voice/tone-test.sh` 写 `VBC DAC0 DSP MDG Set 1024,1024` —— **往 mute 字段塞了非零值**。

⇒ 今天那次"DG 顶到 0 dB 仍然全哑"的听测**是被脚本自己静音的**,不能定模拟侧的罪。
⇒ 续做时第一个要控制的变量就是这颗:要么**按厂商根本不写**(profile 已带 `en=1, step=8`),
要么显式写 `(1,8)`;然后才谈得上重跑听测。

**厂商侧的独立印证(2026-10-17 晚,`/tmp/vend-x` = `work/audio/vendor.img` 只读解出)**:
安卓 HAL 的 `etc/audio_config.xml:24-27` 把这四颗控件的名字就叫
`dsp_da0_mdg_mute / dsp_da1_mdg_mute / audio_mdg_mute / audio_mdg23_mute`,
`ctl=` 分别指向 `VBC DAC0/DAC1 DSP MDG Set`、`VBC DAC0 AUD MDG Set`、`VBC DAC0 AUD23 MDG Set` ——
**厂商自己就把 MDG 当"静音开关"用**,和 `vbc_mdg_put` 的 `mute:%02d` 调试串两条独立证据对上。
step 字段是 **13 bit**(`MDG_STP_MAX_VAL 0x1fff`),blob 里 `voice_dsp_mtdg_step bits="13" val="0x8"`
(`odm-xml/dsp_vbc.xml:4094`),所以 `1024` 合法但**没有任何"1024 = 满量程"的依据** ——
`tools/voice/tone-test.sh` 旧注释里那句"MDG 是 Q10,1024 = unity"**同样撤销**,它是推的,不是查的。

### 10.8 参数生效时机:分两族(旧说法过宽,已按源码改窄)

`aud_stream_start` 确实收 **`u8 startup_param[680]`(按值的数组)**,但**不是所有控件都在这个包里**。
逐行读 `struct snd_pcm_startup_paras`(`vbc-phy-v4.h:1321-1345`)与 `fill_dsp_startup_data`
(`vbc-dai.c:6086-6217`)分出的两族:

- **A 族 = 被 STARTUP 带走的**(起跑后再写等于没写,只有 restart 生效):
  `mdg_para[]`(mute + step)、`smthdg`、`mixerdg` + `mixerdg_step`、`mixer_para[]`、
  `adc_source` / `dac_out` / `mux_tx` / `mux_rx` / `iis_do` / `mst_sel_para` / `iis_master_para`、
  `loopback_para`、`sbcenc_para`、`ivs_smtpa`、`voice_record_type`。
  **我们 `ROUTES` 表里的东西几乎全在这一族** ⇒ "改了参数要重拨一通才变"这个观察是真的。
  (reload 位:`get_startup_mdg/smthdg/mixerdg/mixer_reload()` 恒 0,**只有
  `get_startup_master_reload()` 返回 1**(`vbc-dai.c:6009-6084`)——这两个数在闭源固件里的含义未确定。)
- **B 族 = 只有实时推送、STARTUP 里没有的**:`VBC *DG Set`(结构体里**根本没有 dg 成员**,
  我从头到尾看过)、`VBC_UL_MUTE` / `VBC_DL_MUTE`(`dsp_call_mute_set` 全树**只有一个调用点**,
  在 `vbc_call_mute_put:2216`)、`VBC_VOLUME`。
  ⇒ **通话进行中写这些是真发得出去的**,e5"每次场景起来后再补一次 mute"的写法有道理;
  反过来说,"当时改 DG 听不出变化"**不能全推给顺序**,得看 A/B 两族与下一条的覆盖。
- **两条写者并存、内核不对账**:`/dev/vbc_turningN` 只校验魔数 + 缓存(`:2949-2996`),
  真下发在 **Profile Select**(`vbc_profile_put:3491-3527 → try_apply:2915-2940 →
  aud_send_block_param(…, SND_VBC_DSP_IO_SHAREMEM_SET)`);kcontrol 走 `SND_VBC_DSP_IO_KCTL_SET`。
  同一个 DSP 寄存器**后写者赢** ⇒ 一次 Profile Select 会把 blob 的 `0x18` 盖回我们写的 DG 上。
- 还有 §10.3 记的那条:`dsp_vbc_dg_set` / `dsp_call_mute_set` / `dsp_vbc_set_volume` **一律 `return 0`**,
  SIPC 失败只 `pr_err` ⇒ **`cset` 成功只证明发过,不证明 DSP 收了**。
  "写完立刻读回一样"更不是证据:读回的是内核缓存(`vbc_dg_get` 直接回 `vbc_codec->dg[id]`)。

### 10.9 一条流程教训(不是设备事实,但会再犯)

本轮一个子 agent 的**中间报告**引用了 `e5-call-audio.py` 的一段 docstring,内容是"e5 自己也承认通话是
静音的、ROUTES 增益是错的但无所谓"。**那段话在本仓库不存在**(`grep -rn "REAL BUG\|audio is silent anyway"
work/e5-ref docs` 零命中),同一份报告里的 dB 换算还自相矛盾(把 `20·log₁₀(0.5)=−6 dB` 写成 −20 dB)。
该结论已弃用;它**最终版**报告的场景表/控件名/数值我逐条回文件抽查过(§10.6 就是抽查结果,含一处
它没验到的 `Music/Handsfree = 0x21`),只有抽查通过的部分入库。
**外部结论一律回原文抽查再入库**,尤其当它正好支持当前假设时。

同一天晚上这条教训**在我自己身上重演了一次**,而且更该记:当晚厂商源码审计回来说"内核里不存在
`DG_MAX_GAIN`/`dg_value`",我一开始的反应是怀疑它——但 `grep -rn -e DG_MAX_GAIN -e dg_value kernel-src/`
**确实零命中**,命中的只有我自己当天下午写进 §10.3 和 `tools/voice/tone-test.sh` 的那两句。
那句话来自另一个子 agent 的报告,我当时判它"未决",却还是把公式抄进了正文和工具注释。
⇒ **判据不是"我怀疑过它",而是"我搜过没有"**;一句没搜过的公式写进工具脚本,毒害面比写进文档还大,
因为下一个人会当它是设备事实直接照抄。**入库前先 `grep` 自己引用的那个符号。**
