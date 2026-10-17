# 参照项目 `sprd-linux-devs/e5-linux`:他们做了什么,我们能拿什么

> **状态(2026-10-16)**:由三个独立 agent 直接 clone 仓库(父仓库 + 12 个子模块 + 外挂内核树)
> 读源码得出,不是照抄 README。本文只记**结论与可复用件**;§7 是 `kanoqwq/mu300-linux` 的
> 横向对比结论(已做完)。
>
> 关联:[`cptl-and-boot.md`](cptl-and-boot.md)(它解释了"我们缺 `@modemd` 应答者"),
> [`sipa-wedge.md`](sipa-wedge.md)(我们的病), [`gpu.md`](gpu.md)(我们的 GPU 路线)。

## 0. 结论先行

1. **E5 不是 UMS9620,是 UMS9621**(`ums9158_1h10`,内核原厂 `5.15.119-android13`)。
   **与我们同 SoC 的是它的第三台设备 VIPME M8**(`ums9157_2h10_native` / UMS9620 / qogirn6pro /
   安卓内核 **5.4.210**)—— 要抄 UMS9620 的现场经验,看 `device/linux_device_m8/`。
2. 他们跑的是**主线 Linux 6.18.54 + OpenWrt 25.12.5 / Debian 13**,与我们"厂商 5.4 + OpenWrt"
   是**两条不同的路**,但**蜂窝栈同宗**:都把安卓的 `modem_control` 放进 chroot 去拉 CP。
3. **GPU 他们走主线 panfrost(不是厂商 kbase),而且真跑起来了**(compositor + 客户端都在
   `Mali-G57 (Panfrost)` 上渲染)。这是与我们最有价值的分叉点,见 §3。
4. **最有价值的单件:`e5-modemd`** —— 它正好补上我们缺的那一环(§4.1):
   答 `@modemd` 的 `SLOGMODEM DUMP COMPLETE`,把 CP assert→Alive 从 300 s 压到 4–5 s,**不用重启整机**。
5. **他们以我们为上游模板**:README/Credits 明确致谢 `dikeckaan/mu300-linux`,
   并已采纳我们 **7 个 commit**(共享修复清单见其 `docs/UPSTREAM-SHARED-FIXES-20261012.zh-CN.md`)。
   信息流向主要是 **mu300 → e5-linux**。
6. **`kanoqwq/mu300-linux` 对我们的 WAN 假死没有现成答案**(2026-10-16 三仓对照,§7):
   它的 `main` 是**零独有提交的空 fork**(停在 2026-09-29 的 `1a69a41`),真工作在三个侧分支上;
   那 151 个独有提交里**真正与蜂窝相关的只有 1 个**(`3cbf37fc`,作者自认未上机测过),
   其余是 WiFi/存储/打包,以及把 `dikeckaan` 已有工作 revert 掉再抄回来的循环。
   `dikeckaan` 自己已对这份 fork 做过逐条评审并给出同款结论。⇒ **别在它身上找治法**。

## 1. 项目定位(核对过的)

| 项 | 内容 | 证据 |
|---|---|---|
| E5 本体 | UMS9621 / `ums9158_1h10` / Unisoc T158;原厂 `5.15.119-android13` | `docs/FINDINGS.md` 开头、`kernel/patches/0009` |
| 同 SoC 兄弟 | **VIPME M8 = UMS9620**(`ums9157_2h10_native`,T157,qogirn6pro,安卓 5.4.210) | `device/linux_device_m8/README.md` |
| 系统 | 主线 **6.18.54**(分支 `e5-6.18`,后续 6.19/7.2 跟进)+ OpenWrt 25.12.5 / Debian 13/Phosh | 外挂内核树 `Enceka/linux-lts-e5`(= `sprd-linux-devs/linux` 镜像) |
| 装法 | SD 卡或 `/data` 里 loop 文件;`boot_b` 引导 Linux,安卓留 slot a;`misc` boot-control **与我们同一套** | `docs/FINDINGS.md` §1(逐字节对照并引用我们的结论) |
| 结构 | 父仓库(`boot/`、`upstream/`、`kernel/`(旧 5.15 参考树 + 28 个补丁)、`openwrt/`、`rootfs/`)+ 每设备三层子模块 `linux_device_*` / `debian_device_*` / `openwrt_device_*` | `.gitmodules` |

## 2. 适配清单(E5,按子系统)

子系统状态与证据(全部为 agent 实读文件):显示 **已工作**(`0001/0002/0006/0025`);
**GPU 已工作**(panfrost,§3);触摸 **已工作**(`0028-tlsc6x-single-touch-axes`);
WiFi **已工作**(2.4/5G + 5G 热点;`0007` 是"userdebug 变体 ⇒ assert=carddump"那个大坑);
蓝牙 **除 SCO 麦克风外已通**;蜂窝 **注册/Bearer/短信/VoLTE/双卡已通**(§4);
音频 **实听通过**(`0010–0020`,AGDSP 全套);充电 **已工作**(E5 是 AW32257,**不是**我们的 bq2560x);
**传感器基本没做**;USB NCM gadget 可用;UFS 侧 E5 实为 eMMC,主线下 **userdata F2FS 损坏过 5 次、根因未定位**;
温控 25 个 zone 可读。**明确未做**:系统挂起(其 `docs/STATUS.md` 原话
"System suspend is blocked by the SIPA data path")、GPU 调频(钉 384 MHz)、GSP、pinctrl 全量。

## 3. GPU:他们走 panfrost,我们走 kbase(两条路,各自成立)

- **他们的**:主线 `panfrost` + 自写 `panfrost_sprd.c`(把厂商 kbase 的 `mali_freq_init()`/
  `mali_power_on()`/`mali_clock_on()` 重放:GPLL 强开、PMIC 写 DCDC、解除 force-shutdown、
  DVFS index 写 syscon)。GPU = **Mali-G57(v9/Valhall)**,DT `compatible = "sprd,mali-natt"`;
  厂商 kbase r41p0 **仍在树里但 `=m` 故意不加载**(两个驱动同匹配一个节点,谁先 probe 谁抢)。
  运行证据:`GL renderer: Mali-G57 (Panfrost)`、compositor 与**客户端**都上 GPU、mesa 25.0.7
  (Debian 自带);**无固件 blob**;panfrost 路线下 **`/dev/mali0` 根本不存在**(走 `/dev/dri/renderD128`)。
  没有 Vulkan(PanVK 不含 v9)。
- **我们的**(见 [`gpu.md`](gpu.md)):厂商 kbase **r40p0 重编**,内核侧已实测跑起来
  (`Probed as mali0`、`/dev/mali0`、devfreq 三档),缺的是**用户态 UMD**。
- **可借鉴/不可借鉴**:他们的路证明"G57 的内核侧可以不走厂商 kbase";但对 **OpenWrt/musl** 的我们,
  真正的门槛在**用户态 Mesa**(他们有 Debian 兜着)。若要抄,顺序是"先解决用户态,再换内核驱动"。
  另一条他们踩过、与我们直接相关的坑:**UMD 与 kbase 的 DDK 大版本必须匹配**(r41p0 kernel 只认
  ≤r41p0 的 UMD)——我们取安卓的 `libGLES_mali.so` 时必须验到 **r40p0**。

## 4. 蜂窝/WAN:他们怎么活下来(与我们的病对照)

全仓库(含 12 个子模块)**`cptl` 零命中** —— 与我们 [`cptl-and-boot.md`](cptl-and-boot.md) 的结论吻合。

### 4.1 ⭐ `e5-modemd` —— 直接补我们的缺口

- 位置:`device/openwrt_device_common/src/e5-modemd.c`(160 行 C)+ `overlay/etc/init.d/e5-modemd`
  + `shared/modem-recovery.py`。**勘误**:`modem-recovery.py` **不是**恢复状态机,它只是把 init
  脚本预装进离线 rootfs 的 staging 脚本(还带"拒绝外来 rc.d 链接"的防污染守卫)。
- **谁监听谁应答**(2026-10-16 逐行读源码勘正,这一点很容易搞反):
  socket 是 **abstract namespace AF_UNIX / SOCK_STREAM,地址 `\0modemd`**(`sun_path[0]` 前导 NUL、
  不设结尾——bionic `socket_local_client` 的约定,没有文件系统 socket 文件)。
  **厂商 `modem_control`(chroot 内)是服务端**——建 listen/accept 线程、把状态文本流推给客户端
  (它自己的错误串就是 `Failed to create modemd listen accept thread`);
  **`e5-modemd` 是客户端**,`connect_modemd()` 以 1 s 重试等 socket 出现。
- 协议:`modem_control` 把状态文本**流式**推出,关键 token 是 `Modem Assert` / `Modem State: Assert` /
  **`Modem Blocked`** / `Modem State: Blocked`(后两类 = RIL 报告 AT 服务器挂死),以及只读的
  `Modem Reset` / `Modem Alive`。客户端用 **64 字节滚动后缀窗口**做增量匹配——注释明说
  "read boundaries are not message boundaries",所以能容忍任意切包、容忍带不带尾部 NUL。
- 收到 assert 类 token 就立刻回 `SLOGMODEM DUMP COMPLETE\0`(等于"跳过存 dump、只把应答补上")。
- 前置条件:**没有**。不需要 AT、不碰 NV、不动射频;健康启动时完全静默(其测试断言 0.15 s 内无发送)。
- 附带杠杆:`e5-modemd blocked` —— 主动连上 `@modemd` 发一句 `Modem Blocked` 再退出,
  §47.6 原话 "a CP reset on demand, for an AT server that hangs without an assert"。
  **这正是我们那种形态**(AT 通道死、dmesg 又没 assert、只能重启整机)。
- 效果自述:§30 记修复前每次 assert 吃满 **300 s**;§47.6 记 "Reset to `Modem Alive` in 4-5 s,
  a dozen times today"(2026-09-28)。⚠ 这两条是**他们文档的自述**,我们没独立复核。
- 崩溃语义:服务端关连接后 `return 1`,procd 重拉(`respawn 3600 5 0`,开始 S22/停 K09);
  编译走 `build-rootfs.sh` 的 `gcc -static -Os -s -Wall`(OpenWrt 自己没有编译器)。

### 4.2 AT 通道:他们把"持续 drain"做进了驱动

`kernel/patches/0022` 的 `sipc_wwan` 把 SIPC 的 `stty_nr`(环 1 命令、环 0 URC)包成
`/dev/wwanXat0`,**从加载起持续 drain 两个环**(3 s 不读 ⇒ CP 队列满 ⇒ **assert**,他们实测过三次);
`tx_gap_ms=300` 限速;`0023` 让 AT 口只在 sbuf READY 时注册/注销(CP 复位时 ModemManager 看见
modem 消失又回来);`0024` 丢弃 `<CR>` 后的 `<LF>`。用户态是常驻 AT 守护
(`shared/atd.py` + `at-client.c`,0.3 s 间隔、单飞行、8 s 超时、URC 落日志)。
→ 与我们的 `mobile-data`/独占 `nr1` 那套是**同问题的两种解法**。

### 4.3 「AT 死 ≠ CP assert」与他们记录的「有地址没网」

- **AT 死而不 assert**(§22,2026-09-18 实测):两个 AT 通道全哑、dmesg **0 次 CP assert**、
  没有 `kbc_start_cp`,而**蜂窝 bearer 还在过流量**。原文结论:"So 'the AT channel is dead' and
  'the CP has asserted' are not the same event… A watchdog has to key on AT's silence, not on the
  CP assert appearing in dmesg." —— 与我们"有地址零包、AT 死但未必 assert"**完全同构**。
  他们据此做的 `cp-watchdog`(dead = atd 状态文件的 `last_ok` 超 `DEAD_AFTER` 120 s →
  先落盘证据块 → 重新 arming boot slot → reboot;`GUARD` 900 s 防 boot loop;`ACTION=log` 只观测)
  —— **⚠ 这套后来被他们自己淘汰了**(2026-09-19~26 三步:撤掉 mobile-data 系服务 → 换成
  mu300 血统的 AT 栈 → MM unisoc 插件 + NetworkManager 接管;此后 CP 级复位交给 `e5-modemd`)。
  **别复刻 cp-watchdog 的"AT 哑 → 整机 reboot"**;只值得拿它的**证据块先落盘**和 **GUARD 冷却**两条。

**关于"有地址没网":一条勘误 + 两条有出处的机制。**

> **勘误(2026-10-16)**:本文早期版本写的"**MM 把 APN 放到 CID 12 ⇒ CP 绑到 `sipa_eth11`**"
> **在三个仓库里逐字检索不到**(`CID 12` / `cid=12` / `sipa_eth11` 全部零命中,`sipa_eth11` 只在
> 一份全零的参考 dump 里出现过)。那条叙事已删——**别追这个幻影**。真正有出处、且机制等价的是下面两条。

- **`cid → 网卡` 的映射**(`dikeckaan/docs/FINDINGS.md:824`,原文):
  "`sipa_eth0` (`sipa_eth<cid-1>`, raw IP, `NOARP`)" ⇒ 谁把 bearer 放到高 CID,流量就落在
  一张**没人在用的** `sipa_eth<N-1>` 上(§47.4 同款:认接口别认 `sipa_eth0` 这个名字,要按 card 映射)。
- **真正有出处的「有地址零包」**(`dikeckaan/docs/FINDINGS.md` §13g):下链又死了,计数器与上一次
  **完全一样**;真因**不是 IPA 而是 PDP 上下文掉了**——`AT+CGACT?` 回 `+CGACT:1,0`
  (互联网上下文没了,IMS 的 cid 11 还活着),而**接口上还挂着旧地址**,于是所有"看地址在不在"
  的检查**全部假过**。修法:`mobile-data up` 重拨 cid 1,接口拿新地址后 `rx_packets` 立刻动。
  同节还给了一套**诊断纪律**(极适合抄进我们的 watch):
  1. **先造流量再读表**——"None of these counters mean anything unless traffic is actually
     leaving while you read them"(SIPA 空闲挂起 `suspend_stage=0x3f`、全 Released 是**正常态**不是病);
  2. **两种假象必须排除**:sing-box 的 TUN 会自己应答 ICMP(亚毫秒"成功")、kill-switch 的 `EPERM`
     读起来像 modem 拒收 —— 两个都在骗 `ping -I <蜂窝地址>`;
  3. **最不撒谎的廉价测试**:"Resolve a name against the address `AT+CGCONTRDP` hands back and
     watch `rx_packets`."
  ⇒ 这**是**"上下文/接口失配"那类病的正确修法(上游 e5 把它硬化成了 `watch_context_state`
  显式三态,见 §5(a) 第 3 条)。
- **注意症状方向**:上面这条是**"通着通着上下文掉了、地址还旧"**(和我们的病同构),
  而"从来不通"(bearer 一上去就绑错网卡)是另一回事——两者像,别混。
- `sipa_eth0` 的 **checksum offload 必须关**;M8 首次 PDP 激活失败(error 28)重试 2 次。
- **加载期 SIPA 补丁**(`sipa.py`/`sipa-data-path.patch`/`sipa-tx-retry.patch`):修
  `sipa_dele_cp_in_ap.c` 的 enable 幂等/失败 ACK/PM-runtime 重试循环、`power_lock` 串行化、
  `sipa_eth` 队列锁/校验和重算 —— **与我们 changxing60 的 einprogress/pm-runtime 两条补丁是同一批问题**,
  值得逐字 diff。
- 5G:NR SA 可跑(`+CEREG AcT=11`,~50 Mbit/s);**双卡不带频段锁每 15–30 s CP assert**(安卓侧同病)。

## 5. 可执行清单(按优先级;来源全部为上表路径)

> 2026-10-16 由三仓对照(本节 + §7)重排过一次:每条都标了**证据出处**与**我们这边落在哪个文件**,
> 并区分「他们文档自述」与「我方能独立复核」。铁律照旧:**报成功前必须实测**。

**(a) 现在就能做、风险低**

1. **⚡先做零成本的一步:开机后 `grep modemd /proc/net/unix`**,分清 §4.1 那两种局面
   ——(一)我们的 `modem_control` 根本没建出 `@modemd` 监听,还是(二)建了但没人应答。
   这一眼决定后面走 B5 还是走本条。**在此之前不要写任何代码。**
2. **移植 `e5-modemd`**(治「没人应答」那半边),把「CP 不吃 DONE」从**整机重启**降级为
   **CP 级复位 4–5 s**。
   - 做什么:`gcc -static -Os -s -Wall` 编(OpenWrt 无内建编译器,上游就这么干);落
     `/usr/sbin/changxing60-modemd`(守护模式)+ 同一二进制的 `blocked` 子命令;procd init
     (`respawn 3600 5 0`,S22/K09);把 `tests/modem-recovery.py` **一起搬**(它能在主机上真跑
     那 160 行 C:连私有名字的 abstract socket 回放全流程,含逐字节切包)。
   - 我方落点:`changxing60-linux/rootfs/overlay/usr/sbin/` + `rootfs/overlay/etc/init.d/`
     + `openwrt/build-rootfs.sh` 编译段 + `rootfs/overlay/opt/changxing60/bin/mobile-data`(watch 分支)。
   - **先做"只监听不应答"的探针版**观察一次真实楔死时 `@modemd` 上到底有什么,再开放应答
     ——错答有在**不该复位时复位**的风险。
   - `blocked` 子命令挂自动判决时**必须复用第 3 条的防抖**,否则"AT 慢"会被误判成"AT 死"→ 复位循环。
   - 验证:守护进程打印 connected;一次自然 assert 后 `Modem Reset`→`Modem Alive` 在 ~5 s 内出现
     (对照过去的 300 s);`/root/selfheal.log` 记 rc 与前后 `run_state`(遥测我们已有)。
3. **判决与防抖纪律三合一**(e5 `e5-bearer-watch`/`e5-bearer-up` + `dikeckaan` §13g + kanoqwq
   `3cbf37fc`),直接改 `mobile-data` 的 `watch()`:
   - 判死只看**驱动手流量 + `rx_packets`** 与 `AT+CGACT?` 的**显式三态**:
     `$CID,1`=活跃(再比 `AT+CGPADDR` 与接口地址,不一致先 `ubus renew` **原地续租**而非重拨)、
     `$CID,0`=显式脱附(才走恢复)、**AT 失败/空/不可解析 = 不判死、不计数、绝不动射频**;
     `AT+CFUN?` 必须显式回 0 才允许动射频。
   - 每次动作前落**证据块**(uptime、CGACT 原文、计数器快照);整机重启类动作加 **GUARD 900 s**
     防"自愈循环变 boot loop"。
   - 反面教材就在上游:其 `e5-bearer-up` 注释点名早先的 **6 s 循环把 AT 灌到 CP 不应答、开机都开不完**;
     他们据此把 watcher 从 30 s/每分钟 4 条降到 ~1 条每分钟才稳。**我方 30 s 探针的 AT 量要核一遍。**
   - 验证:人为 `AT+CGACT=0,1` 掉上下文 → 一分钟内重建;人为制造 AT 拥塞 → watch 不再误判射频死。
4. **常驻 URC 环 drain + AT 单主人/防灌爆**:把 `nr0`(URC 环)交给一个永不退出的轻量 drain
   (日志 **256 KiB 轮转封顶**,护 eMMC),AT 命令收口到单点,**命令间隔 ≥300 ms**,
   `AT+CGDATA` 超时 **≥45 s**(8 s 等不起 CONNECT 是"AT 假死"假象的一大来源)。
   - 依据:上游 §22 部署后**同日实测 CP assert 0 次**(此前 ~9.5 分钟必 assert)——
     但他们自己也诚实标注"持久通道与降频两个变量混在一起,不能断言哪个是功臣"。
   - 换主人前后要**扫 fd 确认通道空闲**(其 §25.5 红线),别和现役探针抢。
   - 我方落点:`rootfs/overlay/opt/changxing60/bin/changxing60-at`(或新增 `changxing60-urc-drain`)。
5. **读他们的 `docs/FINDINGS.md` §13/§22/§25/§30/§36/§37/§47** 与 §14.1 全套 AT 命令形状
   (`AT+SPLBAND`/`AT+SPFORCEFRQ`/`AT+SPACTCARD`/`AT+SPSWDATA`/`AT+SPTESTMODEM`)——
   目前公开资料里最好的 UMS9xxx modem AT 面手册。§13 那张表尤其重要:**它列了运行 chroot 里
   Android 二进制的四要素**(property area 属主必须 `root:root`、必须有 logdw sink、节点权限按
   `ueventd.rc`、`/proc/cmdline` 的 `slot_suffix=_a` 要 bind、且**必须 `exec chroot` 直接跑
   Android ELF,不得经 linker64**)—— 正是 B5 的对照清单。
6. **对照 `device/linux_device_m8/`**(同 SoC 现场):`prepare-kernel.py`(UMP962x regulator
   compatible 坑)、`usb.py`/`dwc3-role.h`、`charger.py`(**明确警告 BQ2560x REG0E 的 VREG 编码
   不能套 E5 的语义** —— 与我们 [`power.md`](power.md) 的 REG04 结论互为印证)。

**(b) 值得做但要实验**

7. **B5:`modem_control` 到底为什么不监听 `@modemd`** —— 第 2 条的**总开关**。
   对照 §13 四要素补齐我方 chroot(`rootfs/overlay/opt/changxing60/android-vendor-start`),重启后
   再看 `/proc/net/unix`;若仍不出现,diff 我方与上游的 `modem_control`(字符串同源但版本可能不同)。
   风险:动 chroot 启动顺序;失败无副作用(退回现状)。
8. **内核级双环 drain(`sipc_wwan` 补丁打进 5.4)**:上游 `0022` 的补丁头原文写了现场——
   "a ring nobody reads fills within seconds… **and the CP asserts** (`MN_AL Task PS … queue was
   full`) **-- it did three seconds into a handover**",所以**从模块加载起就 drain 两个环**;
   同补丁还有两条铁律:**ring 0(URC 环)绝对禁止写**(写了会让 AT 服务器全体噤声直到重启)、
   `tx_gap_ms` 默认 300。配套 `0023`(端口跟随通道,1 s 周期 watch work)、`0024`(丢掉 `<CR>` 后的 `<LF>`)。
   比第 4 条强一档:**用户态全崩也保 CP 不 assert** —— 正好打我们"用户态探针死了以后的事"。
   风险:他们的版本基于 6.18 源树,我方 5.4 sipc 要适配;`card=`/`AT+SPACTCARD` 是双卡语境,单卡可先不带。
9. **ModemManager unisoc 插件整套**(`rootfs/deb-patches/modemmanager-01~16-unisoc-*.patch` +
   `openwrt/build-modemmanager.sh` + 三个 openwrt 包补丁):禁 `ATZ`/`+CPMS=`/`+CFUN=0` 黑名单、
   CESQ 九字段、M-ETHER bearer、CID↔`sipa_eth` 绑定、双卡/SMS 隔离 —— 若把 WAN 从裸 AT 脚本
   升级到 MM/netifd,这是完整配方(含"在容器里给官方 SDK 打补丁重编"的 OpenWrt 打包法)。
   注意命名陷阱:**MM 只读 `77-*`~`80-*` 的 udev 规则文件名**(他们踩过 `78-mm-e5-sipc.rules`)。
   体系级换轨,**只适用于我方 `mainline-6.18` 试验线,5.4 vendor 线不适用**。
10. **加载期 SIPA 补丁逐字 diff**:把他们的 `sipa-data-path.patch`/`sipa-tx-retry.patch`
    与我们已装的两条补丁对读,看有没有我们漏掉的**那半边**(enable 幂等/失败 ACK/PM-runtime 重试循环/
    `power_lock` 串行化/`sipa_eth` 队列锁与校验和重算)。可借鉴其纪律:**上下文逐字匹配才允许打 +
    全序列 `git apply --reverse --check`**。
11. **`upstream/wrap-image.py` + `trial-from-openwrt.sh`**:若将来做 6.18 探索(我们已有
    `mainline-6.18` 试验线),他们的"LK 把内核拷到 `0x80080000`、stub 搬到 2 MiB 对齐
    `0x80200000`"这个坑已经解过。

**(c) 不适用 / 别照抄**

12. **panfrost 换掉 kbase**:见 §3 —— 对 OpenWrt/musl 的我们,门槛在用户态 Mesa,不在内核。
13. **复刻 e5 的 `cp-watchdog`**:**不要**。它在上游**已被自己淘汰**(见 §4.3),且其"AT 哑 → 整机
    reboot"语义比我方现有的 停/起 + 90 s 重启更暴力。只吸收**证据块先落盘**与 **GUARD 900 s**。
14. **追"CID 12 / `sipa_eth11` 绑定"的字面问题**:**不要**(三仓无此原文,见 §4.3 勘误)。
    真实机制已由 `sipa_eth<cid-1>` 映射与 §13g(上下文掉了、地址陈旧)覆盖。
15. **他们的悬挂/省电策略**:他们自己的 suspend 被 SIPA 挡着,没有可抄的省电结论。
16. **`/proc/cptl`**:两边都没有,别在这上面花时间(见 [`cptl-and-boot.md`](cptl-and-boot.md))。

## 6. 我们与它的关系(方向别搞反)

- `docs/E5-BUILD-REFERENCE.md` Credits 段原文:*"The approach, repository layout and several scripts
  are derived from dikeckaan/mu300-linux (MIT)"*;`docs/UPSTREAM-SHARED-FIXES-20261012.zh-CN.md`
  记录把我们 **7 个 commit** 落到三台设备;`CHANGXING60-DASHBOARD-BACKPORT-TASKS.zh-CN.md` 是反向的
  backport 任务单。⇒ **我们不是"抄它",而是"它抄了我们一部分、我们去看它多走的那几步"**。
- 也正因如此,它的 `sipa.py`/PM-runtime 那批修**与我们同源**:两边独立撞上同一批问题,
  可互为验证(他们的修复用的是"上下文逐字匹配才允许打、并全序列 `git apply --reverse --check`"的做法,
  我们的 `tools/*.patch` 可以借鉴这个纪律)。

## 7. 三仓横向对比:`kanoqwq/mu300-linux` 里有没有我们要的答案(**2026-10-16,已做**)

三个仓库都真 clone 到 `/tmp/changxing60-compare/{kanoqwq,dikeckaan,e5}` 后按 git 事实判的,不是读 README。

### 7.1 拓扑(git 实测,可复核)

| 事实 | 数值 |
|---|---|
| `kanoqwq/main` 的 HEAD | `1a69a41`,2026-09-29 08:45(+0300),作者 **Abdurrahman Kaan Dikeç** |
| `kanoqwq/main` vs `dikeckaan/main` | **领先 0 / 落后 905** ⇒ `main` 是**零改动的空 fork**,就是上游那天的快照 |
| `dikeckaan/main` 当日 tip | `51898a45`,2026-10-16 04:43,"Merge pull request #254" |
| kanoqwq 的真工作 | 全在**非默认分支**:`clean-tf-7.2`(当日仍在活动,54 个独有提交)、`luci-app-changxing60`(91 个,其中 45 个 kanoqwq 署名、**44 个 `ZCode (GLM) <zcode@z.ai>` 署名**)、`luci-app-changxing60-standalone`(6) |
| 三个分支合计独有提交 | **151** |

那 44 个 "ZCode (GLM)" 提交是**另一条第三方 F50/MU300 家族移植线**(2026-09-26/27),与我们的历史
无交集(我方 `changxing60-linux` 全部历史作者只有 `6Leokk`);`luci-app-changxing60` 里还有一整段
"Revert ~40 条 dikeç 的改动 → 再 Reapply 一部分"的倒带重种。

### 7.2 结论:**没有现成答案**

- 151 个独有提交里,**真正与蜂窝相关的只有 1 个**:`3cbf37fc`(mobile-data `watch()` 状态机硬化:
  `watch_context_state` CGACT 三态 + `watch_radio_if_off` + 地址不一致走 `renew` 原地续租;
  附 `tests/test_cellular_mobility.py`)。**作者自认"只做离线验证、未部署 MU300 实机"**
  —— 已并入 §5(a) 第 3 条作参考。
- 名字最像的两个反而是**名不符实**:`0438ab01` "backport modem reliability improvements" 实为
  权限/TF 检测/升级锁/温控/短信/内核打包 + eMMC DMA;**`23361cea` "backport network recovery fixes"
  实为 WCN/WiFi 驱动 + RA 前缀弃用**。
- `dikeckaan` **已经自己审过这份 fork**:`docs/superpowers/reviews/2026-10-11-kano-clean-tf-7.2.md`
  (174 行),原话 "**Much of the fork's runtime and driver work is our own work going round in a
  circle.** f092671 and 23361ce say 'backport upstream', and upstream is this repository."
  (kanoqwq 说的 backport,就是 dikeç 自己的修复被 revert 后又抄回来。)逐 commit 判词多为
  "none/not ported";它认可的唯一上游欠缺项是 kanoqwq 的 "verified lock reset"(含 tombstone 防中断)。
- kanoqwq 与 e5 双向有往来(`e5` 有 `Merge pull request #2 from kanoqwq/main`;
  `23361cea` 内明写 backport "from E5"),但**都不是治我们这种病的**。

### 7.3 诚实边界

- 上表数字全部本地 git 命令实测;`git diff --stat dikeckaan/main kanoqwq/main` 那 724 files /
  +3 782 / −265 471 是**dikeç 九百多提交对 fork 点的累计**,**不是** kanoqwq 的工作,别误读。
- kanoqwq 的 151 个独有提交**没有逐条读 diff**(按主题检索 + 抽查 + dikeç 评审交叉覆盖),
  不排除个别小 hunk 未归类。
- e5 侧"4–5 s 复位十几次""300 s 超时""atd 部署当日零 assert"等**全是其文档自述**,我们未独立复核
  (且记录大多来自其 UMS9621 的 E5,我们的 SoC 是同代但更老的 UMS9620/UMS9157)。

### 7.4 相关人员/仓库

- `dikeckaan/mu300-linux` = 我们工程的上游(我们自己的 `changxing60-linux` 与它同源)。
- `sprd-linux-devs/e5-linux` = 走了最远的参照项目(**它抄我们**)。
- `kanoqwq/mu300-linux` = 空 fork 在 `main` + 三个侧分支;**对 WAN 假死无独立贡献**,可以不用再跟。
