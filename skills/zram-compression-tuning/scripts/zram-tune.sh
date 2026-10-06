#!/usr/bin/env bash
# zram-tune.sh — 先探测真机上到底有哪些 zram 接口，再按探测结果写入。
#
# 为什么必须探测：zram 的 sysfs 接口在 6.6 / 6.12 / 6.16 之间改过语法。
# 6.12 上 `recomp_algorithm` 与 `recompress` 的写法与 6.16+ 不同，
# 6.16+ 才有的 algorithm_params / 秒级 idle 在 6.12 上根本不存在。
# 盲目照抄新版文档会得到 EINVAL，而且失败是静默的（配置没生效，看似成功）。
#
# 用法:
#   bash scripts/zram-tune.sh --report                 # 只读，报告现状与可用接口
#   bash scripts/zram-tune.sh --apply balanced         # 应用 balanced 档
#   bash scripts/zram-tune.sh --apply aggressive       # 应用 aggressive 档
#   bash scripts/zram-tune.sh --persist balanced       # 生成开机自启脚本
#
# 需要 root。退出码: 0 成功；3 = 环境不支持；4 = 部分项被跳过

set -u

ZRAM=/sys/block/zram0
MODE=""
PROFILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--report)  MODE="report"; shift ;;
		--apply)   MODE="apply"; PROFILE="${2:?}"; shift 2 ;;
		--persist) MODE="persist"; PROFILE="${2:?}"; shift 2 ;;
		-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

[ -n "$MODE" ] || { echo "要么 --report 要么 --apply <profile> 要么 --persist <profile>" >&2; exit 2; }
[ -d "$ZRAM" ] || { echo "没有 $ZRAM —— 这台设备/这个内核没有启用 zram" >&2; exit 3; }

is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }
need_root() { is_root || { echo "需要 root（这些 sysfs 节点只对 root 可写）" >&2; exit 3; }; }

have() { [ -e "$ZRAM/$1" ]; }
show() { [ -e "$ZRAM/$1" ] && printf '  %-22s %s\n' "$1" "$(cat "$ZRAM/$1" 2>/dev/null | tr '\n' ' ' | cut -c1-160)"; }

report() {
	echo "=== zram0 现状 ==="
	[ -d "$ZRAM" ] || { echo "  不存在"; return; }
	for f in comp_algorithm recomp_algorithm recompress idle mem_limit disksize initstate; do show "$f"; done
	echo
	echo "=== mm_stat ==="
	[ -e "$ZRAM/mm_stat" ] && cat "$ZRAM/mm_stat" | sed 's/^/  /'
	echo "  (字段顺序: orig_data_size compr_data_size mem_used_total mem_limit mem_used_max same_pages pages_compacted huge_pages huge_pages_since)"
	echo
	echo "=== io_stat ==="
	[ -e "$ZRAM/io_stat" ] && cat "$ZRAM/io_stat" | sed 's/^/  /'
	echo
	echo "=== 可用接口判定 ==="
	have comp_algorithm   && echo "  [有] comp_algorithm"            || echo "  [无] comp_algorithm"
	have recomp_algorithm && echo "  [有] recomp_algorithm（多算法混合可用）" || echo "  [无] recomp_algorithm → 无 CONFIG_ZRAM_MULTI_COMP，只能单算法"
	have recompress       && echo "  [有] recompress（冷页重压可用）"       || echo "  [无] recompress"
	have idle             && echo "  [有] idle"                     || echo "  [无] idle"
	have mem_limit        && echo "  [有] mem_limit"                || echo "  [无] mem_limit"
	if have recomp_algorithm; then
		echo
		echo "  支持的备用算法与写法（从节点本身读，这是权威）:"
		cat "$ZRAM/recomp_algorithm" 2>/dev/null | sed 's/^/    /'
	fi
	echo
	echo "=== 当前 swap 使用者 ==="
	cat /proc/swaps | sed 's/^/  /'
	echo
	echo "=== 厂商是否已经在配 zram（HyperOS 通常会） ==="
	grep -l zram /vendor/etc/fstab* 2>/dev/null | sed 's/^/  fstab: /'
	grep -rho 'zram[^ ]*' /vendor/etc/fstab* 2>/dev/null | sort -u | sed 's/^/  /'
	echo
	echo "=== MGLRU ==="
	if [ -d /sys/kernel/mm/lru_gen ]; then
		echo "  enabled      = $(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)"
		echo "  min_ttl_ms   = $(cat /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null)"
	else
		echo "  没有 /sys/kernel/mm/lru_gen —— 内核没开 CONFIG_LRU_GEN"
	fi
}

write_or_skip() {
	# write_or_skip <节点> <值>
	if [ ! -e "$ZRAM/$1" ]; then
		echo "  [跳过] $1 不存在于 6.12 的这个内核上"
		return 1
	fi
	if ! printf '%s' "$2" > "$ZRAM/$1" 2>/dev/null; then
		echo "  [失败] 写入 $1='$2' 被拒（EINVAL）。用 cat $ZRAM/$1 读它自己支持的写法。"
		return 1
	fi
	echo "  [写入] $1='$2'"
	return 0
}

apply() {
	need_root
	local size="$1" recomps="$2" recomp="$3" swappiness="$4"
	echo "=== 0. 复位：必须 swapoff → reset，initstate 归 0 才能改 comp_algorithm ==="
	swapoff /dev/block/zram0 2>/dev/null && echo "  已 swapoff" || echo "  zram0 当前不是 swap（跳过 swapoff）"
	if ! printf '1' > "$ZRAM/reset" 2>/dev/null; then
		echo "  复位失败。若有进程正在用 zram，先停掉再试。" >&2
		return 3
	fi
	echo "  reset 完成，initstate=$(cat "$ZRAM/initstate" 2>/dev/null)"

	echo
	echo "=== 1. 主算法（热路径，优先 lz4：最快） ==="
	write_or_skip comp_algorithm lz4 || true

	echo
	echo "=== 2. 容量与上限 ==="
	write_or_skip disksize "$size" || true
	write_or_skip mem_limit 0 || true

	echo
	echo "=== 3. 备用算法（冷页用，压得更好但更慢） ==="
	if [ "$recomps" != "-" ]; then
		write_or_skip recomp_algorithm "$recomps" || true
	fi

	echo
	echo "=== 4. 冷页重压规则 ==="
	if [ "$recomp" != "-" ]; then
		# 先给页打上 idle 标记；idle 节点不存在就跳过（6.6 起有，但可能被厂商内核裁掉）
		write_or_skip idle 86400 || true
		IFS='|' read -r r1 r2 <<EOF
$recomp
EOF
		[ -n "${r1:-}" ] && write_or_skip recompress "$r1" || true
		[ -n "${r2:-}" ] && write_or_skip recompress "$r2" || true
	fi

	echo
	echo "=== 5. VM 与 MGLRU ==="
	if [ -d /sys/kernel/mm/lru_gen ]; then
		printf '0x0007' > /sys/kernel/mm/lru_gen/enabled 2>/dev/null && echo "  [写入] lru_gen/enabled=0x0007" || echo "  [失败] lru_gen/enabled"
		printf '1000'   > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null && echo "  [写入] lru_gen/min_ttl_ms=1000" || echo "  [失败] min_ttl_ms"
	else
		echo "  [跳过] 内核没有 CONFIG_LRU_GEN"
	fi
	sysctl -w "vm.swappiness=$swappiness" >/dev/null 2>&1 && echo "  [写入] vm.swappiness=$swappiness" || echo "  [失败] swappiness"
	sysctl -w vm.page-cluster=0 >/dev/null 2>&1 && echo "  [写入] vm.page-cluster=0" || true
	sysctl -w vm.watermark_scale_factor=150 >/dev/null 2>&1 && echo "  [写入] vm.watermark_scale_factor=150" || true

	echo
	echo "=== 6. 重新启用 swap ==="
	swapon /dev/block/zram0 2>/dev/null && echo "  已 swapon" || { mkswap /dev/block/zram0 >/dev/null 2>&1 && swapon /dev/block/zram0 && echo "  mkswap + swapon 完成"; }
	cat /proc/swaps | sed 's/^/  /'
}

case "$MODE:$PROFILE" in
	report:)             report ;;
	apply:balanced)      apply 6G  'zstd priority=1' 'type=idle priority=1 threshold=2000' 120 ;;
	apply:aggressive)    apply 8G  'zstd priority=1|zstd priority=2' 'type=idle priority=1 threshold=1500|type=huge_idle priority=1' 150 ;;
	apply:*)             echo "未知档位: $PROFILE（可选 balanced / aggressive）" >&2; exit 2 ;;
	persist:*)           need_root
	                     cat > /data/adb/service.d/99-zram-tune.sh <<EOF
#!/system/bin/sh
# 由 xiaomi17-kernel-skills / zram-compression-tuning 生成。
# 放在 /data/adb/service.d/ 由 KernelSU/Magisk 在开机后执行。
# 厂商 init 会先配好 zram，这里在其之后覆盖为我们的参数。
sleep 30
sh $(cd "$(dirname "$0")" && pwd)/zram-tune.sh --apply $PROFILE
EOF
	                     chmod 0755 /data/adb/service.d/99-zram-tune.sh
	                     echo "已写入 /data/adb/service.d/99-zram-tune.sh（$PROFILE）"
	                     echo "注意：脚本路径指向当前目录，请把 zram-tune.sh 一并放到手机上固定的路径，"
	                     echo "      并把上面那行改成绝对路径，否则开机时找不到。" ;;
esac

echo
echo "=== 验证（这是唯一算数的部分） ==="
echo "  比值: awk '{printf \"%.2f:1\\n\", \$1/\$2}' /sys/block/zram0/mm_stat"
echo "  换页: grep -E 'pswp(in|out)|pgscan_kswapd|pgmajfault|workingset_refault_anon' /proc/vmstat"
echo "  杀进程: logcat -d | grep -c lowmemorykiller"
echo "  冷启:   am start -W <pkg>   （取 P50/P95，允许 ≤5% 回退）"
