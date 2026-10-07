#!/usr/bin/env bash
# collect-device-facts.sh — 只读地采集设备事实，写出 device-profile.md 与 build.env。
#
# 这个脚本永远不写任何分区、不改任何 prop。可选地备份原厂镜像（--backup）。
#
# 用法：
#   bash scripts/collect-device-facts.sh                  # 脚本在手机上运行（Operit 终端）
#   bash scripts/collect-device-facts.sh --root           # 脚本在手机上运行，用 su 提权读取
#   bash scripts/collect-device-facts.sh --adb            # 脚本在电脑上运行，通过 adb 读取
#   bash scripts/collect-device-facts.sh --backup         # 额外把原厂 boot/init_boot/... dd 到 backup/
#   bash scripts/collect-device-facts.sh --out DIR        # 改运行时目录（默认见 OUT_DIR）
#
# 退出码：0 = 所有 REQUIRED 字段都有值；3 = 有字段仍是 UNKNOWN（此时禁止开始编译/刷写）。

set -u

OUT_DIR="/sdcard/Download/Operit/kernel-dev"
MODE="local"
DO_BACKUP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--adb)    MODE="adb"; shift ;;
		--root)   MODE="root"; shift ;;
		--backup) DO_BACKUP=1; shift ;;
		--out)    OUT_DIR="${2:?--out 需要一个目录}"; shift 2 ;;
		-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

# --- 运行环境前置检查 --------------------------------------------------------
# 这个脚本必须在 **Android 侧的 shell** 里跑。Operit 自带的 proot Ubuntu 终端
# 看上去「也是 Linux、也是 root」，但那里没有 getprop、没有 /data/adb、没有
# /dev/block/by-name，而且那里的 su 是 Ubuntu 的 su（proot 里本来就是 root，
# su -c 的语义完全不同）。
#
# 在那里跑**不会报错** —— 它会静默产出一份全 UNKNOWN 的 BLOCKED 档案。
# 「写出了档案」和「档案是对的」是两件事，而且前者会让人以为已经可以往下走了。
# 实测病例：2026-10-07，小米 17，Operit proot 终端里 --root 跑出全空档案。
if [ "$MODE" != "adb" ]; then
	if ! command -v getprop >/dev/null 2>&1; then
		{
			echo "环境错误：这个 shell 里没有 getprop。"
			echo
			echo "getprop 属于 Android 的 /system/bin。找不到它，说明你不在 Android 侧 shell 里 ——"
			echo "最常见的场景是在 Operit 自带的 proot Ubuntu 终端里跑本脚本。"
			echo "proot 里没有 getprop、没有 /data/adb、没有 /dev/block/by-name，"
			echo "它自带的 su 也不是 Android 的 su。"
			echo
			echo "在那种环境里跑，本脚本不会报错，只会静默写出一份全 UNKNOWN 的档案。那比失败更糟。"
			echo
			echo "换一个通道再跑："
			echo "  * Operit 的 Shizuku / Root 终端（不是 proot 终端）"
			echo "  * 或从电脑跑：bash scripts/collect-device-facts.sh --adb"
		} >&2
		exit 3
	fi
	if [ ! -d /dev/block/by-name ]; then
		echo "警告：看不到 /dev/block/by-name —— 分区清单与存在性判断会全部为空。" >&2
		echo "  不致命，但请人工补齐，不要当成「这台设备没有分区」。" >&2
	fi
fi

run() {
	case "$MODE" in
		adb)  adb shell "$*" 2>/dev/null | tr -d '\r' ;;
		root) su -c "$*" 2>/dev/null | tr -d '\r' ;;
		*)    sh -c "$*" 2>/dev/null | tr -d '\r' ;;
	esac
}

prop()  { run "getprop $1"; }
first() { printf '%s\n' "$1" | head -n1; }

UNKNOWN="UNKNOWN"

p_device=$(first "$(prop ro.product.device)")
p_model=$(first "$(prop ro.product.model)")
p_platform=$(first "$(prop ro.board.platform)")
p_soc=$(first "$(prop ro.soc.model)")
p_rel=$(first "$(prop ro.build.version.release)")
p_sdk=$(first "$(prop ro.build.version.sdk)")
p_spl=$(first "$(prop ro.build.version.security_patch)")
p_vspl=$(first "$(prop ro.vendor.build.security_patch)")
p_display=$(first "$(prop ro.build.display.id)")
p_slot=$(first "$(prop ro.boot.slot_suffix)")
p_vbstate=$(first "$(prop ro.boot.verifiedbootstate)")
p_locked=$(first "$(prop ro.boot.flash.locked)")
p_verity=$(first "$(prop ro.boot.veritymode)")
p_anti=$(first "$(prop ro.boot.anti)")
p_kmi_prop=$(first "$(prop ro.boot.kmi)")
p_api=$(first "$(prop ro.vendor.api_level)")

krel=$(first "$(run uname -r)")

# --- KMI 世代：三个来源，只信 uname -r 是不够的 ------------------------------
# KMI 世代决定你该编/刷哪个 GKI 分支，也决定 vendor 的预编译模块认不认你的新内核。
#
# **跑第三方内核的设备上，uname -r 里可能根本没有 androidNN 标记** —— 编内核的人
# 改过 CONFIG_LOCALVERSION。于是 KMI 恒为 UNKNOWN，整份档案被判成 BLOCKED，
# 而设备其实一点毛病都没有。这是「来源单一」造成的误 BLOCK，不是设备问题。
#
# 实测病例（2026-10-07，小米 17，第三方内核）：
#   uname -r                        -> 6.12.111-Jianke      （无 androidNN）
#   getprop ro.boot.kmi             -> 空
#   modinfo /vendor_dlkm/lib/modules/adsp_loader_dlkm.ko -F vermagic
#                                   -> 6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64
#   => KMI 世代 = android16
# vermagic 是编模块时就固化进 .ko 的，换内核不会改它 —— 而这恰恰就是
# 「新内核必须满足谁」的答案。所以它排在 uname -r 前面。
kmi_uname=$(printf '%s' "$krel" | sed -n 's/.*-\(android[0-9][0-9]*\)-.*/\1/p')

kmi_vermagic=""
kmi_vermagic_src=""
for _d in /vendor_dlkm/lib/modules /vendor/lib/modules; do
	[ -d "$_d" ] || continue
	_ko=$(ls "$_d"/*.ko 2>/dev/null | head -n1)
	[ -n "$_ko" ] || continue
	_vm=$(run "modinfo -F vermagic $_ko")
	[ -n "$_vm" ] || _vm=$(run "strings $_ko" | grep -oE 'android[0-9]+-[0-9]+-[0-9]+k' | head -n1)
	kmi_vermagic=$(printf '%s' "$_vm" | sed -n 's/.*\(android[0-9][0-9]*\)-.*/\1/p' | head -n1)
	if [ -n "$kmi_vermagic" ]; then
		kmi_vermagic_src="$_ko"
		break
	fi
done

kmi_gen=""
kmi_src=""
if [ -n "$kmi_vermagic" ]; then
	kmi_gen="$kmi_vermagic"
	kmi_src="vendor 模块 vermagic [$kmi_vermagic_src]"
elif [ -n "$kmi_uname" ]; then
	kmi_gen="$kmi_uname"
	kmi_src="uname -r"
elif [ -n "$p_kmi_prop" ]; then
	kmi_gen="$p_kmi_prop"
	kmi_src="ro.boot.kmi"
fi

# 三个来源互相矛盾时必须让 agent 看见。矛盾本身就是信息：
# 它通常意味着有人换过内核或换过 vendor 分区，而不是「随便挑一个用」。
kmi_conflict=""
if [ -n "$kmi_vermagic" ] && [ -n "$kmi_uname" ] && [ "$kmi_vermagic" != "$kmi_uname" ]; then
	kmi_conflict="uname -r 说 $kmi_uname，vendor 模块 vermagic 说 $kmi_vermagic —— 两者不一致，已取 vermagic"
fi
if [ -n "$kmi_gen" ] && [ -n "$p_kmi_prop" ] && [ "$kmi_gen" != "$p_kmi_prop" ]; then
	kmi_conflict="${kmi_conflict:+$kmi_conflict；}ro.boot.kmi 说 $p_kmi_prop，与 $kmi_gen 不一致"
fi

# 运行中的内核版本线（6.12 这种）。它来自 uname -r，与 KMI 世代是两件事。
kmi_line=$(printf '%s' "$krel" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

# --- 启动参数真值：/proc/bootconfig -------------------------------------------
# 已 root 并装了隐藏模块（tricky_store / playintegrityfix / YH_YC 之类）的设备上，
# getprop 报的 BL 锁定状态与验证启动状态是**被 resetprop 伪造过的**。
# 实测病例（2026-10-07，小米 17，装了 YH_YC / tricky_store / playintegrityfix）：
#   getprop ro.boot.flash.locked      -> 1       （实际已解锁）
#   getprop ro.boot.verifiedbootstate -> green   （实际 orange）
#   /proc/bootconfig 里：
#     androidboot.vbmeta.device_state = "unlocked"
#     androidboot.verifiedbootstate   = "orange"
# /proc/bootconfig 是内核启动时收到的参数，resetprop 改不到它 —— 那里才是真值。
# FLASH_LOCKED 直接用来判断「能不能刷」，判反了就是硬砖，所以这个优先级不能省。
bcprop() {
	run "cat /proc/bootconfig" | tr -d '"' \
		| sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" \
		| head -n1
}

bc_device_state=$(first "$(bcprop androidboot.vbmeta.device_state)")
bc_vbstate=$(first "$(bcprop androidboot.verifiedbootstate)")

# 两个字段的语义是反的：ro.boot.flash.locked 是 1=锁；vbmeta.device_state 是 unlocked/locked。
flash_locked_bc=""
case "$bc_device_state" in
	unlocked) flash_locked_bc="0" ;;
	locked)   flash_locked_bc="1" ;;
esac
if [ -n "$flash_locked_bc" ]; then
	flash_locked="$flash_locked_bc"
	flash_locked_src="/proc/bootconfig [$bc_device_state]"
else
	flash_locked="$p_locked"
	flash_locked_src="getprop ro.boot.flash.locked"
fi
if [ -n "$bc_vbstate" ]; then
	vbstate="$bc_vbstate"
	vbstate_src="/proc/bootconfig"
else
	vbstate="$p_vbstate"
	vbstate_src="getprop ro.boot.verifiedbootstate"
fi

# 两者矛盾 = getprop 被伪造。这必须说出来，不能让 agent 以为读到的 1 是真的。
spoof_warn=""
if [ -n "$flash_locked_bc" ] && [ -n "$p_locked" ] && [ "$flash_locked_bc" != "$p_locked" ]; then
	spoof_warn="getprop ro.boot.flash.locked=$p_locked 与 /proc/bootconfig 的 $bc_device_state 矛盾，已按 bootconfig 取 $flash_locked。getprop 在这台设备上不可信。"
fi
if [ -n "$bc_vbstate" ] && [ -n "$p_vbstate" ] && [ "$bc_vbstate" != "$p_vbstate" ]; then
	spoof_warn="${spoof_warn:+$spoof_warn }getprop ro.boot.verifiedbootstate=$p_vbstate 与 /proc/bootconfig 的 $bc_vbstate 矛盾，已按 bootconfig 取 $bc_vbstate。"
fi

blockdev=$(run "ls /dev/block/by-name")
partitions=$(printf '%s\n' "$blockdev" | grep -v '^$' | sort | paste -sd, -)
part_count=$(printf '%s\n' "$blockdev" | grep -cv '^$')

for name in boot init_boot vendor_boot dtbo vbmeta recovery super; do
	eval "has_$name=0"
	printf '%s\n' "$blockdev" | grep -qx "$name${p_slot}" 2>/dev/null && eval "has_$name=1"
	printf '%s\n' "$blockdev" | grep -qx "$name" 2>/dev/null && eval "has_$name=1"
done

# --- 现有 root 方案 ------------------------------------------------------------
# 这不是"顺便看看"。刷入自编内核会换掉 root 所在的那个分区，而**是哪个分区，在
# GKI 设备上和你以为的不一样**：内核在 boot，通用 ramdisk 在 init_boot。KernelSU
# 的 LKM 模式把模块补丁打进 ramdisk，所以补丁多半在 init_boot —— 只备份 boot
# 等于没有退路。这里全部是只读判断，不写任何分区、不改任何 prop。
root_mode="none"
if command -v magisk >/dev/null 2>&1 || [ -d /data/adb/magisk ]; then
	root_mode="magisk"
fi
if command -v ksud >/dev/null 2>&1 || [ -d /data/adb/ksu ]; then
	root_mode="kernelsu-lkm"
	run "zcat /proc/config.gz" | grep -q '^CONFIG_KSU=y' && root_mode="kernelsu-gki"
fi
[ "$root_mode" = "none" ] && command -v apd >/dev/null 2>&1 && root_mode="apatch"
# 有 su 但认不出管理器时不要谎报 none —— "未知"和"没有"是两件事。
[ "$root_mode" = "none" ] && command -v su >/dev/null 2>&1 && root_mode="manager-unknown"

# 补丁落在哪个分区：GKI 布局下内核在 boot、通用 ramdisk 在 init_boot。
# 只有管理器界面显示的"修补目标"才是权威答案，这里给的是最可能的推断。
root_partition="$UNKNOWN"
case "$root_mode" in
	kernelsu-gki) root_partition="boot" ;;
	kernelsu-lkm|magisk|apatch)
		if [ "$has_init_boot" = "1" ]; then
			root_partition="init_boot(推断；以管理器安装页的修补目标为准)"
		else
			root_partition="boot(推断；设备无 init_boot 分区)"
		fi
		;;
	none) root_partition="none" ;;
esac

# 通道到底通没通？getprop 在、但四条最基本的信息全为空 —— 那不是「这台设备没有
# 这些属性」，而是采集通道没工作（su 被解析成别的实现、或提权被拒后被
# run() 的 2>/dev/null 吞掉了）。区分「没有」和「读不到」是本脚本存在的意义之一，
# 所以这里必须停下，而不是把四个空字段写进档案。
probe_ok=0
for _v in "$p_device" "$p_model" "$p_platform" "$p_rel"; do
	[ -n "$_v" ] && probe_ok=1
done
if [ "$probe_ok" = "0" ]; then
	{
		echo "环境错误：getprop 存在，但四条最基本的信息全为空："
		echo "  ro.product.device / ro.product.model / ro.board.platform / ro.build.version.release"
		echo
		echo "这不是「这台设备没有这些属性」，而是采集通道没有工作。常见原因："
		echo "  * 在 proot 之类非 Android shell 里跑（那里的 su 不是 Android 的 su）"
		echo "  * 提权被拒，而 su 的提示被 2>/dev/null 吞掉了"
		echo
		echo "先解决通道，再采集。不要拿一份全空的档案往下走。"
	} >&2
	exit 3
fi

[ -n "$p_device" ]  || p_device="$UNKNOWN"
[ -n "$p_slot" ]    || p_slot="(无，可能非 A/B)"
[ -n "$krel" ]      || krel="$UNKNOWN"
[ -n "$kmi_gen" ]   || kmi_gen="$UNKNOWN"
[ -n "$kmi_line" ]  || kmi_line="$UNKNOWN"
[ -n "$partitions" ]|| partitions="$UNKNOWN"
[ -n "$flash_locked" ] || flash_locked="$UNKNOWN"
[ -n "$p_verity" ]  || p_verity="$UNKNOWN"
[ -n "$vbstate" ]   || vbstate="$UNKNOWN"
[ -n "$kmi_src" ]   || kmi_src="三个来源都没取到"

# 输出目录必须先确认可写。否则后面的 `cat > file` 会逐个报 "No such file or
# directory"，脚本却仍然打印「已写出」——档案根本没落盘，而 agent 以为采集成功了。
# 这个失败模式在非 Android 环境（例如桌面上的 Git bash）上必然发生，必须挡在这里。
if ! mkdir -p "$OUT_DIR/backup" "$OUT_DIR/logs" 2>/dev/null; then
	echo "无法创建输出目录: $OUT_DIR" >&2
	echo "请用 --out <可写目录> 指定，例如：" >&2
	echo "  bash scripts/collect-device-facts.sh --out /sdcard/Download/Operit/kernel-dev" >&2
	exit 3
fi
if ! { : > "$OUT_DIR/.write-test"; } 2>/dev/null; then
	echo "输出目录不可写: $OUT_DIR" >&2
	echo "请用 --out <可写目录> 指定。" >&2
	exit 3
fi
rm -f "$OUT_DIR/.write-test"

if [ "$DO_BACKUP" = "1" ]; then
	stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)
	for part in boot init_boot vendor_boot dtbo vbmeta; do
		src="/dev/block/by-name/${part}${p_slot}"
		[ -e "$src" ] || src="/dev/block/by-name/${part}"
		[ -e "$src" ] || { echo "跳过 $part：分区不存在" >&2; continue; }
		dst="$OUT_DIR/backup/${part}${p_slot}-${stamp}.img"
		run "dd if=$src of=$dst bs=4096" >/dev/null 2>&1 \
			&& echo "已备份 $src -> $dst" \
			|| echo "备份 $part 失败（需要 root）" >&2
	done
	echo "警告：把 $OUT_DIR/backup 整体拷出手机（另一台电脑 + 云盘各一份）。留在手机上不算备份。"
fi

cat > "$OUT_DIR/build.env" <<EOF
DEVICE=$p_device
MODEL=$p_model
PLATFORM=$p_platform
SOC=$p_soc
ANDROID_RELEASE=$p_rel
SDK=$p_sdk
SECURITY_PATCH=$p_spl
VENDOR_SECURITY_PATCH=$p_vspl
BUILD_DISPLAY_ID=$p_display
KERNEL_RELEASE=$krel
KMI_GENERATION=$kmi_gen
KMI_SOURCE="$kmi_src"
KMI_FROM_VERMAGIC=$kmi_vermagic
KMI_FROM_UNAME=$kmi_uname
KMI_FROM_PROP=$p_kmi_prop
KMI_VERMAGIC_MODULE=$kmi_vermagic_src
KMI_CONFLICT="$kmi_conflict"
KERNEL_LINE=$kmi_line
SLOT=$p_slot
VERIFIED_BOOT_STATE=$vbstate
VERIFIED_BOOT_STATE_SOURCE="$vbstate_src"
FLASH_LOCKED=$flash_locked
FLASH_LOCKED_SOURCE="$flash_locked_src"
FLASH_LOCKED_GETPROP=$p_locked
SPOOF_WARNING="$spoof_warn"
VERITY_MODE=$p_verity
ANTI_ROLLBACK_INDEX=$p_anti
ROOT_MODE=$root_mode
ROOT_PARTITION=$root_partition
VENDOR_API_LEVEL=$p_api
HAS_BOOT=$has_boot
HAS_INIT_BOOT=$has_init_boot
HAS_VENDOR_BOOT=$has_vendor_boot
HAS_DTBO=$has_dtbo
HAS_VBMETA=$has_vbmeta
HAS_RECOVERY=$has_recovery
HAS_SUPER=$has_super
PARTITION_COUNT=$part_count
EOF

{
	echo "# Device profile"
	echo
	echo "> 由 \`bash scripts/collect-device-facts.sh\` 采集于 $(date -Iseconds 2>/dev/null || date)。"
	echo "> 这个文件是运行时产物，**不要提交进任何仓库**。"
	echo
	echo "| 字段 | 值 | 来源 |"
	echo "| --- | --- | --- |"
	echo "| 设备代号 device | \`$p_device\` | \`ro.product.device\` |"
	echo "| 营销名 model | \`$p_model\` | \`ro.product.model\` |"
	echo "| 平台 | \`$p_platform\` | \`ro.board.platform\` |"
	echo "| SoC | \`$p_soc\` | \`ro.soc.model\` |"
	echo "| Android 版本 | \`$p_rel\` (SDK \`$p_sdk\`) | \`ro.build.version.*\` |"
	echo "| 安全补丁 | \`$p_spl\` / vendor \`$p_vspl\` | \`ro.*.build.security_patch\` |"
	echo "| 当前 ROM | \`$p_display\` | \`ro.build.display.id\` |"
	echo "| 内核 release | \`$krel\` | \`uname -r\` |"
	echo "| KMI 世代 | \`$kmi_gen\` | $kmi_src |"
	echo "| KMI 来源三值 | vermagic=\`$kmi_vermagic\` / uname=\`$kmi_uname\` / prop=\`$p_kmi_prop\` | 三者矛盾时取 vermagic |"
	echo "| 内核主线 | \`$kmi_line\` | 由 uname -r 解析 |"
	echo "| 当前槽位 | \`$p_slot\` | \`ro.boot.slot_suffix\` |"
	echo "| 验证启动状态 | \`$vbstate\` | $vbstate_src |"
	echo "| BL 锁定 | \`$flash_locked\`（1=锁，0=已解锁） | $flash_locked_src |"
	echo "| verity 模式 | \`$p_verity\` | \`ro.boot.veritymode\` |"
	echo "| ARB 指数 | \`${p_anti:-$UNKNOWN}\` | \`ro.boot.anti\`（常为空，见下） |"
	echo "| 现有 root | \`$root_mode\` | \`/data/adb\`、\`su -v\`、\`ksud\`、\`/proc/config.gz\` |"
	echo "| root 补丁所在分区 | \`$root_partition\` | 分区存在性 + 管理器修补目标 |"
	echo "| vendor API level | \`$p_api\` | \`ro.vendor.api_level\` |"
	echo
	if [ -n "$spoof_warn" ]; then
		echo "## 警告：getprop 被隐藏模块伪造"
		echo
		echo "$spoof_warn"
		echo
		echo "在装了 tricky_store / playintegrityfix / YH_YC 这类隐藏模块的设备上，这是常态。"
		echo "\`ro.boot.flash.locked\` 与 \`ro.boot.verifiedbootstate\` 一律优先信 \`/proc/bootconfig\`。"
		echo "拿被伪造的 1（=已锁定）去判断「能不能刷」，会把结论判反。"
		echo
	fi
	if [ -n "$kmi_conflict" ]; then
		echo "## 警告：KMI 世代来源不一致"
		echo
		echo "$kmi_conflict"
		echo
		echo "来源不一致通常意味着这台设备换过内核、或换过 vendor 分区 —— 本身就是信息，"
		echo "不要随手挑一个用。编内核时应以 vendor 模块 vermagic 为准（那才是新内核要满足的一方）。"
		echo
	fi
	echo "## 现有 root 方案"
	echo
	if [ "$root_mode" = "none" ]; then
		echo "没有检测到已知的 root 管理器。这可能意味着**确实没有 root**，也可能意味着"
		echo "root 方案不在脚本认识的路径里。**这两件事不是一回事**，别混为一谈。"
		echo
		echo "- 确实没有 root → 没有 patch 型 root，不需要备份 root 分区。"
		echo "- 只是没认出来 → 先确认清楚再往下走。刷自编内核会换掉 root 所在的那个分区。"
	else
		echo "检测到：\`$root_mode\`。**刷自编内核之前，要备份的是 \`$root_partition\` —— 不是想当然的 \`boot\`。**"
		echo
		echo "GKI 设备上内核在 \`boot\`、通用 ramdisk 在 \`init_boot\`。KernelSU 的 LKM 模式把"
		echo "\`kernelsu.ko\` 的补丁打进 ramdisk，所以补丁在 \`init_boot\`；刷一个新的 \`boot.img\`"
		echo "**不会**抹掉它 —— 会不会掉 root，取决于新内核的 KMI / 模块校验是否还让那个 \`.ko\` 加载。"
		echo "这一条必须实测，不能推。"
		echo
		echo "权威答案在 KernelSU / Magisk 管理器的\"安装\"（修补）页面：它写明正在修补哪个镜像。"
		echo "脚本给的 \`$root_partition\` 只是推断，界面才是事实。"
		echo
		echo "LKM 模式还意味着：**SUSFS 拿不到**（它是内核源码级补丁，必须自编译内核走 GKI 模式）。"
	fi
	echo
	echo "## 当前内核是不是原厂的"
	echo
	if [ -n "$kmi_uname" ]; then
		echo "\`uname -r\` = \`$krel\`，带 KMI 标记 \`$kmi_uname\` —— 这是一个 GKI 构建（可能是原厂，也可能是在原厂基础上重编的）。"
	else
		echo "**\`uname -r\` = \`$krel\` 里没有 \`androidNN\` 标记。** 这通常意味着它**不是原厂 GKI 构建**"
		echo "（编内核的人改过 \`CONFIG_LOCALVERSION\`）。"
		echo
		echo "这对「备份」的含义有直接影响：现在 \`dd\` 出来的 \`boot\` 备份**不是原厂镜像**，"
		echo "它只能带你回到上一个第三方内核，回不到出厂状态。想要真正的退路，得从与当前"
		echo "ROM 版本、ARB 指数都一致的官方 fastboot ROM 里取出原厂 \`boot.img\` / \`init_boot.img\`。"
		echo
		echo "也正因如此，KMI 世代不能靠 \`uname -r\` 判断 —— 见上表的 KMI 来源三值。"
	fi
	echo
	echo "## 分区布局"
	echo
	echo "\`/dev/block/by-name\` 共 $part_count 项：\`$partitions\`"
	echo
	echo "关键分区存在性：boot=$has_boot init_boot=$has_init_boot vendor_boot=$has_vendor_boot dtbo=$has_dtbo vbmeta=$has_vbmeta recovery=$has_recovery super=$has_super"
	echo
	echo "## ARB / 防回滚"
	echo
	if [ -n "$p_anti" ]; then
		echo "机内读到 \`ro.boot.anti=$p_anti\`。把它记下来：**往后的刷写绝不能把 ARB 指数推高**，推高不可逆。"
	else
		echo "机内没有 \`ro.boot.anti\`。必须从电脑跑以下命令补齐，否则视为 UNKNOWN："
		echo
		echo '```'
		echo "fastboot getvar anti"
		echo "fastboot getvar current-slot"
		echo "fastboot getvar all 2>&1 | grep -Ei 'anti|slot|unlock|verity'"
		echo '```'
	fi
	echo
	echo "## 待人工补齐（电脑侧）"
	echo
	echo '```'
	echo "fastboot devices"
	echo "fastboot oem device-info        # 期望 Device unlocked: true"
	echo "fastboot getvar current-slot"
	echo "fastboot getvar anti"
	echo '```'
	echo
	echo "## 结论"
	echo
	if [ "$p_device" = "$UNKNOWN" ] || [ "$kmi_gen" = "$UNKNOWN" ]; then
		echo "**BLOCKED**：device 或 KMI 世代仍是 UNKNOWN。在补齐之前不要开始编译，更不要刷写。"
	else
		echo "**READY**：device=\`$p_device\`，kmi=\`$kmi_gen\`，slot=\`$p_slot\`，内核=\`$krel\`。"
	fi
} > "$OUT_DIR/device-profile.md"

if [ -s "$OUT_DIR/device-profile.md" ] && [ -s "$OUT_DIR/build.env" ]; then
	echo "已写出："
	echo "  $OUT_DIR/device-profile.md"
	echo "  $OUT_DIR/build.env"
else
	echo "写出失败：$OUT_DIR 下没有生成完整档案。这是脚本的错，不是你的错——" >&2
	echo "把上面完整输出回执给用户，不要继续往下走。" >&2
	exit 3
fi
echo
cat "$OUT_DIR/device-profile.md"

# 档案写出来了，但它能用吗？把缺的 REQUIRED 字段逐个点名。
# 「静默产出 + 只给一个 exit 3」对 agent 没有用 —— 它需要知道缺的是哪一项、该修什么。
missing=""
[ "$p_device" = "$UNKNOWN" ]     && missing="$missing DEVICE"
[ "$krel" = "$UNKNOWN" ]         && missing="$missing KERNEL_RELEASE"
[ "$kmi_gen" = "$UNKNOWN" ]      && missing="$missing KMI_GENERATION"
[ "$flash_locked" = "$UNKNOWN" ] && missing="$missing FLASH_LOCKED"
[ "$p_verity" = "$UNKNOWN" ]     && missing="$missing VERITY_MODE"

if [ "$p_device" = "$UNKNOWN" ] || [ "$kmi_gen" = "$UNKNOWN" ]; then
	[ -n "$missing" ] && echo "REQUIRED 字段缺：$missing" >&2
	echo "脚本跑完了，但这不是一份可以往下走的档案。先补齐上面这些。" >&2
	exit 3
fi
[ -n "$missing" ] && echo "注意：这些 REQUIRED 字段仍然缺 —— $missing" >&2
exit 0
