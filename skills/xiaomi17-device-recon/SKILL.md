---
name: xiaomi17-device-recon
description: 用于在小米 17（SM8850 / 骁龙 8 Elite Gen 5）或任何 A/B 分区 Android 手机上，开始编译、打包或刷写内核之前，把设备代号、内核与 KMI 世代、分区布局、当前槽位、验证启动与防回滚状态、现有 root 模式、boot_index 轮次编号查清楚并落盘。当需要确认设备代号、内核版本、KMI 代次、slot、vbmeta/verity 状态、ARB 等级、root 补丁在哪个分区、当前跑的是哪一轮、模块数是什么口径，或别的 skill 需要 device-profile.md 时使用。当在 Operit 的 proot 终端里采不到数据、KMI 或 root 模式为 UNKNOWN，或要判断一段内核日志 / 取证分区出自哪一轮时也使用。
---

# 设备侦察

## Overview

机型代号、内核版本、KMI 世代、分区布局、当前槽位、验证启动状态、ARB 等级和现有 root 方案，**都必须从设备上读出来，不能从网上查、不能从营销名推断、不能沿用上一次的结果**。本 skill 的唯一产出是一份落盘的设备档案；后续每一个 skill 都从这份档案读取事实，不各自重新猜。

**档案的「有」和「对」是两件事。** 这个脚本最危险的失败模式不是报错，而是**静默写出一份全 UNKNOWN 的档案并正常退出** —— 看起来采集成功了，实际每一项都是空的。所以本 skill 有一半篇幅在讲「怎么确认采集通道本身是通的」。

## When to Use

- 准备编译、打包或刷写内核之前的第一个动作。
- 换机型、换 ROM、系统 OTA、恢复出厂、换槽位、刷过第三方内核之后。
- 任何 skill 需要 `device-profile.md` 而它不存在、或它的 `SECURITY_PATCH` / `KERNEL_RELEASE` 与当前设备不符时。
- 用户提到「小米 17」「pudding」「popsicle」「SM8850」「骁龙 8e5」「KMI」「slot」「vbmeta」「ARB」时。
- 采集结果出现 `UNKNOWN`、或你怀疑采集环境不对（尤其在 Operit 的 proot 终端里跑过之后）时。

**何时不用**：只是问概念、不碰设备时。

## 必须产出

写到运行时目录（默认 `/sdcard/Download/Operit/kernel-dev/`）：

- `device-profile.md` — 给人看的事实表。
- `build.env` — 给脚本 `source` 的机器可读版本。

下列字段**一个都不能是 UNKNOWN**，否则任务停在 BLOCKED，不得继续：

| 字段 | 来源 | 为什么必须要 |
| --- | --- | --- |
| `DEVICE` | `getprop ro.product.device` | 决定 defconfig 名、`device.name1`、源码分支 |
| `KERNEL_RELEASE` | `uname -r` | 完整版本串；**也是判断当前是不是原厂内核的依据** |
| `KMI_GENERATION` | ①`/vendor_dlkm/lib/modules/*.ko` 的 vermagic ②`uname -r` 里的 `androidNN` ③`ro.boot.kmi` | 决定编/刷哪个 KMI 分支；KMI 不匹配 = vendor 模块拒载 |
| `SLOT` | `getprop ro.boot.slot_suffix` | 只刷当前活动槽，是唯一的回退保险 |
| `BOOT_INDEX` | `grep -o 'boot_index=[0-9]*' /proc/cmdline` | **第五个关键标识，也是唯一不会撒谎的「这是哪一次开机」编号。** 刷机前后各记一次；失败时靠它对齐日志归属。`/proc/cmdline` 里没有这个标记时写 `NONE`（设备差异），**不是** UNKNOWN |
| `FLASH_LOCKED` | **`/proc/bootconfig`** 的 `androidboot.vbmeta.device_state`；退化才用 `getprop ro.boot.flash.locked` | 0 才可能刷写；锁着刷自制镜像 = 硬砖 |
| `VERITY_MODE` | `getprop ro.boot.veritymode` | 决定是否要动 vbmeta |
| `ROOT_MODE` | `/data/adb/{magisk,ksu}`、`su -v`、`ksud -V`、`lsmod \| grep -i kernelsu`；`/proc/config.gz` 里 `CONFIG_KSU=y` 且 `lsmod` 无 → GKI 内置 | 决定刷自编内核之后会不会掉 root；LKM 模式拿不到 SUSFS。没有 root 就写 `none` |
| `ROOT_PARTITION` | 管理器的「安装/修补」页面写着在修补哪个镜像；没有 `init_boot` 分区的设备必然在 `boot` | **它才是刷前的「唯一退路」。** 备份错分区等于没备份。没有 root 就写 `none` |
| `ANTI_ROLLBACK_INDEX` | `ro.boot.anti`，空则 `fastboot getvar anti` | ARB 不可逆，推高就再也回不去 |

`ROOT_MODE` / `ROOT_PARTITION` 可以是 `none`（确实没有 root），但**不能是 UNKNOWN** —— 分不清「没有 root」和「不知道有没有 root」，是刷机事故的常见起点。

`BOOT_INDEX` 同理，三种取值含义不同：具体数字 = 这一轮的开机编号；`NONE` = `/proc/cmdline` 读得到但没有这个标记（设备差异，可以继续）；`UNKNOWN` = `/proc/cmdline` 根本没读出来（采集通道没工作，**停下**）。把 `NONE` 写成 UNKNOWN 会误 BLOCK，把 UNKNOWN 当成 NONE 会把通道故障带进后面的排查。

其余记录项（型号、SoC、Android 版本、安全补丁、ROM 版本、分区清单、关键分区存在性、`verifiedbootstate`、`ro.vendor.api_level`）是为后续步骤提供上下文，缺失只记 UNKNOWN。

## 在哪里跑这个脚本

**必须在 Android 侧的 shell 里跑。** Operit 自带的 proot Ubuntu 终端看上去「也是 Linux、也是 root」，其实 `command -v getprop` 为空、`su` 是 Ubuntu 的 `/usr/bin/su`（`su -c` 语义完全不同）、`/data/adb` 与 `/dev/block/by-name` 都不存在。

更糟的是脚本里 `su -c "…" 2>/dev/null` 会把**所有失败都吞掉** —— 每个字段都是空的，脚本却照常写出档案。**在那里跑不会失败，只会给你一份看起来成功的空档案。**

**正确通道**：Operit 的 Shizuku / Root 终端（不是 proot 终端），或从电脑 `--adb`。

脚本有三道闸：`command -v getprop` 自检（缺失即 fail-fast）、`uname -s` 是 `MINGW*|MSYS*|CYGWIN*`（Windows 的 Git bash，`/sdcard/...` 根本不存在）时报错、以及「四条最基本的 prop 全空」的通道体检。三道闸都是 exit 3，不落盘。

## 实施

```bash
bash scripts/collect-device-facts.sh --root          # 手机上运行，多数设备需要 su 才能列 /dev/block/by-name
bash scripts/collect-device-facts.sh --adb           # 或从电脑经 adb
bash scripts/collect-device-facts.sh --root --backup # 顺带把 boot/init_boot/vendor_boot/dtbo/vbmeta dd 到 backup/
```

脚本是纯只读的：它只 `getprop`、读 `/proc/bootconfig`、`uname`、`ls`、`modinfo`，以及在 `--backup` 时从分区 `dd` **出来**。它永远不往分区写。

fastboot 侧三条脚本跑不了的命令，必须人工补齐并回填：`fastboot devices`（只允许一台设备）、`fastboot oem device-info`（期望 `Device unlocked: true`）、`fastboot getvar anti`（空值就写 UNKNOWN 并当作高危）。

## KMI 世代从哪来：不要只信 `uname -r`

**跑第三方内核的设备上，`uname -r` 里的 `androidNN` 标记会消失** —— 编那个内核的人改过 `CONFIG_LOCALVERSION`。只从 `uname -r` 解析，KMI 就恒为 UNKNOWN，整份档案被误判成 BLOCKED，而设备其实什么毛病都没有。

权威来源是 **vendor 模块的 vermagic** —— 它是编 `.ko` 时固化进去的，换内核不会改它，也正是「你的新内核必须满足谁」的答案。取法：`modinfo -F vermagic /vendor_dlkm/lib/modules/adsp_loader_dlkm.ko`，实测输出 `6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64` → KMI 世代 = `android16`。

取不到 `modinfo` 时用 `strings` 兜底：`strings <某个 vendor .ko> | grep -oE 'android[0-9]+-[0-9]+-[0-9]+k' | head -n1`。

兜底顺序：**vermagic → `uname -r` → `ro.boot.kmi`**。三者都取不到才写 UNKNOWN。三个来源**同时记录**（`KMI_FROM_VERMAGIC` / `KMI_FROM_UNAME` / `KMI_FROM_PROP`），不一致时脚本会在档案里出「KMI 世代来源不一致」警告 —— 不一致本身就是信息（换过内核或换过 vendor 分区），不要随手挑一个用。

推论：`uname -r` 里**没有** `androidNN`，说明当前内核不是原厂 GKI 构建，那么现在 `dd` 出来的 `boot` 备份**也不是原厂镜像** —— 它只能带你回到上一个第三方内核。要真正的退路，得从与当前 ROM 版本、ARB 指数都一致的官方 fastboot ROM 里取原厂 `boot.img` / `init_boot.img`。

## boot_index：判断「现在跑的是哪一轮」

`uname -r` 可以被编内核的人改，`getprop` 可以被隐藏模块伪造，**只有 `boot_index` 是 bootloader 每开一次机就加一的硬编号**，注入在 `/proc/cmdline` 里：不需要 root、不需要 fastboot、`resetprop` 也改不到它。

```bash
grep -o 'boot_index=[0-9]*' /proc/cmdline      # -> boot_index=372
```

实测序列（2026-10-07 ~ 2026-10-09，同一台 `pudding`）：原厂 357 → V1(AOSP 树,卡第一屏) 354 → V2(AOSP 树,卡第一屏) 356 → 修复版(ABI 对齐,卡屏重启循环) 361/362 → 成功版(cctv18 树) 365 → zstd/lz4 367 → mi_sched 372。

**它编号的是「开机事件」，不是「镜像」。** 原厂 357 反而大于 V1 的 354，就是因为刷回旧镜像同样会拿到一个更大的新编号。所以：

- **单看 `boot_index` 判断不出跑的是哪个镜像**，必须与 `uname -r` 配对记录（成功版 = `6.12.69-android16-6-4k-<你的署名后缀>` + `365`）。
- 它是排查失败时的对齐锚点：内核日志、`mtdoops` 记录、blackbox 分段都按轮次切开，没有这个编号就分不清哪一段是自己的（见下面的「取证」一节）。
- **刷机前记一次，刷机后立刻再记一次。** 刷后 `boot_index` 没有变，说明这次刷写根本没生效（写错槽、包没写进去），而不是「内核没启动」—— 这两件事的下一步动作完全不同。

## getprop 在已 root 的设备上不可信

装了隐藏模块（`tricky_store` / `playintegrityfix` / `YH_YC` 之类）的设备上，`resetprop` 会**伪造**这两个属性 —— 实测 `ro.boot.flash.locked` 谎报 `1`（已锁定，实际 `unlocked`）、`ro.boot.verifiedbootstate` 谎报 `green`（实际 `orange`）。

`/proc/bootconfig` 是内核启动时收到的参数，`resetprop` 改不到它。**`FLASH_LOCKED` 直接用来判断「能不能刷」，判反了就是硬砖**，所以一律先读 `/proc/bootconfig`，getprop 只作回退和对照。注意两个字段的语义是反的：`ro.boot.flash.locked` 是 `1=锁`，而 `vbmeta.device_state` 是 `unlocked` / `locked`。

完整对照表、`resetprop` 为什么改不到 `/proc/bootconfig`、以及误判清单：`references/bootconfig-vs-getprop.md`。

## root 模式的确证：KernelSU LKM 在 `init_boot`

`ROOT_MODE=kernelsu-lkm` 不能靠「装了 KernelSU 管理器」推出来，要从**分区内容和运行痕迹**读出来（实测 2026-10-08：`ksud -V` = `4.2.0-1-g904c60d1 (uapi: 2)`、`id` 的 context = `u:r:ksu:s0`、`init_boot` 解包后首屏 `init` 只有 607 KB 的 wrapper）。

首屏 `init` 只有 607 KB、真 init 改名成 `init.real` 有 2.81 MB —— **这就是「补丁在 `init_boot`」的直接证据**，不是推断（完整解包清单见 `references/probed-facts-20261008.md`）。两条必须记住的结论：

- **只刷 `boot` 不会掉 root。** 实测两次（`boot_index` 365 零调优版、372 mi_sched 版）：换掉 `boot` 里的 `Image`、`init_boot` 一个字节没动，root 完好。成功版构建走的就是「不内置 KSU、只换 `Image`」这条路。
- **`ksud boot-restore` 会拒绝工作。** 它靠 `init_boot` 里的 `stock_image.sha1`（40 B）校验原始 `boot` 有没有被改过；`boot` 被自编内核换掉后 sha1 必然不匹配 → 它拒绝还原。**不要把 `ksud boot-restore` 当成回滚路径**，回滚只能由人在 PC 上 `fastboot flash boot_a <stock-boot.img>`。

## 模块数：先对齐口径，再比较

「模块数掉了 300 个」这种结论**几乎总是口径错误**，不是故障。同一台设备上同时存在好几个都被叫做「模块数」的数字（实测四套口径：`/proc/modules` 行数原厂 660 / 自编成功版 670 / 另一版构建 668 / `dmesg` 里带 `(O)`、`(OE)` 标记的行数 336，明细见 `references/probed-facts-20261008.md`）。

**只有口径相同的两个数字才能相减。** 拿 `dmesg` 的 336 去比 `/proc/modules` 的 660，就会得出「少了 324 个模块」的假警报 —— 而真相是它们数的根本不是同一批东西。

同口径、可复现的三条判据：`cat /proc/modules | wc -l`（已加载）、`ls /vendor_dlkm/lib/modules/*.ko | wc -l`（可加载，原厂 404）、`dmesg | grep -ic 'disagrees about version\|Unknown symbol'`（**期望 0 —— 这才是真故障判据**）。

**模块总数不是故障判据**，版本不符 / 未知符号的计数才是。看到模块数变化，先问「这是哪条命令数出来的、上一轮是不是同一条命令」。

## 取证：先判归属，再读内容

**解析任何取证分区 / 日志之前，必须先确定这段日志出自哪一轮内核。** 跳过这一步，就会把别人（尤其是刷机前那个内核）的日志当成自己的，然后为一条不存在的故障排查很久。**「有日志」≠「是我们的日志」。**

**归属判据** —— 拿本轮构建独有的特征串去过滤那段日志：

```bash
grep -c '<你的署名后缀>' <log>        # 本轮的 CONFIG_LOCALVERSION 署名
grep -c '6.12.93'   <log>            # 非本轮的主线 SUBLEVEL（成功版是 6.12.69）
grep -o 'boot_index=[0-9]*' <log>    # 日志里带的话，直接对齐轮次
```

`<你的署名后缀>` 是**每个构建者自己取的 `CONFIG_LOCALVERSION` 后缀**，同时也是「内核身份守卫」认自己内核的判据 —— **不要照抄别人的**。

判据必须是**本轮独有**的串：署名后缀、`6.12.69`、`android16-6-4k`、构建时间戳。反面做法是看到 `Linux version 6.12` 就认领 —— 刷机前那个内核也是 6.12。真实病例（在 blackbox 的 361 段看到完全正常的 init 日志，实际那是刷机前 Jianke 轮被本轮 bootmonitor 归档进来的日志，判据是整段里署名后缀与 `6.12.93` 双双零匹配）见 `references/probed-facts-20261008.md`。

### `mtdoops` 的坑

`mtdoops` 写的是**本轮内核正常关机时**的本轮日志。**卡死的轮次没有关机路径 → 永远不会落盘。**

所以「oops 分区里没有我的记录」**不能**推出「内核没跑起来」；反过来，分区里存在的记录也可能属于别的健康轮次（实测覆盖、`boot_index` 353 的病例、以及「修复版的重启是 `PM: Reset by PSHOLD` 硬复位，dmesg 有 `Hard watchdog permanently disabled`，**不是看门狗在工作**」见 `references/probed-facts-20261008.md`）。

## Quick Reference

| 想知道 | 命令 |
| --- | --- |
| 代号 | `getprop ro.product.device` |
| 内核 release | `uname -r` |
| **这是哪一次开机（第五标识）** | `grep -o 'boot_index=[0-9]*' /proc/cmdline` |
| **KMI 世代（首选）** | `modinfo -F vermagic /vendor_dlkm/lib/modules/*.ko \| head -1` |
| KMI 世代（兜底） | `uname -r` 里的 `androidNN`；空则 `getprop ro.boot.kmi` |
| 当前是否原厂内核 | `uname -r` 里有没有 `androidNN` 标记 |
| 槽位 | `getprop ro.boot.slot_suffix`（`_a` / `_b`） |
| **BL 状态（真值）** | `grep vbmeta.device_state /proc/bootconfig` |
| BL 状态（可能被伪造） | `getprop ro.boot.flash.locked`（0=解锁） |
| **验证启动（真值）** | `grep verifiedbootstate /proc/bootconfig` |
| 验证启动（可能被伪造） | `getprop ro.boot.verifiedbootstate` |
| verity | `getprop ro.boot.veritymode`（enforcing/disabled） |
| 现有 root | `ls /data/adb/{magisk,ksu}`、`su -v`、`ksud -V` |
| LKM 还是 GKI 内置 | `su -c 'lsmod \| grep -i kernelsu'`；`zcat /proc/config.gz \| grep '^CONFIG_KSU='` |
| root 补丁在哪个分区 | 管理器「安装/修补」页写的目标镜像（权威）；`ls /dev/block/by-name` 看有无 `init_boot` |
| 分区清单 | `ls /dev/block/by-name` |
| 分区实际挂点 | `readlink -f /dev/block/by-name/boot_a` |
| 已加载模块数（口径 A） | `cat /proc/modules \| wc -l` |
| 可加载模块数（口径 B） | `ls /vendor_dlkm/lib/modules/*.ko \| wc -l` |
| 模块是否真出问题 | `dmesg \| grep -ic 'disagrees about version\|Unknown symbol'`（期望 0） |
| 日志归属判定 | `grep -c '<你的署名后缀>' <log>`、`grep -c '6.12.93' <log>`（零匹配 = 不是本轮） |
| ARB | `fastboot getvar anti` |

## 小米 17 的已知坑

- **代号必须实测，以 `ro.product.device` 为准**（公开资料曾经互相矛盾）：`pudding` = 小米 17、`pandora` = 小米 17 Pro、`popsicle` = 小米 17 Pro Max，三者同属平台 **`canoe`**（内核树 `target_variants.bzl` 实测）。**代号用在 `device.name1`、defconfig/target 名与 `getvar` 校验上；写错等于防呆失效。**
- **KMI 与 Android 版本不是一回事。** 要读实测的 vermagic，不要用 `ro.build.version.release` 反推，也不要靠推 Android 版本得出 KMI —— OEM 分支与 GKI 主线不必同步。**本机实测就是反例本身**：OS = Android 17（SDK 37），KMI 名 = `android16-6-4k`，Linux 主线 = `6.12` —— 三个数字互不相同，谁也推不出谁。
- **ARB 常常读不到，读不到就是 UNKNOWN，不是「没有」。** `ro.boot.anti` 为空只说明这条路径读不到，要确定必须 `fastboot getvar anti`。侧面证据是 blackbox 的 `stored_rollback_index is: 1`，在 `boot_index` 361 / 362 / 364 多轮中一致；**但刷 `boot` 不涉及 ARB 计数，所以这证明不了「ARB 不会变」**。一律按高危处理：不刷旧版官方包，不用「降级」当回滚，绝不整包 `flash_all`。
- **A/B 设备有两套分区。** 备份和刷写都要带槽位后缀，只碰当前槽。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 在 Operit 的 **proot 终端**里跑采集 | 不报错，静默产出一份全 UNKNOWN 的档案，看着像成功 | 用 Shizuku / Root 终端或 `--adb`；脚本的三道闸就是为此 |
| **只从 `uname -r` 解析 KMI** | 第三方内核上恒为 UNKNOWN，误 BLOCK | 优先 `modinfo -F vermagic` 读 vendor 模块 |
| **用 `getprop ro.boot.flash.locked` 判断能不能刷** | 隐藏模块把它伪造成 `1`，而设备其实已解锁 | 读 `/proc/bootconfig` 的 `vbmeta.device_state` |
| **拿当前 `boot` 当原厂备份** | 当前已是第三方内核时，这份备份回不到出厂状态 | 从同版本官方 fastboot ROM 取原厂 `boot.img` / `init_boot.img` |
| 跳过 ARB | 想靠「刷回旧版」回滚时发现熔丝已烧，永久无法降级 | 先记 ARB 指数；未知即高危 |
| 备份留在手机上 | 手机开不了机时备份也拿不出来 | `--backup` 后必须拷到电脑 + 云盘 |
| 把 `device-profile.md` 提交进仓库 | 泄露设备标识 | 它在运行时目录，`.gitignore` 已覆盖 |
| 只备份 `boot`，而 root 补丁其实在 `init_boot` | 以为有退路，真出事时备份里根本没有 root | 先确认 `ROOT_PARTITION`，备份补丁所在的那个分区 |
| 把「没有 root」和「不知道有没有 root」混为一谈 | 该备份的没备份，或该停下的继续走 | `ROOT_MODE` 只能是 `none` 或具体方案，不能是 UNKNOWN |
| **拿两个不同口径的模块数相减** | 得出「掉了 300 个模块」的假警报，去查一个不存在的故障 | 同口径比较；真判据是 `dmesg` 的版本不符 / 未知符号计数（期望 0） |
| **不判归属就读取证日志 / 分区** | 把刷机前那个内核的日志当成自己的，为不存在的故障排查很久 | 先用署名后缀、SUBLEVEL 这类本轮独有的串过滤，零匹配就不是本轮 |
| 看到 oops 分区里没有自己的记录，就断定「内核没跑起来」 | 结论可能是反的：卡死轮次没有关机路径，`mtdoops` 永远不会落盘 | 没有记录不构成证据；有记录也可能属于健康轮次 |
| 只记 `uname -r`，不记 `boot_index` | 日志、轮次、「刷写到底生效没有」全对不上号 | 刷机前后各记一次 `boot_index`，与 `uname -r` 配对 |
| 用 `ksud boot-restore` 当回滚路径 | `stock_image.sha1` 不匹配，它直接拒绝工作 | 回滚靠 PC 上 `fastboot flash boot_a <stock-boot.img>` |
| 把 `ro.boot.anti` 为空当成「没有 ARB」 | 以为可以降级回滚，实际可能触发不可逆的防回滚 | 空 = UNKNOWN；要确定必须 `fastboot getvar anti`，未知即高危 |

## Red flags

出现以下任何一条，停下来补齐档案再说：

- 档案里的 `DEVICE` 是「小米17」「Xiaomi 17」这类营销名，而不是一个代号。
- `KMI_GENERATION` 是空的或 `UNKNOWN`，**而你没有先去看 vendor 模块的 vermagic**。
- 档案里出现「getprop 被隐藏模块伪造」的警告，而你还打算用 getprop 的值做判断。
- 说了「A/B 设备」却不知道当前是 a 还是 b。
- 不知道 ARB 指数，却已经打算「不行就刷回旧版」。
- 不知道 root 补丁在 `boot` 还是 `init_boot`，却已经打算刷自编内核。
- 准备用「刷回备份的 `boot`」来恢复原厂，而当前内核本来就不是原厂的。
- 把 `device-profile.md` 里的日期当成了摆设 —— 它只代表采集那一刻。
- 说不清当前 `boot_index` 是多少，却已经要开始分析一段内核日志。
- 拿两条不同命令数出来的模块数相减，并据此宣布「模块掉了」。
- 取证分区里没有本轮记录，就断定「内核根本没启动」。
- 打算用 `ksud boot-restore`、或「刷回旧版」当回滚路径。

## 产出示例

`device-profile.md` 的结论行只有两种：

- `**READY**：device=…，kmi=…，slot=…，boot_index=…，内核=…` → 可以进入下一步。
- `**BLOCKED**：device、KMI 世代或 boot_index 仍是 UNKNOWN` → 不允许开始编译或刷写。

一个真实例子（2026-10-07，小米 17，第三方内核 `6.12.111-Jianke`，KMI 靠 vendor 模块 vermagic 才查出来、`uname -r` 那条路径为空 —— 只信 `uname -r` 就会误 BLOCK；完整 `build.env` 见 `references/probed-facts-20261008.md`）。

### 分区实测快照（**不是机型常量**）

`sdeNN` 节点编号、分区字节数、任何 `md5` 都只属于采到它的那台设备那一次。**绝不写成「小米 17 都如此」的断言** —— 刷一次机、OTA 一次就全变了。要的永远是本机现在的值：`readlink -f /dev/block/by-name/<part>`、`md5sum`。

2026-10-08 那次实测的完整分区表、字节数、`md5`，以及为什么 `sdeNN` 不能硬编码：`references/probed-facts-20261008.md`（**快照，只用来理解量级，不是判断依据**）。
