# 7552N / 畅行60 — OpenWrt 工程文档索引

> **状态(2026-10-16)**:设备跑**原生 OpenWrt 25.12.5**(path A 持久 ext4,自编 5.4.254 内核)。
> 蜂窝 WAN / WiFi 热点(**下游手机真能关联并拿到地址上网**,`changxing60`)/ USB 管理口 / NAT /
> LuCI / 内屏状态页 / IPv6 双栈 / 魔法 全部实测可用;驱动适配这一轮(13 个 vendor 模块 + DTB 修回
> USB)已上机复验。6.18 LTS 试验线进行中。本索引是这份工程的入口,每份文档顶部都自带状态与日期。
>
> **2026-10-16 当天新增(全部设备实测)**:短信**后台收发**(池里 4 条真实短信、`smsd` 常驻)+
> **转发面板**(`changxing60fwd` 七个方法可调,修掉了"引擎在位、通往它的四条路全缺"那个隐形缺口);
> **网页拨号/接听/挂断**(12 个方法,通话记录里有真实呼叫条目);**AT 状态面**(频段/ARFCN/PCI/
> RSRQ/SINR/邻区/**流量计数**);**通话音频用户态通路**(两个 PCM RUNNING、319 个控件收尾逐字节还原、
> 37 条断言全过);**内屏来电页 + 三键**(118 条主机断言);命名复核补上**第三种搜法(二进制字符串)**,
> 清掉最后一个残留。**仍未完成**:喇叭功放机器卡钩子、真实通话的模式号标定。
>
> **⚠ 2026-10-17 起:版本收束,暂停新增改动。** 判据是用户给的"即使有小 bug,只要不影响网络就行"。
> 当前状态的完整记录(网络实测证据 / 功能清单 / 已知问题逐条的影响面 / 挂起项 / 回滚方法)见
> [`state-2026-10-17.md`](state-2026-10-17.md),设备侧逐文件指纹见
> `rescue/dumps/2026-10-17-device-state/`。**恢复改动前先读那一份。**
> **已挂起**:通话接通后 ~8 s 被 CP 拆线(`CP voice enabled=False (mask=0x0)`)与"声音通道不对"
> —— 拨号链路本身是通的(对方真的响、真的接了),见 state 文档 §6;喇叭功放钩子与真实通话模式号
> 标定一并挂起,两个后台 agent 已停。
>
> 历史背景:这套移植在 2026-10-10 曾被归档放弃,2026-10-13 复活并落地——**放弃决定只对那一刻
> 成立,现行结论以本索引「现行文档」为准**。「为什么曾放弃」「网络优势误判纠正」等仍有效的
> 历史经验保留在文末[「历史背景」](#历史背景2026-10-10-的放弃决定)一节。

## 路径约定与铁律

- **`tools/...`、`openwrt/...`、`mainline-7552n/...`、`boot/...`** 一律指 `changxing60-linux/` 子仓库下的路径
  (`changxing60-linux/` 是独立 git 仓库,被外层 `zte7552n/.gitignore` 整个忽略;见 [`access.md`](access.md) 与
  [`debug-toolbox.md`](debug-toolbox.md) §四「工具的两份拷贝」)。文档里写裸 `tools/...` 是简写,
  从本目录出发**当相对路径解析会落空**——要找实物去 `changxing60-linux/tools/`。
- **adb 只用 Windows 侧** `/mnt/c/platform-tools/adb.exe`,别动系统 PATH/别名(仓库根 README
  「上手前必须知道的三条」;本机工作区另有 `CLAUDE.md` 记录同一铁律,它不进公开快照)。
- **二进制传输只走 `cp` + `adb pull`,禁 `adb exec-out`**(CRLF 毁数据);到设备普通 `scp` 不可用
  (rootfs 无 sftp-server),用 `scp -O` 或 `ssh 'cat > 文件'`。
- **`boot_a` 全程不碰**;`rmmod sprd-drm` / `rmmod sprd_wlan_combo` 会挂死内核;**别在真实数据呼叫
  期间往 `/dev/stty_nr1` 灌 AT**;触摸未获单独确认不开;**报成功前必须实测**。
- **`/opt/changxing60/bin` 下的脚本一律要有 x 位**(`etc/init.d` 与 `etc/uci-defaults` 同理)。它们全部
  被按路径调用,而"没跑"和"跑了没效果"在设备上长得一模一样:`net-split` 曾被提交成 644,
  首启那一刻只回了句 `Permission denied`,于是热点没进任何防火墙 zone、**任何客户端都拿不到地址**
  ——而 AP 照样广播、客户端照样关联、四次握手照样完成(见 `changxing60-linux/docs/FINDINGS.md` §35)。
  `openwrt/build-rootfs.sh` 现在会统一补位,但仓库里改脚本时别把位改掉。
  ⚠ 而且**别把"补位脚本会在"当成"git 里有"**:2026-10-16 核对时,那 9 个位里 6 个被跟踪的在 HEAD 仍是
  `100644`(只改了工作区,`git diff` 看不出来),另 3 个所在的 `openwrt/overlay/opt/changxing60/bin/` 连同该树
  其余新增部分整个**未跟踪** —— 当天已在 `changxing60-linux@7117348` 一并落盘。**判据是 `git ls-files -s`,
  不是 `ls -l`**(见 [`drivers.md`](drivers.md) §8 最后一条)。

## 现行文档(按主题)

| 文档 | 主题 | 一句话 / 状态 |
|---|---|---|
| [`state-2026-10-17.md`](state-2026-10-17.md) | **版本收束(冻结状态)** | **2026-10-17 起暂停新增改动**,固化一个"不影响网络"的版本:网络实测证据(IPv4 4/4 ~70 ms、DNS、计数器在走、IPv6 2/2、热点 ch36 VHT80)、逐个功能是否工作、已知问题**逐条标注会不会影响网络**、**已挂起的通话音频**及其下一步二分实验、怎么再次验收、怎么回滚。配设备快照 `rescue/dumps/2026-10-17-device-state/` |
| [`conflicts.md`](conflicts.md) | **OpenWrt ↔ 底层的冲突扫描(2026-10-17,只读)** | 13 轮设备只读探针 + 2 个只读子 agent,按 🔴panic/🟠死到重启/🟡降级/⚪外观 分级:A 类(充电寄存器分叉 + psy 为何报 0、`packet_steering` 这个暗桩、AT 通道/DTS 证明不撞、磁盘与 misc 逐字节一致、属性区假信号);**B 类(最要紧两条:`net-split` 在全新刷机第一次开机因 S10 早于 S12 而 `uci -q set` rc=1 整个 LAN 拆分静默丢失 —— 靠 carry-over 兜着;`vendor-bisect` 标记还武装着,判据与 `load_good` 的 15 s 窗天然打架,可能永久拉黑一个厂商驱动**;另 wifi down/up 双驱动无锁、IPv6 bearer 双写者、UDC 三写者、charge-fix 那条 cron 只存在于设备);C 类(dnsmasq→mihomo 单点、全机只有一张 `inet fw4`);**E 类(音频 oops 的真实机制 ⇒ 撤回 `saudio.c` 归因;治 CP2 BSS-Load 断言的 `bss_load_update_period=0` 只在设备 uci、镜像里没有;`modem_run()` 无锁 TOCTOU 且我们和 modem_control 都是它的用户)**;§8 一张"假信号/已排除"表(含我自己两处引用错误被抽查打掉:驱动文件搞错、并发当必要条件);§9 九条建议动作 → **2026-10-17 用户点头后 1–5/7/8 已执行(本地+机器双改,chroot 对照/主机 harness/实机验收三层验证),6 裁定"留、记账";行 9(E1 clamp 补丁)当晚经用户点头也已上机实测**(拒绝消息 + carve 定案 7680)。装载重启当晚撞出的开机 panic 是另一条新 🔴(**E5**:vbc-load before-snap 读未加载 turning0)⇒ **§10 全记录,当天 marker 门修复**。落地记录见 `state-2026-10-17.md` §8 |
| [`defects.md`](defects.md) | **代码缺陷记录(review 产物)** | 2026-10-17 派 4 个只读 subagent 分区审(LuCI/设备脚本/rootfs+tools/内核补丁)、逐条复核去重后 **29 条**(4 HIGH/10 MED/15 LOW,评审当日 26 + E1 上机当晚补 H4/L14/L15),**每条标 🔴/🟡/⚪ 影响网络?**;这是「记录」不是「修」,改不改由用户定,🔴 那几条(M5 WAN 无 timeout、M6 teardown 硬编码、M7 net-split exit0、M8 vendor-bisect 默认不调、M10 build-wlan 吞 patch 失败)优先;含「假缺陷」勘误;音频 oops 根因(H1)与 vbc before-snap(H4)**10-17 晚均已修并实测** |
| [`backlog.md`](backlog.md) | 待办总表 | 2026-10-14 存档:还剩什么、为什么卡、设备回来按什么顺序做、命令速查(含 **OpenClash 工件不在 git、重建 rootfs 会丢** 这个缺口) |
| [`access.md`](access.md) | 怎么连进去 | 屏上链接 / LuCI·SSH 口令(**不进仓库**,真值在主机 `~/.changxing60-secrets`;10-16 前是空的)+ 免密密钥 / §2.2 rootfs 属主 uid-1000 那个坑 / 热点 PSK(同样不进仓库)/ 怎么重启(会不会跑到 Android)/ 宿主侧探测陷阱 |
| [`reboot-boot-slot.md`](reboot-boot-slot.md) | **启动落点 + 两条切换动线(OpenWrt ↔ Android)** | 落点只由 misc 偏移 2048 的 32 字节定(§0);**OpenWrt→Android 走后台按钮**(服务→启动目标,第 6 个面板,10-17 上机验过读写、未按 Reboot);**Android→OpenWrt 走宿主一条命令**(`tools/changxing60-back-to-openwrt.sh`:stage→DTB 9 字节→重启→验 USB,顺序不容随意);boot_b 完好时不用重刷,只要 32 字节;三态判据只看 USB |
| [`rename.md`](rename.md) | **命名:mu300 → changxing60** | 全量改名记录:**rootfs 与启动镜像是两个工件**,只改 rootfs 不完整;`default-boot` 那条会让旧 init 每次开机把 misc 指向安卓(有 70 s 敞口);`repack-ramdisk.py` 只换 ramdisk 不动 30 MiB 内核;2026-10-16 已烧 boot_b 并重启逐项实测 |
| [`screen-plan.md`](screen-plan.md) | 内屏 + 按键 + 全功能自查 | 480×854 状态页 + 电源键切背光(五档记忆)+ 音量键;**来电页**(`INCOMING CALL` / 号码 / 通讯录名 + 三键接听·挂断,通话中保持常亮);OpenWrt 全功能逐条实测。顶部记各轮真机反馈(含「第五轮」面板地址修正) |
| [`ipv6.md`](ipv6.md) | IPv6 双栈 | 蜂窝 WAN + 热点下游双栈实测通过;含复测工具与未验证项(WiFi 空口需真机) |
| [`sipa-wedge.md`](sipa-wedge.md) | SIPA 假死 | WAN 有地址零流量、只有重启能救——根因(delegator 缺对端超时)+ 补丁 + 五次触发与完整自愈链条 + 上游调查 |
| [`cptl-and-boot.md`](cptl-and-boot.md) | 安卓启动镜像只读解剖 | **`/proc/cptl` 安卓自己也没有(搬不了)**;真 assert/alive 通道是 `/dev/spipe_nr2`;§4.2 **`@modemd` 结案**:根因是**属性区属主**(解包成 `1000:1000`,bionic 静默拒读 ⇒ 一行 `chown 0:0` 已修,`getprop` 0→1756 条,跨重启有效)、客户端 `changxing60-modemd` 已移植常驻;但**通知门被 AP 状态变量卡在 0(Offline)⇒ e5 的「300 s→4–5 s」在本机不成立**,客户端惰性但无害;`blocked` 子命令在本机危险(实测一次,只能重启救) |
| [`e5-linux.md`](e5-linux.md) | 参照项目 `e5-linux` + 三仓对比 | E5=UMS9621(**M8 才是 UMS9620**);GPU 走主线 panfrost;`e5-modemd` 在上游把 CP assert→Alive 从 300 s 压到 4–5 s(不用重启)——**⚠ 本机不成立,原因见 [`cptl-and-boot.md`](cptl-and-boot.md) §4.2**;§7 **`kanoqwq/mu300-linux` 是空 fork、对 WAN 无贡献(别追)**;§5 按优先级的可复用清单 |
| [`debug-toolbox.md`](debug-toolbox.md) | 调试工具箱 | 镜像自带:`changxing60-diag.sh` 一条命令看全、`changxing60-cp-reset.sh` CP 停/起、ethtool/strace/python3 包;apk 只用 `add` 不用 `upgrade` |
| [`power.md`](power.md) | 功耗 + 充电 + 省电 | 只有库仑计、必须断 USB 走电池(0.8W/13h 实测);充电 0.5A 根因与 charge-fix;§11 省电策略(governor + 空闲熄背光,默认关) |
| [`watchers.md`](watchers.md) | **后台检测/看门狗清单 + 关停手册** | 每个周期任务的位置/周期/**准确的关停命令**/关掉的代价(现场核对过 md5);含建议低功耗档顺序与「没有一项单独测过电流」的诚实边界 |
| [`gpu.md`](gpu.md) | GPU / Mali-G57(kbase) | 为什么 `mali_kbase` 从来没进过镜像(不是加载失败)、怎么重编 r40p0;**2026-10-16 上机实测内核侧全过**(`Probed as mali0`、`/dev/mali0`、devfreq 三档、`Mali-G57 4 cores r0p1`);**用户态 UMD 缺物**,`cltest` 验收尚不能跑 |
| [`drivers.md`](drivers.md) | 驱动适配(缺口表 + DTB) | Android 199 个模块 vs OpenWrt 115 个的对照、25 个已补、哪 85 个补不了;**§2.1 vendor_boot_b 是 5.4 与 6.18 共用的 DTB —— 2026-10-14 给它关掉 `dummyphy` 让 OpenWrt 每次开机都没有 USB,9 字节原地改回,已实测 `VERIFY-USB-OK (PASS=9)` 且重启复现**;**§4.1 自动二分第一版把 13 个"根本没装进去"的模块判成了安全(cron 的 PATH 里没有 `timeout`)**;**§8.1 开机耗时基线:post 落笔 uptime=202 s、ssh ~240 s,两次开机逐秒一致——慢是结构性的,超基线才查错误驱动等待(附三条对账)** |
| [`proxy.md`](proxy.md) | 魔法(透明代理) | OpenClash vs PassWall 选型;**已装到设备且已上机运行**(§7 安装 / §8 运行实录) |
| [`sms-port.md`](sms-port.md) | 短信 / 通话移植 | 上游 SMS 栈:PDU 编解码、AT daemon、池 CLI、smsd、bark 转发;**后台收发已上机实测**(池里 4 条真实短信、`smsd` 常驻)、**转发面板 `changxing60fwd` 七个方法在设备上实测可调**(2026-10-16 补上缺失的 ucode/ACL/菜单/页面四件);**控制面已上机实测**(见 [`telephony.md`](telephony.md) §8.3),音频仍未通 |
| [`usb-mode.md`](usb-mode.md) | **USB 链路:管理口 / 共享口** | 默认只发地址(实测:USB 跃点 25 < WLAN 45,发网关就真的会抢走 PC 的上行);`share` 模式另发网关+DNS+IPv6 中继,蜂窝共享给 PC;**双向实测通过**(强制走 USB 的 HTTP 请求真的从手机出去了);切回来要 `release`+`renew`,单 `renew` 不够 |
| [`net-panel.md`](net-panel.md) | **蜂窝状态面板 luci-app-changxing60net** | 给早已在设备的 `changxing60-net-status --json` 补上从未写过的面板(ucode/ACL/菜单/JS 四件);铁律:**未回答的字段是 null 不是 0**,后端 json() 原样传值、页面唯一出口印 `—`;**主机侧两段验证 45/45 全过**(harness + 真 ubusd/rpcd 对桩采集器,当场抓出 stderr 混管、/tmp 两个真 bug);**2026-10-16 已上机**:五个 view 的 md5 与设备实际 serve 的 `/www` 那份逐个相符、served 字节喂 harness rc=0、`ubus call changxing60net status/fast` 返回真实小区数据;**仍未在浏览器里开过**(ACL 对非 root 会话、DOM 渲染未验) |
| [`audio-oops.md`](audio-oops.md) | **音频路径内核 oops(设备"自己关机"的真因)** | **2026-10-16 那次失联是我自己的音频测试打出来的**:`arecord` 在 `snd_pcm_hw_params()` 的防泄漏 `memset` 里写穿映射(`Comm: arecord`、`pc: __memset`、`lr: snd_pcm_hw_params`、`pte=0`、故障地址 = 基址 + 恰好 2 页),本机 `CONFIG_PANIC_ON_OOPS=y` + 我们自己 `boot/init:85` 写 `panic_on_oops=1` → panic → 复位;**机制 2026-10-17 勘误:当事的不是 `saudio.c:543`**(那个 ko 加载了但 refcount 0、无 platform device、DT 无 `unisoc,saudio` ⇒ 从没 probe),而是 `sprd-dmaengine-pcm.c:1135` 把 `dma_bytes` 写成请求值 + `hw:0,0` 录音缓冲是固定 IRAM carve(本机 `test_normal_cap_use_iram=0x1` 实测)+ core `pcm_native.c:746-752` 按请求值 `memset` ⇒ **单个 `arecord` 就能炸,并发不是必要条件**(放音不走 carve 分支);纪律:card 0 上不并发 + 不在 normal capture FE 上要大于 carve 的 buffer;逐条排除了断电/看门狗喂狗超时/mobile-data/CP 楔死;原始 pstore 已归档并附 sha256(**pstore 只存一条,下次 oops 会顶掉**) |
| [`telephony.md`](telephony.md) | **通话 / 音频 / 三键 / 内屏来电页** | 三键硬件**真实存在**(DT + 安卓 input 记录,114/115/116 都在上报);音频硬件齐全(AW87xxx 喇叭功放 + UMP9620 codec + VBC + 三路 MIC);设备**有 `l_agdsp_a` 固件分区**;驱动源码就在我们已在用的 realme 树**同一 commit**。§8 **网页拨号已落地**(LuCI 拨号页 + rpcd 后端 + 脱手拨号 job,119+82 条主机断言);§9 **音频驱动已编并上机,声卡起来了**(§9.1 勘误:根本不用开 `CONFIG_SND_SOC_SPRD`),**唯一遗留是 aw87xxx 功放无源码**;§9.9 **三份 VBC profile 已产出并逐字节验过**(走 XML 路线,**不用开安卓**:odm_a 是 EROFS,我们内核自己能挂;写进 `/dev/vbc_turning0/1/2` 再回读 md5 完全相同);§7 内屏来电页 + 三键接听/挂断已定稿(`tools/screen/test-call.c` 全过)。**但音频仍未真正流动。** **2026-10-17 用户裁定:记录下来,这部分暂时不再适配** —— §10 是那份记录:三条单点根因猜想(AGDSP 没固件 / CP 没使能语音 / 数字增益 −60 dB)全被实测打掉,AGDSP 其实由 **U-Boot** 加载(`l_agdsp to addr 0xafa00000`,不需要 e5 那套 dd/start),CP 的 `CP voice enabled=True (mask=0x10)` 我们真的收到过,而厂商 `audio_pga.xml` 证明 **24 是本机标称值、ALSA 那个 −94.5 dB TLV 是装饰**;更要紧的是**那次"顶到 0 dB 还是全哑"的听测是脏的**——脚本往 `*_DSP MDG Set` 的 **value[0] = mute** 字段写了 1024(`vbc-dai.c:486-504` 自报 `"mute:%02d, step:%02d"`),等于自己把声音关了。唯一确证的真实缺口:**`ADC_1 Gain ADC_1 Capture Volume` 停在 0,而厂商每个通话场景写 0x07(+21 dB)**,外加从未写过的路由开关 `ADC_1 Mixer MIC1PGA_1 Switch`。**对网络影响:零,本轮没有任何音频改动部署上机。** |
| [`amp-aw87xxx.md`](amp-aw87xxx.md) | **喇叭功放 AW87xxx** | 喇叭哑的真因:**i2c 器件在、驱动从没绑过**;正确源码在 `Enceka/kernel_sprd_ums9158`(我们已有的树里都没有),**已在 5.4.254 上编过**(vermagic 匹配、77 个 `cfi_jt`),固件 `aw87xxx_acf.bin` 已取出;**芯片是 AW87390/AW87391 不是 AW87566**;**但光加载不会响** —— 机器卡 i2c-PA 那条路被 `#if 0` 关着,要照 e5 补丁写 `hook_general_spk_for_aw87xxx()`;⚠ **听筒不经过它,所以通话音频不依赖这个功放**;诚实边界:**还没 insmod、没试听** |
| [`vbc-profile.md`](vbc-profile.md) | **VBC profile 的 ABI 与数据来源** | 通话音频的参数从哪来:24 字节头(`"audio_profile"` + u32 num_mode + u32 len_mode)后跟 `num_mode×len_mode` 字节,**无校验和**;两条装载路(字符设备 / request_firmware)。§3.5 **当天的结果**:odm_a(EROFS)挂上取 XML → 转换 → 写驱动 → 回读,**三份 blob md5 逐字节相同**;记录了四个坑(必须一次大读、busybox 无 `od`、驱动长度≠缓冲长度、**`dd` 块大小必须 ≥ blob**);§5 标了落地进度,剩下 Select 词试错 + 守护进程(依赖 `libasound.so.2`,本 rootfs 没有) |
| [`naming-audit.md`](naming-audit.md) | **命名审计:残余 `mu300` 逐条判定** | 121 个含 `mu300` 的追踪文件逐一判 A(改)/B(保护)/C(存档),**结论 A=0、B=121** —— 全部是受保护名字、第三方 vendored 标识符(整目录快照)、**承重字符串**(补丁上下文/上游 build 挂载路径,改一字节就构建失败)或硬件事实(F50 的型号**就是** MU300);设备可见树的**标识符零残余**(12 个 `changxing60-*` init.d、三个 rpcd ucode、LuCI 菜单/ACL 全换名),**正文仍有 25 处、全 B**(旧路径收养 shim、上游仓库/工具名、硬件型号)——§3.2 是权威清单,那一节早先误写成"零残余"已修正;§8 记了**反向搜**的教训(该保留却被改掉的,得搜受保护名字的新版拼法才抓得到) |
| [`mainline-6.18.md`](mainline-6.18.md) | 6.18 LTS 试验线 | 上游基线接入;已进用户态、CP 首次拉起、卡数据通路;修法在 `mainline-7552n/`(厂商 DTB 纯增量,内核一行不改);Track C 判决:6.18 内屏要自研 |

**Android 侧(非 OpenWrt)模块文档**——设备进 Android 时的另一套,在 `docs/modules/`
(⚠ 这两个子工程**不随 OpenWrt 快照发布**;下面的链接只在完整工作区内可解析,公开仓库里请把本节当作"存在过"的记录):

| 文档 | 主题 |
|---|---|
| [`docs/modules/netproxy.md`](../modules/netproxy.md) | NetProxy 透明代理模块(热点共享接口名 `wlan0`、订阅只供节点不供规则、APK 版本错配根因) |
| [`docs/modules/hotspot.md`](../modules/hotspot.md) | 热点限制解除模块(APEX bind-mount 才有效、`/vendor` EROFS 盖不动、kanokano 站下载法) |

**UFI 面板授权逆向**——另一个独立子工程,在 `docs/ufi/`,有自己的 [`README`](../ufi/README.md) 索引
(同样不随 OpenWrt 快照发布)。

## 历史档案(2026-10-10 归档,结论已被现行文档取代)

下列是 2026-10-10 放弃决定时的设计稿与核对清单,转为只读档案。其中 E1–E37 勘误、备份/回滚工具、
设备身份实测仍是通用排障财富;但**「黑箱/无显示」「5.4 无平台 suspend」等结论已被实测推翻**,读时以现行文档为准。

| 文档 | 内容 | 归档时状态 |
|---|---|---|
| [`port-design.md`](port-design.md) | Phase 1–4 全设计 + E1–E37 勘误日志 + 09-20 / 10-08 时间线 | Phase-2 验收 PASS(9 trial);Phase-3 GPT 已缩容又回滚;Phase-4 未做 |
| [`port-checklist.md`](port-checklist.md) | 可行性核对(机型/存储/SPD)+ 文件级改动清单 + 重分区草案 | 初版核对完成;重分区未持久(已回滚) |
| [`display-design.md`](display-design.md) | 路线 B 显示栈(Phase-D)设计稿 | 设计稿,未执行;**顶部横幅已标注两条前提被推翻**,现行走 `screen-plan.md` |
| [`feasibility.md`](feasibility.md) | 若将来重启移植的路径可行性评估(2026-10-11) | 前瞻评估,非活跃推进;部分路径已被现行 5.4 落地超出 |

> 另:`changxing60-linux/docs/container-architecture.md`(OpenWrt chroot 容器方案,E28–E36)亦已放弃
> (09-20 E35 删光宿主 /dev + E36 卡 boot),在该 gitignored 子树内,仅作参考。

---

## 历史背景(2026-10-10 的放弃决定)

> 这一节记录移植一度被归档的原因与当时得出的、**仍然有效**的经验。结论部分已被上面「现行文档」取代,
> 但「为什么曾放弃」「网络优势误判纠正」仍值得读——避免下次重蹈。

### 放弃理由(2026-10-10 终止决定)

移植方案经 2026-09-20 撤退纯 Android、2026-10-08 重评"维持现状"后,2026-10-10 正式归档。
关键一击是**"5.4 网络比 7.2 稳"这条最后剩的继续推进理由被证伪**(见下节),叠加既有"维持现状"理由,
结论为不值得继续:

- **存储**:7552N UFS 无尾部空闲,无 SD 卡槽(实机确认)→ 唯一存储路径是 GPT 缩容 userdata,
  必然伴随一次恢复出厂(清 /data 全部)。09-20 已回滚原厂全容量,用户否决再缩。
- **身份冲突**:汽水挂机需 Android 在线;双启动同一时刻二选一,Linux 时长=停赚时长。
- **增量有限**:NetProxy 已带规则分流(`docs/modules/netproxy.md`:"规则集质量与订阅同级")
  → OpenWrt 增量仅剩 SQM / 每客户端统计 / 防火墙精细度 / 包生态。
- **黑箱**:7552N 无可用 LED(`/sys/class/leds` 仅哑触发),无显示=纯黑箱,电量只能靠 LuCI 面板。
  *(2026-10-13 推翻:内屏已点亮,见 `screen-plan.md`。)*
- **最后一条理由(网络稳)证伪**:见下。

### 网络优势误判纠正(重要 — 别再把假优势当真)

**错误主张(此前推进 5.4 路线的核心论据之一)**:"5.4 用的是 Android 量产验证的整套网络栈,
所以比 7.2 前向移植版稳。"

**事实**:`changxing60-linux/kernel/build-linux.sh` 第 4 行 `cd /src/zte-u30air`、第 30 行 `$M Image modules`
——94 个 vendor 模块是**从 vendor 源码树重编的**,不是从设备 `/vendor/lib/modules` 拉的 Android
出厂二进制。`changxing60-linux/docs/FINDINGS.md`(行 194)明记 WiFi 驱动 `sprd_wlan_combo` "taken from
the realme C51/C53 AndroidT kernel_modules drop",行 203 "All vendor modules must be rebuilt from
the same tree (symbol CRCs change)"——**符号 CRC 约束使 Android 出厂 .ko 无法直接装到自编内核上,
必须重编**。

**推论**:
- 我们重编的模块与上游 mainline 那套是**同源**(都从 vendor 源码来)。"5.4 用 Android 出厂验证栈"是假的。
- U30 Air 已知最坏的 WiFi 问题里,§31m 硬挂**明确写 "under 6.18"**(mainline 专属);
  §31a `sync_for_device` DMA sync 失效是经典**前向移植回归**特征(5.4 原 DMA API 下不易犯)
  → 结构上 5.4 路径更不容易中这类"挪到主线才犯"的回归,但**未经实测无法断言 5.4 干净**。
- 我们的 9 次 trial **只证明了基础启动 + 网络起来**(udhcpd/telnetd/httpd),**从未做 WiFi 负载压测**
  → 既没有"5.4 WiFi 稳"的实证,也不能声称比 7.2 稳。

**修正后 5.4 真正站得住的优势(去掉那条假的)**:
- ✅ 显示原生(sprd-drm 同代驱动,见 `display-design.md` 顶部横幅 + `screen-plan.md`)
- ✅ boot 已证(9 次 trial,9 循环 0 砖)
- ✅ 用的是原始驱动源码(非前向移植版)——结构性更不易中回归
- ❌ ~~Android 量产验证网络栈~~ —— 撤销,是重编的不是出厂的
- ❓ WiFi 负载稳定性 —— **未测,不知**

**教训**:论证"某路线更稳"前,先查模块是"出厂二进制"还是"源码重编";重编模块不自动继承 Android
量产验证光环。下次评估任何"用某内核栈更稳"的论断,先确认模块 provenance(build 脚本里 `cd` 到哪、
`$M modules` 编的是不是源码树),再下结论。

### 仍值得保留的知识(不是白做)

- **E1–E37 勘误**(见 `port-design.md` §7):WSL interop 损坏二进制(铁律:cp+adb pull,禁 exec-out)、
  UFS LBA=4096、misc slot 字节推导、fw_devlink supplier 链、configfs gadget 函数 / MS OS 描述符、
  Windows NCM 类匹配(DriverStore FileRepository 而非 System32)、busybox httpd 守护化空转……
  这些是 UMS9620 + WSL + Windows 工具链的通用排障财富,移植放弃也仍有参考价值。
- **rescue/ 基础设施**:dumps(boot_ori / misc / GPT)、data-backup/MANIFEST.md、
  `gpt-shrink-userdata.py`、`gen-misc-blocks.py`、`trial-net/` 观察工具——备份与回滚能力仍在。
- **设备身份实测**:UFS YMTC / 6G RAM / upm6910h 充电(sqc_bq2560x 驱动)/ WiFi 固件 _aa/.xpe /
  misc 0xff·0x0f / 无 SD 槽 / 无 LED——任何重启移植的快速核对基线。

### 若将来重启移植的前置条件

翻盘信号(出现任一再重评):①汽水停跑/换机 ②SQM 治上行、端口映射成真需求
③MyOS 模块生态崩坏(system_server 更新杀 root / 模块互踩)④纯项目兴趣。若重启:

> **路径可行性评估见 [`feasibility.md`](feasibility.md)**(2026-10-11):逐条评了
> initramfs-OpenWrt 轻路子 / 全量安装 / 自编内核容器 / mainline 7.2 等分支的可行性、
> 未知数与风险,以及"开机选系统"目标的推荐渐进。本节交代"为何曾放弃",feasibility 交代"若回来走哪条"。

1. `changxing60-linux` 子仓库自成主线 **`mainline-5.4`**(2026-10-18 由 `mainline-6.18` 改名,名字跟随生产内核线;6.18 试验在仓内 `mainline-7552n/` 目录),**不再 rebase 上游 `main`**——发布走仓内 `tools/publish-github.sh`(脱敏克隆)。
2. 重读本节「网络优势误判纠正」,**别再以"5.4 网络更稳"为默认前提**——先实测 WiFi 负载再说。
3. 充电(sqc / upm6910h)、显示(Phase-D)曾是 7552N 特有未解项,需单独验证;现行 5.4 已落地 bq2560x charge-fix 与 sprd-drm 内屏(见 `power.md` / `screen-plan.md`)。
