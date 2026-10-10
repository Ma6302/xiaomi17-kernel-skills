# 真机采集快照（2026-10-07 ~ 2026-10-09）

> **这是快照，不是机型常量。** 下面每个编号、字节数、`md5`、模块数都只属于采到它的那台设备那一次。
> **OTA 一次、刷一次机就全失效。** 动手前必须重跑 `bash scripts/collect-device-facts.sh`，
> 以本机**当前**的值（`readlink -f /dev/block/by-name/<part>`、`md5sum`、`uname -r`、`boot_index`）为准；
> 本文件只用来理解「这些数字长什么样、量级和坑在哪」，**不得作为判断依据抄进任何结论**。

采集上下文（设备状态）：

- 机型：小米 17，`ro.product.device` = `pudding`（平台 `canoe`）
- OS：Android 17（SDK 37）；KMI 名：`android16-6-4k`；Linux 主线：`6.12`
- `uname -r` = `6.12.69-android16-6-4k-<你的署名后缀>`（成功版 `boot_index` 365）
- root：KernelSU **LKM**，补丁在 `init_boot`
- 快照日期：2026-10-08（`boot_index` 序列跨 2026-10-07 ~ 2026-10-09）

## 分区表与字节数（2026-10-08）

| 分区 | 节点 | 字节 |
| --- | --- | --- |
| `boot_a` | `/dev/block/sde14` | 100,663,296（96 MB） |
| `init_boot_a` | `/dev/block/sde30` | 8,388,608（8 MB） |
| `vendor_boot_a` | `/dev/block/sde25` | 100,663,296（96 MB） |
| `dtbo_a` | `/dev/block/sde18` | 33,554,432（32 MB） |

UFS 是多 LUN 的，同一台设备上有 `sda` ~ `sdf` 六条；`sdeNN` 里的 `NN` 是这块盘上的物理分区序号，
**换机、OTA、甚至同一机型的不同批次都可能不同**，所以脚本一律用 `readlink -f /dev/block/by-name/<part>`
解析，不硬编码 `sdeNN`。

`md5` 实测（同样只属于那一次）：

- `stock-boot.img` = `5157f9020b45b51ec1701c79cda9b93d`
- `init_boot_a.img` = `f78cdace08393da6272c658f2e1cc66e`

**绝不写成「小米 17 都如此」的断言。** 要的永远是本机现在的值。

## root 实况：KernelSU LKM，补丁在 `init_boot`

```
ksud -V        -> 4.2.0-1-g904c60d1 (uapi: 2)
id             -> uid=0(root) ... context=u:r:ksu:s0
init_boot 解包 -> init              607 KB    (SukiSU wrapper)
                  init.real        2.81 MB
                  kernelsu.ko      390 KB
                  stock_image.sha1   40 B
```

首屏 `init` 只有 607 KB、真 init 改名成 `init.real` 有 2.81 MB —— 这是「补丁在 `init_boot`」的
**直接证据**（不是推断）：wrapper 先把 `kernelsu.ko` 塞进内核，再把控制权交给 `init.real`。
`context=u:r:ksu:s0` 是 LKM 的特征 SELinux context。

两条由此得出的结论（写进正文的纪律）：

- **只刷 `boot` 不会掉 root。** 实测两次（`boot_index` 365 零调优版、372 mi_sched 版）：换掉 `boot` 里的
  `Image`、`init_boot` 一个字节没动（`init_boot_a` 的 md5 前后一致），root 完好。
- **`ksud boot-restore` 不能当回滚路径。** 它靠 `init_boot` 里的 `stock_image.sha1`（40 B）校验原始
  `boot` 是否被改过；`boot` 被自编内核换掉后 sha1 必然不匹配 → 它直接拒绝工作。回滚只能在 PC 上
  `fastboot flash boot_a <stock-boot.img>`。

## 模块数的四套口径（同一天同一台设备）

| 数字 | 口径 |
| --- | --- |
| 660 | `/proc/modules` 行数（已加载），原厂 |
| 670 | 自编成功版（换 `Image` 后多加载约 10 个） |
| 668 | 另一版构建 |
| 336 | `dmesg` 里带 `(O)` / `(OE)` 标记的模块行数 |

同口径的另一个基线：`ls /vendor_dlkm/lib/modules/*.ko | wc -l` 在原厂约 404（可加载数，不是已加载数）。

**只有口径相同的两个数字才能相减。** 拿 `dmesg` 的 336 去比 `/proc/modules` 的 660，就会得出
「少了 324 个模块」的假警报 —— 真相是它们数的根本不是同一批东西。真故障判据是
`dmesg | grep -ic 'disagrees about version\|Unknown symbol'` 期望为 0，不是模块总数。

## `boot_index` 实测序列（2026-10-07 ~ 2026-10-09，同一台 `pudding`）

```
原厂 357 → V1(AOSP 树,卡第一屏) 354 → V2(AOSP 树,卡第一屏) 356
        → 修复版(ABI 对齐,卡屏重启循环) 361/362 → 成功版(cctv18 树) 365
        → zstd/lz4 367 → mi_sched 372
```

**它编号的是「开机事件」，不是「镜像」。** 原厂 357 反而大于 V1 的 354，就是因为刷回旧镜像同样会拿到
一个更大的新编号。所以单看 `boot_index` 判断不出跑的是哪个镜像，必须与 `uname -r` 配对记录
（成功版 = `6.12.69-android16-6-4k-<你的署名后缀>` + `365`）。

修复版的自动重启循环是 `PM: Reset by PSHOLD` 硬复位，dmesg 里有
`Hard watchdog permanently disabled` —— **不是看门狗在工作**。

## 取证归属的真实病例

### 病例一：把上一轮内核的日志当成本轮（blackbox 361 段）

在 blackbox 的 361 段看到完全正常的 init 日志，于是判定「我们的内核起来了」；实际那是**刷机前
Jianke 轮**（`6.12.111-Jianke`）的运行日志，被本轮启动时的 bootmonitor 归档进来。

复核判据：整段里 `<你的署名后缀>` 零匹配、`6.12.93` 零匹配 → 不是本轮。教训：**「有日志」≠「是我们的日志」。**

### 病例二：`mtdoops` 里没有记录 ≠ 内核没跑

`mtdoops` 写的是**本轮内核正常关机时**的本轮日志；卡死的轮次没有关机路径 → 永远不会落盘。
分区里确实有记录，一度被读成「内核至少存活了 2.1 秒」，后来确认那条属于健康轮次
（`boot_index` 353）—— 卡死的 354 / 356 什么都没留下。

### 病例三：`/sys/fs/pstore` 与 oops 分区的实测覆盖

$ pstore 空；oops 分区（15 MB 全量）只有 `boot_index` 352/353/355/346/347/349/350/351，
**无 354、无 356**；blackbox（188 MB 全量）`boot_index=` 只有 348/353/355/357，`<你的署名后缀>` 零匹配。
这与病例二的结论一致：**没有记录不构成证据；有记录也可能属于别的轮次。**

## ARB 的侧面证据

机内 `ro.boot.anti` 为空 **≠** 没有 ARB。blackbox 实测 `the stored_rollback_index is: 1`，在
`boot_index` 361 / 362 / 364 多轮中一致、未见变化；**但刷 `boot` 不涉及 ARB 计数，所以这证明不了
「ARB 不会变」。** 要确定必须 `fastboot getvar anti`；**未知即按高危处理。**

## `build.env` 实测样例（2026-10-07，第三方内核轮）

```
KERNEL_RELEASE=6.12.111-Jianke          # 无 androidNN → 不是原厂构建
KMI_GENERATION=android16                # 来自 vendor 模块 vermagic，不是 uname -r
KMI_FROM_UNAME=                          # 空 —— 只信 uname 就会误 BLOCK
BOOT_INDEX=372                          # /proc/cmdline；刷机前后各记一次
FLASH_LOCKED=0                          # 来自 /proc/bootconfig；getprop 谎报 1
SPOOF_WARNING=getprop ro.boot.flash.locked=1 与 /proc/bootconfig 的 unlocked 矛盾…
ROOT_MODE=kernelsu-lkm
ROOT_CONTEXT=u:r:ksu:s0                 # id；LKM 的特征 context
KSUD_VERSION=4.2.0-1-g904c60d1 (uapi: 2)
ROOT_PARTITION=init_boot(推断…)
```

这是「跑第三方内核、只看 `uname -r` 就会误判 BLOCKED」的现场：`KMI_GENERATION` 只能靠 vermagic 拿到。
