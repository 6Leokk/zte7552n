# SIPA 假死(WAN 有地址、零流量、只有重启能救)——根因与补丁

> 2026-10-13。现场证据:`changxing60-linux/work/wedge-2026-10-13/live/wedge4-live.txt`(gitignored)。
> 内核侧完整记录:`changxing60-linux/docs/FINDINGS.md` §34。补丁:
> `changxing60-linux/kernel/patches/sipa-delegate-peer-request-timeout.patch`。
> **最新(2026-10-16)**:另一次假死的现场在 `changxing60-linux/work/wedge-20261016/`
> (`console-ramoops-0` / `pmsg-ramoops-0` + 十份 diag dump);**那次为什么归不了因、
> 以及凭什么让下一次能归因**,见 §6.7(附 console 抓取只收 ERR 的坑)。

## 1. 结论

假死**不在** bearer、不在路由、不在 CP 的数据面,而是 **SIPA delegator 少了一个对端超时**:

- 给 PS CP 发 `DELE_REQUEST` 后,若 CP 不回 `DONE`,delegator 的 `stat` 停在
  `SIPA_DELE_REQUESTING`,`sipa_dele_local_req_r_prod()` 就一直返回 `-EINPROGRESS`;
- RM 的 `SIPA_RM_RES_PROD_CP` 因此永久停在 **REQUEST_IN_PROGRESS**;
- 3 秒后 `sipa_nic` 的 `SIPA_NIC_RM_INACTIVE_TIMER` 释放消费者,但消费者**必须等所有生产者 granted
  才能释放完**,于是 `CONS_WWAN_UL` 永久停在 **RELEASE_IN_PROGRESS**;
- `sipa_eth0` 的 TX queue 只在 `SIPA_LEAVE_FLOWCTRL` 里唤醒,而那只在拿到 grant 时发生 →
  **队列永久停住**。地址、路由、`operstate` 全都还在,一个包都出不去。

补丁给对端 2 秒预算,超时按 `SIPA_RM_EVT_FAIL` 把请求撤回,厂商自己的解锁链会把 producer 和
consumer 一起解开、唤醒队列,下一个包重新发起请求。

## 2. 现象

`sipa_eth0` 地址在、默认路由在、`operstate up`,但:

- v4 100% 丢包;
- v6 `sendto: No buffer space available`;
- `mobile-data watch` 修不好(它的探针/重连都基于"地址没了"这类判据);
- **只有 reboot 能救**。

## 3. 现场证据(2026-10-13,uptime 605s,设备正卡着)

`/sys/kernel/debug/sipa/rm_res`:

```
[res] name = SIPA_RM_RES_PROD_IPA     type = 0 ref_count = 1 state = 2   granted  -- IPA 是好的
[res] name = SIPA_RM_RES_PROD_CP      type = 0 ref_count = 1 state = 1   REQUEST_IN_PROGRESS 卡住
[res] name = SIPA_RM_RES_CONS_WWAN_UL type = 1 ref_count = 0 state = 3   RELEASE_IN_PROGRESS 卡住
```

> 解析:该行 state 是第 13 个字段(`awk '{print $13}'`)。

dmesg 时序:

```
605.530121  sipa_rm: calling driver CB
605.530229  sipa_rm: driver CB returned with -115      <- -EINPROGRESS,不是"错",是"还没好"
605.530236  sipa_rm: SIPA_RM_RES_PROD_CP state changed 0->1
605.530257  sipa_eth: fail to send, ret -115
605.535504  sipa_eth: stop queue on dev sipa_eth0
605.535870  sipa_dele: smsg_send, dst=5 chan=120 type=5 flag=1   <- 请求发出去了……
<再无声息>                                                        <- ……对端永远没回
608.530877  sipa_rm: SIPA_RM_RES_CONS_WWAN_UL state changed 1->3
```

## 4. 为什么 `sipa_dele_reset` 也救不回来

`echo 1 > /sys/kernel/debug/sipa/sipa_dele_reset` 走 `cp_dele_restart_handler()`:它把 SIPA 断电、
丢掉 `CONS_WWAN_DL`,**但完全不碰 delegator 的 `stat`**,所以 `PROD_CP` 依旧 REQUEST_IN_PROGRESS、
`CONS_WWAN_UL` 依旧锁死。这就是"只有重启能救"的直接原因。

## 5. 补丁

`kernel/patches/sipa-delegate-peer-request-timeout.patch`(改 `sipa_dele_cmn.c` / `sipa_dele_priv.h`):

- `SIPA_DELE_PEER_TIMEOUT_MS = 2000`,进入 `REQUESTING`(首次请求 / 重试 / 通道重开 / release 后再请求)
  或 `RELEASING` 时 arm 一个 `delayed_work`;正常拿到 grant、或释放完成、或 `on_close` 时 cancel;
- 超时且仍在等 → `stat = RELEASED` + `sipa_rm_notify_completion(SIPA_RM_EVT_FAIL, prod_id)`
  —— 这正是厂商在 `smsg_send` 失败时**已经在用**的放弃信号。

解锁链(全是厂商代码,一行没改):

```
FAIL -> producer_handle_cb        -> PROD_CP RELEASED,通知消费者
     -> consumer_handle_cb(FAIL)  -> do_release(CONS_WWAN_UL) -> RELEASED
     -> sipa_nic_rm_notify_cb     -> sipa_nic_rm_res_reinit()(NIC_OPEN 时返回真)-> 清 rm_flow_ctrl
     -> SIPA_LEAVE_FLOWCTRL       -> netif_wake_queue(sipa_eth0)
     -> 下一个 TX 从 RELEASED 重新请求 -> 新的 smsg CMD 发给 CP
```

设计要点:

- **2 秒** ≈ 对端正常往返(同一次日志里是 5–8 ms)的 250 倍,且**故意低于 `sipa_nic` 的 3 秒**
  不活动定时器 —— 要在 nic 自己放弃之前把失败报上去。
- 挂在 **`system_wq`** 而不是 delegator 自己的 `smsg_wq`:后者是单线程,`smsg_send(..., -1)`
  可能在里头**永久阻塞**,超时器会跟着一起卡死。
- 重试(`SMSG_VAL_DELE_REQ_FAIL`)会**重新计时**,不继承一个快到期的预算。

## 6. 已验 / 未验(重要)

**已验**:模块编译干净、装机启动正常;WAN `ping` 0% 丢包;`rm_res` 照旧 `0->1->2->0` 循环;
正常请求 ~8 ms 拿到;6 流 40 秒压测后 **`peer silent` 计数为 0** —— 正常路径不会误触发。
模块 md5 `8bb307a017a9ecd716b552aae837f9eb`,设备上旧模块备份在 `/root/sipa-dele.ko.orig`。

**已验(两次真机假死:2026-10-13 13:56 与 14:13,均在补丁装载后)**:超时**确实触发**(2.0075s / 2.022s),
并且**永久闩锁确实被解开**(两次结账 `rm_res` 全 `state=0`);但**对端没有回来时,承载不会自己恢复**
—— 见 §6.1、§6.2。

### 6.1 第一次真机触发(补丁后)

`dmesg`,一次完整的假死(`SWC` 全保留):

```
652.132556  sipa_rm: SIPA_RM_RES_PROD_CP state changed 0->1        <- 发起请求
652.132561  sipa_rm: SIPA_RM_RES_CONS_WWAN_UL state changed 0->1
652.132582  sipa_eth: fail to send, ret -115
652.137715  sipa_eth: stop queue on dev sipa_eth0
654.140014  sipa_dele: prod_id:4 peer silent for 2000 ms, failing the pending request   <- 补丁,准时(2.0075s)
654.148719  sipa_eth: dev sipa_eth0 SIPA LEAVE FLOWCTRL            <- 厂商解锁链跑通
654.148722  sipa_eth: wakeup queue on dev sipa_eth0                <- 队列被唤醒
654.148730  sipa_eth: fail to send, ret -115                       <- 重试……对端依旧不答
654.153882  sipa_eth: stop queue on dev sipa_eth0
            <此后再无 RM 状态变化;657.8 "nic can't sleep" → 658.2 SIPA 转入 single/suspend>
```

结账时 `rm_res`:**全部 `state = 0`(Released),`ref_count = 0`** ——
对照 §3,补丁前是 `PROD_CP=1` / `CONS_WAN_UL=3` 的**永久闩锁**。这就是补丁证到的效果:
**“只能重启”的那个死锁没了**,变成了“按 2 秒预算重试”。

但 `ping` 依旧 100% 丢包,`sipa_eth0` 地址/路由/`operstate` 全在。原因是 §6 末尾那条:
**CP 自己不答**。旁证(同一时刻):

- WCN 侧好着:`WCN BASE: rx:loopcheck_ack ... cp2_bootup=60344` 一直在回 —— CP2 没死;
- 蜂窝 AT 通道死了:`wcn_sysfs_store_atcmd: buf=AT` 之后紧跟 `WCN BASE: : at cmd read:TAIL_ERR!`
  ——正是 `mobile-data` 里记的“死的是蜂窝 AT 通道不是 WCN”。

所以这次落在**补丁不解决**的那一半:对端再也不回来。此时该由 `mobile-data` 的最后手段兜住
(`CHANGXING60_WAN_REBOOT_AFTER>=300s` + 修复无果 + 裸 AT 不答 → 本 boot 重启一次)。

> **一条必须说清的保留**:这次假死发生时,设备上正跑着一个 8 线程 CPU 满载测试(§功耗测试),
> 与 652s 只差几秒。**不能断言这是“干净的”自然假死** —— 触发源没有确定。补丁本身的行为
> (准时 2.000s 触发、解开闩锁)与触发源无关,但“多久自然发生一次”不能从这次采样。

**仍未验**:对端(SIPA 侧 CP)**回来的**情形 —— 亦即“假死自愈”那条路。要验它得主动停 CP 再拉起来
(`/dev/modem` 的 `MODEM_STOP_CMD` / `MODEM_UNCONDITIONAL_STOP_CMD`,这两个不像 `MODEM_ASSERT_CMD`
那样有 comm 门禁,再 `MODEM_START_CMD`),代价是蜂窝断几分钟、可能要重启,
**属于要专门安排的测试,不是后台任务**。

**补丁不解决的**:CP 为什么变哑。它把"永久锁死、只能重启"变成"有界的重试循环,对端回来了就自愈";
`mobile-data watch` 里那个最后手段 reboot(commit `6c6fe97`)继续兜住"对端再也不回来"的情况。

### 6.2 第二次触发(2026-10-13 14:13,这次是**干净的**自然假死)

上一节那条"当时有 8 线程满载、触发源未定"的保留,**只对 13:56 那次成立**。同一天第二次触发是在
**一个干净的新 boot** 上抓到的:`ps` 里没有任何 burn 进程,而且上次让我怀疑的 veth 客户端测试脚本
在 `/tmp`(tmpfs)**已经不在了**(中间那次重启把 tmpfs 冲掉了)——所以这次**没有任何已知干扰源**。

设备侧 `dmesg`(在 uptime 910 时抓的,完整一个周期):

```
554.291046  PROD_CP 2->0 / CONS_WWAN_UL 2->0                      <- 空闲释放
566.842863  PROD_CP 0->1 + fail to send, ret -115 + stop queue    <- 一次普通请求(离上次释放 12.5s)
566.852154  CONS_WWAN_UL 1->2 + SIPA LEAVE FLOWCTRL               <- 对端 9ms 就回了,这个周期正常收场
581.843014  PROD_CP 2->0 / CONS 2->0                              <- 又空闲释放
592.854604  PROD_CP 0->1 + fail to send, ret -115 + stop queue    <- 下一个周期(11s 后)
594.876740  sipa_dele: prod_id:4 peer silent for 2000 ms, failing…  <- 补丁,准时(2.022s)
594.885739  SIPA LEAVE FLOWCTRL + wakeup queue                    <- 厂商解锁链跑通,闩锁解开
594.885860  fail to send, ret -115 + stop queue                   <- 对端依旧不答
```

结账 `rm_res`:**全部 `state = 0`、`ref_count = 0`** —— 与 §6.1 同样,永久闩锁被拆掉了(补丁前是
`PROD_CP=1` / `CONS_WWAN_UL=3`)。这次 `ping` 回的是 **`Network unreachable`** 而不是"100% 丢包":
因为 `mobile-data` 已经按"地址在但探针不通"把 `sipa_eth0` 拉下来、地址没了 —— **§2 描述的是假死的
早期形态(地址还在、零流量),晚期形态是地址被撤掉**,两种都见过。

之后照旧:`mobile-data` 修不动(这一 boot 里还看到**两个 `mobile-data up` 叠着跑**,PID 14151/15086,
像是 netifd 的 attach 还没结束就被再起一次),最后手段重启兜住 —— **上一 boot 的 pstore 尾部**:

```
[1087.3~] sprd_wdt_fiq: sprd wdt load value timeout =40, pretimeout =20   (×8,看门狗续命在跑)
[1088.417504] reboot: Restarting system                                    <- 用户态 reboot,不是 panic
```

对应上一 boot 的假死起点 ~592s、重启 1088s,差值 ≈496s,与 `CHANGXING60_WAN_REBOOT_AFTER=300` + 60s 门禁
+ 一轮 repair 的量级相符。

### 6.3 第三次(2026-10-13 14:36,同一 boot 内先"看着没事"、再假死)

**6.2 末尾那条"不是每次开机都假死"的推断,当场被这次采样推翻了 —— 记在这里当反面教材。**
重启后的这个 boot,我在 **uptime 545s** 看了一眼:WAN 活着(`PROD=2 CONS=2`、计数在涨、`ping=OK`),
于是写下"这次没事"。**结果它只是在 545s 还没到点**:同一条日志继续往下,

```
595  rx=4539 tx=4186        <- tx 停在这里(最后一次成功发送)
628.626550  PROD_IPA 0->1 / PROD_CP 0->1 / CONS_WWAN_UL 0->1 + fail to send -115 + stop queue
630.652640  sipa_dele: peer silent for 2000 ms, failing the pending request     <- 补丁,准时(2.026s)
630.661600  PROD_IPA released + SIPA LEAVE FLOWCTRL,fail to send -115,stop queue <- 闩锁解开,对端不答
635  ping=loss → 之后 100% 丢包(地址 10.183.3.127/32 还在,计数冻结)
```

结账 `rm_res` 仍全是 `state=0`。**所以准确结论是:三次开机、三次假死**,分别落在
**652s / 592s / 628s**(即 9.9~10.9 分钟),模式相当稳 —— **"约开机 10 分钟一次"这个规律是成立的**,
反倒是中间那次"545s 看着没事"是个采样太早的假象。教训:**这个假死的判定至少要看到 ~650s 才有意义,
中途一次正常不能说明什么。**

至于"是不是每 boot 必发",样本只有 3 个,别当定论;但按这个节奏,设备实际上**约 18 分钟就自己重启一次**
(`mobile-data` 最后手段),这对"拿它当常驻网关/跑魔法"是**根本性障碍**,优先级高于魔法本身。
触发源(CP 为什么到点不答)仍未知,是下一步要查的;`wedge-watch.sh` 就是为它布的采样器。

### 6.4 自愈链条全程(2026-10-13;勘误:原记作"第四次",实为 §6.3 同一个 boot)

> **勘误**(当晚对着 transcript 时间戳 + 设备时区核过):本节原来记成"第四次假死,
> 09:20 起的那个 boot"。设备时区是 **+03**,文件 mtime/日志里的 "09:20" 是**设备时间**
> = 本地 14:20 —— 正是 §6.3 那个 boot:同一组冻结计数 4539/4186、同一对
> 628.626/630.652 时间戳,不可能是两个 boot。顺带 §6.1 的请求发起在 652.13s,
> §6.3 末尾列表里的"566s"是笔误(566.8s 是 §6.2 那个 boot 里一次**正常收场**的请求)。
> 到外出为止,正确的账是**三次开机、三次假死:652 / 592 / 628s**。

这个 boot 的楔死和前两次同签名(628s 前后计数冻结、`fail to send -115`、补丁 2.0s 准时触发)。
这次 worth 记的是**后半段**:假死→自愈→重启→恢复,整条链路第一次被完整观测到:

```
 600   rx=4539 tx=4186        <- 最后一次成功发送,之后计数冻结
 628.626611  fail to send, ret -115
 630.652640  sipa_dele: peer silent for 2000 ms, failing the pending request   <- 补丁,准时
 630.661810  fail to send, ret -115                                            <- 闩锁解开,CP 依然不答
 834   link=down              <- mobile-data 三次探针失败后 ifdown,把地址收走
      (此后 ping 从"丢包"变成 Network unreachable,计数仍冻结在 4539/4186)
 969.313294  reboot: Restarting system      <- 用户态 reboot,不是 panic,也不是看门狗
```

`969s` 这一下就是 `mobile-data` 的**最后手段重启**在起作用(`bad_since≥300s` + 修复一直在跑 +
裸 AT 不答;AT 探针在 `$IFACE` 还有地址时拒问,所以必须先等 834s 那次 ifdown 把地址撤掉)。
判定依据:console-ramoops 里是用户态 `reboot: Restarting system`,前面跟着 `write kmsg to partition`
(写 syslog 分区),不是 panic/看门狗复位。**重启后 WAN 直接恢复**,新地址 `10.170.42.106/32`、
`ping 223.5.5.5` 0% 丢。

**结论(修正后):三次开机、三次假死**(652/592/628s)。恢复路径本身是**通的**,只是代价是
**每 ~16 分钟一次整机重启**(628s 假死 → 834s 撤地址 → 969s 重启),当常驻网关用是不可接受的。
"是不是每 boot 必发"当晚就有了答案(§6.5):**不是必发 —— 假死是概率性的**。

#### 6.4.1 空闲假设实验:第一次没跑成,第二次跑到了第一份**正面**数据(但设备被拿走,没看到底)

为了验证"假死是不是 modem 的空闲/休眠路径触发"(`wan-keepalive.sh`:每 5s 一次 ping,让链路永不空闲),
我在设备上挂了 `/etc/init.d/changxing60-wan-keepalive`(procd,START=99)。**但那个 boot 的有效窗口(0~650s)
里它根本没在跑** —— `/root/wan-keepalive.log` 只有 uptime 873s 之后的 6 行,而 rc.d 的 `S99` 软链
时间戳是 09:35(即 t≈900),也就是**服务是假死之后才 enable 的**。所以那一次 WAN 在 0~650s 是
**纯空闲**的,假死照旧 —— **那一次实验等于没做,不能拿它支持或否定空闲假设**。

已在下一个 boot 修正(服务 enable、procd 实例在跑、crontab 兜底守卫 `* * * * * ps w | grep -q "[w]an-keepalive" || setsid ...`),
**并且那次真的看到了第一份正面数据**:

```
413s   ping 0% 丢 / PROD=2 CONS=2 / tx_errors 累计 8(上一 boot 的残留)
679s   dmesg 里 "peer silent" = 0(boot 至今补丁一次都没触发);"fail to send" 11 次(散发的,非楔死)
708s   ping 3/3 0% 丢,PROD=2 / CONS=2,计数在涨(rx 25156 / tx 19221),keepalive 每 5s 记 ping=ok
```

**这是今天第一个越过 628s 还没假死的 boot**(前四次分别在 566/592/628/≈628s 楔死)。
**但必须说清楚这还不是结论,理由有三**:

1. **混淆变量**:这个 boot 同时多了一个大流量源 —— 用户把 OpenClash(订阅 + mihomo + TUN)跑起来了,
   它本身就让 WAN 一直有流量(代理连接、节点健康检查)。所以"没假死"**不能单独归因给 keepalive**;
   若要把"永不空闲"当结论,得在**关掉 OpenClash、只留 keepalive** 的条件下再复现一次。
2. **判决点本身也还不够远**:当时已证的三次楔死落在 592~652s,这个 boot 只观测到 708s,余量只有 ~56s。
   要下"不假死"的结论,至少得看到 **≥1200s(两个楔死周期)**。
3. **设备被拿走,后续未知**:708s 之后用户拔了设备,这个 boot 之后有没有楔死**没有观测到**。
   所以现在既不能说"空闲假设成立",也不能说"这次没事"。

**已挂上去的东西(等设备回来要么接着测、要么拆掉)**:

| 位置(设备上) | 作用 | 拆法 |
|---|---|---|
| `/etc/init.d/changxing60-wan-keepalive` + `S99` 软链 | 每 5s ping 一次,让 WAN 永不空闲(**临时诊断用**) | `/etc/init.d/changxing60-wan-keepalive disable && rm /etc/init.d/changxing60-wan-keepalive` || `crontab` 那条守卫行 | keepalive 掉线时自动拉起 | `crontab -e` 删掉那一行 |
| `/root/wedge-watch.sh` → `/root/wedge-watch.log` | 10s 一拍的假死采样器(与上面无关,可长期留) | `rm /root/wedge-watch.sh /root/wedge-watch.log` |
| `/root/wan-keepalive.log` | keepalive 的日志(手工起的那份写这里;procd 那份走 syslog) | `rm` |

> 注:`crond` **实际一直在跑**(`/etc/rc.d/S50cron`),之前"crond 不跑"是误判;
> 所以那条 crontab 守卫是有效的,不是一个挂着好看的空指令。
>
> **脚本已入库**(设备被拿走后从 gitignored 的 `work/` 提升到 `tools/`,免得只在本地):
> `changxing60-linux/tools/changxing60-wan-keepalive.sh`(探针本体)、`tools/changxing60-wan-keepalive.init`
> (procd 服务,含装/拆命令)、`tools/changxing60-wedge-watch.sh`(10s 采样器,顺带修掉了 `grep -m1`
> 那个会往日志里插换行的老毛病)。

### 6.5 外出一天 + 当晚定论(2026-10-13):**keepalive 防不住;假死是概率性的**

**下午外出(14:50 前后拔电 → 21:44 前后回桌,纯电池 ~6h53m)**:keepalive(S99 自启 +
crontab 守卫)和 OpenClash 在每个 boot 都在跑,期间设备按 ~16 分钟一轮"楔死 → 最后手段重启"
循环(970.7s/轮,推算 **20~25 次重启**;pstore 只留最后一轮,但证据链完整):

```
[  543.11s ]     请求发起,对端不答(四次里最早的一次)
[  545.116022]  sipa_dele: prod_id:4 peer silent for 2000 ms, failing the pending request
[  970.705383]  reboot: Restarting system     <- 用户态,前有 write kmsg,同款最后手段链条
```

用户回桌后亲眼撞上它 21:58 的那次重启(原话"刚下又重启了"),就是上面这个 970.7s 的 reboot。

**两个定论:**

1. **keepalive 防不了楔死,"空闲假设"死亡。** 外出的每个 boot 都有每 5s 一次的 ping 和
   OpenClash 的持续流量,楔死照样发生(543s,还是四次里最早的)。§6.4.1 那次"708s 没死"
   只是采样窗口不够长,不是 keepalive 的功劳。keepalive 已按 §6.4.1 的表拆除
   (disable+rm、crontab 守卫行删、进程杀、脚本/日志删);`wedge-watch` 采样器保留。
2. **假死是概率性的,不是每 boot 必发。** 21:58:49 起的当前 boot 同样 keepalive+OpenClash
   在跑,**跨过 1200s 判决线并继续干净**:1200.13s 时 peer silent=0、ping 3/3、计数在涨;
   到 2031s 依然 PROD=2/CONS=2、0% 丢包。
   **(当晚续记)这个 boot 后来还是楔死了——在 ~2955s**:wedge-watch 日志里 2950s 计数
   最后一次变动(rx=3740 tx=4166),之后冻结;3260s mobile-data 撤地址;3402.9s 最后手段
   重启(pstore 尾部同款 `write kmsg` → 用户态 `reboot`)。**即 boot 5 的"通过"只维持到
   2435s,判决线被正式击穿:楔死窗口不是 543~652s,是 543~2955s(观测到的范围),
   1200s/2031s 的"通过"都不能下结论。**当时(2955s 前后)我在做充电寄存器实验
   (读寄存器+一次 REG04 单字节写),但那四次楔死全都发生在无任何交互的 boot 上,
   且充电 I2C 与 CP/SIPA 之间不存在机制通路,判为巧合,记录在案。
   连同外出前,完整观测的 boot 是"五个楔死、零个真通过"。下一步方向是查 CP 侧,
   而不是继续堆对照实验;想下"这 boot 没楔"的结论,观测窗至少要小时级。

**用户对"自动重启了好几次"的三个猜想,全部排除**(查过现场,不是猜的):

| 猜想 | 排除依据 |
|---|---|
| 电压不稳/降压重启 | bootcause=`Reboot into normal`(欠压会是 `Reboot into under voltage`);回桌时电池 418‰/3.8V,离 3.45V 截止电压很远 |
| 过热重启 | 当前 boot 全部热区 37.2~40.8°C,远低于任何阈值;过热复位的 bootcause 也不是 normal |
| swap 满了溢出内存 | zram 2.8GB **used=0**(SwapFree=SwapTotal),MemAvailable 5.3GB;重启是用户态 `reboot`,不是 OOM |

**"会概率性没有网络" = 这个循环的必然表现**:每 ~16 分钟一轮,从楔死到重启完成约 8 分钟
WAN 是死的,占比约一半 —— 任何时候去用都有一半概率撞上死窗;撞上了等 ~2 分钟重启完成
就自己恢复。

### 6.6 上游两条加载期补丁搬进 5.4 + CP 停/起止血实验(2026-10-13 晚,纯模块级部署)

**做了什么**:把上游 `changxing60-linux` 的两条 sipa_delegate **加载期**补丁搬到我们的 5.4 树上,叠在
2s 超时补丁之上 —— `kernel/patches/sipa-delegate-einprogress.patch` +
`kernel/patches/sipa-delegate-pm-runtime.patch`(工作树 `git diff` = 3 个文件:
`sipa_dele_cmn.c` / `sipa_dele_cp_in_ap.c` / `sipa_dele_priv.h`)。只重编 `sipa-dele.ko`,
**不刷 boot 镜像**:三条补丁全都在这一个模块里,而本机模块是从
`/lib/modules/5.4.254-gb50db5b6224c/` 由 modprobe 加载的,boot 期没有任何东西会重新同步模块
(`rootfs-fixups` 只修 capabilities)。新模块 strip 后 41312 B、md5 `5836e22a…`,旧模块备份在
`/root/sipa-dele.ko.bak-5.4.254-gb50db5b6224c-8bb307a0`,loop0 的两个挂载点都已换。

**怎么确认新的真加载了**(不是看文件 md5——内核不记这个):重启后的 boot log 出现
`sipa_dele: sipa pd_eb_flag = 1, pd_get_flag = 1`,而 **`pd_get_flag` 是 pm-runtime 补丁新增的字段**,
旧模块不可能打出这行。`sipa_dele get pd success ret = 0` 也在(若 `ret < 0` 会改打
`ENABLE answered with FAIL`)。部署后 WAN 正常:`sipa_eth0` 地址在、ping 通、两个 RM state = 2。

**诚实前提:这两条是"正确性修复",不是已验证的解药。** 上游 FINDINGS §31f 那个签名
(`sipa_rm_add_dependency()` 在 probe 时返回 `-EINPROGRESS` → 被当失败 → 删 PROD_CP →
`cp_delegator_init failed: -22` → 释放中的 delegator 撞上还在跑的连接线程)**在本机不成立**:
我们的 delegator probe 是**绑定成功**的(5.4 `really_probe()` 成功路径把 `ret` 设成 1,
即 dmesg 那句 `probe of … returned 1` = 绑上了,不是"返回了 1 所以失败")。加载期 20s 前后那句
`get resource failed for remote-base!` / `dts parsing failed` 是**无害噪声**:失败的是 `"mem-base"`
资源查找,`dev_err(dev, "dts parsing failed\n")` 之后代码**没有 return**,而
`cfg.mem_base/reg_base/ul_fifo_depth/dl_fifo_depth` 全树**没有任何读取点**
(`sipa_dele_cp_in_ap.c` 里根本没有 `cfg`)。所以这场部署是**把上游同族挂死的修复摆到位**,不是解药;
真判决仍要看小时级观测 + CP 侧。

**CP 停/起干跑(已批准,确定性实验)**:用 `tools/modem-ioctl`(`/dev/modem` ioctl,`MODEM_STOP/START_CMD`
无 comm 门禁)在**健康 boot** 上先停后起,看链路能不能自己回来。结果——AP 确实把 CP 停住了:

```
716.407  modem run = 0!                              <- 内核,真正的停机点
716.524  stop over                                   <- 厂商栈收尾
721.034  PROD_CP 2->0 / CONS_WWAN_UL 2->0            <- RM 会话全部释放
721.428  sipa ready to suspend and change to single  <- 进单模
```

随后 **~5-10s 内整栈自己重建,全程无重启**。也就是说:**modem 子系统级恢复是一个可用的抓手**
(真楔死时尚未实测,但这是把"整机重启"降级的第一候选)。脚本 `tools/changxing60-cp-reset.sh`
(`status|dry|recover`):实验前 `touch /var/run/changxing60-wan-rebooted` 把 `mobile-data` 的最后手段重启
**解除武装**,并坚持一条铁律 —— **地址还在时绝不往 `/dev/stty_nr1` 写 AT**(AT 口和活着的呼叫是同一个口,
往里面灌字节就是污染数据流;`mobile-data` 的 `at_state()` 出于同样理由在 `link_up` 时不探)。前提:
`modem_control`(chroot 里的厂商守护)全程在跑,否则 PM 协处理器会切电。实验窗口只把 CP 停 ~20s。

> ⚠ **口径已更(2026-10-16)**:`tools/modem-ioctl.c`、`tools/build-modem-ioctl.sh`、
> `tools/changxing60-cp-reset.sh` **都已入库**(`git ls-files` 可见)。仍然不进 git 的只有**编译产物**
> `tools/modem-ioctl`(3024 B 静态 aarch64,无 libc 无解释器),它由 `tools/build-modem-ioctl.sh`
> 生成、由 `openwrt/build-rootfs.sh` 从 `tools/` 拷进镜像的 `/opt/changxing60/bin`。
> ⇒ **新克隆的树要先跑一次 `tools/build-modem-ioctl.sh`**,否则 build-rootfs 只打一句
> `debug tool missing: tools/modem-ioctl` 就**继续**(软失败);那种机器上 `cp_reset` 的 preflight
> 会拒绝 —— 而这个拒绝现在会带理由写进 `/root/selfheal.log`(§6.7),不会像 2026-10-16 那次一样
> 只剩沉默。

**现状**:新模块已在跑,`wedge-watch` 采样器已在当前 boot 启动,进入**小时级**观测
(§6.5 的教训:543~2955s 都可能落楔,1200s / 2035s 的"通过"都不算数)。

### 6.7 2026-10-16:上一次假死**为什么归不了因**,以及把 CP 停/起本身变成证据

**现场**(2026-10-16 凌晨那个 boot;`console-ramoops-0` 只剩 769→1597s 的窗口):
1100.7s 我们的 2s 对端超时补丁照常触发(`sipa_dele: prod_id:4 peer silent for 2000 ms` ——
`pr_err`,所以它**能**进 console 抓取);1590~1592s 有 WCN 的
`sc2355_dis_flush_txlist` / `Drop command CMD_SET_PARAM in case of power off`;1595.9s 某个 pid 往
`common_rs1_a` 写 last-kmsg 失败(重启路径自带),1597.7s `reboot: Restarting system`。

**谁按的重启按钮,这个 boot 说不了**:时间上最像 `mobile-data` 的 WAN 阶梯(坏起点 ~1100s + 300s
阈值 + CP 停/起那 90s 等待 ≈ 1500~1600s),但同一分钟里 WCN 正在 flush / power off,又像
`hotspot-watch` 的 `wifi down` 修复 —— 两个脚本都能走到 `reboot`,而当时**谁都没留落盘的理由**
(ring 与 `/var/run` 都不跨重启)。这就是 2026-10-16 那两处修复(§6.7 末)要堵的洞。

**这个 boot 为什么永远说不清**——一条结构性事实,比任何一次事件都值得记:

> **本机 console 只收 ERR 及以上;`dev_info` 一律不进 console,所以 pstore 里也永远没有它。**

- `quiet-console` 把 `/proc/sys/kernel/printk` 钉成 `4 4 1 4`(console_loglevel=4 ⇒ 只有
  `level < 4` 即 EMERG/ALERT/CRIT/ERR 会打到 console;cmdline 的 `loglevel=1` 只管更早的一段)。
- CP 停/起这一路**每一句都是 KERN_INFO**:`modem_run()` 的 `%s modem run = %d!`、
  `soc_modem_stop()` 的 `stop over`、sipa 的 `PROD_CP 2->0`、`sipa ready to suspend`。
- 两个方向都实测过(banked 的 `console-ramoops-0`):`sipa_eth: fail to send, ret -115`
  (`pr_err`,`sipa_eth.c:137`)出现 **16 次**,而 `sipa ready to suspend and change to single`
  (`dev_info`,`sipa_core.c:596`)**0 次** —— 同一 boot、同一时刻 dmesg 里明明有(§6.6 干跑那份
  记录就是从 dmesg 读的)。
- 而 **dmesg 环形缓冲不跨重启**。⇒ "上次假死时 CP 到底停没停",**重启之后从内核侧问不出来**;
  唯一能留下答案的是**用户态写盘**。**没有 `modem run` 那一行,推不出"ioctl 没发"** ——
  那是把日志过滤当成事实。

**顺带把楔死机制从厂商源码里读清楚**(`upstream/modules/sprd_modem/modem_loader/sprd_modem_loader.c`;
免得下一个人再推一遍):

- `modem_run(modem, b_run, b_restrict)`(:806):`dev_info("... modem run = %d!")` 打在
  `b_restrict` 检查**之前**;`b_restrict && run_state == b_run` 时返回 `-EINVAL` —— 是"重复操作"
  护栏,不是安全锁。(注:这句仍是 KERN_INFO,照样进不了 console。)
- `soc_modem_stop()`(:783)是**开环**的:四次 `regmap` 戳 CTRL 寄存器 + 200ms `msleep`,
  **不可能阻塞**。⇒ `modem-ioctl stop` 的 rc 只说明"ioctl 被接受",不说明"CP 停了"。
- CP 的 AP 侧运行标志**可读**:`cat /sys/kernel/debug/modem/modem` → `run_state: 1, remote_flag: 0`
  (`:1213` 的 seq 文件;`phycp`/`pmsys` 是另外两个 device)。健在的呼叫上实测 `run_state=1`。
- `MODEM_ASSERT_CMD`(`smsg_senddie`,`:976`)是**唯一**有 comm 门禁的命令
  (`strcmp(current->comm, "modem_control")`);`stop`/`start`/`ustop`(:967/:971/:994)都没有门禁。

**所以把杠杆本身变成证据**(`mobile-data` 的 `cp_reset()`,2026-10-16 部署,`tools/mobile-data/test-escalate.sh`
36 项全过、设备上 `sh` 与 `bash` 双壳复跑、且是对**已部署文件**跑):

- preflight 的每条拒绝理由(工具不可执行 / 设备节点不对 / `modem_control` 不在)都落盘;
- `stop`/`start` 的 **rc + 工具那一行输出 + `run_state` 前后值**都落盘(以前 `"$CP_TOOL" stop >&2 || true`
  把 rc 直接丢掉,输出只进易失 ring);`run_state` 读不到时写 `?->?`,不假装知道;
- 90s 等待的两种结局都落盘 —— **"没重启就自愈"以前也没记录**;
- 全部写 `/root/selfheal.log`(ext4;`note()` 自带 200 行 trim),`bootdiag` 的每分钟 dump 里带
  `--- selfheal` 尾 10 行。同一个 `note()` 也把 `hotspot-watch` 的重启理由写进同一个文件、带自己的 tag。

**下一次假死一条命令就能判**(`ssh root@192.168.77.1 cat /root/selfheal.log`):

| 看到 | 结论 |
| --- | --- |
| `cp-reset refused: ...` | preflight 挡了,杠杆根本没动 → 先修 preflight 的前提 |
| `stop rc=0 run_state 1->0` 且呼叫没回来 | 杠杆有效但**不够** → 下一个候选是 `assert`(有 comm 门禁,要写个小 wrapper 先 `prctl(PR_SET_NAME, "modem_control")`) |
| `stop rc=0 run_state 1->1` | CP 不理这个停 → 楔死在 CP 里比 loader 更深 |
| `stop rc=-22` | 重复操作护栏(`run_state` 已经是 0);注意这句 `modem run = 0!` 照样进不了 console |
| 压根没有 `cp-reset:` 行 | 这一 boot 没走到停/起(例如 `CP_MARK` 已花掉,或阶梯还没到),此时应有 `... cp_restart_spent=1): rebooting` 或只有 `repairs not helping` 之类的前置行 |

> `cp_reset` 每次 outage 只花一次(`CP_MARK=/var/run/changxing60-wan-cp-reset`,健康呼叫一到就清),
> 所以同一 boot 的**第二次**楔死是直接重启 —— 这也是"没有 `cp-reset:` 行"的一个正常解释。

**为什么 `note()` 写 ext4 而不写 `/dev/pmsg0`**:pmsg(ramoops,`dts` `pmsg-size = 0x8000`)是
`boot/init` 的引导阶段日志通道,优势是**rootfs 都没挂上时它还在**(所以 initramfs 用它);
但 `mobile-data`/`hotspot-watch` 就住在 rootfs 上 —— 它们能跑 ⇒ ext4 一定在 ⇒ pmsg 没有增量。
要读上一 boot 的引导阶段还是 `cat /sys/fs/pstore/pmsg-ramoops-0`(见 §7 注)。

**本次一并修掉的"证据链本身"的两个 bug**(§6.7 的前半部分工作):

1. `bootdiag` 的"每 boot 十份 dump"以前数的是 **ext4 目录里的文件数**,而文件名是 uptime ⇒
   每个 boot 重写同样那十个名字 ⇒ 计数被钉在 10,**2026-10-15 22:42 之后这个通道整一天没出过 dump**
   (就在最需要它的那段)。现在计数放进 `/tmp`(每 boot 归零),并保留最新 `MAXKEEP=30` 份
   (文件名很少真的撞上,实测一个 boot ~3.3 MB,而本机一天重启 20~25 次)。
2. `mobile-data`/`hotspot-watch` 调 `reboot` 之前**只**写易失 ring / `/var/run` ⇒ 上一 boot 是谁、
   为什么重启,**重启后无从查证**(上面那个 boot 就吃了这个亏)。现在先写 `/root/selfheal.log`。

## 7. 观测手法

```sh
# 一条命令看全:uptime/内存/RM state/SIPA 计数器/WiFi/魔法/温度/电量/pstore/日志尾
# (只读,不发 AT,楔死现场第一个该跑的就是它;也会留一份到 /root/diag/<uptime>s.log 方便前后对比)
# 注意:ssh 跑单条命令是非交互 shell,PATH 里没有 /opt/changxing60/bin,要写全路径
ssh root@192.168.77.1 /opt/changxing60/bin/changxing60-diag.sh

# 当前 RM 状态(卡住时看 PROD_CP=1 / CONS_WWAN_UL=3)
ssh root@192.168.77.1 'grep -E "PROD_CP|CONS_WWAN_UL" /sys/kernel/debug/sipa/rm_res'

# 补丁是否触发过
ssh root@192.168.77.1 'dmesg | grep -c "peer silent"'

# CP 的 AP 侧运行标志(1=在跑)。判"停/起有没有真发生"看这个,别信 ioctl 的 rc —— 见 §6.7
ssh root@192.168.77.1 'cat /sys/kernel/debug/modem/modem'

# 上一 boot 是谁按的重启、为什么,以及 CP 停/起的 rc + run_state 结局(ext4,跨重启)
ssh root@192.168.77.1 'cat /root/selfheal.log'

# 复现尝试:6 流 40 秒(不一定每次都能压出来)
cd changxing60-linux && tools/net-down-test.sh wan 6 40
```

`/sys/kernel/debug/sipa/*` 全部是 0444 只读,别打算往里写。

**读 pstore 的 console 抓取时先记住这一点**(2026-10-16 买来的教训):`quiet-console` 把
console_loglevel 钉在 **4**,所以 `console-ramoops-*` 里**只有 ERR 及以上**;`dev_info` 全都不在 ——
`modem run = 0!` / `stop over` / `PROD_CP 2->0` / `sipa ready to suspend` 一句都没有
(实测对照:`sipa_eth: fail to send` 是 `pr_err`,在;`sipa ready to suspend` 是 `dev_info`,不在)。
**别拿"pstore 里没有这行"当"这事没发生"的证据。** 要问 CP 停没停,只有 `/root/selfheal.log`(§6.7)。

**要看"是不是真没事",必须看到 uptime ≥ ~1200s**(§6.3 的教训:545s 看着好、628s 就死了;
§6.4.1 里 708s 没死也不算数 —— 楔死窗口 543~652s,至少要跨过两个周期;
§6.5 里 1200s/2031s 两读才是"通过"的样子)。**§6.5 续记之后这条也要修:boot 5 跨过
2435s 仍在 ~2955s 楔死 —— 观测到的楔死窗口实为 543~2955s,1200s 只够排除"早发"型;
要宣布一个 boot 干净,得看到小时级,或干脆等 CP 侧根因修掉。**
想连续看就上采样器(10s 一拍,记 uptime / 两个 RM state / rx,tx / 每分钟一次 ping;
**故意不每拍都 ping**,免得自己把链路喂活、把假死盖掉):

```sh
ssh root@192.168.77.1 'setsid /root/wedge-watch.sh >>/root/wedge-watch.log 2>&1 </dev/null &'
# 脚本源:changxing60-linux/tools/changxing60-wedge-watch.sh(已入库;对应"永不空闲"那个探针是
#        changxing60-linux/tools/changxing60-wan-keepalive.sh + tools/changxing60-wan-keepalive.init)
```

## 8. 上游调查(2026-10-13,全部用 `gh`,未用 WebFetch)

**没有任何人修过这个运行时假死,也没有与补丁冲突的更权威修法:**

- **运行时请求路径在所有 UMS9620 树里都没有超时。** vendor 甚至在
  `drivers/net/sprd/sipa_v3/sipa_priv.h:53` 写了 `#define SIPA_RM_REQUEST_TIMEOUT (1 * HZ)` ——
  但**是个死宏**:grep 只有定义、没有使用点。另一个 `SIPA_RM_MAX_WAIT_TIME (HZ * 10)` 只被开机的
  `sipa_rm_add_dependency_sync()` 用。**意图本来就有,只是从没接上**;补丁就是把这个意图放到真正
  等待的那个位置。
- `dikeckaan/zte-ums9620-kernel-5.4.254` 碰 `sipa_v3` 的提交**只有一条** `b07050f10a first upload`
  —— 纯 vendor 镜像。`SIPA_WWAN_CONS_TIMER` / `SIPA_NIC_RM_INACTIVE_TIMER` 在 Enceka f50/u30air、
  Ssrml p720_w205ds、liuwang97 f50 里全部一致,**没有任何仓库把它做成 module_param 或 sysfs 旋钮**。
  issue 搜索 `sipa_rm -115` / `sipa_dele` 搜不到这个假死。
- 上游仅有的 sipa_delegate 补丁都是**加载期**的(kanoqwq `eb5336875c` / dikeckaan `1cee306e7e`,
  即 `sipa-delegate-einprogress.patch`:probe 时容忍 `sipa_rm_add_dependency()` 的 `-EINPROGRESS`、
  `devm_kzalloc`→`kzalloc`、检查 `sipa_delegator_start()` 返回值),**不涉及运行时状态机**。
  (那个 `clean-tf-7.2` 分支 2026-10-16 已查过,**对 WAN 假死没有别的东西可拿** —— 见
  [`e5-linux.md`](e5-linux.md) §7 的三仓对比结论。)
- vendor 唯一的恢复口就是上面那个 `sipa_dele_reset` sysfs —— 够不到 delegator 的 `stat`,治不了这个病。
  `sprd-linux-devs/e5-linux` 的 `4de42b4115`(“bearer: a watch that brings it back after a CP reset”)
  是**同一个思路的 userspace 版**:CP 重置后把链路拉回来,而不是无限等。
- **最强旁证**:`dikeckaan/mu300-linux` 的 `docs/reference/android-ipa-state.txt` 是**原厂 Android 在
  这台硬件上的实测抓包**,里面有**一模一样的序列** —— RM 空闲释放 → “ready to suspend and change to
  single” → `driver CB returned with -115` → `sipa_eth: fail to send, ret -115`,**然后 Android 在
  2.2 ms 后就恢复了,因为 CP 在 chan 120 上回了**。可见 `-115` 本身是正常的、不是故障,**唯一缺的就是
  “CP 不回时怎么办”** —— 正是这个 2 秒超时补上的那一环。

复核命令(节选):

```sh
gh api repos/dikeckaan/zte-ums9620-kernel-5.4.254/contents/drivers/net/sprd/sipa_v3/sipa_priv.h --jq .content | base64 -d | grep -n TIMEOUT
gh api "repos/dikeckaan/zte-ums9620-kernel-5.4.254/commits?path=drivers/net/sprd/sipa_v3" --jq '.[].sha'
gh search issues "sipa_rm -115"
gh api repos/kanoqwq/mu300-linux/contents/kernel/patches/sipa-delegate-einprogress.patch?ref=clean-tf-7.2 --jq .content | base64 -d
gh api repos/dikeckaan/mu300-linux/contents/docs/reference/android-ipa-state.txt --jq .content | base64 -d | grep -n "115\|1->2"
```

## 9. 2026-10-16:CP 侧复位链缺一个客户端应答者(`@modemd`);"把 cptl 搬过来"这条路已封死

两条新证据,把"还能从哪儿下手"收窄了一圈(细节另见 [`cptl-and-boot.md`](cptl-and-boot.md)
与 [`e5-linux.md`](e5-linux.md)):

1. **`/proc/cptl/modemassert` 搬不了 —— 安卓自己也没有。** 只读解剖 `boot_a`(内核 40.3 MiB
   未压缩 Image)+ `vendor_boot_a`(vendor_ramdisk 里 165 个 `.ko`)+ `/vendor_dlkm/lib/modules`
   (150 个)+ 安卓实机 199 个已加载模块 + DTB,**`cptl` 零命中**(方法自检:`sprd` 363、`modem` 10、
   `mali` 11)。这台机器上 assert/alive 走的是 **`/dev/spipe_nr2`**(由
   `ro.vendor.modem.assert=/dev/spipe_nr2` 点名,设备节点确实存在),
   `modem_control` 里那串 `/proc/cptl/*` 是**通用代码的死分支**(它自带
   `open %s unsupport watchdog, errno: %s` 容错)。
2. **我们真正缺的是 `@modemd` 的应答者。** `modem_control` 二进制里
   `client cnct to modemd` / `SLOGMODEM DUMP COMPLETE` / `reset_md_thread wait dump complete...`
   一应俱全 —— 它**复位 CP 前要等日志侧回一句 `SLOGMODEM DUMP COMPLETE`**(安卓上由 `slogmodem` 发)。
   而我们盒子上 `/proc/net/unix` **只有我们自己的 `/dev/socket/logdw`,没有任何 `@modemd`**
   ⇒ 厂商自带的 CP 复位链在我们这里**没有应答者**,这与"CP 侧只能靠重启整机"完全一致。
   上游 [`e5-linux`](e5-linux.md) 有一份 **160 行的 `e5-modemd.c`** 专治这一点:秒回该字符串,
   assert→Reset→Alive 从 **300 s 压到 4–5 s**(他们 §30 实测 300 s、§47.6 实测 4–5 s),
   还能用 `blocked` 子命令**按需**触发一次 CP 复位(治"AT 假死但不 assert")。
   **这是目前最有希望的治本候选。**
   ⚠ **方向别搞错**(2026-10-16 逐行读 `e5-modemd.c` 勘正):**建 `@modemd` 监听/accept 的是
   `modem_control` 自己**(它的错误串就是 `Failed to create modemd listen accept thread`),
   `slogmodem` 与 `e5-modemd` 都是**连上去的客户端**。所以"没有 `@modemd`"可能是两件事:
   **(一)我们的 `modem_control` 根本没建出这个 socket**(没跑起来/线程失败),
   **(二)建了但没人当客户端应答**。这两条修法完全不同。

**下一步(未做,等确认)**:先做**零成本的那一眼** —— 开机 `android-vendor-start` 起来后
`grep modemd /proc/net/unix`,分清上面(一)还是(二);**(一)** 就去查 chroot 环境
(上游 e5 §13 的四要素清单:property area 属主 `root:root`、logdw sink、`ueventd.rc` 节点权限、
`/proc/cmdline` 的 `slot_suffix=_a` bind、必须 `exec chroot` 直跑 Android ELF),**(二)** 才轮到
移植 `e5-modemd`,且**先写只监听不应答的探针版**,等下一次真楔死时看 `@modemd` 上到底有没有请求、
内容与时机如何(不改变现有行为、纯取证);确认协议无误后再让它应答,并用 §6.6 已有的
`run_state` 遥测判"CP 是不是真的自己回来了"(判据不能只信 ioctl 的 rc)。
**别一上手就上生产**:应答错了可能让它在不该复位的时候复位。
