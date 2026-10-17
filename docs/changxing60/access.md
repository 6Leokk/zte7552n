# 7552N / 畅行60:怎么连进去(URL / 账号 / 密码)

> 记录日期:2026-10-13。设备 = 原生 OpenWrt 25.12.5(path A 持久 ext4),内屏状态页在跑。
> 关联:[`screen-plan.md`](screen-plan.md)(内屏/按键/全功能自查)、[`port-design.md`](port-design.md)。
>
> ⚠ **本文件含明文口令**(热点 PSK)。本仓库(外层 `zte7552n`)**没有配任何 git remote**,只在本机;
> 一旦给它加 remote 并 push,这个 PSK 就跟着出去了。要公开仓库就先把本文件的密钥段删掉或改走 `pass`/环境变量。

## 1. 内屏上那条链接是什么

状态页最底下那行 `LuCI http://192.168.77.1/` 是设备自己的 **LuCI 后台**(以下为 2026-10-13 现场读数):

> ⚠ **该地址待改**:`screen-plan.md`「第五轮」已把页脚选址从「先问 `br-lan`」改成「先问 `br-wifi`」,
> 即热点侧读者看到的应是 `192.168.8.1`。代码已改、**真机新二进制未验**;在它上机前,真机屏上仍印
> `192.168.77.1`。下文命令里 `192.168.77.1` 指的是 USB 侧 `br-lan` 的固定地址(USB 口不受这次改动影响)。

```
http://192.168.77.1/
```

正中那个二维码**不是**这个网址,是 **WiFi 入网码**(`WIFI:T:WPA;S:changxing60;P:...;;`)——
用手机相机直接扫就能连上热点,不用手打口令(用 zxing-cpp 对屏上实际像素解码验证过)。
改热点口令后屏上的码约 4 秒内自动跟着变(状态页每 2 秒一个 tick,慢 tick 重读 `/etc/config/wireless`)。

从**手机/电脑**访问的前提是那台设备已经连上本机的网络,两条路:

| 方式 | 做法 | 说明 |
|---|---|---|
| USB 共享(推荐) | USB 线插电脑 → 电脑侧网卡自动 DHCP 拿到 `192.168.77.100`~`.249`(本机现在 `.199`) | 就是当前 WSL 宿主那条链路 |
| WiFi 热点 | 手机/电脑连 SSID `changxing60`(见 §3),拿 `192.168.8.100`~`.249` | SSID 和 BSSID 都已固定(见 §3),一次配对之后开机就自动重连 |

### USB 口和热点是**两个网段**(2026-10-13 拆的)

```
br-lan   (usb0)      192.168.77.1/24   ← 管理口:只发地址,不发网关、不发 DNS
br-wifi  (wlan0)     192.168.8.1/24    ← 热点:网关 + DNS = 192.168.8.1,照常上网
```

以前两者共用 `192.168.77.0/24`,那一个 dnsmasq scope 会把**设备自己**当成网关和 DNS 发给所有
客户端——包括 USB 线那头那台**本来就有自己网络的电脑**。在 Windows 上这不是无害的:实测 USB 网卡
那条默认路由(经 `192.168.77.1`,接口跃点 25)**压过了电脑真正的 WiFi 出口**(跃点 30),代理没接管的
公网目标就会静默改走这台手机的蜂窝。现在管理口只发地址,插任何电脑都不会被抢默认路由。

从热点侧仍然能访问 `192.168.77.1`(两个网络在同一个 firewall zone,设备自己转发;实测 iPhone 连上
热点后 `192.168.8.110 → 192.168.77.1:80` 的 conntrack 是通的)。屏上所以还是印 `192.168.77.1`,
因为**这个地址对两边都可达**,而 `192.168.8.1` 对 USB 那头的电脑不可达。

> ⚠ **上面这句曾经悄悄变假过一次(2026-10-15 → 10-16),值得记住它为什么会假。**
> 10-15 那次重建换掉了 `etc/config/firewall`,而 `br-wifi` 进 zone 的那一行只存在于 `net-split` 里
> (那个脚本当时是 644,首启 `Permission denied`,被 `exit 0` 吞掉)——于是 `br-wifi` 不属于任何 zone,
> **热点客户端不但开不了 77.1,连 DHCP 地址都拿不到**。10-16 把 zone 修回来之后,这句才重新成立
> (实测手机连上后拿到 `192.168.8.196`,48 条 conntrack 里有到公网 IP 的 TCP)。细节见
> `changxing60-linux/docs/FINDINGS.md` §35 与 [`drivers.md`](drivers.md) §8 的"同一轮重启顺带证的"。

拓扑改动落在 `changxing60-linux/rootfs/overlay/opt/changxing60/bin/net-split`(幂等,重装由 `90-changxing60` 调它;
老装机直接跑 `net-split --apply`)。

### 客户端连上后报 "network error"?(2026-10-13 实测定性,先别怀疑热点)

2026-10-13 拿真机客户端连热点跑下载时逐层实测过,**这条路是干净的**:空口 ping 0% 丢(1472 B 大包也 0%)、
hostapd 客户端计数下行 81.5 MB / 61,348 包(`tx_errors 0` / `rx_errors 0`)、抓包 447 个 TCP 载荷段只重传 2 个
(0.45%)且 **0 个 RST**、QUIC 与 STUN 双向都通、DNS 每个查询都在同一秒被 `192.168.8.1` 答掉。

真正的异常只有一类:客户端有 8 次连 `:443` **收不到 SYN-ACK**(重试 3–9 次),目的地**全是 Google 系**
(`142.250.157.x`、`128.242.240.212`)——**从设备自己 ping 也 100% 丢**,是运营商侧不通,与热点无关。
客户端同时在查 `clients3.google.com` / `clients.l.google.com`(系统**连通性自检**),自检失败会让系统把这条
WiFi 标成「无互联网」,很多 App 随后直接报网络错误。**这是"很多 network error"最可能的解释**,热点侧改不了。
详见 [`screen-plan.md`](screen-plan.md)「第三轮」第 12 条。

## 2. 登录 LuCI / SSH 的密码

**现状(2026-10-16 起):不再是空口令。** 真值**不进仓库**——主机侧存在
`~/.changxing60-secrets`(`ROOT_PASSWORD=`,与 `~/.changxing60-password` 同值);仓库工具用
`$CHANGXING60_PASSWORD` / `$CHANGXING60_PASSWORD_FILE` 注入。"空口令"时代的全部旧笔记和旧脚本
已经失效 —— 这条曾经咬过一次:仓库里所有主机侧工具(它们用 `BatchMode=yes` 非交互 ssh)
突然全线连不上,先被误判成"设备不在 USB 上",实际是设备在、认证不过。见 §5.1 的三态分辨。

```
LuCI   用户名 root      密码见主机 ~/.changxing60-secrets(不进仓库)
SSH    ssh root@192.168.77.1        (同一口令;也可用下面 §2.1 的密钥免密)
       ssh root@fd96:b832:c98b::1   (USB-NCM 那条 IPv6,同一口令)
```

LuCI 和 SSH 是**同一个 root 账户、同一份 `/etc/shadow`**,所以改一处等于改两处 —— 用户当时说的是
"改的是登录页面、ssh 没动",但在这台机器上不存在"只改 LuCI 口令"这回事:口令一改,SSH 立即跟着变,
这正是当时非交互 ssh 全线失败的原因。

### 2.1 主机侧怎么连才不用每次敲口令

两条路,都已经落在仓库/宿主上:

```sh
# (a) 口令,给一次性命令用
SSHPASS=$(grep '^ROOT_PASSWORD=' ~/.changxing60-secrets | cut -d= -f2-) sshpass -e ssh -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no root@192.168.77.1

# (b) 密钥,免交互;仓库工具走的就是这条
ssh root@192.168.77.1          # ~/.ssh/config 里 Host 192.168.77.1 配了 IdentityFile
```

- 私钥 `~/.ssh/id_changxing60`(ed25519,无口令),公钥已装到设备,并**同时**放进了
  `rootfs/overlay/etc/dropbear/authorized_keys` —— 所以重刷 rootfs 之后密钥仍然有效,不会一刷就掉。
- `~/.changxing60-password`(0600)存口令,`tools/deploy-pending.sh` 会读它(也可用
  `$CHANGXING60_PASSWORD` / `$CHANGXING60_PASSWORD_FILE` 覆盖),所以 `--apply` 不需要交互。
- **两个坑,都是这台机器上实测踩出来的**:
  1. **OpenWrt 的 dropbear 读的是全局 `/etc/dropbear/authorized_keys`,不是 `~/.ssh/authorized_keys`。**
     把公钥放进 `/root/.ssh/` 完全没用,而且**不报错**,只是静默仍然问口令。判据是
     `dropbear -v` 不受支持(它没有这个开关,usage 里才有线索:
     `-D Directory containing authorized_keys file`)。
  2. **`/etc/dropbear` 与 `/etc/dropbear/authorized_keys` 必须属主 root**(前者 0700、后者 0600)。
     否则 dropbear 直接拒绝用这个文件,日志里只说目录必须属于用户或 root、且不能被 group/other 写 ——
     不说它读的是哪个文件。这台机器上它一度是 `1000:1000`,根因见 §2.2。

### 2.2 顺带查出来的:整个 rootfs 的属主曾经是 uid 1000

密钥装不上这件事顺藤摸出一个更值钱的 bug:**这台设备上每个顶层目录都曾经是 `1000:1000`**,
而不是 root。根因在构建侧、不在设备侧 —— `openwrt/build-rootfs.sh` 用 `cp -a` 把宿主上的
`rootfs/overlay`、`openwrt/overlay`、`android-subset` 拷进去,而 `cp -a` 会把**源目录的属主**
写到**已存在的目标目录**上;宿主那几棵树是 uid 1000,于是 `/usr`、`/etc`、`/www`、`/opt/changxing60`
乃至根目录本身全成了 1000:1000(打出来的 tar 里有 531 条 `1000/1000`)。

为什么值得单独记:它在**设备上的症状是 dropbear 拒用 authorized_keys**(§2.1 第 2 条),
看起来像密钥配错了;而同一个签名在安卓侧已经害过一次 —— 属性区解包成 `1000:1000` 导致 bionic
静默不 mmap,`getprop` 一条都读不出来(见 [`cptl-and-boot.md`](cptl-and-boot.md) §4.2)。
**同一个坑,两种毫不相干的表象。**

修法是在打 tar 之前 `chown -Rh 0:0 $R`。两个细节都是实测出来的,不是推理:

- **必须是 `-Rh`,不能只写 `-R`**:镜像里有故意留着的悬空软链(`/etc/resolv.conf`、`/etc/localtime`、
  `/etc/TZ`、`/etc/ppp/resolv.conf`、`.../android/system/bin/linker64`),它们要到设备运行时才有目标。
  裸 `-R` 会去 dereference,撞上第一个悬空链就 ENOENT,而那段容器脚本是 `set -e` ——
  **整个构建在那里中止,tar 根本没写出来,可 exit code 和输出看着像"少了个文件",不像权限问题。**
  容器里是 busybox,它的 chown 只有 `-R` 和 `-h` 两个开关(有 `-h` 就够)。
- **不要用 busybox tar 的 `--owner/--group`**:它没有这两个开关(只有 `-o`,而且是解包侧的)。

判据(**别只看构建 exit 0**,那次中止就没写 tar):
```sh
tar tzvf openwrt/changxing60-openwrt-rootfs.tar.gz | awk '{print $2}' | sort | uniq -c
# 期望:清一色 root/root,没有 1000/1000
```

### 历史:它曾经是空的

以下是 2026-10-16 之前的状态,留档是因为**旧笔记和旧脚本里写的"空口令"仍可能被翻出来照抄**。
当时 `/etc/shadow` 是 `root:::0:99999:7:::` —— **不是"密码等于 root"之类的默认值,是根本没有口令**;
LuCI 用空 `luci_password` 直接 302 发会话 cookie,dropbear 日志记
`Auth succeeded with blank password for 'root'`。也就是说**能连上热点或插上 USB 的人直接就是 root**,
唯一的门槛是热点 WPA2 口令(§3)。安装脚本 `changxing60-linux/install.sh` 本会让装机的人指定口令;
这台走 path A 手工恢复流程装,口令字段留空了(见 `README.md` 的 09-19/20 记录),10-16 才补上。

改口令的方法(**会同时改掉 LuCI 和 SSH**,两处共用这一个系统口令):

```sh
# 在设备上(或者经 ssh 进去后)执行;把 <pw> 换成你要的
printf '%s\n%s\n' '<pw>' '<pw>' | passwd root
```

设完 **LuCI 也一样用它**(LuCI 校验的是同一个系统口令)。本文件请同步更新,否则下次自己都进不去。

## 3. WiFi 热点的口令

```
SSID       changxing60        ← 2026-10-13 从 MU300-D0FD 改名(整机改名 changxing60)
BSSID      <REDACTED-MAC>      ← 本机出厂 MAC,固定
加密        WPA2-PSK (psk2)
口令        见主机 ~/.changxing60-secrets(HOTSPOT_PSK;不进仓库)
信道        36 / VHT80 (5 GHz) / 国家码 TR
```

- **BSSID 现在是固定的出厂 MAC**(2026-10-13 修):这台机器**有**出厂 WiFi MAC,存在 `prodnv`
  分区的 `wifimac.txt` 里(Android 把该分区挂在 `/mnt/vendor`,正是驱动里
  `WIFI_MAC_ADDR_PATH "/mnt/vendor/wifimac.txt"` 指的那条路)。以前没人把它喂给驱动,驱动就退回
  `random_ether_addr()` 造一个 `40:45:da:xx`,所以**每次开机换 BSSID**。现在每次开机由
  `/opt/changxing60/bin/wifi-mac` 读 `prodnv` 并用厂商自己的 `SPRDWLSETNDEVMAC` ioctl 写进驱动
  (`/usr/bin/wifimac`),hostapd 的 bssid 与接口地址都是它。之前「驱动忽略 MAC 写」的说法只对
  `ip link set wlan0 address` 成立——那条路走的 `ndo_set_mac_address` 在 AP 模式下是空实现,还返回成功。
- SSID 现在就是 **`changxing60`**(2026-10-13 用户定名:整机叫 changxing60,**不要** `-D0FD` 后缀)。
  更早叫 `MU300-D0FD`(从原厂 Android 导入),`D0FD` 是当年随机 MAC 时代的遗留;改名后
  **已配对过的客户端需要重新连一次**(改 SSID 等于换网)。新装一台机器时 `openwrt-wifi-config`
  的兜底是 `changxing60-<MAC 后几位>`(这台会变成 `changxing60-F8465`,只是兜底,正常不走)。
- 读/改都在设备上:`uci show wireless`(口令在 `wireless.ap0.key`),改完 `uci commit wireless && wifi reload`。

## 4. 内屏上那几个按键提示

状态页页脚写的 `power=on/off vol=dim`:

| 按键 | 行为 |
|---|---|
| **电源键短按** | 亮屏/熄屏(直接写背光 `0` / `255`)。**长按系统侧不绑动作**(反而会落回 PMIC 自己的行为,见 §5) |
| **音量键** | 只调背光(变暗),不会关机 |

熄屏只是把背光关到 0,页面还在刷新;再按一下就回来。页面本身**触摸是故意不启用的**(`zte_tpd` 没加载),
所以屏幕上点不动任何东西,要操作后台就扫码或开浏览器进 §1 那个地址。

## 5. 怎么重启、会不会跑到 Android 去(2026-10-13 定性)

### 结论:**任何形式的重启都回 OpenWrt**

实测过多次:设备今天自己重启过好几轮(含 `mobile-data` 的最后手段重启),**每次都回到 OpenWrt**。
启动目标由 **misc 分区里的 slot 状态**决定,不由"你按了什么键"决定:

```
/etc/changxing60/default-boot          = linux
misc bootloader_control: 5f62…fe002f00…    slot a = fe(已成功)   slot b = 2f(prio 15 / tries 2 / successful 0)
```

开机后 `changxing60-post` 里的 `bootok` 实例(S99,`sleep 30`,约 **uptime 70 s**)跑 `changxing60-next-boot --rearm`,
把 slot b 重新置回 `tries=2`。所以只要开机过了那一分钟,**软重启/硬复位/断电再开,落点都是 OpenWrt**。

### ⚠ 唯一的坑:开机 ~70 秒内**别连着重启两次**

`tries` 每次启动 slot b 会被 LK 减 1。开机 70 s 内(bootok 还没跑)重启一次:`2→1`,**仍然进 OpenWrt**;
**同一分钟内再重启一次:`1→0` → LK 判定该槽不可用,自动回落到 slot a(Android)** —— 那时就不是 OpenWrt 了。
**规矩:开机后等 1~2 分钟再动手,且别在开机一分钟内连按两次。**
(回落过去之后怎么回来:boot_b 里的试启镜像若完好,**不用重刷**,重写 misc 那 32 字节即可 ——
`tools/changxing60-back-to-openwrt.sh`;本方向与反方向"后台按钮切去 Android"的完整动线见
[`reboot-boot-slot.md`](reboot-boot-slot.md)。10-13 当日本节曾写"得重刷 boot_b 才回得来",10-15 实测推翻。)

### 三种重启方式(推荐度从高到低)

1. **LuCI(最推荐,干净卸载路径)** —— 手机连热点 → 浏览器开 `http://192.168.77.1/` → **系统 → 重启**
   (`luci-mod-system` 的 `admin/system/reboot`,已确认页面在;`ubus call system reboot` 也在)。
   **WAN 假死时照样能用**:假死只死蜂窝上行,WiFi/LAN 都还活着,所以从手机/电脑就能点。
2. **SSH** —— `ssh root@192.168.77.1 reboot`(走 USB 那条链路)。
3. **长按电源键(物理兜底,手边完全没网时)** —— 状态页**只处理短按**(长按故意不绑,免得误触 PMIC 关机路径),
   所以长按落到 SC27xx PMIC 自己的行为上:**可能是 ~8 s 硬复位,也可能直接断电**。本机**没有实测过是哪一种**
   (要真按下去才知道,设备已不在手边),但**两条路的落点都是 OpenWrt**(断电就再按一下开机)。
   代价:硬复位不给 ext4 卸载机会(下次挂载 journal 要 replay,一般没事,但不是零风险),能手软重启就别长按。
   **同样受上面那条 70 s 规矩约束。**

> 另外:WAN 救不回来时设备**自己也会重启**(`mobile-data` 最后手段,
> 见 [`sipa-wedge.md`](sipa-wedge.md) §6.4),那是软重启,走同一条 slot 路径。

## 5.1 宿主侧探测陷阱:WSL 上的 OpenClash TUN 会劫持 `192.168.77.1`(2026-10-15 复现)

**在 WSL 里 `ssh root@192.168.77.1` 之前,先确认这条路由没被宿主自己的 mihomo/OpenClash 抢走:**

```sh
ip route get 192.168.77.1
# 坏:192.168.77.1 via 198.18.0.2 dev eth3      <- 走了 fake-ip TUN,不是设备
# 好:192.168.77.1 dev <NCM 网卡> src 192.168.77.x
```

**它的症状极具误导性:不是超时,而是 `Connection closed by 192.168.77.1 port 22`** ——
TCP 连上了又立刻被关,看着像"设备在线但 sshd 有问题",实际是 TUN 在应答一个假地址。

两点后果,都会浪费时间:

- **判"设备在不在"不能只看 ssh 的返回。** 设备真的不在 USB 上时,这条路由依然会给出**同一个**报错。
  可靠的信号是 USB 侧:`/mnt/c/platform-tools/adb.exe devices` 有东西、或 Windows PnP 里出现
  NCM 设备/PID `0xa4a3`(见 §5 的 USB gadget 描述)。路由对没对,只在"USB 已经在了"之后才有意义。
- **等设备重启回来时别用长超时硬等。** 正确做法是**短超时反复重连**(`ConnectTimeout=5`,每个 ~10 s),
  同时用上面那个 USB 信号判断"到底连没连上",而不是靠"等了很久"。

**设备刚重启完的那两三分钟,上面那条"坏"读数是必然的 —— 别把它当成故障(2026-10-16 实测)。**
NCM gadget 一挂上来(Windows 侧 `UsbNcm Host Device`,适配器名"以太网 51";`networkingMode=Mirrored`,
所以它在 WSL 里就是 `eth4`),宿主的 DHCP 就开始要地址,而**设备的 `br-lan`/dnsmasq 要到开机
~200 秒才应答**。这中间:

```sh
ip -br addr show eth4
# 刚重启: eth4  UP  169.254.173.133/16 ...      <- 只有 link-local,没有 77.x
# 拿到租约: eth4  UP  192.168.77.199/24 ...      <- 这才是"可以 ssh 了"
```

没有 `192.168.77.x` 就没有那条 on-link 路由,于是 `ip route get 192.168.77.1` 只能走默认路由 =
落到 Clash TUN 上,读出来就是"坏"的那个样子。**换句话说:设备正在启动时,这条路和"设备没回来"
在宿主侧长得一模一样。** 实测时间线(2026-10-16 那次重启):`ssh` 轮询在第 28 次(约 140 秒后)才第一次
成功,设备侧 uptime 已经是 **224 秒**。所以要等就等**租约**(`ip -br addr show eth4` 里出现
`192.168.77.`),它比 USB gadget 出现得晚得多,但比"设备其实没起来"要早得多。

(注:设备侧的 OpenClash 只劫持**它自己**的流量,宿主 PC 日常上网不受影响 —— 受影响的只有 WSL 里
**主动去连 `192.168.77.1`** 这一个动作。)

## 6. 整机网络栈复测命令(2026-10-13 第四轮体检用的那套,一条条跑即可)

```sh
D=root@192.168.77.1
# 1) 地址 / 链路 / 路由(v4+v6 双栈)
ssh $D 'ip -4 -o addr show | awk "{print \$2,\$4}"; ip -6 -o addr show | awk "{print \$2,\$4}" | grep -v "::1/"'
ssh $D 'ip route; ip -6 route | head -6'
# 2) 双栈连通性
ssh $D 'ping -c3 -W2 223.5.5.5 | tail -2; ping6 -c2 -W2 2400:3200::1 | tail -2'
# 3) 热点与客户端(客户端数只信 hostapd,iw station dump 在这台永远空)
ssh $D 'ubus call hostapd.wlan0 get_status | head -8; ubus call hostapd.wlan0 get_clients | grep -c ":"'
# 4) NAT / 转发 / 错误计数(br-lan 与 br-wifi 的 err 应为 0)
ssh $D 'nft list chain inet fw4 srcnat_wan | tail -4'
ssh $D 'for i in sipa_eth0 br-lan br-wifi; do echo -n "$i rx="; cat /sys/class/net/$i/statistics/rx_packets; echo -n " tx="; cat /sys/class/net/$i/statistics/tx_packets; echo -n " rxerr="; cat /sys/class/net/$i/statistics/rx_errors; echo -n " txerr="; cat /sys/class/net/$i/statistics/tx_errors; done'
# 5) DNS(正常时 dnsmasq 上游是被 mihomo 接管的 127.0.0.1#7874)
ssh $D 'nslookup openwrt.org | tail -3; nslookup www.qq.com | tail -3'
# 6) 魔法是否真的接管:tun 在 + 域名回 198.18.x.x = 是的
ssh $D 'ip -o link show utun; ip rule | grep 1888; ps w | grep "[c]lash -d"'
# 7) 假死状态(判定要点:uptime ≥ ~1200s,且 "peer silent" 为 0)
ssh $D 'cut -d. -f1 /proc/uptime; dmesg | grep -c "peer silent"; grep -E "PROD_CP|CONS_WWAN_UL" /sys/kernel/debug/sipa/rm_res'
```

判读要点:①`br-lan/br-wifi` 的 `rx_errors`/`tx_errors` **必须是 0**;②`sipa_eth0` 的 `tx_errors`
在假死之后会留几十个的残留(不是新故障);③WAN 真假看 `PROD_CP`/`CONS_WWAN_UL` 的 `state` 字段
(`2`=granted 正常、`0`=released、`1`/`3`=卡在请求/释放中),别只看 `operstate` 或地址在不在。

## 7. 相关文档

- 假死根因与补丁(为什么 WAN 会"有地址零流量"、最后手段重启)→ [`sipa-wedge.md`](sipa-wedge.md)
- 魔法运行实录(TUN / fake-ip / nft 规则 / 实测)→ [`proxy.md`](proxy.md) §8
- IPv6 双栈(蜂窝 + 热点下游)→ [`ipv6.md`](ipv6.md)
- 内屏状态页与全功能自查表 → [`screen-plan.md`](screen-plan.md)

## 8. 一句话速查

```
屏上链接         →  http://192.168.77.1/   (LuCI)
屏上二维码       →  WiFi 入网码,扫码直连热点(不是网址)
LuCI 登录        →  root / 口令见 §2(10-16 起非空,值不进仓库)
SSH              →  ssh root@192.168.77.1  (§2 的口令或 §2.1 的密钥,USB 口固定这个地址)
WiFi             →  changxing60 / 口令见 §3   (BSSID 固定 = 出厂 MAC;客户端网段 192.168.8.0/24)
网络             →  USB 192.168.77.0/24(无网关/DNS)  |  热点 192.168.8.0/24(网关=DNS=192.168.8.1)
按键             →  电源键=亮/熄屏   音量键=调亮度
重启             →  LuCI 系统→重启(或 ssh reboot);任何重启都回 OpenWrt,
                    但开机 70 s 内别连着重启两次(tries 2→1→0 会回落到 Android),见 §5
```
