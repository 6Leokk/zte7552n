# 设备状态快照 —— 2026-10-17 版本收束时的现场

**用途:回滚参照与"当时到底是什么样"的判据。** 这**不是**可刷写的镜像,是一份**只读的文本记录**:
把设备上跑的那个版本,连同它的每一个文件,固化成可比对的指纹。设备哪天变得奇怪了,拿这里的
`md5sums.txt` 一比就知道**是哪个文件变了**,而不是靠回忆。

采集时间:`2026-10-16 19:02 (+03)`,设备 uptime 34 min,内核 `5.4.254-gb50db5b6224c`。
(目录名是 2026-10-17 是因为按收束这个动作命名的 —— 设备时间比本地早 5 小时,见
`docs/changxing60/state-2026-10-17.md`。)

## 文件

| 文件 | 是什么 | 什么时候看 |
|---|---|---|
| `identity.txt` | `uname -a`、`date`、完整 `/proc/cmdline`、`uptime`、`/etc/changxing60/boot-history` | 想知道"这次开机为什么起来的"——看 `bootcause=` |
| `modules.txt` | 完整 `/proc/modules`(165 行) | 有模块没载上时,和这份比 |
| `network.txt` | `ip -br addr` / `ip route` / `ip -6 route` / 无线状态 | 网络出问题时先比这个 |
| `installed-files.txt` | 设备上所有已装文件的清单(98 行) | **判"文件该不该在"**;含落点(`/usr/bin` 还是 `/opt/changxing60/bin`) |
| `md5sums.txt` | 上面那些文件的 md5(103 行) | **判"文件有没有被改过"** —— 这是本快照最有用的一份 |
| `config-changxing60.txt` | crontab + `/etc/changxing60/*` 全部内容 | 看开机自愈/守护的配置 |
| `config-uci.txt` | network / firewall / wireless / system / dhcp 五份 uci | 看网段、防火墙 zone、热点参数 |
| `logs-and-pstore.txt` | `logread` 尾部 + pstore 各 region 的头部 | 排查重启/崩溃(⚠ 见下) |

## ⚠ 读这份快照要知道的三件事

1. **本快照已脱敏(2026-10-17 晚,为发布 GitHub)**:`config-uci.txt` 的热点口令、`config-changxing60.txt`
   的 PSK 与通话日志里的号码、`identity.txt` 的序列号/eMMC ID 都替换成了 `<REDACTED-…>`。
   **未打码的原件**存在主机仓库外:`~/.local/share/zte7552n-private/rescue-dumps-raw-2026-10-17/`。
   真凭据本身一律只在 `~/.changxing60-secrets`(0600)—— 仓库里任何文件都不再有它们,这条取代早期
   "不许给外层加 remote"的旧说法(当时快照含明文口令)。
2. **`logs-and-pstore.txt` 里 pstore 那段可能已经不是"上一次崩溃"了**:pstore 每个 region **只留一份**,
   后来的崩溃会把旧现场顶掉。这里的 18:28 oops 现场另有一份更完整的存档在
   `rescue/dumps/2026-10-16-audio-oops/`(带 SHA256SUMS)。
3. **`load average` 12 是假象**(vendor kthread 常驻 D 态),别拿它当负载指标。

## 怎么用它回滚 / 比对

`md5sums.txt` 里是**绝对路径**(102 行),所以设备上直接 `md5sum -c` 就行,**不用 `cd /`**。
但**第 1 行是 ssh 的 `Warning: Permanently added …`**,不是校验行 —— 先把它剔掉,否则它会永远报一条
"No such file",看着像"设备变了一个文件"。

```sh
# 逐文件比对:唯一可靠的判据
sed '/^Warning: /d' md5sums.txt > /tmp/snap.md5          # 剔掉那行 ssh 噪声
scp -O /tmp/snap.md5 root@192.168.77.1:/tmp/             # 注意 -O(scp 走旧协议才通这台设备)
ssh root@192.168.77.1 'md5sum -c /tmp/snap.md5 2>&1'
```
**判据**:输出里**只有 `: OK`,没有任何 `FAILED`** = 设备上的文件与收束那一刻**逐字节相同**。
(设备 busybox 有 `md5sum`,支持 `-c`;`installed-files.txt` 用来判"文件该不该在",
`md5sums.txt` 用来判"有没有被改过" —— 两个问题要分开问。)

**这条配方 2026-10-17 已在真机上跑过**:`102 / 102 OK,0 FAILED`,设备 uptime 38 min。所以它现在是一条
**实测过的**回滚判据,不是照着格式猜的。设备那侧唯一可能多出来的一行是 ssh 自己打的
`Warning: Permanently added …`(首次连接时才有,进了 known_hosts 就不再出现)—— 那不是文件不匹配。

源码那一侧的回滚参照不在这个目录,在**两个 git 仓库的提交**(见 `state-2026-10-17.md` §5);
启动镜像的回滚参照在 `rescue/` 的 misc slot 记录(`docs/changxing60/reboot-boot-slot.md`)。
