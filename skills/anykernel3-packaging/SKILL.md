---
name: anykernel3-packaging
description: 用于把编译出的 Android 内核镜像打包成可刷的 AnyKernel3 zip，包括填写 anykernel.sh 的键、决定 BLOCK 与槽位行为、内嵌 vendor 模块与 modules.dep、合并 dtb，以及在刷之前机械检查包结构。当要把 Image 交给 recovery 或 Kernel Flasher 刷入，或 zip 刷了没反应、不开机、模块加载不上时使用。
---

# AnyKernel3 打包

## Overview

AK3 **不生成 boot 镜像**——它在你设备**已有的** boot 镜像里换掉内核，保留厂商 ramdisk。

这不是偷懒，这是 GKI 设备上唯一正确的做法：厂商 ramdisk 里塞满了设备专属的 init 逻辑、fstab、kalama 之类的平台参数，**这些从内核源码根本重建不出来**。任何试图自己 `mkbootimg` 一个完整 boot.img 的路径，都是在赌自己能复刻厂商 ramdisk。

## When to Use

- 已经编译出 `Image` / `Image.lz4` / `Image.lz4-dtb`，要变成能刷的包。
- 刷了自制的 zip 后：不开机、没变化、模块没加载、Wi-Fi 挂了。
- 不确定 `BLOCK` 该填 boot 还是 init_boot、该不该双写槽位。

**何时不用**：内核还没编译成功（先去 `android-kernel-build-on-device`）；要刷入（去 `safe-kernel-flash`）。

## 第一步：固定 AK3 版本，并读它自己的 README

```bash
git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git
cd AnyKernel3 && git rev-parse HEAD     # 把这个 commit 记进你的构建说明
```

**AK3 的键在不同版本间有增删。** 下面列的是常见键的语义，但**权威是这个 commit 的 README 和 `anykernel.sh` 里的注释**。写错键名不会报错——它会被当成注释一样忽略，然后你得到一个行为不符合预期的包。

## 第二步：目录结构

```
你的 zip 根/
├── META-INF/com/google/android/{update-binary,updater-script}   ← 必须在根
├── anykernel.sh
├── Image  (或 Image.gz / Image.lz4 / Image.lz4-dtb)
├── dtb                                  ← 合并后的 dtb（若需要）
└── modules/vendor/lib/modules/*.ko      ← 只有 do.modules=1 时
        + modules.dep, modules.load, modules.alias, modules.softdep
```

`META-INF` 不在 zip 根（比如你把整个文件夹压进去了）是最常见的低级错误，结果是刷了什么都不发生。

**`Image.lz4-dtb` 不是笔误。** 高通 msm-kernel / Kleaf 的 dist 目录里，默认产物就是它——内核与追加的 dtb 合成一个文件。用它的时候通常不需要再单独放 `dtb`。

## 第三步：anykernel.sh 的关键键

| 键 | 作用 | 该填什么 | 填错的后果 |
| --- | --- | --- | --- |
| `do.devicecheck` | 校验机型 | `1` | 设 0 等于防呆失效，包会被刷到任意机器上 |
| `device.name1` | 允许的代号 | **真机 `getprop ro.product.device` 的值** | 抄任何公开对照表都可能错：`pudding`=小米 17、`pandora`=17 Pro、`popsicle`=17 Pro Max，同属平台 `canoe`——而分支名 `popsicle-w-oss` 覆盖的是整个 17 系列。填错 → 要么校验直接失败，要么防呆形同虚设 |
| `BLOCK` | 内核在哪个分区 | GKI A/B 设备通常是 `boot`；AK3 支持 `auto` 自动探测 | 写到 init_boot 会把 ramdisk 覆盖掉，变砖 |
| `IS_SLOT_DEVICE` | 是否 A/B | `1` | 设错会写到不带槽位的分区名上，刷不进去 |
| `SLOT_SELECT` | 写哪个槽 | `active`（只写当前槽） | `both` 双写：一旦新内核有问题，两个槽都完了，**没有回退余地** |
| `do.modules` | 是否带模块 | 有自编模块才 `1` | 开了但没放 `.ko` → 刷完模块缺失 |
| `PATCH_VBMETA_FLAG` | 是否改 vbmeta 标志 | 能不设就不设 | 见 `safe-kernel-flash`：这是变砖的主要来源之一 |
| `supported.versions` | 允许的 Android 版本区间 | 你实测过的区间 | 填宽了会把包刷到不兼容的系统上 |

## 第四步：vendor 模块的归属要先查清楚

自编内核若改了 `CONFIG_*`，厂商预编译模块可能拒绝加载（`Module.symvers` CRC 不匹配）。模块放哪儿取决于设备：

- `vendor_dlkm` 分区 / `vendor_dlkm.img`
- `vendor_boot` 里的 DLKM ramdisk 片段（`VENDOR_RAMDISK_TYPE_DLKM=3`，见 AOSP vendor_boot 分区文档）
- `/vendor/lib/modules`（老布局）

**先看真机**：`ls /vendor/lib/modules`、`mount | grep dlkm`、`getprop | grep dlkm`。猜错位置的后果是刷完能开机但 Wi-Fi / 相机 / 快充全废。

## 第五步：打包与检查

打包时保持 `META-INF` 在根（用 `zip -r` 时先 `cd` 进目录，别包外层文件夹）。然后：

```bash
bash scripts/check-anykernel-zip.sh out/AnyKernel3-xiaomi17-$(date +%Y%m%d).zip
```

它检查结构、`anykernel.sh` 的有效设置、槽位策略、内核镜像与 dtb 是否存在、模块与 `modules.dep` 是否配套，并打印 SHA256。

**注意它能证明什么**：只证明包是完整的，不证明内核是对的。内核正确性只能靠刷完开机后 `uname -r` 验证。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 自己 `mkbootimg` 拼 boot.img | 复刻不出厂商 ramdisk，多数情况不开机 | 交给 AK3，让它替换内核 |
| `SLOT_SELECT=both` | 两个槽一起坏，回滚手段归零 | `active` |
| 照抄网上某个版本的键名 | 键被静默忽略 | 读你手上那个 commit 的 README |
| 代号从网上抄 | 校验失败或校验形同虚设 | 真机 `getprop ro.product.device` |
| 模块不带 `modules.dep` | 模块加载不上，功能静默缺失 | 从编译产物的 `dist/` 里整目录搬 |
| 不记 AK3 commit | 以后无法复现同一个包 | 记进构建说明 |
| dtb 用 `cat` 乱序合并 | 设备树匹配错，可能不开机 | 用编译产物给的 dtb 列表，顺序不能改 |

## Real-World Impact

基线里 agent 能写出完整的 `anykernel.sh`，但把 `BLOCK=boot` 写死、**漏掉了 `PATCH_VBMETA_FLAG`**，并且打算手写 `mkbootimg --header_version 4 --pagesize 4096` 自己造 boot.img——这三处里任何一处都能让设备不开机。这就是为什么本 skill 把「先查真机、再读版本 README」放在命令之前。
