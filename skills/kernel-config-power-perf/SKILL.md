---
name: kernel-config-power-perf
description: 用于给 Android GKI 内核做功耗与性能取向的配置调整，包括调度器、频率调控、MGLRU、内存压缩、热策略与调试项的取舍。当要判断某个 CONFIG_ 该开还是该关、担心改动导致厂商模块拒载或刷完不开机、需要对照原厂配置基线审阅自己的改动、或决定先改哪几项时使用。
---

# 内核配置：功耗与性能

## Overview

调内核配置的**首要目标不是更省电，是还能开机**。绝大多数「刷完卡 logo」不是性能改坏了，而是动了 `MODVERSIONS` / `MODULE_SIG_FORCE` / `TRIM_UNUSED_KSYMS` / LTO 这类**厂商模块依赖的约束**，导致 vendor 分区里的 `.ko` 加载失败。所以本 skill 的核心不是推荐一堆 `CONFIG_*`，而是**一次只改一步、每步都能审阅、每步都能回滚**的流程。

## When to Use

- 要调整调度器、调速器、MGLRU、ZRAM、热策略、`HZ`、LTO/CFI 等功耗性能相关配置。
- 想知道哪些调试项可以安全关掉来省内存/时间。
- 手上有原厂 `stock.config`，想知道自己的改动到底动了哪些项。
- 出现「刷完卡 logo」「vendor 模块加载失败」「编不过 BTF」这类症状。

**何时不用**：只想压 ZRAM 参数（用 zram-compression-tuning）；只想量效果（用 kernel-perf-verification）。

## 前置条件

**必须有原厂配置基线**。没有它，你无法回答「我改了哪些项」：

```bash
zcat /proc/config.gz > logs/stock.config     # 趁还在原厂内核上
```

**REQUIRED SUB-SKILL:** android-kernel-build-on-device —— 闸门 2 就是固化这份基线。

## 核心循环：一步一验证

```bash
bash scripts/safe-config-change.sh \
  --tree "$HOME/kernel/src" \
  --base logs/stock.config \
  --fragment configs/step1.fragment
```

fragment 每行一项：

```
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
CONFIG_SLUB_DEBUG=n
```

脚本做的事**每一步都不能省**：

1. 从 `stock.config` 复制出 `.config`——**永远不要从零手写一份 defconfig**。
2. 调树自带的 `scripts/config` 逐项应用，只动你列出的项。
3. 跑 `make olddefconfig` 让 Kbuild 补齐依赖——**手写依赖必然漏**，漏了就是编译错误或静默错配。
4. 用 `scripts/diffconfig stock.config out/.config` 打出真实改动，并拦截下面那张表里的致命组合。

然后：**编译 → 刷入 → 验证能开机 → 再改下一步**。不要一次改十几项然后期望能开机——出问题时你无法定位是哪一项。

## 绝对不能动的项

| 项 | 保持 | 动了会怎样 |
| --- | --- | --- |
| `CONFIG_MODVERSIONS` | `y` | 关掉后模块与内核符号失配时不报明确错误，只表现为崩溃 |
| `CONFIG_TRIM_UNUSED_KSYMS` | not set | 开了会把 vendor 模块需要的符号裁掉 |
| `CONFIG_MODULE_SIG_FORCE` | not set | 开了拒绝所有非 OEM 签名模块，直接不开机 |
| `CONFIG_DEBUG_INFO` | `y`（若 BTF 开） | **它和 `CONFIG_DEBUG_INFO_BTF` 互相依赖**：BTF 由 DWARF 生成，关掉 DEBUG_INFO 会让 BTF 构不出来 |
| `CONFIG_LTO_CLANG_THIN` | 树内默认 | 关掉省 30% 时间，但可能让厂商模块拒载 |
| `CONFIG_LTO_CLANG_FULL` | not set | 手机上基本编不动，时间和内存都爆炸 |

**想省构建时间而关 `DEBUG_INFO` 是最常见的自伤**：要么保留它，要么同时关掉 BTF，而关 BTF 又可能让部分 vendor 模块加载失败。三者是一个锁链，不能只看一环。

## 可以安全尝试的方向

按「收益/风险」排序，从上往下改：

| 方向 | 配置 | 说明 |
| --- | --- | --- |
| 多代 LRU | `CONFIG_LRU_GEN=y` + `CONFIG_LRU_GEN_ENABLED=y` | 6.12 已有。显著降低 kswapd CPU，通常是单项收益最大的功耗改动 |
| 内存压缩 | `CONFIG_ZRAM=y` + `CONFIG_ZRAM_MULTI_COMP=y` | 多算法混合，详细参数见 zram skill |
| 文件系统压缩 | `CONFIG_F2FS_FS_COMPRESSION=y` | 需 mkfs 时 `-O compression`，否则不生效 |
| 可观测但便宜的项 | 保留 `CONFIG_FTRACE`、`CONFIG_DEBUG_FS`、`CONFIG_PROC_FS` | 关掉它们省不了多少，但会让你**无法诊断**问题 |
| 关掉昂贵的调试 | `CONFIG_KASAN`、`CONFIG_UBSAN`、`CONFIG_LOCKDEP`、`CONFIG_PROVE_LOCKING`、`CONFIG_SCHEDSTATS`、`CONFIG_SLUB_DEBUG` | 这些在量产树上本就该是关的；若原厂已关就别再开 |
| 日志降噪 | `CONFIG_KSU_SUSFS_ENABLE_LOG=n`、`CONFIG_DYNAMIC_DEBUG=n` | 减少 runtime 日志开销 |
| 热策略 | `CONFIG_THERMAL_DEFAULT_GOV_STEP_WISE=y` | 与厂商热策略协同，不要自己发明 |

改 `CONFIG_HZ` **要谨慎**：它对时序敏感的驱动有影响，原厂值通常是精心选的。要改就单独一步改、单独验证。

## Quick Reference：审阅改动

```bash
# 我到底改了什么（最重要的一条命令）
"$TREE/scripts/diffconfig" logs/stock.config out/.config

# 某个项最终是什么值
grep '^CONFIG_ZRAM' out/.config

# 我在跑的核心里这个项是什么（原厂内核上）
zcat /proc/config.gz | grep '^CONFIG_LRU_GEN'
```

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 手写一份完整 defconfig | 漏项、依赖不闭合，症状千奇百怪 | 从 `stock.config` 复制，只改列出的项 |
| 改完不跑 `olddefconfig` | 依赖没补齐，编译报错或静默错配 | 必跑 |
| 不看 `diffconfig` 就编译 | 不知道自己实际改了多少项（Kbuild 会自动带出很多） | 每次改完先看 diff |
| 为提速关 `CONFIG_DEBUG_INFO` | 与 `DEBUG_INFO_BTF` 冲突，BTF 构不出来 | 二者是锁链，一起考虑 |
| 一次改十几项 | 不开机时无法定位 | 一步一编译一验证 |
| 相信 `CONFIG_SCHED_WALT` | 6.12 上游没有 WALT，那是厂商补丁 | 树里没有这个符号就别写进 fragment |
| 关掉 `FTRACE`/`DEBUG_FS` 省资源 | 出问题时无法诊断，省的量微乎其微 | 保留 |
| 以为配置改了性能就一定变 | 调速器默认值可能把差异吃掉了 | 性能必须实测，见 kernel-perf-verification |

## Real-World Impact

实测基线暴露的两个具体陷阱：agent 会建议 `CONFIG_DEBUG_INFO is not set`（与 BTF 冲突，且没意识到 Android GKI 依赖 BTF），也会建议 `CONFIG_SCHED_WALT=y`（6.12 上游不存在）。这两条都不是「可能有点问题」，而是**照着做就编不过或刷不进**。`safe-config-change.sh` 里的致命组合检查就是为它们写的。
