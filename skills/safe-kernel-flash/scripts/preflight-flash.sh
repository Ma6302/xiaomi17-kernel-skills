#!/usr/bin/env bash
# preflight-flash.sh — 刷内核之前的硬闸门。只读，不写任何分区。
#
# 这个脚本不是把刷机步骤念一遍，它只回答一个问题：
#
#     如果这次刷完再也不亮，我下一句话能说什么？
#
# 答不上来就以 exit 3 结束，并点名缺的是哪一项。
#
# 检查项（前四条是硬闸门，缺一个就 exit 3）：
#   1. 启动参数真值：/proc/bootconfig —— **不是** getprop（本机 getprop 被 resetprop 伪造）
#   2. 当前基线：uname -r / boot_index，供刷后对比
#   3. 硬闸门 A：回滚镜像已在 PC 上，md5 与实测值逐字匹配
#   4. 硬闸门 B：ROOT_PARTITION（本机是 init_boot，不是 boot）已经备份
#   5. 硬闸门 C：只允许 boot_a —— 产物若是整包固件则直接拒
#   6. 硬闸门 D：绝不 flash_all / 绝不刷整包（会触发 ARB，不可逆）
#   7. 分区存在性与尺寸、电量、包完整性、AK3 的 devicecheck 假防呆
#
# 用法：
#   bash scripts/preflight-flash.sh --zip <AK3.zip> --pc-rollback /path/to/pc/rollback
#   bash scripts/preflight-flash.sh --image boot-new.img --pc-manifest rollback-manifest.txt
#   bash scripts/preflight-flash.sh --zip ... --pc-rollback ... --root-partition init_boot
#
# 回滚证据有两种，至少给一种，否则闸门 A 直接阻塞：
#   --pc-rollback DIR    DIR 里就是 PC 上那些回滚镜像，脚本会**亲自算 md5**（强形式）
#   --pc-manifest FILE   PC 上 `md5sum stock-boot.img ... > rollback-manifest.txt` 的产物
#                        再传到手机（自述形式；脚本会逐字核对表内 md5，不许有来路不明的镜像）
#
# 退出码：0 = 可刷；3 = 有阻塞项（不要刷）；2 = 参数错误。

set -u

ZIP=""
IMAGE=""
BACKUP="/sdcard/Download/Operit/kernel-dev/backup"
OUT_DIR="/sdcard/Download/Operit/kernel-dev"
PC_ROLLBACK=""
PC_MANIFEST=""
ROOT_PART_OVERRIDE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--zip)            ZIP="${2:?--zip 需要一个文件}"; shift 2 ;;
		--image)          IMAGE="${2:?--image 需要一个文件}"; shift 2 ;;
		--backup)         BACKUP="${2:?--backup 需要一个目录}"; shift 2 ;;
		--out)            OUT_DIR="${2:?--out 需要一个目录}"; shift 2 ;;
		--pc-rollback)    PC_ROLLBACK="${2:?--pc-rollback 需要一个目录}"; shift 2 ;;
		--pc-manifest)    PC_MANIFEST="${2:?--pc-manifest 需要一个文件}"; shift 2 ;;
		--root-partition) ROOT_PART_OVERRIDE="${2:?--root-partition 需要一个分区名}"; shift 2 ;;
		-h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

# --- 实测常量（来自 _kt-kernel/docs/device-facts.md，2026-10-08 采集） -----------
STOCK_BOOT_MD5="5157f9020b45b51ec1701c79cda9b93d"   # 真原厂 6.12.69，首选回滚
BOOT_A_MD5="5329fec9e9c154913673065734662067"        # Jianke 6.12.111 备份，备用
INIT_BOOT_A_MD5="f78cdace08393da6272c658f2e1cc66e"   # KSU 补丁所在分区
BOOT_A_SIZE=100663296                                # /dev/block/sde14 (96 MB)
INIT_BOOT_A_SIZE=8388608                             # /dev/block/sde30 (8 MB)

blockers=0
warns=0
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [停]   %s\n' "$*"; blockers=$((blockers+1)); }
warn() { printf '  [注意] %s\n' "$*"; warns=$((warns+1)); }
info() { printf '  %s\n' "$*"; }
p()    { getprop "$1" 2>/dev/null | tr -d '\r' || true; }

md5_of() {
	[ -f "$1" ] || { echo ""; return; }
	if command -v md5sum >/dev/null 2>&1; then
		md5sum "$1" 2>/dev/null | cut -d' ' -f1
	elif command -v busybox >/dev/null 2>&1; then
		busybox md5sum "$1" 2>/dev/null | cut -d' ' -f1
	elif command -v toybox >/dev/null 2>&1; then
		toybox md5sum "$1" 2>/dev/null | cut -d' ' -f1
	else
		echo ""
	fi
}
size_of() {
	if [ -f "$1" ]; then wc -c < "$1" 2>/dev/null | tr -d ' \r'; else echo ""; fi
}
# 32 位十六进制 = 一个可识别的 md5（纯 shell 判断，不依赖 grep -E 的区间语法）
is_md5() {
	[ ${#1} -eq 32 ] || return 1
	case "$1" in
		*[!0-9a-fA-F]*) return 1 ;;
	esac
	return 0
}
known_md5() {
	case "$1" in
		"$STOCK_BOOT_MD5") echo "stock-boot.img(真原厂 6.12.69，首选回滚)"; return 0 ;;
		"$BOOT_A_MD5")     echo "boot_a.img(Jianke 6.12.111 备份)"; return 0 ;;
		"$INIT_BOOT_A_MD5") echo "init_boot_a.img(KSU 补丁分区)"; return 0 ;;
		*) return 1 ;;
	esac
}

zip_list() {
	[ -f "$1" ] || return 1
	if command -v unzip >/dev/null 2>&1; then unzip -Z1 "$1" 2>/dev/null
	elif command -v busybox >/dev/null 2>&1; then busybox unzip -Z1 "$1" 2>/dev/null
	else return 1
	fi
}
zip_read() {
	if command -v unzip >/dev/null 2>&1; then unzip -p "$1" "$2" 2>/dev/null
	elif command -v busybox >/dev/null 2>&1; then busybox unzip -p "$1" "$2" 2>/dev/null
	else return 1
	fi
}

echo "=== 0. 运行环境 ==="
if ! command -v getprop >/dev/null 2>&1; then
	echo "  环境错误：这个 shell 里没有 getprop。" >&2
	echo "  getprop 属于 Android 的 /system/bin。找不到它说明你不在 Android 侧 shell 里" >&2
	echo "  （最常见的是 Operit 自带的 proot Ubuntu 终端）。在那里跑不会报错，只会得到一份" >&2
	echo "  全空的结果 —— 那比失败更糟。换 Operit 的 Root/Shizuku 终端再跑一遍。" >&2
	exit 3
fi
[ -r /proc/bootconfig ] && ok "可以读 /proc/bootconfig" || warn "读不到 /proc/bootconfig"

echo
echo "=== 1. 启动参数真值（/proc/bootconfig，不是 getprop） ==="
bcprop() {
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"[:space:]]*\).*/\1/p" /proc/bootconfig 2>/dev/null | head -n1
}
BC_SKU="$(bcprop androidboot.hardware.sku)"
BC_DEV_STATE="$(bcprop androidboot.vbmeta.device_state)"
BC_VBSTATE="$(bcprop androidboot.verifiedbootstate)"
BC_SLOT="$(bcprop androidboot.slot_suffix)"

info "hardware.sku              = ${BC_SKU:-<空>}"
info "vbmeta.device_state       = ${BC_DEV_STATE:-<空>}"
info "verifiedbootstate         = ${BC_VBSTATE:-<空>}"
info "slot_suffix               = ${BC_SLOT:-<空>}"

case "$BC_SKU" in
	*pudding*|*canoe*) ok "hardware.sku 是 pudding/canoe，机型对得上" ;;
	"") warn "bootconfig 里没有 hardware.sku —— 无法从启动参数确认机型" ;;
	*) bad "hardware.sku = '$BC_SKU' 既不是 pudding 也不是 canoe —— 这和本 skill 覆盖的设备不是同一台。停下来。" ;;
esac

BC_LOCKED=""
case "$BC_DEV_STATE" in
	unlocked) BC_LOCKED="0" ;;
	locked)   BC_LOCKED="1" ;;
esac

# getprop 在这台机器上被隐藏模块伪造（YH_YC / tricky_store / playintegrityfix）。
# 拿它判断 BL 状态会把结论判反 —— 所以这里读它，但只用来**展示矛盾**，绝不用来下结论。
GP_LOCKED="$(p ro.boot.flash.locked)"
GP_VBSTATE="$(p ro.boot.verifiedbootstate)"
if [ -n "$GP_LOCKED" ]; then
	case "$BC_DEV_STATE" in
		unlocked)
			[ "$GP_LOCKED" = "1" ] && warn "getprop ro.boot.flash.locked=$GP_LOCKED（=已锁定）与 /proc/bootconfig 的 unlocked 矛盾 —— getprop 被伪造，已作废。禁止用它判断 BL 状态。" ;;
		locked)
			[ "$GP_LOCKED" = "0" ] && warn "getprop ro.boot.flash.locked=$GP_LOCKED（=已解锁）与 /proc/bootconfig 的 locked 矛盾 —— 以 bootconfig 为准。" ;;
	esac
fi
case "$BC_VBSTATE" in
	orange) [ "$GP_VBSTATE" = "green" ] && warn "getprop ro.boot.verifiedbootstate=green 是伪造值，真值是 /proc/bootconfig 的 orange。" ;;
esac

if [ -z "$BC_LOCKED" ]; then
	bad "读不到 /proc/bootconfig 的 androidboot.vbmeta.device_state —— 无法证明 BL 已解锁。不许用 getprop 代替（它在这台机器上是假的）。"
elif [ "$BC_LOCKED" = "1" ]; then
	bad "bootconfig 说 BL 仍然 locked。刷自编译内核 = 硬砖。先解锁，不要刷。"
else
	ok "BL 已解锁（来源：/proc/bootconfig，vbmeta.device_state=unlocked）"
fi

if [ -f "$OUT_DIR/build.env" ]; then
	# shellcheck disable=SC1090
	SRC_FL="$(sed -n 's/^FLASH_LOCKED_SOURCE=//p' "$OUT_DIR/build.env" | head -n1)"
	case "$SRC_FL" in
		*getprop*) warn "build.env 的 FLASH_LOCKED 取自 getprop（$SRC_FL）—— 那是伪造值，本脚本改用 /proc/bootconfig 重新判定。" ;;
	esac
fi

echo
echo "=== 2. 当前基线（刷完必须跟它比） ==="
KREL="$(uname -r 2>/dev/null || true)"
BOOT_INDEX="$(grep -o 'boot_index=[0-9]*' /proc/cmdline 2>/dev/null | head -n1)"
DEV="$(p ro.product.device)"; MODEL="$(p ro.product.model)"
SLOT="$(p ro.boot.slot_suffix)"; [ -n "$SLOT" ] || SLOT="$BC_SLOT"
info "代号 ro.product.device = ${DEV:-<空>}"
info "型号 ro.product.model  = ${MODEL:-<空>}"
info "当前内核 uname -r      = ${KREL:-<空>}"
info "当前 ${BOOT_INDEX:-boot_index=<读不到>}"
info "槽位                   = ${SLOT:-<空>}"
[ -n "$KREL" ] || bad "uname -r 读不到 —— 没有基线，刷完无法判断到底变了没有"
[ -n "$BOOT_INDEX" ] && ok "已记录基线，刷完后 grep -o 'boot_index=[0-9]*' /proc/cmdline 应当是**新的一轮**" \
                     || warn "/proc/cmdline 里没有 boot_index —— 刷后少了一个判断依据"

echo
echo "=== 3. 分区与槽位（闸门 C：只允许 boot_a） ==="
for n in boot init_boot vendor_boot dtbo; do
	PATHN="$(ls /dev/block/by-name/${n}${SLOT} 2>/dev/null || ls /dev/block/by-name/${n} 2>/dev/null || true)"
	if [ -n "$PATHN" ]; then
		LINK="$(readlink -f "$PATHN" 2>/dev/null || true)"
		SZ="$(blockdev --getsize64 "$PATHN" 2>/dev/null || echo '?')"
		info "$n -> $PATHN ${LINK:+($LINK} ${SZ} bytes${LINK:+)}"
	else
		info "$n -> 未找到"
	fi
done
BOOT_A="/dev/block/by-name/boot_a"
if [ -e "$BOOT_A" ]; then
	SZ="$(blockdev --getsize64 "$BOOT_A" 2>/dev/null || echo '?')"
	if [ "$SZ" = "$BOOT_A_SIZE" ]; then
		ok "boot_a 尺寸 $SZ B，与实测一致"
	else
		warn "boot_a 尺寸 $SZ B，与实测记录 $BOOT_A_SIZE B 不一致 —— 设备状态可能变了，写之前再确认一次"
	fi
else
	bad "/dev/block/by-name/boot_a 不存在 —— 不知道要往哪写"
fi

echo
echo "=== 4. 闸门 A：回滚镜像在不在 PC 上 ==="
if [ -n "$PC_ROLLBACK" ]; then
	if [ ! -d "$PC_ROLLBACK" ]; then
		bad "--pc-rollback 指向的目录读不到：$PC_ROLLBACK"
	else
		HIT=""
		for f in "$PC_ROLLBACK"/*.img "$PC_ROLLBACK"/*.img.*; do
			[ -f "$f" ] || continue
			M="$(md5_of "$f")"
			[ -n "$M" ] || { warn "算不出 $(basename "$f") 的 md5（没有 md5sum？）"; continue; }
			info "$(basename "$f")  md5=$M"
			[ "$M" = "$STOCK_BOOT_MD5" ] && HIT="$f"
		done
		if [ -n "$HIT" ]; then
			ok "回滚镜像已在 PC 上并逐个校验通过：$HIT"
		else
			bad "这个目录里没有一个文件的 md5 等于 $STOCK_BOOT_MD5（真原厂 6.12.69）—— 回滚路径不存在，不许开刷"
		fi
	fi
elif [ -n "$PC_MANIFEST" ]; then
	if [ ! -f "$PC_MANIFEST" ]; then
		bad "--pc-manifest 指向的文件读不到：$PC_MANIFEST"
	else
		warn "用的是自述清单（$PC_MANIFEST），不是直接算出来的 md5 —— 清单证明「PC 上当时有这些文件」，不证明它们现在还在。能重跑就改用 --pc-rollback。"
		HAS_STOCK=0
		while read -r M N || [ -n "${M:-}" ]; do
			[ -n "${M:-}" ] || continue
			is_md5 "$M" || continue
			if L="$(known_md5 "$M")"; then
				info "$M  -> $L  ($N)"
				[ "$M" = "$STOCK_BOOT_MD5" ] && HAS_STOCK=1
			else
				bad "清单里有来路不明的镜像：$M  $N —— 不在实测已知的三个 md5 里，不要拿它当回滚镜像"
			fi
		done < "$PC_MANIFEST"
		[ "$HAS_STOCK" = "1" ] && ok "清单里有真原厂 stock-boot.img（首选回滚镜像）" \
		                        || bad "清单里没有 md5=$STOCK_BOOT_MD5 的 stock-boot.img —— 回滚路径不存在，不许开刷"
	fi
else
	bad "没有任何证据表明回滚镜像在 PC 上。fastboot 阶段读不到手机内部存储，手机里的备份等于没有。"
	info "两种给证据的方式（至少一种）："
	info "  --pc-rollback <PC 上放镜像的目录>       # 脚本亲自算 md5（强）"
	info "  --pc-manifest <rollback-manifest.txt>   # PC 侧 md5sum 清单（自述）"
	info "PC 侧生成清单：md5sum stock-boot.img boot_a.img init_boot_a.img > rollback-manifest.txt"
fi

echo
echo "=== 5. 闸门 B：ROOT_PARTITION 备份 ==="
ROOT_PART="$ROOT_PART_OVERRIDE"
if [ -z "$ROOT_PART" ] && [ -f "$OUT_DIR/build.env" ]; then
	ROOT_PART="$(sed -n 's/^ROOT_PARTITION=//p' "$OUT_DIR/build.env" | head -n1 | sed 's/(推断.*//')"
	[ -n "$ROOT_PART" ] || ROOT_PART=""
fi
if [ -z "$ROOT_PART" ]; then
	if [ -e /dev/block/by-name/init_boot_a ] || [ -e /dev/block/by-name/init_boot ]; then
		ROOT_PART="init_boot"
		warn "没有 --root-partition，也没有 build.env —— 按 GKI 布局推断 root 补丁在 init_boot，以 KernelSU/Magisk 管理器的「安装/修补」页面为准"
	else
		ROOT_PART="boot"
	fi
fi
info "ROOT_PARTITION = $ROOT_PART"

case "$ROOT_PART" in
	init_boot) ROOT_EXPECT="$INIT_BOOT_A_MD5"; ROOT_NOTE="KSU 补丁所在分区" ;;
	boot)      ROOT_EXPECT="$STOCK_BOOT_MD5 $BOOT_A_MD5"; ROOT_NOTE="内核所在分区（原厂 或 上一个第三方内核）" ;;
	none)      ROOT_EXPECT=""; ROOT_NOTE="据称没有 root" ;;
	*)         ROOT_EXPECT=""; ROOT_NOTE="未知分区（$ROOT_PART）" ;;
esac

if [ "$ROOT_PART" = "none" ]; then
	warn "ROOT_PARTITION=none —— 确认「确实没有 root」而不是「没认出来」。两者不是一回事。"
elif [ -d "$BACKUP" ]; then
	info "备份目录: $BACKUP"
	FOUND=0; ROOT_HIT=""; STOCK_ON_DEVICE=""
	for f in "$BACKUP"/*.img; do
		[ -f "$f" ] || continue
		FOUND=$((FOUND+1))
		M="$(md5_of "$f")"
		printf '    %-44s %10s B  md5=%s\n' "$(basename "$f")" "$(size_of "$f")" "${M:-?}"
		case " $ROOT_EXPECT " in *" $M "*) ROOT_HIT="$f" ;; esac
		[ "$M" = "$STOCK_BOOT_MD5" ] && STOCK_ON_DEVICE="$f"
	done
	[ "$FOUND" -gt 0 ] && ok "备份目录里有 $FOUND 个镜像" || bad "备份目录是空的：刷坏了无法就地恢复"
	if [ -n "$ROOT_EXPECT" ]; then
		if [ -n "$ROOT_HIT" ]; then
			ok "ROOT_PARTITION($ROOT_PART，$ROOT_NOTE) 已备份：$ROOT_HIT"
		else
			bad "备份目录里没有 md5 匹配 $ROOT_PART 实测值的镜像（期望：$ROOT_EXPECT）—— 备份错分区等于没备份"
		fi
	fi
	[ -n "$STOCK_ON_DEVICE" ] && warn "手机上也存着一份真原厂镜像（$STOCK_ON_DEVICE）—— 只留在这里不算备份，PC 上必须另有一份" \
	                          || warn "手机备份目录里没有真原厂镜像。那它只能带你回到上一个能开机的第三方内核，回不到出厂 —— 要原厂退路得从与当前 ROM/ARB 一致的官方包里取 boot.img"
else
	bad "备份目录不存在：$BACKUP —— 先跑 xiaomi17-device-recon 的 collect-device-facts.sh --backup"
fi

echo
echo "=== 6. 闸门 C/D：待刷产物 ==="
TARGET=""
[ -n "$ZIP" ]   && TARGET="$ZIP"
[ -n "$IMAGE" ] && TARGET="$IMAGE"
if [ -z "$TARGET" ]; then
	warn "没有用 --zip 或 --image 指定要刷的产物 —— 闸门 C/D 无法检查"
elif [ ! -f "$TARGET" ]; then
	bad "找不到要刷的产物：$TARGET"
else
	TSZ="$(size_of "$TARGET")"
	info "$TARGET  ($TSZ bytes)"
	case "$TARGET" in
		*.zip)
			LIST="$(zip_list "$TARGET" || true)"
			if [ -z "$LIST" ]; then
				warn "读不出 zip 目录（没有 unzip？）—— 无法确认它不是整包固件，也无法读 anykernel.sh"
			else
				case "$LIST" in
					*flash_all*|*rawprogram*|*xbl*.elf*|*abl*.elf*|*super.img*|*"crclist"*)
						bad "这个包里有 flash_all / rawprogram / xbl|abl / super.img —— 这是**整包固件**，刷它会触发 ARB 且不可逆。绝对不刷。" ;;
				esac
				AK="$(zip_read "$TARGET" anykernel.sh || true)"
				if [ -n "$AK" ]; then
					BLOCK="$(printf '%s\n' "$AK" | sed -n 's/^[[:space:]]*BLOCK[[:space:]]*=[[:space:]]*//p' | head -n1 | tr -d '\r"'"'"'')"
					info "anykernel.sh: BLOCK=${BLOCK:-<未设>}"
					case "$BLOCK" in
						init_boot*) bad "BLOCK=$BLOCK —— 会覆盖 ramdisk，抹掉 KernelSU 补丁。本方案只刷 boot。" ;;
						boot*|auto|"") ok "BLOCK 指向 boot（或 auto 自动探测）" ;;
						*) warn "BLOCK=$BLOCK 不是 boot/init_boot/auto —— 确认这是内核所在分区" ;;
					esac
					SEL="$(printf '%s\n' "$AK" | sed -n 's/^[[:space:]]*SLOT_SELECT[[:space:]]*=[[:space:]]*//p' | head -n1 | tr -d '\r"'"'"'')"
					case "$SEL" in
						both) bad "SLOT_SELECT=both —— 双写两个槽，「另一槽还能开机」这张免费保险就没了" ;;
						*)    [ -n "$SEL" ] && ok "SLOT_SELECT=$SEL" ;;
					esac
					if printf '%s\n' "$AK" | grep -q 'do\.devicecheck[[:space:]]*=[[:space:]]*1'; then
						if printf '%s\n' "$AK" | grep -qE 'DEVICE CHECK FAILED|hardware[.]sku'; then
							ok "有自建的 devicecheck（读 /proc/bootconfig 的 hardware.sku）"
						else
							warn "设了 do.devicecheck=1 —— **这是假防呆**：这个 AK3 fork 的 tools/ak3-core.sh 根本没实现 devicecheck（grep -c devicecheck = 0）。要么在 anykernel.sh 里自建 hardware.sku 校验，要么别指望它。"
						fi
					fi
				else
					warn "包里没有 anykernel.sh —— 可能不是 AK3 zip，确认它到底是什么再刷"
				fi
			fi
			;;
		*.img)
			if [ -n "$(zip_list "$TARGET" || true)" ]; then
				warn "文件后缀是 .img，内容却是个 zip —— 别刷错东西"
			fi
			case "${TSZ:-}" in
				''|*[!0-9]*) warn "算不出镜像大小 —— 自己确认它放得进 boot_a（$BOOT_A_SIZE B）" ;;
				*) if [ "$TSZ" -gt "$BOOT_A_SIZE" ]; then
						bad "镜像 $TSZ B 比 boot_a($BOOT_A_SIZE B) 还大，写进去必然失败"
					else
						ok "镜像尺寸放得下 boot_a"
					fi ;;
			esac
			;;
		*) warn "既不是 .zip 也不是 .img —— 确认这是什么再刷" ;;
	esac
fi

echo
echo "=== 7. 电量 ==="
LVL="$(dumpsys battery 2>/dev/null | awk -F': *' '/^  level:/{print $2; exit}' | tr -d '\r')"
case "${LVL:-}" in
	''|*[!0-9]*) warn "读不到电量（多半是 dumpsys 权限），请自己确认 ≥60%" ;;
	*) if [ "$LVL" -ge 60 ]; then ok "电量 ${LVL}%"; else bad "电量 ${LVL}% < 60% —— 刷到一半没电是最常见的非人为变砖原因"; fi ;;
esac

echo
echo "=== 8. 闸门 D：ARB 与「绝不 flash_all」 ==="
cat <<'TXT'
  本机 ARB 指数 = UNKNOWN。机内 ro.boot.anti 为空 ≠ 没有 ARB。要确定必须在 fastboot 里查：
      fastboot getvar anti
  侧面证据（blackbox 实测）：the stored_rollback_index is: 1，在 boot_index 361/362/364
  多轮一致、未见变化 —— 但刷 boot 本身不涉及 ARB 计数，所以这不等于「ARB 安全」。

  ARB 保护的是 bootloader 与固件链（xbl/abl/tz/hyp/devcfg），不是内核。
  单刷 boot / init_boot / vendor_boot / dtbo / vbmeta 不涉及 ARB 计数。

  绝对不要做：
      fastboot flash_all                       ✗ 触发 ARB，不可逆
      跑官方包里的 flash_all.sh / flash_all.bat ✗ 同上
      刷任何比当前版本旧的官方整包              ✗ 同上
      用「降级到旧官方包」当回滚手段            ✗ 同上（回滚用机外备份的 boot_a 镜像）

  回滚只在 PC 上手动做（fastboot 阶段手机侧助手不可用，也读不到手机内部存储）：
      长按 音量下 + 电源（一次） → fastboot devices
      fastboot flash boot_a stock-boot.img     # 只刷 boot_a
      fastboot reboot
  本方案没有 panic 自动重启配置，卡住不会自己重启，必须手动复位。
TXT

echo
echo "=== 刷后必须上机验证（跑不出结果就不许说成功） ==="
cat <<'TXT'
  uname -r                                       # 期望变成你编的那个版本
  grep -o 'boot_index=[0-9]*' /proc/cmdline      # 期望是新的一轮（跟上面基线比）
  dmesg | grep -ic 'disagrees about version\|Unknown symbol'   # 期望 0
  lsmod | wc -l                                  # 期望 ~670（口径：/proc/modules 全量）
  /data/adb/ksud -V                              # root 还在
  ls /dev/dri/ ; lsmod | grep -c msm_drm         # card0 + renderD128 ；1
  ip link | grep wlan0 ; ls /dev/video0 ; cat /proc/asound/cards
  dmesg | grep -ic 'kernel panic\|Oops'          # 期望 0
  口径提醒：660（原厂）/ 670（本仓成功版）/ 336（dmesg 带 (O)/(OE) 标记）必须同口径对比。
TXT

echo
echo "=== 结果 ==="
echo "  阻塞项 $blockers，需注意 $warns"
[ "$blockers" -eq 0 ] || { echo "  有阻塞项 —— 不要刷。"; exit 3; }
echo "  闸门全过。写入只允许一条：fastboot flash boot_a <你的 boot 镜像>；绝不 flash_all。"
exit 0
