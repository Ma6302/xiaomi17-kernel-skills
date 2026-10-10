---
name: gki-abi-verification
description: 用于在刷入自编 GKI 内核之前、厂商模块报 disagrees about version 或 module verification failed、刷完卡在第一屏之后排查、换过源码树或 SUBLEVEL 之后重建基线、或改动过任何内核 CONFIG_ 之后。当需要离线判断自编内核能否加载 vendor_dlkm 里的厂商模块、msm_drm.ko 是否会被拒载、struct module 尺寸是否被 ftrace 改坏、kobject_uevent_env 的 CRC 是否还匹配设备模块时使用。
---

# GKI 内核 ABI 校验

## Overview

GKI 设备的厂商模块（`vendor_dlkm` 里 404 个 `.ko`）加载时会校验内核导出符号的 CRC（`modversions`）。**任何一个符号 CRC 不匹配 → 模块拒载。** 显示模块 `msm_drm.ko` 拒载 → 显示栈起不来 → **卡在第一屏**。三次实测症状完全一致：无 panic、无 oops、无内核日志。

这是 GKI 上**唯一能离线预测「这个内核能不能加载厂商模块」的手段**，也是唯一能在刷机前挡住「刷进去卡第一屏」的闸门。

**关键认知：CRC 不是源码哈希**，而是 `gendwarfksyms` 依据**结构体布局**递归推导出来的。所以改一个看似无关的配置项会连锁改变 CRC。实测溯源链（逐字保留）：

```
CONFIG_STACK_TRACER=y
  → select FUNCTION_TRACER              (kernel/trace/Kconfig:316-319)
  → CONFIG_FTRACE_MCOUNT_RECORD
  → struct module 里多出 2 个字段：
        num_ftrace_callsites
        ftrace_callsites                (include/linux/module.h:542 的 #ifdef)
  → struct module 从 1600/75 变 1664/77
  → 经 file_system_type->owner 进入 kobject_uevent_env 类型展开
  → gendwarfksyms 递归推出不同 CRC
  → msm_drm.ko 拒载 → 卡第一屏
```

**定位（最重要的一条）**：四项全过 **≠** 必定开机（源码树血统仍须正确）；但**任何一项不过 = 必定不开机**。ABI 校验是**必要条件，不是充分条件**；选错源码树时它会给你虚假的安全感。

## When to Use

触发场景（满足任意一条就跑一遍）：

- **准备刷入自编 GKI 内核前** —— 这是主闸门。刷之前跑，不要刷完再跑。
- 模块加载报错：`disagrees about version of symbol`、`module verification failed`、`no symbol version for`。
- 刷完**卡在第一屏**（XBL splash 之后无任何进展、无日志），要判断是不是 ABI 问题。
- 改动过任何配置 fragment / `CONFIG_*`（尤其 `FTRACE`、`FUNCTION_TRACER`、`STACK_TRACER`、`FUNCTION_GRAPH_TRACER`），或换过源码树、换过 SUBLEVEL。
- 想建立/更新本平台的 ABI **回归基线**（每次迭代都跑同一套四项校验）。

**何时不用 / 先用别的**：

- 内核还没编出来 → 先用 `android-kernel-build-on-device`。
- 只想调功耗性能、不知道某项该不该开 → 先用 `kernel-config-power-perf`（它会拦住 ABI 敏感项）。
- 已经确认是分区 / 签名 / vbmeta / 刷写流程问题 → 用 `safe-kernel-flash`。ABI 校验不检查这些。
- **手上没有任何设备侧基准时，不要下「全绿」结论** —— 见 ② 与 ③，缺外部基准时它们只 SKIP、不计失败。

**REQUIRED SUB-SKILL:** android-kernel-build-on-device —— 构建必须走它的官方入口（`source ./_setup_env.sh`），否则本 skill 的四项校验必然失败。

## 四项判据速查表

| # | 校验项 | 判据 | 缺输入时 |
| --- | --- | --- | --- |
| ① | 全量符号 CRC vs 树自带 `gki/aarch64/abi.stg` | **DIFF = 0 AND MISSING = 0** | 缺 `Module.symvers` 或 `abi.stg` 算 **FAIL** |
| ② | 设备真实模块的 `__versions` 段 | **DIFF == 0**（MISSING 允许，不是「对齐率 100%」） | 缺 `--ko` 只 **SKIP**、不计失败 → **必须强制提供设备模块** |
| ③ | BTF `struct module` 尺寸 | **1600 字节 / 75 成员** | 缺 `pahole` 只 **SKIP**、不计失败 → **同样要强制提供** |
| ④ | 关键符号单点核对 | `kobject_uevent_env` = `0x8bb6d45c` | 缺符号算失败 |

> ②③ 缺失只 SKIP 不计失败 —— 所以一次"全绿"可能是**假绿**。没提供设备模块和 pahole 的绿灯不算数。

## 命令速查

```bash
# 0) 构建侧前提体检（本 skill 自带，只读，不需要内核工程仓）
bash scripts/check-abi-prereqs.sh --out out --src "$SRC"

# 1)~4) 四重校验：在内核工程仓根目录执行
KO=msm_drm.ko bash scripts/verify-abi.sh
```

## ① 全量符号 CRC vs GKI ABI 基线

**查什么**：构建产出的 `Module.symvers` 对比树自带的 `gki/aarch64/abi.stg`（libabigail 风格文本）。

```bash
# 我们的导出符号数量（实测基线 19344）
grep -c . /sdcard/Download/Operit/kernel-dev/out/Module.symvers

# 基线符号数量（实测基线 10235）
grep -c 'crc:' "$SRC/gki/aarch64/abi.stg"
```

解析方式：`abi.stg` 里逐块取 `elf_symbol { name: "..." crc: 0x... }`，与 `Module.symvers` 的 `CRC<TAB>Symbol<TAB>...` 逐项比对。

**判据**：`DIFF = 0 AND MISSING = 0`。实测结果：

```
MATCH   : 10235
DIFF    : 0
MISSING : 0
对齐率  : 100.0000%
```

**怎么读结果**：`DIFF > 0` = 有符号 CRC 已经不一致，模块必定拒载，去 ③ 看 `struct module` 有没有被 ftrace 之类的项改大。`MISSING > 0` = 基线要求但我们没导出（可能被 `TRIM_UNUSED_KSYMS` 裁掉）。**缺 `Module.symvers` 或 `abi.stg` 就是 FAIL，不是 SKIP。**

## ② 设备真实模块的 `__versions` 段（最硬的外部基准）

**查什么**：`modversions` 下每个 `.ko` 的 `__versions` 节记录它要求的所有符号 CRC。这是**最硬的外部基准**，因为它直接来自设备上真正要加载的那个 `.ko`。

```c
struct modversion_info {
    unsigned long crc;              /* 8 bytes */
    char name[MODULE_NAME_LEN];     /* 56 bytes */
};                                  /* 记录 = 64 bytes */
```

解析（纯 Python，手机端也能跑）：

```python
# ELF64: 读 section header → 找 '__versions' → 按 64 字节切分
REC, NAMELEN = 64, 56
crc  = struct.unpack_from('<Q', chunk, 0)[0]
name = chunk[8:8+NAMELEN].split(b'\x00')[0].decode()
```

```bash
adb pull /vendor_dlkm/lib/modules/msm_drm.ko /sdcard/Download/Operit/kernel-dev/logs/
KO=msm_drm.ko bash scripts/verify-abi.sh
```

**判据**：**`DIFF == 0`**，不是「对齐率 100%」。实测 `msm_drm.ko` 851 符号：

```
MATCH   : 701
DIFF    : 0        ← 关键
MISSING : 150
```

那 150 个 MISSING 已逐个验证归属**其他 vendor 模块**，不在 GKI ABI 表面内：

```
hdcp1_init              → hdcp_qseecom_dlkm.ko
altmode_register_client → altmode-glink.ko
drm_dp_dpcd_read        → drm_display_helper.ko
ipc_log_string          → altmode-glink.ko / bam_dma.ko / ...
```

**怎么读结果**：`DIFF = 0` 说明**凡是我们内核该提供的，CRC 全部一致**。`DIFF > 0` 就是真失败，输出的 `ko=... base=...` 列表里前 20 条是元凶候选。**缺 `--ko` 只会 SKIP 不计入失败 —— 所以必须从真机拉一个真实模块，否则这个绿灯是假的。**

`msm_drm.ko` / `qcom_va_minidump.ko` 是 **Qualcomm 专有二进制、不可再分发**，任何仓库里都不含，必须从你自己的设备拉。

## ③ BTF 结构体尺寸（定位根因最有用的一把刀）

**查什么**：用 pahole 读构建产物 `vmlinux` 里关键结构体的字节数与成员数。

```bash
$PAHOLE -C module out/vmlinux | tail -3
# /* size: 1600, cachelines: 25, members: 75 */
```

**判据**（来自实测对照）：

```
能开机内核          : struct module = 1600 字节 / 75 成员
失败版本 (带 ftrace): struct module = 1664 字节 / 77 成员
                       ↑ 多出 num_ftrace_callsites、ftrace_callsites
```

**怎么读结果**：尺寸/成员数不同 → 与结构体相关的符号 CRC **必然**不同，直接解释 ① ② 的 DIFF。多出的成员几乎总是 ftrace 造成的，回去查 `CONFIG_FTRACE` / `CONFIG_FUNCTION_TRACER` / `CONFIG_STACK_TRACER` / `CONFIG_FUNCTION_GRAPH_TRACER`（见「基础设施要求」第 2 条，只关 `FUNCTION_TRACER` 无效）。

**陷阱**：系统自带 pahole（如 Ubuntu 24.04 的 1.25）为 6.12 生成的 BTF 会被内核自带的 `resolve_btfids` 拒收（`FAILED: load BTF from vmlinux: Invalid argument`）。要用 AOSP `build-tools` 里的 prebuilt pahole 并在 PATH 中优先。**绝不要**为了绕开它去关 `CONFIG_DEBUG_INFO_BTF` 掩盖真实编译错误。**缺 `pahole` 只 SKIP、不计入失败 —— 同样要强制提供。**

## ④ 关键符号单点核对

挑几个「一眼能看出问题」的符号交叉验证。在 `Module.symvers` 里按符号名取值：

```bash
# 按符号名取值（Module.symvers 是 TAB 分隔：CRC<TAB>Symbol<TAB>...）
awk -F'\t' '$2 == "kobject_uevent_env" { print $1 }' out/Module.symvers
```

```
kobject_uevent_env   0x8bb6d45c   ← 设备模块要求值，必须一致
kobject_uevent       0x3f4f361e
register_filesystem  0x76fa5f08
module_layout        0x797f2b3e
init_task            0x6951c290
```

**判据**：`kobject_uevent_env` 必须等于 `0x8bb6d45c`。这是最快的冒烟测试：它变了，就说明类型展开已经被配置改动污染，不用等 ② 跑完。

## 基础设施要求（构建侧前提，缺任一个校验必然失败）

1. **必须 `source ./_setup_env.sh`**。GKI 官方构建入口里有一行 `export KBUILD_GENDWARFKSYMS_STABLE=1`，`scripts/Makefile.build:114` 会把它转成 `gendwarfksyms --stable`。不用它 == 走 unstable 路径 == **CRC 全错**（实测裸 `make` 时 `msm_drm.ko` DIFF 高达 471）。跑本 skill 前先用 `bash scripts/check-abi-prereqs.sh` 体检。
2. **必须不引入 ftrace**。首版不要加任何 fragment，用树自带的 `gki_defconfig`。只关 `CONFIG_FUNCTION_TRACER` **无效** —— 会被 `STACK_TRACER` 用 `select` 拉回来；必须先关 `STACK_TRACER`，再跑**两轮** `olddefconfig` 让 select 链收敛。
3. **构建脚本不要设 `set -u`**。`_setup_env.sh` 里多处直接引用可能未定义的变量，`set -u` 下立即 abort（`_SETUP_ENV_SH_INCLUDED: unbound variable`）。预定义变量也无效，直接去掉 `set -u`。

## 归一化陷阱（会造成 100% 假 DIFF）

CRC 是十六进制字符串，比对前必须**先去掉 `0x` 前缀，再去前导零**：

```python
# ★ 错误写法
"0xaebcaf80".lstrip('0')      # -> "xaebcaf80"，与基线永远不等 → 100% 假 DIFF

# ★ 正确实现（verify-abi.py 的 norm_crc()）
def norm_crc(x):
    x = x.strip().lower()
    if x.startswith("0x"):
        x = x[2:]
    return x.lstrip("0") or "0"
```

顺序不能反：先去 `0x` 再 `lstrip("0")`，且空串要落回 `"0"`。

## 命令行与退出码

校验器随**内核工程仓**（patch stack：`versions.lock` + `scripts/` + `config/`）提供，即 `scripts/verify-abi.py` 与包装脚本 `scripts/verify-abi.sh`，**在内核工程仓根目录执行**：

```bash
python3 scripts/verify-abi.py --out <含 Module.symvers 与 vmlinux 的目录> \
                              --src <含 gki/aarch64/abi.stg 的源码树> \
                              [--ko <设备模块>] [--pahole <路径>]
```

**退出码非 0 = 有项未通过。**结论文案逐字：

```
结论: 全部通过 ✅
⚠ 但请注意：ABI 全过 ≠ 必定开机（源码树血统仍须正确）
结论: %d 项未通过 ❌
任何一项不过 = 必定无法加载厂商模块
```

复现步骤：

```bash
adb pull /vendor_dlkm/lib/modules/msm_drm.ko
KO=msm_drm.ko bash scripts/verify-abi.sh
$PAHOLE -C module out/vmlinux
```

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 用 `"0xaebcaf80".lstrip('0')` 归一化 | 得到 `"xaebcaf80"`，100% 假 DIFF | 先 `strip().lower()`、去 `0x`、再 `lstrip("0") or "0"`（`norm_crc()`） |
| 用「对齐率 100%」判 ② | 判据错，会把正常结果判成失败 | ② 的判据是 **DIFF == 0**；851 符号里 MISSING 150 是正常的 |
| 没给 `--ko` / `--pahole` 就宣布全绿 | ②③ 只 SKIP 不计失败，「全绿」是假绿 | 强制从真机拉 `msm_drm.ko` 并提供 prebuilt pahole |
| 裸 `make`，不 `source _setup_env.sh` | CRC 全错，`msm_drm.ko` DIFF 471 | 走官方构建入口，先跑 `check-abi-prereqs.sh` |
| 只关 `CONFIG_FUNCTION_TRACER` | 被 `STACK_TRACER` 用 `select` 拉回 | 先关 `STACK_TRACER`，连跑两轮 `olddefconfig` |
| 以为 ABI 全过就能开机 | 用错源码树时仍然卡第一屏 | 先选对树，再校验；ABI 是必要条件不是充分条件 |
| 用系统 pahole 编 6.12 的 BTF | `FAILED: load BTF from vmlinux: Invalid argument` | 用 AOSP build-tools 的 prebuilt pahole |
| 为绕开 pahole 报错关 `CONFIG_DEBUG_INFO_BTF` | 掩盖真实错误，还可能让部分 vendor 模块加载失败 | 修工具链，不要关 BTF |
| 一看到 `struct module` 变大就去删配置项 | 删错项，问题换一种形式复现 | 用本 skill 的溯源链定位，改一项重编一次 |

## Real-World Impact

**2026-10-08 实测**：这套方法论成功**预测**了内核能否加载设备模块 —— 四重校验的结论与实测结果完全一致（成功版：全量 10235/10235、DIFF 0、MISSING 0；`msm_drm.ko` 851 符号 DIFF 0；`struct module` 1600/75；`kobject_uevent_env` `0x8bb6d45c`）。

**同一套校验也被用来证明「ABI 对齐不等于能开机」**：一个「修复版」把 ABI 修到 100% 对齐（`msm_drm` DIFF=0、`struct module` 1600/75、`kobject_uevent_env` 0x8bb6d45c），**仍然卡第一屏** —— 因为用错了源码树。换成正确的树之后一次成功。

> 一句话：**血统决定能不能开机；ABI 校验决定模块能不能加载；两者都做对才成功。**

这正是本 skill 存在的原因，也是它的边界：它是刷机前的**否决权**，不是通行证。

## 证据与未证实项

实测数据来自 2026-10-07 ~ 2026-10-08，设备状态：平台 `canoe`/SM8850，KMI `android16-6-4k`，`uname -r` = `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`。设备事实是快照，OTA 之后须重新核对（用 `xiaomi17-device-recon` 刷新 `device-profile.md`）。

**UNVERIFIED**（有假设、没测过，不得当结论用）：

- 具体是哪个厂商适配项起决定作用 —— **未做**逐个开关的二分验证；最显眼的标志只是相关项，不是已证实的因果。
- 内核安全补丁日期（SPL）对齐的影响 —— 设备 SPL 为 `2026-09-01`，源码树的 SPL 尚未核查。

**UNKNOWN**（完全没数据）：

- 除 `msm_drm.ko` 之外其它 vendor 模块的 ② 逐符号结果 —— 只对 `msm_drm.ko` 做过完整 `__versions` 比对。
- 404 个 `.ko` 里其余模块在 ABI 部分破坏时的拒载顺序与表现形式。
