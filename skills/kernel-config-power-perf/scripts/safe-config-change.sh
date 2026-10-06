#!/usr/bin/env bash
# safe-config-change.sh — 在 stock.config 基线上做最小、可审阅的内核配置改动。
#
# 它做四件事，缺一不可：
#   1. 从原厂基线复制一份 .config（不是从零写一份 defconfig）
#   2. 用树自带的 scripts/config 逐项改，只改你列出的项
#   3. 跑 make olddefconfig 让 Kbuild 补齐依赖 —— 手写依赖必然漏
#   4. scripts/diffconfig 打出「你到底改动了什么」，并拦截已知的不开机配置
#
# 用法:
#   bash scripts/safe-config-change.sh --tree ~/kernel/src --base logs/stock.config \
#        --fragment configs/step1.fragment
#
# fragment 文件格式（每行一个，`#` 注释）:
#   CONFIG_LRU_GEN=y
#   CONFIG_ZRAM_MULTI_COMP=y
#   CONFIG_SLUB_DEBUG=n
#
# 退出码: 0 = 改动干净；3 = 命中致命组合，拒绝继续；4 = 有警告

set -u

TREE=""
BASE=""
FRAGMENT=""
OUT=""

while [ $# -gt 0 ]; do
	case "$1" in
		--tree)     TREE="${2:?}"; shift 2 ;;
		--base)     BASE="${2:?}"; shift 2 ;;
		--fragment) FRAGMENT="${2:?}"; shift 2 ;;
		--out)      OUT="${2:?}"; shift 2 ;;
		-h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

[ -n "$TREE" ]     || { echo "必须给 --tree" >&2; exit 2; }
[ -n "$BASE" ]     || { echo "必须给 --base（原厂 config 基线）" >&2; exit 2; }
[ -f "$BASE" ]     || { echo "基线不存在: $BASE —— 先在原厂内核上 zcat /proc/config.gz > $BASE" >&2; exit 3; }
[ -n "$FRAGMENT" ] || { echo "必须给 --fragment" >&2; exit 2; }
[ -f "$FRAGMENT" ] || { echo "fragment 不存在: $FRAGMENT" >&2; exit 2; }

[ -n "$OUT" ] || OUT="$TREE/out"
mkdir -p "$OUT"
CFG="$OUT/.config"

cp "$BASE" "$CFG" || { echo "复制基线失败" >&2; exit 3; }
echo "基线已复制: $BASE -> $CFG"

echo
echo "=== 应用 fragment: $FRAGMENT ==="
applied=0
while IFS= read -r line || [ -n "$line" ]; do
	line="${line%%#*}"
	line="$(printf '%s' "$line" | tr -d '[:space:]')"
	[ -n "$line" ] || continue
	case "$line" in
		CONFIG_*=*) : ;;
		*) echo "  跳过无法解析的行: $line"; continue ;;
	esac
	sym="${line%%=*}"
	val="${line#*=}"
	if [ "$val" = "n" ] || [ "$val" = "N" ]; then
		"$TREE/scripts/config" --file "$CFG" --disable "${sym#CONFIG_}"
	else
		if [ "$val" = "y" ] || [ "$val" = "m" ]; then
			"$TREE/scripts/config" --file "$CFG" --enable "${sym#CONFIG_}"
		else
			"$TREE/scripts/config" --file "$CFG" --set-val "${sym#CONFIG_}" "$val"
		fi
	fi
	echo "  已应用 $line"
	applied=$((applied + 1))
done < "$FRAGMENT"
echo "共应用 $applied 项"

echo
echo "=== make olddefconfig（由 Kbuild 补齐依赖，不要跳过） ==="
if ! make -C "$TREE" O="$OUT" ARCH=arm64 olddefconfig >/tmp/olddefconfig.log 2>&1; then
	echo "olddefconfig 失败，尾部日志：" >&2
	tail -n 25 /tmp/olddefconfig.log >&2
	exit 3
fi
echo "  完成"

echo
echo "=== scripts/diffconfig：你到底改了什么 ==="
"$TREE/scripts/diffconfig" "$BASE" "$CFG" || true

echo
echo "=== 致命组合检查 ==="
FATAL=0
WARN=0

cfg_get() { awk -F'=' -v s="$1" '$1==s {print $2}' "$CFG" | tail -n1; }

di=$(cfg_get CONFIG_DEBUG_INFO)
btf=$(cfg_get CONFIG_DEBUG_INFO_BTF)
if { [ "$di" = "n" ] || [ -z "$di" ]; } && [ "$btf" = "y" ]; then
	echo "  [致命] CONFIG_DEBUG_INFO 被关，但 CONFIG_DEBUG_INFO_BTF=y。BTF 由 DWARF 生成，这个组合构不出来。二选一：保留 DEBUG_INFO，或同时关掉 BTF。"
	FATAL=$((FATAL + 1))
fi
if [ "$(cfg_get CONFIG_MODULE_SIG_FORCE)" = "y" ]; then
	echo "  [致命] CONFIG_MODULE_SIG_FORCE=y。厂商预编译模块没有你的签名，会被拒绝加载 → 不开机。保持 not set。"
	FATAL=$((FATAL + 1))
fi
if [ "$(cfg_get CONFIG_TRIM_UNUSED_KSYMS)" = "y" ]; then
	echo "  [致命] CONFIG_TRIM_UNUSED_KSYMS=y。会把 vendor 模块依赖的符号裁掉。保持 not set。"
	FATAL=$((FATAL + 1))
fi
if [ "$(cfg_get CONFIG_MODVERSIONS)" != "y" ]; then
	echo "  [警告] CONFIG_MODVERSIONS 不是 y。关掉它会使模块与内核符号版本失配时不报明确错误，只表现为崩溃。"
	WARN=$((WARN + 1))
fi
if [ "$(cfg_get CONFIG_SCHED_WALT)" = "y" ]; then
	echo "  [警告] CONFIG_SCHED_WALT=y：WALT 不是 6.12 上游调度器，只有厂商补丁才有。若你的树里确实有 WALT 补丁才保留。"
	WARN=$((WARN + 1))
fi
if [ "$(cfg_get CONFIG_LTO_CLANG_FULL)" = "y" ]; then
	echo "  [警告] CONFIG_LTO_CLANG_FULL=y：构建时间与内存开销远高于 THIN，手机上基本编不动。"
	WARN=$((WARN + 1))
fi

echo
echo "=== 结论 ==="
echo "  改动项数=$applied  致命=$FATAL  警告=$WARN"
if [ "$FATAL" -gt 0 ]; then
	echo "  → 拒绝继续。先修掉上面每一条 [致命]。"
	exit 3
fi
echo "  → 配置干净。可以编译。记住：一次只改一步，编好刷好验证过，再改下一步。"
[ "$WARN" -gt 0 ] && exit 4
exit 0
