#!/usr/bin/env bash
# zram-tune.sh — 先探测节点是否存在，再决定能不能写。
#
# 为什么必须先探测（两条独立的理由，都不是"谨慎起见"）：
#   ① 语法差异：zram 的 sysfs 写法在 6.12 / 6.16+ 之间改过
#      （algorithm_params / 秒级 idle / algo= 都是 6.16+ 的），照抄会 EINVAL 且可能静默。
#   ② 存在性差异：这台机器（小米 17 / pudding / SM8850 / 6.12.69 GKI）上
#      有些节点【根本没有】。实测：/sys/block/zram0/backing_dev 不存在
#      → /sys/block/zram0/writeback 也不存在 → zram 官方 writeback 不可用。
#      另有一批节点（recomp_algorithm / recompress / algorithm_params / idle /
#      compression_level / mm_stat / io_stat / initstate / mem_limit）在实测记录里
#      是【未测】—— 未测不等于不存在，但也绝不允许当成"已经存在"来写。
#
# 权威是 /sys/block/zram0/ 的实际内容。任何文档、任何 CONFIG_*、任何配置文件都只是二手。
#
# 用法:
#   bash scripts/zram-tune.sh --report                     # 只读；不需要 root
#   bash scripts/zram-tune.sh --apply <algo|keep> [--yes]  # 切算法 + 写 VM 参数
#   bash scripts/zram-tune.sh --persist <algo|keep>        # 生成开机自启脚本
#   bash scripts/zram-tune.sh --apply lz4 --io-scheduler mq-deadline
#
#   <algo>: keep（只调 VM，不动 zram）| lzo | lzo-rle | lz4 | zstd
#           候选集以 /sys/block/zram0/comp_algorithm 的实际内容为准。
#   keep = 保持现状；本脚本【从不】改容量（没有实测依据），只原样恢复 disksize。
#
# 选项:
#   --yes                 非交互确认。切换算法是破坏性操作（会丢弃 zram 里的压缩页）
#   --swappiness <N>      覆盖 vm.swappiness（默认 100 = 原厂实测值）
#   --io-scheduler <名>   仅当该名字已出现在 queue/scheduler 的候选列表里才写
#
# 退出码: 0 成功；2 参数错；3 环境不支持 / 探测未通过；5 用户取消

set -u   # 注意：绝不要 set -e —— 个别项写入失败不应该中断整体流程

ZRAM=/sys/block/zram0
PERSIST_DIR=/data/adb/service.d
PERSIST_FILE="$PERSIST_DIR/99-zram-tune.sh"
PERSIST_LOG=/data/local/tmp/99-zram-tune.log

# 实测候选集（2026-10-09：comp_algorithm = "lzo [lzo-rle] lz4 zstd"）。
# 这里只用于参数校验；真正是否支持仍以节点内容为准（algo_supported）。
ALGOS="lzo lzo-rle lz4 zstd"

MODE=""
TARGET=""
ASSUME_YES=0
SWAPPINESS=100
WANT_SCHED=""

usage() {
	cat <<'EOF'
zram-tune.sh — 先探测节点是否存在，再决定能不能写。

用法:
  bash scripts/zram-tune.sh --report                     # 只读：逐节点探测 + 现状（不需要 root）
  bash scripts/zram-tune.sh --apply <algo|keep> [--yes]  # 切算法 + 写 VM 参数
  bash scripts/zram-tune.sh --persist <algo|keep>        # 生成开机自启脚本

  <algo>: keep（只调 VM，不动 zram）| lzo | lzo-rle | lz4 | zstd
          候选集以 /sys/block/zram0/comp_algorithm 的实际内容为准。

选项:
  --yes                 非交互确认（切换算法是破坏性操作，会丢弃 zram 里的压缩页）
  --swappiness <N>      覆盖 vm.swappiness（默认 100 = 原厂实测值）
  --io-scheduler <名>   仅当该名字已出现在 queue/scheduler 的候选列表里才写

退出码: 0 成功；2 参数错；3 环境不支持/探测未通过；5 用户取消
EOF
}

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
	case "$1" in
		--report)  MODE="report"; shift ;;
		--apply)
			[ $# -ge 2 ] || { echo "--apply 需要 <algo|keep>" >&2; exit 2; }
			MODE="apply"; TARGET="$2"; shift 2 ;;
		--persist)
			[ $# -ge 2 ] || { echo "--persist 需要 <algo|keep>" >&2; exit 2; }
			MODE="persist"; TARGET="$2"; shift 2 ;;
		--yes|-y)  ASSUME_YES=1; shift ;;
		--swappiness)
			[ $# -ge 2 ] || { echo "--swappiness 需要 <N>" >&2; exit 2; }
			SWAPPINESS="$2"; shift 2 ;;
		--io-scheduler)
			[ $# -ge 2 ] || { echo "--io-scheduler 需要 <名>" >&2; exit 2; }
			WANT_SCHED="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[ -n "$MODE" ] || { usage >&2; exit 2; }

case "$MODE" in
	apply|persist)
		case " keep $ALGOS " in
			*" $TARGET "*) : ;;
			*) echo "未知目标: '$TARGET'（可选: keep $ALGOS）" >&2; exit 2 ;;
		esac ;;
esac

# ---------------------------------------------------------------- 基础工具
is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }
need_root() { is_root || { echo "需要 root（这些 sysfs 节点只对 root 可写）" >&2; exit 3; }; }

have()     { [ -e "$ZRAM/$1" ]; }
node_val() { cat "$ZRAM/$1" 2>/dev/null; }

# 当前算法：只能从方括号里解析。不要相信配置文件的"默认值"——
# 实测 config.conf 写 ZRAM_ALGO=lz4，同一轮开机日志却是 "already lzo-rle"。
cur_algo() { sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ZRAM/comp_algorithm" 2>/dev/null; }

algo_supported() { grep -qw -- "$1" "$ZRAM/comp_algorithm" 2>/dev/null; }

# probe <路径> <说明>
probe_path() {
	p="$1"; note="${2:-}"
	if [ ! -e "$p" ]; then
		printf '  [不存在] %-46s %s\n' "$p" "$note"
		return 1
	fi
	v="$(cat "$p" 2>/dev/null | tr '\n' ' ' | cut -c1-110)"
	[ -n "$v" ] || v='(只写节点 / 读不到内容)'
	printf '  [存在]   %-46s %s\n' "$p" "$v"
	return 0
}

# 已知 zram 节点的逐个探测。格式：节点|说明
ZRAM_NODES='
comp_algorithm|支持列表，[] 内 = 当前算法（唯一权威）
reset|只写；写 1 复位 zram，会清除设备上的 swap 签名
disksize|容量（字节）；reset 后必须重设，否则容量为 0
initstate|0 = 已复位，此时 comp_algorithm 才可写
zgroup_enable|小米 zgroup 开关，实测 =1
mem_limit|未测节点（仓库无实测输出）
mm_stat|未测节点；压缩比字段顺序以 cat 输出为准
io_stat|未测节点
recomp_algorithm|未测节点（未测 ≠ 不存在）
recompress|未测节点
algorithm_params|未测节点；6.16+ 语法，6.12 上大概率没有
idle|未测节点
compression_level|未测节点；也可能出现在 /sys/module/zstd/parameters/
backing_dev|★ 实测不存在 → zram 官方 writeback 不可用
writeback|★ 实测不存在（承 backing_dev）
'

# ---------------------------------------------------------------- 报告（只读）
report() {
	echo "================= zram 探测报告（只读，不修改任何东西） ================="
	echo "  uname -r : $(uname -r 2>/dev/null)"
	echo "  uid      : $(id -u 2>/dev/null)"
	echo "  日期     : $(date 2>/dev/null)"

	if [ ! -d "$ZRAM" ]; then
		echo
		echo "  没有 $ZRAM —— 这台设备/这个内核没有 zram0。本 skill 的 zram 部分不适用。"
		return 3
	fi

	echo
	echo "=== 1. 权威清单：ls -1 $ZRAM/ ==="
	echo "  （这台机器上有什么，就以这个为准；下面的清单只是对照）"
	ls -1 "$ZRAM/" 2>/dev/null | sed 's/^/    /'

	echo
	echo "=== 2. 已知节点逐个探测（存在性 + 当前值） ==="
	printf '%s\n' "$ZRAM_NODES" | while IFS='|' read -r n note; do
		[ -n "$n" ] || continue
		probe_path "$ZRAM/$n" "$note"
	done

	echo
	echo "=== 3. 算法 ==="
	if have comp_algorithm; then
		echo "  候选 + 当前 : $(node_val comp_algorithm | tr '\n' ' ')"
		echo "  当前算法    : $(cur_algo)   （从方括号解析，唯一权威）"
	else
		echo "  [不存在] comp_algorithm —— 这台机器无法在运行时切换算法。"
	fi

	echo
	echo "=== 4. swap 现状 ==="
	sed 's/^/    /' /proc/swaps 2>/dev/null
	echo "    zram0 优先级: $(awk '$1 ~ /zram0/ {print $5}' /proc/swaps 2>/dev/null | head -1)"
	echo "    （ROM 默认优先级是 -2；toybox 的 swapon 不接受负数 -p，所以一律不带 -p）"

	echo
	echo "=== 5. zram 统计（节点存在才有） ==="
	if have mm_stat; then
		echo "    mm_stat : $(node_val mm_stat | tr '\n' ' ')"
		awk 'NF>=2 && $2+0>0 {printf "    压缩比(orig/compr) = %.2f:1\n", $1/$2}' "$ZRAM/mm_stat" 2>/dev/null
		echo "    注：字段顺序以 cat 输出为准，不要照抄别处的顺序。"
	else
		echo "    [不存在] mm_stat —— 没有实测记录，不要引用它的字段。"
	fi
	if have io_stat; then
		echo "    io_stat : $(node_val io_stat | tr '\n' ' ')"
	else
		echo "    [不存在] io_stat"
	fi

	echo
	echo "=== 6. 小米内存回写层（xswapd / mctrl / zgroup） ==="
	echo "  官方 writeback 不成立时，这台机器上的「内存回写」只有这一条路："
	probe_path /dev/memcg/memory.xswapd.enable    "原厂默认 0（关）；控制【主动】回写循环"
	probe_path /dev/memcg/memory.xswapd.quota     "实测 7511834624"
	probe_path /dev/memcg/memory.xswapd.stat      "nr_ext/nr_wb/sz_wb/drop_wb/fault_wb/wake_up"
	probe_path /dev/memcg/memory.mctrl.stat       "wb_pages"
	probe_path /dev/memcg/memory.mctrl.comp_ratio ">=101 才触发自动回写（硬编码 0x65）"
	probe_path /dev/memcg/memory.mctrl.wb_ratio   ">100 会被 -EINVAL 拒绝"
	probe_path "$ZRAM/zgroup_enable"              "实测 =1，回写前提"

	echo
	echo "=== 7. VM 参数现状（本脚本只写 5 项） ==="
	for k in vm.swappiness vm.vfs_cache_pressure vm.compaction_proactiveness \
	         vm.watermark_boost_factor vm.extfrag_threshold; do
		p="/proc/sys/$(printf '%s' "$k" | tr '.' '/')"
		if [ -e "$p" ]; then echo "    $k = $(cat "$p" 2>/dev/null)"; else echo "    $k : [不存在]"; fi
	done
	echo "    本脚本【不写】的：vm.page-cluster / vm.watermark_scale_factor / lru_gen（无实测依据）"
	echo "    read_ahead_kb（保持 ROM 默认 512；抄别人的 128 实测降低顺序读性能）："
	for d in /sys/block/sd* /sys/block/mmcblk*; do
		[ -e "$d/queue/read_ahead_kb" ] || continue
		echo "      $d/queue/read_ahead_kb = $(cat "$d/queue/read_ahead_kb" 2>/dev/null)"
	done
	echo "    I/O 调度器候选（写之前必须先看这里）："
	for s in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler; do
		[ -f "$s" ] || continue
		echo "      $s = $(cat "$s" 2>/dev/null | tr '\n' ' ')"
	done

	echo
	echo "=== 8. MGLRU（本脚本只报告，不写） ==="
	if [ -d /sys/kernel/mm/lru_gen ]; then
		echo "    enabled    = $(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)"
		echo "    min_ttl_ms = $(cat /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null)"
	else
		echo "    没有 /sys/kernel/mm/lru_gen（内核没开 CONFIG_LRU_GEN）"
	fi

	echo
	echo "=== 9. 换页压力 ==="
	grep -E 'pswp(in|out)|pgscan_kswapd|pgmajfault|workingset_refault_anon' /proc/vmstat 2>/dev/null | sed 's/^/    /'

	echo
	echo "=== 10. vendor 模块身份（证明 zram 不在内核里） ==="
	if [ -f /vendor_dlkm/lib/modules/zram.ko ]; then
		echo "    /vendor_dlkm/lib/modules/zram.ko = $(ls -l /vendor_dlkm/lib/modules/zram.ko 2>/dev/null | awk '{print $5}') 字节"
		if command -v modinfo >/dev/null 2>&1; then
			modinfo /vendor_dlkm/lib/modules/zram.ko 2>/dev/null | grep -E '^(name|depends|built_with|parm):' | sed 's/^/    /'
		else
			echo "    （没有 modinfo；实测记录：depends=zsmalloc built_with=DDK parm:num_devices parm:qpace_pool_size）"
		fi
	else
		echo "    没有 /vendor_dlkm/lib/modules/zram.ko"
	fi

	echo
	echo "=== 判定 ==="
	echo "  · backing_dev / writeback 实测不存在 → zram 官方 writeback 在这台机器上【不可用】。"
	echo "  · recomp_algorithm / recompress / algorithm_params / idle / compression_level 是【未测】节点："
	echo "      存在才写；不存在就是「这台机器没有，本 skill 那一节不适用」，不要换语法硬试。"
	echo "  · CONFIG_ZRAM_MULTI_COMP=y 只是 config 的说法 —— 改接口是否暴露【未验证】。"
	echo "      config 和 sysfs 打架时，以 sysfs 为准（反例：CONFIG_ZRAM_WRITEBACK=y 而 backing_dev 不存在）。"
	return 0
}

# ---------------------------------------------------------------- 写入
write_sysctl() {
	# write_sysctl <vm.xxx> <值>
	key="$1"; val="$2"
	path="/proc/sys/$(printf '%s' "$key" | tr '.' '/')"
	if [ ! -e "$path" ]; then
		echo "  [跳过] $key —— $path 不存在"
		return 1
	fi
	before="$(cat "$path" 2>/dev/null)"
	if printf '%s' "$val" > "$path" 2>/dev/null; then
		echo "  [写入] $key = $val   (原值 $before)"
		return 0
	fi
	echo "  [失败] $key = $val 被拒   (原值 $before)"
	return 1
}

write_scheduler() {
	want="$1"
	echo
	echo "=== I/O 调度器（仅当名字已出现在候选列表里才写） ==="
	found=0
	for s in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler /sys/block/dm-*/queue/scheduler; do
		[ -f "$s" ] || continue
		found=1
		if grep -qw -- "$want" "$s" 2>/dev/null; then
			if printf '%s' "$want" > "$s" 2>/dev/null; then
				echo "  [写入] $s = $want"
			else
				echo "  [失败] $s 写入被拒"
			fi
		else
			echo "  [跳过] $s 的候选里没有 '$want'：$(cat "$s" 2>/dev/null | tr '\n' ' ')"
		fi
	done
	[ "$found" = "1" ] || echo "  没有找到 block 设备的 scheduler 节点"
	return 0
}

confirm_destructive() {
	if [ "$ASSUME_YES" = "1" ]; then
		echo "  （--yes：已确认）"
		return 0
	fi
	if [ -r /dev/tty ]; then
		printf '  确认执行破坏性切换？输入 yes 继续: ' > /dev/tty
		if read -r ans < /dev/tty; then
			[ "$ans" = "yes" ] && return 0
		fi
		return 1
	fi
	echo "  非交互环境且未加 --yes —— 拒绝执行破坏性操作。" >&2
	return 1
}

switch_algo() {
	want="$1"

	# reset 会把 disksize 清零。读不到现值就【不做】破坏性操作，绝不把 zram 弄成 0 容量。
	saved_disksize="$(node_val disksize | tr -d ' \n')"
	case "$saved_disksize" in
		''|*[!0-9]*)
			echo "  [中止] 读不到当前 disksize（'$saved_disksize'）—— reset 后无法恢复容量，不做破坏性操作。" >&2
			exit 3 ;;
	esac
	if [ "$saved_disksize" = "0" ]; then
		echo "  [中止] disksize=0，reset 后无法恢复容量，不做破坏性操作。" >&2
		exit 3
	fi

	echo
	echo "=== 切换算法（顺序固定，错一步就丢 swap） ==="
	echo "  已保存 disksize = $saved_disksize"

	# [1] swapoff —— 正在当 swap 用时不允许改算法
	if grep -qw zram0 /proc/swaps 2>/dev/null; then
		if swapoff /dev/block/zram0 2>/dev/null || swapoff -a 2>/dev/null; then
			echo "  [1] swapoff /dev/block/zram0"
		else
			echo "  [1] [警告] swapoff 返回非零；继续，但下面 reset 可能失败"
		fi
	else
		echo "  [1] zram0 当前不是 swap，跳过 swapoff"
	fi

	# [2] reset —— 必须让 initstate 归 0，否则 comp_algorithm 是只读的
	if ! printf '1' > "$ZRAM/reset" 2>/dev/null; then
		echo "  [2] [中止] reset 失败。若有进程正在用 zram，先停掉再试。" >&2
		exit 3
	fi
	echo "  [2] reset 完成   initstate=$(node_val initstate)"

	# [3] comp_algorithm —— 必须在 reset 之后
	if ! printf '%s' "$want" > "$ZRAM/comp_algorithm" 2>/dev/null; then
		echo "  [3] [中止] 写 comp_algorithm='$want' 被拒。候选：$(node_val comp_algorithm)" >&2
		exit 3
	fi
	echo "  [3] comp_algorithm = $want   现在=$(cur_algo)"

	# [4] 重设 disksize —— reset 已把它清零，不重设则 mkswap/swapon 全失败
	if ! printf '%s' "$saved_disksize" > "$ZRAM/disksize" 2>/dev/null; then
		echo "  [4] [中止] 重设 disksize 失败 —— 设备容量为 0，不要 mkswap。" >&2
		exit 3
	fi
	echo "  [4] disksize 重设为 $saved_disksize"

	# 另：zgroup_enable 实测在 reset 后保持 =1；掉了就补回来（小米回写的前提）
	if have zgroup_enable; then
		zg="$(node_val zgroup_enable | tr -d ' \n')"
		if [ "$zg" != "1" ]; then
			printf '1' > "$ZRAM/zgroup_enable" 2>/dev/null
			echo "  另: zgroup_enable $zg -> $(node_val zgroup_enable)（reset 后丢了，已补）"
		else
			echo "  另: zgroup_enable ok (=1)"
		fi
	fi

	# [5] mkswap —— reset 清除了设备上的 swap 签名；没有签名就不是 swap 设备
	if mkswap /dev/block/zram0 >/dev/null 2>&1; then
		echo "  [5] mkswap ok"
	else
		echo "  [5] [警告] mkswap 失败（swapon 大概率也会失败）"
	fi

	# [6] swapon —— 绝不带 -p：toybox 的 swapon 不接受负数 -p，而 ROM 默认优先级是 -2
	if swapon /dev/block/zram0 2>/dev/null; then
		echo "  [6] swapon 完成（未带 -p，由 ROM 分配默认优先级）"
	else
		echo "  [6] [失败] swapon 失败 —— 看 /proc/swaps 与 dmesg"
	fi
	return 0
}

tune_vm() {
	echo
	echo "=== VM 参数（实测写入过的 5 项；其余一律不碰） ==="
	write_sysctl vm.swappiness              "$SWAPPINESS"
	write_sysctl vm.vfs_cache_pressure      100
	write_sysctl vm.compaction_proactiveness 20
	write_sysctl vm.watermark_boost_factor  0
	write_sysctl vm.extfrag_threshold       1000
	echo "  注：不写 vm.page-cluster / vm.watermark_scale_factor / /sys/kernel/mm/lru_gen/*（无实测依据）"
	echo "  注：不改 read_ahead_kb —— ROM 默认 512；照抄别人的 128 实测降低顺序读性能"
	[ -n "$WANT_SCHED" ] && write_scheduler "$WANT_SCHED"
	return 0
}

verify() {
	echo
	echo "=== 验证（唯一算数的部分） ==="
	echo "  comp_algorithm : $(node_val comp_algorithm | tr '\n' ' ')"
	echo "  当前算法       : $(cur_algo)"
	echo "  disksize       : $(node_val disksize)"
	echo "  initstate      : $(node_val initstate)"
	echo "  zgroup_enable  : $(node_val zgroup_enable)"
	echo "  /proc/swaps    :"
	sed 's/^/    /' /proc/swaps 2>/dev/null
	if have mm_stat; then
		echo "  mm_stat        : $(node_val mm_stat | tr '\n' ' ')"
		awk 'NF>=2 && $2+0>0 {printf "  压缩比(orig/compr) = %.2f:1\n", $1/$2}' "$ZRAM/mm_stat" 2>/dev/null
	else
		echo "  mm_stat        : 不存在 —— 这台机器拿不到 zram 自己的压缩比"
	fi
	echo "  换页计数       :"
	grep -E 'pswp(in|out)|pgscan_kswapd|pgmajfault' /proc/vmstat 2>/dev/null | sed 's/^/    /'
	echo "  小米回写       : enable=$(cat /dev/memcg/memory.xswapd.enable 2>/dev/null)  (原厂默认 0)"
	echo
	echo "  注意：本脚本【不】声称任何压缩比提升。换算法后有没有真的更好，"
	echo "        要用 kernel-perf-verification 的 A/B 协议量，不能靠感觉。"
	return 0
}

apply() {
	want="$1"
	need_root

	echo "=== 0. 预检（探测不通过就不动手） ==="
	[ -d "$ZRAM" ] || { echo "  [中止] 没有 $ZRAM —— 这台设备没有 zram0" >&2; exit 3; }
	echo "  zram0: 存在"

	cur="$(cur_algo)"
	echo "  当前算法: ${cur:-（解析不到）}   目标: $want"

	do_switch=0
	if [ "$want" = "keep" ]; then
		echo "  [跳过] keep —— 只调 VM，不动 zram"
	else
		have comp_algorithm || { echo "  [中止] 没有 comp_algorithm，无法切算法" >&2; exit 3; }
		have reset          || { echo "  [中止] 没有 reset，无法安全切算法" >&2; exit 3; }
		have disksize       || { echo "  [中止] 没有 disksize，reset 后无法恢复容量" >&2; exit 3; }
		algo_supported "$want" || {
			echo "  [中止] '$want' 不在候选集里：$(node_val comp_algorithm)" >&2; exit 3; }
		if [ "$cur" = "$want" ]; then
			echo "  [跳过] 当前已经是 $want，不做破坏性操作"
		else
			do_switch=1
		fi
	fi

	if [ "$do_switch" = "1" ]; then
		echo
		echo "  ！！！ 破坏性操作警告 ！！！"
		echo "  切换 $cur -> $want 会 swapoff + reset zram0："
		echo "    · 丢弃 zram 里现有的全部压缩页（= 丢掉那部分 swap 数据）"
		echo "    · 可能杀掉正在运行的进程"
		echo "  只在低负载 + 有空闲内存时做。"
		confirm_destructive || { echo "  已取消，未做任何修改。"; exit 5; }
		switch_algo "$want"
	fi

	tune_vm
	verify
	return 0
}

persist() {
	profile="$1"
	need_root

	# 生成时解析本脚本的【绝对路径】—— 开机时的当前目录不是这个目录。
	self_dir="$(cd -- "$(dirname -- "$0")" && pwd -P 2>/dev/null)" || {
		echo "无法解析脚本所在目录" >&2; exit 3; }
	self="$self_dir/$(basename -- "$0")"
	[ -f "$self" ] || { echo "解析出的脚本路径不存在: $self" >&2; exit 3; }

	[ -d "$PERSIST_DIR" ] || mkdir -p "$PERSIST_DIR" 2>/dev/null || {
		echo "无法创建 $PERSIST_DIR（需要 root）" >&2; exit 3; }

	cat > "$PERSIST_FILE" <<EOF
#!/system/bin/sh
# 由 xiaomi17-kernel-skills / zram-compression-tuning 生成，请勿手改。
# KernelSU / Magisk 开机后执行；厂商 init 会先配好 zram，这里在其之后覆盖。
# 生成时间: $(date 2>/dev/null)
# 目标算法: $profile
sleep 30
if command -v bash >/dev/null 2>&1; then
	RUN=bash
else
	RUN=sh
fi
"\$RUN" "$self" --apply $profile --yes >> $PERSIST_LOG 2>&1
EOF
	chmod 0755 "$PERSIST_FILE" 2>/dev/null

	echo "已写入 $PERSIST_FILE"
	echo "  调用: $self --apply $profile --yes"
	echo "  日志: $PERSIST_LOG"
	echo
	echo "注意:"
	echo "  1) 目标算法与当前一致时脚本会跳过破坏性切换，只做 VM 调参，开机无风险。"
	echo "  2) 这里写入的是【绝对路径】: $self"
	echo "     如果你把 zram-tune.sh 挪到别处，要重新跑 --persist 生成。"
	return 0
}

# ---------------------------------------------------------------- 入口
rc=0
case "$MODE" in
	report)  report || rc=$? ;;
	apply)   apply "$TARGET"; rc=$? ;;
	persist) persist "$TARGET"; rc=$? ;;
esac
exit "$rc"
