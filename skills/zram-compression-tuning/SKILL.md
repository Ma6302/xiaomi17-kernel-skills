---
name: zram-compression-tuning
description: 用于在 Android 手机上调整 zram 内存压缩，包括主算法与备用算法的多算法混合、冷页重压、容量与内存上限、swappiness 与 MGLRU 参数，以及开机持久化。当要提升内存压缩比、减少低内存杀进程、处理 recomp_algorithm/recompress 写入报 EINVAL、或不确定 6.12 与更新内核的 zram 接口差异时使用。
---

# zram 压缩调优

## Overview

zram 的 sysfs 接口**在 6.6 / 6.12 / 6.16 之间改过语法**，而且写错不会报错到你看得见的地方——大多数失败是 `EINVAL` 且配置**静默不生效**。所以本 skill 的第一条规则不是「用 lz4 还是 zstd」，而是：**先读节点本身，再写**。

每个 zram 节点在被写入非法值时会拒绝写入，而 `cat` 它自己就能看到支持的写法。**节点是权威，任何文档（包括这份）都只是二手。**

## When to Use

- 想提升内存压缩比、减少 lmkd 杀后台。
- `recomp_algorithm` / `recompress` 写入无反应或报错。
- 不确定这版内核有没有 `CONFIG_ZRAM_MULTI_COMP`、有没有 `idle`、语法是新式还是旧式。
- 改完 zram 想确认真的生效了（而不是以为生效了）。

**何时不用**：不知道内核是否支持多算法（先探测）；只想量效果（用 kernel-perf-verification）。

## 第一步：探测，不要假设

```bash
bash scripts/zram-tune.sh --report
```

它会打印：`comp_algorithm` / `recomp_algorithm` / `recompress` / `idle` / `mem_limit` 是否存在、各自的当前值与**支持列表**、`mm_stat`、`io_stat`、`/proc/swaps`、厂商 fstab 里的 zram 配置、MGLRU 状态。

判定要点：

| 现象 | 含义 |
| --- | --- |
| 没有 `recomp_algorithm` | 这版内核**没有** `CONFIG_ZRAM_MULTI_COMP`，多算法混合不可用，只能整体选一个算法 |
| 有 `recomp_algorithm` 但写入旧语法失败 | 换新语法 `algo=zstd priority=1` 试试（或反过来） |
| 没有 `idle` | 无法给页打 idle 标记，`type=idle` 的重压规则失去意义 |
| 没有 `mem_limit` | 内核太老，跳过该项 |

## 第二步：写入顺序不能错

```bash
bash scripts/zram-tune.sh --apply balanced      # 6G 容量，lz4 主 + zstd 备，swappiness 120
bash scripts/zram-tune.sh --apply aggressive    # 8G 容量，更激进的重压与 swappiness 150
```

顺序为什么是死的：

1. **`swapoff`** —— zram 正在当 swap 用时不能改算法。
2. **`echo 1 > reset`** —— 必须让 `initstate` 归 0，否则 `comp_algorithm` 等节点是只读的。
3. **`comp_algorithm`（主）** —— 热路径算法，选最快能解压的（lz4）。
4. **`disksize` / `mem_limit`** —— 容量。16G 机器上 6–8G 是常见区间。
5. **`recomp_algorithm`（备）** —— 冷页用压得更好的（zstd），写不进去说明语法不对。
6. **`recompress` 规则** —— 只重压 `idle` / `huge_idle` 的页，**不要对全部页做重压**，那是纯烧 CPU。
7. **重新 `swapon`**。

客户端算法选择的原理：页写入时先用主算法；当页被标记为冷（`idle`）且压缩比不够（`threshold`，单位字节）时，用备用算法重压。**热页永远走 lz4，换入换出快路径不受影响**——这是多算法混合的全部意义。

## 关键的取舍

| 决定 | 理由 |
| --- | --- |
| 主算法用 lz4，不用 zstd | zstd 压得更好但慢。热路径的频率远高于冷路径，速度优先 |
| 备用算法用 zstd | 冷页本来就不常访问，多花 CPU 换容量划算 |
| **不要开 `CONFIG_ZSWAP`** | swap 后端已经是 zram，再套一层是双重压缩：烧 CPU 但不增加可用容量 |
| 不用 z3fold | 已被弃用 |
| swappiness 调高（120–150） | 有 zram 时换出到内存比换出到闪存便宜得多。但 HyperOS 有自己的 LMKD 策略，**必须实测有没有引发抖动** |
| `page-cluster=0` | zram 是随机访问设备，不需要预读相邻页 |
| `mem_limit=0` | 不设额外上限（或设一个也不会撑爆内存的值）。上限太紧会导致 zram 满后无法压缩 |

## 第三步：持久化（否则重开机就没了）

厂商 init 会先配好 zram，你手动改的值重启即失效。用 KernelSU/Magisk 的开机脚本在其之后覆盖：

```bash
bash scripts/zram-tune.sh --persist balanced
```

它写入 `/data/adb/service.d/99-zram-tune.sh` 并 `chmod 0755`。**注意脚本里必须用 `zram-tune.sh` 的绝对路径**——开机时的当前目录不是你现在所在的目录。

## Quick Reference

```bash
# 压缩比（唯一算数的主指标）
awk '{printf "%.2f:1\n", $1/$2}' /sys/block/zram0/mm_stat

# 重压是否在发生
cat /sys/block/zram0/io_stat

# 换页压力
grep -E 'pswp(in|out)|pgscan_kswapd|pgmajfault|workingset_refault_anon' /proc/vmstat

# 冷页重压规则的实际语法 —— 节点自己会告诉你
cat /sys/block/zram0/recompress
```

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 照抄新版文档的语法 | 6.16+ 的 `algorithm_params`、秒级 `idle`、`algo=` 写法在 6.12 上写不进去 | 先 `cat` 节点读它的用法 |
| 改算法前不 `reset` | 写入被拒，但你可能没检查返回值 | `swapoff` → `reset` → 确认 `initstate=0` |
| 对全部页做重压 | 持续烧 CPU，电池掉得快，压缩比提升有限 | 只重压 `idle` / `huge_idle` 且 `threshold` 合理 |
| 同时开 zswap | 双重压缩 | 关掉 zswap |
| 只看「配置写进去了」 | 写进去≠生效 | 用 `mm_stat` 的比值验证 |
| 不持久化 | 重启后一切复原，你以为是自己没生效 | 用 `--persist` |
| 忽略了厂商已经在配 zram | 你的配置和厂商 init 互相打架 | 先看 `/proc/swaps` 与 fstab，明确是覆盖还是共存 |

## Real-World Impact

实测基线里，agent 给出了 `algorithm_params`（zstd `level=`/`dict=`）、按秒标记 idle 的 `CONFIG_ZRAM_TRACK_ENTRY_ACTIME`、以及 key=value 形式的 `writeback`——**这三样都是 6.16+ 才有的接口，在 6.12 上不存在**。它还引用了 kernel.org 的 7.3-rc6 文档作为依据，而设备跑的是 6.12。所以「先探测再写」不是谨慎，是必要。
