#!/usr/bin/env bash
# check-anykernel-zip.sh — 在刷之前，机械地检查 AnyKernel3 zip 是不是一个能刷的包。
#
# 这个脚本只读，不改任何东西。它的价值在于：把「刷之前应该肉眼确认什么」
# 变成一条命令。AK3 的失败大多是打包错误（META-INF 不在根、kernel 文件名不对、
# modules 路径不对），而不是内核编译错误 —— 而打包错误刷进去会直接不开机。
#
# 用法: bash scripts/check-anykernel-zip.sh <zip 文件>

set -u
ZIP="${1:-}"
if [ -z "$ZIP" ]; then echo "用法: bash scripts/check-anykernel-zip.sh <zip>" >&2; exit 2; fi
[ -f "$ZIP" ] || { echo "找不到文件: $ZIP" >&2; exit 2; }

problems=0
warn=0
say()  { printf '  %s\n' "$*"; }
bad()  { printf '  [错误] %s\n' "$*"; problems=$((problems+1)); }
warnf(){ printf '  [警告] %s\n' "$*"; warn=$((warn+1)); }

# 优先用 zipinfo，退化到 unzip -Z1
list_zip() {
	if command -v zipinfo >/dev/null 2>&1; then zipinfo -1 "$ZIP"
	elif command -v unzip  >/dev/null 2>&1; then unzip -Z1 "$ZIP"
	else echo "__NO_ZIP_TOOL__"; fi
}
ENTRIES="$(list_zip)"
if [ "$ENTRIES" = "__NO_ZIP_TOOL__" ]; then
	echo "需要 zipinfo 或 unzip 才能检查。Android 上: pkg install unzip / apt install unzip" >&2
	exit 3
fi
command -v unzip >/dev/null 2>&1 && unzip -tq "$ZIP" >/dev/null 2>&1 && say "zip 完整性: OK" || warnf "无法用 unzip -t 验证完整性（缺少 unzip）"

echo "=== 1. 结构 ==="
echo "$ENTRIES" | grep -qx 'META-INF/com/google/android/update-binary' \
	&& say "META-INF/com/google/android/update-binary: 在根目录 ✓" \
	|| bad "META-INF/... 不在 zip 根目录 —— 多半是把整个文件夹压进去了。刷了会报错或什么都不做。"
echo "$ENTRIES" | grep -qx 'META-INF/com/google/android/updater-script' \
	&& say "updater-script: 在根目录 ✓" || warnf "没有 updater-script（部分 recovery 需要）"

echo
echo "=== 2. anykernel.sh ==="
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
if echo "$ENTRIES" | grep -qx 'anykernel.sh'; then
	say "anykernel.sh: 在根目录 ✓"
	unzip -p "$ZIP" anykernel.sh > "$TMPD/anykernel.sh" 2>/dev/null
	# 去掉注释行后打印有效设置
	sed 's/#.*$//' "$TMPD/anykernel.sh" | grep -E '^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=' | sed 's/^/    /' | head -40
	get() { sed 's/#.*$//' "$TMPD/anykernel.sh" | grep -E "^[[:space:]]*$1=" | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r'; }
	DOCHECK="$(get do\.devicecheck)"; DOCHECK="${DOCHECK:-0}"
	DOMOD="$(get do\.modules)";     DOMOD="${DOMOD:-0}"
	DEV1="$(get device\.name1)"
	BLOCK="$(get BLOCK)"
	ISLOT="$(get IS_SLOT_DEVICE)"
	SLOTSEL="$(get SLOT_SELECT)"
	PVF="$(get PATCH_VBMETA_FLAG)"
	NOVB="$(get NO_VBMETA_PARTITION_PATCH)"
	VERS="$(get supported\.versions)"

	echo
	echo "=== 3. 关键设置检查 ==="
	[ "$DOCHECK" = "1" ] && { [ -n "$DEV1" ] && say "do.devicecheck=1, device.name1=$DEV1 ✓" || bad "do.devicecheck=1 但 device.name1 为空 —— 刷到任何机器上都会过，等于没有防呆"; } \
		|| warnf "do.devicecheck 不是 1 —— 这个 zip 会被刷到任意设备上"
	[ -z "$BLOCK" ] && warnf "BLOCK 没设置。GKI 设备内核在 boot，写错分区是变砖级错误。" || say "BLOCK=$BLOCK"
	[ "$ISLOT" = "1" ] && say "IS_SLOT_DEVICE=1（A/B 设备）" || warnf "IS_SLOT_DEVICE 不是 1 —— 若这是 A/B 设备，必须为 1"
	if [ -n "$SLOTSEL" ]; then
		say "SLOT_SELECT=$SLOTSEL"
		case "$SLOTSEL" in
			both) warnf "SLOT_SELECT=both 会同时写两个槽位。只在确定要双写时使用。" ;;
			active|*active*) say "只写当前活动槽 ✓（推荐）" ;;
		esac
	else
		warnf "SLOT_SELECT 未设置。默认行为随 AK3 版本而异，建议显式写 active。"
	fi
	[ -n "$PVF" ] && say "PATCH_VBMETA_FLAG=$PVF（会动 vbmeta 标志）" || say "PATCH_VBMETA_FLAG 未设置（不动 vbmeta）"
	[ -n "$NOVB" ] && say "NO_VBMETA_PARTITION_PATCH=$NOVB"
	if [ -n "$VERS" ]; then say "supported.versions=$VERS"; else warnf "supported.versions 未设置"; fi
else
	bad "没有 anykernel.sh —— 这不是一个 AnyKernel3 包"
fi

echo
echo "=== 4. 内核镜像与 dtb ==="
# Image.lz4-dtb 必须在列表里：高通 msm-kernel / Kleaf 的 dist 目录里，
# TARGET_PREBUILT_KERNEL 就是 Image.lz4-dtb（内核 + 追加的 dtb 合成一个文件）。
# 少了它，一个完全正确的包会被判成「没有内核可刷」。
FOUND=""
for k in Image Image.gz Image.lz4 Image.lz4-dtb Image.gz-dtb zImage; do
	echo "$ENTRIES" | grep -qx "$k" && { say "内核: $k ✓"; FOUND="$k"; }
done
[ -n "$FOUND" ] || bad "根目录没有 Image / Image.gz / Image.lz4 / Image.lz4-dtb / zImage 中的任何一个 —— 没有内核可刷"
if [ "$FOUND" = "Image.lz4-dtb" ]; then
	say "    Image.lz4-dtb 是内核与 dtb 的合成产物（高通 Kleaf dist 的默认输出），确认它也覆盖了 dtb 的需求"
fi
echo "$ENTRIES" | grep -qx 'dtb' && say "dtb ✓" || warnf "没有 dtb 文件（若内核自带 dtb 可忽略，GKI 上通常需要）"

echo
echo "=== 5. 模块 ==="
if [ "$DOMOD" = "1" ]; then
	MKOS="$(echo "$ENTRIES" | grep -c '\.ko$')"
	[ "$MKOS" -gt 0 ] && say "内嵌 $MKOS 个 .ko ✓" || bad "do.modules=1 但 zip 里没有任何 .ko"
	for f in modules.dep modules.load modules.alias modules.softdep; do
		echo "$ENTRIES" | grep -q "$f" && say "有 $f ✓" || warnf "没有 $f —— 模块可能加载不上"
	done
	echo "$ENTRIES" | grep '\.ko$' | sed 's/^/    /' | head -10
	[ "$MKOS" -gt 10 ] && say "    ...（共 $MKOS 个）"
else
	say "do.modules 未开启，跳过模块检查"
fi

echo
echo "=== 6. AVB/vbmeta 提醒 ==="
echo "  重打包 boot 会让该分区的 AVB 哈希失效。若设备的 vbmeta 仍在验证它，"
echo "  开机会卡住或落到 recovery。处理办法是让 vbmeta 不再校验，而不是随手关 verity。"
echo "  这块的判断依据在 safe-kernel-flash 里，不要在这个脚本里猜。"

echo
echo "=== 7. 校验和（记下来，和刷机日志对账） ==="
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$ZIP" | sed 's/^/  /'
elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$ZIP" | sed 's/^/  /'
else warnf "没有 sha256sum/shasum"; fi

echo
echo "=== 结果 ==="
echo "  错误 $problems 项，警告 $warn 项"
[ "$problems" -eq 0 ] || { echo "  有错误 —— 不要刷这个包。"; exit 1; }
echo "  结构检查通过。注意：这只证明包是完整的，不证明内核是对的 ——"
echo "  内核正确性只能靠刷完开机验证（uname -r）与 kernel-perf-verification。"
exit 0
