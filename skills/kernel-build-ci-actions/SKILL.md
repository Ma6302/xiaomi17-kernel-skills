---
name: kernel-build-ci-actions
description: 用于在 GitHub Actions 上构建 Android 内核并在手机上取回产物，包括判断源码树是否完整可构建、拼装多仓库 kernel_platform 工作区、写 workflow 与缓存策略、应对 runner 磁盘与 6 小时时限、以及在中国大陆触发构建与下载 Release 产物。当要在云端编译内核、clone 官方内核树发现缺文件、或手机端编译不可行时使用。
---

# 内核构建 CI

## Overview

手机端编译内核受工具链、散热、内存和 Android 后台查杀限制。云端 CI 是更可靠的路径。

但对于小米的官方内核树，**CI 的第一步不是写 workflow，而是判断「这棵树到底能不能构建」**。跳过这一步，你会写出一个永远失败的 workflow。

## When to Use

- 要在 GitHub Actions 上编内核。
- 克隆了官方内核树，发现 `kernel/sched/fair.c` 之类的核心文件不见了。
- 手机端编译行不通，想换云端。
- 中国大陆网络下要从手机触发构建、下载产物。

**何时不用**：只是改个 sysfs 参数（不需要编译）。

## 第零步：先判断树是否完整（本 skill 最重要的一步）

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

**2,686 是稀疏树，不是完整内核。** 它缺：`kernel/sched/fair.c`、`mm/memory.c`、`init/main.c`、`arch/arm64/Kconfig`、`net/wireless/nl80211.c`、`drivers/gpu/drm/msm/msm_drv.c`；根目录没有 `build/`、`prebuilts/`、`soc-repo/`、`external/`。

`arch/arm64/configs/` 里只有 6 个配置类文件，唯一的 `*_defconfig` 是 `generic_vm_defconfig`——**没有小米 17 / popsicle / pudding 的 defconfig**。

> 结论：`MiCode/Xiaomi_Kernel_OpenSource@popsicle-w-oss` **不能单独克隆即构建**。
> 用传统 `make ARCH=arm64 xxx_defconfig` 在这棵树上编出小米 17 内核**不可行**。

**这一步在任何构建动作之前做。** 判断依据是路径数量级（几千 vs 几万），不是读 README。

## 它需要什么：多仓库 kernel_platform 工作区

这棵树是 Qualcomm msm-kernel 布局，期望被放进一个父级 workspace：

```
kernel_platform/
├── build/          ← Kleaf（AOSP/Qualcomm 的 kernel/build）
├── common/         ← ACK GKI 内核源码
├── msm-kernel/     ← 本仓库（含 build_with_bazel.py、kleaf-scripts/、configs/）
├── soc-repo/       ← 引用了却不在这里
├── external/dtc/   ← 同上
└── prebuilts/      ← 同上
```

证据链（都可在树上直接验证）：

- `build_with_bazel.py` 里 `workspace = 脚本目录/..`，默认 `DEFAULT_MSM_EXTENSIONS_SRC = "../soc-repo/kleaf-scripts/msm_kernel_extensions.bzl"`、`DEFAULT_ABL_EXTENSIONS_SRC = "../bootable/bootloader/edk2/abl_extensions.bzl"`。
- `build.config.msm.popsicle` 全文只有两行，核心是 `. ${ROOT_DIR}/soc-repo/build.config.msm.canoe`。
- `bazel.WORKSPACE` 含 `new_local_repository(name = "dtc", path = "external/qcom-dtc", ...)`。
- `device.bazelrc` 引用 `//build/kernel/kleaf:*` 与 `//soc-repo:unsafe_headers_qcom_group`。
- `tools/bazel` **不在本仓库**（`tools/` 只有 `testing/`），由父级 workspace 提供；`build_with_bazel.py` 找不到它就 `exit 1`。

**manifest 的可得性（这是真正的门槛）**：

- **MiCode 不提供 manifest**：组织内没有 manifest 仓库；`Xiaomi_Kernel_OpenSource` 的 266 个分支里名字含 `manifest`/`platform` 的为 0。
- 高通 CLO 侧匿名只能读到 automotive 的 `kernelplatform/manifest`，其中**没有** sm8850 / canoe / release-w 条目。
- 对应清单走 CLO 的 `release-w-qcom-sm8850`，**需要账号**（匿名一律 401，且对故意编造的路径也返回 401，所以 401 不能证明仓库存在）。

**在你拿到 manifest 之前，这条路的实际可行性是未知的。** 诚实的做法是把这一点告诉使用者，而不是写一个看起来很完整的 workflow。

## 构建命令（拼好 workspace 之后）

```bash
# 在 workspace 根目录
python3 <kernel_dir>/build_with_bazel.py -t <target> <variant>
# 例：python3 msm-kernel/build_with_bazel.py -t popsicle perf
```

- `-t/--target TARGET VARIANT`：可重复；`VARIANT` 可为 `ALL`
- `-o/--out_dir`：默认 `{workspace}/out/msm-kernel-{target}-{variant}`
- `--cache_dir`：默认 `$CWD/bazel-cache`，同时设置 `TEST_TMPDIR`
- `-c/--menuconfig`、`-d/--dry-run`、`-s/--skip <rule>`、`--log {debug,info,warning,error}`
- 未识别的参数**原样透传给 bazel**

工具链版本**从 `build.config.constants` 读，不要写死**：`CLANG_VERSION=r536225`（= clang 19.0.1，2024-11）、`AARCH64_NDK_TRIPLE=aarch64-linux-android31`。`build.config.common` 用 **`LLVM=1`** 驱动全部工具选择（不是手写 CC/LD/AR 一长串）。

**取工具链时的一个坑（实测踩过）**：`build.config.constants` 里的值是 `r536225`，但 AOSP 仓库里的**目录名**是 `clang-r536225`。gitiles 归档 URL 必须写

```
https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r536225.tar.gz
```

写成 `.../r536225.tar.gz` 会返回 **HTTP 400**——注意是 400 不是 404，报错信息里没有任何线索指向「少了 clang- 前缀」。本地解压出来的目录也必须叫 `clang-r536225`，因为 `build.config.common` 找的是 `prebuilts/clang/host/linux-x86/clang-${CLANG_VERSION}/bin`。

先列目录再下载，可以省掉这一轮试错：

```bash
curl -fsSL 'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/refs/heads/main/?format=JSON' \
  | sed '1s/^)]}.'"'"'//' | grep -oE '"name": "clang-r[0-9]+"' | sort -u
```

**host 依赖里有一个反直觉的必装项**：`libdw-dev`。6.12 的 `CONFIG_MODVERSIONS` 用新的 `gendwarfksyms`（基于 DWARF 的符号版本）取代了老的 `genksyms`，它 `#include <dwarf.h>`。缺这个包时构建挂在

```
scripts/gendwarfksyms/gendwarfksyms.h:6:10: fatal error: 'dwarf.h' file not found
```

——**报错点是内核的 `scripts/` 目录，和「少装一个 -dev 包」这个真正原因看起来毫无关系**。完整的 host 依赖：

```bash
sudo apt-get install -y bc bison flex libssl-dev libelf-dev libdw-dev \
  make gcc tar xz-utils zip unzip cpio rsync python3 dwarves
```

## GitHub Actions 的硬约束

| 约束 | 数字 / 事实 | 对策 |
| --- | --- | --- |
| 磁盘 | runner 约 4 vCPU / 16 GB RAM / **~14 GB 可用**；内核构建要 20–40 GB | `jlumbroso/free-disk-space` 或 `easimon/maximize-build-space` |
| 时限 | 托管 runner 单 job **硬上限 6 小时**，larger runner 也是 | 拆 job / 用 self-hosted（只有它不受限） |
| clone 体积 | `Xiaomi_Kernel_OpenSource` 有 **1,260,958 个 commit / 266 个分支** | `fetch-depth: 1`；**不要** `submodules: recursive`；**不要** LFS |
| 缓存机制 | Kleaf 是 hermetic 工具链 + **Bazel action cache，ccache 无效** | `--disk_cache=<dir>` + `--repository_cache=<dir>` |
| 缓存配额 | `actions/cache` 每仓库 10 GB | 用 `actions/cache/restore` + `save` 分离，`save` 放 `if: always()` |

**不要**把 `build_with_bazel.py --cache_dir` 当跨 runner 缓存：它实际等价于 `--output_user_root`，跨机复用不可靠。

## 中国大陆：触发与取回

| 环节 | 现状 | 办法 |
| --- | --- | --- |
| 触发构建 | `workflow_dispatch` **只认默认分支上已存在的** workflow | 先把 workflow 合进默认分支 |
| 触发 API | `api.github.com` 通常可直连；被墙的主要是 `github.com` 网页与 `raw/objects.githubusercontent.com` | `curl -X POST .../actions/workflows/<f>.yml/dispatches`，需 fine-grained PAT（`Actions: Read and write` + `Contents: Read`） |
| 下载产物 | **artifact 需要登录且走被墙的 objects 域** | 用 **Release asset 匿名直链** |
| 反代 | ghproxy 之类随时失效 | 只用于下公开且有 SHA256 校验的产物 |
| 镜像 | Gitee Release 单附件 ≤100 MB | 或 rclone 推 R2 / OSS / COS；或 WebDAV |

**workflow 里必须产出 `SHA256SUMS`** —— 这是经过反代之后唯一能自证产物没被篡改的东西。

## Workflow 骨架

见 `references/build-kernel.yml`。复制到 `.github/workflows/` 后，**必须先把里面标注 `TODO 核实` 的项按你的实际 workspace 结构改对**。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 直接对稀疏树写 workflow | 永远失败，且错误信息指向缺文件而非配置错 | 先数路径数 |
| 照抄 `BUILD_CONFIG=… build/build.sh` | 这套 `build.sh` 在这棵树上不存在（AOSP 只为 ≤Android 12 或无 Kleaf 的分支保留它） | 用 Kleaf/bazel |
| 给 Bazel 构建配 ccache | 完全不起作用 | `--disk_cache` |
| 不设 `fetch-depth: 1` | clone 超时/爆盘 | 必须设 |
| 用 artifact 给手机下载 | 要登录且域名被墙 | Release asset + SHA256SUMS |
| 把工具链 clang 版本写死 | 换分支后编不过 | 从 `build.config.constants` 读 |
| 假设官方树一定能编 | 白花几天 | 先验证完整性，并准备好备用方案 |

## 备用方案一：改 AOSP GKI 树（首选，唯一实测确认公开可得）

**先想清楚一件事**：`BOARD_USES_GENERIC_KERNEL_IMAGE=true` 意味着设备启动的**本来就是 Google 的 GKI 内核**，厂商树里那个 Image 会被丢弃。你要改 zram / f2fs / 调度、要打 KernelSU，**改 GKI 树就够，根本不需要那棵厂商树**。

`aosp-mirror/kernel_common`（`android.googlesource.com` 的 GitHub 镜像）实测（2026-10）：

```bash
gh api repos/aosp-mirror/kernel_common/git/trees/android16-6.12?recursive=1 --jq '.tree|length'
# → 72991，且 truncated:false
```

| 分支 | 路径数 | Linux |
| --- | --- | --- |
| `android16-6.12` | **72,991**（`truncated:false`） | 6.12 |
| `android16-6.12-lts` | — | 6.12 |
| `android17-6.18` | — | 6.18 |

`android16-6.12` 上**有**：`Makefile`、`kernel/sched/fair.c`、`mm/memory.c`、`init/main.c`、`arch/arm64/Kconfig`、`build.config.gki.aarch64`、`build.config.common`、`arch/arm64/configs/gki_defconfig`。
**没有**：`tools/bazel`、`build/kernel/kleaf/`、`build/build.sh`、`prebuilts/`、`android/abi_gki_aarch64_qcom`。

关键含义：**它自带完整源码与顶层 `Makefile`，可以直接用 `make` 构建**；`build/`（Kleaf）与 `prebuilts/` 在别的仓库里，只有走 Bazel 才需要。所以这条路**绕开了整个 kernel_platform 拼装问题**。

选哪个分支**由实机 `uname -r` 与 KMI 世代决定**，不要从网上推。

两个**未经实测**的点，写 workflow 前先自己验证：

1. `make ARCH=arm64 LLVM=1 gki_defconfig` + `make … -j` 能否在这棵树上产出可启动的 `Image`。
2. 自编 GKI 内核对厂商模块（`dio_dma_mapper.ko`、`mi_kernel_monitor.ko`、`gpu_stats.ko`）的兼容性取决于 KMI 符号表，而 `android/abi_gki_aarch64_qcom` **在厂商树里、不在 GKI 树里**——需要从厂商树取来一起用。

## 备用方案二、三

2. **用一个已经拼装好的社区完整树**（社区内核仓库通常自带 `build.sh` 或能直接 `make`），在其上做功耗/压缩改动。
3. **不编译内核**：zram、调度参数、I/O 参数都可在已 root 的设备上通过 sysfs 调整，`zram-compression-tuning` 覆盖了这部分，**不需要编译就能拿到大部分压缩收益**。
4. 拿到 Qualcomm CLO 账号后按 manifest 拼 `release-w-qcom-sm8850`。

## Real-World Impact

基线里 agent 对源码树的断言经过了独立核实：13 条断言中 **11 条 CONFIRMED、2 条 REFUTED**——而这两条被推翻的（`tools/bazel` 不存在、`soc-repo/` 与 `external/` 不存在）**恰好就是「这棵树能不能构建」的答案**。同一份报告里另外几条关键结论（没有小米 17 的 defconfig、`arch/arm64/configs/vendor/` 404）也是在那次核实中补上的。

这就是为什么本仓库把「断言」和「核实过的断言」分开对待：**看起来完整的技术方案，可能整个建立在一个未经检查的前提上。**
