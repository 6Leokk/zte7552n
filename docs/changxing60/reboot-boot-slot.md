# 启动落点与两条切换动线:OpenWrt ↔ Android

> **状态(2026-10-17)**:两个方向都有正式入口 ——
> **OpenWrt→Android 走后台按钮**(LuCI 服务→启动目标,本轮新增的第 6 个面板,已上机验过读写),
> **Android→OpenWrt 走宿主一条命令**(`changxing60-linux/tools/changxing60-back-to-openwrt.sh`)。
> 落点规则(任何重启都回 OpenWrt)是 10-13 定性的,见 [`access.md`](access.md) §5;本文是"怎么切"的总装。
> 本轮**没有按过 Reboot 按钮**(用户约束:这一轮不再重启),按钮以下的写入链路是实测过的。

## 0. 三十秒看懂:落点由什么决定

这台机有两个可引导系统:**slot a = 原厂 Android**,**slot b = 我们的 OpenWrt**
(自编 5.4.254 内核 + vendor_boot_b)。哪一次重启落到哪里,**只由 misc 分区偏移 2048 的
32 字节 `bootloader_control` 决定**,与你按了什么键无关。当前真值(设备上读回):

```
default boot: linux
misc bootloader_control: 5f6200004243414201020000fe002f000000000000000000000000001c751554
                                         slot a = 0xfe(已成功)  slot b = 0x2f(prio 15 / tries 2)
```

两个事实让"回 OpenWrt"成为默认行为:

- **每次 OpenWrt 开机成功 ~70 秒后**,`changxing60-post` 把 slot b 重新置回 `tries=2`
  (`changxing60-next-boot --rearm`)。所以软重启/硬复位/断电再开,落点都是 OpenWrt。
- **`boot_a` 从头到尾没人碰过**,原厂随时在;切到 Android 不需要刷任何东西,只是改那 32 字节。

唯一的坑(10-13 定性,背下来):**开机 70 秒内连着重启两次**,tries 走 `2→1→0`,
LK 判定 slot b 不可用、自动回落到 slot a —— 那时才真的落到 Android,而且这才是"救不回来"
场景的起点(回法见 §2)。

## 1. 动线 A:OpenWrt → Android(后台按钮)

**入口**:LuCI → 服务 → **启动目标**(order 65,排在短信/通话/转发/USB/网络之后)。
页面上永远是三颗按钮,状态永远是一张读回来的表:

| 按钮 | 做什么 |
|---|---|
| Boot OpenWrt(slot b,安全默认) | 重新武装 slot b(tries=2)。**点了不会重启**,只是回到常态 |
| Boot Android(它自己的系统) | **先弹二次确认**,确认文案里写全了"回去的路"(单向门,这是 Linux 里最后一个能读到那句话的地方);确认后武装 Android |
| Reboot now | 单独一颗,把"武装"和"重启"分开的目的:有人在看着的设备绝不该被顺手重启 |

**底下是什么**:页面(`view/changxing60boot/boot.js`)→ rpcd 对象 `changxing60boot`
(`ucode/changxing60boot.uc`)→ **`/opt/changxing60/bin/changxing60-next-boot`**。
写入全部走这一个脚本 —— 它写完会读回、读回不符就退出码 1;页面显示的 misc 字节、slot a/b
两个 info 字节,是**写完后重读的真值**,不是"命令应该做到了"。`set` 的返回也一样:后端拿
新状态回话,回读不等于所设就报错。这一层设计保证页面、ssh 终端、每开机跑一次的
`--rearm` 三方永远不会对"现在武装的是谁"得出三个结论。

**CLI 等价**(不用浏览器时):

```sh
/opt/changxing60/bin/changxing60-next-boot status     # 看
/opt/changxing60/bin/changxing60-next-boot android    # 武装 Android(下一跳就回 Android)
/opt/changxing60/bin/changxing60-next-boot linux      # 改回武装 OpenWrt
```

武装完成后重启走哪条路都行(LuCI 系统→重启 / `reboot` / 页面上的 Reboot now 是同一个
`/sbin/reboot`)。**重启后设备就在 Android 里了:没有 Web 后台、没有 ssh、没有 USB 管理网卡**
—— 这是预期,不是故障;换回的方法在 §2。电源键不能切系统:它只负责重启,落点仍由那 32 字节定。

**实测回执(2026-10-17,设备在线时)**:`set android` → 读回确认 → `set linux` → 32 字节
与动手前**逐字节相同**(`…fe002f00…`);rpcd 三方法在 ubus 可见;HTTP 实际 serve 的 boot.js
md5 与仓库一致;登录页 nodespec 里本菜单 `"satisfied": true, "order": 65`,标题已出中文
(启动目标)。**没按过的**:Reboot now 的真跳变(按约束不重启)——它的实现只是
`( sleep 1; /sbin/reboot ) &` 加一秒引信让 rpcd 来得及回话,机制与"LuCI 系统→重启"同路。
另记一条教训:后端解析 `misc bootloader_control:` 那行时切片偏移第一版错了 3 个字节
(22 应为 25),**第一次真调用就被真机抓出来** —— 解析函数的判据永远是对着真实输出跑,
不是对着文档字符串。

## 2. 动线 B:Android → OpenWrt(宿主一条命令)

前提:Android 已 root、adb 可用(本项目一律用 Windows 侧 `/mnt/c/platform-tools/adb.exe`,
单层调用)。**首选**:

```sh
changxing60-linux/tools/changxing60-back-to-openwrt.sh              # 全家桶:换 payload → 修 DTB → 重启 → 验 USB
changxing60-linux/tools/changxing60-back-to-openwrt.sh --dry-run    # 只探测 + 打印计划,一个字不写
changxing60-linux/tools/changxing60-back-to-openwrt.sh --no-reboot  # 两步都写,但不重启
```

顺序不是随意的,脚本自己也不容许随意的(每步验自己的 OK 标记,缺一个就停):

1. `tools/stage-adapt.sh --stage` —— 先把驱动适配 payload 装回去。放最前是因为**下一次开机加载
   哪些 vendor 模块由它决定**;设备上留下的手工快照里 default 组还含着 `misc` 组,那个组一加载
   ~3 秒就把内核带走(`CFI failure (target: 0x0)`)。带着它重启,"没 USB"会变成"根本没开机"。
2. `tools/changxing60-dtb-fix.sh` —— **`vendor_boot_b` 里 9 字节**:
   `/soc/ipa-apb/dummyphy` 改回 `status = "okay"`,并给 slot b 一次机会(tries=1)。少了它,
   下一次 slot b 开机没有 usb2.0 phy provider、没有 UDC、没有任何门。
   注意这 9 字节与内核线**互斥**:同一份 `vendor_boot_b`,5.4 要 `okay`、6.18 试验线要
   `disabled`(见 [`drivers.md`](drivers.md) §2.1)——切一次内核线就要再改一次。
3. `adb reboot` → `tools/changxing60-verify-usb.sh --wait`(UDC、dummyphy 绑定、gadget 挂上、
   usb0 起来)。

**手工兜底**:`boot/android-boot-linux.sh <boot-linux-slotb.img>`。它先校验 boot_b 前 48 MiB
的 sha256 与该镜像一致(尾部是每开机都变的持久 init 日志,不比),**这就证明 boot_b 里的试启
镜像还在** —— 在,就只推 `.misc-slot-b-trial.bin` 进 misc offset 2048、读回校验、重启;
回到 Linux 里再 `changxing60-next-boot linux` 把 tries=2 的常态钉回去。
boot_b 若已被刷花,那才需要 `boot/flash-trial.sh` 重刷 slot b 侧(依然不碰 boot_a)。
2026-10-15 的旧说法"落 Android 后可能要重刷 boot_b"已被实测推翻:落点状态全在 misc,
`work/*.misc-slot-b-trial.bin` 逐字节相同就是证据。

**回到 OpenWrt 之后**:等满 1~2 分钟让 `changxing60-post` 把 tries 重新武装,再考虑下一次重启
(§0 的 70 秒坑)。

**物理兜底**:长按电源键(硬断电再上电,落点仍由 misc 定,所以它只能救"卡死",不能救
"武装错了");PMIC 的长按语义本机没单独测过,别把它当常规手段。

## 3. 判据与假信号

- **三态分辨,只看 USB**(宿主侧,`reconnect` 系列工具):adb 有行 + 没有 192.168.77 网卡
  = 在 Android;adb 空 + 有 PnP gadget/NCM = 在 OpenWrt;两者皆无 = 根本没上 USB
  (看 `VID_1D6B`/`PID_A4A3`,别把本机网卡 `VID_0E8D` 认成手机)。
- **WSL 上 OpenClash TUN 会劫持 192.168.77.1**,`Connection closed ... port 22` 能伪装成
  "设备在线"——判在线一律看 USB,不看 ssh 报错样式。
- **切到 Android 后一切 Linux 侧探测都是"坏"** ——那是换系统成功,不是故障;同理,
  刚回 OpenWrt 的头两三分钟 usb0 只有 link-local 是必然的(见 [`access.md`](access.md) §5 末)。

## 4. 相关文件

| 位置 | 是什么 |
|---|---|
| `openwrt/overlay/www/luci-static/resources/view/changxing60boot/boot.js` | 面板视图 |
| `openwrt/overlay/usr/share/rpcd/ucode/changxing60boot.uc` | rpcd 后端(status/set/reboot) |
| `openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60boot.json` + `menu.d/同名` | 权限与菜单注册 |
| `openwrt/overlay/opt/changxing60/bin/changxing60-next-boot` | **唯一写那 32 字节的脚本**(写后读回自证) |
| `changxing60-post`(init 脚本) | 每次成功开机 ~70 s 后 `--rearm` |
| `tools/changxing60-back-to-openwrt.sh` / `boot/android-boot-linux.sh` / `boot/flash-trial.sh` | Android→OpenWrt 的三层兜底 |
| `docs/changxing60/access.md` §5 | 落点规则的原始定性(10-13) |
| `docs/changxing60/drivers.md` §2.1 | vendor_boot_b 那 9 字节的来龙去脉 |
