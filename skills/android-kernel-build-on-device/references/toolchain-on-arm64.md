# 在 ARM64 手机上编译 Android 内核：工具链问题

这是手机端编译的**头号阻塞点**。先把结论说清楚，再给可执行路径。

## 为什么不能直接用 AOSP 预编译 clang

AOSP 的官方内核工具链来自 `platform/prebuilts/clang/host/linux-x86`。
注意路径里的 `host/linux-x86`——**它只有 x86_64 主机的二进制**，根本没有 `linux-aarch64` 变体。

在手机的 PRoot Ubuntu 24.04（aarch64 用户空间）里执行它，结果是：

```
cannot execute binary file: Exec format error
```

先自己验证一遍，别信任何人（包括这份文档）：

```bash
file "$CLANG_DIR/bin/clang" | grep -q x86-64 && echo "x86_64 二进制 —— 在手机上跑不了"
```

`uname -m` 返回 `aarch64` 就意味着：**AOSP 预编译 clang 这条路在手机上是死的**，除非装 qemu 用户态模拟（见下文方案 C，不推荐）。

**但要分清两件事**：AOSP prebuilt clang 在 aarch64 手机上跑不了（主机架构不匹配）；
它同时又是**版本权威** —— 实测能开机的那次构建用的正是它（`clang-r536225`，clang 19.0.1），
跑在 x86_64 主机（PC / WSL / CI）上。所以「不能用」只在手机侧成立，**不要把结论错误地
推广成「发行版 clang 随便哪个版本都行」** —— 那是未验证的偏离，见方案 A 的风险。

## 方案 A：用发行版原生 clang（手机上唯一实用的路）

Ubuntu 24.04 aarch64 自带 clang-18 / lld-18，是**原生 aarch64 二进制**，可以直接跑。

```bash
apt update
apt install -y clang-18 lld-18 llvm-18 llvm-18-tools \
               build-essential bc flex bison libssl-dev libelf-dev libdw-dev \
               cpio rsync zip xz-utils python3 perl git
```

装完立刻验证这几个都指向 18 且能跑：

```bash
clang --version
ld.lld --version
llvm-ar --version && llvm-nm --version && llvm-objcopy --version && llvm-strip --version
```

注意这里**故意不装 `dwarves`**（它提供系统 `pahole`）。原因见下一节——
Ubuntu 24.04 的系统 pahole 编不出 6.12 的 BTF，装了反而会踩坑。

`libdw-dev` 是必需的：6.12 的 `CONFIG_MODVERSIONS` 用基于 DWARF 的 `gendwarfksyms`
取代老 `genksyms`，它 `#include <dwarf.h>`，缺了会以

```
scripts/gendwarfksyms/gendwarfksyms.h:6:10: fatal error: 'dwarf.h' file not found
```

挂在内核 `scripts/` 目录里 —— 报错点和真正的原因（少装一个 `-dev` 包）看起来毫无关系。

构建时显式指定（不要让 Kbuild 去猜）：

```bash
make -j"$JOBS" \
  O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf \
  PAHOLE="$TC/build-tools/build-tools/bin/pahole" \
  HOSTCC=gcc HOSTCXX=g++ \
  <defconfig 名>
```

构建链路本身不是 `make` 一条命令：GKI 树必须先 `source ./_setup_env.sh`（它导出
`KBUILD_GENDWARFKSYMS_STABLE=1`，缺了符号 CRC 全错），而且**构建脚本不能设 `set -u`**。
细节见 SKILL.md 的构建步骤与 Common Mistakes。

### 方案 A 的风险（必须知道）

1. **版本必须与 `build.config.constants` 的 `CLANG_VERSION` 一致。** 这不是偏好问题：
   厂商模块（`vendor_dlkm` 里的 404+ 个 `.ko`）是拿一个特定 clang 版本编的，符号 CRC 由
   `gendwarfksyms` 递归推导。树上实测 `CLANG_VERSION=r536225`（即 clang **19.0.1**，
   revision 12833971）。**装 clang-18 是一个未被验证的偏离** —— 编得出来不等于开得了机。
   手机上能拿到哪个 LLVM 版本，先用 `apt-cache policy clang-19` 之类确认；拿不到 19 就别指望
   本地编译的结果与实测开机的那一套对齐。

   > `UNVERIFIED`：手机上用发行版原生 clang-18/19 编出的产物能否开机，未在设备上验证过。
   > 已实测能开机的那次构建用的是 x86_64 主机 + AOSP prebuilt `clang-r536225`。
2. **`LLVM_IAS=1` 不要关**。关掉会退回 GNU as，与 Clang 的组合在 Android 树上经常编不过。
3. **`libssl-dev` 与 `libelf-dev` 缺一个都会在很早的阶段失败**，报错信息很不直观。

## pahole：必须用 AOSP build-tools 里的 prebuilt（★ 别在这里走错路）

`CONFIG_DEBUG_INFO_BTF=y` 的 BTF 由 `pahole` 生成，再由内核自带的 `resolve_btfids` 校验。
**版本不匹配时校验会直接失败**：

```
FAILED: load BTF from vmlinux: Invalid argument
make[3]: *** [scripts/Makefile.vmlinux:45: vmlinux] Error 255
```

**关键判断：这不是树不完整。** 报这条错时整棵树已经编到 `LD vmlinux` 了 —— 源码、配置、
工具链全都对，只有 `pahole` 这一个工具不对。Ubuntu 24.04 自带的 **pahole 1.25** 为 6.12
生成的 BTF 就会被 `resolve_btfids` 拒收。

正确解法只有一个：**用 AOSP `build-tools` 里的 prebuilt pahole，并让它排在 `PATH` 最前面。**

```bash
export PATH="$TC/build-tools/build-tools/bin:$PATH"
export PAHOLE="$TC/build-tools/build-tools/bin/pahole"
"$PAHOLE" --version                    # 确认用的是 prebuilt，不是 /usr/bin/pahole
```

prebuilt pahole 与 clang 一起发布。实测可用的取用点（x86_64 主机）：

```
https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225/
  clang-r536225.zip      # clang / ld.lld / llvm-*
  rust.zip               # rust 1.82.0.p2
  build-tools.zip        # ★ 内含 prebuilt pahole
```

### 绝不要做的事：临时关掉 `CONFIG_DEBUG_INFO_BTF`

`./scripts/config --file out/.config -d DEBUG_INFO_BTF` 能让构建「成功」，因此很容易被当成
省事的绕过办法。**它是错误的，不要用**：

- 它**掩盖的是真实的编译/工具链错误**，换来的不是「少一个功能」而是一个你无法信任的产物。
  下次真出错时，你面对的是同一个被掩盖的报错和一份已经偏离基线的配置。
- BTF 不是可选项：`/sys/kernel/btf/vmlinux` 缺失会影响 BPF CO-RE 相关程序与部分追踪工具。
- 实测路径里没有一次是靠关 BTF 成功的。**修 pahole，不要修症状。**

> 唯一可以谈降级的场景：报错**逐字命中**上面那段文本、且 prebuilt pahole 确实拿不到。
> 这时要在日志里明确记录「BTF 已关闭、pahole 版本 X、原因 Y」，并把它当作 `UNVERIFIED` 构建。

## 方案 B：在 x86_64 CI 上用真正的 AOSP clang（推荐默认）

既然 AOSP clang 只在 x86_64 上有，那就去 x86_64 上编译。手机只负责触发和下载产物。

```bash
gh workflow run kernel.yml -R <owner>/<repo> -f defconfig=<名字>
gh run watch -R <owner>/<repo>
gh run download -R <owner>/<repo>        # 或从 Release 下载
```

这条路的好处：能用 `android_prebuilts_clang` 的**正确版本**（与 `build.config.constants` 的
`CLANG_VERSION` 一致，实测 `r536225`）、有 4–16 核、不会把手机烧到降频、失败可复现。
实测可用的一次构建就是这条路：x86_64 主机，16 核 / 12GB，`make rc=0`、6 分 19 秒、error count 0。
工具链的公开取用点见上面 pahole 一节的 release 目录。

但是：**CI 只是让你编得出来，编出来的东西能不能开机，取决于源码树血统** —— 见 SKILL.md 第零步。

**REQUIRED SUB-SKILL:** kernel-build-ci-actions —— 完整的 workflow 与工件管理。

什么时候仍要在手机上编：只有小改动、需要立刻验证、且 CI 排队太久时。改动大或第一次出镜像，优先 CI。

## 方案 C：qemu 用户态模拟 x86_64 clang（不推荐）

理论上可以 `apt install qemu-user-static binfmt-support`，注册 binfmt handler，让 aarch64 内核能执行 x86_64 ELF，然后把 AOSP clang 目录接上去。

现实是：**编译速度掉到 1/10 到 1/20**，一个 3 小时的构建变成两三天，而且 qemu 对某些 clang 内部特性支持不全，会以诡异方式崩溃。只在「方案 A 编不过、CI 也不可用」时才考虑，且要预期它失败。

## 方案 D：交叉工具链（不成立）

`apt install gcc-aarch64-linux-gnu` 拿到的是 **aarch64 目标**编译器，运行在 x86_64 主机上。它的主机侧仍是 x86_64 二进制，在手机上照样 `Exec format error`。**交叉编译器解决不了「主机架构不对」这个问题**，这是最常见的误解。

## 一句话判据

```bash
uname -m                       # aarch64 → 只能用发行版原生 clang（方案 A）或去 CI（方案 B）
file $(command -v clang)       # 必须是 aarch64 ELF，不是 x86-64
"$PAHOLE" --version            # 必须指向 AOSP build-tools 的 prebuilt，不是系统 pahole
grep CLANG_VERSION build.config.constants   # 工具链版本以这里为唯一权威
```

前两条都满足才继续本地编译；否则直接走方案 B。

> **工具链只是必要条件之一。** 即使工具链、配置、ABI 全部对齐，**选错源码树照样开不了机** ——
> 本仓上一版正是在这里给出了「AOSP 上游树够用」的错误结论，代价是三次刷机失败。
> 开工前先过 SKILL.md 的选树闸门。
