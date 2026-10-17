# 路线 B:7552N 在 OpenWrt 下走原生 Linux 显示栈(Phase-D 详细设计)

> **⚠ 已归档(2026-10-10 放弃)**:所属移植方案已正式终止推进,本文转为只读档案。
> 终止决定与理由见 [`docs/changxing60/README.md`](README.md)。显示实验从未执行(设备需连回 adb)。
>
> **⚠⚠ 2026-10-13 追加:本文两条前提都已被实测推翻,Phase-D 的模块枚举计划作废。**
> - 「MU300 无显示硬件」**错**:面板/DSI/DPHY/背光/DPU0 全在本机 DT 里且 `status=okay`,
>   屏一直在被 LK 点亮(用户看到的就是 ZTE logo)。
> - 「5.4 无平台 suspend」**错**:与是否点屏无关,且已不影响推进。
>
> 实际交付走的是**另一条路**:外部编 `sprd-drm.ko`(DPU0+DSI 内部屏版)+ 电源域驱动,
> 用户态自绘状态页。**现行方案与进展见 [`screen-plan.md`](screen-plan.md)**,本文仅作历史设计稿。

> 关联:`docs/changxing60/port-design.md` §7 的 Phase-D 立项条(2026-10-08 上游重评条)。
> 本文是该立项条的技术展开。状态:**设计稿,未执行**(设备需连回 adb,当前纯 Android)。
> 依据:本地 `kernel/device.config` + 上游 changxing60-linux `origin/main`(v2026.10.10/11)原文。
> 日期:2026-10-08。

## 0. 目标与边界

**目标**:在 OpenWrt(原生 Linux)下点亮 7552N 内屏,显示状态界面(电量/信号/IP/负载),
替代"无可用 LED = 纯黑箱"现状(§7 重评结论:电量唯一入口是 LuCI 面板,需连热点开浏览器)。

**非目标**:
- 不追求完整 Android 应用生态(那是路线 A,受 `PID_NS/USER_NS` 缺失阻塞,见 §6)。
- 不追求 GPU 加速(状态屏 pixman 软渲染够;mali 用户态 blob 是 Android 专属,Linux 无开源驱动,
  panfrost 不支持 Unisoc 这颗)。
- 不在本阶段解决"持久运行形态"(见 §7,属阶段 2 独立决策)。

**成功定义**:
- 阶段 1(trial):dmesg 有 DPU/DSI/panel probe 成功 + `/dev/dri/card0` 存在 +
  connector status=connected + 背光可调 + 屏幕视觉亮起。回退干净(slot _a、misc 恢复)。
- 阶段 2(持久):OpenWrt 常驻 + labwc 状态屏常显示。形态待决。

## 1. 概念澄清:为什么"原生 Linux"不缺驱动

显示栈是分层的,Android 和 Linux **只在最上面那层分叉**,内核以下两家共用:

```
应用层       Android(ART/应用)          路线 B(Linux 应用/状态屏脚本)
compositor    SurfaceFlinger            labwc + pixman 软渲染
GPU 用户态    mali EGL blob              [缺] — 状态屏不需要
═══════════ 以下全是 Linux 内核,两家共用 ═══════════
DRM/KMS       DRM 框架(内核内建=y)       同一个内核
显示驱动       sprd-drm.ko 等(vendor)    同一个 .ko ← 复用
panel 时序     LK bootloader 已初始化     同(LK 开机点屏)
背光          BACKLIGHT_PWM.ko           同一个 .ko
```

**关键论点**:
- vendor 显示 .ko 本来就是 Linux 内核模块,不是"安卓驱动"。Android 的 init 加载它,
  Linux 的 modprobe 也能加载——同一内核 ABI。Phase-1 提取加载的 94 个模块全走此法,
  显示模块此前没被枚举只是因为 headless 路由不需要,**不是它不存在**。
- `kernel/build-display.sh` 已从 GPL 树编出过 `sprd-drm.ko`(含 DPU0/DSI),vermagic 已对齐
  ——证明可编可加载。
- Android 屏正常亮 = 显示 .ko 在 `/vendor/lib/modules`、开机被 init 加载。D1 第一步就是把它揪出来。
- 路线 B "原生 Linux" 指**用户态**用 labwc/Wayland 替代 SurfaceFlinger,不是"不用 vendor 内核驱动"。
- 真正"缺"的只有 GPU 用户态 blob——状态屏软渲染不需要。

**stock config 实测(`kernel/device.config`)**:

| 项 | 值 | 含义 |
|---|---|---|
| `CONFIG_DRM` / `DRM_MIPI_DSI` / `DRM_PANEL` / `DRM_KMS_HELPER` / `DRM_BRIDGE` | =y | DRM/KMS 框架内建 ✅ |
| `CONFIG_DRM_SPRD` | not set | Unisoc DRM 主驱动走外部模块(预期) |
| `CONFIG_DRM_SPRD_GSP_DVFS` | =y | GSP DVFS 在 |
| `CONFIG_FB` / `DRM_FBDEV_EMULATION` | not set | **无 fbdev,无 /dev/fb0,无 fbcon** |
| `CONFIG_BACKLIGHT_CLASS_DEVICE` / `BACKLIGHT_PWM` / `PWM_SPRD` | =y / =m / =m | 背光框架内建 + PWM 模块可提取 |
| `CONFIG_ZTE_LCD_BACKLIGHT_FADE_FROM_ODM` | =y | 中兴 ODM 背光渐变(供应商特化) |
| `CONFIG_TOUCHSCREEN_VENDOR_V2` / `TOUCHSCREEN_AXS` | =m / =y | 触控走 vendor 模块,AXS 内建(交互才需要) |

## 2. 回退安全设计(阶段 1)

阶段 1 全程在 trial sandbox 内,**回退 100% 有保证**(Phase-2 已验收 9 次干净回滚 0 砖):

```
试启镜像写 boot_b(塞显示模块)  ──►  misc trial 块(tries=2)
  │                                    │
  │ 不碰:boot_a / userdata / super /    │ 62s 内无成功标记 → 自动恢复 slot _a
  │      GPT / misc[0x800] BC 区         │
  │                                    │
  └─ 成功:观察 dmesg/sys/屏幕          300s rescue 超时 → 强制回滚 Android
     (rescue 已 restore_slot_a,        (LK 对启动失败 slot b 自动回滚 slot a)
      touch /run/stay 钉住会话)
```

- 写前:确认 `rescue/dumps/boot_b-ori` 原厂在(sha256 前缀 `7479f4ec…`,64MiB;Phase-3 已 dump)。
- 试启镜像 = trial-9 同一套(`build-boot-image.py` + misc trial 块 a=0xfe/b=0x2f),
  **仅 `module-order.txt` 末尾追加显示模块**,其余零改动。
- 回退路径:misc 62s 自动恢复 slot _a → Android 原样;或 300s rescue 超时强制重启。
- **零持久风险**:不引入 Phase-2 以外的新写分区。boot_a/userdata/super/GPT 全不碰。

阶段 2(持久运行)的风险另计,见 §7。

## 3. 显示栈选择

```
vendor 显示 .ko(DPU0/DSI/panel/backlight)
        │  modprobe(由 module-order 加载,initramfs 阶段)
        ▼
/dev/dri/card0  +  /sys/class/backlight/<dev>/
        │
        ▼
labwc(Wayland compositor, pixman 软渲染, LIBSEAT_BACKEND=noop)
   ├─ waybar(状态栏:电量/信号/IP/负载/CPU)
   └─ foot(终端,按需)
        │
        ▼
内屏 panel(connector DSI-1, status=connected)
```

复用上游 `tools/display/` 配方(README + setup.sh + changxing60-display-load),改造点:
- 上游是 USB-C DP 外接屏(connector `DP-1`),改成内屏 panel connector(预计 `DSI-1`,D3 实测确认)。
- 上游 `changxing60-dp-enable.ko` 把 DPU0/DSI disabled(因 F50 无 panel)——**内屏不需要此模块,删掉**。
- 上游加载序 `unisoc-iommu → changxing60-dp-enable → sc27xx_pd → sprd_typec_displayport → sprd-drm`
  ——内屏版精简为 `unisoc-iommu → sprd-drm → panel/backlight 模块`(D1 枚举后定)。

### 3.1 对 Phase-D 立项条的硬修正:无 fbdev,必须 DRM/KMS 原生

`docs/changxing60/port-design.md` §7 Phase-D 立项条 D3 写的是"看 `/dev/fb0`,`fbcon 或最小渲染器上状态屏`"
——**不成立**:
- stock `# CONFIG_FB is not set` 且 `# CONFIG_DRM_FBDEV_EMULATION is not set`
  → **不会出 /dev/fb0,也没有 fbcon**。
- 不能用 fbdev 路径(fbcon / 直接 mmap fb0 画)。

**修正**:必须走 DRM/KMS 原生——`/dev/dri/card0` + KMS atomic commit + 用户态 compositor。
这反而和上游 `tools/display/` 的 labwc 配方同路(README 原文 "5.4 kernel has no VT, runs with
`LIBSEAT_BACKEND=noop` and the pixman renderer"),内屏 panel 通后直接继承,不用自造 fbdev。

**好处**:labwc 是上游已验证到 DRM 侧的配方(`/dev/dri/card0` + connector `DP-1` 已通,仅 PD 契约失败);
内屏换 connector 名即可,跳过上游卡住的 USB-PD 环节。

## 4. 耗电预算(架构推算,非实测)

**无实测**:项目级与上游 FINDINGS §37(行 2782)均无功耗数字。下表是基于 config + 架构的量级估算。

亮屏常驻功耗拆解:

| 部件 | 量级 | 说明 |
|---|---|---|
| 背光(半亮) | 0.8–1.5W | 最大头,PWM 可调;全亮 2–3W |
| DPU/DSI 持续 60Hz 刷新 | 0.3–0.6W | 显示控制器 + MIPI DSI 常开;vendor,未实测 |
| 系统基线(不 suspend) | 0.5–1.2W | 5.4 vendor 无 platform suspend 驱动(上游 FINDINGS §37 行 2670);CPU WFI idle 但 DDR/modem/WiFi 活;比 Android 待机高 1–2 个数量级 |
| compositor/状态屏渲染 | 0.05–0.2W | 静态屏几乎 0;waybar 每秒刷新周期唤醒 CPU |
| **合计** | **~1.7–3.5W** | 背光 + 不-suspend 基线占 ~80% |

对比基准:

| 形态 | 估算 | |
|---|---|---|
| 路线 B 常亮屏 | ~1.7–3.5W | 本方案 |
| Android 亮屏使用 | ~1.5–4W | 同量级,路线 B 略省(无 SurfaceFlinger/GPU/ART) |
| 纯路由 headless | ~0.5–1.5W | 去掉背光 + 显示子系统 |
| Android 熄屏待机 | ~0.05–0.15W | 路线 B 降不到(5.4 不 suspend) |

续航(假设 4000mAh ≈ 15Wh,量级用):常亮屏 ~4–9h、纯路由 ~10–30h。

**判断**:
- 亮屏场景下,路线 B 不比 Android 亮屏费电,甚至略省(无重负载用户态)。
- 但"常亮"意味着永远停亮屏档,没有 Android 待机 suspend 的低谷回血(5.4 路径无 suspend 档)。
- 上游 mainline 6.18 suspend 进展(PR#57)对**亮屏**无用(亮屏本就醒着),只对熄屏省电有用
  ——且与"常亮状态屏"初衷矛盾。
- **调控杠杆**:背光 `brightness` 设低(max 的 20–30%),整机腰斩到 ~1–1.5W。状态屏纯文字,
  低亮度够用。这是路线 B 相比 Android 亮屏(自动亮度拉高)的特有优势。

**结论**:插电用(现有热点/汽水挂机/NetProxy 场景全插电)→ ~2–3W 不是 blocker。靠电池 →
常亮屏不理想,别这么用。

## 5. 分步设计

### D1 枚举(设备连回 adb 后第一步,~10min)

```sh
# Windows 侧 adb(铁律:只用 /mnt/c/platform-tools/adb.exe,别动系统 PATH)
ADB=/mnt/c/platform-tools/adb.exe
# stock config 已确认 # CONFIG_DRM_SPRD is not set → 显示驱动是外部模块,在 /vendor/lib/modules
$ADB shell su -c 'ls -la /vendor/lib/modules | grep -iE "dpu|dsi|panel|disp|backlight|sprd_drm"'
$ADB shell su -c 'lsmod | grep -iE "dpu|dsi|panel|disp|drm|backlight"'
# 期望产物:一组 .ko 名(如 sprd-drm.ko / sprd_dpu.ko / panel-*.ko / backlight-pwm.ko 等)
# 若 vendor 无独立 panel .ko → 走 D4 兜底(build-display.sh 从 GPL 树编)
```

### D2 提取 + 依赖分析(宿主,~30min)

```sh
# 提取(cp + adb pull 铁律:禁 exec-out,WSL interop 会坏二进制;见 §7 trial A5)
ADB=/mnt/c/platform-tools/adb.exe
mkdir -p rescue/dumps/display-modules
for ko in <D1 列出的 .ko 名>; do
  $ADB shell su -c "cp /vendor/lib/modules/$ko /data/local/tmp/"
  $ADB pull /data/local/tmp/$ko rescue/dumps/display-modules/
done

# 依赖分析:readelf -r 引用 ∩ nm -u,精确匹配 Module.symvers 第2列
# 禁用 grep -F 子串匹配(trial-2/3 血泪:会造假依赖,见 §7 trial-3 "依赖分析铁律")
readelf -r <X>.ko | awk '{print $5}' | sort -u  > refs.txt
nm -u <X>.ko > undef.txt
# 真依赖 = refs ∩ undef,再对 out-linux/Module.symvers 精确匹配第2列符号名

# 追加 module-order.txt:默认插入点 = sprd_pmic_wdt.ko 之后(末尾)
# 理由:显示依赖 regulator/clk/i2c/pinctrl,这些都在 module-order 前段已加载
# 若 D2 发现显示依赖某后加载模块,再前移插入点
```

### D3 trial 试启(宿主重建镜像 + 设备刷写 + 观察,~20min)

```sh
# 重建试启镜像:trial-9 同一套,仅 module-order.txt 末尾多了显示模块
# 具体参数见 boot/build-boot-image.py(--help);沿 trial-9 配置:
#   --stock-boot rescue/dumps/boot_ori.img,读 module-order.txt,misc trial 块 tries=2(a=0xfe/b=0x2f)
cd changxing60-linux/boot
./build-boot-image.py    # 产物 boot_display_trial.img,记录新 sha 前缀
./flash-trial.sh boot_display_trial.img    # 写 boot_b,带哈希校验
```

**观察 checklist(双通道)**:

| 通道 | 命令 | 判据 |
|---|---|---|
| USB 网络(telnet 192.168.77.1) | `dmesg \| grep -iE "dpu\|dsi\|panel\|sprd.*drm\|backlight\|mipi_dsi"` | probe 成功(`returned 1`),无 defer |
| USB 网络 | `ls -la /dev/dri/` | card0 存在(+renderD128) |
| USB 网络 | `cat /sys/class/drm/card0-*/status` | 某 connector = connected |
| USB 网络 | `ls /sys/class/backlight/` + `cat .../max_brightness` | 背光节点存在 |
| ttyGS0 串口(COM15) | rescue 路径 respawn 循环(trial-7 加的) | 控制台可达 |
| **视觉** | 手机屏幕直接看 | 亮起(首次可能花屏/闪屏,不阻塞"能显示"结论) |

**成功判据**:dmesg 有 `sprd_drm`/DPU probe 成功 + `/dev/dri/card0` 存在 + connector
status=connected + 背光节点存在 + **屏幕视觉亮起**。回退干净(misc 自动恢复 slot _a,
`getprop ro.boot.slot_suffix` = `_a`)。

### D4 compositor 接入(D3 出 card0 后,~1 天)

```sh
# 取上游 tools/display/ 配方,改造成内屏版
# setup.sh 改:connector DP-1 → DSI-1;删 changxing60-dp-enable.ko
# labwc autostart 改:waybar 状态栏脚本

# 状态屏数据源:
#   电量 = /sys/class/power_supply/battery/capacity + voltage_now(充电链 trial-3 已通)
#   信号 = modem AT? 或 ubus call network(OpenWrt)
#   IP   = ip -4 addr show usb0 / wlan0
#   负载 = /proc/loadavg

# 背光默认值(开机点亮,防 brightness=0 黑屏)
max=$(cat /sys/class/backlight/*/max_brightness)
echo $((max/4)) > /sys/class/backlight/*/brightness    # 25% 亮度,省电够看
```

### D5 持久化(阶段 2,形态待决,见 §7)

## 6. 为什么不走路线 A(嵌套完整 Android)

stock config 实测(`kernel/device.config`):
- ✅ `CONFIG_ANDROID` / `BINDER_IPC` / `BINDERFS` / `BINDER_DEVICES="binder,hwbinder,vndbinder"`
  —— binder 全套(Android 核心 IPC 在内核,含 binderfs)
- ✅ `CONFIG_ASHMEM` / `MEMFD_CREATE` / `CGROUPS`
- ✅ `CONFIG_NAMESPACES` / `NET_NS` / `UTS_NS`
- ❌ **`# CONFIG_PID_NS is not set`** / **`# CONFIG_USER_NS is not set`**

Waydroid 走 LXC,硬依赖 `PID_NS`(进程隔离)+ `USER_NS`(uid 映射)。这俩缺失是
2026-09-20 终局"架构天花板"的精确根因(彼时记 NET_NS 也未开,实测 NET_NS=y 已开,但 PID_NS 确缺)。

要翻墙:fragment 加 `CONFIG_PID_NS=y` + `CONFIG_USER_NS=y` 重编内核(~120s 增量,
trial-5 加 gadget 函数先例),但 `USER_NS` 在 vendor 内核常被安全策略硬禁需实测;
且 Waydroid 对 5.4 vendor 内核还有 seccomp/dev 节点/hwc 代理等未知坑。

**判定**:路线 A 不是开箱可行,是"重编内核补两个 namespace 后可能可行",工程量与风险远高于
路线 B,且与"维持现状"决策冲突。路线 B 的内核层零改动(只加显示模块),是更小更可控的第一步。

## 7. 阶段 2 持久形态待决

trial 只能验、不能常驻(300s 必回滚)。要"常亮屏当状态屏"需持久运行 OpenWrt,形态选项:

| 形态 | 代价 | 状态 |
|---|---|---|
| changxing60root 分区(GPT 缩容) | 需 wipe /data,用户已否决(09-20) | ❌ |
| chroot 容器 | E35(umount 静默失败删光宿主 /dev)+ E36(重启卡 boot),根因未诊 | ❌(未解) |
| 新形态(待探索) | ? | ? |

**changxing60root 分区为何 ❌——缩容与恢复出厂是绑定的**:GPT 缩容(userdata 110G→64G)本身
不删数据、不触发恢复出厂;但缩容后分区表=64G 而 f2fs 仍=110G 布局,该不一致态无法正常
挂载 /data。port-design.md §3.4/§3.7 门 2 因此把缩容与 recovery 手动 wipe 绑定执行
("不停留,避免任何时刻以普通方式重启进 GPT=64G/f2fs=110G 不一致态"),由 recovery 重建
f2fs + FBE 密钥。即**走分区路线 ⇒ 必然伴随一次恢复出厂**(清 /data 全部:sdcard/app/
模块数据;不清 system/vendor 只读 EROFS;boot_a 的 KPatch 不受影响,wipe 后 APK 装回前
su 已可用,§3.7 步 9)。fstab formattable 自动格式化路径存在,但 metadata-encryption +
checkpoint 时序不确定,只作 recovery 不可达时的备胎。这正是 09-20 否决该路线的核心代价,
也是阶段 1(trial 试启:只写 boot_b+misc,不碰 GPT/userdata)特意绕开它的原因。

**这是路线 B 的真正难点,但它是"怎么常驻"的问题,不是"怎么显示"的问题
——和阶段 1 显示通路验证正交。** 建议:阶段 1 跑通后,再据实测基线
(耗电/dmesg 稳定性)决定是否值得攻阶段 2。

## 8. 风险矩阵

| 风险 | 等级 | 缓解 |
|---|---|---|
| 显示模块拖未知依赖链 | 中 | 方法论已验证(trial-3/4 充电链);readelf+Module.symvers |
| panel 驱动缺失(vendor 无对应 panel .ko) | 低中 | build-display.sh 配方从 GPL 树编 DPU0+DSI;再不行从 vendor dtsi 抄 panel init 序列 |
| 点亮但花屏/闪屏 | 中 | 不阻塞"能显示"结论;D4 调 init 序列 |
| 显示驱动与 Android 服务隐性耦合 | 低 | fbdev 路径自包含;无 fbdev 走 DRM/KMS 更干净 |
| 背光默认 0 黑屏 | 中 | D4 开机脚本 echo brightness(防黑屏);D3 先查 max_brightness |
| 阶段 2 持久形态未定 | 高 | 阶段 1 先验,正交决策;不阻塞"能显示"结论 |
| 耗电高于预期(基线漂) | 低中 | D3 实测基线;背光低亮度杠杆 |

## 9. 试启执行计划(D1-D3 trial)

**前置条件**:
- 设备连回 adb(Windows 侧 `/mnt/c/platform-tools/adb.exe`),slot _a,Android 正常
- `rescue/dumps/` 有 boot_ori.img + boot_b 原厂(sha 7479f4ec)
- `changxing60-linux@7552n-port` 分支 trial-9 状态(init a93b3fc / 镜像 c588bec4)
- `rescue/tools/trial-net/` 观察工具齐(observe-trial.sh / telnet-cmd.py)

**步骤**:
1. **D1 枚举**(adb,~10min):ls /vendor/lib/modules grep 显示相关 + lsmod,记录 .ko 名清单
2. **D2 提取 + 依赖**(宿主,~30min):cp+pull → readelf/nm 依赖分析 → module-order.txt
   末尾追加(sprd_pmic_wdt.ko 之后)
3. **D3 重建镜像 + 刷写**(宿主+设备,~15min):build-boot-image.py(trial 块 a=0xfe/b=0x2f)
   → flash-trial.sh
4. **观察**(设备启动后,~5min 内判定):双通道 checklist(dmesg/sys + 视觉)
5. **回退确认**(misc 62s 或 300s):`getprop ro.boot.slot_suffix` = `_a` = 干净回滚

**回退铁律**:任一步异常,不干预 misc 自动恢复;rescue 路径已 `restore_slot_a` +
`touch /run/stay` 可钉住会话观察,停留安全。

**产物**:
- `rescue/dumps/display-modules/` 显示 .ko 集
- `work/logs-display-trial/` dmesg + sys 快照 + 视觉记录
- `module-order.txt` 显示段(若成功,合入 7552n-port 分支)
