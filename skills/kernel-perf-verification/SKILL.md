---
name: kernel-perf-verification
description: 用于判断自编译内核在小米 17（pudding / canoe / SM8850 / Android 17 / KMI android16-6-4k）上是否真的更省电、更快、更稳，以及在刷机后判定哪些日志与数字才算证据：开机健康检查、模块数口径陷阱、取证归属判定（<署名后缀> / boot_index）、mtdoops 落盘条件、PSHOLD 复位销毁现场、可观测入口、A/B 交叉配对、bootstrap 置信区间判据。当要证明新内核有效、测不出差异、结论反复、拿到日志却读不出结论、或分不清「有日志」和「是我们的日志」时使用。
---

# 内核验证：在这台设备上，什么才算证据

> 本文件基于 2026-10-08 ~ 2026-10-09 实机实测（boot_index 365 / 367 / 372）。
> 设备事实是快照，会随 OTA 失效；运行时的权威来源是 `device-profile.md` / `build.env`。

## Overview

这个 skill 过去回答的是「怎么测功耗性能」。现在它先回答一个更前面的问题：

> **这个数字 / 这段日志，算证据吗？**

因为在本机（小米 17 / 代号 `pudding` / 平台 `canoe` / 高通 SM8850 / Linux 6.12 GKI / Android 17 / KMI `android16-6-4k`）上，**「拿到读数」和「读出结论」之间隔着三道坎**，每一道都真实地浪费过时间：

1. **口径坎** —— 同一个「模块数」有四个值（660 / 670 / 668 / 336），混用就会得出「掉了 300 个模块」的假警报。
2. **归属坎** —— 取证分区里的日志**可能是刷机前另一个内核写的**。「有日志」≠「是我们的日志」。
3. **落盘坎** —— `mtdoops` 只在正常关机时落盘；「卡住 → 音量下+电源重启」这个动作本身**销毁现场**。

所以判据不是「测出来是多少」，而是：

> **这个差异，比这台设备的测量噪声大吗？而且，这条证据真的出自本轮内核吗？**

配套工具 `scripts/ab-stats.py` 把第一个问题变成一个数字；第二、三个问题在本 skill 的正文里。

**REQUIRED SUB-SKILL:** `safe-kernel-flash` —— 本 skill 的「第 0 步」是刷后验收；刷入与回滚本身不在这里。

## When to Use

**命中任意一条就来这里：**

- 要判断新内核是否真的省电 / 更快 / 更稳。
- 刷完要跑「开机健康检查」，需要逐字命令与期望值。
- 模块数对不上（「怎么掉了 300 个模块？」），或两个数不知道能不能比。
- 拿到了 `/sys/fs/pstore/`、oops 分区、blackbox 的日志，却判断不出是不是本轮内核写的。
- 卡第一屏想取证，但 `pstore` 空、oops 分区没有本轮记录。
- 按了「音量下 + 电源」重启之后还想找 printk / ramoops。
- 换了个 tunable，想知道有没有效果。
- 已经测了，但两次结论不一致。

**何时不用**

- 内核还没刷上去并验证过 → 先去 `safe-kernel-flash`。
- 刷完根本进不了系统（`boot_index` 没变 / `uname -r` 不是我们的）→ 这是启动失败，不是性能问题：`safe-kernel-flash` + `gki-abi-verification`。
- 只是问概念、不碰真机。

## 第 0 步：刷完立刻跑「开机健康检查」

**逐字命令与期望值**（期望值 = cctv18 树成功版实测，boot_index 365）：

```bash
# ① 跑的是不是我们的内核
uname -r                                              # 期望含 LOCALVERSION：6.12.69-android16-6-4k-<署名后缀>
grep -o 'boot_index=[0-9]*' /proc/cmdline             # 期望是本次刷入的新轮次（如 boot_index=365）

# ② 模块加载无错
dmesg | grep -ic 'disagrees about version\|Unknown symbol'   # 期望 0
lsmod | wc -l                                         # 期望 ≈670（原厂 660，必须同口径）

# ③ 关键硬件
ls /dev/dri/                                          # 期望 card0 与 renderD128
lsmod | grep -c msm_drm                               # 期望 1（显示栈，卡屏的直接嫌疑对象）
ip link | grep wlan0                                  # 期望存在
ls /dev/video0                                        # 期望存在（相机）
cat /proc/asound/cards                                # 期望 canoe-mtp-snd-card

# ④ 无崩溃
dmesg | grep -ic 'kernel panic\|Oops'                 # 期望 0
```

| 检查 | 期望值 | 不对时说明什么 |
| --- | --- | --- |
| `uname -r` | 含你的 `LOCALVERSION`（如 `-<署名后缀>`） | 没刷进去，或在跑别的槽位 / 别的轮次内核 |
| `boot_index=` | **新的一轮** | 与刷前相同 → 根本没换内核，后面别测 |
| `disagrees about version` / `Unknown symbol` | `0` | ABI 出问题（CRC 或符号），转 `gki-abi-verification` |
| `lsmod \| wc -l` | ≈`670`（原厂 `660`，同口径） | 差得多才可疑；先确认口径（见下节） |
| `/dev/dri/` | `card0` + `renderD128` | 显示栈没起来 → 卡屏根因就在这 |
| `lsmod \| grep -c msm_drm` | `1` | `0` 表示 `msm_drm.ko` 被拒载 |
| `ip link \| grep wlan0` | 存在 | ABI 最灵敏的探针（WiFi 驱动最先挂） |
| `ls /dev/video0` | 存在 | 相机链路 |
| `/proc/asound/cards` | `canoe-mtp-snd-card` | 音频链路 |
| `kernel panic` / `Oops` | `0` | 有一次就不算通过（稳定性没有平均值） |

root 顺带确认（root 在 `init_boot`，只刷 `boot` 不该掉）：`/data/adb/ksud -V` 期望 `4.2.0-1-g904c60d1`；`id` 期望 `uid=0 context=u:r:ksu:s0`。掉了也别在这里处理，转 `safe-kernel-flash`。

> **这些期望值不是通用常数**，是「这一棵树 + 这一份 `gki_defconfig` + 零 fragment」的实测快照。换树、加 fragment 后，正确判据不是「数字必须等于 670」，而是「与原厂**同口径**的差异能逐条解释」。

## 模块数：四个口径，混用就是假警报

| 口径 | 数值 | 采集方式 | 出现场合 |
| --- | --- | --- | --- |
| **A 全量** | **660** | `/proc/modules` + 可加载 `.ko` 文件 | 原厂基线 |
| **A 全量** | **670** | 同上 | boot_index 365（cctv18 首版成功） |
| **A 全量** | **668** | 同上 | boot_index 372（mi_sched 路径 A + AK3 内装 MK-Addon） |
| **B dmesg 标记** | **336** | `dmesg` 里带 `(O)` / `(OE)` 标记的模块数 | 原厂 6.12.69 + 内置 KSU 时期的实测 |

**具体场景（这个假警报真的发生过）：**

刷完先跑了一句 `dmesg | grep -c '(O)'`，得 **336**；翻到原厂基线写着 **660**，于是结论是「掉了 **324** 个模块，模块加载大面积失败」——然后去查一个根本没坏的加载链。

真相是这两个数**不是同一个口径**：660 是「`/proc/modules` + 可加载 `.ko`」的全量口径，336 只是「dmesg 里带加载标记」的那一部分。它们之间的差不是丢模块，是**数法不同**。

**规则：**

1. 对比模块数，**两端必须用同一条命令**。本项目统一用 `lsmod | wc -l`（或采集器的 `modules_loaded.txt`）。
2. 670（365）与 668（372）是**同一口径**的两个真实值。想解释这 2 个的差，要拿两次 `lsmod` 的**差集**；只看总数猜原因是无效推理 —— 目前为 `UNKNOWN`。
3. 出现「模块数腰斩」这类量级跳变时，第一个怀疑对象是**口径**，第二个才是加载失败。

## 取证归属判定：解析任何日志之前先做这一步

**方法论级规则：解析任何日志 / 取证分区之前，必须先用版本串或署名确认它出自哪一轮内核。**

三个锚，按硬度排序：

```bash
F=/sys/fs/pstore/console-ramoops-0          # 也可以是 oops 分区 dump、blackbox 段、/data/local/bootlog/kernel.log

grep -ao 'boot_index=[0-9]*' "$F" | sort -u  # ① 轮次：最硬的锚，每个 bootloader 轮次一个号
grep -ac '<署名后缀>' "$F"                       # ② 署名：LOCALVERSION 里的作者标记
grep -ac '6\.12\.69-android16-6-4k' "$F"     # ③ 版本串：uname -r 的字面值
```

- **轮次（`boot_index`）**最可信：它是启动轮次的编号，刷一次变一次。
- **署名（如 `<署名后缀>`）**只做单向排除：原厂内核**没有**这个署名，所以 `0` 匹配可以排除「这是我们的」，但「有匹配」仍需轮次确认。
- **版本串**要与本轮 `uname -r` 逐字对照。
- 三个锚一个都对不上 → **这份日志不是本轮内核写的**，基于它的所有分析作废，不要写结论。

**历史案例（浪费过一次完整排查）：** 曾在 blackbox 的第 361 段看到一份完全正常的 init 日志，当时当成「本轮内核其实跑到了 init 阶段」。复核判据：整段里 `<署名后缀>` 零匹配、`6.12.93`（当时我们的版本串）零匹配 —— 它属于**刷机前 Jianke 轮（6.12.111）**，是本轮启动时 bootmonitor 归档进来的旧日志。

> **一句话：`有日志` ≠ `是我们的日志`。**

## `mtdoops`：只有本轮正常关机才会写

`mtdoops` 是 vendor 模块，它**只在本轮内核正常关机时**把自己的日志写进 `oops` 分区。实测证据：oops 分区全部 8 条记录的尾部都是干净的关机流程：

```
Unmounting fuse path /mnt/pass_through/999/emulated
VolumeManager shutdown successed
shutdown()--, rtn: 0
```

推论：

- 卡死的轮次**没有关机路径 → 永不落盘**。
- 因此 **「oops 分区里没有我的记录」不能推出「内核没跑起来」**。它只说明：这一轮没有正常关机过。
- 反过来，「oops 分区里有记录」也**不能**推出「这一轮跑得很好」——先用上面的归属判定确认轮次。

**历史错误：** 曾据 oops 分区的一条记录推断「内核至少存活 2.1 秒、卡在显示接管前」。归属判定后发现那条记录属于**健康轮次 353**，整个时间窗推断作废。

**正确用法：** oops 分区能证明的只有「某一轮正常关机过」。用它判断崩溃，必须先用 `boot_index` 把记录钉到具体轮次。

## PSHOLD：`音量下 + 电源重启` 这个动作本身销毁现场

卡住时人（和 agent）的本能是：按住 **音量下 + 电源** → 进 fastboot → 刷回。这一步**恰好把你要的证据删掉了**：

```
PSHOLD warm reset（PMIC / 电源路径）
  → 不走内核 reboot 路径
  → 不调 panic()
  → 不触发 kmsg_dump()
  → printk 环形缓冲与 ramoops 随内存一起丢失
```

**结论：加多少 `printk` / `initcall_debug` / `loglevel=7` / `log_buf_len` 都没用。** 要拿到栈，必须让**内核自己 panic 并自动重启**，不能靠按键。

旁证（blackbox 与 dmesg 实测）：`PM: Reset by PSHOLD`，以及 `Hard watchdog permanently disabled`。曾是「修复版会自动重启 → 说明有看门狗在工作」这一判断的推翻依据 —— 那是 PSHOLD 硬复位，不是看门狗。

### 诚实的局限：本平台「让内核自己 panic」目前也拿不到证据

实测（V2 取证版，boot_index 356，卡第一屏、**没有自动重启**）：

```
CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y      已编入，未触发
CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y       已编入，未触发
CONFIG_PANIC_TIMEOUT=20                  已编入，未自动重启
CONFIG_RCU_CPU_STALL_TIMEOUT=21          已编入，未触发
# CONFIG_HARDLOCKUP_DETECTOR is not set  ← 无 NMI hardlockup（本平台 NMI 不完整支持）
# CONFIG_QCOM_WDT is not set              ← 无 QCOM 硬件看门狗驱动
watchdog_thresh = 10
```

- **四项 panic 配置一个都没触发**；运行时也没有 hardlockup 检测器与 QCOM 硬件看门狗兜底。
- 同日实测：`/sys/fs/pstore` 空；oops 分区 15MB 全量只有 352/353/355/346/347/349/350/351，**无 354、无 356**；blackbox 188MB 全量 `boot_index=` 只有 348/353/355/357，`<署名后缀>` 零匹配。
- **推断（`UNVERIFIED` —— 三条都只是解释，没有任何一条被实测证实，按可能性排序）**：① 全核冻结 / 长时段关中断，检测线程根本没机会跑；② 挂起发生在检测器就绪之前；③ 挂起时机太早，日志只进缓冲区然后随 PSHOLD 丢失。
- 所以本平台的取证边界是：**「卡第一屏 + 零证据」目前是正常结果，不是采集器坏了。** 采集器本身工作正常（15MB `oops.log` 已生成、覆盖备份已生效）——是**没东西可采**。

### 卡住后的操作规则

1. **等 ≥40 秒**，观察是否自动重启（`PANIC_TIMEOUT` 的设计意图）。实测未触发，所以这只是一次尝试，不是保证。
2. **不要反复强制重启**：每按一次就销毁一次现场。
3. 记录现象（是否自动重启、卡在哪一屏、屏幕下缘是否闪）→ 再回滚。
4. 回滚后按顺序读，**每份都先做归属判定**：`/sys/fs/pstore/` → `oops` 分区 → `blackbox`。

## 可用的观测入口清单

| 入口 | 读法 | 含义 | 陷阱 |
| --- | --- | --- | --- |
| `/sys/kernel/sched_ext/` | `ls` + `cat state` | sched_ext 调度器状态（372 实测 `state=disabled`，符合 mi_sched 路径 A 的 dormant 设计） | `disabled` ≠ 没移植成功，`late_initcall` 已注册并执行 |
| `/sys/module/build_policy/parameters/scx_mqhd_stats` | `cat` | MQHD 的 8 级 DSQ 统计（实测 DSQ 3–7 quota = `16/32/32/16/8` → MQHD 真实激活，不是死代码） | 模块 `build_policy` 没加载时该节点不存在 |
| `/dev/memcg/memory.xswapd.stat` | `cat` | `nr_ext / nr_wb / sz_wb / drop_wb / fault_wb / wake_up` | **`sz_wb` 是水位（会归零），`drop_wb` 才是累计流量** |
| `/dev/memcg/memory.mctrl.stat` | `cat` | `wb_pages` | 与 xswapd 是两个独立计数器，不要相加 |
| `/sys/block/zram0/zgroup_enable` | `cat` | 回写目标组是否建立（实测 `1`） | 与 `/dev/memcg/memory.xswapd.enable`（原厂默认 `0`）是两层闸门，别混为一谈 |
| `/sys/block/zram0/comp_algorithm` | `cat` | zram 压缩算法 | 换算法的收益必须走本 skill 的 A/B，见 `zram-compression-tuning` |
| `/sys/fs/pstore/*` | `cat` | 崩溃现场，**首选** | 先做归属判定；**空 ≠ 没崩** |
| `/data/local/bootlog/*` | `cat` | 引导日志（`bootlog.txt` / `kernel.log` / `oops.log`） | **系统起来后才可用**；卡死轮次拿不到 |

实测样值（boot_index 372）：

```
xswapd.enable = 0        nr_wb  = 3024        sz_wb  = 3431716（水位）
drop_wb       = 66845（累计）  fault_wb = 24   zgroup_enable = 1
```

**`sz_wb` 与 `drop_wb` 的坑：** 文档的早期版本曾断言「`sz_wb` 恒为 0 → 回写链路断链、从未激活」，该结论已被实测推翻。根因是把**水位**当成了**流量**：短时压力触发回写时 `sz_wb` 上升，压力解除 / 进程退出后 `zgroup_untrack_obj` 把它减回去并把量累加到 `drop_wb`。**看累计量，别看水位。**

## A/B 协议（协议错了，统计再漂亮也没用）

**唯一自变量是内核镜像。** 两端必须满足：

- 同一 vendor 分区、同一 system 版本
- 同一 root 模块集、同一已装 App 集
- **记录并比较两端的 tunable**（governor、sched 参数）

**必须交叉配对：A B A B A B …… × N，禁止 A×5 再 B×5。** 顺序测量测的是**温度漂移**，不是内核差异 —— 这是手机 A/B 测试最常见的致命错误。

其余固定项：先热身两轮；固定亮度与刷新率；关自适应电池与自适应刷新；两端网络状态一致；记录室温。

**分两个结论**（可能相反，这很正常）：

1. 把 tunable 拉平后比 → 测的是**内核本身**。
2. 各自默认值比 → 测的是**实际体验**。

## 统计判据：说人话

```bash
# 每组每行一个测量值
python3 scripts/ab-stats.py --a stock-energy.txt --b modded-energy.txt \
    --metric energy --target-delta 0.03
```

1. **先跑 3 次拿控制组 `CV = std / mean`。噪声地板就是 CV。** 后面所有判据都相对它。
2. 样本量：**`n/臂 ≈ 15.7 × (CV/Δ)²`**。CV=2% 想分辨 2% 的差异，每臂要 16 次；想分辨 5%，2–3 次就够。
3. **判据看比值的 bootstrap 95% CI 是否跨 1.0，不是 `p<0.05`。** CI 跨过 1.0 → 判「测不出来」，到此为止。
4. **`|Δ| < 2×CV` 时只能说「暂时通过，需要复测」。** 这时 CI 虽排除了 1.0，效应却贴着噪声地板，很容易被温度漂移、后台进程、频点差异伪造。

**判定顺序（不能颠倒）**：`先看 CI 跨不跨 1.0` → `再看阈值` → `最后看幅度`。

> 把幅度提到第一步，是这套方法论最容易犯的错：先拿 `2×CV` 否掉结论，会把一个已经被 CI 证实的真实小效应误判成「测不出来」。`scripts/ab-stats.py` 的早期版本就是这么写的，现在顺序已写死在脚本里。

CV=2% 的设备上，一次测量报出「省电 1.5%」：**若 CI 跨 1.0**，那是在描述随机数；**若 CI 排除 1.0 且两端是交叉配对的**，那是一个真实但微弱、必须复测的效应。这两种情况不能混为一谈。

## 证据层级与物理上限

| 层级 | 来源 | 可信度 |
| --- | --- | --- |
| 1 | `/sys/class/powercap/*/energy_uj` | **唯一真正的焦耳来源**。有它就以它为准 |
| 2 | `/sys/devices/system/cpu/cpufreq/policy*/stats/time_in_state` 频率驻留差分 | 只能说明「频率低了」，不等于「省电了」 |
| 3 | 夜间待机真实放电 mA | 变量最少的窗口，需要自动飞行、灭屏 |
| 4 | `dumpsys batterystats` | 框架**估算值**，仅作交叉校验 |

三者冲突时的信任顺序：**能量计数器 > 电池电流 > batterystats**。

**物理上限（不要假装能绕过）**：`current_now` 有 **3–4 mA 量化噪声**，短 workload 根本测不出功耗差异。只有 **≥1 小时持续负载**或**整夜待机**才有统计意义。若内核没开 `CONFIG_POWERCAP`，方案退化为「电池电流 + 温度 + 频率驻留」三件套，灵敏度显著下降 —— 这时更应该直说测不出来。

## 按类别判定

| 目标 | 通过标准 |
| --- | --- |
| **省电** | `E_uj/work` 比值 ≤0.97 且 CI 上界 <1.0；0.97–1.03 判「无差异」；>1.03 判更费电 |
| **夜间待机** | 真实放电 mA 低 ≥5%，且电池温升不 ≥0.5°C |
| **更快** | 吞吐 ≥2% 提升且 CI 下界 >0；p99 延迟劣化 ≤5%；p99.9 wakeup 延迟劣化 ≤10% |
| **更流畅** | Janky frames % 不高于原厂 |
| **更稳** | **72h 零 panic / watchdog / hard lockup / 异常重启 + 20 轮子系统回归全过** |

**稳定性没有「平均而言」**：出现任意一次 panic / watchdog / hard lockup / 异常重启，**直接判失败**。一次就够——它意味着有一部分用户会遇到。

稳定性取证（首选现场是 `pstore`，不是 `dmesg`）：

```bash
cat /sys/fs/pstore/console-ramoops-0          # 首选；先做归属判定
dmesg | grep -iE 'panic|watchdog|soft lockup|hard LOCKUP|hung task|BUG:|Oops'
cat /proc/sys/kernel/tainted
cmd bootstat print
cat /sys/power/suspend_stats/{success,fail}
```

子系统回归 20 轮：WiFi、移动数据、蓝牙、相机、快充、音频、指纹、传感器、GPU。

## 分两阶段，别一上来就测 72 小时

| 阶段 | 规模 | 何时进入下一阶段 |
| --- | --- | --- |
| Quick screen | 每端 5 次配对 | `\|Δ\| > 10%` 或效应显著 |
| Confirm | 每端 12–16 次配对 + ≥4h 熄屏待机 + 72h 挂机 | —— |

## Quick Reference

| 问题 | 命令 / 判据 |
| --- | --- |
| 刷进去没有？ | `uname -r` 含 `LOCALVERSION` + `grep -o 'boot_index=[0-9]*' /proc/cmdline` 是新轮次 |
| 模块加载有没有错？ | `dmesg \| grep -ic 'disagrees about version\|Unknown symbol'` = 0 |
| 掉了多少模块？ | `lsmod \| wc -l`，且**两端同口径**；原厂 660 |
| 显示栈起来没？ | `ls /dev/dri/` 有 `card0` + `renderD128`；`lsmod \| grep -c msm_drm` = 1 |
| 有没有崩过？ | `dmesg \| grep -ic 'kernel panic\|Oops'` = 0，再看 `/sys/fs/pstore/` |
| 这份日志是谁写的？ | `grep -ao 'boot_index=[0-9]*' <F>` + `grep -ac '<署名后缀>' <F>` + 版本串 |
| oops 分区没有我的记录？ | 说明**那一轮没正常关机**，不能推出「内核没跑起来」 |
| 卡住怎么取证？ | 不能按「音量下 + 电源」（PSHOLD 销毁现场）；只能等内核自己 panic |
| 回写在工作吗？ | `cat /dev/memcg/memory.xswapd.stat`：看 `drop_wb`（累计），不看 `sz_wb`（水位） |
| 差异算数吗？ | `bootstrap 95% CI` 跨不跨 1.0；`\|Δ\| < 2×CV` 只说「暂时」 |

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 跨口径比模块数（660 vs 336） | 得出「掉了 324 个模块」的假警报 | 两端同一条命令；统一 `lsmod \| wc -l` |
| 不确认日志归属就分析 | 把**刷机前另一个内核**的日志当本轮，白排查 | 先用 `boot_index` / 署名 / 版本串定轮次 |
| 拿「oops 分区没有我的记录」推断内核没跑起来 | 把「没正常关机」读成「内核没执行」 | `mtdoops` 只在正常关机时落盘 |
| 卡住就按「音量下 + 电源」 | PSHOLD 销毁 printk 与 ramoops | 等内核自己 panic；按键是最后的止血手段 |
| 靠加 printk 找卡点 | 环冲与 ramoops 一起丢，白加 | 先解决落盘路径，再谈加日志 |
| 把 `sz_wb` 当流量看 | 短时归零被读成「链路断链」 | 看累计量 `drop_wb` |
| 顺序测 A×5 再 B×5 | 测的是温度漂移 | 交叉配对 A B A B × N |
| 不量 CV 就下结论 | 把噪声当效应 | 先测噪声地板；`\|Δ\| < 2×CV` 只说「暂时」 |
| 用 p 值当判据 | 忽略效应量 | 看比值 CI 是否跨 1.0 |
| 拿绝对值比功耗 | 手机绝对功耗不可复现 | 全程比值 |
| 短 workload 测功耗 | 3–4 mA 量化噪声吃掉效应 | ≥1h 长负载或整夜待机 |
| 只看 `dmesg` 查稳定性 | 崩溃可能没写进 dmesg | 先看 `/sys/fs/pstore/` |
| 两端 tunable 不同还比 | 测的是配置差异不是内核 | 记录并分两种结论 |
| 出现一次 panic 仍说「基本稳定」 | 稳定性不是平均值 | 一次即失败 |

## Real-World Impact

上一版 skill 的方法论本身是对的：比值法、交叉配对、bootstrap CI、`|Δ| < 2×CV` 就认输，甚至主动承认「短负载测不出功耗，不假装能绕过」。**但它对这台设备没有任何专有知识** —— `/sys/class/powercap/`、`energy_model`、`thermal_message/sconfig` 这些路径是否存在，必须到真机上裸探。

更贵的一课来自**取证**这一侧。历史上三个被推翻的判断，全部出自同一类错误 —— **没做归属判定，也不懂落盘条件**：

| 当时的结论 | 推翻依据 |
| --- | --- |
| 「内核至少存活 2.1 秒」 | `mtdoops` 只在正常关机时落盘；那条记录属于健康轮次 353 |
| 「有看门狗在工作」 | blackbox 实测 `PM: Reset by PSHOLD`；是按键硬复位，不是看门狗 |
| 「拿到内核日志了」 | 那段是**刷机前 Jianke 轮**的日志（`<署名后缀>` 零匹配、`6.12.93` 零匹配） |

所以本版把重心从「仪器怎么读数」移到「**读数凭什么算证据**」：口径一致、归属确认、落盘路径清楚，然后才是 CV、CI 和幅度。

**这条原则适用于本仓库所有 skill：设备是权威，文档是二手。** 期望值（670 个模块、`6.12.69-android16-6-4k-<署名后缀>`、`drop_wb=66845`）都是**快照**，换树或 OTA 后会变；能长期保留的是判据和取证方法的形状，不是数字本身。
