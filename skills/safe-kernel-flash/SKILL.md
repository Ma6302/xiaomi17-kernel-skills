---
name: safe-kernel-flash
description: 用于在 Android 手机上安全刷入自编译内核并保留可回滚路径，包括刷前检查、备份原厂 boot 分区、在机内用 dd 直接写入或用 fastboot 写入、判断是否需要动 vbmeta、以及刷不开机时的恢复阶梯。当要刷写内核镜像或 AnyKernel3 包、需要回滚到原厂内核、或刷完无法开机时使用。
---

# 安全刷入内核

## Overview

刷内核的风险不在「写入」这一步，而在**「写入之后你还有没有别的路可走」**。所以判据不是「包对不对」，而是：

> 如果现在这块屏幕再也不亮了，我下一句话能说什么？

能说出「另一槽是原厂」或「备份在原厂 boot 已在机外」，才算准备好了。

## When to Use

- 要刷入刚打包好的内核 / AK3 zip。
- 刷完不开机、卡 fastboot、卡 recovery、反复重启。
- 要回滚到原厂内核。
- 不确定该不该动 vbmeta。

**何时不用**：包还没检查过（先跑 `anykernel3-packaging` 的 `check-anykernel-zip.sh`）。

## 第一步：机械检查，不要靠感觉

```bash
bash scripts/preflight-flash.sh --zip /sdcard/Download/Operit/kernel-dev/out/xxx.zip
```

它检查代号、槽位、电量、分区、**备份是否存在且校验和通过**、包是否完整。任何阻塞项都会以 exit 3 结束。

## 第二步：备份（这是唯一真正的保险）

```bash
bash ../xiaomi17-device-recon/scripts/collect-device-facts.sh --backup
```

备份必须满足三条，缺一条就等于没有备份：

1. **落在机外**（电脑、U 盘、云盘）。存在同一个 /data 里，设备一旦进不了系统你取不出来。
2. **有 SHA256 并且校验通过**。一个静默损坏的备份和被刷坏的设备一样无可挽回。
3. **包含 vbmeta**。忘了它，后面想动 verity 时就没有退路。

## 第三步：理解 ARB 到底管什么

**ARB 保护的是 bootloader 与固件链（xbl / abl / tz / hyp / devcfg 等），不是内核。**

只刷 `boot` / `init_boot` / `vendor_boot` / `dtbo` / `vbmeta` **不会触发 ARB**。

真正会触发 ARB 的是刷**整包 fastboot 固件**或整包 ROM：当固件包里的 ARB 版本低于设备已熔断的版本，设备拒绝启动，**且不可逆**。

**查当前 ARB 状态**：

```bash
fastboot getvar anti
# 输出为空  → ARB 尚未启用
# 输出一个数字 → 这就是当前的 rollback index
```

规则：镜像的 index **大于**设备 → 刷入成功，且设备 index **被提升到与该镜像一致**；**等于** → 不变；**更小** → 拒绝刷入（MiFlash 会报 anti-rollback 错误）。

注意两件事：

- **`ro.boot.veritymode` 不是 ARB。** 那个属性反映的是 AVB/dm-verity 状态，和防回滚是两回事。
- 小米的 ARB **不能像 Google 那样通过解锁 BL 关掉**。一旦装上带更高 ARB 版本的固件，就回不去了。

由此得到一条操作纪律：

> 回滚原厂时，**只从官方包里取出 boot / init_boot / vbmeta 单刷**，
> 绝不图省事跑整包的 `flash_all` 之类脚本。

这条纪律同时解释了为什么「刷回原厂」比「刷入自制」更危险——很多人是在回滚的时候把设备弄废的。

## 第四步：写入

**机内写入（推荐，不需要电脑）**

root 后直接从手机上写，这是 Operit 环境下最顺的路径：

```bash
SLOT=$(getprop ro.boot.slot_suffix)
dd if=/sdcard/Download/Operit/kernel-dev/out/boot.img of=/dev/block/by-name/boot${SLOT} bs=4096
# 若是 AK3 zip，用 Kernel Flasher 之类的应用刷更稳（它会自己做槽位与 vbmeta 处理）
```

写之前确认镜像大小 ≤ 分区大小，且 `of=` 指向的是**带槽位后缀**的正确分区。

**fastboot 写入**

```bash
fastboot getvar current-slot          # 读槽位，不要写死 a
fastboot flash boot${SLOT} boot.img
fastboot reboot
```

只写**当前**槽位。**不要双写**：`SLOT_SELECT=both` 或连续刷两个槽，会让「换槽启动」这个免费的回滚手段消失。

## 第五步：vbmeta —— 默认不动

重新打包 boot 会让该分区的 AVB 哈希失效。但**不要在流程里例行执行**：

```bash
# 不要当成常规步骤
fastboot --disable-verity --disable-verification flash vbmeta ...
```

在 HyperOS 上，刷一个来路不明的 vbmeta 本身就是主要的变砖来源。正确顺序：

1. 只刷 boot，试着开机。
2. 只有**明确出现** verity / vbmeta 相关错误（`dm-verity` 报错、落到 recovery、`Your device is corrupt`）时，才考虑 vbmeta。
3. 动手前确认**原始 vbmeta 已经 dd 备份**。
4. 一次只改一项，改完立刻验证能否开机。

## 第六步：刷完立刻验证

```bash
uname -r                # 是否变成你编译的那个版本（应含你的 localversion）
cat /proc/version
dmesg | grep -iE 'panic|watchdog|soft lockup|hung task|BUG:|Oops'
```

`uname -r` 没变 = 你刷的不是你以为的那个分区（去对一下槽位）。

## 恢复阶梯（按顺序试，别跳）

| 层级 | 手段 | 前提 |
| --- | --- | --- |
| 1 | 机内 dd 刷回备份的 boot | 系统还能起来（哪怕只是短暂起来） |
| 2 | `fastboot flash boot${SLOT} 原厂boot.img` | 能进 fastboot |
| 3 | `fastboot set_active <另一槽>` | 另一槽是原厂 |
| 4 | 从官方包**只取** boot/init_boot/vbmeta 单刷 | 绝不跑整包（见 ARB） |
| 5 | EDL / 9008 模式恢复 | 通常需要授权或送修，**不要提前假设它可用** |

## Common Mistakes

| 错误 | 后果 | 正确做法 |
| --- | --- | --- |
| 没备份就刷 | 无可挽回 | 先备份并拷出机外 + 校验和 |
| 双写两个槽 | 免费的回滚手段消失 | 只写当前槽 |
| 把 `--disable-verity` 当常规步骤 | 在 HyperOS 上是主要变砖源 | 只在必要时动，且先备份 vbmeta |
| 槽位写死 `a` | 刷错分区 | `fastboot getvar current-slot` / `ro.boot.slot_suffix` |
| 回滚时跑整包 fastboot 固件 | **触发 ARB，不可逆变砖** | 只单刷 boot 类分区 |
| `fastboot erase` 任何东西 | 抹掉 persist / modemst → 基带、传感器永久损坏 | 不 erase |
| 重新锁 BL | 变砖且不可逆 | 永远不要在刷第三方内核后锁 BL |
| 刷完不看 `uname -r` | 以为刷成功，其实是刷进了另一槽或没生效 | 立刻验证 |
| 假设 EDL 一定能用 | 关键时刻发现进不去 | 把它当最后手段，不是计划的一环 |

## Real-World Impact

基线里 agent 的流程基本正确（校验 hash → 读槽位 → dd 备份 → 只刷单槽 → 重启），但**完全没提 ARB**，而且把 `--disable-verity --disable-verification flash vbmeta` 当成了常规步骤、槽位写死 `a`。三条里两条指向同一个方向的错误：**把「让这次刷机能开机」当成目标，而不是「让自己随时能退回去」**。
