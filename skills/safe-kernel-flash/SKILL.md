---
name: safe-kernel-flash
description: 用于在小米 17（pudding / canoe / SM8850 / Android 17 / KMI android16-6-4k）上刷入自编译 GKI 内核或 AnyKernel3 包，以及判断刷完到底成没成、卡住了还能不能退回来。当要往 boot_a 写内核、刷完卡在 XBL 第一屏（静默、无声音、无振动、不自动重启）、或一分多钟后屏幕下缘闪一下自动重启循环、需要长按音量下加电源进 fastboot 刷回 stock-boot.img、想搞清楚 PSHOLD 复位为什么让 printk 与 ramoops 一起消失、分不清 getprop 与 /proc/bootconfig 哪个是真值、或拿不准 ARB 与 flash_all 的风险时使用。
---

# 安全刷入内核

## Overview

一句话命题：

> **刷机前的每一分钟都在为回滚做准备；刷机后的唯一目标是证明它真的成功了。**

刷内核的风险不在 `fastboot flash` 那一步——那一步几乎不会失败。风险在写完之后：**你还有没有第二条路。**

所以判据不是「包对不对」，而是：

> 如果现在这块屏幕再也不亮了，我下一句话能说什么？

答得出「PC 上有 `stock-boot.img`，md5 是 `5157f9020b45b51ec1701c79cda9b93d`，我能在 fastboot 里单刷 `boot_a`」，才算准备好了。

这台机器（小米 17 / 代号 `pudding` / 平台 `canoe` / 高通 SM8850 / Linux 6.12 GKI / Android 17 / KMI `android16-6-4k`）已经用**三次失败刷机**把这条判据验证过：三次都卡在 XBL 第一屏，其中**两次**是靠**刷机前就拷到 PC 上的镜像**手动救回来的。**回滚路径不存在就不许开刷**——这是硬闸门，不是建议。

**REQUIRED SUB-SKILL:** `xiaomi17-device-recon` —— 本 skill 依赖它的 `device-profile.md` / `build.env`（`ROOT_PARTITION`、`SLOT`、`FLASH_LOCKED`）。档案不存在就先采集，不要在这里重新猜。

## When to Use

**命中任意一条就来这里：**

- 刷完后卡在开机第一屏（XBL splash logo），**无声音、无振动、不自动重启**。
- 或一分多钟后屏幕下缘闪一下 → 自动重启 → 屏幕下缘再闪 → 循环。
- 刷完 `uname -r` 没变；或变了但 `dmesg` 里一堆 `Unknown symbol` / `disagrees about version`。
- 刷完 root 没了（`/data/adb/ksud -V` 报错）。
- 想拿内核日志，却发现 printk / ramoops 里什么都没有。
- 要回滚到原厂或上一个能开机的内核，但不确定镜像在哪、该刷哪个分区。
- 准备开刷之前，要判断「现在退路存在吗」。

**何时不用**

- 包还没检查过结构 → 先去 `anykernel3-packaging` 跑 `check-anykernel-zip.sh`。
- 设备事实还没采集（不知道 `ROOT_PARTITION`）→ 先去 `xiaomi17-device-recon`。
- 内核还没编出来 → `android-kernel-build-on-device`。
- 只是问概念、不碰真机。

## 四个硬闸门（缺一个就不许开刷）

### 闸门 1：回滚镜像已经在 PC 上，且 md5 逐字匹配

**fastboot 阶段读不到手机内部存储。** 手机里的备份在那一刻等于不存在。镜像必须在**刷机之前**就躺在 PC 上。

```bash
md5sum stock-boot.img
# 期望: 5157f9020b45b51ec1701c79cda9b93d   ← 真原厂 6.12.69，首选回滚镜像
```

三个备份（md5 逐字，实测采集）：

| 文件 | md5 | 说明 |
| --- | --- | --- |
| `stock-boot.img` | `5157f9020b45b51ec1701c79cda9b93d` | 真原厂 6.12.69，**首选回滚镜像** |
| `boot_a.img` | `5329fec9e9c154913673065734662067` | Jianke 6.12.111 备份，备用 |
| `init_boot_a.img` | `f78cdace08393da6272c658f2e1cc66e` | KSU 补丁所在分区 |

md5 对不上 = 你手上的不是那个镜像。**不要刷。** 名字对不等于内容对。

### 闸门 2：`ROOT_PARTITION` 已经备份，而且你知道它在哪个分区

GKI 布局里**内核在 `boot`，通用 ramdisk 在 `init_boot`**。KernelSU 的 LKM 模式把 `kernelsu.ko` 打进 ramdisk，所以 root 补丁在 **`init_boot`**：

```
init_boot_a.img 内的 ramdisk:
  init                     607 KB   ← SukiSU wrapper（替换了原 init）
  init.real               2.81 MB
  kernelsu.ko              390 KB
  stock_image.sha1          40 B
```

实测结论（`boot_index` 365 之后）：**不内置 KSU、只替换 `boot` 里的 `Image` → root 完好。**

所以：

- **`init_boot` 不要动。** 刷它才会掉 root，而刷我们的内核不需要它。
- 但**必须备份它**——它是你唯一能整回去的东西。
- 「只备份 `boot`」是最常见的假备份：开机时看着有备份，真出事时发现里面没有你唯一想要的那部分。

### 闸门 3：只刷 `boot_a`，一个字节都不往别处写

实测分区（本机字节，逐字）：

```
boot_a        → /dev/block/sde14    100,663,296 B (96 MB)
init_boot_a   → /dev/block/sde30      8,388,608 B (8 MB)   ← 不要动
vendor_boot_a → /dev/block/sde25    100,663,296 B
dtbo_a        → /dev/block/sde18     33,554,432 B (32 MB)
```

我们的 `Image` 约 41,899,648 字节（实测 41,896,448），`boot_a` 有 96 MB，空间充足。

boot 头是 **header v4**，`ramdisk_size = 0`（ramdisk-less 设备）→ AnyKernel3 走 `flash_boot` 分支（不是 `write_boot`）。

绝对不动：`vbmeta` / `init_boot` / `persist` / `modemst1` / `modemst2` / `frp` / `misc`，也不重锁 BL。

**不要双写两个槽。**「另一槽还能开机」是免费的保险；`SLOT_SELECT=both` 会把它一次花光。

### 闸门 4：绝不 `flash_all` —— 它会触发 ARB，而且不可逆

```bash
# 绝不要执行任何形式的整包刷写：
fastboot flash_all            # ✗ 触发 ARB
# 也不要跑官方包里的 flash_all.sh / flash_all.bat / 任何整包脚本
```

**ARB（anti-rollback）保护的是 bootloader 与固件链（xbl / abl / tz / hyp / devcfg），不是内核。** 单刷 `boot` / `init_boot` / `vendor_boot` / `dtbo` / `vbmeta` 不涉及 ARB 计数。

**本机 ARB 指数：`UNKNOWN`。** 机内 `ro.boot.anti` 是空的，**空 ≠ 没有 ARB**。要确定必须在 fastboot 里查：

```bash
fastboot getvar anti
```

侧面证据（blackbox 分区实测）：`the stored_rollback_index is: 1`，在 `boot_index` 361 / 362 / 364 多轮中保持一致、未见变化——但刷 `boot` 本身不涉及 ARB 计数，所以这不能当成「ARB 很安全」的结论。

**按高危处理**：不要刷任何比你当前版本旧的官方整包，不要拿降级当回滚手段。

## 刷前检查清单

在手机上跑（只读，不写任何分区）：

```bash
bash skills/safe-kernel-flash/scripts/preflight-flash.sh \
  --zip /sdcard/Download/Operit/kernel-dev/out/<包名>.zip \
  --pc-rollback <PC 上放回滚镜像的目录>
```

PC 侧先生成回滚清单，脚本会逐字核对：

```bash
md5sum stock-boot.img boot_a.img init_boot_a.img > rollback-manifest.txt
```

**手工也要过一遍的真值检查**（`getprop` 在这台机器上不可信）：

```bash
# 1) 启动参数真值 —— 只信 /proc/bootconfig
grep -E 'vbmeta.device_state|verifiedbootstate|hardware.sku' /proc/bootconfig
#    androidboot.vbmeta.device_state = "unlocked"
#    androidboot.verifiedbootstate   = "orange"

# 2) BL 状态：getprop 是被伪造的，只能用来对照，不能用来判断
getprop ro.boot.flash.locked         # 报 1（=锁定）—— 假的
getprop ro.boot.verifiedbootstate    # 报 green      —— 假的
```

本机装了 YH_YC / tricky_store / playintegrityfix 这类隐藏模块，`resetprop` 会把上面两个属性改成「已锁定 / green」。**拿 `ro.boot.flash.locked=1` 当真值，会把一台已经解锁的设备判成锁着。** 注意两个字段语义相反：`flash.locked` 是 `1=锁`，`vbmeta.device_state` 是 `unlocked` / `locked`。

```bash
# 3) 当前基线（刷完要跟它比）
uname -r
grep -o 'boot_index=[0-9]*' /proc/cmdline

# 4) 分区存在性与尺寸
ls -l /dev/block/by-name/boot_a /dev/block/by-name/init_boot_a

# 5) 电量 ≥ 60%
dumpsys battery | grep level
```

## 刷入

**方式 A：机内 AK3（推荐）** —— 把 zip 放到设备上，用 Kernel Flasher / Horizon Kernel Flasher / SukiSU 刷：AK3 解包当前 `boot`、只替换 `Image`、重新打包写回。

> **`do.devicecheck=1` 是假防呆。** 这个 AK3 fork 的 `tools/ak3-core.sh` **根本没实现 devicecheck**（`grep -c devicecheck ak3-core.sh` = **0**），设了只是写一个没人读的变量。要防呆必须在 `anykernel.sh` 里自建：读 `/proc/bootconfig` 的 `hardware.sku`，匹配 `"pudding"` / `"canoe"`，否则 `abort`。提 devicecheck 就必须同时提这个陷阱。

**方式 B：PC fastboot**（需要 `.img`，不是 AK3 zip）：

```bash
fastboot devices
fastboot getvar current-slot
fastboot flash boot_a boot-new.img     # 只刷当前槽
fastboot reboot
```

**PC → 手机传文件（USB adb 不可用时实测可用）**：手机侧起一个 HTTP 接收服务，PC 侧主动 POST 上去。

```bash
# 手机侧
python3 upload_recv.py 9999 /sdcard/Download/Operit/kernel-dev
# PC 侧（<手机IP> 用占位符，别写死）
curl -X POST --data-binary @file.zip http://<手机IP>:9999/file.zip
```

方向不能反：PC → 手机的**出站**连接不受 Windows 防火墙影响；反过来（PC 起服务、手机去连）会被入站规则拦掉。

## 刷后验证（必须上机跑，跑不出结果就不许说成功）

```bash
uname -r                      # 6.12.69-android16-6-4k-<署名后缀>（或你的 localversion）
grep -o 'boot_index=[0-9]*' /proc/cmdline     # 应该是新的一轮
dmesg | grep -ic 'disagrees about version\|Unknown symbol'   # 期望 0
lsmod | wc -l                                  # 期望 ~670
/data/adb/ksud -V                              # root 还在
ls /dev/dri/                                   # card0 + renderD128
lsmod | grep -c msm_drm                        # 1（显示栈起来了）
ip link | grep wlan0
ls /dev/video0
cat /proc/asound/cards                         # canoe-mtp-snd-card
dmesg | grep -ic 'kernel panic\|Oops'          # 期望 0
```

两条口径纪律：

- **`uname -r` 没变 = 你刷的不是你以为的那个分区。** 先去对槽位，不要急着再刷一次。
- **模块数必须同口径对比**：`660`（`/proc/modules` 全量，原厂）/ `670`（本仓成功版）/ `336`（`dmesg` 里带 `(O)` / `(OE)` 标记的口径）。拿 670 去比 336 会得出「模块掉了」的错误结论。

刷后**必须上机验证才允许声称成功**。包完整、ABI 对齐、哈希一致，都不能代替 `uname -r` + `boot_index`。

## 卡住时怎么自救

**症状（三次完全一致）**：刷入 → 卡在开机第一屏（XBL splash logo），无声音、无振动、不自动重启；或者一分多钟后屏幕下缘闪一下 → 自动重启 → 循环。

**关键观察：XBL 层按键仍可交互 → 这不是全局硬死锁，是内核或显示链路挂起。** 所以还能救。

**恢复动作（实测成功，记录在案两次以上）—— 全程在 PC 上完成，手机侧的 AI 助手此刻不可用：**

```
1. 长按 音量下 + 电源（一次）      → 进 fastboot
2. PC: fastboot devices            → 确认设备可见
3. PC: fastboot flash boot_a stock-boot.img
4. fastboot reboot                 → 正常开机
```

**为什么必须手动**：fastboot 阶段 Android 没起来，手机侧助手不可用；而且 **fastboot 阶段读不到手机内部存储**，回滚镜像必须刷机前就在 PC 上。

**本方案没有 panic 自动重启配置** —— 卡住不会自己重启，必须手动复位。

### 取证陷阱：按键复位会让你拿不到任何日志

用按键触发的 **PSHOLD warm reset 不走内核 reboot 路径** → 不调 `panic()` → 不触发 `kmsg_dump()` → **printk ring buffer 与 ramoops 全部随内存丢失**。

所以「卡住 → 按键重启 → 想看日志」这个做法**本身就是取证失败的原因**，加多少 printk 都没用。

黑盒里还能看到的（blackbox 分区）：

```
Loading Image boot_a Done
PM: Reset by PSHOLD
the stored_rollback_index is: 1
Hard watchdog permanently disabled
```

归属判定纪律：解析取证分区时**必须用版本串 / 署名做归属**（`<署名后缀>`、`6.12.93` 这类），不能看到「有日志」就以为是自己这一轮写的——曾被 bootmonitor 归档进来的上一轮日志骗过一次。

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 回滚镜像只留在手机里 | fastboot 阶段读不到，等于没有 | 刷机前拷到 PC，并核对 md5 |
| 没备份就开刷 | 没有第二句话可说 | 先备份 + 机外副本 + md5 |
| 刷 `init_boot` | 抹掉 KSU 补丁，root 没了 | 只刷 `boot_a`；`init_boot` 只备份不动 |
| 跑 `flash_all` / 整包脚本 | **触发 ARB，不可逆** | 只单刷 `boot_a` |
| 用降级当回滚手段 | 同样的 ARB 风险 | 回滚用机外备份的 `boot_a` 镜像 |
| 拿 `getprop ro.boot.flash.locked` 判断 BL | 已解锁的机器被判成锁着（或反过来） | 一律读 `/proc/bootconfig` |
| `SLOT_SELECT=both` 双写 | 免费的回滚手段归零 | 只写当前槽 |
| 信 `do.devicecheck=1` | 防呆没生效，包可能刷到别的机器 | 在 `anykernel.sh` 里自建 `hardware.sku` 校验 |
| 刷完不看 `uname -r` / `boot_index` | 以为成功，其实刷进了另一槽或没生效 | 上机逐条跑刷后验证 |
| 模块数跨口径对比（670 vs 336） | 误判「模块掉了」 | 同口径比：660 / 670 / 336 各自成组 |
| 按键复位后去 pstore 找日志 | 什么都找不到，白花时间 | 记住 PSHOLD 不走 `kmsg_dump()`；要取证得另设计 |
| 假设 EDL(9008) 一定能兜底 | 关键时刻发现进不去 | EDL 状态 `UNKNOWN`，不能当计划的一环 |

## Real-World Impact

三次失败刷机（`boot_index` 354 / 356 / 361·362），三次都卡在 XBL 第一屏；恢复动作（音量下 + 电源 → fastboot → PC 单刷 `stock-boot.img`）**实测自助恢复成功两次**，均记录在案。结论不是「内核难编」，而是**「回滚路径是不是在开刷之前就存在」这件事决定了一切**。

另一个真实陷阱：本机 `getprop ro.boot.flash.locked` 报 `1`、`ro.boot.verifiedbootstate` 报 `green`，而 `/proc/bootconfig` 是 `unlocked` / `orange`。**把 `getprop` 当真值，会把一台已经解锁的设备判成锁着**，然后得出「不能刷」的错误结论——反过来的误判（把锁着的机器当成能刷）是硬砖。

## UNKNOWN / UNVERIFIED

| 项 | 状态 | 说明 |
| --- | --- | --- |
| ARB 指数 | `UNKNOWN` | 机内 `ro.boot.anti` 为空；需 `fastboot getvar anti`。侧面证据 `stored_rollback_index is: 1` 多轮一致，未见变化 |
| EDL(9008) 兜底 | `UNKNOWN` | 硬件通道存在（UFS 多 LUN），是否需要授权文件未验证 |
| 主动取证方案 | `UNVERIFIED` | 让卡死轮也能留下日志的做法（panic 自动重启 + pstore 落盘之类）**没有实测过** |

## 相关 skill

- **REQUIRED SUB-SKILL:** `xiaomi17-device-recon` —— `device-profile.md` / `build.env` 是所有事实的来源。
- **REQUIRED SUB-SKILL:** `anykernel3-packaging` —— 刷之前先验包结构与 `anykernel.sh` 的键。
- **root 会不会掉**：只看 `ROOT_PARTITION` 指的那个分区有没有被动过。GKI 设备上内核在 `boot`、通用 ramdisk 在 `init_boot`，而这台设备的 KernelSU **LKM** 补丁装在 `init_boot` —— **只换 `boot` 里的 Image 不会掉 root**（实测两次，`init_boot_a` 的 md5 前后一致）。反过来，`ksud boot-restore` **不能**当回滚手段（它的 `stock_image.sha1` 与你换过的 `boot` 不匹配，会直接拒绝工作）。
- `kernel-perf-verification` —— 刷成功之后怎么证明它真的更好。
