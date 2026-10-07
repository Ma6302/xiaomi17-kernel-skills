---
name: kernelsu-susfs-integration
description: 用于把 KernelSU / KernelSU-Next 与 SUSFS 集成进自编译的 Android 内核，包括判断当前 root 方案、选择 KMI 对应的分支、打补丁链、配置 CONFIG_KSU 与 KSU_SUSFS 选项、验证是否生效，以及换 root 方案时的回退。当要获取隐藏 root、SUSFS 特性、或刷入内核后掉 root、模块失效时使用。
---

# KernelSU 与 SUSFS 集成

## Overview

先记住这一条，它决定了整个工作是否可行：

> **SUSFS 是内核源码级补丁。纯 LKM 模式拿不到它。**
> 要 SUSFS，就必须自编译内核并以 GKI 模式刷入。

## When to Use

- 要给自编译内核加上 KernelSU（含隐藏能力）。
- 设备现在有 root，想知道换了内核之后会不会掉。
- SUSFS 特性没生效、`ksu_susfs` 命令不存在、Momo/Holmes 仍能检测到。

**何时不用**：内核还没编译成功（先去 `android-kernel-build-on-device`）；要刷入（去 `safe-kernel-flash`）。

## 第零步（不能跳）：先确认现在是什么 root

```bash
bash scripts/detect-root.sh
```

它会报告：当前 root 管理器（Magisk / KernelSU / APatch）、是 LKM 还是 GKI 内置、`ksu_susfs` 是否在、已启用的 SUSFS 特性、已装模块列表、当前内核配置里相关项的值。

**为什么这步不能跳**：刷入自编内核会**替换掉 root 所在的那个分区**。但 **是哪个分区，在 GKI 设备上和你以为的不一样**：

| 现在的 root | root 补丁在哪 | 刷自编 `boot.img` 之后 |
| --- | --- | --- |
| KernelSU **LKM**（管理器修补镜像） | GKI 设备上是 **`init_boot`**（内核在 `boot`，通用 ramdisk 在 `init_boot`） | `boot` 被换掉，`init_boot` 里的补丁**还在** → 掉不掉 root 取决于新内核的 KMI / 模块校验还能不能加载那个 `.ko`。**必须实测，不能推** |
| KernelSU **GKI 内置** | `boot`（内核镜像自带 `CONFIG_KSU=y`） | 直接换掉；带不带 KSU 由你编译时决定 |
| Magisk | 有 ramdisk 的老设备在 `boot`；GKI 设备在 **`init_boot`** | 补丁消失 = **掉 root**，模块可能全部失效 |
| APatch | `boot` | 补丁消失 = 掉 root |

**动手前必做两件事**：① 确认 root 补丁到底在哪个分区（管理器的"安装/修补"页面会写明正在修补哪个镜像，那才是事实；下面是辅助判断）；② 把**那个分区**备份出来并拷到机外 —— 只备份 `boot` 而补丁在 `init_boot`，等于没有退路。

```bash
su -c 'lsmod | grep -i kernelsu'                            # 有输出 = LKM（模块在跑）
ls -l /data/adb/ksu /data/adb/ksud /data/adb/magisk 2>/dev/null
zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_KSU='   # =y 且 lsmod 里没有 → GKI 内置
```

**反过来也要注意**：如果你从 LKM 改走 GKI 内置，`init_boot` 里那个 LKM 补丁就成了多余的，两套 KSU 同时存在会互相打架 —— 这种情况要恢复原厂 `init_boot`。`xiaomi17-device-recon` 的 `ROOT_MODE` / `ROOT_PARTITION` 两个字段就是为这件事采集的。

## 第一步：选对分支（KMI 必须匹配）

下表来自社区线程（XDA Picters Kernel），**是线索不是事实，必须以实机为准**：

| 设备 | Android | Linux | KMI |
| --- | --- | --- | --- |
| 小米 17 | Android 16 | 6.12.23 | KMI 5 |
| 小米 17 | Android 17 | 6.12.69 | KMI 6 |

判断依据只能从设备上取：`uname -r`（Linux 版本）+ `getprop ro.build.version.release`（Android 版本）+ `xiaomi17-device-recon` 采到的 KMI 世代。

> **一条需要留意的矛盾**：AOSP GKI 的 Android 17 分支是 `android17-6.18`（Linux 6.18），而这里说小米 17 的 Android 17 仍在 6.12。两者可能都对（厂商内核分支与 GKI 主线分支不必同步），但这意味着**「Android 版本 → Linux 版本」不能靠推**，必须读实机。

- KernelSU-Next：用 `next` 分支。
- SUSFS：用 `simonpunk/susfs4ksu` 的 **`gki-6.12`** 分支。

**KMI 不匹配的后果**：厂商预编译模块拒绝加载（CRC/符号不匹配），表现为开机后 Wi-Fi、相机、快充等静默失效。

## 第二步：补丁链（顺序错了会冲突）

```
1. KernelSU 目录准备
   git clone <KernelSU-Next> KernelSU
2. 把 10_enable_susfs_for_ksu.patch 打进 KernelSU 目录
3. 把 50_add_susfs_in_gki-6.12.patch 打进内核根目录
4. 拷 fs/* 与 include/linux/* 里的 SUSFS 新增文件
```

补丁文件名里的数字前缀是执行顺序。**先打 KernelSU 侧的，再打内核侧的**——反了会因为上下文不匹配而失败，而失败信息往往指向一个与被改文件无关的位置。

> **搬上游代码前先看许可证——这一步不能跳。**
> `tiann/KernelSU` 的 GitHub 识别结果是 GPL-3.0，而它的 README 原文写明：**只有 `kernel/` 目录是 GPL-2.0-only**，除该目录外其余是 GPL-3.0-or-later。`simonpunk/susfs4ksu` 的 `LICENSE` 则是 **GPLv3 全文**，没有 "only" / "or later" 限定词（且托管在 GitLab，GitHub 上的同名地址是 404）。
> 内核整体是 GPL-2.0 **only**；kernel.org 列出的兼容集（GPL-1.0+、GPL-2.0+、LGPL-2.0、LGPL-2.0+、LGPL-2.1、LGPL-2.1+）里 **没有 GPL-3.0**。
> 所以：**只把明确是 GPL-2.0-only 的文件搬进内核树**，含糊的先查清再搬。完整处置办法见 `kernel-project-repo-bootstrap` 第一步。

## 第三步：配置项

必须的：

```
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_ENABLE_LOG=n        # 日志开着会暴露痕迹
```

用 `kernel-config-power-perf` 的 `safe-config-change.sh` 改，别手改 `.config`。

**风险提醒**：KernelSU/SUSFS 会改动核心内核代码。若改动了导出符号，`Module.symvers` 的 CRC 会变，厂商预编译模块可能拒载。**每次改完都要验证厂商模块是否仍能加载**，这是验证项，不是可选项。

## 第四步：验证（在真机上，不是看编译日志）

```bash
uname -r                                   # 确认跑的是自编译内核
ksu_susfs show version                     # 命令不存在 = 内核没编进去
ksu_susfs show enabled_features            # 逐项对照你开的 CONFIG
su -c 'id'                                 # root 是否真的可用
dmesg | grep -iE 'ksu|susfs|module.*(verif|version)' 
```

再用 Momo / Holmes 这类检测 App 看隐藏效果。

**验证的最低标准**：`enabled_features` 的输出与你的 `CONFIG_KSU_SUSFS_*` 清单**逐项一致**。少一项就说明那个选项没编进去（多半是被 `olddefconfig` 掉了，因为它的依赖项没满足）。

## 第五步：回退路径（在刷之前就写好）

| 想回到 | 做法 |
| --- | --- |
| 原来的 root | 刷回你备份的原厂/原 root 的 boot 分区 |
| 从 SUSFS 内核退回无 SUSFS | 刷上一个能开机的自编译内核 |
| 完全干净 | 恢复 boot + init_boot 原厂镜像，然后卸载 `/data/adb/ksu` 相关残留 |

`/data/adb` 下的状态（模块、隐藏列表、白名单）**在换 root 方案后不保证兼容**。切换前导出或记下配置。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 没确认当前 root 就刷 | 掉 root、模块全失效，且不知为何 | 先 `detect-root.sh`，先备份 boot |
| 想用 LKM 拿 SUSFS | 拿不到，白折腾 | SUSFS 必须 GKI 内置 |
| 分支 KMI 选错 | 厂商模块静默失效 | 按 Android 版本对 KMI |
| 补丁顺序颠倒 | 上下文冲突，报错位置误导 | 先 KernelSU 侧，再内核侧 |
| 只改 `.config` 就跑 | 依赖没满足的选项被 `olddefconfig` 静默关掉 | 改完比 `enabled_features` |
| 开了 `KSU_SUSFS_ENABLE_LOG` | 日志本身成为痕迹 | 关掉 |
| 认为刷上就完事 | 隐藏效果没验证 | Momo/Holmes + `enabled_features` 对照 |
| 把 KernelSU 整个仓库的代码搬进内核树 | KernelSU 只有 `kernel/` 是 GPL-2.0-only，其余是 GPL-3.0-or-later，混进 GPL-2.0-only 内核是真实冲突 | 只搬 `kernel/` 目录下的文件；许可证细节见 `kernel-project-repo-bootstrap` |

## Real-World Impact

基线里 agent 的技术判断是对的：它正确指出 **SUSFS 无法通过 LKM 获得，必须 GKI 模式刷自编译内核**，也给出了补丁链与完整的 config 清单。但它**从头到尾没有确认用户当前用的是什么 root，也没有给任何卸载/回退路径**——在一个「刷内核」的场景里，这等于只给了油门没给刹车。它还引用了 XDA 上「小米 17 自编译 GKI 内核多例卡 bootloop，而 LKM 稳定」的说法，**这一条未经实机验证**，本仓库不把它当结论，只当作需要自己复现的线索。
