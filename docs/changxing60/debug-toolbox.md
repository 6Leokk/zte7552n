# 7552N 调试工具箱(镜像自带)

从 2026-10-13 起,`changxing60-linux/openwrt/build-rootfs.sh` 会把一组调试工具**打进 rootfs 镜像**,
所以设备上开箱即用。

**怎么调用**:`/opt/changxing60/bin` 由 `/etc/profile.d/changxing60.sh` 加进 `PATH`,但那只对**登录 shell** 生效
(串口/LuCI 终端、`ssh root@…` 进去之后的 shell)。**`ssh root@… 'cmd'` 是非交互 shell,不走 profile.d**
——那时的 `PATH` 是 `/usr/sbin:/usr/bin:/sbin:/bin`,得写全路径:

```sh
ssh root@192.168.77.1 /opt/changxing60/bin/changxing60-diag.sh          # 对
ssh root@192.168.77.1 changxing60-diag.sh                          # 只有登录 shell 里才对
```

## 一、先上这一串

| 命令 | 干什么 | 什么现场用 |
|---|---|---|
| `changxing60-diag.sh [标签]` | **一条命令看全**:uptime/负载/内存/zram、`sipa_eth0` 地址与收发包、`mobile-data` 健康文件、RM 状态、SIPA `nic`/`flow_ctrl` 计数、模块、WiFi SSID/BSSID/客户端、魔法与 IPv6、温度/电量、pstore、内核噪声、`logread` 尾。只读、不发 AT | 「WAN 又死了」「WiFi 不对」时的**第一个动作**;同时留一份到 `/root/diag/<uptime>s.log`,两次跑可以 diff(假死是计数器的*变化*) |
| `changxing60-cp-reset.sh status` | CP 停/起实验的体检:helper、`/dev/modem`、`modem_control` 在不在,并打一行现场 | 动手之前 |
| `changxing60-cp-reset.sh dry`(`recover`) | 停 CP → 观察 20s → 起 CP → 最多 90s 看 WAN 能否自愈,出 VERDICT;并先把最后手段重启**解除武装** | `dry` = 健康 boot 演练;`recover` = 真楔死时救 |
| `changxing60-wedge-watch.sh` | 10s 一拍的假死采样器(uptime / 两个 RM state / rx,tx / 每分钟一次 ping) | 想连续盯假死 |
| `net-down-test.sh wan\|lan\|air` | 下行测速(读 WAN 计数器口径) | 测速 |
| `net-scope-test.sh br-lan\|br-wifi` | 用真 veth DHCP 客户端问两个网段各自给什么地址/网关/DNS | 网段/网关/DNS 不对 |
| `net-v6-client-test.sh [br-wifi]` | 把真 IPv6 客户端挂上热点跟全程 | ⚠ **它把这个内核跑崩过**(见文件头与 `docs/FINDINGS.md` §33),当「带已知危险的台式设备」用,且跑完别马上折腾它 |
| `modem-ioctl stop\|start\|ustop` | 直接发 `/dev/modem` ioctl,别的什么都不做 | 手工做 CP 停/起 |

细节(为什么这么设计、铁律、判据)见 [`sipa-wedge.md`](sipa-wedge.md) §6.6 与各脚本文件头。

## 二、装了哪些工具包

build 时 `apk add` 进去(名字均已实测存在):**ethtool、strace、lsof、iperf3、mtr、socat、drill、
usbutils(lsusb)、htop、iftop、nload、openssl-util、python3-light**。原来就有:tcpdump、curl、
ip-full、dnsmasq-full、iw/iwinfo、bash、coreutils-stty;另加一个**完整静态 busybox**(补 OpenWrt
busybox 缺的 `od/timeout/losetup/telnetd/getty`,在 `/opt/changxing60/busybox-bin`)。

**为什么塞这些**:这个 rootfs 此前**既没有 ethtool 也没有 strace**,两次想用都得绕路;没有解释器
(python3)也两次卡住一次性小检查。

## 三、apk 还能用,但只用 `apk add`

设备的 feed 是好的(`/etc/apk/repositories.d/distfeeds.list` → 25.12.5 的 `armsr/armv8` +
`aarch64_generic` `packages/packages.adb`)。**但只敲 `apk add <pkg>`,不要 `apk upgrade`** ——
`world` 里钉着 `kernel=6.12.94` / `kmod-*`,升级会把 armsr 的 **6.12** 内核与模块装到这台 **5.4**
机器上。(镜像里已删掉 `sysupgrade` / `attendedsysupgrade` / `owut`,online 整盘升级不会自己发生。)

## 四、工具的两份拷贝

**规范副本一律在 repo 的 `changxing60-linux/tools/`**;`build-rootfs.sh` 按名单把**跑在设备上**的那批拷进
镜像 `/opt/changxing60/bin/`。名单里目前是:`changxing60-diag.sh`、`changxing60-cp-reset.sh`、`changxing60-wedge-watch.sh`、
`changxing60-wan-keepalive.sh`、`net-down-test.sh`、`net-scope-test.sh`、`net-v6-client-test.sh`、
`modem-ioctl`。

> ⚠ **「在 repo」不等于「已提交」**:`changxing60-linux` 是独立 git 仓库(被外层 `.gitignore` 忽略),
> 其中 `changxing60-diag.sh`、`changxing60-cp-reset.sh`、`modem-ioctl` 等**仍是未跟踪状态**(`git status` 报 `??`),
> 即只存在本机磁盘、未进 `changxing60-linux` 的 git;一次 `git clean` 或换机就没了。与 `backlog.md` §4
> 记的 OpenClash 缺口是同一类问题。要落盘请先在 `changxing60-linux/` 里 `git add`。

主机侧那些(靠 ssh/adb 驱动设备,不装进镜像):`changxing60-ssh.py` / `changxing60-sh.py` / `changxing60-serial.py` /
`changxing60-telnet.py` / `collect-logs.sh` / `stage-modules.py` / `android-*`。

改了工具 → 改 repo 那份 → **重跑 `build-rootfs.sh`** 才会进镜像;临时也可以直接推:
`ssh root@192.168.77.1 'cat > /opt/changxing60/bin/xxx && chmod 755 /opt/changxing60/bin/xxx' < tools/xxx`。
