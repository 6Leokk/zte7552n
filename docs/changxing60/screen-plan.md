# 7552N / 畅行60:内屏点亮 + 按键控屏 + OpenWrt 全功能达标

> 状态:**G1/G2/G3/G4/G5 已实测通过**(2026-10-13 立项,同日收口);此后按**用户真机反馈**又做了几轮。
> **第二轮**(屏幕闪动 / 下游无法上网 / 缺电量显示)见下「第二轮」;**第三轮**(真机客户端连上热点跑下载:
> 空口/蜂窝逐层实测 + 「很多 network error」的定性 + 蜂窝 WAN 的最后手段重启兜底)见「第三轮」;
> **第四轮(2026-10-13 上午,设备被拿走前)**(整机网络栈 8 层体检 + 魔法上机 + SIPA 假死第四次与自愈链条 +
> 改名收口 `changxing60` + 重启/启动槽定性)见「第四轮」。
> P4 只剩「WiFi **多**客户端并发」缺条件——单客户端(真机)这轮已经实测过了,见「第三轮」。
> 另补修了页脚两行叠印(字体是 8×16,字格高度被按 8 估),并做了 NAT/DNS 的跨重启复测与二维码独立解码验证。
> 取代 [`display-design.md`](display-design.md)——那份 2026-10-10 归档的设计稿基于两条已被实测推翻的前提
> (「MU300 无显示硬件」「5.4 无平台 suspend」),其 Phase-D 模块枚举计划也随之作废(见 §2)。
> 关联:[`port-design.md`](port-design.md)(移植总设计)、[`feasibility.md`](feasibility.md)(路线评估)、
> [`access.md`](access.md)(**怎么连进去:屏上那条链接、LuCI/SSH 口令、热点 PSK、怎么重启**)。

## 第五轮(2026-10-14,真机反馈:面板上的管理地址印错了)

用户报「管理后台进不去」,查下来是**屏上那个地址不对**:面板写 `192.168.77.1`,而真正能用的是 `192.168.8.1`。

- **根因**:`read_wan()` 挑地址是**先问 `br-lan`**。net-split(2026-10-13)之后 `br-lan` 是 USB 管理口
  `192.168.77.1/24`、`br-wifi` 才是热点 `192.168.8.1/24`,于是屏上永远印前者。当时那段注释赌的是
  「两个网在一个防火墙 zone 里,热点客户端也能到 192.168.77.1」—— **实测不成立**(用户打不开,换
  `192.168.8.1` 立刻通)。
- **改法**:改成**先问 `br-wifi`**,`br-lan` 退为第二顺位,最后才是「全表里第一个非 WAN、非 loopback 的 IPv4」
  兜底;初值(`lan_ip`)与 `--dump` 预览值一并对齐成 `192.168.8.1`。
- **顺带修的两处**:(a) 每一步都要求「命令跑通**且真拿到了地址**」——老写法里「接口在但没地址」(热点关了
  的残桥)会**堵死兜底**,屏上就会一直印一个没人应答的地址;(b) 最后那道全表兜底改用 `run_cmd_all`
  ——`run_cmd` 只读第一行,而 `ip -4 -o addr show` 是**一行一个地址**,值得印的那个未必排第一。
- **为什么热点侧赢**:二维码是 **Wi-Fi 加入码**(`WIFI:T:WPA;S:changxing60;P:…;;`),SSID 就印在同一页上,
  读这张屏的人**就是刚从热点连上来的手机**,对它而言管理地址只能是 `192.168.8.1`。走 USB 线的人本来就知道
  敲 `192.168.77.1`(仓库里每份文档、每个工具都这么写),而且 `br-lan` **故意不下发网关**,那条线上的机器
  **根本到不了** `192.168.8.1` —— 两个读者只能顾一个,顾屏所面向的那个。
- **验证**:`tools/screen/build.sh` 编过、`tools/screen/test.sh` 全过(背光状态机 + QR 对拍)。
  **真机未验**(改的时候设备不在线)。
- **顺带更正**:下面 §5 那句「屏上二维码用 OpenCV 独立解码 = `http://192.168.77.1/`」是**更早那一轮**的读数
  —— 那时码里装的还是 LuCI URL,后来换成了 Wi-Fi 加入码;现在 URL 印在页脚(`LuCI http://…/`),
  同一件事,但值应为 `192.168.8.1`。

## 进展快照(2026-10-13 夜,结尾)

| 目标 | 状态 | 证据 |
|---|---|---|
| **G1** 内屏状态页 | ✅ **已通** | 480×854 竖屏整页渲染,`--shot` 抓 scanout 缓存转 PNG 肉眼确认;数据全活(WAN/WiFi/负载/温度/内存/电池/二维码) |
| **G2** 开关机键切背光 | ✅ **已通** | `keyinject` 经 uinput 注入 4 次 `KEY_POWER`,背光 255→0→255→0→255 逐步跟随;真键在 `event0`(gpio-keys, code 116) |
| **G3** 触摸保持关闭 | ✅ **保持** | `/dev/input/` 只有 `event0`(gpio-keys)+`event1`(振动器)+`uinput`;`zte_tpd`/`spi-sprd`(触摸)未加载 |
| **G4** OpenWrt 全功能 | ✅ **逐条查完**(只剩 1 项缺条件) | 见 §5;蜂窝 WAN(**含假活自愈 + 最后手段重启**)/WiFi AP(**真机客户端连过并实测**)/USB LAN/NAT+防火墙(跨重启复测)/DNS-DHCP(已加双备)/LuCI/NTP/zram/热管理/模块持久 全绿;**IPv6 双栈第四轮实测通过(旧记的"限制"作废)**;明确记为**本机限制**的只剩 LED 与信号强度两项;**WiFi AP「多客户端并发」压测缺条件**,单客户端已实测(见「第三轮」) |
| **G5** 可回滚 | ✅ | 全程未碰 `boot_a`;显示改动只落 ramdisk + 持久 ext4;两次重启均正常回到 OpenWrt(slot b tries 兜底未触发) |

**重启验证(累计 ≥5 次)**:显示栈/服务/按键/无触摸全部自恢复,不依赖任何手工步骤。

**本轮新修的问题**(全部实测过):

1. **状态页把 WAN 报成 `sipa_eth8 down`,实际 WAN 好得很**。`mobile-data` 固定 `CID=1` → 数据口恒为 `sipa_eth0`;而页面用 `readdir()` 取 `/sys/class/net` 里**第一个** `sipa_eth*`,拿到的是文件系统顺序不是数字顺序。改为**按存活挑选**(`mobile-data` 掉线时会把链路 down,所以 up 的那个就是承载数据呼叫的那个),回退 `sipa_eth0`。实测:改前 `sipa_eth8 down / rx 0 B`,改后 `sipa_eth0 up / 10.x.x.x/32 / rx 154K tx 58K`。**载体每次重连会换 IP**,更说明必须读活接口而非写死。
2. **rxtx 行被右边缘截断**(`tx 53 K`)。竖屏该行只有 19 列,`rx 145 KiB  tx 53 KiB` 需要 21 列;加 `human_bytes_short`(`145K`)只给这一行用。不能拆两行——行块会撞上二维码(行止 y=572,码起 y=604)。
3. **重启后 `/dev/input/uinput` 不存在**,`keyinject` 开不了。驱动是内建的(`223 uinput` 在 `/proc/misc`),但本 rootfs 的 `/dev` 是 tmpfs 叠在 devtmpfs 上,没有东西给它建节点。在 `changxing60-screen` 的 init 脚本里从 `/proc/misc` 取 minor 建节点(不写死 223)。
4. **按键读取只在启动时打开一次设备**是个陷阱:设备若晚于进程出现就永远读不到。改为**每个刷新周期重扫**,新设备自动接管。实测日志 `2 input device(s)` → 4 秒后 `3 input device(s)`,注入器后启动也能控屏。
5. **`openwrt/build-rootfs.sh` 根本不能解析**(仓库里就是这样):`-c '...'` 单引号块内一句注释里的 `Docker's` 把字符串提前闭合,`sh -n`/`bash -n` 双双报 unterminated quote。改掉该撇号并在块顶加警告注释。**这个 bug 让「重建 tarball」这条路一直是断的**。
6. **rootfs 重建缺显示栈**:`build-rootfs.sh` 既不含 6 个显示模块,也不装 `changxing60-screen`/`keyinject`,更不 enable 服务——即「照现在的脚本重建,屏不会再亮」。补齐:挂 `out/display` + `tools/screen/out`,装二进制进 `/usr/bin`,enable 名单加 `changxing60-screen`。`tools/screen/build.sh` 也改成同时编两个二进制。
7. **页脚两行字叠印**(本轮补修,截图放大才发现):`power=on/off vol=dim` 与 `LuCI http://192.168.77.1/` 印在彼此身上、两行都读不清。
   **根因是字号算错了**:字体是 **8×16**(`changxing60-screen.c` 的 `font8x16`),不是 8×8——scale=2 时一个**字格高 32 px**,而代码按 8 px 估:`hint_y = fb_h - 26*sc` 让提示行字格落在 854-52=802..833,底边 12 px 正好扎进 40 px 高的页脚条(814..854),而 URL 行就画在同一区。
   **修法**:`hint_y = fb_h - 38*sc`(让整个 16×sc 字格连 2×sc 间隙一起落在页脚条上方),并把这句「字格是 16 行不是 8 行」的理由写进注释。实测:提示行墨迹 782..807,页脚条 814 起,URL 行 826..851,三层互不重叠。
   **顺带**:二维码区域改动前后**逐字节相同**(173×173,md5 `b16c2bed…`,只整体上移 24 px),即这次改动没碰编码。

**用户实测反馈后的第二轮(2026-10-13 夜,三个报障)**:

用户在真机上报了三条:**屏幕闪动** / **下游设备连上但不能上网** / **缺电量显示**。三条都已定位并改掉:

8. **屏幕闪动 —— 单缓冲直接画在扫描缓冲上**。`render()` 第一句就是 `fill_rect(0,0,fb_w,fb_h,FB_BG)`,而这块内存就是 CRTC 正扫出去的那一块(整个进程只建了一块 dumb buffer,`SETCRTC` 一次绑死),于是每 2 秒刷新时面板先整屏变黑、几十毫秒后各行才补回来——肉眼就是闪。
   **修法**:两块 dumb buffer + `drmModePageFlip` 等价物(裸 ioctl `DRM_IOCTL_MODE_PAGE_FLIP` + 事件 `DRM_EVENT_FLIP_COMPLETE` 经 `read(drm_fd, …)` 收回,`drm_min.h` 补了对应结构)。不变式:**永远画在"当前没在扫描"的那一块**上。驱动不支持翻页时自动降级为"整帧一次 memcpy"进扫描缓冲(可见的半成品从"整屏重画"缩成一次 1.6 MiB 拷贝),并在日志里说明走了哪条路。
   **实测**:重启后日志 `mode set, 480x854, pitch 1920, scale 2, double buffered`,且**没有**出现降级行 → 这台驱动**接受页翻转**,走的是双缓冲路径。`--shot`/`--once` 显式关掉 present(它们要回读刚画好的那一块)。
   **顺带**:`--dump` 现在支持 `--dump FILE portrait`,能直接在宿主机复现面板的竖屏排版——横竖两个分支布局不同,以前只有上机才看得到竖屏。

9. **缺电量显示 —— 燃油计被量程判掉了**。`read_system()` 原先用 `c >= 0 && c <= 100` 取容量,而**真正的燃油计 `sc27xx-fgu` 报的是千分比**(实测 `cap=885`,即 88.5%),直接被这个判断丢掉;于是整行只剩 `battery/capacity`(charger-manager,92)撑着,它一旦没准备好,行就退化成 `no fuel gauge` —— 在一块"移动设备"上等于没电量。
   **修法**:>100 且 ≤1000 的读数按千分比折算;不再 `break` 提前退出(容量和状态可能来自不同节点);状态只认 `Charging/Discharging/Full/Not charging`,并缩写成 `CHG/DIS/FULL/IDLE`;另加一个**电量条**画在该行右侧(空间不够就不画,阈值按实际文本长度算,不会和数字撞)。
   **实测**:真机取帧为 `Battery 92% FULL 4.29V` + 右侧电量条((真机取帧 --shot 后肉眼核对))。

10. **下游设备无法上网 —— 数据呼叫"假活":地址在、operstate 绿、一个包都不走**。取证:默认路由在、`sipa_eth0 10.67.19.111/32`、operstate `up`、carrier 1,但**收发计数完全不动**(5 秒 delta `tx +0 rx +0`,ping/HTTP 全失败),`nf_conntrack` 里宿主(192.168.77.199)的 SYN 已被 NAT 成 10.67.19.111 发出去、反向 `packets=0 [UNREPLIED]` —— 转发与 NAT 都正常,**是蜂窝上行整个不回包**。同时 watch 的 `link_up()` 只看"有没有 IPv4 地址",地址一直在,所以**永远不会自愈**(本次开机 4.7 小时里一直如此;状态页还一直绿着报 `up`)。
    **修法**(`mobile-data` / `changxing60cell.sh`):
    - **存活性改按"能不能通"判**:加 ICMP 探针(多目标=运营商 DNS + 223.5.5.5/119.29.29.29,且**绝不碰 AT 口**)——与旧注释的铁律一致;空闲时才探(每 3 个周期≈90s),**有流量就直接判活**(免费证据,也避免运营商封 ICMP 时误判);连续 3 次不通才动作;每次修复后 10 分钟限流。
    - **修复动作用 `ifdown`+`ifup`**:netifd 认为接口还 up 时 `ifup` 是空操作,而"假活"正是这种情况,所以必须先 down 再 up;连修 3 次无效则做一次 `sim-reset`(整射频 off/on + 等 PIN,即 Android RIL 的那套)。
    - **发布健康状态**:watch 写 `/tmp/changxing60-wan-health`(`ok|dead` + uptime),状态页据此**敢报红**(新鲜度 900s,上一开机遗留的 dead 不会粘住);这解决了"页面绿着、实际没网"。
    - **attach 单实例锁**(`/var/run/changxing60-attach.lock`):netifd 失败后每 ~20s 重试,而一次 attach 在 `AT+CEREG?` 等待里能待 2 分钟以上,于是重试会**叠加**成多个 `mobile-data up` 抢同一个 AT 口——这正是 2026-10-13 那次风暴(五个叠进程)的形状。第二个调用者现在立刻失败退出,让 netifd 下一轮再来。
    - 如实记下:`ethtool -K $IFACE rx off` 那行**在本 rootfs 上从来没生效过**(全系统没有 ethtool,连 busybox applet 都没有),两处都保留了但注释写明是惰性的。
    **实测(重启后)**:
    - 重启前:`sipa_eth0 10.67.19.111/32` + 默认路由在 + operstate `up`,但 5 秒计数 delta `tx +0 rx +0`、`ping` 100% 丢包、宿主 `wget http://www.baidu.com` 失败、conntrack 全是 `[UNREPLIED]`。**即"假活"当场复现**。
    - 重启后(约 50 s 回来):`sipa_eth0 100.114.5.58/32`(运营商换了 IP)、`ping 223.5.5.5` **0% 丢包**。
    - **下游端到端**:宿主 `192.168.77.199`(USB-NCM)→ `curl http://www.baidu.com/` → **HTTP 200 / 0.39 s**;conntrack 里该流双向计数、NAT 到 `100.114.5.58`,标 `[ASSURED]`;宿主经路由器的 DNS 解析正常。**这就是用户报的"下游设备连上不能上网"的直接反证**。
    - 单实例锁生效:`ps` 只有一个 `mobile-data watch`,无叠加 `up`;`/var/run/changxing60-attach.lock` 未被占用(空闲时正确释放)。
    - 健康文件 `/tmp/changxing60-wan-health` = `ok 102`(watch 写出,状态页据此显示)。

**本轮另外做掉的 P4 收尾**(全部重启后复测):

- **NAT/防火墙规则跨重启**:`firewall.@forwarding[0]`(lan→wan)已在 `uci` 里提交(`uci changes` 空),重启后 nft 重新生成出 `chain forward_lan { jump accept_to_wan }` + `chain srcnat_wan { masquerade }`;**端到端实测**:宿主 192.168.77.199 → `http://www.baidu.com/` HTTP 200,设备 `nf_conntrack` 见 `src=192.168.77.199 dst=39.156.70.239 → NAT 成 dst=10.67.19.111`(重启后运营商换的新 IP)`[ASSURED]`。
- **上游 DNS 双备**:运营商只给两个**同运营商**的 DNS(211.138.21.66/23.66),运营商侧一挂就没有退路。加 `dhcp.@dnsmasq[0].server` = `223.5.5.5` + `119.29.29.29`(阿里/DNSPod,已提交,重启后仍在 `/tmp/etc/dnsmasq.conf.*` 的 `server=` 行)。dnsmasq 默认按响应快慢选上游,运营商 DNS 正常时仍优先用它,沉默时才回退。**要撤就把这两条 `del_list` 掉**。
- **设备上残留的 `/etc/init.d/changxing60-hw.orig`**(我早先改脚本留下的旧版备份,935 B,不在 `rc.d` 里、纯惰性)已删;现在 `/etc/init.d/changxing60-*` 与仓库 overlay 一致。
- **二维码独立解码验证**:用**另一个库**(OpenCV `QRCodeDetector`)解这张实拍帧,得到 `http://192.168.77.1/` —— 不是拿渲染它的那份代码自证。

**本轮核过没问题、不改的地方**:

- **LuCI 是好的**。busybox `wget` 在 403 时丢弃响应体,看起来像挂了;实际 403 是 **LuCI 自己的登录门**(`x-luci-login-required: yes` + `<title>mu300 | Overview</title>`),curl 一看就是正常登录页。uhttpd 那条指向不存在的 `/usr/lib/lua/luci/sgi/uhttpd.lua` 的 `lua_prefix`(本版 LuCI 是 ucode)无害——uhttpd 会落到 `/www/cgi-bin/luci` 的 ucode 派发器;实测加不加它都是同一张登录页,故保持发行版原样。

**新记录的硬件/驱动限制**:

- ~~**WiFi BSSID 每次开机都变**~~ → **2026-10-13 已修,见 `docs/changxing60/access.md` §3**。当时的判断是「本机没有出厂 MAC(LK cmdline 无 `androidboot.wifimac=`)+ 驱动静默忽略 MAC 写入」,两条只对了一半:这台机器**有**出厂 MAC,在 `prodnv:/wifimac.txt`(Android 挂在 `/mnt/vendor`,正是驱动里 `WIFI_MAC_ADDR_PATH` 指的位置),只是没人把它喂给驱动;而「驱动忽略写入」只对 `ip link set wlan0 address` 那条路成立——`ndo_set_mac_address`(`sprdwl_set_mac`,main.c:980)在 AP 模式下什么都不做还返回成功。厂商自己的 `SPRDWLSETNDEVMAC` ioctl(main.c:857)会写 `vif->mac`/`wdev.address`/`default_mac`,用它就固定下来了:每次开机 `wifi-mac` 读 prodnv 并用 `/usr/bin/wifimac` 写进去,hostapd 的 bssid 与接口地址同时是 `<REDACTED-MAC>`。**当初「钉死会让 hostapd 与空口分叉」的现象是真的**:那时只把 uci 里的 `macaddr` 钉死,驱动并不知道,两者自然分叉;现在先钉驱动、再让 uci 跟着驱动走,分叉的前提没有了。
- **`rmmod sprd-drm` 会挂内核**(硬件看门狗随后重启)。显示栈只 insmod,不 rmmod;要改就重启。

**第三轮(2026-10-13 深夜,用户真机连热点跑下载)**:

用户把一台真机连到 `MU300-D0FD` 跑下载,同时报「走网页流量时出现很多 network error」。空口这轮第一次有
真实客户端,于是把「客户端连上后到底通不通」逐层实测了一遍,并顺手把蜂窝 WAN 的最坏情况兜底补上。

11. **蜂窝 WAN 的最后手段:重启兜底**(`mobile-data`,commit `6c6fe97`)。
    **背景**:第 10 条修好「假活」自愈后仍留一个死角 —— `ifdown`/`ifup` 修不动、`sim-reset` 也修不动的情况。实地见过两次:
    **SIPA_RM 释放 WWAN**(773 s 先兆 `SIPA_RM CB -115`,1066 s 彻底不通)与**6 流 279 Mbps 把蜂窝拉爆**之后,
    `mobile-data up` 会**静默卡在 `do_select`**,清锁重连无效;此时**蜂窝的 AT 口整个哑掉**(裸 `AT` 不答),
    但 WCN 的 `atcmd` 属性仍 `rc=0` —— 死的是蜂窝 AT 通道,不是 WCN。**只有 reboot 能救。**
    **修法**:`watch` 里加 `at_state()` / `bad_clock()` / `maybe_reboot()`,四条**全部满足**才重启:
    (a) 健康文件已记 `dead` 且「坏」已持续 ≥300 s(`CHANGXING60_WAN_REBOOT_AFTER`);
    (b) 在跑的修复距开始已 ≥60 s(即修复确实做过、且没救回来);
    (c) **裸 `AT` 探针确认 AT 口不应答** —— `at_state()` 在链路还 up 时返回 2(不判死)、设备节点不在也返回 2,
        只有真发出去 `AT` 且 5×1 s 内一句都没读回来才返回 1;
    (d) 本次开机还没重启过(`REBOOT_MARK=/var/run/changxing60-wan-rebooted`;`/var` 是 tmpfs,标记天然按 boot 失效)。
    即:**只在「数据死透 + 修复无效 + AT 口哑 + 本次开机第一次」时 `sync; reboot`**。AT 探针在 `$IFACE` 还有地址
    (数据呼叫可能还活着)时**拒绝发问**,守住「绝不在活数据呼叫上塞 AT」那条铁律。
    **实测**:另存一份桩化副本(`link_up` 恒假、`ifup`/`ifdown` 打桩、`CHANGXING60_AT_DEV=/dev/null`、阈值压到 4 s、
    `CHANGXING60_REBOOT_CMD="echo WOULD-REBOOT"`)跑真逻辑:在 **62 s**(= 60 s 冷却 + 阈值)触发**恰好一次**,
    落下标记后再不触发 → 一次性语义正确。线上 `watch` 已换新(pid 5838 → 12917),`bash -n` 干净,两侧 md5 一致
    `77ebe32725f0dd0cd6c9a3de12cdc94f`。**注意:这是「重启」,不是「自愈」—— 只在已判定救不回来时才用。**

12. **空口与蜂窝逐层实测:热点这条路是干净的**(这轮第一次有真机客户端)。
    - **空口**:设备 ping 客户端 `-c 15` **0% 丢**;1472 B 大包 10/10 **0% 丢**;hostapd 客户端计数
      **下行 81,587,058 B / 61,348 包,`tx_errors 0` / `rx_errors 0`**。
    - **蜂窝**:`ping -I sipa_eth0 223.5.5.5` 0% 丢(33–96 ms);从设备自身 `wget http://www.qq.com/` **10/10 成功**;
      `IpExt/Tcp` 的 `InCsumErrors 0`,重传 10/582 段。
    - **DNS**:设备上 `nslookup <名字> 127.0.0.1` 20–60 ms(含 `clients3.google.com`、`tracker.ai.xiaomi.com` 这些),
      四个上游(211.138.21.66/23.66 + 223.5.5.5 + 119.29.29.29)各 30–60 ms 都答。
    - **抓包**(`apk add tcpdump` 装在设备上,抓 wlan0 45 s,`ssh 'cat /tmp/cap.pcap' > 本地` 取回后解析):
      客户端 23 次连接、15 次建立且有真实载荷;TCP 载荷段 447 个、**重传 2 个(0.45%)**、**0 个 RST**;
      conntrack 里客户端有大量 `ESTABLISHED` 双向流;**QUIC(UDP/443)与 STUN(UDP/3478)双向都通**。
    - **「很多 network error」的定性**:真正的异常只有一类 —— **8 次 `:443` 连接没有 SYN-ACK**(重试 3–9 次、
      conntrack 记 `[UNREPLIED]`),目的地**全是 Google 系**:`142.250.157.100/101/102/113/138/139`
      (PTR = `ta-in-f100.1e100.net`)与 `128.242.240.212`;**从设备自己 ping 这两个也 100% 丢** —— 运营商侧就不通,
      与热点无关。而客户端同时在查 `clients3.google.com` / `clients.l.google.com`(**连通性自检**),自检失败
      会让系统把这条 WiFi 标成「无互联网」,很多 App 随后直接报网络错误。**这是「很多 network error」最可能的解释**,
      也不是热点侧能修的;真要绕,得从客户端侧改动。

**这轮踩的坑(留给以后的自己)**:

- **抓包里 DNS 的事务 ID 在 DNS 载荷的前 2 字节,不在 UDP 头**。第一版解析器读的是 `uh[6:8]`(UDP **校验和**),
  于是「13 个查询没应答 / 13 个应答对不上」全是假的 —— 实际每个查询都在同一秒被 `192.168.8.1` 答了。
- **SYN-ACK 配对写反过一次**,导致 23 次连接被全判失败(正确的读数是 15 通 / 8 不通)。
- 设备上**没有 `python3`**(顺带查出 `up()` 里算 prefix 的 `python3 -c ipaddress…` 一直走 `|| echo 32` 回退,
  **前缀恒为 32** —— 不是 bug,但要知道)、**没有 `ethtool`**;busybox 的 `nc` 是精简版 `nc [IP PORT]`
  (**不认 `-w`/`-z`**,拿它测端口连通性会静默失败,我因此得出过「10 个站点 443 全 FAIL」的假结论);
  `ping` 不认小数 `-i 0.2`。`scp` 到设备不可用(无 sftp-server)→ 二进制一律 `ssh 'cat 文件' > 本地`。

**第四轮(2026-10-13 上午,设备被拿走前的最后一轮)**:

这一轮用户只提了三件事(测功耗 / 改中文与改名 / 调研魔法),做完之后又追加:屏幕标题与热点名收口、
查 WAN 为什么又死、以及一次"整机网络栈快速体检"。功耗那件按用户自己说的"先不测,就用现有数据"关掉(结论见 `power.md`)。

13. **全栈体检:8 层全绿**(唯一异常是已知的 SIPA 假死周期)。逐层读数见 `access.md` §5/§6 与本表 §5:
    蜂窝 v4(`sipa_eth0 10.170.42.106/32`,`ping 223.5.5.5` 0% 丢)/ **蜂窝 v6**
    (`2409:8947:365:97f:…/64` + `default via fe80::1 dev sipa_eth0 proto ra`,`ping6 2400:3200::1` 0% 丢
    —— **§5 表里"IPv6 WAN 只有 link-local"那行已被本轮推翻**,细节见 `ipv6.md`)/ WiFi AP
    (`ssid=changxing60`、`bssid=<REDACTED-MAC>`、ch36/5180)/ USB LAN / NAT(v4+v6 两条 masquerade 都在)/
    DNS(dnsmasq → `127.0.0.1#7874`)/ **转发错误计数 `br-lan`、`br-wifi` 全 0** / 魔法。
    唯一污点:`sipa_eth0` 累计 `tx_errors=8`(`rx_errors=0`),来源是上一 boot 假死那段的残留。
14. **魔法真正上机了**(用户自己填订阅并启动)。运行实录(进程 / TUN / 策略路由 / nft / 实测下载)见
    `proxy.md` §8 —— mihomo v1.19.31 + `91code.yaml`、TUN `utun`、fake-ip、`ip rule` fwmark `0x162` → table 354、
    nft mangle + DNS 劫持 + QUIC REJECT;**实测外网内容通**(`www.debian.org` 拉回 15,864 B 经 🇸🇬 SG 节点)、
    国内域名走 DIRECT,而且**没有**把宿主电脑(br-lan 那条路)劫持掉。
15. **SIPA 假死第四次:自愈链条第一次被完整观测**。628s 楔死 → 630.65s 补丁准时(2.0s)→ CP 仍不答 →
    **834s `mobile-data` 撤地址**(ping 从"丢包"变 `Network unreachable`)→ **969.31s 用户态 `reboot: Restarting system`**
    (console-ramoops 佐证非 panic/看门狗)→ 重启后 WAN 直接恢复(新地址 `10.170.42.106/32`)。
    即**恢复通路是通的,代价是每 ~16 分钟整机重启一次**。全文见 `sipa-wedge.md` §6.4;
    空闲假设的 keepalive 实验(第一次没跑成、第二次 708s 前没假死但被设备拿走截断)见 §6.4.1。
16. **改名收口:状态页标题与热点 SSID 都定为 `changxing60`**(用户定名,整机叫 changxing60,
    **不要** `-D0FD` 后缀)。状态页左上角原来画 `MU300` / `MU300 / changxing60`,已改成无条件 `changxing60`
    (`changxing60-screen.c` 的 `render()`,提交 `6e2136b`;`strings` 复核二进制里已无 `MU300` 字样);
    热点 `ssid=changxing60`(hostapd `ENABLED` + `iw dev wlan0 info` 复核),`openwrt-wifi-config` 的兜底前缀
    同步改成 `changxing60-<MAC 后几位>`。**已配对过的客户端要重连一次**(改 SSID 等于换网)。
17. **重启路径定性**(怎么手动重启 / 会不会跑到 Android 去):落点是**任何重启都回 OpenWrt**,
    但**开机 ~70s 内连着重启两次**会把 slot b 的 `tries` 打到 0 而回落到 Android。三种重启方式与取舍
    写在 `access.md` §5。

## 0. 目标与验收标准

在当前设备(自编 5.4.254 内核 + 原生 OpenWrt 25.12.5,path A 持久 ext4)上交付一个**可用的手持设备**:

| # | 目标 | 验收标准(必须实测) |
|---|---|---|
| **G1** | 内屏显示 OpenWrt 后台信息 | 屏上出现自绘状态页:系统(主机名/uptime/负载/温度/内存)、WAN(LTE/运营商/IP/DNS/流量)、WiFi(SSID/信道/客户端数/MAC)、电池(电量/状态),外加指向 LuCI 的二维码 |
| **G2** | 开关机键控制亮屏/息屏 | 按一下熄屏(背光=0)、再按一下亮屏;短按即生效,长按不触发任何关机动作 |
| **G3** | 触摸**保持关闭** | `zte_tpd`/`spi-sprd` 不加载,`/dev/input/event*` 里没有触摸设备——**只有用户单独确认后才开启** |
| **G4** | OpenWrt 功能全量自查 | §5 清单逐条实测通过(蜂窝 WAN、WiFi AP、USB LAN、NAT/防火墙、DNS/DHCP、时间同步、LuCI、zram、热管理、持久化) |
| **G5** | 全程可回滚 | 任一步失败靠 misc tries 兜底回 Android;`boot_a` 全程不碰;显示相关改动只落在 ramdisk 与持久 rootfs 内 |

**非目标(明确不做)**:
- 不启用触摸(G3);
- 不上 7.2/主线内核(feasibility.md 已判:modem 栈只有 5.4 厂商版,上主线 = 没有蜂窝);
- **状态屏不做 GPU 加速**(854×480 用 CPU 软渲染,且 `DCDC_GPU enable=0` 现在就省着电)。
  (2026-10-15 勘误:原先写成"不编 `mali_kbase`"—— 那是把"屏不用 GPU"错当成了"不要 GPU"。
  用户明确要求 GPU 正常,模块已重编入库,见 [`gpu.md`](gpu.md);**屏这条路仍然不用它**。) 
- 不做浏览器/kiosk 打开真实 LuCI 页面(ARMv8 无 GPU 合成不现实;LuCI 是 JS 前端,文本浏览器也渲染不了)。

## 1. 一句话架构

**内核侧没有"从安卓移植"这回事**——安卓用的就是这份 vendor DRM(`drivers/gpu/drm/sprd`),DT 里面板/触摸/背光描述**已经在我们运行中的内核里**。要做的只有三件:

1. 把 `sprd-drm.ko`(DPU0+DSI+DPHY+panel+backlight)和它唯一缺的依赖 `sprd,vpu-pd` 电源域驱动**编出来装上去**;
2. 写一个**直接走 DRM/KMS 的状态页程序**(没有 fbdev,不能用 `/dev/fb0`);
3. 写一个**读 `event0` 的按键守护**,开关机键切背光。

## 2. 实测基线(2026-10-13,全部来自设备现场 dump)

**屏幕与触摸(新证据,推翻旧结论):**
- 屏 / 触摸都存在,DT `status=okay`:面板 `/lcds/lcd_easyquick_aixiesheng_boe_mipi_hd`(完整 init 序列 `zte,lcd-init-code-version=20240201_gamma_v0`、`sprd,phy-bit-clock`、`sprd,dsi-work-mode`、`display-timings`),`dsi@31300000` 下 `panel` 节点 `compatible=sprd,generic-mipi-panel`;dpuvsp 下 `dpu/dsi/dsi1/dphy/dphy1/iommu×3` 全 okay。分辨率 `lcd_size=854x480`。
- 触摸在 **SPI** 上:`/soc/ap-apb/spi@70000/touch_spi@0` `compatible=axs15205,axs15205_touch`。树里 `touchscreen_v2/axs_touch/axs_core.c:1893` 精确匹配此 compatible。**旧结论「无触摸」作废**(当时只扫 i2c)。
- DT 由 **LK 提供**(`vendor_boot_b` + `dtbo_b`;`dtb_a/b` 全零不用),我们的 boot 镜像不带 DTB → **DT 不需要改**。
- **屏幕现在亮着**(用户目视:ZTE logo,无任何 OpenWrt 内容)= LK 点亮后没人关过。显示时钟 `dpu-eb/dpu-vsp-eb/dsi0-eb/dphy-*` 在 Linux 侧 enable count 全 0;`/sys/class/graphics`、`/sys/class/backlight`、`/sys/class/pwm` 不存在;dmesg 无任何 drm/panel/dsi 行。

**模块账本:**
- 树里 `make Image modules` 出 **198 个 .ko**;stage **110 个**(2026-10-15 起含 `mali_kbase`,见 [`gpu.md`](gpu.md));
  开机 insmod 94 个(`boot/module-order.txt`);`mali_kbase` 等由 `extra-modules` 启动后加载。
  设备 `/lib/modules/5.4.254-gb50db5b6224c/` 里就是这 110 个(平铺,kmodloader 用)。
- 与屏幕有关而**已经编好、只是没装**:`spi-sprd.ko`、`zte_tpd.ko`、`unisoc-iommu.ko`、`ion_cma_heap.ko`、`ion_ipc_trusty.ko`、`pwm-sprd.ko`、`pwm_bl.ko`、`zte_lcdbl_vsp_vsn.ko`(面板偏压,对应 DT 里 i2c6 `ti65132b@3e`)、`lcd_state_notify.ko`、`sprd_mipi.ko`、`mipi_driver.ko`。
- **没编的只剩两样**:`sprd-drm.ko`(`CONFIG_DRM_SPRD` 未开)、`sprd,vpu-pd` 电源域驱动(ZTE 树里没有,只有 realme 树 `kernel_modules/kernel5.4/video/sprd-vpu-power/sprd_vpu_pw_domain.c` 提供此 compatible)。
  ~~`mali_kbase`~~ 2026-10-15 已编好入库(它不服务内屏,但用户要 GPU;见 [`gpu.md`](gpu.md));`sprdbt_tty` 仍是 realme 树的可选件(蓝牙只在需要时)。
- 框架 config 已经齐:`DRM=y DRM_MIPI_DSI=y DRM_PANEL=y DRM_KMS_HELPER=y BACKLIGHT_CLASS_DEVICE=y BACKLIGHT_PWM=m PWM_SPRD=m ION=y ION_CMA_HEAP=m UNISOC_IOMMU=m PM_GENERIC_DOMAINS_OF=y TRUSTY_VIRTIO_IPC=m` → **编外部模块不需要改内核**。

**电量与运行态:**
- 109 模块 + procd,26 min uptime 里 CPU **83% 时间在 `cluster-pd`**(最深空闲态);load 14 是 vendor kthread D 态假象。
- `/sys/power/mem_sleep = "s2idle [deep]"`(能力有),但 `CONFIG_PM_AUTOSLEEP` 未开且无任何 userspace 触发器 → **实际从不睡**。
- 电源现状:`bq2560x_charger=Full`、`current_now=-1000` —— USB 在供电,电池读数不能当功耗计。
- 按键:DT `gpio-keys` 三键 —— `key-power`(code 116 `KEY_POWER`)、`key-volumedown`(114)、`key-volumeup`(115),全部 `wakeup-source`,挂在 `/dev/input/event0`(`Handlers=event0 sysdump`)。

**用户态环境:**
- OpenWrt `25.12.5 r33051` `armsr/armv8`(`aarch64_generic`),`/` 是 `/dev/loop0` ext4 **rw**(装的东西持久)。
- 极简:67 个 `/usr/bin`,`apk` 可用**且能连 downloads.openwrt.org**(实测 rc=0)→ 用户态包可运行时装。
- 无 `/dev/fb0`、无 `/dev/dri/*`、无 `/dev/tty0`;模块工具走 `/sbin/kmodloader` + `/sbin/insmod`(busybox 无 insmod applet)。

## 3. 交付物

**内核侧(外部模块,不改内核镜像 → 零 CRC 风险):**
| 模块 | 来源 | 说明 |
|---|---|---|
| `sprd-vpu-pd.ko` | realme 树 `video/sprd-vpu-power/` | **关键路径**:DT `vpu_pd_top` 是 `compatible="sprd,vpu-pd"`,ZTE 树两个 pm-domain 驱动都不匹配它;没有它 DPU 会永远 `-EPROBE_DEFER` |
| `sprd-drm.ko` | ZTE 树 `drivers/gpu/drm/sprd` | 内部屏版:`DPU0=y DSI=y`(+DPHY/panel/backlight 编在同模块内);`DRM_SPRD_DPU1/DP` 可留可去(本机 board overlay 已 disable `dptx`) |
| 依赖(已编待装) | — | `unisoc-iommu.ko` → `ion_cma_heap.ko`/`ion_ipc_trusty.ko` → `sprd-drm.ko` → `zte_lcdbl_vsp_vsn.ko`;`pwm-sprd.ko`+`pwm_bl.ko` 备用(DT backlight 是 `sprd,qogirn6pro-backlight`,主驱动在 sprd-drm 内的 `sprd_bl.c`) |

**用户态(静态交叉编译,丢进持久 rootfs,不依赖 musl 版本):**
- `/usr/bin/changxing60-screen` —— 状态页:打开 `/dev/dri/card0`,dumb buffer 画点/字(内嵌点阵字体),定时刷新数据;背光由 `/sys/class/backlight/*/brightness` 控制。
- `/usr/bin/changxing60-screend` —— 按键守护:读 `/dev/input/event0`,`KEY_POWER` 短按切背光;`KEY_VOLUMEUP/DOWN` 调亮度(可选);**不处理长按关机**(PMIC 硬件路径不掺和)。
- `/etc/init.d/changxing60-screen` —— procd 服务:先 `kmodloader` 装显示模块(带超时保护),再拉 status/d 两个进程;失败只记日志不阻塞开机。
- 数据源全部走现成接口:`ubus call network.interface.wan status`、`/proc/net/dev`、`iw dev wlan0 station dump`、`/sys/class/thermal/*/temp`、`/sys/class/power_supply/*/capacity`、`free`。

**文档/脚本:**
- `kernel/build-internal-display.sh`(新,内部屏版外部模块构建,合 `sprd-vpu-pd` + `sprd-drm` 两件)
- `tools/screen/`(用户态源码 + 静态交叉编译脚本)
- 修正 `kernel/build-display.sh` 注释(「MU300 ships without display」与本机 DT 矛盾)。

## 4. 阶段计划

每阶段独立可停,失败即回滚;设备侧改动**先走运行时**(`scp` + `insmod`,不重启),只有验证通过后才落进 ramdisk/rootfs。

### P0 构建环境(✅ 完成)
1. 重建 docker volume `changxing60-kernel`(旧 volume 已丢失),从 `kernel-src/zte-ums9620-kernel-5.4.254` 灌入;
2. `docker run ... changxing60-kbuild bash /work/build-linux.sh` 全量构建 → `/src/out-linux`(Image + 198 .ko + `Module.symvers`);
3. 编 `sprd-drm.ko`(内部屏配置)与 `sprd-vpu-pd.ko`。
   **验收**:两个 .ko 产出、`llvm-objdump -p` 的 vermagic = `5.4.254-gb50db5b6224c SMP preempt mod_unload modversions aarch64`。
   **风险评估**:新模块只 import 现有内核符号;若 CRC 不符,内核 insmod 会直接拒绝(干净失败),届时再按 `Module.symvers` 逐符号比对。

### P1 内屏点亮(**不重启**,运行时 insmod)(✅ 完成)
1. `scp` 新 .ko 到 `/lib/modules/5.4.254-gb50db5b6224c/`;
2. `kmodloader unisoc-iommu.ko` → `ion_cma_heap.ko`/`ion_ipc_trusty.ko` → `sprd-vpu-pd.ko` → `sprd-drm.ko` → `zte_lcdbl_vsp_vsn.ko`,每步看 `dmesg | tail`;
3. **验收**:`/dev/dri/card0` 出现;dmesg 里 `dpu`/`dsi`/`panel`/`backlight` probe 成功(或明确报出缺哪一条);`/sys/class/backlight/` 出现。
   **回滚**:`rmmod` 逆序;或内核 hang → 断电重启(misc tries 兜底)。
   **风险 R1(最大未知数)**:`vpu_pd_top` 的 genpd provider 现在根本没注册(cur `pm_genpd_summary` 为空),DPU 会 `-EPROBE_DEFER`;若 realme 版驱动在本机 DT 上跑不起来,退路是临时让 DPU 跳过 PM domain(显示电源域的 PMU 默认态常常是开的),但这是 hack,要先记录清楚。

### P2 显示验证(✅ 完成,含竖屏判定)
1. 屏上出现内容(先自绘色块/测试图,再进 P3);
2. **验收**:背光可调(`echo 0|N > /sys/class/backlight/*/brightness` 有肉眼可见变化);面板无花屏/半屏(顺带确认 DT `sprd,dual-channel=1` 是单屏双通道而非双屏,见 R2)。

### P3 状态页 + 按键守护(✅ 完成;按键守护并入 `changxing60-screen`,不单列进程)
1. 交叉编译静态 `changxing60-screen` / `changxing60-screend`(docker `changxing60-kbuild-cross`),`scp` 到 `/usr/bin`;
2. 写 `/etc/init.d/changxing60-screen`;
3. **验收**:G1 + G2 两条;按键响应 <200 ms;熄屏后 WAN/WiFi 功能不受影响。

### P4 OpenWrt 全功能自查(✅ 逐条查完)
逐条实测,坏的当场修;**验收**:清单全绿或明确标注「本机不适用/已知限制」。
已完成部分见 §5;WAN 报告 bug、LuCI 误判已在本轮澄清。
**收尾三项**:NAT/防火墙跨重启复测 ✅(nft 重建 + conntrack 端到端)、上游 DNS 双备 ✅(加 223.5.5.5/119.29.29.29)、**WiFi AP 多客户端压测 ⏳ 缺条件**(单客户端真机第三轮已实测,见「第三轮」第 12 条;并发仍缺,见 §8 第 0 条)。
另第三轮补掉 WAN 的最后死角:**蜂窝数据「修不回来」时的重启兜底**(见「第三轮」第 11 条,`mobile-data` `6c6fe97`)。

### P5 持久化 + 文档(✅ 主体完成)
1. ✅ 显示模块(6 个 .ko)与用户态(`changxing60-screen`/`keyinject`/`display-modules`/init 脚本)全部固化到设备持久 ext4,**两次重启实测自恢复**;
2. ✅ `openwrt/build-rootfs.sh` 补齐显示栈(模块 + 二进制 + enable 服务),并修好它自身的单引号解析 bug → **重建 tarball 现在能复现当前设备**;
3. ✅ `tools/screen/build.sh` 同时编 `changxing60-screen` 与 `keyinject`;
4. ⏳ 剩余:§2 新事实回写 `README`/`MANIFEST` + 3 处旧文档纠错(见 §7 文末)。

### (可选)P6 文本控制台
编内核开 `CONFIG_FB=y + DRM_FBDEV_EMULATION=y + FRAMEBUFFER_CONSOLE=y` → 面板上出真正的 Linux 控制台(能看到启动日志/login)。
**这一步会改内核镜像**,必须先跑 CRC 门禁(比对 109 个模块的 `__crc_*` 与新 `Module.symvers`)再刷。默认不做,按需再说。

## 5. OpenWrt 功能自查清单

全部条目为 2026-10-13 重启后**现场实测**结果(命令与输出见下);蜂窝 WAN 与 WiFi AP 两行另有**第三轮真机客户端**的实测补强(见「第三轮」)。

| 项 | 现状 | 实测证据 |
|---|---|---|
| 蜂窝 WAN | ✅ | `sipa_eth0 <运营商IP>/32`(**每次重连都换**,本轮实测过 10.67.19.111 → 100.114.5.58)+ 默认路由 `dev sipa_eth0`;`ping 223.5.5.5` 0% 丢包;宿主经它 HTTP 200;设备自身 `wget http://www.qq.com/` 10/10。**另有 "假活" 自愈**:watch 按 ICMP 探针 + 健康文件判活/报红/自修复(「第二轮」第 10 条),再修不动时**最后手段重启一次**(「第三轮」第 11 条) |
| WiFi AP | ✅ | hostapd `status=ENABLED` `ssid=changxing60`(2026-10-13 改名,原 `MU300-D0FD`) `bssid=<REDACTED-MAC>`(出厂 MAC,重启后不变);`wlan0` UP 且已桥入 `br-wifi`。**真机客户端实测**(第三轮,当时 SSID 还是 `MU300-D0FD`):ping 0% 丢(1472 B 大包 10/10)、hostapd 下行 81.5 MB/61,348 包 **0 错**、抓包重传 0.45% / **0 RST**、QUIC+STUN 双向通 —— 空口干净。**并发多客户端**仍缺条件 |
| USB LAN(usb0/NCM) | ✅ | `br-lan 192.168.77.1/24`(仅管理口,不下发网关/DNS)+ `fd96:.../60`,usb0 为桥口;本轮所有 ssh/scp 都走这条 |
| NAT + 防火墙 | ✅ **(跨重启复测)** | `uci` 已提交(`uci changes` 空)→ 重启后 nft 重建出 `chain forward_lan { jump accept_to_wan }` + `chain srcnat_wan { masquerade }`;端到端:宿主 →`baidu.com` HTTP 200,conntrack `192.168.77.199→39.156.70.239` NAT 成重启后的新蜂窝 IP `10.67.19.111` `[ASSURED]` |
| DNS/DHCP(dnsmasq) | ✅ **(加了双备)** | dnsmasq 在跑;上游 = 运营商 `211.138.21.66/23.66`(`resolv.conf.auto`)+ **新增公共回退 `223.5.5.5`/`119.29.29.29`**(`uci` 已提交,重启后仍在 `dnsmasq.conf` 的 `server=` 行);`/tmp/dhcp.leases` 1 条;`nslookup openwrt.org` 正常 |
| LuCI | ✅ | `curl http://192.168.77.1/cgi-bin/luci/` → 403 + `x-luci-login-required: yes` + `<title>mu300 \| Overview</title>`(即登录页;busybox wget 会因 403 丢弃响应体,曾误判为挂)。**屏上二维码另用 OpenCV `QRCodeDetector` 独立解码 = `http://192.168.77.1/`**,即扫码这条入口也是实测过的 |

> ⚠ **本表是 2026-10-13 快照,已被「第五轮」部分修正**(见本文顶部第五轮):①二维码后来改为
> **Wi-Fi 加入码**(不再是 URL),URL 改印页脚;②页脚地址应由 `192.168.77.1` 改成
> `192.168.8.1`(第五轮已改代码、**真机未验**);③标题 `<title>` 已随整机改名成 `changxing60`。
> 本表保留作 10-13 现场读数,真机新二进制上线后以实测为准。
| 时间同步(NTP) | ✅ | `ntpd` 在跑,`S98sysntpd` 已 enable;设备 `+03`(随国家码 TR),换算 UTC 与宿主机一致 |
| zram/swap | ✅ | `/dev/zram0` 2.8 GiB swap,priority 100;状态页显示 `swap 2739 MB` |
| 热管理 | ✅ | 26 个 thermal zone 读数正常(≈40 °C);zone24/25 读报 EINVAL 属该 zone 无 temp 属性 |
| 存储持久化 | ✅ | 显示栈 + 服务 + 配置两次重启自恢复 |
| 模块二次加载(extra-modules) | ✅ | 重启后无 `insmod` 失败;显示 6 模块由 S95 加载,`/proc/modules` 全在 |
| IPv6(WAN) | ✅ **(2026-10-13 第四轮推翻旧结论)** | `sipa_eth0` 有全局 `2409:8947:365:97f:…/64`,默认路由 `default via fe80::1 dev sipa_eth0 proto ra metric 1024`;`ping6 2400:3200::1` **0% 丢**;`wget http://[2400:3200::1]/` 回 **HTTP 404**(能收到 HTTP 应答 = TCP v6 也通,404 只是那台服务器没有默认首页)。热点下游的 v6 中继/NAT66 另见 `ipv6.md`。**旧记录"WAN 只有 link-local"作废** |
| 魔法(OpenClash) | ✅ **(2026-10-13 第四轮上机)** | mihomo v1.19.31 + `/etc/openclash/91code.yaml`,`/etc/init.d/openclash status` = running,TUN `utun 198.18.0.1/30`,`ip rule` fwmark `0x162` → table 354;实测 `www.debian.org` 15,864 B 经 SG 节点、国内域名 DIRECT;宿主 PC(br-lan)未被劫持。**魔法只走 IPv4**(`ipv6` 不被接管)。实录见 `proxy.md` §8 |
| 重启 / 启动槽 | ✅ **(2026-10-13 第四轮定性)** | `/etc/changxing60/default-boot=linux` + misc `slot b = 2f(prio15/tries2/successful0)`,开机 ~70s 由 `changxing60-post` 的 bootok 重新 arm;今天多次重启(含 `mobile-data` 最后手段那次)**全部回到 OpenWrt**。⚠ **开机 ~70s 内连着重启两次**会 tries 2→1→0 → 回落 Android。三种重启方式见 `access.md` §5 |
| LED(状态灯) | ⚠️ 限制 | 仅 `mmc0/1/2`,无 `sc27xx:blue` 等状态灯可绑 |
| 信号强度 | ⚠️ 不显示 | `+CSQ` 返回 `99,99`(不支持);`+CEREG: 2,1,"400465",...,11` 可用,但**状态页刻意不碰 AT**——`mobile-data` 在活数据呼叫上占着 AT 通道,状态页插 AT 会打断它。要做需先让 `mobile-data` 把注册态/运营商落成文件再读 |

## 6. 风险登记

| # | 风险 | 状态 | 说明 / 对策 |
|---|---|---|---|
| R1 | `sprd,vpu-pd` genpd 不匹配/不生效 | ✅ **已解除** | `kmodloader` 装上电源域驱动后 DPU 不再 defer;dmesg 出 `[drm] sprd_drm_bind()` / `bound 31000000.dpu` / `bound 31300000.dsi` 全链 |
| R2 | DT `sprd,dual-channel=1` + `dphy1` | ✅ 已排除 | 实测单屏双通道,无花屏/半屏 |
| R3 | LK 已点亮面板,内核再走一遍上电+init 序列 | ✅ 已排除 | 面板干净重初始化,无撕裂 |
| R4 | 无电池导致的 PD hard reset 处理 | ✅ 沿用既有方案 | 沿用 `sc27xx_pd` 的 `changxing60_allow_hard_reset` |
| R5 | DRM 驱动加载后内核 hang | ⚠️ **部分坐实** | `rmmod sprd-drm` **必挂内核**(硬件看门狗随后重启):显示栈只 insmod,**绝不 rmmod**,要改就重启 |
| R6 | 状态页读到不存在的数据源 | ✅ 已处理 | 每项「取不到显示 —」;实测熄屏/亮屏循环下数据不残 |
| R7 | 熄屏后误触发关机(PMIC 长按路径) | ✅ 已处理 | 只处理短按(<150 ms 去抖),长按不绑定动作 |
| R8 | 按键设备晚于程序出现 / 重新编号 | ✅ **本轮修掉** | 从「启动时打开一次」改为「每刷新周期重扫」,新设备自动接管 |

## 7. 明确不做

- 触摸:本轮不启用(G3),用户单独确认后再议。
- ~~GPU/`mali_kbase`:不编不装(省电 + 无需求)~~ —— **已作废**(2026-10-15):用户要求 GPU 正常,
  前提变了。现为编好入库、默认随 `extra-modules` 加载;代价 ~45 MiB 常驻,见 [`gpu.md`](gpu.md) §6。
  **"状态屏不用 GPU"这条仍然成立**,两者不冲突。
- 7.2 内核:不评估不推进(§0 非目标)。
- 真实浏览器渲染 LuCI:不可行,用二维码 + 自绘状态页替代。
- ~~钉死 WiFi BSSID~~:已于 2026-10-13 做掉(走 `SPRDWLSETNDEVMAC` ioctl,见上「新记录的硬件/驱动限制」)。

## 8. 待办清单(按优先级)

0. **P4 收尾只剩 1 项**:WiFi AP **多客户端并发**压测 —— **单客户端已被第三轮实测覆盖**(见「第三轮」第 12 条),
   缺的是**同时多台**。本机只有 USB-NCM 那条宿主链路(宿主 WSL 无无线栈);让用户的笔记本连上热点会把它整个网络
   切到蜂窝上并消耗流量,不做。要测就找第二台手机同时连 `changxing60` 再压。其余收尾已做(见上「本轮另外做掉的 P4 收尾」)。
1. ~~**P5 收尾 — 旧文档纠错**(3 处,均为已被实测推翻的旧结论):~~ ✅ **已完成**(display-design.md 顶部作废横幅、FINDINGS.md 三处、build-display.sh 顶部注释)。原文留档:
   - `docs/changxing60/display-design.md`:「MU300 无显示硬件」与「5.4 无平台 suspend」两条前提都不成立,应在文首标注作废并指向本文;
   - `changxing60-linux/docs/FINDINGS.md`:「ZTE 树无 display/touch」——display 在 ZTE 树内(只是 `CONFIG_DRM_SPRD` 没开),touch 在 SPI 上(`axs15205`);
   - `changxing60-linux/kernel/build-display.sh` 顶部注释:「MU300 ships without display」与本机 DT 矛盾。
2. ~~**P4 收尾**:WiFi AP 多客户端压测(需真实客户端);NAT/防火墙规则跨重启复测;上游 DNS 双备。~~ → NAT 复测 ✅、DNS 双备 ✅(见上),**多客户端压测**移到第 0 条。第三轮又补上**蜂窝 WAN 的重启兜底** ✅(`6c6fe97`,见「第三轮」第 11 条)。
3. **(可选)P6**:`CONFIG_FB=y + DRM_FBDEV_EMULATION=y + FRAMEBUFFER_CONSOLE=y` 上文本控制台。**会改内核镜像**,须先跑 CRC 门禁(比对 109 模块 `__crc_*` 与新 `Module.symvers`)再刷。
4. **(可选)状态页加运营商/注册态**:需先让 `mobile-data` 把 `+CEREG`/`+COPS` 结果落成文件,状态页只读文件不碰 AT(见 §5 信号强度一行)。
5. **(非本机可修,记下来免得重复排查)**客户端把「连通性自检失败」当硬判据:第三轮定性出的「很多 network error」,
   根因在客户端侧 —— 它查 `clients3.google.com` / `clients.l.google.com`,而这些目的地**从运营商侧就不通**
   (设备自己 ping 也 100% 丢)。热点侧已实测干净(0% 丢 / 0 错包 / 0 RST),要改善只能从客户端侧绕开自检域名。
