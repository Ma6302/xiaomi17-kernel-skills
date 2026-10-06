#!/usr/bin/env bash
# preflight.sh — 编译前的只读体检：工具链架构、依赖、内存/swap、磁盘、树布局、defconfig 名。
#
# 它不编译任何东西，只回答两个问题：
#   1) 这台设备/这个环境到底能不能本地编译？
#   2) 内核树是 Kleaf 还是 legacy make，defconfig 叫什么？
#
# 用法:
#   bash scripts/preflight.sh --tree ~/kernel/src --defconfig popsicle_defconfig
#   bash scripts/preflight.sh --tree ~/kernel/src            # 自动探测 defconfig 名
#
# 退出码：0 = 可以继续；3 = 有 BLOCKER；4 = 只有 WARNING。

set -u

TREE=""
DEFCONFIG=""
JOBS=""

while [ $# -gt 0 ]; do
	case "$1" in
		--tree)      TREE="${2:?}"; shift 2 ;;
		--defconfig) DEFCONFIG="${2:?}"; shift 2 ;;
		--jobs)      JOBS="${2:?}"; shift 2 ;;
		-h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

if [ -z "$TREE" ]; then
	for cand in "$HOME/kernel/src" "/sdcard/Download/Operit/kernel-dev/src" "$HOME/Xiaomi_Kernel_OpenSource"; do
		[ -d "$cand" ] && { TREE="$cand"; break; }
	done
fi

BLOCKERS=0
WARNINGS=0
blocker() { echo "  [BLOCKER] $*"; BLOCKERS=$((BLOCKERS + 1)); }
warn()    { echo "  [WARN]    $*"; WARNINGS=$((WARNINGS + 1)); }

echo "=== 1. 主机架构与工具链 ==="
arch=$(uname -m)
echo "  uname -m = $arch"

if command -v clang >/dev/null 2>&1; then
	clang_path=$(command -v clang)
	echo "  clang    = $clang_path"
	if command -v file >/dev/null 2>&1; then
		desc=$(file -b "$clang_path" 2>/dev/null)
		echo "  clang 类型 = $desc"
		case "$desc" in
			*x86-64*|*x86_64*)
				if [ "$arch" = "aarch64" ]; then
					blocker "clang 是 x86_64 二进制，在 aarch64 上无法执行。这几乎肯定是 AOSP 预编译 clang —— 改用发行版 clang（apt install clang-18 lld-18 llvm-18），或改走 CI。"
				fi
				;;
			*aarch64*|*ARM\ aarch64*)
				echo "  → 原生 aarch64 clang，可以本地编译。"
				;;
		esac
	fi
else
	blocker "找不到 clang。apt install clang-18 lld-18 llvm-18"
fi

for t in ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip llvm-objdump make bc flex bison cpio rsync zip python3; do
	command -v "$t" >/dev/null 2>&1 || blocker "缺命令: $t"
done
for t in pahole gcc g++ perf; do
	command -v "$t" >/dev/null 2>&1 || warn "缺命令: $t（pahole 缺了 BTF 会失败；gcc/g++ 缺了 HOSTCC 会失败）"
done

echo
echo "=== 2. 内存与 swap ==="
if [ -r /proc/meminfo ]; then
	mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
	avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
	swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
	echo "  MemTotal=$(awk -v k="$mem_kb" 'BEGIN{printf "%.1fG", k/1048576}')  MemAvailable=$(awk -v k="$avail_kb" 'BEGIN{printf "%.1fG", k/1048576}')  SwapTotal=$(awk -v k="$swap_kb" 'BEGIN{printf "%.1fG", k/1048576}')"
	[ "$swap_kb" -lt 4194304 ] && warn "swap 小于 4G。LTO 链接阶段很吃内存，建议加 swapfile。"
	[ "$avail_kb" -lt 3145728 ] && blocker "可用内存不足 3G，链接阶段几乎一定 OOM。先腾内存再加 swap。"
fi

if [ -z "$JOBS" ]; then
	cores=$(nproc 2>/dev/null || echo 4)
	if [ "$cores" -ge 8 ]; then JOBS=$((cores - 2)); else JOBS=$((cores > 1 ? cores - 1 : 1)); fi
fi
echo "  建议 -j$JOBS（留 1–2 核给系统与温控，比 -j\$(nproc) 慢但不容易 OOM/过热）"

echo
echo "=== 3. 磁盘 ==="
for d in "$TREE" "$HOME"; do
	[ -d "$d" ] || continue
	if command -v df >/dev/null 2>&1; then
		line=$(df -h "$d" 2>/dev/null | tail -n1)
		echo "  $d -> $line"
		avail_g=$(df -BG "$d" 2>/dev/null | tail -n1 | awk '{gsub("G","",$4); print $4}')
		if [ -n "${avail_g:-}" ] && [ "$avail_g" -lt 40 ]; then
			warn "剩余空间 ${avail_g}G。内核树 + out/ 通常要 25–40G（LTO 更费）。"
		fi
	fi
done

echo
echo "=== 4. 内核树 ==="
if [ -z "$TREE" ] || [ ! -d "$TREE" ]; then
	blocker "找不到内核树。用 --tree 指定，或先 clone 到 /sdcard/Download/Operit/kernel-dev/src"
else
	echo "  TREE = $TREE"
	[ -f "$TREE/Makefile" ] || blocker "$TREE 里没有 Makefile，这不像内核源码根目录"
	if [ -f "$TREE/Makefile" ]; then
		echo "  版本: $(awk -F'= *' '/^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) *=/{printf "%s ", $2}' "$TREE/Makefile")"
	fi
	if [ -d "$TREE/common" ] && [ -f "$TREE/tools/bazel" ]; then
		BUILD_SYSTEM="kleaf"
		echo "  构建系统: Kleaf（存在 tools/bazel + common/）"
	else
		BUILD_SYSTEM="legacy"
		echo "  构建系统: legacy make（没有 tools/bazel 或 common/）"
	fi
	echo "  配置文件:"
	if [ -d "$TREE/arch/arm64/configs" ]; then
		ls "$TREE/arch/arm64/configs" 2>/dev/null | sed 's/^/    /'
		if [ -z "$DEFCONFIG" ]; then
			DEFCONFIG=$(ls "$TREE/arch/arm64/configs" 2>/dev/null | grep -E '_defconfig$' | grep -v gki_defconfig | head -n1)
			[ -z "$DEFCONFIG" ] && DEFCONFIG=$(ls "$TREE/arch/arm64/configs" 2>/dev/null | grep -E '_defconfig$' | head -n1)
			[ -n "$DEFCONFIG" ] && echo "  → 自动选中 defconfig: $DEFCONFIG（必须人工确认这是你的机型）"
		fi
	else
		warn "$TREE/arch/arm64/configs 不存在，可能不是完整树或还是浅克隆"
	fi
fi

echo
echo "=== 5. 基线配置（最关键的一步） ==="
if [ -r /proc/config.gz ]; then
	echo "  /proc/config.gz 可读 —— 趁还在原厂内核上，立刻固化它："
	echo "    zcat /proc/config.gz > logs/stock.config"
	echo "  这份文件是厂商的权威配置，是你判断「我改动到底改了哪些项」的唯一基线。"
else
	warn "/proc/config.gz 读不到（当前内核可能没开 CONFIG_IKCONFIG_PROC，或你已经在自制内核上）。改用 scripts/extract-ikconfig 从未刷的原厂 boot.img 提取。"
fi
if [ -n "${TREE:-}" ] && [ -x "$TREE/scripts/extract-ikconfig" ]; then
	echo "  备选: bash $TREE/scripts/extract-ikconfig <stock_boot.img> > logs/stock.config"
fi

echo
echo "=== 结论 ==="
echo "  构建系统: ${BUILD_SYSTEM:-未知}"
echo "  defconfig: ${DEFCONFIG:-未确定}"
echo "  建议并行: -j$JOBS"
echo "  BLOCKER=$BLOCKERS  WARNING=$WARNINGS"

if [ "$BLOCKERS" -gt 0 ]; then
	echo
	echo "  → 有 BLOCKER，不要开始编译。先解决上面每一条 [BLOCKER]。"
	echo "  → 如果 BLOCKER 是「clang 是 x86_64」，唯一的两条路是：装发行版 clang，或改走 CI。"
	exit 3
fi
[ "$WARNINGS" -gt 0 ] && { echo "  → 只有 WARNING，可以继续，但先读一遍上面每条。" ; exit 4; }
echo "  → 可以进入编译。"
exit 0
