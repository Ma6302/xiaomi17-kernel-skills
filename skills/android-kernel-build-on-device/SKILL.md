---
name: android-kernel-build-on-device
description: 用于为小米 17（pudding / canoe / SM8850 / Android 17 / KMI android16-6-4k）编译第三方 GKI 内核：选哪棵源码树（cctv18/android_gki_kernel_common 还是 aosp-mirror/kernel_common）、SUBLEVEL 与版本号对齐、_setup_env.sh 与 KBUILD_GENDWARFKSYMS_STABLE、gendwarfksyms 符号 CRC 全错、msm_drm 拒载、pahole 与 FAILED: load BTF from vmlinux、Exec format error、LOCALVERSION 多出 +、刷入后卡第一屏或循环重启、OOM 与过热、Image 产物在哪。当要开始一次内核构建、换树、或排查自制内核刷不进去时使用。
---

# 为小米 17 编译能开机的 GKI 内核

## Overview

**核心命题：先证明你要编的是对的那棵树，再谈怎么编。**

**能不能开机由「源码树血统」决定，不是配置微调决定。** 实测（2026-10-07 ~ 2026-10-09，Xiaomi 17 `pudding` / HyperOS `OS4.0.0.32.XPCCNXM` / Android 17 SDK 37 / 原厂 `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`）：用 Google 上游 `aosp-mirror/kernel_common` 编出的内核，**即使四重 ABI 校验 100% 对齐**，仍然卡在第一屏；换成 `cctv18/android_gki_kernel_common` 后**一次开机成功**。代价是三次刷机失败 + 三天排查。

所以第一步是**选树闸门**，不是 `make`。本 skill 适用于手机侧（PRoot/Termux aarch64）与桌面侧（x86_64 + AOSP prebuilt clang）两条构建路径——**选树与环境无关**。

## When to Use

- 要开始一次小米 17 的内核构建，或判断「这棵树值不值得编」。
- 自制内核刷进去**卡第一屏**（XBL splash logo 停住）、无振动、不自动重启；或一分多钟后屏幕闪一下自动重启并循环。
- 正在考虑用 AOSP 上游 `aosp-mirror/kernel_common`——**它是错的树**，见第零步。
- 报错关键词：`FAILED: load BTF from vmlinux: Invalid argument`、`Exec format error`、`_SETUP_ENV_SH_INCLUDED: unbound variable`、`error: unable to read sha1 file of ...`、`No rule to make target`。
- 符号 CRC 全错、`msm_drm.ko` 拒载、`struct module` 不是 1600 字节 / 75 成员。
- 版本串尾巴多一个 `+`，或 `uname -r` 里没有 `android16-6-4k` 段。
- 手机上编译中途 OOM、过热降频、被 Android 后台杀掉。

**何时不用**：只是打包已编好的 `Image`（用 anykernel3-packaging）；只是刷入与回滚（用 safe-kernel-flash）；只想采集设备事实（用 xiaomi17-device-recon）；只想调 sysfs 参数而不是改内核（用 zram-compression-tuning / kernel-config-power-perf）。

## 设备事实的时效性（开工前先核对）

下面这些设备侧数字是**快照**，不是常量：原厂 `uname -r` = `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`、
KMI `android16-6-4k`、SUBLEVEL 69、SPL `2026-09-01`。证据形式为设备 `uname -r` /
`modinfo ... | grep vermagic` / `getprop` 输出，采集时间 2026-10，设备状态为小米 17
`pudding` / HyperOS `OS4.0.0.32.XPCCNXM` / Android 17 SDK 37。**一次 OTA 就可能让它们失效。**

**REQUIRED SUB-SKILL:** xiaomi17-device-recon —— 先读运行时的 `device-profile.md`，再与本节的
pin 对照：

- KMI 世代与 `LOCALVERSION` 的 `-android16-6-4k` 段不一致 → **停下来**，本节的分支选择不再适用。
- 原厂 SUBLEVEL 不再是 69 → 重新找与之对齐的 cctv18 分支，不要硬套本节。

## 第零步：选树（决定性闸门，不过就停）

### 唯一可用树

| 项 | 值 |
| --- | --- |
| 仓库 | `cctv18/android_gki_kernel_common` |
| 分支 | `android16-6.12-2026-03` |
| commit | `58ee67741556c83c523f48518284c4a6b1ef31d6`（`Add Re-Kernel & Re-Kernel netlink support`，2026-03-16） |
| SUBLEVEL | **69**（与设备原厂 `6.12.69` 完全一致） |
| `gki_defconfig` 首行 | `CONFIG_LOCALVERSION="-4k"` |
| 路径数 | 约 **87186** 个文件（完整树，非稀疏），本地检出约 **1.9 GB** |
| 许可证 | GPL-2.0-only（上游 `COPYING` 明写 version 2 only） |

**停止条件：拿不到这棵树、或其等价的、带小米/高通适配层的血统，就不要开始编译。**
不要「先编一版看看能不能开机」——那正是三次失败（V1 / V2 / 修复版）的做法。选树不对时，
后面每一步都只是在把一次注定失败的构建做得更精致。

### 为什么不是 `aosp-mirror/kernel_common`

AOSP 上游 GKI 树**缺一整层小米/高通适配**。用 cctv18 树特有的标志去测「能开机的第三方内核」与「真原厂」：

| 标志 | Jianke（实测能开机） | 真原厂 OTA | cctv18 树 | AOSP 上游树 |
| --- | --- | --- | --- | --- |
| `GKI_HACKS_TO_FIX` | y | y | **y** | ✗ 无此 Kconfig |
| `GCMA` / `GCMA_SYSFS` | y | y | **y** | ✗ |
| `RT_SOFTIRQ_AWARE_SCHED` | y | y | **y** | ✗ |
| `UNWIND_PATCH_PAC_INTO_SCS` | y | y | **y** | ✗ |
| `SCHED_PROXY_EXEC` | y | y | **y** | ✗ |
| `MODULE_SCMVERSION` | y | y | **y** | ✗ |
| `CPUSETS_V1` / `MEMCG_V1` | y | y | **y** | ✗ |
| `AUTOFDO_CLANG` | y | y | **y** | ✗ |
| `GKI_TASK_STRUCT_VENDOR_SIZE_MAX` | 1024 | 1024 | **1024** | 512（上游默认） |

Jianke 命中 12/14。这些项**全部由 cctv18 树自带**，AOSP 上游树里没有对应 Kconfig —— 不是「改几个配置就能补上」的差距。

另外 `aosp-mirror/kernel_common@android16-6.12` 是**滚动分支**：当时取到的是 `6.12.93`，
比设备原厂新 **24 个 patchlevel**。分支名不是 pin，见下面的断言步骤。

### 决定性反例：把「血统」从其它解释里摘出来

「修复版」这个中间产物很有价值，因为它逐一排除了其它候选解释：

| 候选解释 | 修复版的做法 | 结果 |
| --- | --- | --- |
| 「ABI 不匹配」 | 四重 ABI 全对齐（`msm_drm` DIFF=0、`struct module` 1600/75、`kobject_uevent_env` `0x8bb6d45c`） | ✗ 仍然卡屏 |
| 「KernelSU 干扰」 | 完全不内置 KSU | ✗ 仍然卡屏 |
| 「cmdline 注入干扰」 | 移除全部 `patch_cmdline` | ✗ 仍然卡屏 |
| **「源码树血统」** | 换成 cctv18 树 | ✅ **开机成功** |

> **用错的树对齐出来的 ABI，对齐得再准也不充分。**

### 选树自检（复制即可跑）

```bash
# 1) 远端分支当前指向（写进记录，方便日后判断上游是否移动）
git ls-remote https://github.com/cctv18/android_gki_kernel_common \
  refs/heads/android16-6.12-2026-03

# 2) 取源码：用 --depth=1
git clone --depth=1 --branch android16-6.12-2026-03 \
  https://github.com/cctv18/android_gki_kernel_common src

# 3) 断言 SHA —— 只写分支名等于没 pin
EXPECT=58ee67741556c83c523f48518284c4a6b1ef31d6
ACTUAL=$(git -C src rev-parse HEAD)
[ "$ACTUAL" = "$EXPECT" ] || { echo "SHA 不匹配 expect=$EXPECT got=$ACTUAL"; exit 1; }

cd src

# 4) 血统标志：必须全部 grep 到，缺一个就停下来
for k in GKI_HACKS_TO_FIX GKI_TASK_STRUCT_VENDOR_SIZE_MAX GCMA RT_SOFTIRQ_AWARE_SCHED; do
  grep -m1 "$k" arch/arm64/configs/gki_defconfig || echo "!! 缺 $k —— 血统可疑，停下来"
done

# 5) 版本与完整性
awk '/^SUBLEVEL/{print "SUBLEVEL =", $3}' Makefile        # 必须是 69
head -1 arch/arm64/configs/gki_defconfig                 # CONFIG_LOCALVERSION="-4k"
find . -path ./.git -prune -o -type f -print | wc -l     # 约 87186
```

关键文件存在性（缺任一即非完整树）：`arch/arm64/configs/gki_defconfig`、`kernel/sched/fair.c`、
`mm/memory.c`、`init/main.c`、`include/linux/module.h`、`kernel/trace/Kconfig`、`_setup_env.sh`、
`gki/aarch64/abi.stg`、`build.config.gki`、`build.config.constants`。

### 取源码的坑：不要用 `--filter=blob:none`

稀疏/懒加载克隆后检出整个工作区，会退化成逐 blob 懒加载，且与 `--3way` 不兼容，报：

```
error: unable to read sha1 file of ...
```

**用 `--depth=1`**（约 87186 个文件的完整工作区照常检出）。

## 构建前必须断言的三件事

在敲 `make` 之前，这三条都要有确定答案；任何一条不确定 → 停下来查。

1. **血统**：`gki_defconfig` 里 grep 得到 `GKI_HACKS_TO_FIX`，`SUBLEVEL = 69`，路径数是万级。
   （第零步已覆盖。）**这一条不过，后面两条毫无意义。**
2. **版本号对齐**：`SUBLEVEL` 必须等于设备原厂（本机为 **69**）。`LOCALVERSION` 必须带
   `-android16-6-4k` 段（与设备 KMI `android16-6-4k` 一致），后半段署名自定。
3. **工具链版本**：`build.config.constants` 里的 `CLANG_VERSION` 是**唯一权威**。
   本机实测 `CLANG_VERSION=r536225` → clang **19.0.1**（revision 12833971），
   rust `1.82.0.p2`。**不要凭喜好装一个别的 clang 版本**；版本不符的产物能否开机是 `UNVERIFIED`。

取工具链（x86_64 主机）：

```
https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225/
  clang-r536225.zip
  rust.zip
  build-tools.zip        # ★ 内含 prebuilt pahole，编 BTF 必需
```

目录约定：

```
$TC/clang-r536225/bin              clang / ld.lld / llvm-*
$TC/rust/bin                       rustc / bindgen
$TC/build-tools/build-tools/bin    pahole   ← ★ 关键
```

**pahole 必须用 build-tools 里的 prebuilt。** Ubuntu 24.04 自带的 pahole 1.25 为 6.12
生成的 BTF 会被内核自带 `resolve_btfids` 拒收：

```
FAILED: load BTF from vmlinux: Invalid argument
```

注意此时**树已经编到 `LD vmlinux` 了，不是树不完整**。

> **绝不要因为这条报错去关 `CONFIG_DEBUG_INFO_BTF`。** 关掉它只是掩盖真实编译错误
> （见 `references/toolchain-on-arm64.md` 里已被删除的那条有毒建议）。正确解法是把
> prebuilt pahole 放到 `PATH` 前面并 `export PAHOLE=...`。

## 构建步骤

### 1. 环境变量与工具链

```bash
export TC=/path/to/toolchain
export PATH="$TC/clang-r536225/bin:$TC/rust/bin:$TC/build-tools/build-tools/bin:$PATH"
export CC="$TC/clang-r536225/bin/clang"
export LIBCLANG_PATH="$TC/clang-r536225/lib"
export RUSTC=rustc BINDGEN=bindgen
export LLVM=1 LLVM_IAS=1
export PAHOLE="$TC/build-tools/build-tools/bin/pahole"   # ★ 显式指定
```

### 2. 走 GKI 官方构建入口（★ 最容易被忽略的一步）

```bash
cd src
export ARCH=arm64
export BRANCH=android16-6.12
export KERNEL_DIR="$PWD"
export OUT_DIR=/path/to/out
export BUILD_CONFIG=build.config.gki.aarch64
export SKIP_CP_KERNEL_HDR=1

. ./_setup_env.sh          # ← 这一行是核心
echo "KBUILD_GENDWARFKSYMS_STABLE = ${KBUILD_GENDWARFKSYMS_STABLE}"   # 必须打印 1
```

`_setup_env.sh` 会导出 `KBUILD_GENDWARFKSYMS_STABLE=1`，`scripts/Makefile.build:114`
把它转成 `gendwarfksyms --stable`。裸 `make` 走 unstable 路径（该特性在主线上根本没有），
**符号 CRC 会全错**（实测 `msm_drm` DIFF **471** → 厂商模块拒载 → 卡第一屏）。

**不要 `set -u`。** `_setup_env.sh` 直接引用多个可能未定义的变量，`set -u` 下立刻 abort：

```
./_setup_env.sh: line 20: _SETUP_ENV_SH_INCLUDED: unbound variable
./_setup_env.sh: line 25: KLEAF_INTERNAL_NO_BUILD_CONFIG: unbound variable
```

预定义 `_SETUP_ENV_SH_INCLUDED=""` 也救不了（下一个变量继续绊倒）。直接去掉 `set -u`。

### 3. 生成配置：用树自带的 `gki_defconfig`，原样

```bash
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 gki_defconfig

# 署名：-android16-6-4k 段必须保留（与设备 KMI 一致），后半段自己取一个，
# 不要照抄别人的（这个后缀同时也是「内核身份守卫」认自己内核的判据）
TAG="<你的后缀>"   # 例：你的 ID、缩写或随机短串
./scripts/config --file "$OUT_DIR/.config" --set-str LOCALVERSION "-android16-6-4k-$TAG"
./scripts/config --file "$OUT_DIR/.config" --disable LOCALVERSION_AUTO

# 抑制 setlocalversion 追加的 '+'（LOCALVERSION_AUTO=n 时 short 分支会无条件 echo "+"）
SLV=scripts/setlocalversion
cp -f "$SLV" "$SLV.bak"
sed -i 's|^[[:space:]]*echo "+"[[:space:]]*$|echo ""|' "$SLV"

# 两轮 olddefconfig，让 select 链收敛（一轮不够）
make O="$OUT_DIR" ARCH=arm64 LLVM=1 olddefconfig
make O="$OUT_DIR" ARCH=arm64 LLVM=1 olddefconfig
```

### 4. 配置自检：任何一项不符 → 停下来，不要继续编

```bash
for k in GKI_HACKS_TO_FIX GKI_TASK_STRUCT_VENDOR_SIZE_MAX GENDWARFKSYMS \
         MODVERSIONS EXTENDED_MODVERSIONS CFI_CLANG SHADOW_CALL_STACK \
         FUNCTION_TRACER STACK_TRACER MODULE_SIG_FORCE DEBUG_INFO_BTF; do
  grep -E "^(CONFIG_${k}=|# CONFIG_${k} is not set)" "$OUT_DIR/.config" || echo "  $k = <absent>"
done
grep '^CONFIG_LOCALVERSION' "$OUT_DIR/.config"
```

实测期望值：

```
CONFIG_GKI_HACKS_TO_FIX=y
CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024
CONFIG_GENDWARFKSYMS=y
CONFIG_MODVERSIONS=y
CONFIG_EXTENDED_MODVERSIONS=y
CONFIG_CFI_CLANG=y
CONFIG_SHADOW_CALL_STACK=y
# CONFIG_FUNCTION_TRACER is not set        ← 必须是 n
# CONFIG_STACK_TRACER is not set           ← 必须是 n
# CONFIG_MODULE_SIG_FORCE is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_LOCALVERSION="-android16-6-4k-<你的后缀>"
```

`FUNCTION_TRACER` / `STACK_TRACER` 为什么必须为 n：

```
CONFIG_STACK_TRACER=y
  → select FUNCTION_TRACER              (kernel/trace/Kconfig:316-319)
  → CONFIG_FTRACE_MCOUNT_RECORD
  → struct module 多 2 个字段（num_ftrace_callsites / ftrace_callsites）
  → struct module 从 1600 字节/75 成员 变 1664/77
  → 经 file_system_type->owner 进入 kobject_uevent_env 类型展开
  → gendwarfksyms 递归推出不同 CRC → msm_drm.ko 拒载 → 显示栈起不来 → 卡第一屏
```

陷阱：只关 `FUNCTION_TRACER` 无效 —— 会被 `STACK_TRACER` 用 `select` 拉回来。
必须先关 `STACK_TRACER`，再跑**两轮** `olddefconfig`。

### 5. 编译

```bash
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) 2>&1 | tee build.log
```

实测基线：**16 核 / 12GB，`make rc=0`，`elapsed=6m19s`，error count 0**。源码树约 1.9 GB
+ 输出约 2 GB，**建议预留 10 GB**。

手机侧额外注意（`UNVERIFIED`：这一组合——cctv18 树 + 手机 PRoot——没有完整实测过；
下面的 `-j` 与防杀是通用经验，磁盘数字来自 x86_64 主机）：

- 树与 `out/` 不要放在真正的 FUSE 挂载上（`/sdcard` 是 FUSE，没有真实权限位与符号链接语义，
  构建会在很早期以莫名其妙的错误失败）。先 `mount | grep /sdcard` 确认；落在 FUSE 上就把
  树与 `out/` 放到 PRoot `$HOME` 下的 ext4，只把日志与产物放进共享目录。
- `-j` 用**核心数 −2**，不要用 `nproc`：留核给温控与系统，慢一些但不 OOM、不过热。
- 长构建会被 Android 后台杀掉：`setsid nohup tmux new -d -s k "bash -lc 'make ... 2>&1 | tee logs/build.log'"`，
  同时开前台服务 + wake lock。

### 6. 首版红线

首版必须**零 fragment、零 cmdline 注入、不内置 KernelSU**，用树自带 `gki_defconfig`，只改署名。
理由：修复版已经证明 ABI、KSU、cmdline 都不是根因，多一个变量只会让下一次失败无法归因。
配置增量留到「确认能开机」之后，一次只加一项（**REQUIRED SUB-SKILL:** kernel-config-power-perf）。

## 产物校验

```bash
IMG="$OUT_DIR/arch/arm64/boot/Image"
ls -la "$IMG"                                   # 实测 41,896,448 字节
md5sum "$IMG"
strings "$IMG" | grep -m1 '6\.12\.69.*<你的后缀>'
#   → Linux version 6.12.69-android16-6-4k-<你的后缀> (build-user@build-host)
strings "$IMG" | grep -m1 'SMP preempt'
#   → 6.12.69-android16-6-4k-<你的后缀> SMP preempt mod_unload modversions aarch64
```

版本串基线：`6.12.69-android16-6-4k-<你的后缀>`。**尾巴不能多 `+`** —— 多了说明
`setlocalversion` 的 short 分支没压住。

vermagic 说明：设备模块的 vermagic 是 `6.12.69-android16-6-4k`，我们的多一段后缀。
这不影响加载 —— `modversions` 下 vermagic 只比较**第一个空格之前**的内容。**真正决定模块
能不能加载的是符号 CRC**，交给 ABI 校验把关。

零调优基线（2026-10-08，boot_index 365）的 `Image` md5 = `146b1bb4810b89383a47e05541ddf24e`。
换了署名或加了 fragment，md5 必然不同 —— **尺寸与版本串是稳的判据，md5 不是。**

## ABI 校验（必须做，但别指望它证明能开机）

```bash
bash scripts/verify-abi.sh        # 在「内核工程仓」根目录执行（本 skills 仓不含内核代码）
```

四门判据（全部通过才继续）：

| 指标 | 通过标准 |
| --- | --- |
| 全量 CRC vs `gki/aarch64/abi.stg` | 100%，DIFF = 0（实测 10235/10235 MATCH） |
| `msm_drm.ko`（设备真实模块，851 符号） | DIFF = 0 |
| `struct module` | 1600 字节 / 75 成员 |
| `kobject_uevent_env` | `0x8bb6d45c` |

**REQUIRED SUB-SKILL:** gki-abi-verification —— 四重校验的完整方法论与判读。

> **四门全过 ≠ 必定开机。** ABI 校验是**必要条件**，不是充分条件：它能排除「模块拒载」
> 这一整类故障，但选错树时它会给你**虚假的安全感**（修复版四门全过，照样卡屏）。
> 顺序永远是：**先选对树 → 再对齐版本 → 再走官方构建入口 → 最后才是 ABI 校验。**

产物打包见 **REQUIRED SUB-SKILL:** anykernel3-packaging；刷入与回滚见
**REQUIRED SUB-SKILL:** safe-kernel-flash。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 用 `aosp-mirror/kernel_common` 编 | 卡第一屏；ABI 对齐到 100% 也没用 | 第零步换 cctv18 树，先复现社区基线 |
| 只写分支名不 pin SHA | 上游一动，构建不可复现，失败现场无法复原 | 断言 commit `58ee6774...` |
| 用 `git clone --filter=blob:none` 再检出全树 | `error: unable to read sha1 file of ...`，与 `--3way` 不兼容 | `--depth=1` |
| 脚本里写 `set -u` | `_SETUP_ENV_SH_INCLUDED: unbound variable`，`_setup_env.sh` 直接 abort | 去掉 `set -u` |
| 裸 `make` 不 source `_setup_env.sh` | 符号 CRC 全错（`msm_drm` DIFF 471）→ 拒载 → 卡第一屏 | `. ./_setup_env.sh` 并自检 `KBUILD_GENDWARFKSYMS_STABLE=1` |
| 用系统 pahole 1.25 | `FAILED: load BTF from vmlinux: Invalid argument` | 用 build-tools 的 prebuilt pahole，放 `PATH` 前面 |
| 关 `CONFIG_DEBUG_INFO_BTF` 绕过 BTF 报错 | 掩盖真实编译错误，且产物不可信 | 修 pahole，不要关 BTF |
| 首版就加 fragment / cmdline / KernelSU | 多变量，失败无法归因 | 首版零 fragment、零注入、无 KSU |
| 用 `FUNCTION_TRACER` 做诊断 | `struct module` 变 1664/77 → CRC 变 → 拒载 | 两个 tracer 都保持 n，两轮 `olddefconfig` |
| 不做 `setlocalversion` 抑制 | 版本串尾巴多 `+` | 打掉 short 分支里的 `echo "+"` |
| 拿 ABI 全过当「一定能开机」 | 虚假安全感，白刷一次 | 四门全过 ≠ 必定开机 |

## Real-World Impact

**这个 skill 的上一版自己就是事故原因。** 上一版正文写着：

> 「换哪棵树：AOSP GKI 是唯一确定公开可得的完整树」

它把 `aosp-mirror/kernel_common@android16-6.12` 推荐为「唯一确定公开可得的完整树」，
并给出了在 CI 上编出 `Image` 的实测数据。**结论只对了一半**：那棵树确实完整、确实能编出
`Image`，但**编出来的内核在这台设备上开不了机**。照着它做，得到的是 V1 / V2 / 修复版
三次刷机全败、卡第一屏、耗时三天。

失败链条可以逐字追溯：skill 说「树是完整的 → 可以编」，于是没有人去问「这棵树的血统对不对」；
编出来的 `Image` 能过 `file` 检查、能过 ABI 校验（修复版全过），**唯一的信号是刷完之后不开机**。
这就是「能编出 Image」被当成「能开机」的代价。

**修复版反例（最硬的证据）**：四重 ABI 校验全部对齐（`msm_drm` DIFF=0、
`struct module` 1600/75、`kobject_uevent_env` `0x8bb6d45c`）、不内置 KernelSU、无 cmdline 注入
—— **仍然卡第一屏**。换到 cctv18 树后，同样的流程一次通过（一次编译 6 分 19 秒 + 一次刷机）。

**代价对比**：

| 方案 | 代价 | 结果 |
| --- | --- | --- |
| 用 AOSP 上游树自己对齐 | 三次编译 + 三次刷机 + 三天排查 | ✗ 全败 |
| 用 cctv18 树 | 一次编译（6m19s）+ 一次刷机 | ✅ 成功 |

**教训**：社区已有成熟血统时，**先复现它的基线，再谈增量优化**。本版的第零步就是这个教训
的产物：在花任何时间编译之前，先用几条命令证明「我要编的是对的那棵树」。

## UNVERIFIED / UNKNOWN

进入本 skill 正文但**未实测**的条目，不得当作结论使用：

**UNVERIFIED（有假设，未测）**

1. **具体是哪个厂商适配标志起决定作用** —— 没有做逐个开关的二分验证。`GKI_HACKS_TO_FIX`
   只是最显眼的相关标志，**不是已证实的因果**。
2. **内核安全补丁日期（SPL）对齐的影响** —— 社区文章警告「SPL 不得比设备旧」；设备 SPL
   为 `2026-09-01`，**cctv18 树的 SPL 尚未核查**。
3. **`MI_SCHED_EXT` 的来源** —— 真原厂为 `y`，但 cctv18 与 Kokuban 树里都没有该 Kconfig，
   推测来自 vendor 模块层（`vendor_dlkm`）而非 GKI。**假设未证实。**
4. **手机侧用发行版原生 clang（clang-18/19）编出的产物能否开机** —— 未在手机上验证过。
   已实测能开机的路径是 x86_64 主机 + AOSP prebuilt `clang-r536225`。
5. **cctv18 工具链 release 里的 `clang-r536225.zip` 是否含 aarch64 主机可用二进制** ——
   只按 x86_64 主机使用过；AOSP 官方内核 clang 只发布 `host/linux-x86`。
6. **手机 PRoot 本地构建的耗时与磁盘占用** —— 6m19s / 10GB 是 16 核 12GB **x86_64** 上的数据。
7. **`build.config.constants` 之外的 clang 版本是否同样可开机** —— 未做版本矩阵。

**UNKNOWN（完全没数据）**

1. **在 PRoot aarch64 上完整跑通一次 cctv18 树构建并开机** —— 没有任何一次手机侧端到端记录。
2. **cctv18 树在小米 17 之外的机型上的行为** —— 只在小米 17（`pudding` / `canoe`）上测过。
