---
name: kernel-build-ci-actions
description: 用于判断 GitHub Actions 云端 CI 到底能证明什么、不能证明什么：源码树血统自检、编译期冒烟测试、ABI 第①项校验，以及在中国大陆触发 workflow 并把产物取回手机。当 agent 打算用 CI 编一个可刷内核、想拿 CI 的结果证明内核能开机、看到 workflow 命中 load BTF from vmlinux 就自动关 CONFIG_DEBUG_INFO_BTF 重编、或者需要为 skill 里的断言留下可复现证据时使用。
---

# 云端 CI：它能证明什么，不能证明什么

## Overview

**CI 不能替代本地构建，也不能证明内核能开机。唯一能证明开机的是真机刷入。**

这个 skill 的定位是被实测逼出来的。它的上一版（连同当时 `android-kernel-build-on-device` 的旧版「换哪棵树」一节）把 agent 引向了 `aosp-mirror/kernel_common`，代价是**三次失败刷机 + 三天排查**：那棵树缺一整层小米/高通适配，**即使 ABI 100% 对齐也卡第一屏**。这两个 skill 都已按真机实测改写。

所以本 skill 只保留 CI 的三种**正当**用途：

1. 对 pin 死的上游树做**血统自检**（不编译，几十秒，最便宜也最值钱）；
2. **编译期冒烟测试 + ABI 四重校验的第 ① 项**；
3. 把**可复现的证据**留在仓库里（这正是本仓 `AGENTS.md` 允许的唯一一种内核 workflow）。

## When to Use

- 打算用 GitHub Actions 编内核，或者已经开写 workflow。
- 想用 CI 的绿色勾证明「内核能用 / 能开机」。
- 在别人给的 workflow 里看到：命中 `load BTF from vmlinux` 后自动 `./scripts/config -d DEBUG_INFO_BTF` 重编。
- 需要为某个 skill 里的断言留下可复现的证据。
- 在中国大陆网络下从手机触发 workflow、把产物取回手机。

**何时不用**：真要一个可刷的内核 → 本地或 WSL 构建。

**REQUIRED SUB-SKILL:** `android-kernel-build-on-device` —— 选哪棵树、`_setup_env.sh`、本地真实构建；本 skill **不**编可刷内核。

**REQUIRED SUB-SKILL:** `anykernel3-packaging`（只打包）、`safe-kernel-flash`（只刷入）。

## 铁律一：CI 的绿色勾不等于能开机

| CI 能证明 | CI 不能证明 |
| --- | --- |
| clone 到的树就是 pin 死的那一棵 | 内核能在这台设备上启动 |
| 这棵树 + 这套工具链在干净机器上能编过 | 厂商模块（`vendor_dlkm` 里几百个 `.ko`）能加载 |
| `Module.symvers` 与树自带 ABI 基线该对齐的部分对齐 | 显示链路能起来（`msm_drm.ko` 只是必要条件） |
| 同一 commit + 同一工具链下产物可复现 | 刷进去不会变砖 |

实测反例（2026-10-08）：修复版内核四项 ABI 校对全部通过 —— `msm_drm` DIFF=0、`struct module` 1600 字节 / 75 成员、`kobject_uevent_env` = 0x8bb6d45c —— **仍然卡第一屏**。

**ABI 是必要条件，不是充分条件；决定能不能开机的是源码树血统。** 用错的树对齐出来的 ABI，对齐得再准也不充分 —— 它只会给你虚假的安全感。

## 铁律二：唯一可用的树是 cctv18，不是 AOSP 上游

| 树 | 结果 |
| --- | --- |
| `aosp-mirror/kernel_common`（Google 上游 GKI，滚动分支） | ✗ 缺小米/高通适配层，**开不了机** |
| `cctv18/android_gki_kernel_common` @ `android16-6.12-2026-03` | ✓ 实测开机成功 |

pin 死的上游（**必须写 commit，只写分支名等于没 pin**）：

```
url     = https://github.com/cctv18/android_gki_kernel_common
branch  = android16-6.12-2026-03
commit  = 58ee67741556c83c523f48518284c4a6b1ef31d6
```

本地实测基线（2026-10-08，WSL2 Ubuntu 24.04，16 核 / 12GB）：`make` 全程 **6 分 19 秒**，`error count 0`，`Image` = **41,896,448 字节**；交付口径是 **md5**。

> 对照：同期在免费 4 vCPU runner 上用 CI 编 AOSP 上游树花了 **32 分 54 秒**。
> **CI 的意义不是「编得快」，也不是「证明能开机」。**

血统判据都是 grep，不需要编译：`Makefile` 的 `SUBLEVEL = 69`、`arch/arm64/configs/gki_defconfig` 首行 `CONFIG_LOCALVERSION="-4k"`、该文件里 `GKI_TASK_STRUCT_VENDOR_SIZE_MAX` = **1024**（AOSP 上游默认 512）。逐条展开见下节。

## CI 的正当用途一：血统自检

这段逻辑与内核工程仓的 `scripts/fetch-sources.sh` 是同一件事，搬进 CI 后**不编译**、几十秒出结果：

1. `git ls-remote` 读远端分支当前 SHA（**只报告，不据此失败** —— 我们 pin 的是历史 commit，远端移动是正常的）。
2. clone 后断言 `git rev-parse HEAD` 等于 pin 的 commit；不等就 `fetch --depth=1 <sha>` 精确检出；仍不等则失败。
3. 断言 `Makefile` 里 `SUBLEVEL = 69`（与设备原厂内核版本号一致）。
4. 关键文件存在性：`_setup_env.sh`、`gki/aarch64/abi.stg`、`build.config.gki`、`build.config.constants`、`arch/arm64/configs/gki_defconfig`、`kernel/sched/fair.c`、`mm/memory.c`、`init/main.c`、`include/linux/module.h`、`kernel/trace/Kconfig`。
5. **路径数**：实测基线约 **87186** 个文件。数量级判断 —— 几千条就是稀疏树，立刻停。
6. 厂商适配标志 grep（`GKI_HACKS_TO_FIX`、`GCMA`、`RT_SOFTIRQ_AWARE_SCHED`、`UNWIND_PATCH_PAC_INTO_SCS`、`SCHED_PROXY_EXEC`、`MODULE_SCMVERSION`、`CPUSETS_V1`、`MEMCG_V1`、`AUTOFDO_CLANG`）——**这些项全部由 cctv18 树自带，AOSP 上游树里根本没有对应的 Kconfig**。

第 5 条不能省。小米官方那棵树（`MiCode/Xiaomi_Kernel_OpenSource@popsicle-w-oss`）只有 **2,686** 条路径：能 clone、有 `Makefile`，但缺 `kernel/sched/fair.c`、`mm/memory.c`、`init/main.c`。**不数路径数，它会以「缺文件」的形式失败，而错误信息指向的地方和真正的原因毫无关系。**

## CI 的正当用途二：冒烟测试 + ABI 第 ① 项

目的是回答「这棵树 + 这套工具链在干净机器上能不能编过」，**不是**产出一个能刷的 Image。

ABI 四重校验里，**CI 只做得了第 ① 项**：

| 校验 | 判据 | CI 能不能做 |
| --- | --- | --- |
| ① 全量 CRC vs 树自带 `gki/aarch64/abi.stg` | **DIFF = 0**（基线 **10235** 个符号） | ✓ 只需要 `Module.symvers` |
| ② 设备真实模块的 `__versions` 段 | `msm_drm.ko`（851 符号）DIFF = 0 | ✗ 需要从设备拉 `.ko` |
| ③ BTF 结构体尺寸 | `struct module` = **1600 字节 / 75 成员** | 需要 `vmlinux` + 正确来源的 `pahole` |
| ④ 关键符号单点核对 | `kobject_uevent_env` = **0x8bb6d45c** | 可做，但不独立 |

① 有一个**归一化陷阱**，写错会把 100% 的对齐报成 100% 的 DIFF：

```python
# 错："0xaebcaf80".lstrip('0')  ->  "xaebcaf80"
# 对：先去掉 0x 前缀，再去前导零
crc = s[2:] if s.startswith('0x') else s
crc = crc.lstrip('0') or '0'
```

判定口径是 **`DIFF == 0`**，**不是**「对齐率 100%」：`msm_drm.ko` 的 851 个符号里有 150 个 MISSING，它们归属其他 vendor 模块，不在 GKI ABI 表面内。凡是我们内核该提供的，CRC 必须全部一致。

四项全过 **≠** 必定开机（血统仍要正确）；但**任何一项不过 = 必定不开机**。

**REQUIRED SUB-SKILL:** `gki-abi-verification` —— 四重校验的完整方法论、②③④ 项的命令与判据（CI 只做得了 ①）。

## CI 的正当用途三：把可复现的证据留在仓库里

本仓 `AGENTS.md` 只允许一种内核产物留在 `xiaomi17-kernel-skills`：**「作为 skill 断言的可复现证据」的 workflow**。CI 跑出来的 `VERDICT.txt`、`Module.symvers`、ABI 比对输出、config 自检输出，就是这个证据。

证据要能回答「哪一次、什么输入、什么结果」，所以每次都必须记录：pin 的 commit、工具链版本、`pahole --version`、`kernelrelease`、以及产物的 **md5**。

> 本仓现有的 `.github/workflows/gki-build-check.yml` 是旧的 AOSP 上游树冒烟测试。它的结论（`Image` 编出来了）**不构成能开机的证据**；要更新就用 `references/build-kernel.yml`。

## workflow 必须写对的九件事

| # | 要求 | 为什么 |
| --- | --- | --- |
| 1 | clone `cctv18/android_gki_kernel_common` 并**断言 commit SHA** | 分支名会动；不开机时无法复原现场 |
| 2 | 工具链版本**从 `versions.lock` 取**，不写死 | 实测值：`clang r536225`（19.0.1）、`rust 1.82.0.p2` |
| 3 | `. ./_setup_env.sh` | 它导出 `KBUILD_GENDWARFKSYMS_STABLE=1`；缺它 → CRC 全错 |
| 4 | **不要 `set -u`** | `_setup_env.sh` 引用 `_SETUP_ENV_SH_INCLUDED`、`KLEAF_INTERNAL_NO_BUILD_CONFIG` 等可能未定义的变量，`set -u` 下立刻 abort |
| 5 | **不引入 ftrace** | `STACK_TRACER` 会 `select FUNCTION_TRACER`，`struct module` 从 1600/75 变 1664/77 |
| 6 | 关键文件 + 路径数自检 | 稀疏树以「缺文件」的形式失败，且报错点误导 |
| 7 | 产物收 **md5** | 仓内交付口径只有 md5，见下 |
| 8 | `pahole` 来源检查 + **明确失败** | 见下节，这是本 skill 修掉的那个坑 |
| 9 | 失败时**不降级重编** | 降级会掩盖真实的编译错误 |

**关于 md5**：内核工程仓里交付镜像与刷机包的既有口径**只有 md5**（`versions.lock` 的 `image_md5` / `package_md5`），**全仓没有 `Image` 的 sha256**。唯一一处 sha256 出现在历史 CI 产物的记录里 —— 那是那一次**自加的**口径，不是仓内口径。所以 workflow 里产 `md5sum`；如果哪天真要写 sha256，必须在文件里标明它是自加的。

另外：**CI 产物的 md5 不会等于交付镜像的 md5**（署名、路径、时间都可能不同）。它是**本次构建的自证指纹**，不是拿去做交付比对的常量。

## 必须删掉的有毒自动降级

旧 workflow 里有一条逻辑：`make` 失败后 `grep -q 'load BTF from vmlinux' build.log`，命中就 `./scripts/config -d DEBUG_INFO_BTF` + `olddefconfig` + 重编。

**这条必须删掉。** 报错原文是：

```
FAILED: load BTF from vmlinux: Invalid argument
make[3]: *** [.../scripts/Makefile.vmlinux:45: vmlinux] Error 255
```

根因是**系统自带的 `pahole` 太旧** —— Ubuntu 24.04 是 `pahole 1.25`，它给 6.12 生成的 BTF 会被内核自带的 `resolve_btfids` 拒收。**这不是树不完整**：此时整棵树已经编到 `LD vmlinux`，前面几十分钟一个错都没有。

正确解法只有一条：

> **把 AOSP build-tools 里的 prebuilt `pahole` 放到 `PATH` 最前面。**

**绝不要**因为这个问题去关 `CONFIG_DEBUG_INFO_BTF`：关掉它，同一个报错位置会把**真正的编译错误**一起吞掉，你拿到一个「绿」的构建和一个解释不了的失败。

> 本仓 `.github/workflows/gki-build-check.yml` 是这个坑的历史现场：它只在**精确命中**该报错时降级一次，并在注释里自述那是「权宜之计」。它存在的目的是回答「AOSP 上游那条链走不走得通」，不是产出可信内核。**这个模式不要复制到任何新 workflow。**

正确写法不是「失败后重试」，而是**编之前就检查**：

```bash
PAHOLE_BIN="$(command -v pahole || true)"
echo "pahole = ${PAHOLE_BIN:-<none>} ($(pahole --version 2>/dev/null || echo '?'))"
case "$PAHOLE_BIN" in
  "$TC"/*) echo "OK: pahole 来自工具链目录" ;;
  *) echo "ERROR: PATH 上的 pahole 不是工具链自带的；BTF 一定会挂在 LD vmlinux"
     echo "       正解是把 AOSP 的 prebuilt pahole 放到 PATH 最前面"
     exit 1 ;;
esac
```

顺带一条：安装依赖时**刻意不要装 `dwarves`** —— 它会带来发行版的 `pahole 1.25`，正是那个编不出 BTF 的版本。`libdw-dev` 倒是必装（否则 `gendwarfksyms` 报 `dwarf.h: file not found`）。

**REQUIRED SUB-SKILL:** `references/build-kernel.yml` —— 完整可复制的 workflow，包含上面九件事，并且**没有**任何降级重编逻辑。

## 中国大陆：触发与取回（真实痛点）

| 环节 | 现状 | 办法 |
| --- | --- | --- |
| 触发 API | `api.github.com` **通常可直连**，不需要代理 | `curl -X POST -H "Authorization: Bearer $PAT" https://api.github.com/repos/<owner>/<repo>/actions/workflows/<file>.yml/dispatches -d '{"ref":"main","inputs":{...}}'` |
| `workflow_dispatch` 的前置条件 | **只认默认分支上已经存在的 workflow** | 先把 workflow 合进默认分支，再触发 |
| PAT 权限 | 越权没有必要 | fine-grained token：`Actions: Read and write` + `Contents: Read`（发 Release 才需要 `Contents: write`） |
| 网页与 raw | `github.com` 网页、`raw.githubusercontent.com`、`objects.githubusercontent.com` **常被墙** | 不要让流程依赖它们 |
| 取产物 | **artifact 需要登录，而且走被墙的 `objects` 域** | 用 **Release asset 的匿名直链**：`https://github.com/<owner>/<repo>/releases/download/<tag>/<file>` |
| 完整性 | 经反代/镜像之后无法确认产物没被改 | workflow 里**必须**产出校验和文件（本仓口径是 `md5sum`），并在 Release 正文里贴出来 |
| 反代 | ghproxy 之类随时失效 | 只用于下载公开、且带校验和的产物 |
| 手机侧 | 手机 agent 只需要能 `curl` 到 `api.github.com` 与 Release 直链 | 触发走 API、取回走 Release 直链；**不要**教它用浏览器登录 |

**Release asset 的匿名直链优于 artifact**，这在手机侧不是偏好问题而是可行性问题：artifact 下载要登录，而登录页在 `github.com`，恰好是常被墙的那一侧。

## 常见错误

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 用 CI 的绿色勾证明「内核能用」 | 把三次失败刷机的教训再学一遍 | 开机只由真机刷入证明 |
| clone `aosp-mirror/kernel_common` 去编可刷内核 | 即使 ABI 全对齐也卡第一屏 | 用 `cctv18/android_gki_kernel_common`，并断言 SHA |
| 命中 `load BTF from vmlinux` 就关 `CONFIG_DEBUG_INFO_BTF` | 掩盖真实的编译错误 | 换 prebuilt `pahole`；编前检查它的来源 |
| 把 CI 产物的 md5 与 `versions.lock` 里的 `image_md5` 比 | 永远不相等，白白报错 | CI 产物是**本次构建**的自证指纹 |
| 只 pin 分支名不 pin SHA | 上游一动，构建不可复现，失败现场无法复原 | 断言 `git rev-parse HEAD` |
| 写 `set -u` / 打开 ftrace / 不数路径数 / 用 `sha256sum` | 依次是：`_setup_env.sh` abort、`struct module` 变 1664/77、稀疏树缺文件、口径漂移 | 见上面「必须写对的九件事」 |

## UNVERIFIED / UNKNOWN

- **本 skill 的 workflow 在 CI 上跑过一次完整的 cctv18 构建** —— **UNVERIFIED**。本地 6 分 19 秒是实测；CI 上只实测过 AOSP 上游树（32 分 54 秒）。CI 上的耗时与峰值磁盘占用 **UNKNOWN**。
- **Rust / build-tools（`pahole`）在 AOSP 上的归档 URL** —— `clang-r536225` 的 gitiles 归档地址是实测可用的；`rust 1.82.0.p2` 与 `build-tools` 的**具体归档路径 UNVERIFIED**。workflow 里先用 gitiles 的 `?format=JSON` 列目录再取，取不到就明确失败。
- **`abi.stg` 解析器对这份文件方言的适配** —— 判据（DIFF=0 / 10235 个符号）来自 2026-10-08 实测，但 workflow 里内联的解析脚本 **UNVERIFIED**。这正是脚本里带「解析出的基线符号数不等于 10235 就中止」这道闸门的原因：宁可拒答，不要给出一个假的 DIFF。
- **具体是哪个厂商适配项决定能否开机** —— **UNVERIFIED**，未做逐个开关的二分验证。`GKI_HACKS_TO_FIX` 只是相关标志里最显眼的一个，**不是已证实的因果**。
- **`MI_SCHED_EXT` 的来源** —— **UNVERIFIED**（推测来自 `vendor_dlkm` 而非 GKI，未证实）。
- **内核安全补丁日期（SPL）对齐的影响** —— **UNKNOWN**（cctv18 树的 SPL 未核查）。
- **CI 产物的 md5 在各次运行之间是否稳定** —— **UNKNOWN**。
- **各厂商适配标志的确切归属**（`arch/arm64/configs/gki_defconfig` 本体，还是 fragment）—— 只有 `GKI_HACKS_TO_FIX` / `GKI_TASK_STRUCT_VENDOR_SIZE_MAX` / `GCMA` / `RT_SOFTIRQ_AWARE_SCHED` 这四项被内核工程仓的脚本当作核心判据；其余 **UNVERIFIED**，所以 workflow 里对它们只告警、不硬失败。

## Real-World Impact

**上一版这个 skill，连同当时 `android-kernel-build-on-device` 的旧版「换哪棵树」一节，把 agent 引向了 AOSP 上游树。代价是三次失败刷机 + 三天排查。**

三次都卡在开机第一屏（XBL splash），无声音、无振动；修复版一分多钟后闪一下屏、自动重启、循环。恢复方式是音量下 + 电源进 fastboot，然后刷回原厂 `boot`。**修复版把四项 ABI 全部对齐了 —— `msm_drm` DIFF=0、`struct module` 1600/75、`kobject_uevent_env` 0x8bb6d45c —— 仍然开不了机。** 换成 cctv18 树之后，一次编译（6 分 19 秒）加一次刷机就成功。

那次失败暴露的是一个安全假象：**「CI 全绿 + ABI 全对齐」看起来像充分条件，实际只是必要条件。** 一个只看绿色勾的 agent，会把一个开不了机的产物推给用户去刷。所以本 skill 的第一句话就是「CI 不能证明内核能开机」。

**REQUIRED SUB-SKILL:** `safe-kernel-flash` —— 真要刷入时走它（本 skill 不覆盖刷入与回滚）。
