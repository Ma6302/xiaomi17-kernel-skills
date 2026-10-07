---
name: xiaomi17-device-recon
description: 用于在小米 17（SM8850 / 骁龙 8 Elite Gen 5）或任何 A/B 分区 Android 手机上，开始编译、打包或刷写内核之前，把设备代号、内核与 KMI 世代、分区布局、当前槽位、验证启动与防回滚状态、现有 root 模式查清楚并落盘。当需要确认设备代号、内核版本、KMI 代次、slot、vbmeta/verity 状态、ARB 等级、root 补丁在哪个分区，或别的 skill 需要 device-profile.md 时使用。当在 Operit 的 proot 终端里采不到数据、KMI 或 root 模式为 UNKNOWN 时也使用。
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
| `FLASH_LOCKED` | **`/proc/bootconfig`** 的 `androidboot.vbmeta.device_state`；退化才用 `getprop ro.boot.flash.locked` | 0 才可能刷写；锁着刷自制镜像 = 硬砖 |
| `VERITY_MODE` | `getprop ro.boot.veritymode` | 决定是否要动 vbmeta |
| `ROOT_MODE` | `/data/adb/{magisk,ksu}`、`su -v`、`ksud -V`、`lsmod \| grep -i kernelsu`；`/proc/config.gz` 里 `CONFIG_KSU=y` 且 `lsmod` 无 → GKI 内置 | 决定刷自编内核之后会不会掉 root；LKM 模式拿不到 SUSFS。没有 root 就写 `none` |
| `ROOT_PARTITION` | 管理器的「安装/修补」页面写着在修补哪个镜像；没有 `init_boot` 分区的设备必然在 `boot` | **它才是刷前的「唯一退路」。** 备份错分区等于没备份。没有 root 就写 `none` |
| `ANTI_ROLLBACK_INDEX` | `ro.boot.anti`，空则 `fastboot getvar anti` | ARB 不可逆，推高就再也回不去 |

`ROOT_MODE` / `ROOT_PARTITION` 的值可以是 `none`（确实没有 root），但**不能是 UNKNOWN** —— 分不清「没有 root」和「不知道有没有 root」，是刷机事故的常见起点。在 GKI 布局里内核在 `boot`、通用 ramdisk 在 `init_boot`，所以 KernelSU 的 LKM 补丁通常在 `init_boot`：**只备份 `boot` 是最容易犯的错。**

其余记录项（型号、SoC、Android 版本、安全补丁、ROM 版本、分区清单、关键分区存在性、`verifiedbootstate`、`ro.vendor.api_level`）是为后续步骤提供上下文，缺失只记 UNKNOWN。

## 在哪里跑这个脚本

**必须在 Android 侧的 shell 里跑。** Operit 自带的 proot Ubuntu 终端看上去「也是 Linux、也是 root」，其实三样都没有：

```
$ command -v getprop   -> (无)          # proot 里没有 Android 工具
$ command -v su        -> /usr/bin/su   # 这是 Ubuntu 的 su，不是 Android 的
$ id                   -> uid=0(root)   # proot 里本来就是 root，su -c 语义完全不同
$ ls /data/adb         -> No such file or directory
$ ls /dev/block/by-name -> No such file or directory
```

而且脚本里 `su -c "…" 2>/dev/null` 会把**所有失败都吞掉**，于是每个字段都是空的，脚本却照常写出档案、照常打印「已写出」。**在那里跑不会失败，只会给你一份看起来成功的空档案。**

**正确通道**：Operit 的 Shizuku / Root 终端（不是 proot 终端），或从电脑 `--adb`。

脚本现在会在开头自检 `command -v getprop`，缺失即 fail-fast 并解释原因；另外还有一道「四条最基本的 prop 全空」的通道体检。两道闸都是 exit 3，不落盘。

## 实施

```bash
bash scripts/collect-device-facts.sh --root          # 手机上运行，多数设备需要 su 才能列 /dev/block/by-name
bash scripts/collect-device-facts.sh --adb           # 或从电脑经 adb
bash scripts/collect-device-facts.sh --root --backup # 顺带把 boot/init_boot/vendor_boot/dtbo/vbmeta dd 到 backup/
```

脚本是纯只读的：它只 `getprop`、读 `/proc/bootconfig`、`uname`、`ls`、`modinfo`，以及在 `--backup` 时从分区 `dd` **出来**。它永远不往分区写。

fastboot 侧的三条命令脚本跑不了，必须人工补齐并回填：

```bash
fastboot devices                    # 只允许一台设备
fastboot oem device-info            # 期望 Device unlocked: true
fastboot getvar anti                # 空值就写 UNKNOWN，并当作高危
```

## KMI 世代从哪来：不要只信 `uname -r`

**跑第三方内核的设备上，`uname -r` 里的 `androidNN` 标记会消失** —— 编那个内核的人改过 `CONFIG_LOCALVERSION`。只从 `uname -r` 解析，KMI 就恒为 UNKNOWN，整份档案被误判成 BLOCKED，而设备其实什么毛病都没有。

权威来源是 **vendor 模块的 vermagic** —— 它是编 `.ko` 时固化进去的，换内核不会改它，而它恰恰就是「你的新内核必须满足谁」的答案：

```bash
modinfo -F vermagic /vendor_dlkm/lib/modules/adsp_loader_dlkm.ko
# -> 6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64
#    KMI 世代 = android16
```

取不到 `modinfo` 时用 `strings` 兜底：

```bash
strings /vendor_dlkm/lib/modules/adsp_loader_dlkm.ko | grep -oE 'android[0-9]+-[0-9]+-[0-9]+k' | head -n1
```

兜底顺序：**vermagic → `uname -r` → `ro.boot.kmi`**。三者都取不到才写 UNKNOWN。三个来源**同时记录**（`KMI_FROM_VERMAGIC` / `KMI_FROM_UNAME` / `KMI_FROM_PROP`），不一致时脚本会在档案里出「KMI 世代来源不一致」警告 —— 不一致本身就是信息（换过内核或换过 vendor 分区），不要随手挑一个用。

顺带一个推论：`uname -r` 里**没有** `androidNN`，说明当前内核**不是原厂 GKI 构建**。那么现在 `dd` 出来的 `boot` 备份**也不是原厂镜像** —— 它只能带你回到上一个第三方内核。要真正的退路，得从与当前 ROM 版本、ARB 指数都一致的官方 fastboot ROM 里取原厂 `boot.img` / `init_boot.img`。

## getprop 在已 root 的设备上不可信

装了隐藏模块（`tricky_store` / `playintegrityfix` / `YH_YC` 之类）的设备上，`resetprop` 会**伪造**这两个属性：

| 属性 | 被伪造的输出 | 真值（`/proc/bootconfig`） |
| --- | --- | --- |
| `ro.boot.flash.locked` | `1`（已锁定） | `androidboot.vbmeta.device_state = "unlocked"` |
| `ro.boot.verifiedbootstate` | `green` | `androidboot.verifiedbootstate = "orange"` |

`/proc/bootconfig` 是内核启动时收到的参数，`resetprop` 改不到它。**`FLASH_LOCKED` 直接用来判断「能不能刷」，判反了就是硬砖**，所以一律先读 `/proc/bootconfig`，getprop 只作回退和对照。

注意两个字段的语义是反的：`ro.boot.flash.locked` 是 `1=锁`，而 `vbmeta.device_state` 是 `unlocked` / `locked`。

## Quick Reference

| 想知道 | 命令 |
| --- | --- |
| 代号 | `getprop ro.product.device` |
| 内核 release | `uname -r` |
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
| ARB | `fastboot getvar anti` |

## 小米 17 的已知坑

- **代号必须实测。** 公开资料曾经互相矛盾，现在有了更可靠的对照，但**仍然以 `ro.product.device` 为准**：`pudding` = 小米 17、`pandora` = 小米 17 Pro、`popsicle` = 小米 17 Pro Max；三者同属平台 **`canoe`**（内核树里 `target_variants.bzl` 的映射为 `{"popsicle":"canoe","pandora":"canoe","pudding":"canoe"}`）。注意「小米 17 系列」不等于代号——`MiCode` 的 `popsicle-w-oss` 分支名容易被误读成「小米 17」，实际对应的是 Pro Max。同 SoC 家族另有 `nezha`(17 Ultra)、`annibale`(K90)、`myron`(K90 Pro Max)。**代号的用途是给 `device.name1`、defconfig/target 名和 `getvar` 校验用；写错等于防呆失效。**
- **KMI 与 Android 版本不是一回事。** 已知对照：Android 16 常见 Linux `6.12.23`、Android 17 常见 Linux `6.12.69`，但**这条对照本身只来自社区线程**，且 OEM 分支与 GKI 主线不必同步（AOSP 的 Android 17 分支是 `android17-6.18`，而小米 17 的 Android 17 仍是 6.12）。所以要读实测的 vermagic，不要用 `ro.build.version.release` 反推，也不要靠推 Android 版本得出 KMI。
- **ARB 常常读不到。** `ro.boot.anti` 在新机型上经常为空，这不是「没有 ARB」，而是「未知」。未知就按最高危处理：不要刷任何比当前版本旧的官方包，不要用「降级」当回滚手段。
- **A/B 设备有两套分区。** 备份和刷写都要带槽位后缀，只碰当前槽。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 在 Operit 的 **proot 终端**里跑采集 | 不报错，静默产出一份全 UNKNOWN 的档案，看着像成功 | 用 Shizuku / Root 终端或 `--adb`；脚本的两道闸就是为此 |
| 把「写出了档案」当成「档案是对的」 | 后面每一步都建在空字段上 | 看结论行与 `REQUIRED 字段缺：…` 那行；exit 3 就是 BLOCKED |
| **只从 `uname -r` 解析 KMI** | 第三方内核上恒为 UNKNOWN，误 BLOCK | 优先 `modinfo -F vermagic` 读 vendor 模块 |
| 从 mifirm/XDA 抄代号 | defconfig 名、`device.name1` 全错，AK3 直接 abort 或刷到错误机型 | 读 `ro.product.device` |
| 用 `ro.build.version.release` 推 KMI | 选错 GKI 分支 | 读 vendor 模块 vermagic |
| **用 `getprop ro.boot.flash.locked` 判断能不能刷** | 隐藏模块把它伪造成 `1`，而设备其实已解锁 | 读 `/proc/bootconfig` 的 `vbmeta.device_state` |
| **拿当前 `boot` 当原厂备份** | 当前已是第三方内核时，这份备份回不到出厂状态 | 从同版本官方 fastboot ROM 取原厂 `boot.img` / `init_boot.img` |
| 跳过 ARB | 想靠「刷回旧版」回滚时发现熔丝已烧，永久无法降级 | 先记 ARB 指数；未知即高危 |
| 备份留在手机上 | 手机开不了机时备份也拿不出来 | `--backup` 后必须拷到电脑 + 云盘 |
| 把 `device-profile.md` 提交进仓库 | 泄露设备标识 | 它在运行时目录，`.gitignore` 已覆盖 |
| 只备份 `boot`，而 root 补丁其实在 `init_boot` | 以为有退路，真出事时备份里根本没有 root | 先确认 `ROOT_PARTITION`，备份补丁所在的那个分区 |
| 把「没有 root」和「不知道有没有 root」混为一谈 | 该备份的没备份，或该停下的继续走 | `ROOT_MODE` 只能是 `none` 或具体方案，不能是 UNKNOWN |

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

## 产出示例

`device-profile.md` 的结论行只有两种：

- `**READY**：device=…，kmi=…，slot=…，内核=…` → 可以进入下一步。
- `**BLOCKED**：device 或 KMI 世代仍是 UNKNOWN` → 不允许开始编译或刷写。

一个真实例子（2026-10-07，小米 17，第三方内核，KMI 靠 vermagic 才查出来）：

```
KERNEL_RELEASE=6.12.111-Jianke          # 无 androidNN → 不是原厂构建
KMI_GENERATION=android16                # 来自 vendor 模块 vermagic，不是 uname -r
KMI_FROM_UNAME=                          # 空 —— 只信 uname 就会误 BLOCK
FLASH_LOCKED=0                          # 来自 /proc/bootconfig；getprop 谎报 1
SPOOF_WARNING=getprop ro.boot.flash.locked=1 与 /proc/bootconfig 的 unlocked 矛盾…
ROOT_MODE=kernelsu-lkm
ROOT_PARTITION=init_boot(推断…)
```
