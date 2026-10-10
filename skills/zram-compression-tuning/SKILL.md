---
name: zram-compression-tuning
description: 用于在小米 17（pudding / SM8850 / 6.12 GKI）上调整 zram 内存压缩：判断哪些 zram 节点真实存在、解析并切换 comp_algorithm、识别小米 xswapd/mctrl 内存回写接口、调 vm.swappiness 等 VM 参数，以及排查 swapon 失败、swap 丢失、recomp_algorithm 写 EINVAL、backing_dev 不存在、zram 官方 writeback 不可用等问题。当要提升内存压缩比、减少 lmkd 杀后台、评估内存回写是否值得做、或发现某节点在这台机器上根本不存在时使用。
---

# zram 压缩调优（小米 17 / 6.12 GKI）

## Overview

这台机器的 zram **不是内核里的一组标准 sysfs 节点**，而是一个小米定制的 vendor 模块
（`/vendor_dlkm/lib/modules/zram.ko`）。它的接口是一个**子集**，而且和上游文档对不上。

所以本 skill 的第一条规则不是「用 lz4 还是 zstd」，而是：

> **先探测节点是否存在、值是什么，再决定能不能写。**
> **不存在就明说「这台机器没有，这一节不适用」，不要换一个写法硬试。**

两个**互相独立**的坑，都会让人以为「已经写进去了」：

1. **语法差异** —— 6.12 与 6.16+ 的 zram sysfs 写法不同（`algorithm_params`、秒级 `idle`、
   `algo=` 都是 6.16+ 才有的）。
2. **存在性差异** —— 这台机器上有些节点**根本没有**（见下表）。这不是语法问题，是驱动就没暴露。

**探测的权威不是任何文档，不是 `/proc/config.gz`，也不是配置文件，而是 `/sys/block/zram0/` 的实际内容。**

## 真机事实：哪些节点有、哪些没有

> 证据快照 **2026-10-09**，设备状态：原厂内核
> `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`，`boot_index=366`。
> 来源：内核工程仓 `analysis/07-stock-boot-forensics.md`、`docs/zram-wb-reverse.md`。
> **快照会被 OTA 作废** —— 每次动手前先跑 `bash scripts/zram-tune.sh --report` 重新探测。

| 节点 | 实测 | 值 / 说明 |
| --- | --- | --- |
| `comp_algorithm` | **存在** | `lzo [lzo-rle] lz4 zstd`，`[]` 内 = 当前算法 = **`lzo-rle`** |
| `reset` | **存在** | 只写节点（`cat` 无内容） |
| `disksize` | **存在** | zram0 = 16GB（`docs/CHANGELOG.md` 2026-10-08 实测记录） |
| `zgroup_enable` | **存在** | `1` |
| `backing_dev` | **实测不存在** | → 官方 writeback 在这台机器上**不可用** |
| `writeback` | **实测不存在** | 承上：没有 `backing_dev` 就没有它 |
| `recomp_algorithm` | **未测** | 仓库里没有任何实测记录 |
| `recompress` | **未测** | 同上 |
| `algorithm_params` | **未测** | 同上 |
| `idle` | **未测** | 同上 |
| `compression_level` | **未测** | 同上；也可能出现在 `/sys/module/zstd/parameters/` |
| `mm_stat` / `io_stat` / `initstate` / `mem_limit` | **未测** | 只有 dump 脚本引用过，**没有实测输出** |

**「未测」= 必须现场探测，既不等于「有」，也不等于「没有」。**
`ls /sys/block/zram0/` + 逐个 `cat` 你打算写的节点；存在才写，不存在就写
「这台机器没有，本 skill 这一节不适用」。

`CONFIG_ZRAM_MULTI_COMP=y` 据称原厂 defconfig 已含（`analysis/01-config-comparison.md`
对真原厂 `6.12.69` 与 cctv18 树的比对为 y/y），但**接口是否暴露 = 未验证**。
同一份分析里就有现成反例：树里 `CONFIG_ZRAM_WRITEBACK=y`，而 `backing_dev` 实测不存在。
**config 与 sysfs 打架时，以 sysfs 为准。**

## When to Use

- 想提升内存压缩比、减少 lmkd 杀后台。
- 要在 `lzo / lzo-rle / lz4 / zstd` 之间切换压缩算法。
- `swapon` 失败，或 `/proc/swaps` 里 swap 不见了。
- 某个 zram 节点写入报 `EINVAL`，或干脆找不到节点。
- 想评估「内存回写」（小米 `xswapd`）值不值得开。
- 想确认改完 zram 是真的生效了，而不是以为生效了。

**何时不用**：

- 内核还没确认能开机 / 正在做 ABI 校验 → 先走 `gki-abi-verification`。
- 只想量效果（压缩比、杀进程数、功耗）→ 用 `kernel-perf-verification`，本 skill 不出结论。
- 想改 **zram 驱动本身**（加多算法、改回写实现）→ 那是**编 vendor 模块**，不是调 sysfs（见下）。

## 第一步：探测

```bash
bash scripts/zram-tune.sh --report
```

只读，不需要 root。报告包括：`ls -1 /sys/block/zram0/` 的完整清单、逐个节点的
`[存在]/[不存在]` + 当前值、算法候选集与当前算法、`/proc/swaps`、小米回写层接口、
5 项 VM 参数、UFS `read_ahead_kb`、调度器候选、MGLRU 状态、vendor `zram.ko` 身份。

**任何 `--apply` 之前先跑它。**

## 第二步：当前算法从方括号里解析

**不要相信配置文件，也不要相信文档写的「默认值」。** 实测就有一处自相矛盾：
`config.conf` 里写 `ZRAM_ALGO=lz4`，同一轮开机日志却是 `zram: already lzo-rle`。

唯一权威是节点的方括号：

```bash
sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm
# 输出: lzo-rle

cat /sys/block/zram0/comp_algorithm
# lzo [lzo-rle] lz4 zstd      ← 候选集也从这里读
```

## 第三步：切算法（顺序固定，错一步就丢 swap）

```
1. swapoff /dev/block/zram0
2. echo 1  > /sys/block/zram0/reset
3. echo <algo> > /sys/block/zram0/comp_algorithm
4. 重设 disksize            ← reset 把它清零了，不重设则 mkswap/swapon 全失败
5. mkswap /dev/block/zram0  ← 必须；reset 清掉了 swap 签名
6. swapon /dev/block/zram0  ← 绝不带 -p
```

**两个必须记住的原因**：

| 步骤 | 漏掉会怎样 | 为什么 |
| --- | --- | --- |
| 重新 `mkswap` | `swapon` 失败，swap 没了 | `echo 1 > reset` **清除设备上的 swap 签名**，没有签名就不是一台 swap 设备 |
| `swapon` **不带 `-p`** | 用 `-p` 指定优先级就失败 | toybox 的 `swapon` **不接受负数 `-p`**，而 ROM 默认优先级是 **-2**。不带 `-p` 时 ROM 会分配同样的默认值 |

顺序也不能颠倒：`swapoff` 必须在 `reset` 之前（正在当 swap 用时改算法会被拒），
`comp_algorithm` 必须在 `reset` 之后（`initstate != 0` 时该节点只读），
`disksize` 必须在 `comp_algorithm` 之后、`mkswap` 之前。

另外要**复查 `zgroup_enable`**：实测它在 `reset` 后保持 `=1`；掉了就补回 `1`
（它是小米回写的前提）。

`scripts/zram-tune.sh` 在 `reset` 之前先读并保存当前 `disksize`；**读不到或为 0 就中止，不做破坏性操作** ——
绝不允许把 zram 弄成 0 容量。本脚本**从不改容量**（改容量没有实测依据）。

### 切算法是破坏性操作（警告必须到位）

> 切换会**丢弃 zram 里现有的全部压缩页** —— 等同于丢掉那部分 swap 数据，
> **可能杀掉正在运行的进程**。只在**低负载 + 有空闲内存**时做。

所以 `--apply` 在真正 `reset` 之前要求确认：交互终端下输入 `yes`；非交互环境必须显式加 `--yes`。
没有确认就一个字节都不改。

## zram 官方 writeback：这台机器上没有，别走这条路

实测 `/sys/block/zram0/backing_dev` **不存在** → `/sys/block/zram0/writeback` 也不存在 →
官方那条 `echo /dev/sdX > backing_dev` + `echo idle > writeback` 的路**整节不适用**。

- 不要写「用 `writeback` 把冷页写到 UFS」这类建议 —— 节点不存在，方案不成立。
- 不要因为 `CONFIG_ZRAM_WRITEBACK=y` 就认为它可用（见上文：config ≠ sysfs）。
- 想真的改 zram 驱动的回写行为 → **编 vendor 模块**，见下一节。

## 想改 zram 驱动本身？那是 vendor 模块，不是内核

```
boot 分区里 zram 驱动符号    0 处   （zram_add / writeback_store / disksize_store 全无）
真身                         /vendor_dlkm/lib/modules/zram.ko
                             282,432 字节
                             depends=zsmalloc   built_with=DDK
                             vermagic=6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64
                             parm: num_devices
                             parm: qpace_pool_size:fs_bio_set pool size used by QPaCE
```

**所以**：

- 「把 zram 改成内置（`=y`）」= 丢掉 QPaCE / xswapd / mctrl / zgroup，**不要做**。
- 「改 zram 驱动」= 编一个**新的 vendor 模块**（DDK），不是编内核。
- AK3 的 `do.modules=0` 意味着**刷内核不会覆盖 vendor 模块** —— 那些小米特性照常加载。
- **算法层是唯一和原厂同层、可改的东西**：升级内核里的 `lib/zstd` / `lib/lz4` 后，
  vendor `zram.ko` 通过 `crypto_comp_compress` 自动用上新算法，**不需要碰模块**。

算法层现状（`docs/CHANGELOG.md`，boot_index 367 实测）：zstd `1.5.2 → 1.5.7`、lz4 `→ 1.10.0` 已落地。
**升级后实际压缩比的变化：UNVERIFIED**（没有对照实测）。

## 小米的「内存回写」= `xswapd`，不是 zram writeback

用户口中的「内存回写」在这台机器上是小米自己的实现，代码在 `zram.ko` 里，分三层：

| 层 | 接口 | 实测状态 |
| --- | --- | --- |
| 控制 | `/dev/memcg/memory.xswapd.enable` | **原厂默认 `0`（关）** |
| 执行 | `xswapd` 内核线程 → `zgroup_memcg_wb` → `zgroup_write_ext_sync` | 活跃 |
| 目标 | 一个经 **dm-linear**（fallback loop）呈现的块设备，由 `/dev/zram-control` ioctl 传入 | **实体未定位** |

观测命令：

```bash
cat /dev/memcg/memory.xswapd.stat    # nr_ext / nr_wb / sz_wb / drop_wb / fault_wb / wake_up
cat /dev/memcg/memory.mctrl.stat     # wb_pages
cat /sys/block/zram0/zgroup_enable   # 实测 =1
```

实测样本（2026-10-09，boot_index 372）：`enable=0`、`nr_wb=3024`、`sz_wb=3431716`、
`drop_wb=66845`、`fault_wb=24`。

### 三个最容易搞反的判断

| # | 别搞反 | 正确表述 |
| --- | --- | --- |
| 1 | `sz_wb` **不是**流量 | `sz_wb` 是**水位**（会归零，正常呼吸）；`drop_wb` 是**累计流量**（真证据）。两者不可混用 |
| 2 | `enable=0` **≠** 没有回写 | `enable` 只控制**主动**回写循环；**被动**释放路径（进程退出 / 页回收的 `zgroup_untrack`）不依赖它。**不能用 `drop_wb` 增长去证明「刚刚发生了主动回写」** |
| 3 | 门槛是**硬编码**的 | 自动回写要求 `comp_ratio >= 101`（硬编码 `0x65`）；`wb_ratio > 100` 会被**直接拒绝**（`-EINVAL`） |

### 风险（要写全，不能只写好处）

1. **手动开 `xswapd` 有 I/O 风暴风险**：唤醒闸门极多（内存水位比较 + `wake_interval=1000ms` 频控等），
   实测 `low_mem_skip` 计数 **802 万次**。
2. **可能有上层 / 内核双回写引擎冲突，需要仲裁** —— MIUI 上层 `extm` 与内核 `xswapd` 的回写目标可能相同。
   `docs/zram-wb-reverse.md` **明确把这条标注为推断（非实锤）**，引用时也要这么标。
3. **在 6.12.69 上开发 zram writeback 会踩已知 bug**：`6.12.111` 才修的有
   `zram: fix out-of-bounds access in writeback_store()`、
   `zram: fix out-of-bounds access in read_block_state()` 等 7 条（含 2 条越界访问）。
   **建议先升级内核版本再动这条线。**
4. **UFS 擦写寿命（TBW）仓库里完全没有评估** —— 所以「回写落到真实块设备会消耗 TBW」
   是**推断，标 UNVERIFIED**，不要当实测讲。
5. **回写是否真的落盘都还没被证实**：计数器在涨，但目标块设备实体未定位
   （`docs/zram-wb-reverse.md` 遗留问题 R2）。

## 不要推荐的东西

| 东西 | 实测真相 |
| --- | --- |
| `/sys/kernel/smart_cache/file` 写失败 | **设计如此**：内核侧只有 `show`、没有 `store`。**不是 SELinux 问题**，别再去查 SELinux |
| 「打开 QPaCE」 | QPaCE 是**空桩**：`get_qpace` / `put_qpace` 是空函数，`qpace_queue_compress_wrapper` 恒返回 `-EINVAL`，**而且没有任何 sysfs 开关** —— 没有可启用的路径 |
| 把 QPaCE 当压缩算法选 | QPaCE 不在 `comp_algorithm` 候选集里（候选只有 `lzo lzo-rle lz4 zstd`）。它是 bio 提交路径 + 电源管理 + ring buffer，**不是压缩算法** |

## 非 zram 的 VM 调参（可写，但要说清代价）

实测写入过、且与原厂一致的 5 项：

```bash
sysctl -w vm.swappiness=100
sysctl -w vm.vfs_cache_pressure=100
sysctl -w vm.compaction_proactiveness=20
sysctl -w vm.watermark_boost_factor=0
sysctl -w vm.extfrag_threshold=1000
```

- `vm.swappiness=100` 是**原厂本来就是的值**（`analysis/07` 实测），不是我们「调高」的。
  有 zram 时换出到内存比换到闪存便宜，但这台机器上它不是本次改动的成果。
- **`read_ahead_kb` 保持 ROM 默认 `512`。** 曾有人照抄别人的 `128`，实测**降低了顺序读性能**，已改回。
  这是本仓库最典型的一条反面例子：**参数值不能跨设备抄**。
- **调度器只在它已经出现在候选列表里时才写**：

```bash
grep -qw <name> /sys/block/<dev>/queue/scheduler   # 不在候选里就跳过，不要硬写
```

- 本 skill **不写** `vm.page-cluster`、`vm.watermark_scale_factor`、`/sys/kernel/mm/lru_gen/*`：
  没有实测对照，改了不知道好坏。

## 收益数字：只有一个，而且是别的口径

| 数字 | 值 | 口径 |
| --- | --- | --- |
| 压缩比 | **2.58x** | 原厂内核**运行态**实测（`pswpin 598,669` / `pswpout 2,228,622` / swap 已用 `3.5G/16G` / `swappiness 100`），2026-10-09 |

**没有**任何「换算法后压缩比提升 X%」的实测对照 —— 仓库里不存在这类数据。
所以任何「切 lz4 能提升压缩比」「换 zstd 能省多少内存」的声称，都必须标 **UNVERIFIED**。

特别地，旧模块 README 里那句「lz4 相比 lzo-rle 有更好的压缩率」**没有数字支撑，方向也存疑**
（lz4 的典型取舍是**更快、压缩率更低**）→ 标 **UNVERIFIED**，不要引用。

要出结论，用 `kernel-perf-verification` 的 A/B 协议；本 skill 只负责把节点改对。

## Quick Reference

```bash
# 权威：这台机器上到底有哪些节点
ls -1 /sys/block/zram0/

# 逐节点探测（只读，不需要 root）
bash scripts/zram-tune.sh --report

# 当前算法（方括号，唯一权威）
sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm

# 切算法（会要求确认；--yes 用于非交互）
bash scripts/zram-tune.sh --apply lz4
bash scripts/zram-tune.sh --apply zstd --yes

# 只调 VM、不动 zram
bash scripts/zram-tune.sh --apply keep --yes

# 开机持久化（生成的脚本里写的是绝对路径）
bash scripts/zram-tune.sh --persist lz4

# 压缩比 —— 仅当 mm_stat 存在；字段顺序以 cat 输出为准
cat /sys/block/zram0/mm_stat

# 换页压力
grep -E 'pswp(in|out)|pgscan_kswapd|pgmajfault|workingset_refault_anon' /proc/vmstat

# swap 现状（含优先级；ROM 默认 -2）
cat /proc/swaps

# 小米回写层
cat /dev/memcg/memory.xswapd.enable
cat /dev/memcg/memory.xswapd.stat

# vendor 模块身份（证明 zram 不在内核里）
modinfo /vendor_dlkm/lib/modules/zram.ko
```

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 照抄 6.16+ 文档的 `algorithm_params` / 秒级 `idle` / `algo=` 语法 | 在 6.12 上写不进去（`EINVAL`），还可能静默 | 先 `ls` + `cat` 节点；不存在就说「这台机器没有」 |
| 用 `/proc/config.gz` 判断接口可用 | `CONFIG_ZRAM_WRITEBACK=y` 而 `backing_dev` 不存在 | **以 sysfs 为准**，config 只作参考 |
| 相信配置文件的「默认算法」 | `config.conf` 写 `lz4`，开机日志却是 `already lzo-rle` | 从 `comp_algorithm` 的方括号解析 |
| `reset` 后忘了重设 `disksize` | `mkswap` / `swapon` 全失败，zram 变成 0 容量 | 顺序固定：… → 重设 `disksize` → `mkswap` → `swapon` |
| `reset` 后忘了 `mkswap` | `swapon` 失败（swap 签名被清除） | 必须重新 `mkswap` |
| `swapon -p -2`（负数优先级） | toybox 直接拒绝，swap 起不来 | **不带 `-p`**，由 ROM 分配默认优先级 |
| 在高负载 / 内存紧张时切算法 | 压缩页被丢弃 → 进程被杀 | 低负载 + 有空闲内存时做；脚本会先要求确认 |
| 建议用 `backing_dev` / `writeback` 做冷页回写 | 节点不存在，方案不成立 | 这台机器只有小米 `xswapd`，或改 vendor 模块 |
| 手动打开 `xswapd` 指望「白拿容量」 | I/O 风暴风险，`low_mem_skip` 实测 802 万次 | 默认保持 `0`；要开先量 I/O 与功耗 |
| 用 `drop_wb` 增长证明「主动回写发生了」 | 被动路径不依赖 `enable`，结论错误 | `enable` 只管主动循环；区分主动 / 被动 |
| 把 `sz_wb` 当流量指标 | 它是水位，会归零 | 流量看 `drop_wb` |
| 抄别人的 `read_ahead_kb=128` | 实测降低顺序读性能 | 保持 ROM 默认 `512` |
| 声称「换算法提升压缩比 X%」 | 没有任何实测对照 | 标 `UNVERIFIED`，或用 `kernel-perf-verification` 实测 |

## Real-World Impact

**上一版 skill 自己造成的错误**（这就是本次重写的原因）：

1. 它把 `recomp_algorithm` / `recompress` / `algorithm_params` / `idle` 当成**已经存在**，
   直接给出「主 lz4 + 备 zstd 冷页重压」的完整写入流程，并引用 kernel.org 7.3-rc6 的文档。
   而这台设备跑 6.12，且**这些节点在仓库里没有任何实测记录** —— agent 会照着一份不存在的接口清单动手。
2. 它给出了 `writeback` 的用法，而 **`backing_dev` 实测不存在**，整条路走不通。
3. 它默认 `mem_limit` 存在，还把「内存上限」写进了取舍表。

改写后的规则是：**探测节点 → 存在才写 → 不存在就明说这一节不适用**。
「先探测再写」在这里不是谨慎，是唯一能避免静默失败的做法。

**给 on-device agent 的话**：`skills/**` 由桌面 agent 负责（见本仓 `AGENTS.md`）。
你在真机上看到的事实（命令 + 原始输出 + 日期 + 设备状态）请回报，
但**不要自己改 skill** —— 这些 skill 是你自己的安全护栏。

## 相关 skill

- **REQUIRED SUB-SKILL:** `kernel-perf-verification` —— 量「换算法到底有没有用」，本 skill 不承诺收益。
- **REQUIRED SUB-SKILL:** `gki-abi-verification` —— 改内核里的算法层（zstd/lz4 升级）之后必须过 ABI 四判据。
- **REQUIRED SUB-SKILL:** `anykernel3-packaging` —— `do.modules=0` 的含义与 vendor 模块不被覆盖的机制。
