# 蜂窝状态面板 luci-app-changxing60net

> **状态(2026-10-16)**:四件套(ucode 后端 / ACL / 菜单 / 页面 JS)已写完,**主机侧两段验证全过**
> (`tools/net/test-rpcd.sh`,45 条断言,含真 ubusd+rpcd 段);**尚未上机、尚未开过浏览器**——
> 上机命令与判据见 §4,在那之前别把「面板能用」当已发生的事。

## 1. 这是什么

采集器 `changxing60-net-status`(`rootfs/overlay/opt/changxing60/bin/`,`--json` 一次蜂窝快照)
**早已在设备上工作**,但它的头部注释里许诺的「panel 读 `--json`」那个 panel 从来没写过——
`luci-app-changxing60net` 在仓库里不存在(改前用
`find . -path ./upstream -prune -o -name '*changxing60net*' -print` 验过,零命中)。本文件记录
2026-10-16 把它补上的这一层:四件套 + rpcd 胶水 + 主机侧测试 + 推送验证,全部照抄仓库里
三个能工作的面板(SMS / USB / fwd)的形状,一个字段也没自己发明。

页面显示一整轮快照:

| 区块 | 字段 |
|---|---|
| 无线电与注册 | CFUN、LTE/NR 注册状态(27.007 stat:TAC/小区 id/AcT)、运营商(名或 PLMN) |
| 信号质量 | RSRP / RSRQ / SINR / RSSI(优先源:SPENGMD NR → SPENGMD LTE → CESQ → CSQ)+ 来源 |
| 服务小区 | LTE 与 NR 各一:band、EARFCN/ARFCN、PCI、RSRP/RSRQ/SINR、带宽、小区 id、MCS(UL/DL)、BLER(UL/DL) |
| 邻区 | LTE 与 NR 各一张表:band、ARFCN、PCI、RSRP、RSRQ、SINR |
| 数据流量 | `sipa_eth0` 的内核计数器:rx/tx 字节(人类可读)+ 包数 |

两个按钮:全量刷新(整轮,含工程页与邻区)和**快速刷新**(`--fast`,只问廉价层——工程页
读占用 AT 通道更久,而通道和短信发送、通话引擎共享,这一档是给「页面开着还在收发」的)。

页面**只读**。后端 `changxing60net` 一共两个方法:`status { fast }` 和 `fast`,没有第三个;
写入方向的 AT 命令在这条链上根本不存在(采集器只读,后端只跑采集器,页面只调后端)——
`AT+SPENGMD=0,1,0` 会把 AT 口切进流模式致死,频段锁定是写形命令,两者都不在面里。

## 2. 数据契约:未知必须是未知,不能是 0

这是本面板唯一的铁律,也是它存在的理由。采集器保证:**调制解调器没回答的字段是 JSON
null,绝不是编造的 0**;整轮无回答是顶层 `error` + exit 1,而不是一桌看起来像快照的
null。后端与页面要做的只是把这两条区别原样传到屏幕:

- **后端**(`changxing60net.uc`)用 ucode 的 `json()` 把 stdout 解析成值再原样返回——
  null 是真 null,到页面前不经过任何逐字段重读、重类型化或补默认值。真 RSRP 0 dBm 比手机
  能见到的强 1000 倍;给未回答的字段打 0 是比没有页面更糟的那一个谎。
- **错误轮**(exit 1)不冒充页面自己的错:`{ ok: 0, error }` 带采集器自己的句子
  (busy 通道 / atd 不在 / 超时),busy 位只在采集器说了才有;而**后端自己**跑不了采集器
  (或读到的不是它的 JSON)是第三种形状 `{ error, detail }`——页面与人都分得清
  「调制解调器的处境」和「采集器坏了」。
- **页面**(`net.js`)所有字段只有一个出口 `val()`:null → 长破折号 `—`,绝无 0。
  邻区同理:`null`(没问/没报)与 `[]`(问了,就是没有)是两句话,都如实印;
  工程页缺失的原因(`eng_skip`)决定说哪句——`fast`/`unregistered` 是**我们没问**,
  绝不印成「modem 没报」(那是对调制解调器的断言,它没得到回答的机会)。

采集器自己的 null 纪律由 `tools/net/test-status.sh` 用假 AT 钉死(它自己的文件);本面板
的这一跳由 §3 的新测试钉死。

## 3. 怎么验的(主机侧,无设备、无浏览器)

两段,照 SMS 面板的 `tools/sms/test-rpcd.sh` 的结构:

1. **harness 段**(`tools/net/rpcd-harness-net.uc`,在 OpenWrt 镜像里跑 ucode):后端对着
   **桩采集器**(`tools/net/fake-net-status`,回放测试写的 JSON 文件 + 退出码,并把被调
   参数记录到 `dialed`)逐法调用——好快照**逐字段、逐 null 深比对**(自写 `same()`:
  null≠0、null≠""、数字≠字符串、数组逐项、对象逐键,多一键少一键都不算同);错误轮
   (busy / atd 死)各一;**五种坏采集器**(exit 1 无 JSON / 非 JSON / 两行 / 成功却带
   error / JSON 标量)全部拒收而不是猜;全 null 快照逐项仍是 null;`fast` 真的传了
   `--fast --json`(从桩收到的参数证,不从回包猜)。
2. **真 rpcd 段**(`tools/net/rpcd-ubus-check.sh`,镜像里 root 跑真 ubusd+rpcd):插件装到
   rpcd 真读的目录、ACL 装到真位置、`/opt/changxing60/bin/` 放上桩,然后 **`ubus call`** ——
   和页面 `rpc.declare` 同一条路。这一段专抓两样东西:**ucode 插件编不过会装载成
   空,`ubus list` 压根不提它**(页面每个控件都死、什么都不报错)和 **ACL 没授权
   页面调的方法**。所以判据是实调,不是 `ls`。

```sh
tools/net/test-rpcd.sh     # 两段都跑,exit 0 = 全过
```

2026-10-16 实跑结果:两段 **45/45 全过**(harness 33 + ubus 12)。写测试当场抓出两个真 bug:

1. **后端第一版把 stderr 混进 stdout 管**(`2>&1`):采集器 stderr 上的 AT 客户端自述行
   (busy/dead)会排到行 1,把一轮好快照挤丢。修法:stderr 单独落 `TMPDIR` 文件,
   stdout 只留采集器的 JSON 行;顺带把「一行契约」从宽(取第一行)收紧为
   **stdout 出第二行就拒收**(哪行是 JSON 不能靠猜)。
2. **`/tmp` 在镜像里 root-only**:非 root 测试容器写不进,后端的 stderr 重定向全被拒。
   修法:重定向目标跟 `TMPDIR`(设备上 rpcd 是 root,`/tmp` 照常)。

另外页面 JS 本身用 node 做过语法级检查(`new Function(src)` 解析通过);LuCI 的模块依赖
头(`'require dom'` 等)按本项目 2026-10-16 的勘误补齐——三个旧面板都栽在没 require 的
`dom.content` 上,本页面的 requires 是 `view, rpc, ui, dom`。

## 4. 上机与浏览器验收(下一步,尚未做)

推送:`tools/deploy-pending.sh --apply`——2026-10-16 重构后的推送段**按 glob 走**,新面板
四件套自动进清单,不需要逐文件加行;rpcd 重启也在装机段里统一做(后端是插件,rpcd 只在
启动时读一次,不重启文件就躺在盘上)。验证段里有对 `changxing60net` 的**实调**(和 fwd/voice
同一载荷里):

```sh
# 证明对象装载成功(编不过的插件在这里是静默的):
ubus -v list changxing60net          # 应列出 status { "fast": Bool } 和 fast {}
ubus call changxing60net status       # 应答 {"ok":1,"snap":{...}}  一整轮真快照
ubus call changxing60net fast         # 同上,但 --fast 轮

# null 纪律的现场判据:开着 NR 时 csq.rssi 应是 null 而不是 0:
#   "csq":{"rssi":null,...}   对,页面印 —
#   "csq":{"rssi":0,...}      错,后端或采集器在编造
```

浏览器:LuCI → 服务 → **Cell status**(`http://192.168.77.1/cgi-bin/luci/admin/services/changxing60net`)。
判据:页面出数据、null 字段印 `—`、两个刷新按钮都回包、「快照时间」页脚在变。

## 5. 尚未验证(诚实边界)

- **没上机**:四件套还没推到设备、`ubus call changxing60net status` 还没在真采集器上跑过。
- **没开过浏览器**:页面 JS 只有语法级检查,没有任何浏览器(哪怕无头)渲染过它;
  `render()/draw()` 的 DOM 结构错误只能在那里暴露。
- 桩采集器回放的快照是 **2026-10-16 真机实测轮的字段级复刻**(值来自任务里给的实测输出),
  但**后端 ↔ 真采集器**的拼接(命令行、退出码、stdout 单行)只在契约层面测过,真采集器
  从没喂过后端。
- 页面的中文文案没有过浏览器,长字段(注册行)换行后的视觉没验过。

## 6. 工件

| 文件 | 作用 |
|---|---|
| `openwrt/overlay/usr/share/rpcd/ucode/changxing60net.uc` | ubus 对象 `changxing60net`:`status { fast }` / `fast`;跑采集器、json() 原样传值、错误轮与自故障分形状 |
| `openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60net.json` | 页面 ACL(只授两个读方法,无写) |
| `openwrt/overlay/usr/share/luci/menu.d/luci-app-changxing60net.json` | 菜单项(服务 → Cell status,order 64) |
| `openwrt/overlay/www/luci-static/resources/view/changxing60net/net.js` | 页面;`val()` 是字段唯一出口,null → `—` |
| `tools/net/fake-net-status` | 桩采集器:回放 JSON 文件 + 退出码,记录被调参数 |
| `tools/net/rpcd-harness-net.uc` | harness 段断言(33 条) |
| `tools/net/rpcd-ubus-check.sh` | 真 rpcd/ubus 段断言(12 条) |
| `tools/net/test-rpcd.sh` | 两段的总入口(docker 跑 OpenWrt 镜像) |
| `tools/deploy-pending.sh` | 推送按 glob 自动收本面板;验证段实调 `changxing60net` |

采集器本体、它的 AT 面约束(哪条命令能发哪条会弄死通道)和它的测试在
`tools/net/test-status.sh` 与其头部注释;本面板不改它一个字。
