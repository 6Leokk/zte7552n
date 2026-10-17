# rescue/ — 救援记录与设备状态快照

回滚判据与事故证据。**已脱敏**:真实凭据(root/LuCI 口令、热点 PSK、IMEI、序列号、UFI 机器码、出厂 WLAN/BT MAC)
一律不在这里 —— 发布历史也扫过(判据模式集见仓库根 README 的凭据政策)。
原始未脱敏的整机备份在主机本地 `~/.local/share/zte7552n-private/`,不入库。

| 路径 | 是什么 |
|---|---|
| `dumps/2026-10-16-audio-oops/` | `arecord` 打穿 snd_pcm_hw_params 映射那次 oops 的原始 pstore(机制与教训见 `docs/changxing60/audio-oops.md`;pstore 只存一条,这份额度是抢下来的) |
| `dumps/2026-10-17-device-state/` | 版本收束(冻结)时的设备全量状态:uci/网络/模块/已装文件逐份 md5 —— **回滚配方实测 102/102 OK**,README 在同一目录 |
| `dumps/2026-10-17-guard-boot-panic/` | E1 guard 补丁上机当晚装载重启的 boot X panic 原始 pstore(定性为 conflicts.md §10 的 E5,与新 ko 无关) |
| `dumps/7552n-stock.config`,`dumps/config-7552n.gz` | 原厂 5.4.251 内核 config(取证自其 GPL 发布物;.gz 那份带 CORRUPT 后缀的同名件是 adb exec-out CRLF 事故的现场,留作教训) |
| `tools/gen-misc-blocks.py` | 生成 misc 偏移 2048 的 32 字节 bootloader_control(slot b trial 等;`.bin` 产物被 `.gitignore` 的 `*.bin` 规则拦住,现用现生成) |
| `tools/gpt-shrink-userdata.py` | userdatalabel GPT 整备工具(试验线遗产;现行 path A 不需要) |
| `tools/trial-net/` | 早期试启期(boot_b ramdisk 只有 telnet 时代)的 Windows 侧观察脚本 |

**不在 git 里、也刻意不进 git**:`bin/`(WSL adb/docker 包装,机器本地路径)、`firmware/`(厂商
`.ini`,专有)、`data-backup/`(整机 userdata 备份,含真实凭据,只留主机)、`misc-blocks/`、
`gpt-new/`(生成物)、`module-zips/`(第三方模块)、`.docker-config/`。

判据提醒:`rescue/dumps/**/*` 的排除规则吃新目录吃得过两次(audio-oops 归档、设备快照都曾差点
进不了 commit)—— 新增证据目录要**同步加 `!dir/` + `!dir/**` 两行反选**,并用
`git check-ignore -v` 验。二进制文件的取证不要用 `adb exec-out`(CRLF 转换会毁 sha)。
