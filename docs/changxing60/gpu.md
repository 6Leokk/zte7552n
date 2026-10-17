# 7552N:把 Mali-G57(kbase)在 5.4 上装回来

> 用户要求「尽可能从安卓那里移植驱动,让 gpu 什么的正常」。本文记的是**我们这一侧**为什么会缺
> `mali_kbase`、怎么把它编回来、以及**还没做的那一步**(上机验证)。
> 上游同款结论见 `changxing60-linux/docs/FINDINGS.md` §28 —— 与我们独立得出的根因逐条吻合,交叉印证。

## 0. 结论先行

- **`mali_kbase` 从来就没进过我们的 5.4 镜像**,不是加载失败、不是符号不匹配、不是 DTB 没使能。
  判据是**三份清单里都没有它**(§1),不是日志里那句 `FAILED mali_kbase` ——
  见 §1.1,那句日志**并不指向 mali**,把它当证据用会得出过强的结论。
- 现在**已编好并入库**(`out/modules/mali_kbase.ko`;模块集 `stage-modules.py` 报 110 个 10.9 MiB),`vermagic` 与设备内核一致。
- **2026-10-16 上机实测:内核侧三条全过**(§5)。设备上 `mali_kbase.ko` = `r40p0-01eac0`、
  `vermagic=5.4.254-gb50db5b6224c`、md5 `aa32a1cddf4c920da475c74a6d54eeb1`;`modprobe` 成功、
  `Probed as mali0`、`/dev/mali0` 在、devfreq 三档频率在。
- **唯一没做的仍是第 3 条(用户态)**,原因不是驱动而是**东西不在**:我们的 rootfs 没有 Mali UMD,
  而 vendor chroot 里当初只拷了 `modem_control` 需要的两个 so(`lib_crypto.so`、
  `libkernelbootcp.trusty.so`),**没有 `cltest`、没有 `libGLES_mali.so`** ⇒
  `android-gpu-run /system/bin/cltest` 现在**无物可跑**(§5.3 给了补齐它要拉什么)。

## 1. 症状与它骗了我们很久的地方

`extra-modules` 是「一项失败不算致命」的脚本(`rootfs/overlay/opt/changxing60/bin/extra-modules` 末尾 `true`),
失败**不拦启动**,而设备**照样起来、热点照样开、WAN 照样通** —— 一个 headless 路由器不需要 GPU,
于是没人回头看。用户提「让 gpu 正常」时才把它翻出来。

### 1.1 那份日志**不能**当 mali 的证据用(勘误)

`work/logs-pathc-1/linux-persist-legacy.txt` 第 726 行确实是 `FAILED mali_kbase:`,很容易顺手引用。
**但它不指向 mali**:同一段第 716~726 行里,**11 个模块全部 FAILED**——

```
716:FAILED sprd_soc_thm:
...
725:FAILED sprd_gpu_cooling:
726:FAILED mali_kbase:
```

那是 path A **第一次**起来时的日志,当时 **`extra-modules` 那整个集合一个都还没装**。它证明的是
"那一次 boot 模块集是空的",**不是**"后来 sprd_gpu_cooling 装上了、唯独 mali 缺失"。
(此后 9 轮 `logs-trial*` 都没有采到 `extra-modules` 的 stdout,所以**没有**一份日志能把 mali 单独摘出来。)

顺带一个真实但独立的小问题:这些失败行**冒号后面全是空的**,单看分不出"文件不在"和"内核拒收"
(`invalid module format` 那一类)—— 第一反应很容易被引去查 CRC / vermagic / DTB,而真因在最上游的
构建清单里。已顺手让 `extra-modules` 在 stderr 为空时明说 `x.ko is probably not installed`。

### 1.2 所以靠**清单**定性:三份互相独立的核对,缺一不可

| 核对面 | 结果 |
|---|---|
| 启动期加载集 `boot/module-order.txt`(**94** 项,非注释非空全算) | 无 mali |
| 部署集 `out/modules/`(stage 出来那 110 个的落点) | 无 mali(2026-10-15 之前) |
| rootfs 发行 tarball `openwrt/changxing60-openwrt-25.12.5-rootfs.tar.gz`(95 个 .ko) | 无 mali |

前两份今天可直接复看;第三份是**已经烧进设备的那一版 rootfs**(2026-10-14 00:31 构建),
所以它是"设备上真的没有"的硬证据,不是推测。

三处都没有 → 它不是"没加载",是**根本没被构建出来**。这也解释了为什么 DTB 那头的检查全是绿的:

```
gpu@23140000  status = "okay"、gpu-supply = <0x17f>、compatible = "sprd,mali-natt"   ✅
```

**供电链、时钟、DT 节点全对** —— 所以"查 DTB"这条线永远查不出问题,问题在我们的构建清单里。

## 2. 根因:两层,都是"清单"问题

### 2.1 厂商源码随 docker volume 一起丢了

`mali_kbase` 是**树外模块**,不在 `zte-u30air` 厂商内核树里,来源是 realme C51/C53 的 AndroidT
内核源码 `kernel_modules/kernel5.4/gpu/natt/mali`(DDK r40p0-01eac0)。它被塞在 docker volume
`changxing60-kernel` 的 `/src/ext-mali` 里 —— 而 volume 重建过一次,`/src/ext-mali` 就没了。
上游 README 交代的构建步骤是**纯人工的三个 `docker cp`**,没有任何脚本记录"这个目录必须存在",
所以丢失是**静默**的。

### 2.2 `stage-modules.py` 把 `mali_kbase` 当"可选"

这才是让上面那件事**无人察觉**的原因。`tools/stage-modules.py` 里有:

```python
OPTIONAL_ROOTS = ["zte_sar", "sprdbt_tty"]
```

`mali_kbase` 不在硬清单里 —— 意思是「编不出来就跳过,不算错」。于是 volume 一丢、模块一缺,
**staging 照常退出 0**,产出镜像照常能启动。一个**可选的必需模块**是自相矛盾的:
对 headless 路由器它是可选,对用户要的东西它是必需。

**已改**:`mali_kbase` 移入 `ROOTFS_ROOTS`(硬根),`OPTIONAL_ROOTS` 只剩 `zte_sar` / `sprdbt_tty`。
现在它编不出来,`stage-modules.py` 会打印
**`mali_kbase is requested by the rootfs scripts but was not built`** 并 **exit 1**,而不是安静地跳过
(删掉 `mali_kbase.ko` 跑一遍验证过,就是这个输出)。

## 3. 修法:一个可复跑的取源+构建脚本

`tools/build-mali-54.sh`(新增)把上面那段"人工 docker cp"固化成:

1. **sparse clone** `realme-kernel-opensource/realme_C51_C53_Narzo-N53-AndroidT-kernel-source`,
   **钉 commit `4381465ccaf87fcf3215b9cd42f4a685df40e5e0`**,sparse 路径只取 `kernel_modules/kernel5.4/gpu/natt/mali`;
   源码缓存到 `$HOME/.cache/mali-src`,重跑不重下(`--fetch` 强制重取)。
2. 拷进 volume `changxing60-kernel:/src/ext-mali`;
3. 在 `changxing60-kbuild-cross` 里跑 `kernel/build-mali.sh`(`-e CROSS_COMPILE=aarch64-linux-gnu-`);
4. 把 `mali_kbase.ko` 拷到 `$TOP/out-linux/`(即 `stage-modules.py --built` 的默认索引目录);
5. **核对 `WANT_VERMAGIC=5.4.254-gb50db5b6224c`** —— 对不上就直接失败,不产出。

### 为什么必须钉 commit / DDK 版本

DDK 版本必须**和服务端用户态严格同版**:Android 的 `libGLES_mali.so`(同时是 `libOpenCL.so` 与
Vulkan ICD)是 r40p0,给它 r34p0 的 kbase 它**拒收**。上游 FINDINGS §28 已经踩过这个坑
(「an older checkout of the tree has r34p0 (UK 11.31), which Android's r40p0 userspace would not accept」),
所以我们的版本核对是硬门禁,不是提示。

### 为什么不是"直接拿 stock 的 `mali_kbase.ko`"

stock 模块**加载不了**:它与本内核 335 个导入符号里有 **166 个 CRC 对不上**(FINDINGS §28 实测)。
原因是我们用的是**厂商 DTB + 厂商 config 编出来的自编内核**,不是 Android 那个内核,`modversions` 全变。
所以"从手机里抠一个 ko 出来"这条路是死的 —— 只有**对着我们自己的 `zte-u30air` 树重编**才行,
`kernel/build-mali.sh` 正是这么做的(`cd /src/zte-u30air` + `O=/src/out-linux`,vermagic 由此而来)。

## 4. 宿主侧已经查清的部分(标注了每条是实测还是读源码)

```
$ modinfo out/modules/mali_kbase.ko
license:   GPL
version:   r40p0-01eac0 (UK version 11.36)      <- 与 Android 用户态同版
softdep:   pre: memory_group_manager
import_ns: DMA_BUF
vermagic:  5.4.254-gb50db5b6224c SMP preempt mod_unload modversions aarch64   <- 与设备内核一致
depends:   sprd_gpu_cooling,trusty              <- 真依赖,两个都在 out/modules 里
alias:     of:N*T*Csprd,mali-natt
```

### 4.1 `memory_group_manager` 这条 softdep:判定无害(三条证据,一条是实测)

`modinfo` 里那条 `softdep: pre: memory_group_manager` 一开始像个**能毁掉整件事的坑**:这个模块
**我们和设备都没有**。查清了,是虚惊,三条独立证据:

1. **它是 `softdep`,不是 `depends`。** 真正的符号依赖在 `depends:` 那一行(只有 sprd_gpu_cooling / trusty)。
   `MODULE_SOFTDEP` 只是给 modprobe 的**提示**,内核自己完全不读它。
2. **它在这个配置下本就是死的。** 源码里那句写在 `mali_kbase_core_linux.c:6003`,
   而同一个 Kbuild 把 `mali_kbase_native_mgm.o` **编进了 `mali_kbase` 本体**
   —— 也就是走的是「内置 mgm」这条路,本该由 softdep 拉起的那个独立模块**根本不该存在**。
   树里也确实没有 `memory_group_manager.c`(realme 树和 ZTE 树都没有,只有 `.h`)。
3. **lab 实测 modprobe 会跳过它且不算失败。** 把 `out/modules/*.ko` 拷到一个临时 modules 目录、
   `depmod` 后干跑:

   ```
   $ modprobe -S 5.4.254-test -d /tmp/mdmod -n -v mali_kbase
   insmod .../trusty.ko
   insmod .../sprd_gpu_cooling.ko
   insmod .../mali_kbase.ko
   rc=0
   ```

   三个真依赖全部解析、`mali_kbase` 在计划里、**rc=0**,那条无解的 softdep 被静静丢掉。
   (真加载路径没能在 lab 里跑到底:WSL 里 `finit_module` 直接 `EPERM`。所以**上机时顺手看一眼**
   `dmesg | grep -i mali` 有没有 softdep 告警即可 —— 但即便有告警也不致命,softdep 的全部意义就是"可以不在"。)

### 4.2 `sprd_gpu_cooling` / `trusty` 在不在

都在 `out/modules/`:它们本来就属于 5.4 的必装集。`extra-modules` 的 5.4 清单里
`sprd_gpu_cooling` 排在 `mali_kbase` **前面**(第 9 与第 11 项),`trusty` 由 modprobe 按 `depends` 自动拉起。

## 5. 上机实测(2026-10-16:内核侧全过,用户态缺物)

### 5.1 第 1 步:模块在位、能加载 ✅

```
$ ls -l /lib/modules/5.4.254-gb50db5b6224c/mali_kbase.ko
-rw-r--r-- 1000 1000 1578376 Oct 15 20:21  …/mali_kbase.ko      md5 aa32a1cddf4c920da475c74a6d54eeb1
$ strings …/mali_kbase.ko | grep -m2 r40p0
K:r40p0-01eac0(GPL)          version=r40p0-01eac0 (UK version 11.36)
vermagic=5.4.254-gb50db5b6224c SMP preempt mod_unload modversions aarch64   ← 与设备内核一致
$ grep mali /proc/modules
mali_kbase 1007616 0 - Live … (OE)          ← 已加载
sprd_gpu_cooling 24576 1 mali_kbase, Live … (E)   ← 热控 cooling 也挂上了
$ ls -l /dev/mali0
crw------- root root 10, 112   /dev/mali0                                        ← 节点在
```

早期启动日志(`/root/diag/*.log` 抓的 dmesg,uptime 154 s):

```
mali 23140000.gpu: GPU identified as 0x1 arch 9.0.9 r0p1 status 0
mali 23140000.gpu: No priority control manager is configured
mali 23140000.gpu: No memory group manager is configured      ← §4.1 判定无害,现场证实
mali 23140000.gpu: Using coherency mode 31 set from dtb
mali 23140000.gpu: Probed as mali0
```

**⇒ 内核侧真的起来了**,不是"文件在位而已":GPU 被识别出 arch/rev、`Probed as mali0`、
`/dev/mali0` 在、`gpuinfo` 报 **`Mali-G57 4 cores r0p1 0x9091`**、`core_mask` 三组都是 `0x50005`
(4 核可用)、`devfreq` 有 `384/512/655.2 MHz` 三档且 `governor=simple_ondemand`、
空闲时 `runtime_status=suspended`(**runtime PM 正常,空闲不耗电**)。
**没有固件依赖**:`/lib/firmware` 下没有任何 mali/csf blob,probe 照样成功(G57 是 job-manager
型,不需要固件)——这与上游 e5-linux 的结论一致(见 [`e5-linux.md`](e5-linux.md))。

### 5.2 第 2 步:启动链不再报错 ✅

`extra-modules` 的清单里 `mali_kbase` 已是硬根;设备上模块文件在位、`/proc/modules` 里有它,
`FAILED mali_kbase` 那类行只出现在 §1.1 那份"模块集还空着"的历史日志里。

### 5.3 第 3 步:用户态真的吃得下 ❌ **缺物,不是缺驱动**

```sh
/opt/changxing60/bin/android-gpu-run /system/bin/cltest     # 脚本在设备上(/opt/changxing60/bin/,805 B,10-14 装的)
ls /opt/changxing60/android/vendor/lib64/                   # → 只有 lib_crypto.so、libkernelbootcp.trusty.so
find /opt/changxing60/android -name 'cltest*' -o -name 'lib*GLES_mali*' -o -name 'libmali*'   # → 空
```

当初 stage 安卓子集时**只拷了 `modem_control` 需要的东西**(见 `android-vendor-start`),GPU 用户态
从没进来。要跑通第 3 步,得从安卓 vendor 侧补两样(它们在 `super` 动态分区的 `vendor` 逻辑分区里):

1. `cltest` 本体 —— 但**我们有源码**:`tools/gpu/cltest.c` + `build.sh`(clang 直编 bionic,
   自带 `_start`),不依赖安卓里的副本;
2. **`libGLES_mali.so`(Mali UMD)才是缺的关键件**,DDK 大版本必须与内核 kbase 匹配
   —— 我们的内核是 **r40p0**,所以要 r40p0 的 UMD(安卓原厂同版本,理论可直取)。
   取法与校验:从 vendor 的 `lib64/egl/` 拿,`strings | grep -m1 r40p0` 先验版本再拷。

预期结果(与本文 §5 原计划一致):`OpenCL 3.0 v1.r40p0-01eac0`、device `Mali-G57 r0p1`、
4M 元素 kernel 结果正确。

**注意**:GLES/Vulkan 只能**离屏**用 —— 内屏没有接到 GPU 合成器上(内屏走的是 `sprd-drm`,
CPU/软渲染那条路,见 [`screen-plan.md`](screen-plan.md))。所以「GPU 正常」= **OpenCL/compute 可用**,
不是"界面变流畅"。

## 6. 与旧文档冲突的地方(以本文为准)

- `screen-plan.md` §「没编的只有三样」写「`mali_kbase`/`sprdbt_tty`(realme 树,本项目暂不需要)」,
  §「不编 `mali_kbase`(省电 + 无需求)」—— **那两条已作废**。当时的判断前提是"状态屏不用 GPU",
  但用户在 2026-10-15 明确要求 GPU 正常,需求变了,结论跟着变。
- 代价诚实说清:`mali_kbase` 常驻约 **+45 MiB 内存**(FINDINGS §28 实测)。在 6GB 的板子上,
  相对"用户明确要的功能"这笔钱不值一提;但它是**真的会多耗电**的一项,若将来做省电策略,
  「不用 GPU 时 `rmmod mali_kbase`」是可以考虑的一档(见 [`power.md`](power.md) §11)。

## 7. 顺带的教训(可推广)

「可选」清单是**技术债的藏身处**。这次修的不只是一个模块:

- 一个**静默**的构建缺失,能在设备上潜伏好几轮迭代,因为**失败被设计成非致命**;
- 而"非致命"的决定是**对的**(headless 场景下确实不该拦住启动)—— 错的是把
  **有需求的东西**留在那个清单里,以及**构建步骤只存在于 README 的人工步骤**里。

两条都已修:`stage-modules.py` 里 `mali_kbase` 变硬根;`tools/build-mali-54.sh` 让"编出来"这件事
**可复跑、可核对版本、错了会退出非零**。
