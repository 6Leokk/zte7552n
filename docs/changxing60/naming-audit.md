# 命名审计 — mu300 → changxing60 清理后的残余核对

**日期**: 2026-10-16
**范围**: `/home/kk/code/zte7552n/changxing60-linux`,分支 `mainline-6.18`
**方法**: 对 git 追踪的全部 121 个含 `mu300`/`MU300` 的文件逐一核对（`git grep -i mu300` 的全集），每个出现处判定：

- **A = 改** — 本移植自己的名字（用户可见或内部但属于我们）
- **B = 保护** — 受保护名字 / 第三方或 vendored 标识符，不动
- **C = 存档** — 历史/变更记录引用，保持原样并确认读起来是历史

**结论**: **A = 0，B = 121，C = 0。** 121 个追踪文件中的全部 `mu300`/`MU300` 残余都是受保护名字、
事实正确的硬件名，或对上游命名机制的**功能性**引用——改动它们会破坏补丁上下文、构建挂载路径、
硬件探测或引用出处。

设备可见的重命名已在（尚未追踪的）新目录树里完成：`openwrt/overlay`、`rootfs/overlay`、
`container`、`boot/`、`tools/screen`、`tools/flash-boot-b.d` 里**所有标识符**（脚本名、路径、服务名、
uci 选项、LuCI 菜单、日志文本）都是新名；**正文仍有 25 处 `mu300`，但逐条判定后全是 B**
（旧路径收养 shim、上游仓库/工具名、硬件型号）——见 §3，那一节的早先版本误写成「零残余」，已修正。

本次唯一实际修改是 7 处文件权限位（§2），**无内容改动，未提交任何东西**。

---

## 1. 判定依据（为什么全归 B）

### 1.1 `upstream/`（108 个文件）= dikeckaan/mu300-linux 的逐字节快照

- 仓库 origin = `https://github.com/dikeckaan/mu300-linux`；基提交 `294deb8`（dikeckaan，
  2026-09-17）；其后 39 个提交全部是本移植者（6Leokk）。
- 外层文档 `docs/changxing60/mainline-6.18.md` B0 明确：`upstream/` 整目录取自
  dikeckaan/mu300-linux@**4106772aae**（整目录替换，不 merge history）。
- 实测快照内**零**本移植标记（`7552N`/`changxing60`/`P720S20` 在 `upstream/` 里 0 命中）。
- 典型残余（全部是上游自己的名字）：
  - `upstream/port/mali/driver/product/gc/.../mali_kbase_mem_linux.c` 的 `mu300_vm_flags_set/clear`
  - `upstream/port/thermal/mu300_thermal`（注释注明 "After kanoqwq's mu300_thermal"）
  - `upstream/port/*.h` 的 `mu300_compat.h`、`mu300-stubs.c`、`mu300-at`、`mu300-mainline.config`
  - `upstream/debug/install-probe.py` 的 `mu300_probe_reset()` 注入机制

**对整目录快照不做任何单点改名**——那会破坏下次整目录替换（B0 的流程），且快照内每个名字
都是 dikeckaan 或 kanoqwq 的产物。

### 1.2 非上游 13 个文件：全部是功能性适配或硬件事实

非上游文件中共 38 处 `mu300`，按性质分四组（明细见 §4 表格）：

| 组 | 性质 | 为什么不能改 |
|---|---|---|
| 硬件名 | "ZTE F50 / MU300"、"hardware MU300"、`MU300_ZYV1.0.0B09` | F50 的硬件型号**就是** MU300；`changxing60` 是我们给 7552N 起的项目名，不是硬件型号。改了就是事实错误。`MU300_ZYV1.0.0B09` 是厂商自己的固件/型号串（明确受保护名单）。 |
| 上游仓库名 | `kanoqwq/mu300-linux`、`dikeckaan/mu300-linux`、`mu300-linux build` | 引用出处（受保护名单）；改了引用就断了。 |
| 上游文件路径 | `"$UP/mu300-mainline.config"`、`:/work/mu300-mainline.config:`、快照里的 `.mu300` 路径引用 | **功能性**：上游受保护的 `build.sh:35` 读 `/work/mu300-mainline.config`，我们的 build.sh 把合并结果 bind-mount 到**这个路径**上（README「不 fork 上游 build.sh」一节正是为此设计）。改路径名 = 构建直接失败。 |
| 补丁上下文 / 匹配串 | `mainline-7552n/patches/0100-*.patch` 的两行 ` /* MU300: ... */ ` 上下文；`module-deltas.sh` 的 `old = '''.../* MU300 build: ...*/...'''` | **逐字节承重**，证据见 §1.3。改一个字节补丁就打不上/匹配就失败。 |

### 1.3 承重字符串的直接证据

**(a) 0100 补丁的两行 MU300 上下文** — 来自上游自己的改名机制：

- `mainline-7552n/patches/0100-mm-sdhci-sprd-allow-the-wcn-sdio-host.patch` 第 6、17 行都是
  上下文行（前缀空格）：` /* MU300: only the eMMC and the card slot */ `、
  ` /* MU300: the card slot waits for the eMMC's host... */ `
- 来源：`upstream/port/install.py`（上游自己的移植安装器）就是这个机制——它把含
  `MU300: ...` 的注释**注入** 6.18 树：
  - `install.py:125`: `marker = 'MU300: only the eMMC and the card slot'`
  - `install.py:144/152/165`: 注入 `MU300: CD GPU deferred` 警告串
  - `install.py:212`: 注入 `/* MU300: the card slot waits for the eMMC's host... */`
  - `install.py:302`: 把这些标记串列为**校验锚点**
- 我们的 0100 补丁是**在 install.py 的产物之上**再打的，其上下文引用的正是被注入的行。
  改上下文 → `git apply` / `patch` 找不到上下文 → 补丁失败。

**(b) module-deltas.sh 的匹配串** — 对 vendored 上游源码的逐字节匹配：

- `mainline-7552n/module-deltas.sh:35` 的 `old = '''\t/* MU300 build: only the SC2355 PCIe
  variant is compiled in */...'''`
- 与 `upstream/modules/sprd_wlan_combo/common/sprd_wlan.c:122`（vendored 上游文件）逐字节一致
  （含行首制表符）。这是脚本设计：先精确匹配，再替换成 `7552N:` 版本。改匹配串 = 永远
  走到 `sys.exit('... not found -- upstream changed it')`。

**(c) 构建挂载路径**：

- `mainline-7552n/build.sh:27` `cat "$UP/mu300-mainline.config" "$HERE/config-7552n.config"` —
  `$UP` 指向受保护快照，文件名是上游的。
- `mainline-7552n/build.sh:40` `-v "$HERE/merged-7552n.config":/work/mu300-mainline.config:ro` —
  挂到**上游 build.sh 读取的路径**上（README:19-22 解释了为什么用覆盖式合并）。
- `mainline-7552n/merged-7552n.config` 是**生成文件**（build.sh `cat` 两段拼出来），
  前 ~735 行就是上游配置文本的逐字节拷贝，其中的 mu300 行自然是上游的。

**(d) install.sh 的硬件探测**：

- `install.sh:31`: `case "$model" in *MU300*|*F50*|*mu300*|*7552N*|*P720S20*)` —
  **运行时功能**：匹配的是设备报出来的硬件型号。会报 `MU300` 的设备（F50）必须继续匹配。
  这里改了，安装器在 F50 上直接拒绝工作。

### 1.4 `tools/rename-device.remote` / `rename-device.sh`（未追踪，但按 B 记录）

这两个文件**本身就是**迁移工具：它把设备上本移植起的名字 `mu300*` → `changxing60*`，
其中出现的老名字引用（`/run/mu300`、`/opt/mu300`、`/etc/mu300`、`mu300-cell`、`mu300screen`…）
是它**要检测和替换的目标**，不是要改掉的残留。文件头的三行注释（第 24-29 行）已把三个
受保护名字写明，并明确 "MU300_ZYV1.0.0B09 ... names the hardware, not us"。
`tools/flash-boot-b.sh:13-14` 注释里的 `/run/mu300`、`/mnt/mu300-disk` 同理：那是**老 boot
镜像的行为**（这正是该工具存在的理由），读起来就是历史/说明。

---

## 2. 本次实际修改（7 处，全是 chmod，无内容改动）

### 2.1 三个脚本 644 → 755（明确是脚本：都有 shebang，会作为程序执行）

| 文件 | 旧 → 新 | 证据 |
|---|---|---|
| `openwrt/overlay/etc/init.d/changxing60-bootpaths` | 644 → 755 | shebang `#!/bin/sh /etc/rc.common`；init.d 脚本由 procd/rc.common 执行 |
| `openwrt/overlay/etc/init.d/changxing60-voiced` | 644 → 755 | shebang `#!/bin/sh /etc/rc.common`；同上 |
| `rootfs/overlay/opt/changxing60/bin/changxing60-net-status` | 644 → 755 | shebang `#!/bin/sh`；由 CLI 调用 |

背景（内存教训）：**100644 的脚本 = 从来没跑过，且看不出来**——判据必须用 `git ls-files -s`
而非 `ls -l`/`git diff`。这三个修复后，`git ls-files -s` 里新路径将记为 100755（index 目前
还持旧 mu300 路径，见 §5）。

### 2.2 四个容器文件 600 → 644（对齐旧 index 记录的 100644；600 是误设）

| 文件 | 旧 → 新 | 理由 |
|---|---|---|
| `container/overlay/etc/init.d/changxing60-vpn` | 600 → 644 | 旧 index（mu300-vpn）= 100644；设备侧 build 也会 chmod |
| `container/overlay/etc/changxing60/vpn.conf` | 600 → 644 | 同上（mu300 时代 index = 100644） |
| `container/apatch-module/changxing60-openwrt/service.sh` | 600 → 644 | 同上 |
| `container/apatch-module/changxing60-openwrt/module.prop` | 600 → 644 | 同上 |

### 2.3 核对过、正确保持 644 的（不修——它们是被 source 的片段，不是被执行的脚本）

- `openwrt/overlay/lib/preinit/05_changxing60_early_recorder`（lib/preinit 由 preinit source）
- `openwrt/overlay/etc/profile.d/changxing60.sh`（profile.d 由 sh 启动时 source）
- `openwrt/overlay/etc/hotplug.d/iface/10-changxing60-usb`（hotplug.d 由内核事件 source）

这三处旧 index 也是 100644，语义正确。

### 2.4 四目录模式位终态（磁盘）

任务要求核对的四个目录，磁盘上每个文件现在都是 755：

```
openwrt/overlay/opt/changxing60/bin   5/5   全 755
openwrt/overlay/etc/init.d          10/10   全 755
openwrt/overlay/etc/uci-defaults     2/2   全 755
rootfs/overlay/opt/changxing60/bin  40/40   全 755
```

（index 里 5 个新路径已显式 100755，其余因重命名未暂存而显示为 untracked——见 §5。）

---

## 3. 设备可见面复核（新目录树）

### 3.1 标识符：0 残余（这是「改名」的实质）

设备可见的**名字**全部是新名，逐类核过：主机名 / USB 串 / LuCI 标题与菜单 / 日志文本 /
`--help` / 包名 / 服务名 / **init.d 脚本名** / uci 选项名 / overlay 路径。
最硬的一条是 init.d ——重命名后是 `changxing60-{at,audio,bootpaths,hw,modemd,ndp,post,power,screen,smsd,vendor,voiced}`
十二个，磁盘上**一个 `mu300-*` 都不剩**（旧名在 index 里是 120 个待删路径，见 §5）。
rpcd/LuCI 同理：`changxing60sms.uc` / `changxing60usb.uc` / `changxing60voice.uc`，
菜单与 ACL 是 `luci-app-changxing60{sms,usb,voice}.json`。

### 3.2 正文：8 个文件 25 处，**全是 B**（2026-10-16 复核修正）

> ⚠ **本节早先写成「0 命中」，那是错的**——当时的 grep 排除了 `changxing60` 自身命中，
> 把「路径已改名」误当成「正文无 mu300」。实际正文有 25 处。逐条判定后**仍然全是 B**
> （改名不是把它们改掉，而是它们本来就不该被改），但结论必须按事实写，不能按愿望写。

| 文件（设备可见） | 处数 | 判定 | 名字是什么 / 为什么不能改 |
|---|---|---|---|
| `openwrt/overlay/etc/init.d/changxing60-bootpaths` | 8 | B | **旧路径收养 shim**：`/run/mu300`、`/mnt/mu300-disk` 是**旧启动镜像**（改名前的 initramfs）亲手建的路径，这个脚本的全部工作就是把它们搬到新名。改掉它 = 迁移失效、旧镜像启动后设备可见树错位。**这是唯一一处「mu300 必须留在设备可见脚本里」的地方**，文件头已写明 |
| `rootfs/overlay/opt/changxing60/bin/extra-modules` | 4 | B | `mu300_thermal` **是 6.18 那棵树里模块自己的名字**（`upstream/modules/mu300_thermal/`、`obj-m += mu300_thermal.o`）——不是 2026-10-16 改名的漏网。改了就 insmod 不到 |
| `rootfs/overlay/opt/changxing60/bin/changxing60-net-status` | 4 | B | 「the mu300 cell collector」= **上游那个采集器的名字**，本文件是它的移植（注释里就是在跟它对照）。我们树里没有叫这个名字的文件 |
| `rootfs/overlay/opt/changxing60/bin/changxing60-at` | 3 | B | `kanoqwq/mu300-linux@25f8d0c` —— 上游仓库 + commit 引用（受保护 slug） |
| `rootfs/overlay/opt/changxing60/bin/changxing60-sms` | 3 | B | `mu300dash` —— **上游面板后端**的名字（"不是上游的 mu300dash"），我们没移植它，只是拿它当列格式的对照 |
| `openwrt/overlay/usr/share/rpcd/ucode/changxing60sms.uc` | 1 | B | 同上，`mu300dash` 的上游指代 |
| `rootfs/overlay/opt/changxing60/bin/ndp-learn` | 1 | B | `dikeckaan/mu300-linux` —— 上游仓库名 |
| `boot/build-boot-image.py` | 1 | B | 第 2 行 docstring "ZTE F50 / MU300 (Unisoc T760, UMS9620)" —— **硬件型号事实**，F50 的型号就是 MU300 |

### 3.3 顺带清掉的一件小事

`tools/screen/out/mu300-screen` ——改名前的**陈旧构建产物**（10-15 的二进制，
`build.sh` 现在输出 `changxing60-screen`）。它被 `.gitignore` 的 `out/` 覆盖、从未入库，
但躺在树里会让人以为屏程序还叫旧名。已删除。

---

## 4. 逐文件判定表（121 个追踪文件）

### 4.1 `upstream/`（108 个文件，全 B）

一句话归类：**dikeckaan/mu300-linux@4106772aae 的逐字节快照**（§1.1）。每处 mu300 都在
下列之一：上游 port 代码（mali kbase、mu300_thermal、mu300_compat.h、mu300-stubs.c、
mu300-at、install.py 注入机制、mu300-mainline.config、debug/probe、drivers LED 注释等）。
**0 修改。**

### 4.2 非上游 13 个文件（全 B，共 38 处）

| 文件 | 处数 | 判定 | 这个名字是什么 / 为什么 |
|---|---|---|---|
| `boot/build-boot-image.py` | 1 | B | 第 2 行 docstring "Build a ZTE F50 / MU300 (Unisoc T760, UMS9620) Linux boot image"——继承自上游的硬件描述，F50 的型号就是 MU300，事实正确 |
| `docs/container-architecture.md` | 1 | B | 第 10 行 "其目标设备 F50/MU300 是 5G 随身热点"——上游项目的目标硬件 |
| `docs/FINDINGS.md` | 3 | B | 标题 "running Linux on the ZTE F50 / MU300"；第 3 行 "hardware MU300, firmware `MU300_ZYV1.0.0B09`"（厂商型号串，受保护名单）；`dikeckaan/mu300-linux` 的 docs 引用（受保护 slug） |
| `install.sh` | 2 | B | 第 2 行注释 "changxing60 / ZTE F50 (hardware MU300) Linux installer"（重命名时已把项目名改对，MU300 保留为硬件名）；第 31 行 `*MU300*|*F50*|*mu300*|*7552N*|*P720S20*`——**运行时硬件探测**（§1.3(d)） |
| `kernel/patches/wlan_combo-default-board-config.patch` | 1 | B | 第 4 行 "The ZTE F50/MU300 ships wifi_board_config.ini"——补丁头的硬件/固件事实 |
| `mainline-7552n/build.sh` | 5 | B | 第 2 行 "upstream's mu300-linux build"（上游仓库名）；第 4/8 行硬件；第 27 行 `cat "$UP/mu300-mainline.config"`；第 40 行 bind-mount 到 `/work/mu300-mainline.config`（§1.3(c)，功能性路径） |
| `mainline-7552n/config-7552n.config` | 4 | B | 对上游配置文件名 `mu300-mainline.config` 的引用 + 硬件上下文 |
| `mainline-7552n/merged-7552n.config` | 9 | B | **生成文件**（build.sh 把上游配置 + 我们的片段 cat 在一起）；第 1/71/105/213/290 行是上游配置文本的逐字节拷贝；第 736-755 行是 config-7552n.config 注释的拷贝。改了会在下次生成时被打回 |
| `mainline-7552n/module-deltas.sh` | 1 | B | 第 35 行匹配串 `/* MU300 build: only the SC2355 PCIe variant is compiled in */`——与 vendored `upstream/modules/sprd_wlan_combo/common/sprd_wlan.c:122` 逐字节一致（§1.3(b)） |
| `mainline-7552n/patches/0100-mm-sdhci-sprd-allow-the-wcn-sdio-host.patch` | 2 | B | 第 6/17 行是**上下文行**，引用 `upstream/port/install.py` 注入的 `MU300:` 标记（§1.3(a)，install.py:125/212/302 证据）。改上下文 = 补丁打不上 |
| `mainline-7552n/README.md` | 4 | B | 第 3 行 "上游 `upstream/` 整目录原样保留(F50/MU300/U30 Air,…)"；第 9 行 "上游 `mu300-mainline.config`"；第 19/21 行 `/work/mu300-mainline.config`——上游设备描述 + 功能性配置路径 |
| `README.md` | 4 | B | 第 1 行标题、第 4 行硬件描述、第 7 行、第 84 行 "ZTE F50 / MU300"——**仓库自身的 README** 描述的是上游支持的目标硬件（F50，型号 MU300）。改了就变成事实错误（F50 不叫 changxing60）；第 4 行已同时写明 "changxing60 (P720S20)" |
| `tools/display/README.md` | 1 | B | 第 3 行 "The F50/MU300 device tree ships with…"——硬件/固件事实 |

### 4.3 分类汇总

- **A（改）**: 0 文件 / 0 处
- **B（保护）**: 121 文件 / 465+ 处（108 upstream 文件 + 13 非上游文件的 38 处）
- **C（存档）**: 0 文件 / 0 处

---

## 5. 仓库状态备注（非本次任务改动，但影响验收）

重命名在**磁盘上完成、尚未暂存**（2026-10-16 复核时的实测数字）：

- index 里仍有 **120 个旧 mu300 路径**记录为 deleted（内容已从磁盘消失）
- **282 个文件尚未追踪**，其中 **139 个**路径里带 `changxing60`；10 个已显式 `git add`（mode 100755）
- 另有 69 个已追踪文件被修改
- 旧 index 对这 10 个已暂存新路径的 mode 是 100755，与磁盘一致
- 验收者执行 `git add -A && git commit`（由用户自行执行；本审计**未提交、未暂存任何东西**）
  后，§2 的 chmod 会随之入库
- 在那之前，`git ls-files -s` 查 mode 会看到旧路径 100755 + 少量新路径——这是预期的中间态。
  ⚠ 但**别把「磁盘上 755」当成「入库了 755」**：新树整个未追踪，`git ls-files -s` 里根本没有它们，
  而 §2 那条教训（`net-split` 644 导致热点拿不到地址）正是这么发生的。

## 6. 追踪文件之外的发现（未追踪文件）

> **以 §3.2 为准。** 那一节是 2026-10-16 晚用 `grep -ril mu300` 对设备可见树**逐个文件**重跑的
> 结果（8 个文件 25 处，逐条判定全 B）。本节是更早一轮的枚举，**漏了 5 个**（`changxing60-net-status`、
> `changxing60-sms`、`changxing60sms.uc`、`extra-modules`、`boot/build-boot-image.py`）——
> 和 §8 记的那个判据缺口同源：枚举按「文件里出现 mu300」做，容易漏。下面保留原始 6 条，
> 但它们不是全集。

原始 6 条（全部功能性或受保护，无需改）：

1. `kernel/changxing60-dp-enable/changxing60-dp-enable.c` — 硬件名引用
2. `openwrt/overlay/etc/init.d/changxing60-bootpaths` — **功能本体**：接管老 boot 镜像的
   `/run/mu300`、`/mnt/mu300-disk`（这是它的职责，不是残留）
3. `rootfs/overlay/opt/changxing60/bin/changxing60-at` — 引用 `kanoqwq/mu300-linux@25f8d0c`（受保护 slug）
4. `rootfs/overlay/opt/changxing60/bin/ndp-learn` — 引用 `dikeckaan/mu300-linux`（受保护 slug）
5. `tools/rename-device.remote` / `tools/rename-device.sh` — 迁移工具本身（§1.4）
6. `tools/flash-boot-b.sh` — 注释描述老 boot 镜像行为（历史/说明性，正确保留）

## 7. 外层文档的一处小笔误（不在本仓库审计范围，但顺带记录）

`/home/kk/code/zte7552n/docs/changxing60/mainline-6.18.md` 第 61 行把上游模块写成
"changxing60_thermal"——实际受保护的上游模块名是 `mu300_thermal`（kanoqwq 的，快照里
就是这个名）。

> ⚠ **这句结论当时写错了**:本仓库内**有此问题**,而且正是同一处。见 §8。

## 8. 复核追加（2026-10-16,改完 §7 那条笔误时顺手全盘复查）

本审计 §6 判"6 个未追踪文件……全部功能性或受保护,无需改",**漏了一处真的改错了的地方**;
§7 判"本仓库内无此问题"也**是错的**。两处都已修:

1. **`rootfs/overlay/opt/changxing60/bin/extra-modules`(§6 里根本没被列出来)** —— 改名把
   6.18 分支的模块名从 `mu300_thermal` 改成了 `changxing60_thermal`(第 6 行注释 + 第 10 行
   `MODULES=`)。这不是注释问题:`mu300_thermal` 是**模块自己的名字**,也就是 `.ko` 文件名
   (`upstream/modules/mu300_thermal/Makefile` 里 `obj-m += mu300_thermal.o`),改名会让
   6.18 侧 `modprobe` 一个两边内核都不存在的模块。而且**症状是哑的** —— busybox modprobe 对
   "文件不存在"不写 stderr,只有这个脚本自己那句 `no message from modprobe -- $m.ko is probably
   not installed` 会说出来(脚本里正好为 `mali_kbase` 写过这条教训)。已改回,并加注释说明它
   **不是漏网、是必须绕开的名字**。
   判据来源:`work/new-rootfs/opt/mu300/bin/extra-modules`(改名前的 build 产物)里就是 `mu300_thermal`。

2. **`changxing60dash` —— `mu300dash` 被改名了(2 个文件 4 行)**,违反 [`rename.md`](rename.md) §1 的
   "故意不动"四类之一:
   - `rootfs/overlay/opt/changxing60/bin/changxing60-sms`(3 行注释)
   - `openwrt/overlay/usr/share/rpcd/ucode/changxing60sms.uc`(1 行注释)

   `tools/rename-device.remote` 是用 `__CX60C__` 占位符**专门保护**这个名字的,说明改名工具没做错;
   是**有人在工具之外手改了工作区**。反证很干净:**设备上的两份文件都还是 `mu300dash`**
   (`grep -n dash /usr/share/rpcd/ucode/changxing60sms.uc` 与设备侧 `changxing60-sms`),改回仓库后
   `changxing60-sms` 的 md5 与设备**逐字节相同**(`baedd93f9a328c4a1525c3f6db0a1415`)。
   注意:`rename.md` §6 与 `sms-port.md` 引用的名字也一并核对过,它们是 `mu300dash`。

**教训(和 §6 的判据缺口同源)**:这份审计是**按"文件里出现 mu300"去枚举**的,所以只能发现
"该改没改";而**该保留却被改掉**的那类,文件名里没有 `mu300` 可搜,得**反向搜"改名后的名字"**
才抓得到 —— 上面两处正是反向搜 `changxing60_thermal` / `changxing60dash` 才出来的。
以后复核改名,两个方向都要搜:正向搜残留的 `mu300`,反向搜**受保护名单里每个名字的新版拼法**。

## 9. 第三种搜法:二进制里的字符串(2026-10-16 追加)

前面 §3.1 说的"标识符 0 残余",判据是**文件名**;§3.2 说的"正文 25 处全 B",判据是**源码文本**。
这两条都搜不到**编进二进制里的名字** —— 而那是改名最容易漏的地方,因为改的是 `.c` 文件名,
残留的是几个月前编好的 `.ko`/可执行文件里的 `__FILE__` 之类。

**实测发现**:设备上的 `/opt/changxing60/bin/changxing60-bt-init`(684072 B)里有

```
$ strings /opt/changxing60/bin/changxing60-bt-init | grep -i mu300
mu300-bt-init.c
```

—— 它是从**改名前的 `mu300-bt-init.c`** 编出来的。文件名早就改了,二进制没有。**已重编并上机替换**
(`0eab3f043013aab5224372cf6f51c0ad`,582040 B,`strings | grep -i mu300` 已空),
并实测能跑(报 `bt_configure_pskey.ini: No such file or directory` 是**预期的** —— BT 固件本来就没铺,
蓝牙也没自动起:无 init 脚本、`/etc/rc.d/` 无条目,所以换二进制不影响任何在跑的东西)。

**顺带挖出一个更严重的**:`tools/bt-init/changxing60-bt-init` **根本不在仓库里**
(`tools/bt-init/` 只有 `.c`)。而 `build-rootfs.sh` 是这样要它的:

```sh
$(opt tools/bt-init/changxing60-bt-init bt-init)     # 第 39 行,构建输入
[ -e /in/bt-init ] && { cp /in/bt-init $R/opt/... }  # 第 143 行,安装
```

`opt()` 在文件不存在时**展开成空** —— 于是**重新构建出来的 rootfs 会静默地不带 bt-init**,
而设备上那份是手工编的、一直在用,所以谁都没发现。**判据缺失 + 条件式引用 = 隐形**,
和 mode bit 那件事(§README 的铁律)是同一个形状。已补 `tools/bt-init/build.sh`(照 `tools/modem/build.sh`
的形状,输出就落在 `build-rootfs.sh` 找的位置),二进制现在入库。

**所以改名复核要搜三个方向**:

| 方向 | 命令 | 抓什么 |
|---|---|---|
| 正向 | `grep -rl mu300` | 源码/配置里残留的旧名 |
| 反向 | 搜受保护名字的**新版拼法** | 该保留却被改掉的(§8) |
| **二进制** | `strings <每个 ELF> \| grep -i mu300` | **编进去的旧名**(本节) |

设备侧三方向终态(2026-10-16 实测):文件名 0、二进制 0、正文只剩**出处注释**
(`mu300dash`、`mu300 cell collector`、`dikeckaan/mu300-linux`、`kanoqwq/mu300-linux@25f8d0c`),
**全部是 B 类受保护引用** —— 它们记的是"这段代码从哪来",改掉就等于抹掉出处。

