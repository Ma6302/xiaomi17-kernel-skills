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

## 方案 A：用发行版原生 clang（手机上唯一实用的路）

Ubuntu 24.04 aarch64 自带 clang-18 / lld-18，是**原生 aarch64 二进制**，可以直接跑。

```bash
apt update
apt install -y clang-18 lld-18 llvm-18 llvm-18-tools \
               build-essential bc flex bison libssl-dev libelf-dev \
               dwarves cpio rsync zip xz-utils python3 perl git
```

装完立刻验证这几个都指向 18 且能跑：

```bash
clang --version
ld.lld --version
llvm-ar --version && llvm-nm --version && llvm-objcopy --version && llvm-strip --version
pahole --version        # BTF 生成需要它，缺了 CONFIG_DEBUG_INFO_BTF 会失败
```

构建时显式指定（不要让 Kbuild 去猜）：

```bash
make -j"$JOBS" \
  O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf \
  HOSTCC=gcc HOSTCXX=g++ \
  <defconfig 名>
```

### 方案 A 的风险（必须知道）

1. **保真度不如 AOSP clang。** 厂商内核树是拿 AOSP clang-r5xx 验证的；发行版 clang-18 版本号不同，个别 `-Werror` 或内联汇编写法可能编不过。编不过就改这些点，不要靠加 `-Wno-error` 全关掉。
2. **BTF 与 pahole 版本**。`CONFIG_DEBUG_INFO_BTF=y` 需要 pahole 支持 `--btf_gen_flags`；Ubuntu 24.04 的 dwarves 通常够，但树里可能要求 `pahole >= 1.16/1.24`。编 BTF 失败时先看 `scripts/link-vmlinux.sh` 的报错，必要时临时关 BTF——**但关 BTF 会让部分 vendor 模块加载失败，只能作为最后一招并记录在案**。
3. **`libssl-dev` 与 `libelf-dev`** 缺一个都会在很早的阶段失败，报错信息很不直观。
4. **`LLVM_IAS=1` 不要关**。关掉会退回 GNU as，与 Clang 的组合在 Android 树上经常编不过。

## 方案 B：在 x86_64 CI 上用真正的 AOSP clang（推荐默认）

既然 AOSP clang 只在 x86_64 上有，那就去 x86_64 上编译。手机只负责触发和下载产物。

```bash
gh workflow run kernel.yml -R <owner>/<repo> -f defconfig=<名字>
gh run watch -R <owner>/<repo>
gh run download -R <owner>/<repo>        # 或从 Release 下载
```

这条路的好处：能用 `android_prebuilts_clang` 的正确版本、有 4–16 核、不会把手机烧到降频、失败可复现。

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
```

两者都满足才继续本地编译；否则直接走方案 B。
