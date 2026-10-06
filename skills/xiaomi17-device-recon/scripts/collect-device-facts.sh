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
kmi_gen=$(printf '%s' "$krel" | sed -n 's/.*-\(android[0-9][0-9]*\)-.*/\1/p')
kmi_gen="${kmi_gen:-$p_kmi_prop}"

# android14-6.1 这类 KMI 世代字符串里的内核版本线
kmi_line=$(printf '%s' "$krel" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

blockdev=$(run "ls /dev/block/by-name")
partitions=$(printf '%s\n' "$blockdev" | grep -v '^$' | sort | paste -sd, -)
part_count=$(printf '%s\n' "$blockdev" | grep -cv '^$')

for name in boot init_boot vendor_boot dtbo vbmeta recovery super; do
	eval "has_$name=0"
	printf '%s\n' "$blockdev" | grep -qx "$name${p_slot}" 2>/dev/null && eval "has_$name=1"
	printf '%s\n' "$blockdev" | grep -qx "$name" 2>/dev/null && eval "has_$name=1"
done

[ -n "$p_device" ]  || p_device="$UNKNOWN"
[ -n "$p_slot" ]    || p_slot="(无，可能非 A/B)"
[ -n "$krel" ]      || krel="$UNKNOWN"
[ -n "$kmi_gen" ]   || kmi_gen="$UNKNOWN"
[ -n "$kmi_line" ]  || kmi_line="$UNKNOWN"
[ -n "$partitions" ]|| partitions="$UNKNOWN"

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
KERNEL_LINE=$kmi_line
SLOT=$p_slot
VERIFIED_BOOT_STATE=$p_vbstate
FLASH_LOCKED=$p_locked
VERITY_MODE=$p_verity
ANTI_ROLLBACK_INDEX=$p_anti
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
	echo "| KMI 世代 | \`$kmi_gen\` | 由 uname -r 解析 |"
	echo "| 内核主线 | \`$kmi_line\` | 由 uname -r 解析 |"
	echo "| 当前槽位 | \`$p_slot\` | \`ro.boot.slot_suffix\` |"
	echo "| 验证启动状态 | \`$p_vbstate\` | \`ro.boot.verifiedbootstate\` |"
	echo "| BL 锁定 | \`$p_locked\`（1=锁，0=已解锁） | \`ro.boot.flash.locked\` |"
	echo "| verity 模式 | \`$p_verity\` | \`ro.boot.veritymode\` |"
	echo "| ARB 指数 | \`${p_anti:-$UNKNOWN}\` | \`ro.boot.anti\`（常为空，见下） |"
	echo "| vendor API level | \`$p_api\` | \`ro.vendor.api_level\` |"
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

if [ "$p_device" = "$UNKNOWN" ] || [ "$kmi_gen" = "$UNKNOWN" ]; then
	exit 3
fi
exit 0
