# `getprop` 会被伪造：安全启动状态的取证对照

上级文档：`../SKILL.md`（skill `xiaomi17-device-recon`）。正文只留结论，这里是完整取证细节。

## 结论先行

- 判断「能不能刷」**只看 `/proc/bootconfig`**；`getprop` 只作回退与对照。
- 装了隐藏模块的设备上，`resetprop` 会**伪造** `ro.boot.*`，`/proc/bootconfig` 改不到。
- 两个字段的**语义是反的**：`ro.boot.flash.locked` 是 `1=锁`；`androidboot.vbmeta.device_state` 是
  `unlocked` / `locked`。
- 判反 = 拿还锁着的 bootloader 去刷自制镜像 = **硬砖**。

## 实测对照

同一台设备上同时读两条路径（采集上下文与日期见 `probed-facts-20261008.md`：小米 17 `pudding`，
`uname -r` = `6.12.69-android16-6-4k-<你的署名后缀>`，成功版 `boot_index 365`，root = KernelSU LKM）：

| 属性 | `getprop` 的输出（被 `resetprop` 伪造） | `/proc/bootconfig` 的真值 |
| --- | --- | --- |
| `ro.boot.flash.locked` | `1`（看上去已锁定） | `androidboot.vbmeta.device_state = "unlocked"` |
| `ro.boot.verifiedbootstate` | `green`（看上去是原厂签名态） | `androidboot.verifiedbootstate = "orange"` |

伪造方是 `resetprop`，常见来源是 `tricky_store` / `playintegrityfix` / `YH_YC` 一类隐藏模块。

## 为什么 `/proc/bootconfig` 改不到

`/proc/bootconfig` 是**内核启动时从 bootloader 收到并固化的参数表**，由内核 `bootconfig` 子系统在启动
早期生成，是内核态的只读数据。`resetprop`（Magisk / KernelSU 的 prop 覆写机制）只改 Android
**userspace 的 property service** 里的键值 —— 它根本不经过 `/proc/bootconfig` 这个文件，所以伪造对它无效。

推论：

- `getprop ro.boot.*` 的**任何**值都可能被隐藏模块改写；`/proc/bootconfig` 不会。
- `/proc/bootconfig` 反映的是**这一次开机**bootloader 传进来的状态，重启/刷机后会更新 —— 它也不是
  「永久熔丝」，ARB 那类一次性的东西它不表达（ARB 见正文的 `ANTI_ROLLBACK_INDEX`）。

## 具体怎么读

```bash
# 真值：解锁状态（unlocked / locked）
grep -o 'androidboot.vbmeta.device_state=[^ ]*' /proc/bootconfig

# 真值：验证启动状态（green / orange / yellow / red）
grep -o 'androidboot.verifiedbootstate=[^ ]*' /proc/bootconfig

# 对照（可能被伪造）
getprop ro.boot.flash.locked            # 0 = 解锁
getprop ro.boot.verifiedbootstate
getprop ro.boot.veritymode              # enforcing / disabled，决定要不要动 vbmeta
```

`scripts/collect-device-facts.sh` 把这两条路径**都**采下来（`FLASH_LOCKED` 取 bootconfig，`getprop`
版本另存为对照），不一致时在档案里写 `SPOOF_WARNING`。看到这条警告，说明设备上存在 prop 伪造，
**不要**再拿 `getprop` 的值做刷写判断。

## 常见误判

- **只看 `getprop ro.boot.flash.locked` 判断能不能刷** → 隐藏模块把它伪造成 `1`，你以为设备锁着，
  其实已解锁；反过来把真锁的设备当成解锁的，下一次刷写就是硬砖。
- **把 `androidboot.vbmeta.device_state` 当成 `0/1` 读** → 它给的是 `unlocked` / `locked` 字符串，
  `[ "$x" = 0 ]` 这类判断恒为假。
- **以为 `verifiedbootstate=green` 就代表原厂内核** → 它同样会被伪造；当前是否原厂要看 `uname -r`
  里有没有 `androidNN` 标记，不是看这个属性。
- **以为 `/proc/bootconfig` 里的值就是「刷机状态」** → 它是开机时快照；`fastboot` 侧的状态
  （如 `fastboot oem device-info`、`fastboot getvar anti`）必须另外采。
