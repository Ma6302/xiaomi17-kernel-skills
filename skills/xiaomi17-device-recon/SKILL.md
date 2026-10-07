---
name: xiaomi17-device-recon
description: 用于在小米 17（SM8850 / 骁龙 8 Elite Gen 5）或任何 A/B 分区 Android 手机上，开始编译、打包或刷写内核之前，把设备代号、内核与 KMI 世代、分区布局、当前槽位、验证启动与防回滚状态查清楚并落盘。当需要确认设备代号、内核版本、KMI 代次、slot、vbmeta/verity 状态、ARB 等级，或别的 skill 需要 device-profile.md 时使用。
---

# 设备侦察

## Overview

机型代号、内核版本、KMI 世代、分区布局、当前槽位、验证启动状态和 ARB 等级，**都必须从设备上读出来，不能从网上查、不能从营销名推断、不能沿用上一次的结果**。本 skill 的唯一产出是一份落盘的设备档案；后续每一个 skill 都从这份档案读取事实，不各自重新猜。

## When to Use

- 准备编译、打包或刷写内核之前的第一个动作。
- 换机型、换 ROM、系统 OTA、恢复出厂、换槽位之后。
- 任何 skill 需要 `device-profile.md` 而它不存在、或它的 `SECURITY_PATCH` / `KERNEL_RELEASE` 与当前设备不符时。
- 用户提到「小米 17」「pudding」「popsicle」「SM8850」「骁龙 8e5」「KMI」「slot」「vbmeta」「ARB」时。

**何时不用**：只是问概念、不碰设备时。

## 必须产出

写到运行时目录（默认 `/sdcard/Download/Operit/kernel-dev/`）：

- `device-profile.md` — 给人看的事实表。
- `build.env` — 给脚本 `source` 的机器可读版本。

下列字段**一个都不能是 UNKNOWN**，否则任务停在 BLOCKED，不得继续：

| 字段 | 来源 | 为什么必须要 |
| --- | --- | --- |
| `DEVICE` | `getprop ro.product.device` | 决定 defconfig 名、`device.name1`、源码分支 |
| `KERNEL_RELEASE` | `uname -r` | 完整版本串，含 `-androidNN-` 与 KMI 后缀 |
| `KMI_GENERATION` | 从 `uname -r` 解析 `androidNN` | 决定刷哪个 KMI 分支；KMI 不匹配＝vendor 模块拒载 |
| `SLOT` | `getprop ro.boot.slot_suffix` | 只刷当前活动槽，是唯一的回退保险 |
| `FLASH_LOCKED` | `getprop ro.boot.flash.locked` | 0 才可能刷写；锁着刷自制镜像＝硬砖 |
| `VERITY_MODE` | `getprop ro.boot.veritymode` | 决定是否要动 vbmeta |
| `ROOT_MODE` | `/data/adb/{magisk,ksu}`、`su -v`、`ksud -V`、`lsmod \| grep -i kernelsu`；`/proc/config.gz` 里 `CONFIG_KSU=y` 且 `lsmod` 无 → GKI 内置 | 决定刷自编内核之后会不会掉 root；LKM 模式拿不到 SUSFS。没有 root 就写 `none` |
| `ROOT_PARTITION` | 管理器的"安装/修补"页面写着在修补哪个镜像；没有 `init_boot` 分区的设备必然在 `boot` | **它才是刷前的"唯一退路"。**备份错分区等于没备份。没有 root 就写 `none` |
| `ANTI_ROLLBACK_INDEX` | `ro.boot.anti`，空则 `fastboot getvar anti` | ARB 不可逆，推高就再也回不去 |

`ROOT_MODE` / `ROOT_PARTITION` 的值可以是 `none`（确实没有 root），但**不能是 UNKNOWN** —— 分不清"没有 root"和"不知道有没有 root"，是刷机事故的常见起点。在 GKI 布局里内核在 `boot`、通用 ramdisk 在 `init_boot`，所以 KernelSU 的 LKM 补丁通常在 `init_boot`：**只备份 `boot` 是最容易犯的错。**

其余记录项（型号、SoC、Android 版本、安全补丁、ROM 版本、分区清单、关键分区存在性、`ro.boot.verifiedbootstate`、`ro.vendor.api_level`）是为后续步骤提供上下文，缺失只记 UNKNOWN。

## 实施

```bash
bash scripts/collect-device-facts.sh --root          # 手机上运行，多数设备需要 su 才能列 /dev/block/by-name
bash scripts/collect-device-facts.sh --adb           # 或从电脑经 adb
bash scripts/collect-device-facts.sh --root --backup # 顺带把原厂 boot/init_boot/vendor_boot/dtbo/vbmeta dd 到 backup/
```

脚本是纯只读的：它只 `getprop`、`uname`、`ls`，以及在 `--backup` 时从分区 `dd` **出来**。它永远不往分区写。

fastboot 侧的三条命令脚本跑不了，必须人工补齐并回填：

```bash
fastboot devices                    # 只允许一台设备
fastboot oem device-info            # 期望 Device unlocked: true
fastboot getvar anti                # 空值就写 UNKNOWN，并当作高危
```

## Quick Reference

| 想知道 | 命令 |
| --- | --- |
| 代号 | `getprop ro.product.device` |
| 内核 + KMI | `uname -r` → `6.12.23-android15-8-g…` 里的 `android15` |
| 槽位 | `getprop ro.boot.slot_suffix`（`_a` / `_b`） |
| BL 状态 | `getprop ro.boot.flash.locked`（0=解锁） |
| 验证启动 | `getprop ro.boot.verifiedbootstate`（green/orange/yellow） |
| verity | `getprop ro.boot.veritymode`（enforcing/disabled） |
| 现有 root | `ls /data/adb/{magisk,ksu}`、`su -v`、`ksud -V` |
| LKM 还是 GKI 内置 | `su -c 'lsmod \| grep -i kernelsu'`；`zcat /proc/config.gz \| grep '^CONFIG_KSU='` |
| root 补丁在哪个分区 | 管理器「安装/修补」页写的目标镜像（权威）；`ls /dev/block/by-name` 看有无 `init_boot` |
| 分区清单 | `ls /dev/block/by-name` |
| 分区实际挂点 | `readlink -f /dev/block/by-name/boot_a` |
| ARB | `fastboot getvar anti` |

## 小米 17 的已知坑

- **代号必须实测。** 公开资料曾经互相矛盾，现在有了更可靠的对照，但**仍然以 `ro.product.device` 为准**：`pudding` = 小米 17、`pandora` = 小米 17 Pro、`popsicle` = 小米 17 Pro Max；三者同属平台 **`canoe`**（内核树里 `target_variants.bzl` 的映射为 `{"popsicle":"canoe","pandora":"canoe","pudding":"canoe"}`）。注意「小米 17 系列」不等于代号——`MiCode` 的 `popsicle-w-oss` 分支名容易被误读成「小米 17」，实际对应的是 Pro Max。同 SoC 家族另有 `nezha`(17 Ultra)、`annibale`(K90)、`myron`(K90 Pro Max)。**代号的用途是给 `device.name1`、defconfig/target 名和 `getvar` 校验用；写错等于防呆失效。**
- **KMI 与 Android 版本不是一回事。** Android 16 常见 Linux `6.12.23` / KMI 5，Android 17 常见 `6.12.69` / KMI 6。要用 `uname -r` 里的 `androidNN` 标记，不要用 `ro.build.version.release` 反推。
- **ARB 常常读不到。** `ro.boot.anti` 在新机型上经常为空，这不是「没有 ARB」，而是「未知」。未知就按最高危处理：不要刷任何比当前版本旧的官方包，不要用「降级」当回滚手段。
- **A/B 设备有两套分区。** 备份和刷写都要带槽位后缀，只碰当前槽。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 从 mifirm/XDA 抄代号 | defconfig 名、`device.name1` 全错，AK3 直接 abort 或刷到错误机型 | 读 `ro.product.device` |
| 用 `ro.build.version.release` 推 KMI | 选错 GKI 分支 | 解析 `uname -r` |
| 跳过 ARB | 想靠「刷回旧版」回滚时发现熔丝已烧，永久无法降级 | 先记 ARB 指数；未知即高危 |
| 备份留在手机上 | 手机开不了机时备份也拿不出来 | `--backup` 后必须拷到电脑 + 云盘 |
| 把 `device-profile.md` 提交进仓库 | 泄露设备标识 | 它在运行时目录，`.gitignore` 已覆盖 `device-profile.local.md` |
| 字段 UNKNOWN 就继续 | 后面每一步都在猜，错到刷机才暴露 | 脚本 exit 3 就是 BLOCKED |
| 只备份 `boot`，而 root 补丁其实在 `init_boot` | 以为有退路，真出事时备份里根本没有 root | 先确认 `ROOT_PARTITION`，备份补丁所在的那个分区 |
| 把「没有 root」和「不知道有没有 root」混为一谈 | 该备份的没备份，或该停下的继续走 | `ROOT_MODE` 只能是 `none` 或具体方案，不能是 UNKNOWN |

## Red flags

出现以下任何一条，停下来补齐档案再说：

- 档案里的 `DEVICE` 是「小米17」「Xiaomi 17」这类营销名，而不是一个代号。
- `KMI_GENERATION` 是空的或 `UNKNOWN`。
- 说了「A/B 设备」却不知道当前是 a 还是 b。
- 不知道 ARB 指数，却已经打算「不行就刷回旧版」。
- 不知道 root 补丁在 `boot` 还是 `init_boot`，却已经打算刷自编内核。
- 准备用「刷回原厂 `boot`」来恢复 root，但 root 其实在 `init_boot` —— 刷了也不管用。

## 产出示例

`device-profile.md` 的结论行只有两种：

- `**READY**：device=…，kmi=…，slot=…，内核=…` → 可以进入下一步。
- `**BLOCKED**：device 或 KMI 世代仍是 UNKNOWN` → 不允许开始编译或刷写。
