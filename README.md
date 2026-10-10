# xiaomi17-kernel-skills

给 **AI Agent** 用的 Android 内核技能包。目标设备是小米 17 系列（SM8850 / 骁龙 8 Elite Gen 5 / Linux 6.12 GKI），运行环境是手机上的 Agent（如 [Operit](https://github.com/AAswordman/Operit)）。

**这些不是给人看的教程，是给 agent 的执行约束。** 每一份都写自一次「没有这个 skill 时 agent 真的会怎么做」的实测——包括它会在哪里翻车。

## 为什么存在

实测了 10 个场景下「没有 skill 的 agent」的行为。它自信、细节丰富、多数流程正确，但在几个地方**知道得不够精确**，而那些地方恰好都是变砖级或时间级代价：

| 场景 | 没有 skill 时的典型行为 |
| --- | --- |
| 侦察 | 从网上抄机型代号（把杜撰的 `diting` 当成候选）；不查 slot、不查 verity 状态 |
| **编译** | **推荐 `aosp-mirror/kernel_common`，并断言它是完整树、能编出可启动内核**——这条建议后来在真机上**连续三次刷机失败、卡在第一屏、耗时三天** |
| 配置 | 建议关 `CONFIG_DEBUG_INFO`，而那会让 `DEBUG_INFO_BTF` 直接构不出来 |
| 打包 | 漏掉 `PATCH_VBMETA_FLAG`；把 `do.devicecheck=1` 当防呆（这个 AK3 fork 根本没实现它） |
| 刷机 | 把 `--disable-verity flash vbmeta` 当常规步骤；完全没提 ARB |
| zram | 引用 Linux 7.3-rc6 的文档去配一台 6.12 的设备（`algorithm_params` 在 6.12 上并不存在） |
| 验证 | 把 2% 的噪声当成功效（该基线自己承认了这一点，值得肯定） |
| **CI** | **断言源码树「可以直接构建」，并建议在 BTF 失败时自动关掉 `CONFIG_DEBUG_INFO_BTF`**——前者被实测推翻，后者会掩盖真实编译错误 |
| 建仓 | 许可证与 patch-stack 形状都选对了，但推荐了一个实测会失败的 fetch 组合，并把「`--depth 1` 检不出任意 SHA」当成事实（已实测推翻）；同时默认「内核补丁都是 GPL-2.0」——而 KernelSU 只有 `kernel/` 是 GPL-2.0-only，`susfs4ksu` 的 LICENSE 是 GPLv3 全文 |
| ABI | 完全没有这个概念——不知道符号 CRC 是由结构体布局递归推导出来的，不知道改一个配置就能让显示模块拒载 |

**加粗的两行不是「不够精确」，是「错得开不了机」。** 这个仓库存在的理由，主要就是这两行。

## 十个 skill

| skill | 解决什么 |
| --- | --- |
| [`xiaomi17-device-recon`](skills/xiaomi17-device-recon/SKILL.md) | 把设备事实变成落盘档案：代号、KMI、slot、root 模式与补丁分区、`boot_index`、ARB。任一必需字段 UNKNOWN 即 BLOCKED |
| [`android-kernel-build-on-device`](skills/android-kernel-build-on-device/SKILL.md) | 手机能不能编，以及**先确认源码树的血统**——选错树，后面全白做 |
| [`kernel-config-power-perf`](skills/kernel-config-power-perf/SKILL.md) | 改配置为什么是危险操作；八条红线；一次只加一项 fragment |
| [`zram-compression-tuning`](skills/zram-compression-tuning/SKILL.md) | 先探测真机接口再写；哪些节点这台机器上根本不存在 |
| [`anykernel3-packaging`](skills/anykernel3-packaging/SKILL.md) | 打包成可刷 zip，并用脚本机械检查结构 |
| [`safe-kernel-flash`](skills/safe-kernel-flash/SKILL.md) | 刷之前先确保「还有别的路可走」；ARB 到底管什么；为什么只备份 `boot` 是假备份 |
| [`gki-abi-verification`](skills/gki-abi-verification/SKILL.md) | **四重 ABI 校验**：符号 CRC、设备真模块的 `__versions`、`struct module` 尺寸、关键符号单点。四项全过 ≠ 能开机，但任一项不过 = 一定不能开机 |
| [`kernel-build-ci-actions`](skills/kernel-build-ci-actions/SKILL.md) | 云端构建、缓存策略、中国大陆触发与下载；以及 **CI 能证明什么、不能证明什么** |
| [`kernel-perf-verification`](skills/kernel-perf-verification/SKILL.md) | 用比值与置信区间判断「是不是真的更好」；以及什么才算这个设备上的证据 |
| [`kernel-project-repo-bootstrap`](skills/kernel-project-repo-bootstrap/SKILL.md) | 内核工程另建仓：GPL-2.0 边界、`versions.lock` 做唯一真相来源、许可证按目录划分、ruleset 上锁的极限 |

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

## 必须最先知道的三个现实

### 1. 选错源码树，ABI 再完美也开不了机

这是本仓库最重要的一条，也是花了三天和三次刷机换来的。

**`aosp-mirror/kernel_common`（Google 上游 GKI）编出来的内核，在小米 17 上开不了机。** 它能编出来、能过编译、`make` 全程无错、ABI 甚至可以对齐到 100%——然后卡在开机第一屏，**没有 panic、没有任何内核日志**。

实测过一条完整的失败路径：

| 轮次 | `boot_index` | 源码树 | `msm_drm` 符号 DIFF | 结果 |
| --- | --- | --- | --- | --- |
| V1 | 354 | AOSP `android16-6.12`（6.12.93） | 471 | ✗ 卡第一屏、静默 |
| V2 | 356 | 同上 + panic 化 | 471 | ✗ 同上 |
| 修复版 | 361/362 | 同上，**ABI 已 100% 对齐**、去掉 KernelSU、去掉 cmdline 注入 | **0** | ✗ 仍然卡屏 → 屏幕下缘闪一下 → 自动重启循环 |
| **成功版** | **365** | **`cctv18/android_gki_kernel_common`** | **0** | **✅ 开机成功** |

**唯一改动的变量就是树。** 修复版把能对齐的全对齐了（全量 CRC 100%、`struct module` 1600/75、关键符号一致），还是开不了机；换上另一棵树，一次就开机。

原因是 AOSP 上游树**缺一整层小米/高通厂商适配**。这些配置项在能开机的内核里全是 `y`，在 AOSP 上游树里**连对应的 Kconfig 都不存在**：

```
CONFIG_GKI_HACKS_TO_FIX
CONFIG_GCMA / CONFIG_GCMA_SYSFS
CONFIG_RT_SOFTIRQ_AWARE_SCHED
CONFIG_UNWIND_PATCH_PAC_INTO_SCS
CONFIG_SCHED_PROXY_EXEC
CONFIG_MODULE_SCMVERSION
CONFIG_CPUSETS_V1 / CONFIG_MEMCG_V1
CONFIG_AUTOFDO_CLANG
CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX = 1024    # AOSP 默认是 512
```

**结论：能不能开机由「源码树血统」决定，不是配置微调。社区已有成熟血统时，先复现它的基线，再谈增量优化。**

### 2. ABI 校验是必要条件，不是充分条件

这是上一条的孪生教训。ABI 四项全过**不代表能开机**（选错树时它照样全过，然后卡屏），但**任何一项不过 = 一定不能开机**：因为内核要加载厂商预编译的 404 个 `.ko`（Wi-Fi、音频、摄像头、充电、显示……），符号 CRC 对不上就直接拒载。

而 CRC 不是源码哈希，是 `gendwarfksyms` **依据结构体布局递归推导**出来的。所以一个看起来无关的调试配置就能引发连锁：

```
CONFIG_STACK_TRACER=y
  → select FUNCTION_TRACER              (kernel/trace/Kconfig:316-319)
  → CONFIG_FTRACE_MCOUNT_RECORD
  → struct module 多两个字段             (include/linux/module.h:542 的 #ifdef)
  → struct module: 1600 字节/75 成员  →  1664 字节/77 成员
  → 经 file_system_type->owner 进入 kobject_uevent_env 的类型展开
  → gendwarfksyms 推出不同的 CRC
  → msm_drm.ko 拒载 → 显示栈起不来 → 卡第一屏（静默）
```

写这段配置的人，在同一份 fragment 的注释里写着「**不修改任何既有符号 CRC → 对厂商 404 个 .ko 零影响**」。**注释和事实完全相反。**

详见 [`gki-abi-verification`](skills/gki-abi-verification/SKILL.md) 与 [`kernel-config-power-perf`](skills/kernel-config-power-perf/SKILL.md)。

### 3. 机型号与代号不是一回事

`pudding` = 小米 17、`pandora` = 小米 17 Pro、`popsicle` = 小米 17 Pro Max，三者同属平台 `canoe`。

**但最终以真机 `getprop ro.product.device` 为准。** 代号写错的后果不是「显示不对」，而是 `device.name1` 防呆失效、defconfig/target 选错。

顺带一个必然踩到的坑：**KMI 名 ≠ OS 大版本**。本机 OS 是 Android 17，而 KMI 名是 `android16-6-4k`——因为它描述的是内核 ABI 基线，不是系统版本。权威来源是 `modinfo /vendor_dlkm/lib/modules/msm_drm.ko | grep vermagic`，**不是** `uname -r`（跑第三方内核时那里面的 `androidNN` 标记会消失）。

## 已经真的走到哪一步

配套的内核工程仓是 **[`Ma6302/xiaomi17-kernel`](https://github.com/Ma6302/xiaomi17-kernel)**（GPL-2.0-only）。它记录了一条真实的、已经成功开机的路径：

- **上游**：`cctv18/android_gki_kernel_common` @ `android16-6.12-2026-03`，commit `58ee67741556c83c523f48518284c4a6b1ef31d6`（SUBLEVEL 69，与设备原厂一致）
- **编译**：16 核 / 12 GB，**6 分 19 秒**，error count 0，`Image` = **41,896,448 字节**
- **已开机的三个版本**：`boot_index 365`（零调优基线）、`367`（zstd 1.5.7 + lz4 1.10.0）、`372`（mi_sched 路径 A + MK-Addon，当前最新）
- **ABI**：全量 CRC 10235/10235 MATCH、DIFF 0；`msm_drm.ko` 851 符号 MATCH 701 / **DIFF 0** / MISSING 150（属其他 vendor 模块）；`struct module` 1600/75；`kobject_uevent_env` `0x8bb6d45c`
- **root 不受影响**：`init_boot` 里的 KernelSU LKM 补丁原样保留，**只换 `boot` 里的 Image 不会掉 root**（实测两次）

两仓的边界是**许可证边界**：内核仓含 GPL-2.0 派生内容（GPL-2.0-only），本仓是纯 MIT 原创。详见 [`kernel-project-repo-bootstrap`](skills/kernel-project-repo-bootstrap/SKILL.md)。

## 参考的上游项目

只作为参考链接列出，**本仓库不包含它们的代码**：

- [cctv18/android_gki_kernel_common](https://github.com/cctv18/android_gki_kernel_common) —— 唯一实测能开机的源码树血统
- [aosp-mirror/kernel_common](https://github.com/aosp-mirror/kernel_common) —— AOSP 上游 GKI 树；**完整、能编译，但在本设备上开不了机**
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) —— AK3 的配置语义以它自己的 README 为准
- [tiann/KernelSU](https://github.com/tiann/KernelSU)、[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) —— 列在这里只是因为它们解释了 `init_boot` 里那个 LKM 补丁从哪来。**本仓库不涉及 SUSFS**，也不涉及把 KernelSU 编进内核
- [capntrips/KernelFlasher](https://github.com/capntrips/KernelFlasher) —— 机内刷 AK3 zip
- [AAswordman/Operit](https://github.com/AAswordman/Operit) —— 目标 agent 环境
- [firelzrd/zram-ir](https://github.com/firelzrd/zram-ir) —— zram 即时重压
- [sched-ext/scx](https://github.com/sched-ext/scx) —— 注意 6.12 上可用的 kfunc 集与 7.x 不同

## 已验证清单

这些是**真的跑过**的，不是从文档抄的：

**设备侧（真机，2026-10-07 起）**

- 设备身份：Xiaomi 17 `pudding`、平台 `canoe`、SM8850、型号 `25113PN0EC`、Android 17（SDK 37）、HyperOS `OS4.0.0.32.XPCCNXM`、slot `_a`、SPL `2026-09-01`
- KMI 世代 = `android16-6-4k`，来自 `/vendor_dlkm/lib/modules/msm_drm.ko` 的 `vermagic: 6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64`；`uname -r` 在第三方内核上是 `6.12.111-Jianke`（**不含 `androidNN`**）→ **只从 `uname -r` 解析 KMI 会恒判 UNKNOWN**
- root = **KernelSU LKM**，补丁在 **`init_boot`**（不在 `boot`），`ksud 4.2.0-1-g904c60d1 (uapi: 2)`，SELinux context `u:r:ksu:s0`
- **`getprop` 在已 root 的设备上会撒谎**：同一台机器 `ro.boot.flash.locked` 报 `1`、`ro.boot.verifiedbootstate` 报 `green`，而 `/proc/bootconfig` 是 `vbmeta.device_state = "unlocked"`、`verifiedbootstate = "orange"`（装有 `YH_YC`/`tricky_store`/`playintegrityfix`）→ **BL 状态必须读 `/proc/bootconfig`**
- 分区实测字节：`boot_a` 100,663,296 B（96 MB）、`init_boot_a` 8,388,608 B（8 MB）、`vendor_boot_a` 100,663,296 B、`dtbo_a` 33,554,432 B；`ramdisk_sz = 0`（ramdisk-less → AK3 走 `flash_boot` 分支）
- 模块基线：原厂 **660**、自编成功版 **670**、另一版 **668**、dmesg 带 `(O)`/`(OE)` 标记口径 **336** —— **口径不同，不要跨口径比较**

**构建侧**

- **源码树血统决定能否开机**：AOSP 上游树三次失败（`boot_index` 354/356/361/362），换 `cctv18` 树一次成功（`boot_index` 365）——**同一份 ABI 对齐结果，两种结局**
- AOSP 上游树缺的厂商适配标志（`GKI_HACKS_TO_FIX` 等 9 项 + `GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024`），在可开机内核里全为 `y`
- `CONFIG_STACK_TRACER=y` → `struct module` 1664/77 → `msm_drm.ko` 拒载 → 卡屏；关掉后回到 1600/75
- 裸 `make` 缺 `KBUILD_GENDWARFKSYMS_STABLE=1` → `msm_drm` 符号 DIFF **471**；`source ./_setup_env.sh` 后归零
- 系统 pahole 1.25 → `FAILED: load BTF from vmlinux: Invalid argument`；换 AOSP build-tools 的 prebuilt 后通过
- 16 核 / 12 GB 实测 **6 分 19 秒**编完，`Image` 41,896,448 字节
- **CI 能编出来但不算证明**：`aosp-mirror/kernel_common@android16-6.12` 在 4 vCPU 托管 runner 上 **32 分 54 秒**跑通，产出 `Image` 33,286,656 字节 / sha256 `14adb4ec596b7bd4bff6b2ac5658dd06582f5bf5a74417bc2f3937604a5d31b7` / `kernelrelease 6.12.52-4k-g105b5745f1d7`——**那是一个开不了机的 Image**，这条路现在只作为「CI 管线本身是通的」的证据保留
- `MiCode/Xiaomi_Kernel_OpenSource@popsicle-w-oss` 只有 2,686 条路径（同组织其他分支约 76,000）、缺 `kernel/sched/fair.c` 等核心文件、无 `build/`、无 `tools/bazel`、无 `arch/arm64/configs/*_defconfig` —— **不能单独构建**；且 **MiCode 不提供 manifest**（266 个分支里含 manifest/platform 的为 0）
- 代号 `pudding`=小米 17 / `pandora`=17 Pro / `popsicle`=17 Pro Max，同平台 `canoe`（`pudding` 已由真机 `getprop ro.product.device` 证实）
- `scripts/validate-skills.sh` 与 `scripts/install-to-operit.sh` 的行为（10 个 skill 全绿；安装幂等；格式错误会拒绝）

## 未核实清单（诚实记录）

- **自编内核在长时间、多场景下的稳定性** —— 只验证过开机与子系统可用，**没有跑过 72 小时挂机或功耗基线**
- **`recomp_algorithm` / `recompress` / `algorithm_params` / `idle` 这些 zram 接口在本机是否存在** —— **未探测**。已实测**不存在**的是 `/sys/block/zram0/backing_dev`（因此 `/sys/block/zram0/writeback` 也不存在）
- **改压缩算法能带来多少压缩比收益** —— **没有任何实测对照**；唯一实测的压缩比是 `2.58x`（原厂内核运行态），换算法后的数字未知
- **zram 回写是否真的落盘、以及它对 UFS 擦写寿命（TBW）的影响** —— **未评估**。计数器在增长，但目标块设备的实体未定位
- **ARB 指数** —— **UNKNOWN**。机内 `ro.boot.anti` 为空**不等于**没有 ARB，要 `fastboot getvar anti` 才能确定
- **EDL(9008) 兜底是否可用**（是否需要授权文件）—— **未验证**
- **V1/V2 卡第一屏时内核究竟有没有开始执行** —— 两种可能同样成立：内核跑起来了但挂起，或 ABL 加载跳转就没成功。**从未验证**
- **具体是哪个厂商适配项起了决定作用** —— **未做二分验证**。`GKI_HACKS_TO_FIX` 只是最显眼的相关标志，不是已证实的因果
- **内核安全补丁日期（SPL）对齐的影响** —— 设备 SPL 是 `2026-09-01`，上游树的 SPL 未核查
- **`gki-abi-verification` 的工具脚本**只在真机上跑过一次完整流程；它依赖设备侧导出的 `msm_drm.ko`，**换设备后基线常量（`1600/75`、`0x8bb6d45c`）需要重新测定**
- **手机端**完整编译 6.x arm64 Android 内核的耗时 —— **无可靠报告**（本机是 16 核 / 12 GB 的 PC 环境，AOSP prebuilt clang 只有 `host/linux-x86`，ARM64 PRoot 里跑不了，见 `android-kernel-build-on-device/references/toolchain-on-arm64.md`）
- 小米 17 的完整分区表 —— **未由设备转储确认**
- 「小米 17 自编译 GKI 内核多例卡 bootloop 而 LKM 稳定」—— 流传于 XDA，**未实机复现**

## License

MIT，见 [LICENSE](LICENSE)。**刷机可能永久损坏设备**，风险自负。
