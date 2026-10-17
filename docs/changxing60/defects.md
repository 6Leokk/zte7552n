# changxing60 — 代码缺陷记录 (defects)

> **状态(2026-10-17)**:本文件是「开机 review 代码、记录我们的缺陷」的产物。方法:派 4 个只读
> subagent 分区审(LuCI 面板 / 设备侧脚本 / rootfs+tools / 内核补丁+构建脚本),再由我逐条复核
> 去重、补验证、按"会不会影响网络"打标(对齐 [`state-2026-10-17.md`](state-2026-10-17.md) 的判据)。
> **这里是"记录",不是"修"**——每条只给失效场景与建议改法,改不改、改哪条由用户决定;版本收束的
> 铁律仍是"网络必须保持可用",恢复任何改动前先读 state 文档。
> **10-17 晚间状态**:H1(音频 guard 补丁)与 H4(vbc before-snap 开机 panic)经用户点头后**当晚已修并实测**;
> H4/L14/L15 为 E1 上机过程新发现,合计从 26 → 29。

## §0 怎么读这份文档

- 每条缺陷:**文件:行** → 失效场景 → 🔴/🟡/⚪ 影响网络? → 建议改法。
- 🔴 = 会直接断网/热点/拨号链路;🟡 = 间接或仅在边角条件下咬到网络;⚪ = 与网络无关(UI/工具/资源泄漏)。
- 「已知?」列:标 `state §x` 的是 state 文档已记录的;**NEW** 是本次 review 新发现的。
- 严重度:**HIGH**(数据损坏/不可恢复/安全)/ **MED**(功能失效或静默吞错)/ **LOW**(健壮性/卫生)。
- 结尾 §5 列了本次推翻掉的「假缺陷」,免得下次又当真。

## §1 汇总

| 严重度 | 数量 | 其中 🔴 影响 WAN/热点 | 备注 |
|---|---|---|---|
| HIGH | 4 | 1(直接)+1(构建期)+1(开机 panic) | 音频 oops 根因 + vbc before-snap(H4,当晚新增) + 两个工具/容器的静默失败 |
| MED  | 10 | 6 | 含 1 条被汇总 agent 漏掉、我补验证的 teardown 硬编码 |
| LOW  | 15 | 1(🟡 边角) | 多为 `|| true` 吞错、引用泄漏、陈旧凭据;L14/L15 是 10-17 晚救机过程新记 |
| **合计** | **29** | | 4 HIGH / 10 MED / 15 LOW(评审当日 26 条 + E1 上机当晚补 3 条) |

**按"影响网络"重排的优先级(若用户决定动手,先动这些)**:
1. 🔴 `90-changxing60:39` exit 0 吞 net-split 失败(MED,NEW,但机制与 10-16 那次热点没地址同源)
2. 🔴 `changxing60cell.sh:24` proto setup 无 timeout(MED,NEW,WAN 卡死)
3. 🔴 `changxing60cell.sh:112-115` teardown 硬编码 sipa_eth0(MED,NEW,我补验证;目前 ifname 恒为 sipa_eth0 故未发作,latent)
4. 🟡 `changxing60-hw:45` reset_dump 写失败静默(LOW,NEW,assert 策略留在 dump → 热点静默死)
5. 🔴 `vendor-modules` bisect_verdict 不在默认路径调(MED,NEW,good-set 变杀手→boot loop→回落 Android)
6. 🟡 `wan-keepalive.sh:33` awk 只加第一个文件(MED,NEW,rx 死 tx 活会判成"有流量")
7. 🔴(构建期)`build-wlan.sh:6` patch 失败被 `|| true` 吞(MED,NEW,WiFi 补丁静默缺失)

---

## §2 HIGH

### H1. 🔴(构建期)音频 oops 根因没有任何补丁处理 — NEW(**2026-10-17 勘误:要补的文件换了**)
**文件**:`kernel/patches/audio-*.patch`(全部 6 个都不碰出问题那行)。
**勘误**:本条原先写"根因 `saudio.c:543`"。`saudio.ko` 虽然由 `kernel/build-audio.sh:118` 编进镜像、也在 `/proc/modules` 里,
但它 **refcount 0、`/sys/bus/platform/drivers/saudio/` 下没有任何绑定设备、DT 无 `unisoc,saudio` 节点** ⇒ 从没 probe。
当事的是 **`sprd-dmaengine-pcm.c:1135`**(`runtime->dma_bytes = totsize;`,driver `.name="sprd-pcm-audio"`,
`/sys/bus/platform/drivers/sprd-pcm-audio/` 下确实绑着 `sprd-pcm-audio`/`sprd-pcm-iis`)。详见 `audio-oops.md` §3 与 `conflicts.md` §6 E1。
**失效场景**:`sprd_pcm_hw_params()` 把 `dma_bytes` 写成**上层请求值**,而 `hw:0,0`(`FE_ST_NORMAL_AP01`)的**录音**缓冲
是一块**固定 IRAM carve**(`is_normal_cap_use_iram()` 为真;本机 `/proc/asound/card0/sprd-dmaengine` 实测
`test_normal_cap_use_iram 0x1`),`buffer_bytes_max` 又 advertised 到 228 KiB ⇒ core `pcm_native.c:746-752` 那句防信息泄漏的
`memset(dma_area, 0, PAGE_ALIGN(dma_bytes))` 写穿映射(`pte=0`、故障地址=基址+恰好 2 页),
`CONFIG_PANIC_ON_OOPS=y`(且 `boot/init:85` 我们自己又写了一次)→ 复位。
6 个音频补丁只盖症状(period timer、AGCP-sleep 指针、MCDT 时钟、格式表、codec defer),**没有一个动 `runtime->dma_bytes`**。
**影响网络**:🟡(oops → 复位 → 网络中断一轮;且这正是挂起的通话音频攻坚项的直接成因)。
**建议**:给 `sprd-dmaengine-pcm.c:1135` 打补丁——用预分配缓冲的真实大小(或 `min(请求, 实际)`)并拒掉超限请求;
**纯源码,不需要设备**。落地前先看下面的 H1-vs-M2 顺序。
**已落地(2026-10-17 晚,用户点头)**:`kernel/patches/audio-pcm-prealloc-guard.patch` 进 `kernel/build-audio.sh`
注册表,ko(`1ee9ed78…`)上机、一次重启装载,实测 dmesg `buffer_bytes 19200 exceeds preallocated 7680 … refusing`
+ `-EINVAL`、内核存活;carve 定案 7680。细节 `conflicts.md` §9 行 9、`audio-oops.md` §7.4。

### H2. ⚪ 容器 service.sh 空 pid 判成"已在运行" — NEW
**文件**:`container/apatch-module/changxing60-openwrt/service.sh:28-30`。
**失效场景**:`$RUNPID` 存在但为空时,`$(cat "$RUNPID")` 为空,`[ -d /proc/ ]` 命中字面量 `/proc/`
目录,函数 echo `"container already running (pid )"` 并 `return 0`——容器永远不起,退出码干净。
**影响网络**:⚪(这是 apatch 容器化 OpenWrt 那条部署线,不是设备主 OpenWrt;但会让"装不上"长得
像"装好了")。
**建议**:`pid=$(cat "$RUNPID" 2>/dev/null); [ -n "$pid" ] && [ -d "/proc/$pid" ] && { echo "already running (pid $pid)"; return 0; }`。

### H3. ⚪ verify-usb.sh 的密码分支是死的 — NEW
**文件**:`tools/changxing60-verify-usb.sh:15-16,32`。
**失效场景**:注释仍写"rootfs 密码为空",第 32 行用 `sshpass -p ''`。密码 2026-10-16 已从空改为非空
(真值不进仓库,在主机 `~/.changxing60-secrets`),
密码回退分支**静默死掉**,只剩密钥那条路能用。与 `deploy-pending.sh`(支持
`CHANGXING60_PASSWORD`/`_FILE`)不一致。
**影响网络**:⚪(工具;但恢复/排障时会把"密码分支没走通"误读成"设备不在 USB 上")。
**建议**:对齐 `deploy-pending.sh` 的 env 变量口径,或至少更新注释 + 删掉死的 `sshpass -p ''` 分支。

### H4. 🔴 `changxing60-vbc-load` 的 before-snap 读未加载的 `/dev/vbc_turning0` ⇒ 开机服务自己打死开机 — NEW(**2026-10-17 晚 E1 上机当晚发现,当天已修**)
**文件**:`rootfs/overlay/opt/changxing60/bin/changxing60-vbc-load`(开头的 `snap "$TMP/before"`)、
`tools/voice/changxing60-vbc-dump`(头注释把"未加载 ⇒ ENOMEM"泛化到全部四个 turning 节点 —— 对 turning0 **为假**)。
**失效场景**:S20 `changxing60-audio` 第一次真正开跑(符号链接 16:52 才建)→ vbc-load 为了幂等比较先快照"现状"
→ dump 对 `/dev/vbc_turning0` 发 262144 B 整读 → 此时 audio_structure 从没进过 kernel、data 指针 NULL,而
`vbc_turning_structure_read` **没有判空**(turning1–3 判了,答 ENOMEM;≤24 B 走 header 分支也安全 ——
所以 voice-audio 的 24 B 探针没事)→ 0x18 NULL 解引用 oops(`Comm: dd`,PID 6713)→ `panic_on_oops=1` → panic 落
Android(boot X)。`vbc-load` 尾部的 after-snap 是**同型第二处潜在点**(audio_structure 没写进去时照样读)。
**影响网络**:🔴(整机不可达;每次重启都过这行,不自愈)。
**修法(当天已落地)**:marker 门 `/tmp/changxing60-vbc-loaded` —— snap 只在标记存在时执行;audio_structure
**写成功那一刻** touch(不等 verify 结束,否则 after-snap 自己被门死);vbc-dump 独立运行门住 turning0
(`CHANGXING60_VBC_ALLOW_UNLOADED=1` 是给 Android 侧 dump 的显式越权);README 顺手改掉"回写用 bs=65536"那条
会踩两次-write 坑的示例。验证:主机 `tools/voice/test-vbc-load.sh` **31/31**;设备实测拒绝消息逐字、1/2/3 ENOMEM、
`--check` 零读、uptime 未断、dmesg 零新增。全文 `conflicts.md` §10。

---

## §3 MED

### M1. 🟡 voice.js 拨号 keydown 监听重复绑了两份 — NEW
**文件**:`openwrt/overlay/www/luci-static/resources/view/changxing60voice/voice.js:326-333`。
**失效场景**:回车触发 `dial()` 两次:第二次撞已占用的 job 被拒,页面把"Dialing…"覆盖成"通话没拨
出去,再试"。**电话其实拨出去了,却告诉用户没拨**。
**影响网络**:⚪(拨号链路本身是通的;但 UX 会让人误判设备坏了)。
**建议**:删掉重复的 keydown 绑定。

### M2. 🟡 audio-pcm-period-timer.patch 移除了原本防住"双 ALSA 客户端"的停顿 — NEW
**文件**:`kernel/patches/audio-pcm-period-timer.patch:63-103`。
**失效场景**:`period_timer=true`(默认)让单路 `aplay`/`arecord` 靠 hrtimer 连续流(AGCP DMA IRQ 不
发,补丁前只发一簇就阻塞)。那个停顿正是让 `audio-oops.md` §6 的"并发 arecord+aplay"场景平时不可达
的天然屏障;**补丁落地后该 oops 路径比补丁前更可达**,而 H1 还没修。
**2026-10-17 补一句**:按 `conflicts.md` §6 E1 的更正,**并发本来就不是那次 oops 的必要条件**
(单个 `arecord` 请求比 carve 大的 buffer 就够)——所以这个补丁的作用是"让测试更容易跑到那条路",
不是"创造了那条路"。本条仍成立,只是严重度的理由要按 H1 的真实机制读。
**影响网络**:🟡(同 H1;oops→复位→网络一轮中断)。
**建议**:先落地 H1 的 `sprd-dmaengine-pcm.c:1135` 修,再留这个 timer;或在此之前给 card 0 加单客户端门禁。

### M3. ⚪ aw87xxx-hook 补丁孤儿 + 文件名对不上 — NEW
**文件**:`kernel/patches/audio-sprd-card-aw87xxx-hook.patch` vs `kernel/build-audio.sh:70-74`(apply 列表
不含它)vs `tools/build-aw87xxx-54.sh:37`(指向不存在的 `0012-aw87xxx-hook-without-gpio.patch`)。
**失效场景**:编出来的功放模块加载了但 `hook_general_spk` 仍落到死的 `#if 0` GPIO 路径("gpio is
invalid!"),喇叭哑。两个脚本互相矛盾。
**影响网络**:⚪(听筒不经过它;通话音频不依赖此功放——见 `amp-aw87xxx.md`)。
**建议**:在 `build-audio.sh` 的 apply 列表加 `audio-sprd-card-aw87xxx-hook`,并改正 `build-aw87xxx-54.sh:37`
的文件名。

### M4. 🟡 `changxing60-dp-enable.c` parent_of() 泄漏 device 引用 — NEW
**文件**:`kernel/changxing60-dp-enable/changxing60-dp-enable.c:24-30`。
**失效场景**:`of_find_device_by_node`/`bus_find_device_by_of_node` 内部都 `get_device`,函数只
`of_node_put`(放节点引用)就返回 `dev`(仍持 device 引用);`of_platform_device_create` 再叠加一份。
PMIC SPI 设备永生,实际影响=每次 scope 漏一个引用。
**影响网络**:⚪(显示路径)。
**建议**:`of_platform_device_create()` 返回后 `put_device(dev)`(pdev 自持一份)。

### M5. 🔴 `changxing60cell.sh` proto setup 无 timeout — NEW
**文件**:`openwrt/overlay/lib/netifd/proto/changxing60cell.sh:24`。
**失效场景**:`out=$(CHANGXING60_NETIFD=1 /opt/changxing60/bin/mobile-data up $apn …)` 无 `timeout`,
且 proto 没用 `proto_run_command`(netifd 可监管的那个)。CP 楔死时 mobile-data 自己的 AT 超时不一定
发(CP ~每 16 min 楔一次,`AT+CGDATA` 阻塞通道 10–20 s,楔死的 CP 永不返回)→ proto setup 无限挂 →
wan 卡在 setup。
**影响网络**:🔴(WAN)。
**建议**:`out=$(timeout 120 /opt/changxing60/bin/mobile-data up $apn 2>/tmp/changxing60cell.err)`;
exit 124 当 ATTACH_FAILED。`busybox-bin` 带 `timeout`(build-rootfs.sh 已装),只是这里没用。

### M6. 🔴 teardown 硬编码 `sipa_eth0`(我补验证;汇总 agent 漏了) — NEW
**文件**:`openwrt/overlay/lib/netifd/proto/changxing60cell.sh:112-115`(对照 setup `:39`/`:44`/`:78-92`)。
**失效场景**:teardown 把 `dev sipa_eth0` 写死 4 次,而 setup 从 `mobile-data up` 的 `IFACE=` 动态解
`ifname`、其余全用 `$ifname`。一旦 mobile-data 报出别的接口名,teardown flush 错设备,真实 bearer 上的
SLAAC 地址/路由(运营商 RA 给的 infinite lifetime)会在每次重拨上堆叠。
**影响网络**:🔴(WAN,latent)。目前 `ifname` 恒为 `sipa_eth0`(本机唯一 bearer),故**未发作**,但
属定时炸弹。
**建议**:teardown 也解 `ifname`(从 `mobile-data down` 输出或一个状态文件),或让 `mobile-data down`
自己 flush bearer。

### M7. 🔴 `90-changxing60:39` exit 0 吞 net-split 失败 — NEW(机制同 10-16 热点没地址)
**文件**:`openwrt/overlay/etc/uci-defaults/90-changxing60:36-39`。
**失效场景**:`sh net-split || logger …` 后**无条件 `exit 0`**。`||` 让 logger 在失败时跑(logger 恒返
0),复合语句恒 0。uci-defaults 跑完 `exit 0` 就**删脚本**,于是 net-split 任何失败都是永久的——下次开
机不重试,热点永远没防火墙 zone(客户端关联、四次握手全过、就是拿不到地址)。2026-10-16 的 mode-bit
事件是其中一个触发;`sh` 修了那一个原因,但**别的 net-split 失败仍被吞**。
**影响网络**:🔴(热点)。已知机制(`script-mode-bit-trap` 记的那次),但"无条件 exit 0"这个一般化
缺陷是新记的。
**建议**:`rc=$?; [ $rc -ne 0 ] && logger …; exit $rc`(上面的 UCI 提交在 `uci -q` 下幂等)。

### M8. 🔴 vendor-modules 的 bisect_verdict 默认路径不调 — NEW
**文件**:`openwrt/overlay/opt/changxing60/bin/vendor-modules:187-196`(对照 `:90-93,109,135`)。
**失效场景**:`load_good()` 每 boot 写 `TRYING good-set`/`OK good-set`,注释(`:90-93`)说这对"捕获
一旦整组装上就杀内核的模块"——但 `bisect_verdict()`(检测死的 TRYING、从 `$GOOD` 里踢最后那个)**只
在 `bisect()`(`:135`)里调**,而 `bisect()` 要手动建 `/etc/changxing60/vendor-bisect` 标志才跑。默认
路径(`case ""`→`:196`)调 `load_good` 却从不调 `bisect_verdict`。一旦 `vendor-good` 里某个模块在内
核变动后开始杀内核,同一份 good-set 每 boot 装同一份 → boot loop → misc-slot 重试耗尽 → 回落 Android,
无模块级自愈。
**影响网络**:🔴(boot loop = 没网)。
**建议**:默认路径在 `load_good` 前调 `bisect_verdict`(幂等——无死 TRYING 时返 0)。

### M9. 🟡 `wan-keepalive.sh:33` awk 只加第一个文件 — NEW
**文件**:`tools/changxing60-wan-keepalive.sh:33-34`。
**失效场景**:`tot=$(awk 'NR==1{print $1+$2}' rx_packets tx_packets)`——`NR==1` 只在**第一个文件**的第
一条记录触发,每个统计文件每行一个数,所以 `$2` 恒空,`tot` 只拿到 rx_packets,tx 被静默漏掉。watch 靠
`tot` 跨轮比较判"零流量",于是**rx 死、tx 活**会判成"有流量"(看着活其实半死)。
**影响网络**:🟡(WAN 探测假阳性;但 SIPA 自愈重启仍会兜底,只是判据不干净)。
**建议**:`awk '{s+=$1} END{print s}' /sys/.../rx_packets /sys/.../tx_packets`。

### M10. 🔴 `build-wlan.sh:6` patch 失败被 `|| true` 吞 — NEW
**文件**:`kernel/build-wlan.sh:6`。
**失效场景**:`for p in /work/patches/wlan_combo-*.patch; do patch -p1 --forward < "$p" || true; done`
吞掉所有 apply 失败。某个 `wlan_combo-*` 补丁上下文漂移(SC2355 源码 drop 动了)→ 模块静默缺修、构建
不报错,下游 vermagic 检查照样过。这是项目反复踩的"log/退出码说 OK、现实不是"那一类
(`drivers.md` §4.1.1)。
**影响网络**:🔴(构建期;WiFi 补丁静默缺失→热点可能坏,但只在补丁上下文漂移时咬)。
**建议**:去掉 `|| true`(让 `set -e` 接),或显式检查 `patch` 退出码并失败构建。

---

## §4 LOW

| # | 文件:行 | 一句话 | 🔴/⚪ | 已知? |
|---|---|---|---|---|
| L1 | `voice.js` stateTimer | 离开页面不清理定时器(轻微泄漏) | ⚪ | NEW |
| L2 | `usb.js:108` | IPv6 行漏 `\|\| '—'` 兜底,字段空时可能印 null | ⚪ | NEW |
| L3 | `fwd.uc:706-711` forward_log | 不检查 rc,引擎坏和"没数据"长得一样 | ⚪ | NEW |
| L4 | `fwd.uc:723-736` forward_status | 同 L3 | ⚪ | NEW |
| L5 | `changxing60-sms-job:99`+`changxing60-voice-job:102` | `LIMIT`(200s/60s)只上报不强制,无 `timeout`;atd 楔住时脱手进程不死→`running()` 恒真→面板锁到重启 | ⚪ | NEW |
| L6 | `tools/changxing60-ssh.py:5-6`+`scp.py:4,6` | 陈旧默认 `ubuntu@`/`ubuntu`;现是 root + 主机侧口令(值不在仓库),默认静默鉴权失败 | ⚪ | NEW |
| L7 | `bootdiag:41` | `berr=$(echo "$bdev" > /sys/.../bind 2>&1)` 重定向顺序错——fd1 先转 bind 文件再 `2>&1`,stdout+stderr 都进 sysfs,`$berr` 恒空,失败时只印 `err=[]` | ⚪ | NEW |
| L8 | `changxing60-hw:45` | `[ -w "$R" ] && echo reset > "$R"` 写失败/超时无 log;assert 策略留在 dump → 下次 assert 静默死射频而 hostapd 仍报 ENABLED | 🟡 | NEW |
| L9 | `changxing60-power:13` | `\|\| true` 吞 power-policy 失败无 logger;崩溃/缺失时 governor 钉不住,无痕迹 | ⚪ | NEW |
| L10 | `changxing60-dp-enable.c:44-47` | "已有设备"早返回路径泄漏 device 引用 | ⚪ | NEW |
| L11 | `changxing60-dp-enable.c:55,78` | `kstrdup("okay"/"disabled")` 结果永不 free;`disable_node` 找不到 DT 路径时静默无操作 | ⚪ | NEW |
| L12 | `build-linux.sh:30` | `make … \| grep … \| tail` 无 `pipefail`,make 失败被 tail 的 0 掩盖,延后到 `ls Image` 才报、误归因为"缺 Image" | ⚪ | NEW |
| L13 | `audio-pcm-period-timer.patch:233,238` | 释放路径用 `spin_lock_irq`/`_unlock_irq`,而包装用 `irqsave`;若从 hrtimer xrun→stop→release 链(本补丁引入)进、IRQ 已关,会过早开 IRQ。目前只进程上下文到,fragile 非 live bug | ⚪ | NEW |
| L14 | `tools/android-mount-changxing60root.sh` | 挂载前判 `fs label = changxing60root`,而本机 ext4 label 仍是 **`mu300root`** ⇒ 脚本在**唯一需要它的设备**上直接中止(boot X 救回当晚只能照它的配方手工做) | ⚪ | NEW(10-17 晚) |
| L15 | `changxing60-vbc-load:74` `--dir` 解析 | `for a in "$@"` 里 `shift` 不改变迭代:DIR 赋给 FW 后,下一轮迭代把它判成 unknown option 直接 exit 2 ⇒ **`--dir` 一次都没能用过**(默认 `/lib/firmware` 路线无人受害) | ⚪ | NEW(10-17 晚) |

L5/L8 的建议改法见对应 agent 报告:`timeout "$LIMIT" "$SMS" send …`、reset_dump 不可写时 `logger` + echo `\|\| logger`。

---

## §5 本次推翻掉的「假缺陷」(别再当真)

- **`changxing60-vpn` 644 / "一次都没跑"** —— 复核:`openwrt/overlay/etc/init.d/changxing60-vpn` **不存在**;
  唯一一份在 `container/overlay/`(另一条非发货部署线),且 `container/build-rootfs.sh:26` 显式 `chmod 755`。
  不是缺陷。
- **`tools/stage-adapt.sh` 模块名清单漂移** —— 复核:`vendor-modules`/`touch-ctl` 的手写清单与
  `stage-adapt.sh` 逐项对齐(13 misc + 7 crypto + 2 usbnet + 3 touch,`stage-adapt.sh:174` 有
  `grep -q 'zte_tpd'` 守卫)。不是缺陷。
- **所有 git 跟踪脚本的 mode bit** —— 复核:`git ls-files -s` 全 `100755`(脚本)/`100644`(数据)。
  不是缺陷(这是本次唯一一处"看着像 mode-bit 坑但实际干净")。
- **`changxing60-at` 的 `wait_and_exec` 240s 上界** —— 合理,不是缺陷。

## §6 用法

1. **改不改、改哪条,用户决定**;本文件只记录。版本收束未解除(除"汉化"那一摊已单独获用户授权)。
2. 若动手:**先 🔴 那几条**(M5/M6/M7/M8/M10 + L8),它们碰 WAN/热点/启动;改前先读
   [`state-2026-10-17.md`](state-2026-10-17.md) §3 的"会不会影响网络",别把"不影响网络的小 bug"
   当成必须现在修。
3. **音频一摊(H1/M2/M3)与挂起的通话音频攻坚同源**,要捡通话音频就从 H1 的 **`sprd-dmaengine-pcm.c:1135`** 补丁起
   (2026-10-17 勘误:原先写的 `saudio.c` 那份在本机从没 probe);但先想清楚
   "怎么干净地只动音频一半"(两进程同读 AT 会弄哑 modem 到重启,见 state §6)。
4. 改完每条都按"报成功前必须实测"验:网络那几条用 state §7 的验收命令;UI 那几条真机开页面看。
