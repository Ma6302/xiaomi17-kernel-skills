# xiaomi17-kernel-skills

给 **AI Agent** 用的 Android 内核技能包。目标设备是小米 17 系列（SM8850 / 骁龙 8 Elite Gen 5 / Linux 6.12 GKI），运行环境是手机上的 Agent（如 [Operit](https://github.com/AAswordman/Operit)）。

**这些不是给人看的教程，是给 agent 的执行约束。** 每一份都写自一次「没有这个 skill 时 agent 真的会怎么做」的实测——包括它会在哪里翻车。

## 为什么存在

实测了 10 个场景下「没有 skill 的 agent」的行为。它自信、细节丰富、多数流程正确，但在几个地方**知道得不够精确**，而那些地方恰好都是变砖级或时间级代价：

| 场景 | 没有 skill 时的典型行为 |
| --- | --- |
| 侦察 | 从网上抄机型代号（把杜撰的 `diting` 当成候选）；不查 slot、不查 verity 状态 |
| 编译 | 假设 AOSP 预编译 clang 能在 ARM64 手机上跑（它自己都发现了矛盾，却没给出结论） |
| 配置 | 建议关 `CONFIG_DEBUG_INFO`，而那会让 `DEBUG_INFO_BTF` 直接构不出来 |
| 打包 | 漏掉 `PATCH_VBMETA_FLAG`；打算自己 `mkbootimg` 复刻厂商 ramdisk |
| 刷机 | 把 `--disable-verity flash vbmeta` 当常规步骤；完全没提 ARB |
| KernelSU | 从不确认用户当前用哪种 root，也不给卸载路径 |
| zram | 引用 Linux 7.3-rc6 的文档去配一台 6.12 的设备（`algorithm_params` 在 6.12 上不存在） |
| 验证 | 把 2% 的噪声当成功效（该基线自己承认了这一点，值得肯定） |
| CI | 断言源码树「可以直接构建」（后来被独立核实推翻） |
| 建仓 | 许可证与 patch-stack 形状都选对了，但推荐了一个实测会失败的 fetch 组合，并把「`--depth 1` 检不出任意 SHA」当成事实（已实测推翻）；同时默认「内核补丁都是 GPL-2.0」——而 KernelSU 只有 `kernel/` 是 GPL-2.0-only，`susfs4ksu` 的 LICENSE 是 GPLv3 全文 |

## 十个 skill

| skill | 解决什么 |
| --- | --- |
| [`xiaomi17-device-recon`](skills/xiaomi17-device-recon/SKILL.md) | 把设备事实变成落盘档案：代号、KMI、slot、verity、ARB。任一 UNKNOWN 即 BLOCKED |
| [`android-kernel-build-on-device`](skills/android-kernel-build-on-device/SKILL.md) | 六道闸门判断手机能不能编，以及**先确认源码树是完整的** |
| [`kernel-config-power-perf`](skills/kernel-config-power-perf/SKILL.md) | 一步一验证地改配置；拦截三个致命组合 |
| [`zram-compression-tuning`](skills/zram-compression-tuning/SKILL.md) | 先探测真机接口再写；区分 6.6 / 6.12 / 6.16 的语法差异 |
| [`anykernel3-packaging`](skills/anykernel3-packaging/SKILL.md) | 打包成可刷 zip，并用脚本机械检查结构 |
| [`safe-kernel-flash`](skills/safe-kernel-flash/SKILL.md) | 刷之前先确保「还有别的路可走」；ARB 到底管什么 |
| [`kernelsu-susfs-integration`](skills/kernelsu-susfs-integration/SKILL.md) | 先搞清当前 root，再打补丁链；SUSFS 必须 GKI 内置 |
| [`kernel-build-ci-actions`](skills/kernel-build-ci-actions/SKILL.md) | 云端构建、缓存策略、中国大陆触发与下载 |
| [`kernel-perf-verification`](skills/kernel-perf-verification/SKILL.md) | 用比值与置信区间判断「是不是真的更好」；`\|Δ\| < 2×CV` 就认输 |
| [`kernel-project-repo-bootstrap`](skills/kernel-project-repo-bootstrap/SKILL.md) | 内核工程另建仓：GPL-2.0 边界与 GPL-3.0 地雷、patch stack 而非 fork、补丁来源头、pin 死 SHA、`quiltimport`、ruleset 上锁的极限 |

## 部署到手机

```bash
bash scripts/validate-skills.sh                 # 先校验格式
bash scripts/install-to-operit.sh               # 再安装到 /sdcard/Download/Operit/skills/
```

`install-to-operit.sh` 会在格式不合规时**拒绝安装**，因为格式错的 skill 会被 Operit **静默忽略**——你不会收到任何报错，只是发现 agent 不遵守它。

默认用 `--copy` 而不是 `--link`：Operit 的 SAF 层对符号链接的跟随不可靠。

### 部署后的第一步：让手机 agent 采集设备事实

把下面这段直接粘给手机上的 agent：

```
请用 xiaomi17-device-recon 这个 skill，在你所在的这台设备上执行
scripts/collect-device-facts.sh --backup，把采集结果（device-profile.md 和
build.env）原样回执给我，并明确列出所有值为 UNKNOWN 的字段。
不要猜测任何一项；读不到就写 UNKNOWN。
```

## 分工：桌面写 skill，手机跑 skill

手机 agent 知道的是**快照**（这台设备当前的状态），不是**知识**（agent 在没有 skill 时会怎么翻车）。设备事实会随 OTA、换 ROM、换内核而失效，写进 skill 正文就会静默过期。

所以：

- **设备事实** → 写进运行时档案 `kernel-dev/device-profile.md`，由 agent 每次重新采集。
- **方法、陷阱、判据** → 写进 skill 正文，只写「怎么查」，不写「查到的值」。
- **手机不可替代的作用是验证**：GREEN 测试必须在真机上跑。

## 三个必须先知道的现实

### 1. 官方内核树不能单独构建

`MiCode/Xiaomi_Kernel_OpenSource@popsicle-w-oss` 只有 **2,686** 条路径（同组织其他分支约 76,000 条）。它缺 `kernel/sched/fair.c`、`mm/memory.c`、`init/main.c` 等核心文件，没有 `build/`、`prebuilts/`、`soc-repo/`、`external/`，**也没有小米 17 的 defconfig**（`arch/arm64/configs/` 里唯一的是 `generic_vm_defconfig`）。

它必须被放进多仓库 `kernel_platform` 父级工作区，而 **MiCode 不提供 manifest**（266 个分支里名字含 manifest/platform 的为 0），对应的 Qualcomm CLO 清单 `release-w-qcom-sm8850` 需要账号。

**在拿到 manifest 之前，「从官方源编一个小米 17 内核」这条路的可行性是未知的。** 现实的替代路径：

1. **改 AOSP GKI 树，而不是厂商树。** `BOARD_USES_GENERIC_KERNEL_IMAGE=true` 意味着设备启动的**本来就是 Google 的 GKI 内核**，厂商树里那个 Image 会被丢弃。而 `aosp-mirror/kernel_common` 是**实测确认的完整树**：`android16-6.12` 有 72,991 条路径（`truncated:false`），含 `Makefile`、`kernel/sched/fair.c`、`mm/memory.c`、`init/main.c`、`arch/arm64/configs/gki_defconfig`、`build.config.gki.aarch64`。要改 zram / f2fs / 调度、要打 KernelSU，改这棵树就够。选哪个分支（`android16-6.12` / `android16-6.12-lts` / `android17-6.18`）**由实机 `uname -r` 与 KMI 世代决定**。详见 [`android-kernel-build-on-device`](skills/android-kernel-build-on-device/SKILL.md)。
2. 用一个**已经拼装好的社区完整树**（自带构建脚本、能直接 `make` 的那种），在其上做功耗/压缩改动。
3. **先不编译**：zram、调度参数、I/O 参数都能在已 root 的设备上通过 sysfs 调整，`zram-compression-tuning` 覆盖了这部分。**相当一部分压缩收益不需要编译内核。**

> **一个可能让整件事变简单的实测结论**：AOSP GKI `android16-6.12` 的 `gki_defconfig` 里 `CONFIG_ZRAM_MULTI_COMP=y`、`CONFIG_F2FS_FS_COMPRESSION=y`、`CONFIG_SCHED_CLASS_EXT=y` 都已经是默认值。也就是说，「更好的压缩算法 + 更好的功耗控制」这个目标里，**配置层面的东西 GKI 早就开好了**——真正要做的是调 sysfs、选算法、换调度器，而不是先学会编内核。编译内核留给「要改源码」的那些需求（打 KernelSU/SUSFS 补丁、改调度器实现、加厂商驱动）。

### 1.5 「能不能编出来」已经真的验过了

不是推测。仓库里的 [`.github/workflows/gki-build-check.yml`](.github/workflows/gki-build-check.yml) 在 GitHub 托管 runner（4 vCPU / 16 GB）上完整跑通了一次，**32 分 54 秒**：

```
Image  33,286,656 字节
sha256 14adb4ec596b7bd4bff6b2ac5658dd06582f5bf5a74417bc2f3937604a5d31b7
file   Linux kernel ARM64 boot executable Image, little-endian, 4K pages
make -s kernelrelease = 6.12.52-4k-g105b5745f1d7
```

代价是两个坑，都写进了 skill：host 要装 **`libdw-dev`**（否则 `gendwarfksyms` 找不到 `dwarf.h`），以及发行版的 `pahole 1.25` 生成不出可用的 BTF（`FAILED: load BTF from vmlinux: Invalid argument`），这个 Image 是**关掉 `CONFIG_DEBUG_INFO_BTF` 后**产出的。

**注意「编得出 Image」≠「能开机」**：AVB/vbmeta、厂商模块加载、KMI 兼容性都还没验。见下面的未核实清单。

### 2. 手机端编译的内核树通常是 Qualcomm msm-kernel 布局

不是网上教程里的 `BUILD_CONFIG=... build/build.sh`（AOSP 只为 ≤Android 12 或无 Kleaf 的分支保留它）。这棵树用 Kleaf / Bazel，`build_with_bazel.py -t <target> <variant>`，产物在 `out/msm-kernel-<target>-<variant>/dist`。

工具链版本**从 `build.config.constants` 读**（实测 `CLANG_VERSION=r536225`，即 clang 19.0.1），不要写死。构建用 `LLVM=1`。

### 3. 机型号与代号不是一回事

`pudding` = 小米 17、`pandora` = 小米 17 Pro、`popsicle` = 小米 17 Pro Max，三者同属平台 `canoe`。

**但最终以真机 `getprop ro.product.device` 为准。** 代号写错的后果不是「显示不对」，而是 `device.name1` 防呆失效、defconfig/target 选错。

## 仓库约定

见 [`AGENTS.md`](AGENTS.md)。要点：

- `skills/<name>/{SKILL.md,references/,scripts/}`
- frontmatter 只有 `name` + `description`，合计 ≤1024 字符
- `description` 只写**触发条件**，**绝不概括流程**（否则 agent 会照 description 走而跳过正文）
- 脚本用 `bash scripts/x.sh` 调用，不写裸路径
- **不写入任何设备标识**（序列号、IMEI、账号）

## 参考的上游项目

只作为参考链接列出，**本仓库不包含它们的代码**：

- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) —— AK3 的配置语义以它自己的 README 为准
- [tiann/KernelSU](https://github.com/tiann/KernelSU)、[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)、[simonpunk/susfs4ksu](https://github.com/simonpunk/susfs4ksu)
- [capntrips/KernelFlasher](https://github.com/capntrips/KernelFlasher) —— 机内刷 AK3 zip
- [AAswordman/Operit](https://github.com/AAswordman/Operit) —— 目标 agent 环境
- [firelzrd/zram-ir](https://github.com/firelzrd/zram-ir) —— zram 即时重压
- [sched-ext/scx](https://github.com/sched-ext/scx) —— 注意 6.12 上可用的 kfunc 集与 7.x 不同

## 已验证清单

这些是**真的跑过**的，不是从文档抄的：

- `aosp-mirror/kernel_common@android16-6.12` 是完整树（72,991 路径，关键文件齐全），`make gki_defconfig` + `make Image` 在干净 runner 上**成功**，32m54s，产出 33 MB 的 ARM64 `Image`
- 该树 `gki_defconfig` 中 `ZRAM=m`、`ZRAM_MULTI_COMP=y`、`F2FS_FS_COMPRESSION=y`、`SCHED_CLASS_EXT=y`、`CFI_CLANG=y`、`MODVERSIONS=y`、`DEBUG_INFO_BTF=y`（数值取自 CI 实跑日志）
- `MiCode/Xiaomi_Kernel_OpenSource@popsicle-w-oss` 只有 2,686 条路径、缺 `kernel/sched/fair.c` 等核心文件、无 `build/`、无 `tools/bazel`、无 `arch/arm64/configs/*_defconfig` —— **不能单独构建**
- 代号 `pudding`=小米 17 / `pandora`=17 Pro / `popsicle`=17 Pro Max，同平台 `canoe`（来自 MiCode issue #40786 等，仍以实机 `getprop` 为准）
- `scripts/validate-skills.sh` 与 `scripts/install-to-operit.sh` 的行为（10 个 skill 全绿；安装幂等；格式错误会拒绝）

## 未核实清单（诚实记录）

这些是本仓库**没有**验证、或验证为否的：

- **自编 GKI 的 Image 能否在小米 17 上真正启动** —— **未验证**。AVB/vbmeta 处理、厂商模块（`dio_dma_mapper.ko`/`mi_kernel_monitor.ko`/`gpu_stats.ko`）能否加载、KMI 是否兼容，三样都没验（`android/abi_gki_aarch64_qcom` 在厂商树里，不在 GKI 树里）
- 官方树按 manifest 拼装后能否真正构建成功 —— **未知**（未做任何同步/构建）
- `soc-repo`、`common`、`build`(kleaf)、`prebuilts` 是否有公开来源 —— **无法判定**（CLO 对匿名一律 401，含故意编造的不存在路径，故 401 不能证明存在）
- `LTO`、`KERNEL_VERSION` 在树中的定义位置 —— **未知**（仅在 `build.config.constants` 与 `build.config.msm.common` 中有负证据）
- **手机端**完整编译 6.x arm64 Android 内核的实测耗时/峰值内存 —— **无可靠报告**（CI 上的 32m54s 不能外推到手机；AOSP prebuilt clang 只有 `host/linux-x86`，ARM64 PRoot 里跑不了，见 `android-kernel-build-on-device/references/toolchain-on-arm64.md`）
- BTF 失败的**确切**根因 —— 目前只知道「Ubuntu 24.04 的 pahole 1.25 复现，关掉 BTF 就过」，未逐一排除其他因素
- 小米 17 的完整分区表 —— **未由设备转储确认**
- ARB 计数器是否物理存储于 eFuse/OTP —— **未核实**
- 「小米 17 自编译 GKI 内核多例卡 bootloop 而 LKM 稳定」—— 流传于 XDA，**未实机复现**

## License

MIT，见 [LICENSE](LICENSE)。**刷机可能永久损坏设备**，风险自负。
