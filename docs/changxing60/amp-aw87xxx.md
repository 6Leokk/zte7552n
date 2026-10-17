# 喇叭功放 AW87xxx:驱动能编、能装,但要响还差一个机器卡钩子

> **状态(2026-10-16)**:**源码找到了、在 5.4.254 上编过了(vermagic 逐字匹配、77 个 `cfi_jt`)、
> 固件也捞出来了**。但**还没 insmod、没试听过**,而且**光加载驱动喇叭不会响** —— 机器卡那条路
> 被 `#if 0` 关着,需要一个 `hook_general_spk_for_aw87xxx()`(形状照 e5-linux 的补丁)。
> 本文件把"到哪一步了、下一步是什么、坑在哪"写清楚。
>
> **最重要的一条先说**:听筒**不经过** AW87xxx。所以**打电话的音频不依赖这个功放**
> (见下面「听筒不需要它」一节)—— 这个功放是给**喇叭/铃声/外放**用的。

## 1. 为什么它是最后一块

内屏状态页、来电页、三键、AGDSP/ASoC 声卡、voice PCM 通路都已经通了
(见 [`telephony.md`](telephony.md) §9 与 §7)。**但喇叭是哑的**,而这个驱动就是喇叭和"响"
之间唯一的东西。DT 里那个节点一直都在:

```
/sys/firmware/devicetree/base/soc/ap-ahb/i2c@22a0000/aw87xxx@58
  compatible = "awinic,aw87xxx_pa"   reg = <0x58>   dev_index = <0>   status = "okay"
```

现场状态(设备上实测):

| 项 | 值 |
|---|---|
| `/sys/bus/i2c/devices/6-0058/name` | `aw87xxx_pa` |
| `modalias` | `of:Naw87xxxT(null)Cawinic,aw87xxx_pa` —— **与驱动的 `of_device_id` 完全一致** |
| `/sys/bus/i2c/devices/6-0058/driver` | **不存在**(`waiting_for_supplier = 0`) |
| 总线 | `i2c@22a0000`(`sprd,qogirn6pro-i2c`) |
| 卡 | `sound@0`:`sprd-audio-card,name = "sprdphone-sc2730"`,`extral-iic-pa = <0x02>` |

**i2c 器件是真实存在、可寻址、已上电的,只是从来没有驱动认领它。** 这就是喇叭哑的全部原因。

## 2. 芯片是 AW87390 或 AW87391(**不是** AW87566)

早先从 Android 预编译 `.ko` 的产品表推断成 "AW87566 = pid 0xC2",**已被板上固件推翻**:
`aw87xxx_acf.bin` 里只有 **aw87390** 和 **aw87391** 的 profile。

| pid | 产品 |
|---|---|
| `0x76` | aw87390 / aw87320 / aw87401 |
| `0xC1` | aw87391 |

驱动**用寄存器 0x00 自动探测**,所以代码不依赖这个结论 —— 但 BOM / 数据手册 / 订货的活要按
AW87390/AW87391 走,别再按 AW87566 找。

## 3. 源码:哪棵树有、哪棵树没有

**我们已有的树里都没有 aw87xxx**:

- realme C51/C53 音频 drop(`$HOME/.cache/mali-src/realme/`)的 `sound/`(2291 条)与
  `kernel_modules/`(5274 条)里搜不到 `aw87`/`awinic` —— 只有 `aw881xx`/`aw883xx`。
- `kernel-src/realme-unisoc-5.4/` 与 `kernel-src/zte-ums9620-kernel-5.4.254/` 同样只有
  `aw881xx`/`aw883xx`/`drivers/vendor/common/awinic`。

**线上那个同名仓库是错的驱动**:`github.com/gtxaspec/aw87xxx`(Awinic v2.0.0.10)的
`aw_dev_chip_init()` 只分派 chipid 9A/9B/39/59/5A/76,其余一律 `unsupported device revision`。
它对 0x76 有效,**对 0xC1 无效**。

**正确的那棵**:

```
Enceka/kernel_sprd_ums9158
  sound/soc/sprd/unisoc/codec/aw87xxx/        (14 个文件)
  pinned @ 9b36195d554d18c17dc30733a977ee69ce888ac1
```

**凭什么认定它是同一代**:

- `aw87xxx.c:1969` `{.compatible = "awinic,aw87xxx_pa"}` —— **与我们的 DT 节点逐字相同**。
- `aw87xxx.c:61` `AW87XXX_FW_BIN_NAME "aw87xxx_acf.bin"` —— 与我们板上的固件名相同。
- 导出符号集与 Android 预编译 `.ko` 完全一致:`aw87xxx_set_profile`、`aw87xxx_set_profile_by_id`、
  `aw87xxx_show_current_profile`、`aw87xxx_set_boost_voltage`、`aw87xxx_get_boost_voltage`、
  `aw87xxx_add_codec_controls`、`aw87xxx_spin_set_record_val`。
- `g_aw_dev_property_registry[]` 覆盖 9A/9B/18/39/59/5A/**76**/60/**C1**/C2/23 —— **两个候选 pid 都在**。

**源码树是 5.15.211,但能在 5.4 上编**:驱动带显式的 `AW_KERNEL_VER_OVER_5_4_0` 保护,
且不用任何 5.6+ 的 API(无 `sysfs_emit`、无 `proc_create`、无 `dev_err_probe`)。
**这不是"看起来可行"** —— `tools/build-aw87xxx-54.sh` 编过,产物
`work/aw87xxx-modules/snd-soc-sprd-pa-aw87xxx.ko`:

```
vermagic: 5.4.254-gb50db5b6224c SMP preempt mod_unload modversions aarch64
depends:
1643432 B, 77 个 cfi_jt 符号
```

`depends:` 空 —— 它不依赖任何 sprd 头文件,只用 `<linux/*>` 和 `<sound/*>`。

## 4. 固件

`firmware/aw87xxx_acf.bin`(1888 B),从仓库已有的 EROFS dump 里取的:
`work/audio/vendor.img` → `/firmware/aw87xxx_acf.bin`。头部 `08 f9 15 0a | "P720F09" | "ZTE"`
—— 项目代号与本板匹配。`work/e5-ref/pull-audio-firmware.sh` 在 Android 上拉的是同一个文件
(`/vendor/firmware/aw87xxx_acf.bin`)。

`firmware/` 是 gitignore 的(和 VBC 那三份一样),属于**构建输入**,`build-rootfs.sh` 会把它拷进
`/lib/firmware`。

## 5. 🔴 真正的拦路石:机器卡把 i2c-PA 那条路 `#if 0` 掉了

**加载驱动 ≠ 喇叭响。** 机器卡是通过 `sprd-asoc-card-utils-hook.c` 够到功放的,而那里:

- i2c-PA 那条路被 **`#if 0` 关着**(该文件 137–164 行);
- 现在生效的那条(`extral-iic-pa = <2>` 时选中)会退回去做 GPIO 查找,
  在 `gpio is invalid!` 处失败并返回 `-EINVAL` —— 因为**我们的 DT 没有 `sprd,spk-ext-pa-gpio`**。

**所以"把 `#if 0` 打开"这个直觉是错的**:那段代码用 `kallsyms_lookup_name` 找
`aw87xxx_i2c_pa` 和 `aw87xxx_audio_scene_load`,而**这两个符号 Android 预编译版和 E5 源码都没导出**。

**修法是 E5 用的那条**(`e5-linux/kernel/patches/0012-aw87xxx-hook-without-gpio.patch`):
写一个 `hook_general_spk_for_aw87xxx()`,调**已导出**的
`aw87xxx_set_profile(0, "Music")` / `"Off"`,**跳过 GPIO 查找**。

已核对:`"Music"`(id 0)与 `"Off"`(id 11)**都是我们 `acf.bin` 里真实存在的 profile 名**
(DDE `dev_profile` 字段在偏移 106 和 234)。

## 6. 听筒**不需要**它(这条对通话很重要)

`sprd-codec.c`(realme UMS9620 树,`ump9620/codec/`):

```
SND_SOC_DAPM_OUTPUT("EAR Pin"), SND_SOC_DAPM_OUTPUT("SPK Pin"),
{"SPK Pin", NULL, "SPK PA"},
{"EAR Pin", NULL, "EAR Gain"},
```

DT 路由里 `Ext Spk ↔ SPK Pin` 与 `Ext Ear ↔ EAR Pin` 是**两条独立的路**。
**只有喇叭那条经过 AW87xxx**;听筒、耳机、麦克风、BT-SCO 都不经过。

**推论**:打电话(听筒出声)不依赖这个功放。这个功放卡的是**外放/铃声/媒体**。
所以 §5 那个钩子是"让喇叭响"的活,不是"让通话有声音"的活 —— 两者别混。

## 7. 下一步(按顺序)

1. **写机器卡钩子** —— `hook_general_spk_for_aw87xxx()`,照 e5 补丁的形状,跳过 GPIO。
   这是工作量最大的一步,也是唯一挡住"喇叭响"的一步。
2. **纳入构建** —— `tools/build-aw87xxx-54.sh` 已经能一键重编(源码 pinned、vermagic 校验、
   `cfi_jt` 校验)。
3. **暂存** —— `tools/stage-modules.py`;模块**无依赖**,放音频模块之后即可。
4. **上机** —— insmod + 试听。**这一步还没做**(见下面的诚实边界)。

## 8. 诚实边界

- **编过了,但没在设备上 insmod、没试听过。** 端到端"喇叭出声"仍未验证。
- §5 那个钩子是**尚未开始**的工作,不是"差一点"。
- Android 预编译的 `snd-soc-aw87xxx.ko`(285806 B,在 `work/audio/vendor_dlkm_a.img` 里)
  **装不上**:vermagic `5.4.254-android12-9-gd5a8ab235157` ≠ 我们的 `5.4.254-gb50db5b6224c`,
  `module_layout` 等 CRC 也不同。**只作参考**(产品表、导出符号集就是从它身上取的)。
- 芯片是 AW87390/AW87391 而非 AW87566 —— 对代码无影响(自动探测),但影响任何 BOM/手册的活。
- 听筒/耳机/麦克风/BT-SCO **从来没有被这个功放挡过**。
