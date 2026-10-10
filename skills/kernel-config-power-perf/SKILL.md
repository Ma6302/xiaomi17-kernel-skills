---
name: kernel-config-power-perf
description: 用于小米 17（canoe/SM8850，KMI android16-6-4k）GKI 内核的配置改动与调优取向判断。当想改 CONFIG_ 让手机更省电或更快、要写或合并 config/*.fragment、要判断某一项该开还是该关、改动后厂商模块报 disagrees about version 或 module verification failed、struct module 不是 1600/75、刷完卡在第一屏、想知道首版为什么零 fragment、或拿不准某项会不会破坏 ABI 时使用。
---

# 内核配置：在这个 ABI 上，改配置是危险操作

## Overview

本 skill 的核心命题**不是**「怎么调配置让手机更省电更快」，而是：

> **在这个 ABI 上，改配置是一种危险操作。**

原因是 GKI 的符号 CRC **不是源码哈希**，而是 `gendwarfksyms` 依据**结构体布局递归推导**出来的。所以打开一个看似无关的诊断项，可以让 `struct module` 多出两个字段 → 与它相关的符号 CRC 全变 → `vendor_dlkm` 里的厂商模块拒载 → 显示模块 `msm_drm.ko` 起不来 → **卡在第一屏，静默，无 panic、无 oops、无内核日志**。

这不是理论推演。三次刷机失败、卡第一屏、耗时三天，凶器正是一个自己写的 `diag-safe.fragment` —— 它的注释写着「不修改任何既有符号 CRC → 对厂商 404 个 .ko 零影响」，而里面恰恰开着 ftrace 四项。**注释与事实完全相反。**

所以正确的顺序是：**先有能开机的基线 → 一次只加一项 → 每项都过 ABI 校验 → 上机验证 → 才加下一项**。省电与提速是这条流程的**输出**，不是起点。任何跳过 ABI 闸门的「优化」都是在拿能不能开机赌博。

## When to Use

- 想改调度器、调速器、MGLRU、ZRAM、F2FS、热策略、`HZ`、LTO/CFI 等配置来省电或提速。
- 要判断某个 `CONFIG_*` 该开还是该关，或想知道「这一项会不会影响 ABI」。
- 要写 / 合并一个 `config/*.fragment`，或已经写好想知道能不能编。
- 出现 `disagrees about version of symbol`、`module verification failed`、`no symbol version for`、模块拒载、卡第一屏。
- 发现 `struct module` 不是 **1600 字节 / 75 成员**，或 `kobject_uevent_env` 不是 `0x8bb6d45c`。
- 想知道首版为什么刻意用**零 fragment**。

**何时不用 / 先用别的**：

- 还没有能开机的基线 → 先用 `android-kernel-build-on-device`。
- 已经编完、要判断这个内核能不能加载厂商模块 → 用 `gki-abi-verification`（本 skill 每一步的放行条件都是它的四项判据）。
- 只想调 zram 的**运行时**参数、不重编内核 → 用 `zram-compression-tuning`。
- 只想量效果 → 用 `kernel-perf-verification`。
- 分区 / vbmeta / 签名 / 刷写流程问题 → 用 `safe-kernel-flash`。

**REQUIRED SUB-SKILL:** gki-abi-verification —— 本 skill 的闸门就是它的四项校验，不要另立一套判据。

## 8 条红线（任何 fragment 都不能出现）

```ini
✗ CONFIG_FUNCTION_TRACER=y
✗ CONFIG_FUNCTION_GRAPH_TRACER=y
✗ CONFIG_STACK_TRACER=y
✗ CONFIG_FTRACE_MCOUNT_RECORD=y
✗ CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=<改值>
✗ CONFIG_CFI_CLANG=<改值>
✗ CONFIG_SHADOW_CALL_STACK=<改值>
✗ CONFIG_MODULE_SIG_FORCE=y
```

| # | 红线项 | 为什么是红线 |
| --- | --- | --- |
| 1 | `CONFIG_FUNCTION_TRACER=y` | `struct module` 多出 ftrace 字段 → 1600/75 变 1664/77 |
| 2 | `CONFIG_FUNCTION_GRAPH_TRACER=y` | 同上，并在 `FUNCTION_TRACER` 之上再加一层回调 |
| 3 | `CONFIG_STACK_TRACER=y` | **select `FUNCTION_TRACER`** —— 你以为关掉了，内核给你拉回来 |
| 4 | `CONFIG_FTRACE_MCOUNT_RECORD=y` | 直接决定 `include/linux/module.h:542` 那个 `#ifdef` 分支 |
| 5 | `CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=<改值>` | 改它 = 改 `task_struct` 尺寸 = 直接改 ABI（基线 **1024**） |
| 6 | `CONFIG_CFI_CLANG=<改值>` | KCFI 类型哈希进符号表，改了模块拒载（基线 **y**） |
| 7 | `CONFIG_SHADOW_CALL_STACK=<改值>` | SCS 改变调用约定与结构体布局（基线 **y**） |
| 8 | `CONFIG_MODULE_SIG_FORCE=y` | 拒绝所有非签名模块；厂商模块没有你的签名 → 直接不开机 |

`scripts/build.sh`（内核工程仓侧）会在编译前对其中 4 个 ABI 敏感项做 `=y` 检测并**中止编译**；
本 skill 的 `bash scripts/safe-config-change.sh` 把 8 条全拦一遍，且在**合并前**和**olddefconfig 之后**各查一次。

## 反面教材：`diag-safe.fragment`

这是本 skill 值得存在的唯一理由。文件名、注释、内容三者互相矛盾：

```ini
# diag-safe.fragment —— 原样保留的失败样本
# 只做诊断加固，不引入重负载调试 → 不影响启动速度与稳定性
# 不修改任何既有符号 CRC → 对厂商 404 个 .ko 零影响
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_STACK_TRACER=y
```

**注释与事实完全相反的三处**：

1. 「不引入重负载调试」——ftrace 的 mcount 记录是**编译期**插桩，不是运行时开关。
2. 「不修改任何既有符号 CRC」——它改的正是 CRC 的**输入**：结构体布局。
3. 「对厂商 404 个 .ko 零影响」——实测后果是 `struct module` 从 **1600/75** 变 **1664/77**，`msm_drm.ko` 拒载，显示栈起不来，**卡第一屏**。

更坏的是失败形态：**静默**。没有 panic、没有 oops、没有内核日志，只有屏幕停在 XBL splash。
这种失败不会给你任何提示去指向「是你上周改的那个 fragment」。

教训：**fragment 的注释不是证据，`.config` 才是。** 任何关于「本改动不影响 ABI」的断言，都必须用
`bash scripts/verify-abi.sh` 的四项判据证明，而不是写在注释里。

## 完整因果链（本 skill 最有价值的部分）

从一行看似人畜无害的配置到卡第一屏，逐字保留：

```
CONFIG_STACK_TRACER=y
  → select FUNCTION_TRACER              (kernel/trace/Kconfig:316-319)
  → CONFIG_FTRACE_MCOUNT_RECORD
  → struct module 多 2 个字段：
        num_ftrace_callsites
        ftrace_callsites                (include/linux/module.h:542 的 #ifdef)
  → struct module 从 1600/75 变 1664/77
  → 经 file_system_type->owner 进入 kobject_uevent_env 类型展开
  → gendwarfksyms 递归推出不同 CRC
  → msm_drm.ko 拒载 → 显示栈起不来 → 卡第一屏
```

读这条链要知道三件事：

- **起点是 `STACK_TRACER`，不是 `FUNCTION_TRACER`。** 前者 `select` 后者，所以凶手在最上游。
- **传播路径经过 `file_system_type->owner`。** 这就是为什么「改的是 trace 配置，坏的是显示模块」——中间隔了三次类型展开，没有任何直观关联。
- **终点是模块拒载，不是内核崩溃。** 内核本身活得好好的，只是显示栈没起来。所以现场找不到证据。

## 陷阱：只关 `FUNCTION_TRACER` 无效

这是最容易踩的第二脚：

```
❌ 把 CONFIG_FUNCTION_TRACER 从 y 改成 n
   → CONFIG_STACK_TRACER=y 用 select 把它拉回来
   → 编完一看 FUNCTION_TRACER 还是 y
```

**正确顺序（顺序不能反）**：

1. **先关 `CONFIG_STACK_TRACER`**（上游先断）。
2. 再关 `CONFIG_FUNCTION_TRACER` / `CONFIG_FUNCTION_GRAPH_TRACER` / `CONFIG_FTRACE_MCOUNT_RECORD`。
3. 跑 **两轮** `olddefconfig` —— 第一轮只解开一层 select，第二轮才真正收敛：

```bash
make O="$OUT" ARCH=arm64 LLVM=1 olddefconfig
make O="$OUT" ARCH=arm64 LLVM=1 olddefconfig
```

4. 然后**用 `.config` 复查**，不要凭操作记忆：

```bash
grep -E '^(CONFIG_(FUNCTION_TRACER|STACK_TRACER|FUNCTION_GRAPH_TRACER|FTRACE_MCOUNT_RECORD)=|# CONFIG_(FUNCTION_TRACER|STACK_TRACER|FUNCTION_GRAPH_TRACER|FTRACE_MCOUNT_RECORD) is not set)' "$OUT/.config"
```

只跑一轮、或只改一个符号，都会让你以为修好了而实际没有。

## 规矩：首版零 fragment，之后一次只一项

### 首版：零 fragment

**首版的目标是只复现基线，不引入任何变量。** 用树自带的 `gki_defconfig`，`config/` 目录保持为空：

```bash
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 gki_defconfig
```

这不是保守，是**单变量原则**：血统（源码树）已经是一个未验证的大变量，此时再叠配置就是两个变量一起动。
一旦不开机，你无法回答「是树的问题还是配置的问题」——实测的三天就是这么花掉的。

### 之后：一次只加一项

```
config/zram.fragment          ← 只放 zram
config/scheduler.fragment     ← 只放调度
config/f2fs.fragment          ← 只放 F2FS
```

**不要**把所有调优塞进一个 fragment，否则出问题无法定位是哪一项。

合并命令（逐字，注意 `-O` 与 `-m` 都要给）：

```bash
ARCH=arm64 scripts/kconfig/merge_config.sh -O "$OUT_DIR" -m "$OUT_DIR/.config" config/zram.fragment
make O="$OUT_DIR" ARCH=arm64 LLVM=1 olddefconfig
```

fragment 写法模板（只写增量 + 头部写清依据与回滚）：

```ini
# config/zram.fragment
# SPDX-License-Identifier: MIT
# ------------------------------------------------------------
# 目标    : 提升 zram 压缩比
# 依据    : 原厂 defconfig 已含 ZRAM_BACKEND_ZSTD=y / ZRAM_MULTI_COMP=y
# 前置条件: 必须先有可开机的基线
# 回滚    : 删除本文件即可恢复默认
# ------------------------------------------------------------
CONFIG_ZRAM_DEF_COMP_ZSTD=y
# CONFIG_ZRAM_DEF_COMP_LZORLE is not set
CONFIG_ZRAM_MULTI_COMP=y
```

### 每加一项必须走完的四步（缺一步就退回上一步）

1. **单独编译**。
2. **`bash scripts/verify-abi.sh` —— 四项必须全过**（全量 CRC DIFF=0；`msm_drm.ko` DIFF=0；`struct module` 1600/75；`kobject_uevent_env` `0x8bb6d45c`）。
3. **记录**到内核工程仓的 `docs/CHANGELOG.md`。
4. **上机验证**，确认能开机且功能正常，**然后才加下一项**。

## 编前自检：期望值表（逐字，任何一项不符就停下来查）

```bash
for k in GKI_HACKS_TO_FIX GKI_TASK_STRUCT_VENDOR_SIZE_MAX GENDWARFKSYMS \
         MODVERSIONS EXTENDED_MODVERSIONS CFI_CLANG SHADOW_CALL_STACK \
         FUNCTION_TRACER STACK_TRACER MODULE_SIG_FORCE DEBUG_INFO_BTF; do
  grep -E "^(CONFIG_${k}=|# CONFIG_${k} is not set)" "$OUT_DIR/.config" || echo "  $k = <absent>"
done
grep '^CONFIG_LOCALVERSION' "$OUT_DIR/.config"
```

```
CONFIG_GKI_HACKS_TO_FIX=y
CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024
CONFIG_GENDWARFKSYMS=y
CONFIG_MODVERSIONS=y
CONFIG_EXTENDED_MODVERSIONS=y
CONFIG_CFI_CLANG=y
CONFIG_SHADOW_CALL_STACK=y
# CONFIG_FUNCTION_TRACER is not set       ← 必须是 n
# CONFIG_STACK_TRACER is not set          ← 必须是 n
# CONFIG_MODULE_SIG_FORCE is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_LOCALVERSION="-android16-6-4k-<署名后缀>"
```

**这一整张表就是本 skill 的闸门。** `bash scripts/safe-config-change.sh` 把它实现成了机器检查：
表里任何一项不符都是 **FAIL**，脚本不会打印放行语；`<absent>` 也是 FAIL，不是「跳过」。
`CONFIG_LOCALVERSION` 里必须含 `-4k`（KMI 段），否则 vermagic 与设备模块对不上。

## 有毒建议：关掉 `CONFIG_DEBUG_INFO_BTF` 绕开 pahole

**不要这么做。** 这是一条必须从笔记里删掉的建议。

```bash
# ❌ 有毒：系统 pahole 编不出 BTF，于是关掉 BTF
./scripts/config --file "$OUT_DIR/.config" --disable DEBUG_INFO_BTF
```

为什么有毒：

- 报错 `FAILED: load BTF from vmlinux: Invalid argument` 的**原因不是树不完整**，而是 Ubuntu 24.04
  自带的 pahole 1.25 太旧，为 6.12 生成的 BTF 被内核自带的 `resolve_btfids` 拒收。**此时已经编译到 `LD vmlinux`。**
- 关掉 BTF 会让这个错误**消失**，于是你继续编、继续刷，把真正的工具链问题带进产物 —— 它掩盖的是真实编译错误。
- `CONFIG_DEBUG_INFO_BTF=y` 是期望值表里的一项，关掉即 FAIL。Android GKI 依赖 BTF。

**正确解法**：把 AOSP `build-tools` 里的 prebuilt pahole 放到 `PATH` 最前面并显式导出。

```bash
export PATH="$TC/build-tools/build-tools/bin:$PATH"
export PAHOLE=$TC/build-tools/build-tools/bin/pahole
"$PAHOLE" --version
```

**只有在精确命中该报错、且已确认 prebuilt pahole 也不可用时**才考虑降级，并在日志里明确记录降级理由与影响面。
其余情况一律修工具链。

## 还存在的配置级收益方向（候选、尚未实施、风险低→中）

以下方向**都没有在本机实测过**，只是「不触碰红线、理论上可做」的候选。顺序就是风险顺序。

| 方向 | 相关配置 / 参数 | 说明 | 风险 |
| --- | --- | --- | --- |
| ZRAM 默认算法 | `lzo-rle` → `zstd`（`CONFIG_ZRAM_DEF_COMP_ZSTD=y`） | 压缩比更高，CPU 略升。实测原厂运行为 `zram0 16GB`、算法 `lzo-rle` | 低 |
| ZRAM 多算法分层 | `CONFIG_ZRAM_MULTI_COMP=y` + 冷页重压 | 热页走快算法、冷页走高压算法 | 低 |
| F2FS 压缩 | `CONFIG_F2FS_FS_COMPRESSION=y`（需 fs 侧启用） | 内核侧具备，需 mkfs / 挂载侧配合才生效 | 低 |
| 调度参数 | `SCHED_CLASS_EXT` / `RT_SOFTIRQ_AWARE_SCHED`（树中已有） | 改的是参数不是开关，定位更难 | 中 |
| 内存管理 | MGLRU 参数（`LRU_GEN=y` 树中已有） | 6.12 已具备，调的是参数 | 中 |

**先决条件（不要跳过）**：先跑**一两天稳定性与功耗基线**，确认当前版本本身没问题，再叠上游改。
这样每次只有一个变量，出了事才知道该回退什么。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 在一个 fragment 里塞多项调优 | 不开机时无法定位哪一项 | 一次只加一项，走完「编译 → ABI → 记录 → 上机」四步再加下一项 |
| 首版就加自己的 fragment | 血统 + 配置两个变量一起动 | 首版零 fragment，用树自带 `gki_defconfig` |
| 相信 fragment 注释里的「不影响 ABI」 | `diag-safe.fragment` 就是这么坏的：1600/75 → 1664/77 | 只认 `.config` 与 `verify-abi.sh` 的输出，注释不算证据 |
| 只关 `CONFIG_FUNCTION_TRACER` | 被 `STACK_TRACER` 用 `select` 拉回，白改 | 先关 `STACK_TRACER`，再关其余 ftrace 四项 |
| 只跑一轮 `olddefconfig` | select 链没收敛，`.config` 与预期不符 | 连跑**两轮**，再 grep `.config` 复查 |
| 想省构建时间关 `CONFIG_DEBUG_INFO_BTF` 绕开 pahole | 掩盖真实编译错误，且 BTF 是期望值项 | 修工具链：prebuilt pahole 放 PATH 最前 |
| 手写一份完整 defconfig | 漏项、依赖不闭合，症状千奇百怪 | 从基线 `.config` 复制，只改列出的项 |
| 改完不看 `scripts/diffconfig` | 不知道 Kbuild 顺带改了多少项 | 每次改完先看 diff，再决定编不编 |
| 编前不自检期望值表 | 带着 ABI 破坏项进入 6 分钟编译，白白浪费 | 先跑 `bash scripts/safe-config-change.sh`，它会在编译前拦住 |
| 相信 `CONFIG_SCHED_WALT=y` | 6.12 上游没有 WALT，那是厂商补丁；树里没这个符号 | 符号在树里不存在就别写进 fragment |
| ABI 四项全过就认为必定开机 | 源码树血统错时仍卡第一屏 | ABI 是**必要条件不是充分条件**；先选对树 |

## Real-World Impact

**这一版 skill 推翻的正是它自己上一版的核心建议。** 上一版把这件事写成「怎么做功耗性能取向的配置调整」，
并给出一份「可以安全尝试的方向」清单（`LRU_GEN`、`ZRAM_MULTI_COMP`、`F2FS_FS_COMPRESSION`，甚至建议
「保留 `CONFIG_FTRACE`」）。**保留 FTRACE 那条是直接有害的** —— 它和 `diag-safe.fragment` 的思路同源，
实测后果是 `struct module` 1664/77 与 `msm_drm.ko` 拒载。

上一版还把 `CONFIG_DEBUG_INFO_BTF` 描述成「与 `DEBUG_INFO` 互相依赖的锁链，可以一起关掉」。
这个措辞给了「关掉 BTF 是选项之一」的错误印象 —— 在 GKI 上它不是选项，是期望值表里的一行。

**实测数据（2026-10-07 ~ 2026-10-08）**：

| | 失败版（带 ftrace） | 成功版 |
| --- | --- | --- |
| `FUNCTION_TRACER` | 开 | 关 |
| `struct module` | 1664 / 77 | **1600 / 75** |
| `msm_drm` DIFF | **471** | **0** |
| 结果 | ✗ 卡第一屏 | ✅ 开机 |

失败版的具体形态：`diag-safe.fragment` 注释声称「对厂商 404 个 .ko 零影响」，
实际让显示模块拒载，屏幕停在 XBL splash，**无 panic、无 oops、无日志**。
恢复方式是音量下 + 电源进 fastboot，刷回 stock boot。

**一句话**：血统决定能不能开机；ABI 校验决定模块能不能加载；配置改动只在两者都做对之后才有意义。

## 证据与未证实项

实测数据来自 2026-10-07 ~ 2026-10-08。设备状态：平台 `canoe` / SM8850，OS Android 17，
KMI `android16-6-4k`（来源 `modinfo /vendor_dlkm/lib/modules/msm_drm.ko | grep vermagic`，
**不是** `uname -r`、**不是** OS 版本）。原厂 `uname -r` = `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`；
成功版 `uname -r` = `6.12.69-android16-6-4k-<署名后缀>`，`boot_index` 365。设备事实是快照，OTA 后须重新核对。

**UNVERIFIED**（有假设、没测过，不得当结论用）：

- 上表「候选方向」里每一项的**实际**功耗 / 性能收益 —— 全部未实测，只有原厂运行为 `zram0 16GB`、算法 `lzo-rle` 这一条实测值。
- 「两轮 `olddefconfig` 足够收敛」—— 实测经验，未做第三轮对照。
- 除 ftrace 四项外，其余 4 条红线（`GKI_TASK_STRUCT_VENDOR_SIZE_MAX` / `CFI_CLANG` / `SHADOW_CALL_STACK` / `MODULE_SIG_FORCE`）**未在本机逐个复现**其破坏后果；列入红线依据是它们的 ABI 语义，不是实测。

**UNKNOWN**（完全没数据）：

- 404 个 `.ko` 在 ABI 部分破坏时的拒载顺序与完整表现面 —— 只完整验过 `msm_drm.ko`。
- 内核 SPL 对齐的影响 —— 设备 SPL `2026-09-01`，源码树的 SPL 未核查。
