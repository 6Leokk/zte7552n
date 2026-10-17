# 7552N 移植路径可行性评估

> **状态:前瞻评估(2026-10-11)。** 移植方案 2026-10-10 已归档(见 [README.md](README.md)),
> 本文档评估**若将来重启**各路径的可行性与代价,不意味着恢复推进。
> 用户当前焦点目标:**开机时能选择进哪个系统**(OpenWrt / Android)。

## 0. 硬约束(所有路径共用)

| 约束 | 含义 |
|---|---|
| LK bootloader 锁死 | boot ROM 签名链验证 LK;无 SPD 工具/固件 → **不能替换 bootloader,不能装真 GRUB**。任何"开机菜单"只能放我们的内核 initramfs 里(LK 之后) |
| 无 SD 卡槽 | 上游"rootfs 落 SD、eMMC 不动"的零损伤路径不可用(实机确认) |
| UFS 无尾部空闲 | userdata 占满全盘;持久 rootfs 分区只能靠 GPT 缩容 userdata(必然伴随恢复出厂) |
| stock 内核无 PID_NS/USER_NS | 裸 chroot 容器无隔离(E28-E36 炸根);我们**自编** 5.4 内核(fragment)有全套 namespace + cgroup + overlay |
| A/B slot + misc 机制已证 | 9 trial 干净回滚 0 砖;tries+successful+prio 字节布局已解码(本机 live A=0xff/B=0x0f,trial A=0xfe/B=0x2f) |
| PMIC 看门狗 | 独立于 AP 的硬件计时器(pmic-wdt);AP 全锁死也能切电重启 |
| recovery-as-boot | recovery 在 boot_a(全程不动)→ 软件全失灵时物理按键进 recovery 恢复出厂 = 不砖(毁 /data) |

## 1. 开机选系统的通用机制(所有持久路径共用)

真 GRUB(替换 bootloader)不可行 → "菜单"放 initramfs:

```
LK → slot b(我们的内核)→ initramfs 菜单:
   默认 N 秒 → OpenWrt(pivot 到 rootfs);打断 → 出菜单
   选 Android → init 改 misc(slot_a active) + reboot → LK 起 Android(保 KPatch root + AVB 干净)
   底下叠 tries 兜底:OpenWrt 起不来 → tries 耗尽 → 自动回 Android
```

- 交互媒介:USB 串口 ttyGS0(trial 已证)/ USB 网络 telnet(已证);屏幕点选需 Phase-D 显示先点亮(未做)。
- 切 Android 走 **misc+reboot**(保 root + 干净 AVB),不走 kexec——kexec 丢 KPatch root、跳过 AVB,不划算。
- 安全持久化配置:`tries=2, successful=0`,OpenWrt 健康后续 tries(不 mark successful=1);看门狗常开 + 用户态踢。死机 → 看门狗重启 → 没续命 → tries 耗尽 → 回 Android。

## 2. 路径可行性矩阵

| 路径 | wipe? | 死机回安卓 | 工作量 | 主要未知数 | 契合"开机选系统" |
|---|---|---|---|---|---|
| **C. initramfs-OpenWrt(轻)** | 否 | tries 兜底 | 中 | 塞进 64MB boot_b;配置 RAM 临时;initramfs 打包 | ★★★ 最贴 |
| **A. 全量原生安装(Phase-3)** | 是 | tries 兜底 | 中高 | 已证大半;wipe 代价 | ★★ 持久稳 |
| **D. 自编内核 + namespace 容器** | 否 | Android 始终在线 | 中高 | APatch/KPatch 存活;E36 根因未诊 | ★ 范式不同 |
| **E. mainline 7.2 原生** | 是 | 需自建同套 tries | 高 | 充电 sqc 无覆盖;网络稳未证;显示移植未证 | ★ 长期可维护 |
| ~~F. stock 内核容器~~ | — | — | — | E35 删光 /dev、E36 卡 boot | ❌ 已排除 |

## 3. 各路径详评

### C. OpenWrt-as-initramfs(轻路子,最低风险)

boot_b = 内核 + initramfs(OpenWrt + vendor 模块 + 菜单)。OpenWrt 从 RAM 跑,不要 rootfs 分区。

- **优点**:不缩容、不 wipe、slot_a Android + 全部数据原封不动;菜单天然;死机吃 tries 兜底。
- **代价**:配置 RAM 临时(重启丢,需导出/导入配置包兜底);要塞进 64MB boot_b(内核 30.5MB + OpenWrt 15MB + 模块 7.5MB ≈ 53MB,挤掉持久日志区能进,未实测打包);14.7MB OpenWrt tarball 要转 cpio.gz initramfs 格式(一步构建)。
- **状态**:未试;Phase-2 trial 机制可复用(同套 boot 镜像 + misc trial 块)。
- **契合**:正是"开机选 OpenWrt/Android"的最小风险实现。

### A. 全量原生安装(归档 Phase-3)

GPT 缩容 userdata + ext4 changxing60root + 持久 boot_b。

- **优点**:持久、配置不丢、功能最全;Phase-1(内核)+ Phase-2(boot 机制)已证;GPT 工具 `gpt-shrink-userdata.py` 已建并执行+回滚过一次;OpenWrt rootfs 已预编(14.7MB,sha 143477f1)。
- **代价**:必然一次恢复出厂(清 /data 全部);无 SD 槽无替代存储。
- **状态**:大半就绪,卡在"wipe 代价"用户否决(09-20)。单启动场景下(不再以 Android 为主)代价可接受度上升。
- **契合**:能加菜单,但 wipe 代价重。

### D. 自编内核 + namespace 容器(未走)

boot_a 换成我们自编内核(有 PID_NS/USER_NS),Android 照常起(汽水照挂),OpenWrt 当真·LXC/Docker 容器常驻。

- **优点**:不 wipe、不双启动、Android 全功能 + OpenWrt 共存;E28-E36 的炸根(裸 chroot 无 PID_NS + bind /dev)结构性消除。
- **代价/未知**:KPatch/APatch 贴的是 stock 内核,换内核后 root 能否保住 = **未测**;E36 卡 boot 根因从未确诊,自编内核上是否复发 = 未知;容器持久形态要落实 E35 铁律(容器 /dev 独立 tmpfs 白名单、umount 验返回值、rm 前查挂载)。
- **状态**:纯未走;**APatch/KPatch 兼容性是首个硬未知,先验这个**。
- **契合**:不是"开机选 slot",是"Android + 容器常驻",范式不同——若你要的是开机二选一,这条不对路。

### E. mainline 7.2 原生

上游 changxing60-linux 的 7.2 mainline 路径。

- **优点**:长期可维护、现代内核、KVM/WireGuard/SQM 等模块全;UFS 主线已有驱动(6.3 起 `drivers/ufs/host/ufs-sprd.c`,~2-4 天 DT 接线);suspend 已通(FINDINGS §37)。
- **代价/未知**:充电 sqc/upm6910h **主线无覆盖**(上游只 bq25601 / U30 Air),需自适配;WiFi 网络稳未证(模块重编非出厂二进制,9 trial 未压测);显示 sprd-drm 移植到 7.2 估算"天级非周级"但未实测;仍要 wipe(GPT 缩容)。
- **状态**:最高工作量 + 最多未知;适合"长期可维护基线"目标,不适合"快速实现开机选系统"。
- **契合**:与"开机选系统"目标距离最远。

### F. stock 内核容器(已排除)

E28-E36:无 PID_NS → 裸 chroot → E35(umount 静默失败 + rm -rf 穿透 bind mount 删光宿主 /dev)+ E36(重启卡 boot,根因未诊)。09-20 用户拍板放弃。**不再作为路径。** 教训(容器 /dev 独立 tmpfs 白名单、umount 验返回值、rm 前查挂载)记入 D。

## 4. 推荐与渐进

按"开机选系统"目标 + 最小风险:

1. **先走 C(initramfs-OpenWrt)**:不 wipe、Android 全留、菜单原生、tries 兜底。验两件事——OpenWrt 能否塞进 64MB boot_b + 起来;配置临时性能否接受。这是"能不能选"的最快验证。
2. **C 验通后若要持久配置/全功能**:升到 A(GPT 缩容 + rootfs 分区),C 的菜单 + tries 安全层原样复用。此时 wipe 代价换持久。
3. **若要 Android + OpenWrt 同时在线(非二选一)**:走 D,但先验 APatch/KPatch 在自编内核的存活这个硬未知。
4. **E(7.2 mainline)** 留作"长期可维护基线"的远期目标,不在"开机选系统"的近程路径上。

## 5. 已证可复用的资产

- boot 机制(9 trial,LK 放行 / 模块加载 / NCM / 看门狗 / 干净回滚全绿)
- misc 字节推导(`gen-misc-blocks.py` + `build-boot-image.py` live 推导,F50 回归互证)
- GPT 缩容工具(`gpt-shrink-userdata.py`,4096 LBA,主备 CRC,dry-run + 执行 + 回滚过)
- OpenWrt rootfs(14.7MB,sha 143477f1)+ Ubuntu rootfs(89.6MB,sha ea221c8a)
- 自编 5.4 内核(Image + 94 模块,vermagic 精确,fragment 全套 namespace)
- trial-net 观察工具(`observe-trial.sh` / `telnet-cmd.py`,在 `rescue/tools/trial-net/`)
- rescue/dumps(boot_ori / misc / GPT 五件套)+ `data-backup/MANIFEST.md`

## 6. 任意路径重启时的前置

- `changxing60-linux@7552n-port` 落后 `origin/main` 497+ commits → rebase 到新 main(继承 fgu / suspend / ttl / CI / KVM 合并波)。
- 重读 [README.md](README.md)「网络优势误判纠正」:**别以"5.4 网络更稳"为默认前提**,先压测 WiFi 再下结论。
- 充电(sqc/upm6910h)、显示(Phase-D)仍是 7552N 特有未解项,上游 bq256xx / sprd-drm 覆盖不上。

## 7. 三条澄清(2026-10-11 讨论结论,备查)

用户三问的结论,均带仓库实据可审计。

### 7a. 缩容(GPT shrink)能解决"所有"问题么?—— 不能,只解决 2/6 且让汽水更糟

| 墙 | 缩容是否解决 | 说明 |
|---|---|---|
| 无 SD 槽 | ✅ | 不靠 SD,在自己 UFS 上造 rootfs 分区 |
| 无尾空 | ✅ | 缩 userdata 腾出 changxing60root |
| stock 无 PID_NS | ❌ | 内核配置缺口,非存储问题;需配自己内核(slot B 自编 5.4) |
| 汽水身份 | ❌ **更糟** | 缩容=一次恢复出厂=清 /data=汽水数据没;单启动 OpenWrt 则汽水根本不在线 |
| 黑箱(无 LED) | ❌ | 不沾 |
| 充电(sqc)/WiFi 稳 | ❌ | 不沾,仍待解/压测 |

组合结论:**缩容 + 自己的内核(slot B)** = 本文档 A 路径,同时解决存储 + PID_NS/Docker;代价是进 OpenWrt 时 Android/汽水不在线。**缩容本质 = 选 Linux 优先、汽水只能靠双启动在 Android 时段赚。** 是取舍,不是"全解决"。

### 7b. 能用 Docker 么?—— 分内核

- **stock 内核:不能。** 无 PID_NS/USER_NS,E28-E36 已证裸 chroot 在 stock 上炸根(E35 删光 /dev)。Docker 要求 ≥ PID namespace,stock 死路。
- **自编 5.4 内核:配置允许,未实测。** fragment 开了 `PID_NS`/`USER_NS`/`NET_NS`/`CGROUPS`/`VETH`/`BRIDGE`/`OVERLAY_FS`/`SECCOMP`/`MEMCG`/`NFT_NAT`——Docker 全套。但 7552N 上没跑过 dockerd。开放未知:cgroup v1(Android 混合态)vs v2(Docker 偏 v2)、SELinux/AppArmor 拦不拦 dockerd、(若与 Android 共存)APatch/KPatch 在非 stock 内核 root 能否活。
- **未必需要 Docker**:slot B 里 OpenWrt 当 init,procd/ubus/dnsmasq/sing-box 原生跑,不套容器。Docker 只在"OpenWrt 之上再塞额外容器化 app"时才用得上。

### 7c. 能用 5.4 / 6.1 / 7.2 内核么?—— 只有 5.4 在 7552N 上证过

仓库实据(changxing60-linux `git branch -a` / `git tag` / `docs/FINDINGS.md`,2026-10-11 查):

- **5.4:能,唯一在 7552N 证过启动的内核。** stock = `5.4.254-android12-9-g9c6342244991`(FINDINGS §4);自编 = 5.4.254 开源 Unisoc 树(`build-linux.sh` `cd /src/zte-u30air`)。9 trial 就是它。FINDINGS §89:开源树正好 5.4.254,覆盖 150 个 F50 vendor 模块中的 137 个;§93:更老的 5.4.147 树缺整套 qogirn6pro USB 栈,不可用。
- **6.1:无现成路径。** 仓库**无 6.1 tag/branch**——tag 全日期制(`v2026.09.17`…`v2026.10.12`),branch 全特性制(`charger-bq256xx`/`clean-tf-7.2`/`suspend-drivers`/`ttl-luci`/`wlan-build-rerun`/`fgu-capacity`/`power-profiles`…)。FINDINGS 出现的内核版本仅 5.4.254(在用)、5.4.147(不可用)、mainline 方向提及(§31m "under 6.18"、§37 suspend 在 6.18 通、§18 警告 OpenWrt 自带 armsr 用 kernel 6.12 会整盘刷毁 eMMC)。要用 6.1 = 自把 5.4 BSP 前向移植到 6.1,且**无意义**——要花移植劲不如直接奔 7.2(上游 mainline 真正在那儿)。
- **7.2:上游 mainline 方向,7552N 上未证。** 有 `clean-tf-7.2` 分支、FINDINGS §37 suspend 在 6.18 通——但那是**上游主线进展,非 7552N 跑通证据**。7552N 上用 7.2 要自啃:UFS DT 接线(mainline 6.3+ `drivers/ufs/host/ufs-sprd.c`)、充电 sqc/upm6910h 自适配(上游只 bq256xx 给 U30 Air,`charger-bq256xx` 分支覆盖的是 U30 Air 不是 7552N 的 sqc)、WiFi 前向移植、sprd-drm 移到 7.2。**最高工作量 + 最多未知。**

**横切铁律(三版本都吃):** 无论选哪个内核,94 个 vendor 模块须**针对该内核 vermagic 重编**(symbol CRC 约束,见 [README.md](README.md)「网络优势误判纠正」)。换内核 = 移植全部 vendor 驱动到新内核 API + 重编,非 config 一翻。故 5.4 务实(已做完)、7.2 费劲(移植量最大)、6.1 既无现成也白做。
