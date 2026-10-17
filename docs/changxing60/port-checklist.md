# changxing60-linux → ZTE 7552N 移植改造清单

> **⚠ 已归档(2026-10-10 放弃)**:本方案已正式终止推进,本文转为只读档案。
> 终止决定与理由见 [`docs/changxing60/README.md`](README.md)。

> 依据: `changxing60-linux` 仓库(clone 于 `~/code/zte7552n/changxing60-linux`,2026-09-18)
> 与本机实测(adb + su,同日)。F50=MU300,本机=ZTE 7552N (P720S20)。

## 0. 实测核对结论

| 项 | F50(作者) | 7552N(本机实测) | 判定 |
|---|---|---|---|
| SoC/板型 | ums9620 / 2h10_feimao | ums9620 / 2h10 | ✅ 同板系 |
| 内核 | 5.4.254-android12-9 | 5.4.254-android12-9-gd5a8ab235157 | ✅ 同基线 |
| root/校验绕过 | 需具备 | Magisk;locked+green 但改过 boot_a 能跑 | ✅ 改 boot_b 大概率也过(待实测) |
| 当前槽位 | _a(要求) | `_a`,boot_b=完整原厂镜像 | ✅ |
| boot 头格式 | ANDROID! v4 | boot_ori/boot_a 均 v4;vendor_boot_b=VNDRBOOT;dtbo_b 有效;dtb_a/b 全零(不用) | ✅ |
| misc 引导控制块 | BCAB@0x800 | BCAB@0x800,CRC 正确;**A=0xff B=0x0f**(F50 基线是 0x9f/0x1e) | ⚠️ slot 字节要重新推导 |
| UDC | 25100000.dwc3 | 同(另有 musb-hdrc.1.auto) | ✅ 不改 |
| vendor 依赖 | modem_control/cp_diskserver/refnotify/库/XML | 全部存在,路径一致 | ✅ extract-subset.sh 不改 |
| WiFi/BT 固件 | /odm/firmware 等 | `/odm/firmware/wcnmodem.bin` 等全在;变体名不同:`_aa`/`.xpe`(F50 拉的是 `_ab`) | ⚠️ 改拉取列表 |
| 存储 | eMMC mmcblk0 | **UFS(YMTC)/dev/block/sda**,3 LUN(sda 主 119GiB,sdb/sdc=spl) | ❌ 脚本改盘符 |
| 尾部空闲空间 | ~32GiB(核心依赖) | **0(只剩 2MiB GPT 备份区)**,userdata 110G 占满全盘 | ❌ 最大工程:重分区 |
| RAM | 1.4GiB 可见 | 5.3GiB 可见(6G 机) | ✅ 更宽裕 |
| 原厂内核 config | f50-stock-B09.config | 已从 /proc/config.gz 拉取 → `rescue/dumps/7552n-stock.config` | ✅ |
| module-order | 含 sdhci+**ufs-sprd-qogirn6pro**+rpmb | 7552N 正是走 ufs-sprd | ✅ UFS 驱动已在列表 |
| SPD 救砖 | 要求"已验证" | **本地无固件无工具** | ❌ 硬前置,未完成 |

## 1. 文件级改动清单

### install.sh
- L31 机型白名单:`*MU300*|*F50*` → 加 `*7552N*|*P720S20*`
- L36-51 空闲区扫描:`mmcblk0/mmcblk0p*` → `sda/sda*`;且本机扫不出空间,
  改为接受外部 `CHANGXING60_OFF/CHANGXING60_SIZE`(重分区后的固定值)
- L88-92 固件拉取列表:`wifi_board_config_ab.ini` → 拉全变体
  (`wifi_board_config{,_aa}{,.xpe}.ini`、`bt_configure_{pskey,rf}{,_aa}{,.xpe}.ini`、
  `fm_board_config*.ini`、`wcnmodem.bin`、`gnssmodem.bin`),让驱动自己按板型选
- L138 `sed ROOT_OFFSET` → 新偏移
- L139 `--stock-boot` 用 **boot_ori.img**(原厂),不要用现在的 boot_a(Magisk 改过)

### boot/init(initramfs)
- L103/L122-124/L247:`/sys/class/block/mmcblk*p*` → `sda*`(misc/boot_b 定位、by-name 重建)
- L185:`losetup -o $ROOT_OFFSET ... /dev/mmcblk0` → `/dev/sda`
- L168:`ROOT_OFFSET=27762098176` → 新值(install.sh sed 注入)
- UDC/persist 日志区(boot_b 48MiB 处,8MiB)不用改:7552N boot_b 同为 64MiB
- 注意镜像总大小必须 <48MiB(build-boot-image.py 会检查)

### tools/android-install.sh
- L20-25 分区扫描、L34 losetup、L38 sb():`mmcblk0` → `sda`
- L63 热点导入路径 `WifiConfigStoreSoftAp.xml`:确认 7552N 上存在(MyOS 可能改路径),
  失败会退化为随机密码,不致命

### tools/android-mount-changxing60root.sh
- 同样 grep `mmcblk` 改 `sda`

### boot/build-boot-image.py
- 设备无关 ✅(输入全是自己 dump 的)
- **但 bootloader_control 字节不能照抄**:`0x9f/0x1e`(slot a)、`0x9e/0x2f`(b trial)
  是 F50 LK 上实测的值;本机原厂是 **A=0xff,B=0x0f**(hex 全文:
  `5f6100004243414201020000ff000f0000000000000000000000000096b18d84`)。
  改法:slot-a 恢复块 = 原样保留本机 live 值;trial 块 = suffix `_b` +
  B 槽设"高优先级+tries=2+!successful",A 槽保持 0xff。
  位布局按标准: prio(4b)|tries(3b)|succ(1b),即 B=0xf4 一类,以 Phase 2 实测为准
- boot/flash-trial.sh 的 live 校验(要求等于 A_HEX)随之调整

### kernel/
- `f50-stock-B09.config` → `7552n-stock.config`(已拉)+ merge `changxing60-linux.fragment`
- 源码用 U30 Air 5.4.254 镜像树(`dikeckaan/zte-ums9620-kernel-5.4.254`),同 SoC;
  DTB 不用管(LK 从原厂 vendor_boot_b 取,已验证有效)
- build-linux.sh 的 ThinLTO 本机 config 默认关(`# CONFIG_THINLTO is not set`),沿用脚本开启即可

### rootfs/ 与 openwrt/
- Docker 内构建,设备无关 ✅;`KREL` 随新内核版本号改(openwrt/build-rootfs.sh L10)
- OpenWrt 用的官方 armsr/armv8 25.12.5 rootfs 不变

### android-vendor/extract-subset.sh
- 不改 ✅(所有文件已验证存在)

## 2. 重分区方案(最大工程,草案)

目标:userdata 110G→~60G,尾部空出 ~50G 放 changxing60root ext4。

1. **前置:SPD 救砖通道已打通**(见 §3),`/data` 已备份或接受清空
2. dump  boot_b(当前原厂,sha256 前缀 `7479f4ec`)、vendor_boot_a/b、super 头
3. 改 GPT:python 脚本重写 userdata(sda76)entry 的 end LBA + 主 GPT CRC,
   **同步重写盘尾备份 GPT**(位于 LBA 249921535 附近;缩小 userdata 后备份 GPT
   位置不变,但 entry 数组要一致)。已有 gpt_main.bin/gpt_backup.bin 原件可回滚
4. 抹掉 userdata 头部 f2fs 超级块 → 重启 Android → fstab 带 `formattable`,
   init/fs_mgr 应自动格式化并重建 FBE/metadata 密钥
5. 验证 Android 正常、/data 全新 ~60G 后,再跑改造版 install.sh
   (losetup 到新偏移,建 ext4 `changxing60root`)

风险点:
- metadata 加密(`/metadata/vold/metadata_encryption`)+ formattable 的重建时序
  若不顺利会 bootloop → 救援 = SPD 恢复 GPT + 重刷
- 备份 GPT 不一致会被部分工具判为坏盘 → 主备两份都必须写对
- **必须在 Phase 2(试启动)成功后再做**,顺序不能反

## 3. SPD 救砖通道(硬前置,未完成)

- [ ] 找 7552N 原厂 PAC/SPD 固件(MyOS13.0.18_7552N_UNI 对应版;国内机固件难找,
      渠道:ZTE 官网支持/论坛/酷安/QQ群;或退而求其次:自己 dd 全盘备份代替)
- [ ] 工具:ResearchDownload/SPD Upgrade Tool(Windows)或开源 `spd_dump`
- [ ] 确认 7552N 进 BROM/下载模式的方法(组合键/短接测试点/`reboot edl` 类命令)
- [ ] **实测一次**:进下载模式→工具识别→不刷任何东西退出(或刷回原固件)
- 替代保底:无固件时,先做**全盘 dd 备份**(119G,慢但可行)存 PC,
  砖了用 spd_dump 写回原始镜像(sdb/sdc 的 spl 也要备)

## 4. 建议的实施顺序(风险递增)

- **Phase 0**:SPD 救砖通道(§3)+ 全量备份(boot_a/boot_b/vendor_boot/misc/GPT/spl)
- **Phase 1**:编内核(7552n config + fragment,U30 Air 源码)→ 出 Image + 模块
- **Phase 2**:**不动分区表**,做最小试启动:boot_b 写"内核+initramfs(busybox shell)",
  misc 写 trial 块 → 重启验证:①改过的 boot_b 能否过 LK 校验 ②slot 回滚语义
  ③USB/UDC 起来没有(init 的 300s 定时回滚+持久日志在 boot_b 48MiB 处兜底)。
  失败自动回 Android,boot_b 原镜像可恢复 → **零分区风险**
- **Phase 3**:重分区(§2)+ 跑改造版 install.sh(Ubuntu/OpenWrt rootfs)
- **Phase 4**:功能验收:modem_control chroot(PM 看门狗)、AT+sipa_eth0 蜂窝、
  hostapd 热点、LuCI、蓝牙;OpenWrt `proto changxing60cell` 配 APN

## 5. 备份现状

| 位置 | 内容 |
|---|---|
| 设备 /data/local/tmp | boot_a.img(现 Magisk 版)、**boot_ori.img(原厂 boot,8月)**、misc.bin、gpt_main.bin、gpt_backup.bin |
| PC rescue/dumps/ | misc.bin、gpt_main.bin、gpt_backup.bin、7552n-stock.config(.gz) |
| 待补 | boot_b.img(原厂,写前必备)、vendor_boot_a/b、sdb/sdc(spl)、(可选)全盘 |

## 6. 已识别的坑(来自 FINDINGS.md,对本机同样适用)

- ramdisk 必须 **LZ4 legacy** 打包(gzip 会让 5.4 内核 panic)
- LK 把 `tries==1 && !successful` 当已失败 → 一次性试启动要写 tries=2
- usb0 必须在 UDC bind 后立即 up(macOS/主机侧 ECM 链路状态问题)
- modem_control 只认 comm 名精确等于 "modem_control" 的进程(chroot exec 本体)
- OpenWrt 的 attendedsysupgrade/owut 必须删(整盘刷 armsr 会毁盘),
  sysupgrade 已换成 changxing60 自定义版
- ujail 的 CAP_PERFMON(38) 5.4 内核不认 → procd-ujail/seccomp 要删(build-rootfs.sh 已做)
- regulatory.db 需要签名版(从 Ubuntu 拿,build-rootfs.sh 已做)
