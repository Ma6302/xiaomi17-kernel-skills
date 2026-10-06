---
name: android-kernel-build-on-device
description: 用于在 Android 手机（PRoot/Termux 的 aarch64 Linux 用户空间）上从源码编译 GKI 内核，或在本地工具链不可用时切换到云端 CI 编译。当要判断这台手机到底能不能本地编译、选 Kleaf 还是 legacy make、确定 defconfig 名、处理工具链架构不匹配、防 OOM 与过热、以及决定产物放哪里时使用。
---

# 在设备上编译 Android 内核

## Overview

手机端编译的**第一道坎不是内存也不是温度，是工具链架构**。AOSP 官方内核 clang 只发布 `host/linux-x86`（x86_64）二进制，在 aarch64 手机上直接 `Exec format error`。所以第一个动作永远是判定「本地到底能不能编」，而不是 `make -j8`。这一关过不去，其余优化全是白费。

## When to Use

- 要在手机上从源码编内核，或判断该不该改用 CI。
- 遇到 `Exec format error`、`clang: not found`、编译中途 OOM、手机过热降频、构建被 Android 杀掉。
- 不确定内核树是 Kleaf 还是 legacy、defconfig 叫什么、产物在哪。

**何时不用**：只是打包已经编好的产物（用 anykernel3-packaging）；只是刷入（用 safe-kernel-flash）。

## 六道闸门，按顺序过

### 闸门 1：工具链能不能跑 —— 不过就停

```bash
bash scripts/preflight.sh --tree "$HOME/kernel/src"
```

**REQUIRED SUB-SKILL:** 读 `references/toolchain-on-arm64.md`，那里有方案 A/B/C/D 的完整取舍。

一句话判据：

```bash
uname -m                    # 必须是 aarch64
file "$(command -v clang)"  # 必须是 aarch64 ELF，出现 x86-64 立刻停
```

出现 x86-64 只有两条路：装发行版原生 clang（方案 A），或改走 CI（方案 B）。**不要**试图用 `gcc-aarch64-linux-gnu` 之类的交叉编译器来救——那个编译器本身也是 x86_64 二进制，问题不在目标架构而在主机架构。

### 闸门 2：固化原厂配置 —— 只能趁现在

**在刷任何自制内核之前**，当前运行的还是原厂内核，这是拿到厂商权威配置的唯一窗口：

```bash
zcat /proc/config.gz > "$HOME/kernel-dev/logs/stock.config"
wc -l "$HOME/kernel-dev/logs/stock.config"
```

读不到就用原厂 boot 镜像反解：

```bash
bash "$TREE/scripts/extract-ikconfig" stock_boot_a.img > logs/stock.config
```

**没有这份基线，你无法回答「我这次改动到底动了哪些项」**，也就无法在刷完不开机时定位问题。这一步不做，后面所有对比都是空谈。

### 闸门 3：这棵树到底能不能构建 —— 不过就换树

**在做任何构建动作之前，先数路径数。** 小米的官方内核分支**不保证是完整树**：

```bash
gh api repos/MiCode/Xiaomi_Kernel_OpenSource/git/trees/popsicle-w-oss?recursive=1 --jq '.tree|length'
```

实测（2026-10，HEAD `45705be1220b4cfa8100516ad86711656c0b634e`）：

| 分支 | 路径数 |
| --- | --- |
| `popsicle-w-oss` | **2,686** |
| `annibale-w-oss` | 75,910 |
| `aurora-u-oss` | 76,161 |
| `bixi-v-oss` | 75,911 |

几千 vs 几万，就是「稀疏树」与「完整树」的差别。`popsicle-w-oss` 缺 `kernel/sched/fair.c`、`mm/memory.c`、`init/main.c`、`arch/arm64/Kconfig`、`net/wireless/nl80211.c`、`drivers/gpu/drm/msm/msm_drv.c`；根目录没有 `build/`、`prebuilts/`、`soc-repo/`、`external/`；`arch/arm64/configs/` 共 6 个配置类文件，唯一的 `*_defconfig` 是 `generic_vm_defconfig`。

> **它不能单独克隆即构建。** 传统 `make ARCH=arm64 <xxx>_defconfig` 这条路在这棵树上不存在。

它期望被放进多仓库 `kernel_platform` 父级 workspace（`build/`、`common/`、`msm-kernel/`、`soc-repo/`、`external/dtc/`、`prebuilts/`）——证据是 `build_with_bazel.py` 用 `workspace = 脚本目录/..`，并默认引用 `../soc-repo/kleaf-scripts/msm_kernel_extensions.bzl`；`build.config.msm.popsicle` 只有两行，核心是 `. ${ROOT_DIR}/soc-repo/build.config.msm.canoe`；`bazel.WORKSPACE` 引用 `external/qcom-dtc`；`tools/bazel` 不在本仓库（`tools/` 只有 `testing/`）。

**而 manifest 拿不到**：MiCode 没有 manifest 仓库，`Xiaomi_Kernel_OpenSource` 的 266 个分支里名字含 `manifest`/`platform` 的为 0；高通 CLO 匿名只读得到 automotive 清单，对应 sm8850/W 的 `release-w-qcom-sm8850` 需要账号。

| 情况 | 做法 |
| --- | --- |
| 路径数是万级、有 `build/` 或能直接 `make` | 继续闸门 4 |
| 路径数是几千（稀疏树） | **换树**（见下） |
| 有 CLO 账号 | 按 `release-w-qcom-sm8850` manifest 拼 workspace |

**不要在稀疏树上开始构建。** 你会得到一连串缺文件的报错，然后花很久才发现问题不在命令而在树本身。

### 换哪棵树：AOSP GKI 是唯一确定公开可得的完整树

`aosp-mirror/kernel_common`（`android.googlesource.com` 的 GitHub 镜像）：

| 分支 | 路径数 | Linux |
| --- | --- | --- |
| `android16-6.12` | **72,991**（`truncated:false`） | 6.12 |
| `android16-6.12-lts` | — | 6.12 |
| `android17-6.18` | — | 6.18 |

实测 `android16-6.12`：

- **有** `Makefile`、`kernel/sched/fair.c`、`mm/memory.c`、`init/main.c`、`arch/arm64/Kconfig`、`build.config.gki.aarch64`、`build.config.common`、`arch/arm64/configs/gki_defconfig`
- **没有** `tools/bazel`、`build/kernel/kleaf/`、`build/build.sh`、`prebuilts/`、`android/abi_gki_aarch64_qcom`

它自带完整源码与顶层 `Makefile`，**可以直接 `make` 构建**；`build/`（kleaf）与 `prebuilts/` 在别的仓库里，只有走 Bazel 才需要。

**为什么这是对的方向**：`BOARD_USES_GENERIC_KERNEL_IMAGE=true` 意味着设备启动的**本来就是 Google 的 GKI 内核**，厂商树里那个 Image 是被丢弃的。要改 zram / f2fs / 调度、要打 KernelSU，改 GKI 树就够，根本不需要那棵厂商树。

**选哪个分支由设备的 `uname -r` 与 KMI 世代决定**——先跑 `xiaomi17-device-recon`，不要从网上推。小米 17 的 GKI 是 6.12（KMI 5 或 6 视 Android 版本）还是 6.18，**必须以实机为准**。

**两个还没验证的点**（不要当成结论）：

1. 用 `make` 直接构建 `kernel_common` 并产出可启动的 `Image` —— **未实测**。
2. 自编 GKI 内核对厂商模块（`dio_dma_mapper.ko`、`mi_kernel_monitor.ko`、`gpu_stats.ko`）的兼容性取决于 KMI 符号表，而 `android/abi_gki_aarch64_qcom` 在厂商树里、不在 GKI 树里 —— **需要验证**。

### 闸门 4：构建系统与 defconfig 名

```bash
[ -f "$TREE/tools/bazel" ] && [ -d "$TREE/common" ] && echo Kleaf || echo legacy
ls "$TREE/arch/arm64/configs/"
```

**defconfig 名必须从树里列出来，不能猜。** 网上流传的名字（例如按机型猜的 `popsicle_defconfig`）经常不存在——在 `popsicle-w-oss` 上就确实不存在。

| 情况 | 命令 |
| --- | --- |
| Kleaf（有 `tools/bazel` + `common/`） | `tools/bazel run --config=fast //common:kernel_aarch64_dist -- --dist_dir=out/dist` |
| Qualcomm msm-kernel（有 `build_with_bazel.py`） | `python3 <kernel_dir>/build_with_bazel.py -t <target> <variant>`（从 workspace 根目录运行；产物在 `out/msm-kernel-<target>-<variant>/dist`） |
| legacy make | `make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang <defconfig名>` 然后 `make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang -j"$JOBS"` |

工具链版本**从 `build.config.constants` 读，不要写死**（这棵树上实测 `CLANG_VERSION=r536225`，即 clang 19.0.1）。

构建目录的三个硬约束：

1. **绝对不要建在 `/sdcard` 上。** 它是 FUSE 挂载，不提供真正的权限位与符号链接语义，内核构建会在很早期就以莫名其妙的错误失败。树和 `out/` 都放在 PRoot 的 `$HOME` 下（ext4）。
2. 源码树 + `out/` 需要 **40G 左右**（Thin LTO 更费）。PRoot 根镜像要留够。
3. `-j` 用 **核心数 −2**，不要用 `nproc`。留出的核给温控与系统，慢约 25%，但换来不 OOM、不过热。

### 闸门 5：让构建活下来

Android 会在后台杀掉长任务，即使前台服务、wake lock、电池优化白名单都开了。三层一起上：

```bash
setsid nohup tmux new -d -s k "bash -lc 'make ... 2>&1 | tee logs/build-$(date +%s).log'"
tmux attach -t k
```

```bash
# 控温：宁可慢，不要热到降频再更慢
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  echo 1800000 > "$p/scaling_max_freq" 2>/dev/null
done
# 守护：>43℃ 暂停编译器，<40℃ 恢复
while :; do
  t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
  t=$((t / 1000))
  if [ "$t" -gt 43 ]; then kill -STOP $(pgrep -f clang) 2>/dev/null
  elif [ "$t" -lt 40 ]; then kill -CONT $(pgrep -f clang) 2>/dev/null; fi
  sleep 30
done
```

- 需要 swap 时用 swapfile（`fallocate -l 16G`，`mkswap`，`swapon`），**不要把 swappiness 拉到 100**——内核构建的匿名页压力下这会引发抖动；80 左右足够。
- 摘掉手机壳、别放在充电垫上。充电 + 满载是双重发热源，能只充到 80% 再拔掉更好。

### 闸门 6：确认产物

| 构建系统 | 产物位置 |
| --- | --- |
| legacy | `out/arch/arm64/boot/Image`、`Image.lz4`、`out/arch/arm64/boot/dts/vendor/*.dtb`、`out/arch/arm64/boot/dtbo.img` |
| Kleaf | `out/dist/`：`Image.lz4`、`dtb.img`、`dtbo.img`、`boot.img`、`vendor_boot.img`、`system_dlkm.img`、`vendor_dlkm/*.ko` |

**REQUIRED SUB-SKILL:** anykernel3-packaging —— 把 Image 与模块打成可刷 zip。

## 关键约束：哪些配置绝对不能顺手改

| 项 | 为什么不能动 |
| --- | --- |
| `CONFIG_LTO_CLANG_THIN` | 关掉省 ~30% 时间与大量内存，但**厂商预编译的 vendor 模块可能因此拒载**，表现是开机卡 logo 后 panic |
| `CONFIG_MODVERSIONS` | 保持开。关掉等于放弃符号版本校验，vendor 模块与内核符号对不上时不会报明确错误，只会崩 |
| `CONFIG_TRIM_UNUSED_KSYMS` | 保持关。开了会把 vendor 模块需要的符号裁掉 |
| `CONFIG_MODULE_SIG_FORCE` | 保持关。开了会拒绝所有非 OEM 签名模块 |
| `CONFIG_DEBUG_INFO` | **不要为了提速而关**。它和 `CONFIG_DEBUG_INFO_BTF` 互相依赖（BTF 由 DWARF 生成），关掉前者会让后者直接构不出来 |

配置改动的正确姿势：拿闸门 2 的 `stock.config` 做基线，用 `scripts/config` 只改你要改的项，然后 `make olddefconfig` 让 Kbuild 补齐依赖。**不要手写一份完整 defconfig**，也不要一次改十几项——先保证能开机，再迭代。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 以为能直接跑 AOSP 预编译 clang | `Exec format error`，或花了几个小时才发现 | 先 `file $(command -v clang)` |
| 用交叉编译器救场 | 同样是 x86_64 二进制，白折腾 | 问题在主机架构，不在目标架构 |
| 在 `/sdcard` 上建树 | 权限/符号链接语义不对，构建早期诡异失败 | 建在 PRoot 的 `$HOME` |
| 猜 defconfig 名 | `No rule to make target` | `ls arch/arm64/configs/` |
| 刷完自制内核才想拿原厂 config | 窗口已过，只能反解 boot.img | 刷之前 `zcat /proc/config.gz` |
| 关掉 LTO/MODVERSIONS 提速 | vendor 模块拒载 → 不开机 | 保持树内默认，改动最小化 |
| 用 `-j$(nproc)` | OOM 或持续过热降频，实际更慢 | 核心数 −2 |
| 长时间构建不做防杀 | 编到 90% 被 Android 杀掉 | `setsid nohup tmux` + 前台服务 + wake lock |

## 时间与预期

手机上冷编一次 **2.5–4 小时起**，热节流会显著拉长。增量编译 15–30 分钟。**第一次出镜像建议直接走 CI**（方案 B），手机只负责打包与刷入——用几小时的手机发热换几分钟的云端构建并不划算。

## Real-World Impact

两条实测结论支撑了这个 skill，都来自「先核实再断言」而不是「看起来对就写下来」：

1. **工具链那条**：没有这个 skill 的 agent 会推荐 `apt install clang-18`，同时假设 AOSP 预编译 clang 可用，并把它指向一个 ARM64 环境——它自己也发现了矛盾却没给出可执行的结论。闸门 1 存在的意义就是在动手前 30 秒内把这个矛盾变成明确的二选一。
2. **源码树那条**：另一份基线报告给出了 13 条关于 `popsicle-w-oss` 的断言，独立核实后有 **11 条成立、2 条被推翻**——而被推翻的那两条（`tools/bazel` 不存在、`soc-repo/` 与 `external/` 不存在）**恰好就是「这棵树能不能构建」的答案**。同时核实补上了更致命的一条：这棵树**没有小米 17 的 defconfig**，根本无法用 `make` 走出内核镜像。

闸门 3 就是这两次教训的产物：**在花几个小时构建之前，先用一条命令确认树是完整的。**
