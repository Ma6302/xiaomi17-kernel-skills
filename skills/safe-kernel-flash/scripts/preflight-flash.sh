#!/usr/bin/env bash
# preflight-flash.sh — 刷内核之前，把「能不能安全刷」这件事变成可检查的清单。
#
# 只读。不写任何分区。它做什么：
#   1. 确认机型代号与槽位
#   2. 确认电量
#   3. 确认分区是否存在、大小多少
#   4. 确认备份目录里有没有原厂镜像（这才是回滚的唯一依靠）
#   5. 校验要刷的包
#   6. 打印 ARB 与 vbmeta 的注意事项
# 任何一项不满足会以 exit 3 结束，并且明确告诉你缺什么。
#
# 用法:
#   bash scripts/preflight-flash.sh --zip /sdcard/Download/Operit/kernel-dev/out/xxx.zip
#   bash scripts/preflight-flash.sh --zip ... --backup /sdcard/Download/Operit/kernel-dev/backup

set -u

ZIP=""
BACKUP="/sdcard/Download/Operit/kernel-dev/backup"
while [ $# -gt 0 ]; do
	case "$1" in
		--zip)    ZIP="${2:?}"; shift 2 ;;
		--backup) BACKUP="${2:?}"; shift 2 ;;
		-h|--help) sed -n '2,18p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

blockers=0
warns=0
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [停]   %s\n' "$*"; blockers=$((blockers+1)); }
warn() { printf '  [注意] %s\n' "$*"; warns=$((warns+1)); }
p()    { getprop "$1" 2>/dev/null || true; }

echo "=== 1. 设备身份（这是防呆的基础，不是可选项） ==="
DEV="$(p ro.product.device)"; MODEL="$(p ro.product.model)"
SLOT="$(p ro.boot.slot_suffix)"; [ -z "$SLOT" ] && SLOT="$(p ro.boot.slot_suffix)" 
KREL="$(uname -r)"
BUILD="$(p ro.build.display.id)"; SEC="$(p ro.build.version.security_patch)"
echo "  代号(ro.product.device) = ${DEV:-未知}"
echo "  型号(ro.product.model)  = ${MODEL:-未知}"
echo "  系统构建               = ${BUILD:-未知}（安全补丁 ${SEC:-未知}）"
echo "  当前内核(uname -r)     = $KREL"
echo "  槽位(ro.boot.slot_suffix) = ${SLOT:-<无槽位>}"
[ -n "$DEV" ] || bad "读不到 ro.product.device —— 后面所有基于代号的一致性检查都无法进行"
[ -n "$SLOT" ] && ok "A/B 设备，当前槽 $SLOT" || warn "没有 slot_suffix：可能是非 A/B 设备，或者是读取受限"

echo
echo "=== 2. 电量 ==="
LVL="$(dumpsys battery 2>/dev/null | awk -F': *' '/^  level:/{print $2; exit}')"
echo "  level = ${LVL:-未知}%"
if [ -n "${LVL:-}" ]; then
	[ "$LVL" -ge 60 ] && ok "电量足够" || bad "电量 ${LVL}% < 60%。刷到一半没电是变砖最常见的非人为原因。"
else
	warn "读不到电量（多半是 dumpsys 权限问题），请自己确认 ≥60%"
fi

echo
echo "=== 3. 分区 ==="
for n in boot init_boot vendor_boot dtbo vbmeta; do
	PATHN=$(ls /dev/block/by-name/${n}${SLOT} 2>/dev/null || ls /dev/block/by-name/${n} 2>/dev/null || true)
	if [ -n "$PATHN" ]; then
		SZ=$(blockdev --getsize64 "$PATHN" 2>/dev/null || echo '?')
		echo "  $n -> $PATHN (${SZ} bytes)"
	else
		echo "  $n -> 未找到"
	fi
done
echo "  说明：内核在 boot 还是 init_boot 必须以真机为准。GKI 设备内核通常在 boot，"
echo "        init_boot 里是通用 ramdisk —— 往 init_boot 写内核会破坏 ramdisk。"

echo
echo "=== 4. 回滚备份（没有这个就别刷） ==="
echo "  备份目录: $BACKUP"
if [ -d "$BACKUP" ]; then
	FOUND=0
	for f in "$BACKUP"/*.img; do
		[ -f "$f" ] || continue
		FOUND=$((FOUND+1))
		printf '    %-40s %s\n' "$(basename "$f")" "$(wc -c < "$f" 2>/dev/null) bytes"
	done
	[ "$FOUND" -gt 0 ] && ok "找到 $FOUND 个镜像" || bad "备份目录是空的：刷坏了无法就地恢复"
	# 校验和要与镜像同时存在才算可用
	if [ -f "$BACKUP/SHA256SUMS" ]; then
		ok "有 SHA256SUMS，可验证备份完整性"
		( cd "$BACKUP" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
			&& ok "备份校验和全部通过" || bad "备份文件与 SHA256SUMS 不匹配 —— 备份可能已损坏"
	else
		warn "没有 SHA256SUMS：无法证明备份是好的。备份坏掉和被刷坏一样致命。"
	fi
	FREE=$(df -k "$BACKUP" 2>/dev/null | awk 'NR==2{print int($4/1024)}')
	[ -n "${FREE:-}" ] && echo "  剩余空间: ${FREE} MB"
else
	bad "备份目录不存在。先跑 xiaomi17-device-recon 的 collect-device-facts.sh --backup"
fi

echo
echo "=== 5. 要刷的包 ==="
if [ -n "$ZIP" ]; then
	if [ -f "$ZIP" ]; then
		echo "  $ZIP"
		echo "  大小: $(wc -c < "$ZIP") bytes"
		if command -v sha256sum >/dev/null 2>&1; then printf '  SHA256: %s\n' "$(sha256sum "$ZIP" | cut -d' ' -f1)"; fi
		ok "文件存在"
		echo "  下一步: bash skills/anykernel3-packaging/scripts/check-anykernel-zip.sh \"$ZIP\""
	else
		bad "找不到 $ZIP"
	fi
else
	warn "没有用 --zip 指定要刷的包，跳过包检查"
fi

echo
echo "=== 6. 两件必须想清楚的事 ==="
cat <<'TXT'
  [ARB / 防回滚] ARB 保护的是 bootloader 与固件链（xbl/abl/tz/hyp 等），
    不是内核。只刷 boot / init_boot / vendor_boot / dtbo / vbmeta 不会触发 ARB。
    真正会触发 ARB 的是刷「整包 fastboot 固件」或整包 ROM —— 它们的 ARB 版本
    比你设备的熔丝低时，设备会拒绝启动且不可逆。
    → 刷之前先查一次: fastboot getvar anti
        空   = ARB 尚未启用
        数字 = 当前 rollback index（镜像 index 更大则刷入后设备会被提升到该值）
      注意: ro.boot.veritymode 不是 ARB，那是 AVB/dm-verity 状态。
    → 所以回滚 stock 时，只从官方包里取 boot/init_boot/vbmeta 单刷，
      不要图省事跑整包的 flash_all 脚本。

  [verity / vbmeta] 重新打包 boot 会让该分区的 AVB 哈希失效。
    不要为了省事例行执行
      fastboot --disable-verity --disable-verification flash vbmeta ...
    在 HyperOS 上，刷一个来路不明的 vbmeta 本身就是主要的变砖来源。
    正确顺序是：先只刷 boot，试着开机；只有明确出现 verity/vbmeta 相关
    错误时才动 vbmeta，而且动手前必须已经 dd 备份了原始 vbmeta 分区。
TXT

echo
echo "=== 结果 ==="
echo "  阻塞项 $blockers，需注意 $warns"
[ "$blockers" -eq 0 ] || { echo "  有阻塞项 —— 不要刷。"; exit 3; }
echo "  可以进入刷写步骤。"
exit 0
