# 7552N:VBC profile 的 ABI 与数据来源(2026-10-16 勘查)

> **状态(2026-10-16)**:驱动侧全部结论来自**本仓库厂商源码逐行阅读**(带 file:line);
> 安卓侧结论来自**对 `audio.primary.whale.so` 的反汇编**(capstone,PLT/GOT 全部解析)。
> **设备侧已实测的部分**:read-back 路径(§3.3)已在我们的 OpenWrt 上真机验证。
> **§3.5 是当天的结果:三份 profile 已经做出来了,而且逐字节验过** —— 走的是来源 B(XML),
> **不需要开安卓**(odm_a 是 EROFS,我们自己的内核就能挂),产出的 blob 写进
> `/dev/vbc_turning0/1/2` 再读回来 **md5 完全相同**。来源 A(read-back)因此降级为"对不上时的
> 仲裁手段",不再是必经之路。落盘工具:`tools/voice/make-vbc-profiles.sh`(主机侧)、
> `rootfs/overlay/opt/changxing60/bin/changxing60-vbc-load`(设备侧)、转换器
> `tools/voice/vbc-profile.py`(vendored)。
> 本文是 [`telephony.md`](telephony.md) §9.8 指名的 ABI 参考文档,为 `changxing60-voice-audio`
> (用户态语音守护)服务。
>
> 关联:[`telephony.md`](telephony.md)(总计划,§5 第 3 步/§9)、
> [`e5-linux.md`](e5-linux.md)(参照项目——**有一套已实机跑通的完整实现可抄**)。

## 0. 结论先行

1. **可移植,而且有人已经走通过一遍。** 参照项目 e5-linux(VIPME M8 板,与我们同为
   UMS9620/qogirn6pro)有一整套现场验证过的实现:XML→blob 转换器、提取脚本、
   语音守护(PCM 打开/路由/profile 选词/事件处理),全部在本地 checkout
   `/tmp/e5-linux/`(永久位置见 [`e5-linux.md`](e5-linux.md) §1)。我们要做的不是发明 ABI,
   而是把它的数据源换成我们这台机器自己的。

2. **`/dev/vbc_turningN` 的 ABI 极简单,无校验和**:24 字节头
   (`"audio_profile"` 16 字节 NUL 填充 + LE u32 `num_mode` + LE u32 `len_mode`)
   后跟 `num_mode × len_mode` 字节的数据。写 = 整块装载,读 = 整块回读。
   minor 0..3 = profile 0..3(audio_structure / dsp_v / cvs / dsp_smartamp)。

3. **profile 数据的来源已经查明,而且两条路都不用开安卓**(2026-10-16 更新):
   本机 Android 的 HAL 会把四份 profile 装进内核(§4 证实);内核把它们原样缓存在
   `hdr[]`/`data[]` 里,**read-back 接口能原样吐出来**(§3.3;设备侧已实测该路径存在)。
   ⇒ 原本的首选路线是"回到 Android 让它装好,再对 `/dev/vbc_turning0..3` 各做一次大块 read"。
   **但当天发现 odm_a 分区是 EROFS,而我们自己的内核就能挂它**(§3.5)——于是 XML 路线
   (来源 B)不再需要安卓启动,变成了成本更低的那条,**而且已经做完并逐字节验证**。
   read-back(来源 A)保留为仲裁手段:两边对不上时以它为准(它是 DSP 真正吃过的版本)。

4. **语音路径的完整清单**(§5):一份 `/lib/firmware` blob + 打开 FE_STVOICE 双向
   (hostless,无 DMA 数据)+ 一串路由/增益控制 + profile Select 词 + 监听
   `/dev/audiopipe_voice` 的 20 字节事件。每一步的参数都从 e5 的实机代码里抄,
   唯一要换成我们的值的只有 Select 词里的 mode 编号(那是每台机器参数表里的布局)。

5. **最大的不确定**仍是参数表的内容本身:我们拿到的 blob 是不是这台机器音频参数的
   正确版本(§6)。这是唯一要上机才能回答的问题,上面的提取路线正是回答它的手段。

---

## 1. 四份 profile 是什么、装到哪去

### 1.1 四个名字与四个 minor

驱动侧的对照表(`kernel-src/realme-unisoc-5.4/kernel_modules/kernel5.4/audio_driver/sprd/`
下同,简写为 `audio_driver/`):

| minor | profile id | 名字 | 内容 |
|---|---|---|---|
| 0 | 0 `SND_VBC_PROFILE_AUDIO_STRUCTURE` | `audiost` | 语音场景参数(增益/滤波器,最大的一份) |
| 1 | 1 `SND_VBC_PROFILE_DSP` | `dsp_vbc` | VBC 引擎参数 |
| 2 | 2 `SND_VBC_PROFILE_NXP` | `cvs` | CV 序列噪声抑制/录音参数(名字里的 NXP 是历史遗留) |
| 3 | 3 `SND_VBC_PROFILE_IVS_SMARTPA` | `dsp_smartamp` | 智能功放参数(我们没有 aw87xxx 驱动,暂不需要) |

- 名字数组:`audio_driver/sprd/dai/vbc/v4/vbc_dai/vbc-dai.c:436-439`
  (`sprd_profile_name[] = {"audio_structure", "dsp_vbc", "cvs", "dsp_smartamp"}`)。
- profile 枚举:`audio_driver/sprd_audio/audiosipc/audio-sipc.h:24-32`。
- minor→fops 映射:`vbc-dai.c:3182-3211`(`audio_turning_fops[4]`,按下标对应四个 profile);
  各 fops 直接以固定 profile id 调 `vbc_turning_ndp_write/read`(`vbc-dai.c:3144-3159`)。
- 设备注册:`vbc-dai.c:3247-3310`(`vbc_turning_ndp_init`:`alloc_chrdev_region` 起始
  minor 0(`AUD_TURNING_MINOR_START`,`vbc-dai.c:2946`),4 个 minor(`AUD_TURNING_PRO_CNTS`
  = `SND_VBC_PROFILE_MAX`,`vbc-dai.c:2945`),`sprintf("%s%d", "vbc_turning", index)`
  + `device_create`。**minor N 对应名字里的 N**,与 fops 下标一致。
- 本机实测(2026-10-16,coordinator):`/dev/vbc_turning0..3` 存在,主设备号 479
  (动态分配,`1041:1005` 是另一组节点,见 §6)。

### 1.2 blob 的字节格式(唯一的"ABI")

头结构(`audio_driver/sprd/dai/vbc/v4/vbc_dai/vbc-phy-v4.h:1427-1431`):

```c
struct vbc_fw_header {
    char magic[VBC_PROFILE_FIRMWARE_MAGIC_LEN]; /* 16, "audio_profile" */
    u32 num_mode;
    u32 len_mode;
};
```

- `VBC_PROFILE_FIRMWARE_MAGIC_LEN = 16`、`VBC_PROFILE_FIRMWARE_MAGIC_ID = "audio_profile"`
  (`vbc-phy-v4.h:1421-1422`)。magic 按字符串比较**前 16 字节**,不足补 NUL;
  小端 u32。**没有校验和,没有版本号,没有其他字段。**
- 整个 blob = 24 字节头 + `num_mode × len_mode` 字节,mode 0 在前。
- 装载逻辑 `vbc_turning_profile_loading()`(`vbc-dai.c:2949-2997`):
  1. `unalign_memcpy(hdr, fw_data, sizeof(hdr))`(2956-2957);
  2. `strncmp(magic, "audio_profile", 16)` 不等 → `-EINVAL`(2964-2968);
  3. `offset = sizeof(struct vbc_fw_header)`(2972,即 24);
  4. `len = num_mode * len_mode`(2973),`data[id] == NULL` 则 `kzalloc(len)`(2975-2982);
  5. `len = min(len, size - 24)`(2983-2984),拷贝(2985)。
- 读逻辑 `vbc_turning_profile_get()`(`vbc-dai.c:2998-3042`):对称(见 §3.3)。
- **没有CRC/校验**:装载只看 magic,数据本体驱动不解释——它只是一段要转发给 DSP 的
  不透明参数(见 §2)。

### 1.3 装载的两条路(内核侧)

同两个数据槽 `hdr[]`/`data[]`,有两条装载路径:

**路径 A:字符设备写**(运行时/调参)。
`vbc_turning_ndp_write()`(`vbc-dai.c:3045-3089`):一次 `write()` = 一次完整装载
(`vmalloc(data_size)` + `copy_from_user` + 调 `vbc_turning_profile_loading`),
成功返回 `data_size`。**不支持流式/部分写**,每次写都是整块替换。
e5 的 `e5_call_profiles.py` 里有同样经验的注释:"This vendor interface consumes one
complete blob per write, not a stream"(`/tmp/e5-linux/device/linux_device_common/overlay/opt/e5/e5_call_profiles.py:33`)。

**路径 B:request_firmware。**
`vbc_profile_loading()`(`vbc-dai.c:3391-3450`):`strcpy(firmware_path,
vbc_get_profile_name(profile_id))` + `request_firmware(&fw, firmware_path, codec->dev)`
(`vbc-dai.c:3404-3408`)——**裸文件名**,即内核去 `/lib/firmware/<name>` 拿
`audio_structure` / `dsp_vbc` / `cvs` / `dsp_smartamp`,然后走与路径 A 完全相同的
magic 检查 + 拷贝(3430-3450)。

路径 B 的触发方式是写 mixer 控制 `"X Profile Update" = 1`
(`vbc_profile_load_put`,`vbc-dai.c:3545-3564`;控制名定义在 `vbc-dai.c:4912-4927`:
`Audio Structure Profile Update` / `DSP VBC Profile Update` / `CVS Profile Update` /
`DSP SMARTAMP Update`,max 2)。**这就是 e5 的 `e5-audio-d` 脚本用的那条**
(对每个名字写 1,内核自己从 `/lib/firmware` 拿)。

### 1.4 "应用"到 DSP 是另一个动作(Select 词)

装进内核 ≠ 生效。真正把参数送进 DSP 的是 **Select** 控制:

- 控制名(`vbc-dai.c:4928-4943`):`Audio Structure Profile Select` /
  `DSP VBC Profile Select` / `NXP Profile Select`(注意:名字叫 NXP,管的是 profile 2
  = cvs,e5 代码注释也点过这一致性)/ `DSP FFSMARTAMP Select`。max =
  `VBC_PROFILE_CNT_MAX = 0x0fffffff`(`vbc-phy-v4.h:1423`)。
- **Select 词格式**(`vbc_profile_put` 注释,`vbc-dai.c:3513-3520`;逻辑 3491-3527):

  ```
  32 bit = (mode_offset << 24) | (param_id << 16) | dsp_case
           ^bit24-31        ^bit16-23          ^bit0-15
  ```

  `mode_offset` 必须 `< num_mode`(3522-3523),否则整词被丢弃(不更新 `now_mode`)。
- 应用过程 `vbc_profile_try_apply()`(`vbc-dai.c:2915-2942`):
  `data = data[profile_id] + len_mode * mode_offset`,然后 `vbc_profile_set()`
  (`vbc-dai.c:2898-2913`)→ `aud_send_block_param(AMSG_CH_VBC_CTL, mode, -1,
  SND_VBC_DSP_IO_SHAREMEM_SET, profile_type, data, len_mode, WAIT_FOREVER)`。
- `aud_send_block_param`(`audio_driver/sprd_audio/audiosipc/audio-sipc.c:818-866`):
  把 `len_mode` 字节拷进该 profile 类型的共享内存块(`block_param->addr_v`),
  再发一条 20 字节 SIPC 消息(`struct aud_smp`,含 `SND_VBC_DSP_IO_SHAREMEM_SET = 11`,
  `vbc-phy-v4.h:534`)告知 DSP"去这块共享内存按 `len_mode` 字节读"。
  共享内存块的物理地址/大小来自 DT(`sprd,shmad-*` 属性,
  `audio_driver/sprd_audio/audiomod/audio_mem.c:565-618`;我们 DT 里五块都在,
  见 [`telephony.md`](telephony.md) §1.3)。

**注意 bit16-23 的 `param_id` 在 Select 应用路径里其实没被用来选数据**
——选数据的只有 bit24-31(`vbc_profile_try_apply` 只取 `(now_mode >> 24) & 0xff`,
2928-2929);`param_id` 与低 16 位只是原样随消息带给 DSP/e5 的经验是
param_id 填 mode 的逻辑编号、低字节填 DAI id,照抄即可,别自己发明语义。

---

## 2. Android 侧是怎么干的(whale HAL 反汇编结论)

`/vendor/lib/hw/audio.primary.whale.so`(541 KB,ARM32,Android 33,stripped;
本仓库 `changxing60/work/audio/vendor.img` 里,已复制到分析副本)。
结论:**HAL 是把 XML 解析成 blob、然后两条装载路都有的那个"用户态"**。

### 2.1 数据来源:XML,不是二进制

HAL 的字符串与符号表说明它读的是 XML 参数树:

- 路径:`/odm/etc/audio_params/sprd`(目录)、`/odm/etc/audio_params/sprd/audioparam_config.xml`、
  `/odm/etc/audio_params/sprd/audio_param_infor`、`/data/vendor/local/media/audio_params/`
  (运行时调参目录,`init.md.rc` 有对应 `mkdir`,见 §4.3)、`/vendor/etc/audio_config.xml` 等。
- 符号:`init_sprd_audio_param_from_xml`(@0x473c1)、`get_param_count_from_xml`(@0x46b95)、
  `get_param_size_from_xml`(@0x46b21)、`load_audio_param`(@0x495f9)等。
- 场景字符串 77 条:`Audio\Handset\NB1` … `Audio\BTHS\WB1` …
  `Audio\Loopback\Headset3P\Loop1`——XML 里的场景树。
- 同时也有 `audio_structure` / `dsp_vbc` / `dsp_smartamp` 这些**裸名**字符串
  (0x10ef2 / 0x1581c / 0x15824),以及 `read vbc_fw_header failed`(0x18c7c)、
  `read_audio_firmware`(0x138f0)——说明 HAL 也认这个二进制头格式。

### 2.2 装载动作:两条路都实现了,以 firmware 路为主

两个关键函数(符号地址来自 `.dynsym`;PLT/GOT 已解析):

**`upload_audio_profile_param_firmware`(@0x4991c)**——从文件读 blob 后
**塞回内核**:它 `access()` 探测文件、`open` + `__read_chk` 读入、然后调
`send_firmware_params_to_kernel`(日志字符串 0x184d2;写路径见下),把
**整块数据写进 `/dev/vbc_turningN`**(`__open_2(path, O_WRONLY)` + `__write_chk`,
`@0x49e4e-0x49e7e`,path 来自一张 8 项指针表,见 §2.3)。
日志 `"send %zu bytes effect data at %p to kernel"`(0xd862)、
`"send effect data to file(%s) device success"`(0x14e46)。

**`upload_audio_profile_param_from_turning`(@0x49ca0)**——反向:从
`/dev/vbc_turningN` **读回来**(`open` + `__read_chk` 循环,`@0x49d20-0x49d4e`),
然后 `mixer_ctl_set_value`(PLT @0x740b0 解析自 GOT 0x7859c)把数据写进
**"Profile Update"/"Select" 类 mixer 控制**。日志
`"load effect params finished. To read %ld bytes, realy %ld bytes"`(0x16cbd)。

⇒ **Android 上,`/dev/vbc_turningN` 是读写双向的调参通道**:
HAL 从 XML 生成 blob → write 进内核(生效路径);调参工具改完 → read 回来 → 存盘。
e5 的 `e5_call_profiles.py` 在 Linux 上复刻的正是这套 read-modify-write 用法。

### 2.3 HAL 的 minor 映射表(我们设备名的出处)

`upload_audio_profile_param_from_turning` 里那张 8 项指针表
(基址 0x77b30,由 `get_turning_profile_path` @0x4a194 同一张表索引,
合法下标掩码 0x47 = {0,1,2,6}):

| 下标 | 指向 |
|---|---|
| 0 | `/dev/vbc_turning1` |
| 1 | `/dev/vbc_turning0` |
| 2 | `/dev/vbc_turning2` |
| 3,4,5 | `/dev/vbc_turning1` |
| 6 | `/dev/vbc_turning3` |
| 7 | `"2731S"`(非法下标的错误串) |

**HAL 的"profile 类别 → 设备文件"映射与我们驱动侧的 minor 顺序不完全一致**
(它的类别 0 是 turning1、类别 1 是 turning0)——这说明 HAL 内部还有一层
"类别 id → profile id"的换算,换算表在 HAL 私有数据里,没随符号导出。
**对我们的实现无影响**:我们直接用驱动的定义(minor N = profile N,§1.1),
不需要复刻 HAL 的内部类别编号;e5 也是这么做的。

### 2.4 Select 词的 Android 值

`e5-ctl-raw` 的注释(`/tmp/e5-linux/.../e5-ctl-raw:5-9`)与 e5 实机经验:
Android 会写出**超过驱动声明 max(0x0fffffff) 的 Select 值**,例如
`DSP VBC Profile Select = 0x404B0000`——按 §1.4 的格式解,
bit24-31=0x40(64)、bit16-23=0x4B(75)、低 16 位=0。
这只有用裸 ioctl 写(绕过 amixer 的钳位)才能复现;e5 的
`e5-ctl-raw` 就是干这个的(53 行 C,可直接抄)。
**我们机器上正确的 Select 值要自己从 blob/试错中得出**(§5 第 4 步、§6)。

---

## 3. 我们这边怎么拿数据(已验证的提取路线)

### 3.1 两条互相验证的来源

| 来源 | 内容 | 前置条件 |
|---|---|---|
| **A. read-back(推荐)** | 让 Android HAL 装好,读 `/dev/vbc_turning0..2` 吐出 blob | 一次 Android 启动 |
| B. XML + 转换器 | `/odm/etc/audio_params/sprd/*.xml` + e5 的 `vbc-profile.py` | 一次 Android 启动(odm 是 super 里的独立分区) |

两路拿到的应该逐字节一致(都出自同一份 XML 参数);不一致时以 A 为准
(它是 DSP 真正在吃的版本,可能含 HAL 的运行时改写,如 e5 实机遇到的
调参覆盖)。

### 3.2 来源 B 的位置(odm 分区)

`/odm` 不在 `vendor.img` 里(vendor.img 里只有 `audio_config.xml` 的**指针**,
指向 `/odm/...`);它在 super 的独立分区 `odm_a`:

- 布局(本仓库 `changxing60/work/audio/parse-super.py` 实测):
  `odm_a` size 371,650,560 B,super 内偏移 4,625,268,736。
- 里面要拿的文件(HAL 字符串指名):`/odm/etc/audio_params/sprd/`
  目录下的 `audioparam_config.xml`、`audio_structure.xml`(场景树)、
  `dsp_vbc.xml`、`cvs.xml`、`audio_param_infor`。
- e5 的提取脚本 `rootfs/pull-audio-finance.sh`(实为 `pull-audio-firmware.sh`,
  `/tmp/e5-linux/rootfs/pull-audio-firmware.sh`)就是干这个的:
  adb 进 Android,`cp` 到 `/data/local/tmp` 再 `adb pull`,然后
  `vbc-profile.py` 转换 → `/lib/firmware/`。
- 转换器 e5/tools/vbc-profile/vbc-profile.py 的格式定义(经与驱动源码互证,**正确**):
  XML 根元素的 `num_mode`/`struct_size` 即 blob 的两个 u32;每个字段用
  `id`(全模式数组内的**绝对字节偏移**)+ `t`(位宽,如 u16/u32/t960)+
  `offset`/`bits`/`val` 描述;没提到的字节填 0。
- **注意**:odm 是 OTA 会换的分区;提取时应记录 Android 侧的版本号
  (`build.prop` 的 ro.build 属性),别以后拿旧 XML 配新 DSP。

### 3.3 来源 A 的机制(read-back,设备侧已验证)

**内核把 HAL 写进来的 blob 原样缓存,读接口能原样吐出来。**

- 读路径 `vbc_turning_ndp_read()`(`vbc-dai.c:3090-3137`):
  `vmalloc(data_size)` → `vbc_turning_profile_get(buf, data_size, ...)` →
  **`copy_to_user(data_p, buf_p, data_size)` 拷贝整个请求长度**(3131-3134),
  返回值是"实际填充的字节数"但**缓冲区是按请求大小填的**(不足部分零填充)。
- `vbc_turning_profile_get()`(`vbc-dai.c:2998-3042`):
  - `data_size <= 24`:只给头(3031-3010,`return profile_size`);
  - `data_size > 24`:给 24 字节头 + `min(请求-24, num_mode×len_mode)` 字节数据
    (3011-3028);**`data[id] == NULL` → 返回 `-ENOMEM`**(3029-3031)。
- **正确用法:一次 read 请求整个 blob**——`dd bs=64 count=1` 或直接
  `read(fd, buf, 大数)`。`dd` 默认 512 字节块也行(≥24 走全量分支);
  **绝不能用 `bs=1`**:那样第一笔 read(size 1)落在"只给头"分支,
  拿到 1 字节就结束。
- **设备侧实测(2026-10-16,coordinator,我们的 OpenWrt 5.4.254)**:
  `/dev/vbc_turning0` 存在(479:0);`dd if=/dev/vbc_turning0 bs=64 count=1` →
  `dd: Out of memory`,dmesg `vbc_turning_profile_get: profile audio_structure
  data is NULL!` → **正是 -ENOMEM 分支,代码路径活着,只是还没有人装载**。
  这反过来证实:**只要装载发生(无论 Android HAL 写、还是我们写
  `/lib/firmware` + Update 控制),read-back 立刻可用。**
- **结论:提取脚本 = 进 Android → HAL 装载发生 → 每个 `/dev/vbc_turningN`
  一次大 read → 存盘。** 这是"这块板子自己参数"的最直接来源,
  也是 §6 里几个未知的唯一上机验证手段。

### 3.4 装载 happens when?Android 什么时候写

HAL 的装载不是开机即做,而是**第一次用到对应 profile 时**(懒惰装载):
符号 `load_audio_param`(@0x495f9)的调用方是 `audio_param_thread`
(字符串 `"audio_param_thread profile:%d Enter"` @0x19e24),
按 profile 一线一线起;`init_audio_param`(@0x3c42d)是总入口。
对语音而言,HAL 在**第一次通话/录音场景**初始化时装载(字符串
`persist.vendor.audio.boot_completed` @0x17181 暗示启动完成标志)。
**提取脚本要在 Android 里触发一次音频动作(如放个铃声/拨个测试音)
再读,不能一开机就读。** 兜底做法:读之前先检查头 magic 是否有效,
无效就再等等(§5 第 0 步)。

---

## 3.5 结果:三份 profile 已产出并逐字节验证(2026-10-16)

**来源 B 走通了,而且不需要开安卓。** 关键发现是 **odm_a 是 EROFS**,而我们的 5.4 内核
`/proc/filesystems` 里就有 `erofs`(不需要任何 ko):

```
mkdir -p /tmp/odm && mount -t erofs -o loop,ro /mnt/changxing60-disk/odm_a.img /tmp/odm
ls /tmp/odm/etc/audio_params/sprd/
  audio_structure.xml  2293417   dsp_vbc.xml  689605   cvs.xml  2850045
  audioparam_config.xml   12151   audio_pga.xml  audio_process.xml  codec.xml
```

根元素名与驱动要的固件名**逐字相同**(`<audio_structure num_mode="0x43" struct_size="0x2da">`、
`<dsp_vbc … 0x48/0x6c4>`、`<cvs … 0x43/0x33c>`),`audioparam_config.xml` 里写着
`CodeType="ump9620"`——就是我们这颗 codec,不是别的板子的参数。

转换器 `tools/voice/vbc-profile.py`(vendored 自 e5,e5 又注明转自 mu300-linux,即我们的上游)
一次跑出三份,**没有一条 `overflow` / `misplaced` 警告**——那是转换器自带的交叉校验
(每个字段的绝对偏移除 `len_mode` 必须等于它自己声明的 mode 号),55,662 个字段全过:

| profile | num_mode | len_mode | 文件大小 | md5(写入 = 读回) |
|---|---|---|---|---|
| `audio_structure` | 67 | 730 (0x2da) | 48,934 | `238c36a07aef0a7cc097b1689c2cec6f` |
| `dsp_vbc` | 72 | 1732 (0x6c4) | 124,728 | `bfe6097b66ed4dac3ba0d31ffe4c0265` |
| `cvs` | 67 | 828 (0x33c) | 55,500 | `76e6b2b32e2682becf8075898054c078` |

**决定性的一步是写进真驱动再读回来。** 每份 blob `dd` 进 `/dev/vbc_turning0/1/2`,再用
`changxing60-vbc-dump` 读回,**三份都逐字节相同**。这一步证明了 XML→blob 的解读(尤其是
字段表的绝对偏移寻址)与驱动完全一致——不是"转换器没报错",是"内核认并且原样存住了"。

**踩到的坑:`dd` 的块大小必须大于等于 blob,否则写入会被拆开。** 驱动把**每一次 `write()`**
当成一整份 profile,并且在每次写的前 16 字节上校验 magic。用想当然的 `bs=65536` 时,
124,728 字节的 `dsp_vbc` 被拆成两次写,第二次从 blob 中间开始、没有 magic,于是:

```
dd: error writing '/dev/vbc_turning1': Invalid argument
1+1 records in
1+0 records out
```

两份小的(48,934 / 55,500)在同一个 `bs=65536` 下都正常——**只有 dsp_vbc 坏**,这正是会被
误判成"blob 不对"的形状。所以 `changxing60-vbc-load` 的块大小是按文件大小算出来的,不是猜的。

**为什么必须回读校验:驱动只看 magic。** 没有长度、没有校验和、没有版本号
(`vbc-dai.c:2964-2984`)。当天用一个**改了一个字节、magic 和长度都对**的 cvs 做实验:驱动
**照样收下了**(内核里 md5 变成 `47d0f01f…`),没有任何报错。是 `changxing60-vbc-load` 回读比对
才发现不一致并把它重写成正确的 `76e6b2b3…`。⇒ **"写进去了"和"写对了"是两件事**,这个校验不是
形式。

**落盘的三件东西**(都已在真机跑过):

| 件 | 位置 | 作用 |
|---|---|---|
| `make-vbc-profiles.sh` | `tools/voice/`(主机侧) | XML 目录 → `firmware/`(build-rootfs.sh 会拷进 `/lib/firmware`) |
| `vbc-profile.py` | `tools/voice/`(主机侧) | 转换器,vendored 未改(改了那次验证就作废) |
| `changxing60-vbc-load` | `rootfs/…/opt/changxing60/bin/`(设备侧) | 写 `/dev/vbc_turningN` + 回读比对,幂等 |

`etc/init.d/changxing60-audio` 在模块加载完之后调它。`firmware/` 与 `work/` 都在
`.gitignore` 里——厂商参数不进仓库。

**还没回答的**(与 §6 呼应):`num_mode` 是 67/72/67 已经确定,但**哪个 mode 号对应哪个场景**
(听筒 NB/WB/SWB/FB 各是第几个)仍然只能靠真机试听——这是 §5 第 3 步,离线做不了。

---

## 4. 语音路径的完整清单(`changxing60-voice-audio` 要做的事)

> 来源:e5 的 `e5-call-audio.py`(736 行,已实机跑通,M8 板同 SoC)。
> 行号指 `/tmp/e5-linux/device/linux_device_common/overlay/opt/e5/e5-call-audio.py`。

按时间顺序:

1. **找到 PCM 对**:`/proc/asound/pcm` 里正则 `^(\d+)-(\d+): FE_ST_VOICE `
   (295 行)——本机实测存在(`telephony.md` §9.6 第 7 条:`00-05 FE_ST_VOICE`)。
   这对 PCM 是 **hostless** 的:内核 `FE_DAI_ID_VOICE = 5`
   (`audio_driver/sprd/platform/platform_routing/sprd-platform-pcm-routing.h:25`),
   数据不经 AP DMA,CP 语音直接在 modem DSP 与 codec 间走
   (`e5-call-audio.py:190-196` 注释)。AP 侧打开它只是"让路由活起来"。
2. **打开双向 PCM**:`hw:X,Y`,capture + playback 各一
   (170 行);格式 S16_LE(code 2)、1 ch、8000 Hz(173 行);
   period 640、buffer 1280(175-176 行);`prepare` 双向、然后 `start` 双向
   (183-193 行)。**playback 侧有个坑**:空缓冲不能 start,
   要用 `snd_pcm_forward` 把应用指针推过去(186-190 行,注释
   "ALS refuses an empty playback start... FE_ST_VOICE has no AP DMA")。
3. **先路由,后 profile**:`start()` 的顺序(556-573 行):
   快照所有相关控制 → **profile Select**(PROFILES = 三个 Select,419 行附近)→
   **ROUTES**(213-231 行,路由开关/端口选择)→ **output**(RECEIVER/SPEAKER,235-258 行)
   → 打开/启动 PCM → **再来一遍 profile Select**(注释:"The vendor applies the
   parameters again after starting both PCMs",569 行)→ 解除下行 mute。
4. **路由/增益控制清单**(全部是 amixer 可写的普通控制,名字与值见
   213-258 行的 ROUTES/RECEIVER/SPEAKER 字典):
   - 路由开关:`S_VOICE_P_CODEC SWITCH` / `S_VOICE_C_CODEC SWITCH` = on
     (内核侧 connect 定义:`audio_driver/sprd/platform/platform_routing/
     sprd-platform-pcm-routing.c:728-733`,widget `S_VOICE_P_CODEC`/`S_VOICE_C_CODEC`);
   - VBC 端口选择:`VBC_MUX_DAC1_IIS_PORT_SEL`、`VBC_MUX_IIS0_PORT_DO_SEL`、
     `VBC_MUX_ADC2`、`VBC_MUX_ADC2_IIS_PORT_SEL`(213-219 行);
   - 增益基线:`VBC DAC1 DG Set = 24,24`、`VBC DAC1 DSP MDG Set = 1,1024`、
     `VBC ADC2 DG Set = 24,24`(220-223 行);音量走 `VBC_VOLUME`
     (注意:e5 实测 **改 VBC_VOLUME 才是 Android 的音量语义**,
     改 DAC DG 在 codec 路线上不生效,427-437 行注释);
   - 输出端:`Speaker Mute = off`、`Earpiece Mute = off`、`Mic Function = on`
     (230 行);听筒/喇叭各自的详细 routing(235-258 行)。
   - **mute 纪律**(223-224 行 + 434-442 行):路由切换期间保持
     `VBC_DL_MUTE = enable`,切换完成、profile 重放后才 `disable`;
     缓存的 "disable" 不算数,要真写一次。
5. **profile Select 词**(419-424 行,§1.4 格式):
   `(mode << 24) | (mode << 16) | 5`——mode 从一张**机器自己的表**里查:
   听筒 NB/WB/SWB/FB = 0/2/4/5,免提 = 7/9/11/12,蓝牙 = 28/30/32/33
   (注释:"Own Handset NB1/WB1/SWB1/FB1: 0/2/4/5 ...")。
   **这些编号是 M8 的参数表布局;我们机器的编号要从我们自己的 blob 里数
   (§5 第 4 步),不能照抄。** 低 16 位的 5 = `VBC_DAI_ID_VOICE`
   (`vbc-phy-v4.h:1251`,枚举第 5 个,值 5)。
6. **带宽切换**:监听 `/dev/audio_pipe_voice`(631 行),读 20 字节
   `struct aud_smp`(`audio_driver/sprd_audio/audiosipc/audio-smsg.h:61-68`:
   `u16 command; u16 channel; u32 parameter0..3`,小端):
   - `command == 0 && channel == 2`:带宽变化,`parameter1` = 0..3
     (NB/WB/SWB/FB)→ 重放 profile Select + 解 mute(646-647 行,
     处理函数 `network()` 在 537-544 行);
   - `command == 0x35 && channel == 2`:CP 语音使能(648-649 行)。
   - 消息格式与内核侧一致(`audio_driver/sprd_audio/audiopipe/audio-pipe.c:159-215`
     的 read 就是原样转发一条 20 字节 smp;write 同理)。
   - 退出时用 `ioctl(fd, AUDIO_PIPE_WAKEUP=_IOW('A',0,int), 1)` 解阻塞读
     (`audio-pipe.c:37`;e5 在 725-729 行)。
7. **挂断/清理**:`stop()` 反向恢复快照(576-607 行),注意
   **make-before-break**:恢复 S_VOICE_* 开关时先恢复"原来开的",
   再恢复其余(592-599 行注释),否则会把共享同一个 DSP scene 的
   旧路由先关掉,通话中声音消失。
8. **(可选)调试通道**:`/dev/audio_dsp_call_info` 的
   `DSPLOG_CMD_CALL_INFO_ENABLE = _IOW('X', 10, int)` /
   `DSPLOG_CMD_CALL_INFO_SET_SIZE = _IOW('X', 11, int)`
   (`kernel-src/realme-unisoc-5.4/include/uapi/sound/sprd_audiodsp_ioctl.h:35-36`;
   驱动侧 `audio_driver/sprd_audio/audiodspdump/audio_dsp_dump.c:640-700`)。
   e5 没用它也能跑通,先不依赖。

**不需要的东西**(常被误以为要):
- 不需要打开 `FE_ST_VOICE_PCM_P`(那是 VOIP 的另一个 hostless 对,通话不用);
- 不需要给 PCM 写任何样本数据(hostless,写了也不走);
- 不需要 `audio_structure` 的 **Update** 控制在运行时重写(blob 装载只在启动时做一次);
- 不需要实现 `audio_pipe_trigger_*`(那是录音处理的触发,e5 未用)。

---

## 5. 建议的落地顺序(给 `changxing60-voice-audio`)

0. ✅ **提取 blob —— 已完成,且没开安卓**(§3.5)。走的是 XML 路线:odm_a(EROFS)挂上,
   取四份 XML,`tools/voice/make-vbc-profiles.sh` 转出三份。
1. ✅ **放固件 + 装载** —— `firmware/{audio_structure,dsp_vbc,cvs}`(build-rootfs.sh 拷进
   `/lib/firmware`),`changxing60-vbc-load` 写 `/dev/vbc_turningN`。**没用 `Update` 控制**:
   那条路要 mixer,而本 rootfs 没有 amixer / libasound / alsa-utils(§3.5),字符设备这条路
   一条 `dd` 就够,且两条路最终都进同一个 `vbc_turning_profile_loading()`。
2. ✅ **冒烟测试(不打电话)—— 已过**:三份写入后回读,**md5 逐字节相同**;dmesg 无
   `magic error`、无 `-ENOMEM`(§3.5)。**并且额外做了负例**:改一字节的 blob 驱动会静默收下,
   是回读校验抓出来的。
3. ⬜ **Select 词试错 —— 唯一必须在真机上做的环节**。对三个 Select 控制用裸 ioctl 写
   `(mode << 24) | (mode << 16) | 5`,mode 从 0 扫到 `num_mode - 1`(现在知道是 67/72/67),
   同时拨一通测试电话听筒/喇叭各试。**e5 的 mode 表是 M8 的,不是答案**(§6 第 1 条)。
   注意:本机没有 amixer,`e5-ctl-raw` 那种裸 ioctl 写法是必需的,不是可选的。
4. ⬜ **实现守护进程**:抄 `e5-call-audio.py` 的骨架(hostless PCM + 路由表 +
   pipe_voice 监听),把 mode 表、增益字典、输出端 routing 换成本机的。
   **依赖面已查清**(2026-10-16):e5 那份是 Python,混音用自带的 ctypes ioctl(不需要
   libasound),**但 PCM 那段 `ctypes.CDLL` 的是 `libasound.so.2`** —— 而本 rootfs 没有它,
   feeds 里也没有 `alsa-utils`。所以要么自己交叉编 alsa-lib 装进 rootfs,要么把 PCM 那段
   也改成裸 ioctl。**python3 本身是有的**(3.13.15,`python3-light` 已进镜像)。
5. ⬜ **接入 `changxing60-voice`**:现在的网页/按键层已经就绪
   (`telephony.md` §7/§8),把"拨号/接听/挂断"事件连到守护进程的
   start/stop/speaker/mute。

---

## 6. 还没搞清楚的(诚实清单)

1. **我们机器 blob 的 mode 编号表**(§4 第 5 点):听筒/免提/蓝牙 ×
   NB/WB/SWB/FB 各是第几个 mode,只能从提取出的 blob + 真机试听得出。
   e5 的表(M8)是同 SoC 的**参考起点**,不是答案。
2. **Select 词的 `param_id`/低 16 位语义**:驱动只看 bit24-31 选数据
   (§1.4),其余位是"随消息带给 DSP"的 opaque 值;e5 的经验是
   param_id = mode 逻辑编号、低 16 位 = DAI id(5)。**照抄 e5 大概率对,
   但没有驱动侧的代码证明**,留作试错项。
3. **dsp_smartamp 是否要装载**:我们板子有 aw87xxx 功放但驱动没移植
   (`telephony.md` §9.5);e5 的 M8 板也用了 aw87xxx 并装了这个 profile。
   先不装,听筒/喇叭不受影响(e5 经验);若后续移植功放驱动再补。
4. **HAL 内部"类别 id → profile id"换算**(§2.3):没从反汇编里挖出来;
   对我们的实现无影响(我们直接用驱动的 minor 语义),但意味着
   **不能**拿 HAL 日志里的 "profile 0/1/2" 直接当我们的 profile id。
5. **本机那组 `1041:1005` 的设备号**:coordinator 实测里 `/dev/vbc_turning0..3`
   同时报了 `479:0..3` 与 `1041:1005` 两组;驱动源码只有一组
   (`alloc_chrdev_region`,§1.1)。猜测是同一节点的另一可见形式
   (或另一次注册的残留),未验证;不影响使用(按路径打开即可)。
6. **`/odm` 分区的在线读取**:odm_a 在 super 里,本机尚未 dump;
   §3.2 的偏移/大小已备好,等一次 Android 会话即可 dd 出来
   (与 §5 第 0 步同一会话完成)。
7. **播放/录音场景的 profile**(非通话):`Audio Structure` blob 里也含
   媒体播放参数(mode 0 通常是),e5 的经验是媒体路径用
   `Audio Structure Select = 0` + `DSP VBC Select = 0x404B0000`。
   我们先只做通话,媒体参数留待后续(声卡其他 PCM 已能出声,
   见 `telephony.md` §9.6 第 7 条,但那走的不是 DSP 参数路径)。

---

## 7. 与既有文档的关系

- **`telephony.md` §5 第 3 步说"移植 `tools/vbc-profile` 从 XML 生成固件"——
  本文证实该路线可行(§3.2),但给出了更好的首选:read-back 直接拿 blob(§3.3),
  XML 转换降级为对照手段。** 这不是矛盾,是补充:两条路的产出应该一致,
  read-back 少一个解析器依赖。
- `telephony.md` §9.8 说"要写 `changxing60-voice-audio`...ABI 见
  `docs/changxing60/vbc-profile.md`"——本文就是那份 ABI。
- `e5-linux.md` §2 的"音频实听通过"与本文 §4 的清单互为印证:
  那边是结果,这边是可复制的步骤。
- **设备号勘误**:`telephony.md` §9.6 第 7 条只写了 `/dev/vbc_turning0..3`
  (char 479:0..3);本文 §6 第 5 条记录了 coordinator 实测同时存在
  `1041:1005` 一组,原因未查明(不影响使用)。
