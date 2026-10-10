#!/usr/bin/env bash
# safe-config-change.sh — 内核配置改动的闸门。
#
# 设计前提：在这台设备（小米 17 / canoe / SM8850 / KMI android16-6-4k）上，
# **改配置是一种危险操作**。GKI 的符号 CRC 由 gendwarfksyms 依据结构体布局递归推导，
# 所以打开一个看似无关的诊断项可以改变 struct module 的大小，进而让 vendor_dlkm 里的
# 厂商模块拒载 → 显示栈起不来 → 卡第一屏（静默，无 panic、无 oops、无日志）。
#
# 本脚本做五件事，缺一不可：
#   1. 从基线 .config 复制一份（绝不要从零手写 defconfig）
#   2. 合并前，先扫描 fragment 的「声明意图」，命中红线立刻停
#   3. 用树自带的 scripts/config 逐项应用，只动你列出的项
#   4. 跑两轮 make olddefconfig，让 select 链收敛
#   5. 用 scripts/diffconfig 打出真实改动，再对**最终 .config** 复查 8 条红线 + 期望值表
#
# 只有全部通过，脚本才会打印放行语：「可以编译了，下一步：verify-abi.sh」。
#
# ★ 本脚本刻意不设 set -u（内核构建环境的硬约束）：
#   _setup_env.sh 引用多个可能未定义的变量（_SETUP_ENV_SH_INCLUDED /
#   KLEAF_INTERNAL_NO_BUILD_CONFIG / BUILD_CONFIG_FRAGMENTS），在 set -u 下会立即 abort。
#   本脚本自身也大量使用 ${VAR:-默认} 形式，不要改成依赖未定义变量报错。
#
# 用法:
#   # 零 fragment 模式（首版唯一正确做法：只复现基线，不引入任何变量）
#   bash scripts/safe-config-change.sh --tree ~/kernel/src --base logs/stock.config
#
#   # 从树自带 gki_defconfig 现场生成基线，再合并一项
#   bash scripts/safe-config-change.sh --tree ~/kernel/src --from-gki-defconfig \
#        --fragment config/zram.fragment
#
#   # 有基线，加一项
#   bash scripts/safe-config-change.sh --tree ~/kernel/src --base logs/stock.config \
#        --fragment config/zram.fragment
#
# fragment 格式（一次只放一项；`#` 注释与 `# CONFIG_X is not set` 都支持）:
#   CONFIG_ZRAM_DEF_COMP_ZSTD=y
#   # CONFIG_ZRAM_DEF_COMP_LZORLE is not set
#   CONFIG_ZRAM_MULTI_COMP=y
#
# 退出码: 0 = 全过，可以编译；2 = 用法错误；3 = 命中红线/致命组合，拒绝继续；4 = 通过但有警告

set -o pipefail

TREE=""
BASE=""
FRAGMENT=""
OUT=""
FROM_DEFCONFIG=0

usage() { sed -n '2,40p' "$0"; }

while [ $# -gt 0 ]; do
	case "$1" in
		# 每个带值的选项都先确认后面真的还有一个参数 ——
		# 否则 `shift 2` 在只剩 1 个参数时不会移动位置参数（bash 返回 1 但不 shift），
		# while 循环会拿着同一个 $1 无限转下去。
		--tree)              [ $# -ge 2 ] || { echo "--tree 需要一个值" >&2; exit 2; }; TREE="$2"; shift 2 ;;
		--base)              [ $# -ge 2 ] || { echo "--base 需要一个值" >&2; exit 2; }; BASE="$2"; shift 2 ;;
		--fragment)          [ $# -ge 2 ] || { echo "--fragment 需要一个值" >&2; exit 2; }; FRAGMENT="$2"; shift 2 ;;
		--out)               [ $# -ge 2 ] || { echo "--out 需要一个值" >&2; exit 2; }; OUT="$2"; shift 2 ;;
		--from-gki-defconfig) FROM_DEFCONFIG=1; shift ;;
		-h|--help)           usage; exit 0 ;;
		*) echo "未知参数: $1" >&2; echo "用 --help 看用法" >&2; exit 2 ;;
	esac
done

[ -n "$TREE" ] || { echo "必须给 --tree <内核源码树>" >&2; exit 2; }
[ -d "$TREE" ] || { echo "源码树不存在: $TREE" >&2; exit 2; }
[ -x "$TREE/scripts/config" ] || { echo "找不到 $TREE/scripts/config —— 这不是内核源码树" >&2; exit 2; }

[ -n "$OUT" ] || OUT="$TREE/out"
CFG="$OUT/.config"
BASE_SNAP="$OUT/.config.base"

if [ "$FROM_DEFCONFIG" = "0" ]; then
	[ -n "$BASE" ] || { echo "必须给 --base <基线 .config>，或改用 --from-gki-defconfig" >&2; exit 2; }
	[ -f "$BASE" ] || {
		echo "基线不存在: $BASE" >&2
		echo "在还能开机的内核上取一份：zcat /proc/config.gz > logs/stock.config" >&2
		exit 2
	}
fi

if [ -n "$FRAGMENT" ] && [ ! -f "$FRAGMENT" ]; then
	echo "fragment 不存在: $FRAGMENT" >&2
	exit 2
fi

echo "============================================"
echo " 安全配置改动闸门"
echo "   TREE = $TREE"
echo "   OUT  = $OUT"
echo "   BASE = ${BASE:-<由 gki_defconfig 现场生成>}"
echo "   FRAG = ${FRAGMENT:-<无 —— 零 fragment 模式>}"
echo "============================================"

# 提醒：本脚本只负责生成一份干净的 .config，不负责编译环境。
if [ "${KBUILD_GENDWARFKSYMS_STABLE:-}" != "1" ]; then
	echo ""
	echo "[提醒] KBUILD_GENDWARFKSYMS_STABLE 不是 1。"
	echo "       编译前必须先 source ./_setup_env.sh —— 否则 gendwarfksyms 走 unstable 路径，"
	echo "       符号 CRC 全错（实测裸 make 时 msm_drm.ko DIFF 高达 471）。"
	echo "       本脚本不修改环境变量，只提醒。"
	ENV_WARN=1
else
	ENV_WARN=0
fi

# ---------------------------------------------------------------
# 步骤 1：取出冻结的基线快照
# ---------------------------------------------------------------
echo ""
echo "=== [1/6] 冻结基线 ==="
mkdir -p "$OUT" || { echo "无法创建 $OUT" >&2; exit 3; }

if [ "$FROM_DEFCONFIG" = "1" ]; then
	echo "  用树自带 gki_defconfig 生成基线（首版单变量原则：不引入任何 fragment 之外的东西）"
	# 防呆：下一行是 rm -rf。先确认 $OUT 既不是根、也不是源码树或源码树的祖先
	# （`--out "$TREE"` 会连源码一起删掉，事后无法恢复）。
	case "$OUT" in
		""|"/"|"."|"..") echo "  危险的 --out: '$OUT'，拒绝 rm -rf" >&2; exit 2 ;;
	esac
	case "$TREE/" in
		"$OUT"/*) echo "  --out ($OUT) 等于或包含源码树 ($TREE)，拒绝 rm -rf" >&2; exit 2 ;;
	esac
	rm -rf "$OUT"
	mkdir -p "$OUT"
	if ! make -C "$TREE" O="$OUT" ARCH=arm64 LLVM=1 gki_defconfig >"$OUT/gki_defconfig.log" 2>&1; then
		echo "  gki_defconfig 失败，日志尾部：" >&2
		tail -n 25 "$OUT/gki_defconfig.log" >&2
		exit 3
	fi
	cp "$OUT/.config" "$BASE_SNAP" || { echo "  基线快照失败" >&2; exit 3; }
else
	cp "$BASE" "$BASE_SNAP" || { echo "  基线快照失败" >&2; exit 3; }
fi
echo "  基线快照: $BASE_SNAP"

# ---------------------------------------------------------------
# 步骤 2：合并前扫描 fragment 的「声明意图」
#    这一层在改动之前就拦住红线 —— 因为 apply 完再查，你已经动过 .config 了。
# ---------------------------------------------------------------
RED_FATAL=0
red_fatal() { echo "  [致命] $1"; RED_FATAL=$((RED_FATAL + 1)); }

FRAG_SAW_STACK_OFF=0
FRAG_SAW_FTRACE_OFF=0

if [ -n "$FRAGMENT" ]; then
	echo ""
	echo "=== [2/6] 合并前扫描 fragment 声明意图: $FRAGMENT ==="

	# 归一化成 SYM|VALUE
	PARSED="$(sed -e 's/[[:space:]]*$//' "$FRAGMENT" | awk '
		/^# CONFIG_[A-Za-z0-9_]+ is not set$/ { print $2 "|n"; next }
		/^CONFIG_[A-Za-z0-9_]+=/              { i = index($0, "="); print substr($0, 1, i - 1) "|" substr($0, i + 1); next }
		{ next }
	')"

	if [ -z "$PARSED" ]; then
		echo "  fragment 里没有可解析的 CONFIG_ 行（只有注释？）—— 检查一下是不是写错了。"
	fi

	printf '%s\n' "$PARSED" | while IFS='|' read -r sym val; do
		[ -n "$sym" ] || continue
		echo "  声明: $sym=$val"
	done

	printf '%s\n' "$PARSED" | while IFS='|' read -r sym val; do
		case "$sym" in
			CONFIG_FUNCTION_TRACER|CONFIG_FUNCTION_GRAPH_TRACER|CONFIG_STACK_TRACER|CONFIG_FTRACE_MCOUNT_RECORD)
				case "$val" in
					y|Y|m|M) echo "  !!! 红线 $sym=$val —— 会让 struct module 变 1664/77 → msm_drm.ko 拒载 → 卡第一屏" ;;
				esac ;;
			CONFIG_MODULE_SIG_FORCE)
				case "$val" in
					y|Y) echo "  !!! 红线 $sym=y —— 厂商模块没有你的签名，会全部被拒绝加载 → 不开机" ;;
				esac ;;
			CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX)
				[ "$val" = "1024" ] || echo "  !!! 红线 $sym=$val —— 期望值是 1024，改它等于直接改 task_struct 的 ABI" ;;
			CONFIG_CFI_CLANG)
				[ "$val" = "y" ] || echo "  !!! 红线 $sym=$val —— 期望值是 y，KCFI 类型哈希进符号表" ;;
			CONFIG_SHADOW_CALL_STACK)
				[ "$val" = "y" ] || echo "  !!! 红线 $sym=$val —— 期望值是 y，SCS 改变调用约定与结构体布局" ;;
			CONFIG_DEBUG_INFO_BTF)
				case "$val" in
					n|N) echo "  !!! 有毒: $sym=n —— 绝不要用关 BTF 来绕开 pahole 报错，那会掩盖真实编译错误。正确解法是把 AOSP build-tools 的 prebuilt pahole 放到 PATH 最前面。" ;;
				esac ;;
		esac
	done >"$OUT/.fragment-scan" 2>&1
	cat "$OUT/.fragment-scan"
	while IFS= read -r l; do
		case "$l" in *"!!!"*) RED_FATAL=$((RED_FATAL + 1)) ;; esac
	done <"$OUT/.fragment-scan"

	# select 依赖陷阱：只关 FUNCTION_TRACER 无效，会被 STACK_TRACER 拉回来
	while IFS='|' read -r sym val; do
		case "$sym" in
			CONFIG_STACK_TRACER) case "$val" in n|N) FRAG_SAW_STACK_OFF=1 ;; esac ;;
			CONFIG_FUNCTION_TRACER|CONFIG_FUNCTION_GRAPH_TRACER|CONFIG_FTRACE_MCOUNT_RECORD)
				case "$val" in n|N) FRAG_SAW_FTRACE_OFF=1 ;; esac ;;
		esac
	done <<EOF
$PARSED
EOF

	if [ "$FRAG_SAW_FTRACE_OFF" = "1" ] && [ "$FRAG_SAW_STACK_OFF" = "0" ]; then
		red_fatal "你关了 FUNCTION_TRACER 一类的项，但没关 CONFIG_STACK_TRACER。"
		echo "         STACK_TRACER 会用 select 把 FUNCTION_TRACER 拉回来（kernel/trace/Kconfig:316-319），"
		echo "         于是你改了个寂寞，编完一看 FUNCTION_TRACER 还是 y。"
		echo "         正确顺序：先关 CONFIG_STACK_TRACER，再关其余 ftrace 项，然后连跑两轮 olddefconfig。"
	fi
	if [ "$FRAG_SAW_STACK_OFF" = "1" ]; then
		echo "  [i] 已声明关闭 STACK_TRACER —— 顺序正确（上游先断）。别忘了两轮 olddefconfig。"
	fi
fi

if [ "$RED_FATAL" -gt 0 ]; then
	echo ""
	echo "  → 合并前就被拦住了，共 $RED_FATAL 项。拒绝了，不继续。"
	echo "    详见 skill kernel-config-power-perf 的「8 条红线」与「反面教材 diag-safe.fragment」。"
	exit 3
fi

# ---------------------------------------------------------------
# 步骤 3：复制基线 -> .config，逐项应用
# ---------------------------------------------------------------
echo ""
echo "=== [3/6] 应用 fragment ==="
cp "$BASE_SNAP" "$CFG" || { echo "  复制基线失败" >&2; exit 3; }
echo "  基线: $BASE_SNAP -> $CFG"

applied=0
if [ -n "$FRAGMENT" ]; then
	while IFS='|' read -r sym val; do
		[ -n "$sym" ] || continue
		name="${sym#CONFIG_}"
		case "$val" in
			n|N) "$TREE/scripts/config" --file "$CFG" --disable "$name" ;;
			y|Y|m|M) "$TREE/scripts/config" --file "$CFG" --enable "$name" ;;
			*) "$TREE/scripts/config" --file "$CFG" --set-val "$name" "$val" ;;
		esac
		echo "  已应用 $sym=$val"
		applied=$((applied + 1))
	done <<EOF
$PARSED
EOF
else
	echo "  零 fragment 模式：只复现基线，不引入任何变量。"
	echo "  这是首版唯一正确的做法 —— 血统已经是未验证的大变量，不要再叠配置变量。"
fi
echo "  共应用 $applied 项"

# ---------------------------------------------------------------
# 步骤 4：两轮 olddefconfig（select 链要两轮才收敛）
# ---------------------------------------------------------------
echo ""
echo "=== [4/6] make olddefconfig x2（select 链收敛） ==="
round=1
while [ "$round" -le 2 ]; do
	if ! make -C "$TREE" O="$OUT" ARCH=arm64 LLVM=1 olddefconfig >"$OUT/olddefconfig.$round.log" 2>&1; then
		echo "  第 $round 轮 olddefconfig 失败，日志尾部：" >&2
		tail -n 25 "$OUT/olddefconfig.$round.log" >&2
		exit 3
	fi
	echo "  第 $round 轮完成"
	round=$((round + 1))
done

# ---------------------------------------------------------------
# 步骤 5：diffconfig —— 你到底改了什么
# ---------------------------------------------------------------
echo ""
echo "=== [5/6] scripts/diffconfig: 真实改动 ==="
echo "  注意：Kbuild 会顺带带出很多项，只看你写的那几行是不够的。"
echo ""
"$TREE/scripts/diffconfig" "$BASE_SNAP" "$CFG" || true

# ---------------------------------------------------------------
# 步骤 6：对最终 .config 复查（权威判据）
# ---------------------------------------------------------------
echo ""
echo "=== [6/6] 闸门：8 条红线 + 编前自检期望值表 ==="

cfg_val() { sed -n "s/^$1=//p" "$CFG" | tail -n 1; }
cfg_yes() { grep -qE "^$1=y$" "$CFG"; }

FATAL=0
WARN=0
fatal() { echo "  [致命] $1"; FATAL=$((FATAL + 1)); }
warn()  { echo "  [警告] $1"; WARN=$((WARN + 1)); }
okline(){ echo "  [ok]   $1"; }

echo "-- 红线 1-4：ftrace 四项，必须是 n --"
FT_ON=""
for k in FUNCTION_TRACER FUNCTION_GRAPH_TRACER STACK_TRACER FTRACE_MCOUNT_RECORD; do
	if cfg_yes "CONFIG_$k"; then
		FT_ON="$FT_ON CONFIG_$k"
		fatal "CONFIG_$k=y —— 红线。"
	else
		okline "CONFIG_$k is not set"
	fi
done
if [ -n "$FT_ON" ]; then
	echo ""
	echo "      因果链（逐字，来自实机实测）："
	echo "        CONFIG_STACK_TRACER=y"
	echo "          → select FUNCTION_TRACER        (kernel/trace/Kconfig:316-319)"
	echo "          → CONFIG_FTRACE_MCOUNT_RECORD"
	echo "          → struct module 多 2 个字段：num_ftrace_callsites / ftrace_callsites"
	echo "                                          (include/linux/module.h:542 的 #ifdef)"
	echo "          → struct module 从 1600/75 变 1664/77"
	echo "          → 经 file_system_type->owner 进入 kobject_uevent_env 类型展开"
	echo "          → gendwarfksyms 递归推出不同 CRC"
	echo "          → msm_drm.ko 拒载 → 显示栈起不来 → 卡第一屏"
	echo "      处理顺序（不能反）：先关 CONFIG_STACK_TRACER，再关其余 ftrace 项，"
	echo "      然后连跑两轮 olddefconfig，最后 grep $CFG 复查。"
	echo "      只关 FUNCTION_TRACER 无效 —— 它被 STACK_TRACER 用 select 拉回来。"
fi

echo "-- 红线 5-8：直接改 ABI 的开关 --"
tsz="$(cfg_val CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX)"
[ "$tsz" = "1024" ] && okline "CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024" \
	|| fatal "CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=${tsz:-<absent>} —— 期望 1024，改它等于直接改 task_struct 的 ABI"
[ "$(cfg_val CONFIG_CFI_CLANG)" = "y" ] && okline "CONFIG_CFI_CLANG=y" \
	|| fatal "CONFIG_CFI_CLANG=$(cfg_val CONFIG_CFI_CLANG) —— 期望 y，KCFI 类型哈希进符号表"
[ "$(cfg_val CONFIG_SHADOW_CALL_STACK)" = "y" ] && okline "CONFIG_SHADOW_CALL_STACK=y" \
	|| fatal "CONFIG_SHADOW_CALL_STACK=$(cfg_val CONFIG_SHADOW_CALL_STACK) —— 期望 y，SCS 改变调用约定与结构体布局"
[ "$(cfg_val CONFIG_MODULE_SIG_FORCE)" = "y" ] \
	&& fatal "CONFIG_MODULE_SIG_FORCE=y —— 厂商预编译模块没有你的签名，会被拒载 → 不开机。必须 not set。" \
	|| okline "CONFIG_MODULE_SIG_FORCE is not set"

echo "-- 期望值表：编前自检（任何一项不符就停下来查） --"
[ "$(cfg_val CONFIG_GKI_HACKS_TO_FIX)" = "y" ] && okline "CONFIG_GKI_HACKS_TO_FIX=y" \
	|| fatal "CONFIG_GKI_HACKS_TO_FIX=$(cfg_val CONFIG_GKI_HACKS_TO_FIX) —— 期望 y。缺这一层小米/高通适配就算 ABI 对齐也卡第一屏"
[ "$(cfg_val CONFIG_GENDWARFKSYMS)" = "y" ] && okline "CONFIG_GENDWARFKSYMS=y" \
	|| fatal "CONFIG_GENDWARFKSYMS=$(cfg_val CONFIG_GENDWARFKSYMS) —— 期望 y，CRC 由它推导"
[ "$(cfg_val CONFIG_MODVERSIONS)" = "y" ] && okline "CONFIG_MODVERSIONS=y" \
	|| fatal "CONFIG_MODVERSIONS=$(cfg_val CONFIG_MODVERSIONS) —— 期望 y。关掉它符号版本失配时不报明确错误，只表现为崩溃"
[ "$(cfg_val CONFIG_EXTENDED_MODVERSIONS)" = "y" ] && okline "CONFIG_EXTENDED_MODVERSIONS=y" \
	|| fatal "CONFIG_EXTENDED_MODVERSIONS=$(cfg_val CONFIG_EXTENDED_MODVERSIONS) —— 期望 y"
[ "$(cfg_val CONFIG_DEBUG_INFO_BTF)" = "y" ] && okline "CONFIG_DEBUG_INFO_BTF=y" \
	|| fatal "CONFIG_DEBUG_INFO_BTF=$(cfg_val CONFIG_DEBUG_INFO_BTF) —— 期望 y。Android GKI 依赖 BTF；绝不要用它来绕开 pahole 报错"

# DEBUG_INFO 与 BTF 的组合（BTF 由 DWARF 生成）
if [ "$(cfg_val CONFIG_DEBUG_INFO_BTF)" = "y" ]; then
	di="$(cfg_val CONFIG_DEBUG_INFO)"
	if [ "$di" != "y" ] && [ "$di" != "m" ]; then
		fatal "CONFIG_DEBUG_INFO=${di:-<absent>} 但 CONFIG_DEBUG_INFO_BTF=y —— BTF 由 DWARF 生成，这个组合构不出来。"
		echo "          注意：正确解法不是关 BTF，而是修工具链 —— 把 AOSP build-tools 的 prebuilt pahole 放到 PATH 最前面（系统 pahole 1.25 编不出 6.12 的 BTF：FAILED: load BTF from vmlinux: Invalid argument）。"
	fi
fi

# 已知会裁符号的项
if [ "$(cfg_val CONFIG_TRIM_UNUSED_KSYMS)" = "y" ]; then
	fatal "CONFIG_TRIM_UNUSED_KSYMS=y —— 会把 vendor 模块依赖的符号裁掉。保持 not set。"
fi

# LOCALVERSION 的 KMI 段
lv="$(cfg_val CONFIG_LOCALVERSION)"
case "$lv" in
	*-4k*) okline "CONFIG_LOCALVERSION=$lv  （含 -4k KMI 段）" ;;
	"")    fatal "CONFIG_LOCALVERSION 缺失 —— vermagic 对不上设备模块" ;;
	*)     fatal "CONFIG_LOCALVERSION=$lv 不含 -4k —— KMI 段必须保留" ;;
esac

echo "-- 已知但非致命的项 --"
[ "$(cfg_val CONFIG_SCHED_WALT)" = "y" ] \
	&& warn "CONFIG_SCHED_WALT=y：WALT 不是 6.12 上游调度器，只有厂商补丁才有。确认你的树里真有这个符号。"
[ "$(cfg_val CONFIG_LTO_CLANG_FULL)" = "y" ] \
	&& warn "CONFIG_LTO_CLANG_FULL=y：构建时间与内存开销远高于 THIN，手机上基本编不动。"
[ "$ENV_WARN" = "1" ] \
	&& warn "KBUILD_GENDWARFKSYMS_STABLE 未设为 1：编译前必须 source ./_setup_env.sh。"

echo ""
echo "=== 结论 ==="
echo "  应用项数=$applied  致命=$FATAL  警告=$WARN"

if [ "$FATAL" -gt 0 ]; then
	echo "  → 拒绝放行。先修掉上面每一条 [致命]，然后重新跑本脚本。"
	echo "    不要「反正能编」就往下走 —— 这些项不会让编译失败，只会让你刷完卡在第一屏。"
	exit 3
fi

echo "  → 可以编译了，下一步：verify-abi.sh"
echo ""
echo "  完整顺序（一项也不能省）:"
echo "    source ./_setup_env.sh            # 必须，否则 CRC 全错"
echo "    bash scripts/build.sh             # 编译"
echo "    bash scripts/verify-abi.sh        # 四项必须全过："
echo "        ① 全量 CRC vs gki/aarch64/abi.stg  DIFF=0"
echo "        ② msm_drm.ko 的 __versions          DIFF=0（MISSING 150 允许）"
echo "        ③ struct module                     1600 字节 / 75 成员"
echo "        ④ kobject_uevent_env                0x8bb6d45c"
echo "    然后将本项记录到 CHANGELOG，上机验证能开机，才加下一项。"
echo "    首版请保持零 fragment。一次只加一项。"
[ "$WARN" -gt 0 ] && exit 4
exit 0
