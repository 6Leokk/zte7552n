# IPv6 双栈:蜂窝 WAN + 热点下游(2026-10-13 实测通过)

> 记录日期:2026-10-13。设备 = 原生 OpenWrt 25.12.5(path A 持久 ext4),自编 5.4.254 内核。
> 关联:[`access.md`](access.md)(怎么连进去)、[`screen-plan.md`](screen-plan.md)(全功能自查)、
> 代码级记录见 `changxing60-linux/docs/FINDINGS.md` §31/§32。
>
> 需求原话:**「ipv6必须可用,双栈都要正常」**。本文件记的是这条需求现在的落点:哪些是实测的、
> 怎么复测、以及**还没验到的那一块**(WiFi 空口)。

## 1. 现在的状态

| 位置 | 状态 | 证据 |
|---|---|---|
| 蜂窝 WAN(bearer) | ✅ 公网 IPv6 地址 + RA 默认路由,**重拨/开机自动拿到**,不用手工命令 | 强制重拨后 `2409:8947:39b:557:...:3941/64` 自己回来;重号后前缀跟着换;**冷启动也验过**:一次意外重启后新前缀 `2409:8948:3c1:1e3:.../64` 自己回来(见 §5 末尾那次崩溃) |
| 热点下游(br-wifi) | ✅ odhcpd 中继运营商 RA,客户端 SLAAC 出**公网**地址 | 抓包见 RA:`2409:8947:39b:557::/64` `Flags [auto]`,有效期 infinity |
| 下游出网 | ✅ NAT66 改写源地址 + 回程走 `/64` 路由 | 链路抓包:bearer 上 echo request 的源**是设备自己的地址**,不是客户端的 |
| 下游 DNS | ✅ 走 IPv6 传输可解析 | 客户端 `nslookup -type=AAAA www.qq.com 2409:8088::8` 拿到 AAAA |
| 管理口 br-lan | ✅ 故意**不给** IPv6(与 IPv4 的拆网段规则一致) | 见 §3 |
| **WiFi 空口** | ⚠️ **未验证**(见 §5) | 测试客户端走的是网桥,没走 WiFi 驱动 |

IPv4 未受影响(重拨后 v4 照常,`10.230.17.125/32`)。

## 2. WAN 侧:为什么原来没有 v6

三条根因,按发现顺序:

1. **APN 不是问题**。`AT+CGDCONT?` 显示 context 早就是 `IPV4V6`(配置里 APN 为空 → 走网络默认
   `cmnet`),`AT+CGCONTRDP=1` 也确实带 IPv6 字段。**但它的地址字段只有接口标识、前缀是零**
   (`::18dd:fcd3:369a:2978`)—— 所以"从 AT 里读前缀"这条路永远是空的,前缀只在 RA 里。
   (本轮一开始我误判成"context 是 IPv4-only",是错的:那次的 18 秒静默实际是 **WAN 当时正好死了**,
   见 §4 的 SIPA 说明。)
2. **运营商不发主动 RA**,只应答 RS;而**没有任何东西发 RS**:`net.ipv6.conf.all.forwarding=1`(热点需要)
   会把每个接口的 `accept_ra` 默认压成 0,bearer 又没人给它配 IPv6 协议(bare `sipa_eth0`,arptype 519)。
3. **顺序陷阱**(在链路上抓包量出来的,同一根 bearer 连续试):

   | 动作 | 发出的 RS | RA |
   |---|---|---|
   | 只把 `accept_ra` 0→2 | 0 | 无 |
   | `accept_ra` 已 2,再把 `disable_ipv6` 1→0 | 2 | 57 ms 后回来 |
   | 先重启 addrconf,**再**把 `accept_ra` 0→2 | 0 | 无 |

   第三行最容易踩:重启 addrconf 会把 RS 排进队列,**之后再写 `accept_ra` 会取消这个待发请求**,
   于是又静默 30 秒,看起来就像"这张卡没有 IPv6"。正确顺序:**先 `accept_ra`,再重启,之后什么都别碰**。

修复落在 `proto changxing60cell` 的 `ipv6 'relay'` 分支(`changxing60-linux/openwrt/overlay/lib/netifd/proto/changxing60cell.sh`)。
地址和默认路由由内核 SLAAC 自己管,不报给 netifd(odhcpd 是直接从线上读 RA 的)。

RA 的寿命是 **infinite**,所以地址永不续期 —— 这就是每次拨号前要 **flush** bearer 的 v6 的原因:
不然重号之后旧前缀会赖到本次开机结束,和新前缀叠在一起。

## 3. 下游侧:三件事同时成立才行

* **中继**:`dhcp.wan` 作 `master`(RA 从这条口进)、热点作 `ra/dhcpv6 = relay`。客户端因此拿到公网前缀的
  地址,网关是热点自己的链路本地。实测 RA 长这样:

  ```
  fe80::.. > ff02::1: ICMP6, router advertisement
    hop limit 0, Flags [other stateful], pref medium, router lifetime 65535s
    prefix info option: 2409:8947:39b:557::/64, Flags [auto], valid time infinity, pref. time infinity
  ```

  两个细节:标志是 odhcpd 自己定的(**中继模式下配置里的 `ra_flags` 不起作用**,这里是 SLAAC 而
  不是 DHCPv6 派址);**RA 里没有 RDNSS**,客户端不会从 IPv6 拿到解析器 —— 实际影响不大(双栈客户端
  用 IPv4 的解析器查 AAAA 是常规做法),但纯 v6 客户端会没有 DNS。
* **NAT66**:运营商只路由它分配给设备的那一个地址,回给客户端的包会被丢,所以 wan zone 要 `masq6`。
* **回程路由**:默认**没有**到 LAN 的路由(`changxing60cell` 每次 setup 都会清 bearer 的 v6 路由),
  查客户端地址会落到默认路由、从 modem 出去然后消失。`ndp-learn` 把 bearer 的 `/64` 挂到 br-wifi
  (metric 128,低于 RA 在同一前缀上那条 metric 256 的路由),并跟随重号。上游那份里"给每个邻居条目钉
  `/128`"的部分**故意不搬**:任何主机用一个伪造的邻居通告就能把任意地址(别的客户端、路由器自己、
  某个公网 DNS)钉到 LAN 上,那是路由劫持。

`br-lan`(USB 管理口)**不参与**:它连 IPv4 都不发网关/DNS,因为那条链路在 Windows 上会把电脑真实
出口的默认路由压下去(见 `access.md`);IPv6 上放一条默认路由是同一个错误的另一个版本。

## 4. 怎么复测

设备上直接跑(工具已入库):

```sh
tools/net-v6-client-test.sh br-wifi          # 真·转发客户端:veth 进 netns 挂到 br-wifi,自己 SLAAC
tools/net-v6-client-test.sh br-wifi --keep   # 留着不删,方便手工进去看
```

> **⚠ 这个工具有前科:它把内核跑崩过一次(2026-10-13),见 §5 末尾。** 崩的是**收尾**(删除挂过网桥的
> veth / 拆 netns 那一半),不是转发路径。**真机连热点是更安全也更算数的验证**;要用这个工具就接受
> "手机可能重启"。

它做四件事:抓客户端收到的 RA 原文 → 打印地址/路由 → ping6 两个公网 v6 → 对运营商 v6 resolver 做
AAAA 查询。**为什么必须用 netns**:放在设备自己的命名空间里,中继来的 RA 会被**设备自己**收走,
地址和默认路由落进主表,包就是本地生成的了 —— 绕过了 FORWARD、NAT66 和回程路由,恰好是真正要验的部分。

WAN 侧自愈/重拨:

```sh
ip -6 addr flush dev sipa_eth0 scope global     # 伪装成"还没有 v6"
/opt/changxing60/bin/net-split --apply                # 守卫会自己重拨把 relay 拉活
```

注意:**netifd 的 `network reload` 不会重启"协议选项变了"的接口**(实测:加完 `network.wan.ipv6`
后 wan 的 uptime 没重置、状态还是 v4-only),而 relay 分支只在 setup 时跑 —— 所以老装机要么重启、
要么跑一次 `net-split --apply`(它现在会自己补这一下,靠"bearer 有没有公网地址"守卫,一台机最多触发一次)。
全新安装不用管:uci-defaults 在 `S10boot` 就调 net-split 落盘,`S20network` 才起接口。

> **顺带一提**:`/etc/init.d/changxing60-ndp stop` 曾经杀不掉守护进程 —— 因为 `stop_service()` 里写了
> `exit 0`,而 rc.common 的 `stop()` 是先跑这个 hook、**再** `procd_kill`(同一个 shell),`exit` 把脚本
> 提前结束,路由删了、进程还活着。已改成 `return 0`。同类错误在 `net-split` 里也犯过一次
> (`set -e` + `uci -q delete <不存在的选项>` 返回 1 → 脚本当场终止 → masq6 和 commit 都没跑到,
> 配置全卡在 uci 暂存区,一重启就没)。

## 5. 已知限制 / 未验证

* **WiFi 空口上的 IPv6 没验**,而且**这台设备自己验不了**:Marlin3 的 `iw phy` 写着
  `#{ managed, AP } <= 1` —— **不能用 AP+STA 并存**,所以没法"自己连自己的热点"在空口上跑一个来回
  (顺带说明:这台机的热点与它自己的 WiFi 客户端二选一,不是配置问题)。**必须第三方真机**。
  上面的客户端挂在**网桥**上(是真转发,但没经过 WiFi 驱动)。
  上游记录:5.4 上 Wi-Fi 客户端的 IPv6 TCP/UDP 不通,而 6.18 通,那条路径上唯一的差异是本移植的
  `wlan_combo-rx-software-checksum.patch`(无条件 `CHECKSUM_NONE`)。**需要一台真机连热点复测**:
  连上以后在手机上访问 `test-ipv6.com` 或 `ping6 ipv6.baidu.com` 即可;若不通,方向是按上游的
  RX DMA-sync + 只在匹配时信任固件校验和,改 `ext-wlan-combo` 模块并撤掉那个 patch。
* **RA 无 RDNSS**:纯 v6 客户端拿不到解析器(见 §3)。要补的话是给 odhcpd 配 `dhcp.wifi.dns`
  之类的段,但中继模式下是否生效需要实测 —— 尚未做,也没做需求。
* 客户端**第一次** RS 要重传一次才有应答(实测:重传 4 s 后 65 ms 内回 RA,接口刚 up 时 odhcpd 还没
  把它登记上)。任何真实客户端都会重传,无代价;但"发一次包就断言中继死了"的探针会误判。
* 上游 SIPA 那条老账**已定位并打了补丁**(2026-10-13):`driver CB returned with -115` → `sipa_eth0`
  停队列,**根因是 SIPA delegator 对端(PS CP)不回 DONE 时没有超时**,生产者 `PROD_CP` 永久卡在
  REQUEST_IN_PROGRESS、消费者 `CONS_WWAN_UL` 永久卡在 RELEASE_IN_PROGRESS,**只有重启能救**。
  现加 2 秒对端超时,超时按 `SIPA_RM_EVT_FAIL` 撤回请求,队列自行唤醒、下个包重新发起请求。
  详见 `changxing60-linux/docs/FINDINGS.md` §34 与本目录 `sipa-wedge.md`(含现场证据与未验部分)。
  重拨期间 WAN 会断约 95 秒(teardown 释放 PDP context 后重新注册),这是重拨的固有代价,不是故障。

### 5.1 那次内核崩溃(复测工具的前科,务必先读)

**2026-10-13,复测工具跑完的收尾阶段把整机打崩了。** 现象与根因分开记:

* 现象:设备重启,`/proc/cmdline` 里 `bootcause="Reboot into ap watchdog"`(**看门狗复位 ≠ 看门狗超时**,
  panic 从外面看就是这个样子)。
* 证据在 **`/sys/fs/pstore/console-ramoops-0`** —— 死掉那次启动的完整控制台还留着,不用靠
  early-recorder(它只录前 300 秒,而且这次开机一写就覆盖掉了)。原文见 `changxing60-linux/docs/FINDINGS.md` §33。
* 崩溃点是 **`fork()`**:`kmem_cache_alloc_trace` → `scs_alloc` → `copy_process` →
  `call_usermodehelper_exec_work`(kworker 里跑 usermode helper),地址 `dead000000000100`(LIST_POISON)。
  **不在转发路径上**,是 slab 被弄坏了、由下一个分配的人摔死。
* 那次启动里全部 8 条 `sipa_dummy: dev ... evt ...` 都是测试用的 veth `v6cp` 的,挤在崩溃前同一个 30ms 窗口,
  还带 `evt 1/14`(`NETDEV_UP`/`PRE_UP`,即 netns 拆除时设备被重新注册回 init_net)和
  `device v6cp entered promiscuous mode`。那次启动在它之前一条 `sipa_dummy` 都没有。
  怀疑对象是厂商 `sipa`/`sipa_dummy` 的 netdev notifier 处理了一个**不属于它的设备**(veth),
  把 slab 写坏;微秒级先后无法定论(首条 fault 比那批事件早 12ms,但那是 8 核共享 ring buffer,
  两条日志来自不同 CPU),所以只能说到这个程度。
* **线上不受影响**:真机客户端连热点不会增删网桥端口,AP 连续跑过几天客户端流量都没事。
  这条只约束"拿 veth 挂网桥做实验"。
* 顺带一个正面结论:这次崩溃后的**冷启动**把 IPv6 完整地自己拉起来了(新前缀 `2409:8948:3c1:1e3`),
  说明开机路径(不需要任何手工命令)是通的。

## 6. 文件清单

| 文件 | 作用 |
|---|---|
| `changxing60-linux/openwrt/overlay/lib/netifd/proto/changxing60cell.sh` | `ipv6` 选项 + relay 分支(accept_ra 先、重启后的顺序),teardown 两族都清 |
| `changxing60-linux/rootfs/overlay/opt/changxing60/bin/ndp-learn` | 跟随 bearer 前缀给 br-wifi 挂 `/64`(metric 128),bearer 没地址时按实测配方自愈 |
| `changxing60-linux/openwrt/overlay/etc/init.d/changxing60-ndp` | `START=99` 的 procd 服务,只在 `network.wan.ipv6=relay` 时起 |
| `changxing60-linux/rootfs/overlay/opt/changxing60/bin/net-split` | IPv6 配置(relay / masq6 / 删 ndp)+ apply 时把服务拉起并补一次重拨 |
| `changxing60-linux/tools/net-v6-client-test.sh` | 真·转发客户端复测工具(netns + veth) |
