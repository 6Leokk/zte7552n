# 7552N:短信/通话移植(上游 mu300-linux SMS 栈)

> 状态:**引擎已移植 + 主机侧验证通过**;LuCI 管理页与 rpcd 后端**已写好并主机侧验证通过**(见下);
> **设备侧尚未上机**(设备离线,`192.168.77.1` 不可达)。本文记录来源、架构、**已知的通道冲突**与分阶段上机方案。
> 关联:[`README.md`](README.md)、[`screen-plan.md`](screen-plan.md)(内屏/按键)、
> [`mainline-6.18.md`](mainline-6.18.md)(6.18 试验线)、[`sipa-wedge.md`](sipa-wedge.md)(蜂窝假死)。

## 来源与许可

上游 `github.com/dikeckaan/mu300-linux`,锚点 **`4106772aae5e`**(2026-10-13,与 `mainline-6.18.md` 的 B0 同一提交),
**MIT**。我们按文件原样 vendoring(不改内容,便于日后 `git diff` 对账上游),落在:

上游路径按上游命名(`opt/mu300/bin/mu300-*`),我们的路径是同一批文件 vendoring 后统一改名为
`changxing60`(见 [`README.md`](README.md) 的命名约定):

| 上游路径 | 我们的路径 | 作用 |
|---|---|---|
| `rootfs/overlay/opt/mu300/bin/mu300-atd` | `rootfs/overlay/opt/changxing60/bin/changxing60-atd` | AT 通道常驻持有者(唯一读者) |
| `rootfs/overlay/opt/mu300/bin/mu300-at` | `rootfs/overlay/opt/changxing60/bin/changxing60-at` | AT 客户端(过 daemon;无 daemon 时**直开 tty**) |
| `rootfs/overlay/opt/mu300/bin/mu300-cmt-spool` | `rootfs/overlay/opt/changxing60/bin/changxing60-cmt-spool` | `+CMT` 帧落盘(供 smsd 导入+回执) |
| `rootfs/overlay/opt/mu300/bin/sms` | `rootfs/overlay/opt/changxing60/bin/sms`(未改名) | SIM 直读工具(list/json/read/send/delete/watch) |
| `openwrt/luci-overlay/opt/mu300/bin/mu300-sms` | `rootfs/overlay/opt/changxing60/bin/changxing60-sms` | **面板用的池 CLI**(收/发/同步/删除) |
| `openwrt/luci-overlay/opt/mu300/bin/mu300-smsd` | `rootfs/overlay/opt/changxing60/bin/changxing60-smsd` | 池与 SIM 保持同步的守护 |
| `openwrt/luci-overlay/opt/mu300/bin/mu300-sms-forward` | `rootfs/overlay/opt/changxing60/bin/changxing60-sms-forward` | 转发(webhook/Telegram/邮件/短信) |
| `openwrt/luci-overlay/opt/mu300/lib/sms-forward-http.uc` | `rootfs/overlay/opt/changxing60/lib/sms-forward-http.uc`(未改名) | ucode HTTP POST(uclient),**bark 走这里** |
| `rootfs/overlay/opt/mu300/lib/sms-pdu.awk` | `rootfs/overlay/opt/changxing60/lib/sms-pdu.awk`(未改名) | GSM 03.38 / PDU 编解码 + 长短信分组 |

`changxing60-atd` 与 `changxing60-at` 都以 `#!/bin/sh` 起手,再**自我 exec 到 bash 或静态 busybox ash**(它们要
`read -t 0.1`)。设备的 rootfs 已装 `bash`,且 `build-rootfs.sh` 把静态 busybox 放在 `/opt/changxing60/bin/busybox`
并做了 `timeout` 等 applet 链接,满足前提。

## 架构(上游设计,我们原样沿用)

```
changxing60-atd           一个人常驻持有 /dev/stty_nr1(SIPC tty:只有第一个读者拿得到数据)
  ├─ 命令 fifo  /run/changxing60-at/cmd      ← changxing60-at 写命令、读回显
  └─ URC 日志   /run/changxing60-at/urc/*.log ← +CMT/+CMTI 等非请求行
changxing60-at            CLI → daemon;daemon 不在时直开 tty("能成一次,之后要重启 modem")
changxing60-sms           池 CLI:list/show/send/delete/mark/sync/import-pdu
changxing60-smsd          守护:处理 spool、按 URC 日志签名变化触发 sync、维持 AT+CNMI 直投
changxing60-cmt-spool     +CMT 帧 → $POOL/incoming/*.ready(fsync 后才回执 AT+CNMA=1)
changxing60-sms-forward   队列 + 重试 + 过滤器 → webhook(**bark 就是 webhook**)/Telegram/邮件/短信
```

池布局(上游定义,勿改):`$POOL` = `/etc/changxing60/sms-pool`(**在 /etc,不在 /run**,重启后仍在);
一条消息一个文件,头是 `字段: 值`,空行后是正文;`$POOL/incoming` 是 spool。

## ⚠ 关键发现:AT 通道冲突(上机前必须解决)

**我们现在的 `mobile-data` 自己独占 `/dev/stty_nr1` 走完整条拨号**(`rootfs/overlay/opt/changxing60/bin/mobile-data`
第 8 行 `DEV=${CHANGXING60_AT_DEV:-/dev/stty_nr1}`,自己 `exec 3<>$DEV` 做 CFUN/SFUN → CEREG → CGDCONT → CGACT →
`AT+CGDATA="M-ETHER"`)。**上游不是这样**:它把**数据**放 `nr2`、**命令**留 `nr1`:

> nr1 is the general command channel (changxing60-at, toolkit, diagnostics). nr2 ... is dedicated to mobile-data:
> AT+CGDATA blocks its channel for 10-20 s, and nr1 stays free for signal checks and SMS meanwhile.

也就是说,**直接把 `changxing60-atd` 加到我们这棵树上会踩双读者**:`changxing60-atd` 开着 nr1,`mobile-data` 又开一次
同一通道——而上游注释明确记录了这个故障模式的后果是"数据面挂死"(`changxing60-atd` 头部:
"only one reader gets the data ... a second process that opens the device reads nothing";init 脚本:
"two readers on one SIPC tty")。

**因此分层上机,不要一步到位:**

- **第 0 步(零风险)**:只跑 `sms-pdu.awk` + `changxing60-sms list/show`(纯读,SIM 上没消息时也不发 AT 之外的
  东西)。确认编解码、Sender 名字、长短信拼接与真机一致。
- **第 1 步**:加 `changxing60-atd` 持有 nr1,**同时**把 `mobile-data` 的 AT 调用改成走 `changxing60-at`(即
  `at() { changxing60-at -t "$2" "$1"; }`),让两者共用同一个持有者。`mobile-data` 的 `CHANGXING60_AT_DEV` 仍指 nr1。
  这一步动的是**承载 WAN 的脚本**,必须整轮实测(拨号成功、假活自愈、watchdog 重启兜底都没回归)。
- **第 1b 步(上游做法,可选但更彻底)**:`changxing60-atd` 起第二实例占 nr2(`CHANGXING60_AT_DEV=/dev/stty_nr2
  CHANGXING60_AT_DIR=/run/changxing60-at2`),把 `mobile-data` 的拨号挪到 nr2。这样 `AT+CGDATA` 阻塞的是 nr2,
  nr1 始终留给信号查询与短信——**顺带可能缓解 SIPA 假死**(拨号不再堵住命令通道)。
- **第 2 步**:上 `changxing60-smsd` + `changxing60-cmt-spool` + `changxing60-sms-forward`(守护会每 5 s 摸一次 AT,
  所以第 1 步没做完**不要**开它——`changxing60-smsd` 自己没有 daemon 时会 `die`:`need_atd` 检查 `$ATDIR/cmd`)。

`mobile-data` 的 `CHANGXING60_AT_DEV` 也说明:**换通道只改这一个环境变量**,不必改脚本逻辑。

### 第 1 步:已上机,已实测(2026-10-16)

装法就是三个文件换新的 + 一个 enable,`mobile-data` 新旧只差这一处(`AT_BIN` 调用,10 处),其余四个
(`changxing60-at` / `changxing60-atd` / `changxing60-smsd` / `changxing60cell.sh`)与设备上原有字节相同。
`/etc/init.d/changxing60-at enable` 落的 `S19changxing60-at` **刻意排在 `S20network` 之前**,这样首次 attach
一定找得到 daemon。回滚件在设备 `/root/at-stack-backup/`。

一次重启(只重启一次 —— 开机 ~70 s 内连着重启两次会把 misc 打到 Android)后逐项实测:

| 项 | 期望 | 实测 |
|---|---|---|
| 落点 | 仍是 OpenWrt | 5.4.254,misc slot b 的 `BCAB` 完好 ✅ |
| daemon 在跑 | `changxing60-atd` 常驻 | pid 5452(ppid 1)+ 子进程 5490 ✅ |
| **nr1 只有一个读者** | 只有 daemon | 全 `/proc/*/fd` 扫下来**只有 pid 5452 持有 `/dev/stty_nr1`** ✅ |
| 子进程是谁 | — | 是 daemon 按设计起的 **nr0 URC 排水器**(`stty_nr0.log` 在写),Android RIL 也是六个通道全读;每通道仍只有一个读者 ✅ |
| AT 客户端过 daemon | `AT+CSQ` 有真回包 | `+CSQ: 99,99` + `OK`;`AT+CREG?` → `+CREG: 2,8,...,11` + `OK` ✅ |
| `mobile-data` 走 daemon | 自己不持有 nr1 | 它在跑、WAN 通,而**全机没有第二个 nr1 持有者** ⇒ 只能走 daemon ✅ |
| 拨号没回归 | 地址 + 真通 | `sipa_eth0 10.166.156.74/8`,`proto=changxing60cell`,ping 223.5.5.5 **0% 丢包**,DNS 解析出 39.156.70.46 ✅ |
| 健康文件 | `ok`(不是假活) | `/tmp/changxing60-wan-health` = **`ok 501`** ✅ |
| 升级阶梯没被误触 | 四个 mark 都该不在 | `mobile-data-down` / `wan-rebooted` / `wan-cp-reset` / `attach.lock` **全部 absent** ✅ |
| CP 状态 | 在跑 | `/sys/kernel/debug/modem/modem` → `run_state: 1` ✅ |
| 日志无 AT 错误 | — | `logread` / `dmesg` 里 `changxing60-at` / `stty_nr` / `EBUSY` 零命中 ✅ |

两个当场踩到的细节:`changxing60-at` 在 `/opt/changxing60/bin/` 而**不在 PATH 里**(要用全路径,或自己
`export PATH=/opt/changxing60/bin:$PATH`);设备 busybox **没有 `timeout`**,别拿它包 AT 调用。
`+CSQ: 99,99` 是"信号未知"而不是"无信号" —— WAN 在同一时刻是通的,这条留给信号查询那一轮(见 W5)。

### 🔴 真正的拦路石:一条 `AT+CPMS=` **把 AT 通道打死**(而 WAN 照跑)

上表那一轮是**真的全过**。但在同一 boot 里继续用 AT 之后就全哑了。起初看起来像"通道自己变哑",
**实测下来不是:是 `AT+CPMS=<设置形式>` 这一条命令把它打死的,单条、必现。**

现象长这样:

| 现象 | 实测 |
|---|---|
| 所有 AT 命令 | `changxing60-at: modem returned no final response`(连裸 `AT` 也是) |
| nr0 的 URC 日志 | **停止增长**(1729 B 卡住不动,20 s 两采样一模一样) |
| **WAN 数据面** | **完全正常** —— ping 223.5.5.5 **0% 丢包**,健康文件一路 `ok` 到 1342 |
| 谁持有 tty | 只有 daemon 和它的 nr0 排水器,**没有第二个读者** |
| daemon 状态 | `wchan=fifo_open`,S —— 空闲等命令,不是卡在命令里 |
| CP | `run_state: 1` |
| 内核新行 | `sprd_wdt_fiq: ... timeout =40, pretimeout =20`,从 uptime 1102 起每 8 s 一条(那是**果**,不是因) |

**定因实验**(2026-10-16,专门重启一次干净 boot 跑的):

```
--- 阶段 1:五条无害命令(排除"是不是发够多少条就死") ---
  1) AT         rc=0 | OK
  2) AT+CPMS?   rc=0 | +CPMS: "SM",9,50,"SM",9,50,"SM",9,50 OK     <-- 查询形式,安全
  3) AT         rc=0 | OK
  4) AT+CSQ     rc=0 | +CSQ: 99,99 OK
  5) AT         rc=0 | OK

--- 阶段 2:CPMS 的**设置**形式 ---
  6) AT+CPMS="SM","SM","SM"   rc=1 | modem returned no final response
  7) AT                       rc=1 | modem returned no final response   <-- 通道已死
```

**查询形式(`AT+CPMS?`)无害,设置形式(`AT+CPMS=...`)一条就打死**,而且**打死之后只有重启能救**
(daemon 自己的注释解释了这个不可逆性:modem 侧一复位,它那个 fd 就挂在一个**已经不存在的 SIPC 通道**上,
读永远为空,而它仍占着通道;注释里还实测过"modem 活着时关掉再打开,通道会永久变哑")。
两次自然发生的"AT 口全哑"现在都能对上:boot 1 是我跑了 `sms list`(它第一步就是 CPMS 设置),
boot 2 是 `AT+CPMS="SM"`。

**这条直接挡住 W2**:上游那套**两个工具都发 CPMS 设置形式**——
`sms`(SIM 直读)`bin/sms:113` → `AT+CPMS="$s","$s","$s"`;
`changxing60-sms`(池 CLI)`bin/changxing60-sms:293/295` → 三参形式,失败再退一参形式。
也就是说**这两个工具在这台 modem 上一次都跑不了** —— 第一次调用就把通道打死。
`changxing60-smsd` 自己不发 CPMS(只发 CMGF/CSMS/CNMI/CNMA/CPIN),但它每次 `sync` 都会调
`changxing60-sms` ⇒ **直接 enable smsd 会在第一次 sync 时打死通道**。

**修法(方向已定,未实现)**:`pick_store()` 改成**只问不设**。`AT+CPMS?` 已经把当前存储报出来了
(`"SM",9,50` —— mem1 就是 SM,9/50 已用),所以根本不需要"选":读一次查询、取 mem1 当存储即可。
顺带说,这解释了 `sms` 那句 `the modem accepted neither SM nor ME storage` —— 不是没有存储,
是它先被自己的 CPMS 设置打死、后面的读自然全空。

**还有一层设计缺陷值得单独记**:即使通道死了,`mobile-data` 也**永远不会发现**。
它的 `at_state()` 在 `link_up` 时**故意直接 `return 2`(不问)**——因为不分通道时数据呼叫和 AT 共用 nr1,
怕探针的字节混进数据流;而"不问"又让 `maybe_reboot` 否决升级。于是设备会**带着一个死掉的 AT 通道
无限期跑下去,还一路报 `wan-health: ok`**:短信、通话、信号查询静默不可用,而所有看板都正常。
**这正是第 1b 步(at-split:数据走 nr2、命令留 nr1)存在的理由** —— nr1 空出来之后,AT 探针才能随时发,
`at_state()` 那个 `return 2` 才能去掉。在那之前,任何 AT 相关的验收都必须**先自己探一次 AT**,
不能只看 `wan-health`。

现场证据已落盘在设备上:`/root/dmesg-at-death-uptime1102.txt`(1.0 MB 全量 dmesg)、
`/root/urc-nr0-at-death.log`。

**仍然未决的一小半**:为什么 CPMS 设置形式会打死通道。这是 modem 固件侧的行为(我们没有 CP 源码),
`AT+CPMS?` 明明工作正常。**"AT 死而数据面活"这个组合是本次新观察到的**;
它和笔记里记过的 SIPA 假死**不是**同一件事(那次流量也不通,`SIPA_RM` 有先兆;这次 dmesg 里 `SIPA_RM` 零命中)。

**对 W2/W4/W5 的直接后果**:这三项全靠 AT。(a) `pick_store` 必须先改成只问不设;
(b) 验收时必须**自己探 AT**,不能信 `wan-health`。

## 主机侧已验证(可复跑)

两个测试都在主机上跑,不碰设备。它们能覆盖的正是"错了也不会报错"的部分——解错一个字、长短信少一段。

```
tools/sms/test-pdu.sh     45 项:编解码(含 UCS2/土耳其/扩展表/USSD/长短信分组)
tools/sms/test-cli.sh     15 项:池 CLI 全链路(用 tools/sms/fake-at 假 AT)
```

`test-pdu.sh` 的强力之处在于**双向对拍**:收到的 PDU 由 `tools/sms/deliver.py`(独立实现,按 TS 23.038
自己写的一套打包)生成,再喂给设备那份 `sms-pdu.awk`;发出的 PDU 则对**手算的固定串**。另有 3GPP TS 23.040
附录的定标向量(发送方 `+27381000015`、正文 `hellohello`)做第三方锚点。

> 这套对拍**当场抓到一个真 bug**,而且在**我写的那一侧**:`deliver.py` 的 UDH 少写了 `UDHL` 长度字节,
> 于是解码方读到 `udhl=0`,把 IE 自己的字节当成正文显示在消息前面(`@ù(_Δ@first half...`)。这正是
> 对拍的价值——自己对自己做往返测试永远发现不了它(两边会一致地错)。

`test-cli.sh` 覆盖:sync 把 SIM 上 3 个槽(含一条两段长短信)收成池中 2 条、长短信两段拼回一条、
`show` 出全文、**未变化的 sync 不重写任何文件**(池在 flash 上,这点很重要)、池化后 SIM 槽被清、
`import-pdu` 走直投路径并触发 hook、`send` 真的把 PDU 交给了 modem 且回池标记为 `mo`。

## 管理后台(LuCI 页 + rpcd 后端,已写好,主机侧验证通过)

"短信可以在 openwrt 管理后台看"这一步的文件(都在 `changxing60-linux/openwrt/overlay/`):

| 文件 | 作用 |
|---|---|
| `usr/share/rpcd/ucode/changxing60sms.uc` | 后端:`list/show/send/job/sync/delete` 六个方法,壳到 `changxing60-sms` |
| `opt/changxing60/bin/changxing60-sms-job` | 脱手发送的另一半(`claim/start/state/reply/run`) |
| `usr/share/rpcd/acl.d/luci-app-changxing60sms.json` | 读写 ACL(`show/list/job` 只读,`send/sync/delete` 需写权限) |
| `usr/share/luci/menu.d/luci-app-changxing60sms.json` | 菜单项:服务 → SMS |
| `www/luci-static/resources/view/changxing60sms/sms.js` | 页面(自包含,不依赖上游 `mu300/common.js`) |
| `usr/share/rpcd/ucode/changxing60fwd.uc` | **转发面板后端**:`forward_get/set/test/gate/log/log_clear/status` 七个方法;它拥有 `/etc/changxing60/sms-forward.conf` |
| `www/luci-static/resources/view/changxing60fwd/fwd.js` | 转发面板页面:webhook / Telegram / 邮件 / 短信四种出口 + 过滤器(`allow`/`deny`/`keyword`)+ 投递日志 |

转发那半是**独立对象**、不是 sms 对象的一个方法:池是人人可读的,而转发配置是 root 的文件、
里面躺着 Telegram token 和 webhook URL,所以两个世界的 ACL 分开。但**页面是一页两半**,
所以 `acl.d/` 与 `menu.d/` 里那两个 `luci-app-changxing60sms.json` 同时覆盖两半。

**菜单 order 是四个互不相同的号**(2026-10-16 修):SMS 60 / Calls 61 / SMS forwarding 62 /
USB link 63。之前 forwarding 和 Calls **都是 61** —— LuCI 允许重复(按 key 兜底排序),
所以不报错、两项也都在,只是"两个功能抢一个位置"这件事没人看得出来。
四个号现在各自唯一,顺序按"短信 → 通话 → 转发 → USB"分组。

**为什么不 vendoring 上游那个页面**:上游 `sms.js` 依赖它自己的 `mu300dash`(40+ 方法,含信号/流量/VPN/终端/操作日志)
与 `mu300.common`。我们只要一个短信页,所以自己写了个小后端 + 精简页面,共用的是**池**(`changxing60-sms` 拥有、
`changxing60-smsd` 填充,后端只读它、请它发)。

**一个 send 不能在一次调用里答完**,这是这份后端唯一不显然的设计:rpcd 30 秒掐断一次调用,而 `changxing60-at`
自己等锁就要 90 秒、一个真实 send 的事务可以更久。所以 `send` 只做校验 + `claim` + 写 text/num +
`start`(detach),**立刻返回 `started`**;页面每秒 `job` 一次问结果。否则慢发送会被连调用一起杀掉,
它的结果丢了,而消息已经出去(或没出去)而页面不知道。同理 `sync`(CMGL 要走完整个 SIM)也是脱手的。

`job` 的四种回答:`none`(从没发过)/ `running SECONDS LIMIT` / `done` + `ok`(或 `busy`),
以及**结束但没结果**(send 被重启打断)→ 如实报失败而不是成功——消息到底出没出去是未知的,
而且没有任何东西会自动重发。

### 上机:引擎早就到了,通到它的四条路一条都没有(2026-10-16)

**上机实测时,设备上 `ubus list` 里只有 `changxing60sms` / `changxing60usb` / `changxing60voice`,
没有 `changxing60fwd`** —— 转发面板整个是死的。逐件核对下来,缺的**不是**引擎:

| 件 | 设备上 |
|---|---|
| `/opt/changxing60/bin/changxing60-sms-forward`(35658 B, 755) | ✅ 在,且与仓库 **md5 逐字节相同** |
| `/opt/changxing60/lib/sms-forward-http.uc` | ✅ 在,md5 相同 |
| `changxing60-sms` / `changxing60-smsd` | ✅ 在,md5 相同 |
| `ucode/changxing60fwd.uc` | ❌ **整个文件不在** |
| `acl.d/luci-app-changxing60sms.json` | ❌ 是旧的 255 B(只点 sms 六个方法) |
| `menu.d/luci-app-changxing60sms.json` | ❌ 是旧的 205 B(只有 SMS 一项) |
| `view/changxing60fwd/fwd.js` | ❌ **目录都不存在** |

**根因是构建时间差,不是代码错**:引擎随 09:52 那次构建进了设备,而转发面板是当天 20:06 才写的,
**之后再没构建过、也没人把它推上机**。这正是本项目反复踩的那一类——*干活的那一半在位且正确,
通往它的每一条路都不在*,而"文件在不在"和"功能通不通"在设备上长得一模一样。

补上四件后(`tools/deploy-pending.sh` 已加进推送与验证清单,形状照抄 USB 那页),
`rpcd restart` 一过就实测通过:

```
ubus list | grep changxing        →  changxing60fwd  changxing60sms  changxing60usb  changxing60voice
ubus -v list changxing60fwd       →  七个方法全在
ubus call changxing60fwd forward_status  →  {"queued":0,"running":0,"email":0}
ubus call changxing60fwd forward_get     →  完整配置模式(webhook/telegram/email/sms 四路 + 过滤器)
curl .../view/changxing60fwd/fwd.js      →  HTTP 200, 18557 B
```

**后台收发这一半是拿真短信证的**:`changxing60-smsd` 在跑(pid 7594),池里躺着
**4 条真实收到的短信**(10086 / 139 邮箱 / 卡券提醒,2026-10-13~10-16),没有任何人手工跑过命令——
这就是"后台收"。

转发链路的接线也逐行核过:`changxing60-smsd` → `changxing60-sms sync` →
`changxing60-sms` 第 593 行 `[ -s "$_newids" ] && "$FORWARD" enqueue ... || "$FORWARD" kick`。
转发默认 `enabled: false`,是**正确默认**:面板上不填目标就不该发东西出去。

> **教训**:`ubus list` 里少一个对象,先分三问——①引擎在不在(这里在)、②rpcd 插件文件在不在
> (这里不在)、③ACL/菜单/页面在不在(这里都不在)。**别看到"文件在"就以为功能在**,也别看到
> "功能不通"就回头查引擎。这次差的是②③,而①完全无辜。

### 主机侧验证手段:`tools/sms/rpcd-harness.uc` + `tools/sms/test-rpcd.sh`

rpcd 插件是**模块**,它自己不打印任何东西、也不能直接跑,所以另写了一个 harness:
`ucode rpcd-harness.uc PLUGIN.uc METHOD [JSON]` —— 按 rpcd 的方式 load 插件、取它返回的第一个对象、
用 `{args:...}` 调那个方法、把返回值打成 JSON。**这是这套后端能被测试的唯一原因**(对任何同形状的插件都通用)。

`tools/sms/test-rpcd.sh` 在 OpenWrt 镜像里跑(rpcd 插件是 ucode,得在目标环境测),AT 通道是
`tools/sms/fake-at`,SIM 由 `tools/sms/deliver.py` 在主机侧生成 —— 于是"发一条、收一条、删一条"全都能在
没有设备的情况下走完。覆盖:六个方法的每一种返回形状、页面的越权请求(非数字 id / 不存在的 id /
非数字页码 / sim 不是布尔)、发送前的校验(号码带字母、空正文、481 字、控制字符,且**都没到 AT 通道**)、
**发送是脱手而不是在调用里跑完**(让假 modem 故意慢 6 秒答 `+CMGS`,断言调用 ≤4 秒返回、`job` 报 running、
同一时刻第二次 send 被拒 busy、最后 done/ok、PDU 到了 modem、发件回池标 `mo`)、
**busy 的 AT 通道不算发送成功**(AT 客户端自己那行 `changxing60-at: busy` 不是 modem 的答复)、
以及**claim 的并发性**(同一时刻只有一个 claim 能拿到)。**共 69 项,两段都全过。**

它分两段跑,是因为**harness 代替不了 rpcd,而 rpcd 恰恰是最会静默失败的那一层**(插件放错目录就永不加载、
参数声明错了就被空着调用、返回值序列化不了就回空)—— 这些通过 harness 一个都看不出来:

1. `rpcd-check.sh`:上面那些,用 harness 逐方法直调。
2. `rpcd-ubus-check.sh`:**装到 rpcd 真正找插件的地方**(`/usr/share/rpcd/ucode/` +
   `/usr/share/rpcd/acl.d/`),起真的 `ubusd` + `rpcd`,**用 `ubus call` 问** —— 就是 LuCI 页走的那条路。
   它验证对象注册出来了、六个方法都在、list/sync/send/job 的返回形状与直调一致、
    ACL 文件在 rpcd 读的位置且点了这六个方法。顺带实测了一件设计上的事:
   **`page` 声明成数字,于是 `{"page":"x"}` 被 ubus 在进插件之前就用 `Invalid argument` 拒掉**
   (插件自己那层拒绝由第 1 段覆盖)。这一段要 root(ubusd/rpcd),所以跑完把 work 目录 `chown` 回去。

> 测试里踩到的两个环境坑,都是"看起来像代码坏了"的那种:①镜像的 `/tmp` 是 `drwxr-xr-x root root`,
> 非 root 跑 `mktemp` 直接失败,而池 CLI 要 `mktemp` → 得把 `TMPDIR` 指到一个自己拥有的目录;
> ②ucode 的 `%J` 打印是紧凑单行,按 `,` 切 JSON 提取 id 会漏(第一个 id 挤在 `"msgs": [ {` 后面),
> 要按 `"id": "` 这个 key 切。

## Webhook / bark 推送(已主机侧端到端验证)

`changxing60-sms-forward` 的 `webhook_url` + `webhook_format` 就是 bark 的入口(bark 的接口形如
`https://api.day.app/<key>/<title>/<body>`,普通 HTTP POST)。请求由 `sms-forward-http.uc` 发出。

**依赖已核实全在 rootfs 里**(在 `changxing60-openwrt-base:25.12.5` 里查过,无需 `apk add`):
`ucode`、`ucode-mod-uclient`、`ucode-mod-uloop`、`ucode-mod-fs`、`libustream-mbedtls`,以及 helper 写死的
`/etc/ssl/certs/ca-certificates.crt`(存在,182 KB)。

**已实测**(把 helper 直接喂给一个本地 HTTP stub,docker `--network host`):

| 场景 | 结果 |
|---|---|
| 正常 POST(bark 形态的路径 + `Content-Type` + `Authorization`) | `status 200`;服务端收到 **完整的 chunked 正文**、正确的路径与两个头 |
| `CHANGXING60_FWD_ANSWER=100`(面板 `webhook_expect` 判据靠它读回包) | `status 200` + 回包前 100 字节 |
| 端口无人监听 | `error connect` |
| URL 不合法 | `error bad url` |

头一个坑值得记:**`uclient` 用 chunked 发送正文**。第一版 stub 只读 `Content-Length`,于是"成功"却是
**空正文**——真发到 bark 就是一次静默失败(200,但什么都没推)。所以这个测试必须用 chunked-aware 的服务端,
"status 200" 本身不足以证明推成功。

## 待办

1. ~~**LuCI 管理页 + rpcd 后端**~~ —— **已写并验证,且已上机**(见上"管理后台"一节)。
   **收**:实测有 4 条真实短信被 `changxing60-smsd` 后台收进池;**发**:面板走脱手 job;
   **转发**:`changxing60fwd` 七个方法在设备上实测可调,链路 `sync → enqueue/kick` 逐行核过,
   默认关。**用户要在面板里填一个目标(webhook/Telegram/邮件/短信)才会真的往外发** —— 这一步是配置,
   不是缺功能。
2. **通话**("通话可以用手机接")—— **已查清形态,结论是:不需要 RIL,但需要一整套我们现在没有的音频驱动**。
   上游 `changxing60-voice`(473 行,未移植)把"通话"拆成两半:
   - **控制**(拨打/接听/挂断/通话状态)走 **AT**,就是上面那套通道 —— 这部分没有新依赖,第 1/1b 步做完就有。
   - **声音**走 **AGDSP**(Unisoc 音频 DSP),不开 Android 运行时也能驱动:它用的是 ALSA。脚本头部写明
     这板子**没有喇叭/听筒/麦克风**,所以通话音频只有两个去处:①**蓝牙耳机**(控制器 PSKey 把 SCO 音频
     经 PCM 引脚送进 DSP 的 IIS3,配套 `mu300-hfp`);②**不落地**(hostless 场景,把通话两端暴露成
     `FE_ST_VOICE_PCM_P`/`FE_ST_VOICE_C` 两个 PCM 设备,给 `tone`/`echo`/SIP 桥用)。

   **它的依赖里有一条我们当前不成立**:脚本要 `/proc/asound/cards` 里有 `sprdphone` 这张卡,而
   **我们的 5.4 `kernel/device.config` 是 `# CONFIG_SND_SOC_SPRD is not set`** —— 现在这张卡根本不存在。
   更要紧的是,关掉配置还不够:**机器驱动不在我们编的那棵树里**。查过 `changxing60-kernel` 卷里的
   `zte-u30air/sound/`:只有平台侧(`sprd-pcm-dma.c` / `sprd-mcdt.c` / `sprd-pcm-compress.c`),
   而 `sprd-audio-card`(建卡的那个)与 `sprd_fe_dai`(前端 DAI)**在整个 `sound/`+`drivers/` 里搜不到实现**,
   只在 DTS 里以 `sprd-audio-card,name = "sprdphone-sc2730"` 的形式被引用 → 它们在 Android 侧是
   **厂商预编译模块**(`/vendor/lib/modules`)。

   所以通话的下一步不是改配置,而是**先把这几个 .ko 从 Android 的 vendor 分区捞出来**(本仓已有
   `android-vendor/extract-subset.sh` 这类工具),在 5.4(与 Android 同内核版本)上试着加载 —— 这条路可行
   与否,要看厂商模块的 vermagic/符号依赖。另外 `changxing60-voice` 还要 `amixer`/`aplay`/`arecord`(alsa-utils)、
   上游自己的 `tools/ctlset`(amixer 会把某些控制值钳掉,得写完整 32 位)与 `tools/pcmhost`(起 hostless 场景),
   以及 `kernel/patches/audio-pcm-period-timer.patch`。可抄的先例:kanoqwq/e5-linux(同款 DSP,
   其下行已在听筒/喇叭上被听到,`@402fde1 @8e9b8a4 @2c726fc`)。

   > 形态问题(用户要的是"用手机接电话"到底指什么)因此可以缩小成:**控制面用 AT 就够了,声音面要不要做**
   > —— 要做就得先把上面那套 AGDSP 栈搞进来,这是独立于短信的一个大块。
3. **设备上机**:按上面第 0 → 1 → 1b → 2 步,每步实测后再下一步。**LuCI 页与 rpcd 后端从未在设备上跑过**
   (只过了主机侧 `tools/sms/test-rpcd.sh`),上机时要单独验一次真机路径:rpcd 的 ACL、菜单项、
   池路径 `/etc/changxing60/sms-pool`、以及 `changxing60-sms-job` 在 `/var/run/changxing60sms` 上的 claim。
