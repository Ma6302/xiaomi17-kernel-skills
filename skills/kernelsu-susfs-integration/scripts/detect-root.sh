#!/usr/bin/env bash
# detect-root.sh — 在给内核打 KernelSU/SUSFS 补丁之前，先搞清楚设备现在是什么 root。
#
# 为什么必须先做这一步：刷入一个自带 KernelSU 的内核，会替换掉 boot 分区里
# 现有的 root 方案。如果设备现在是 Magisk 且 ramdisk 里打过 Magisk 补丁，
# 刷入新内核 = Magisk 补丁消失 = 掉 root，而且已装模块可能全部失效。
# 「先搞清楚现状再动手」在这里不是谨慎，是避免把能用的东西弄坏。
#
# 只读。用法: bash scripts/detect-root.sh

set -u
p() { getprop "$1" 2>/dev/null || true; }
has() { command -v "$1" >/dev/null 2>&1; }
say() { printf '  %s\n' "$*"; }

echo "=== 内核与平台 ==="
say "uname -r            = $(uname -r)"
say "uname -v            = $(uname -v 2>/dev/null)"
say "代号                = $(p ro.product.device)"
say "系统                = $(p ro.build.display.id)（Android $(p ro.build.version.release)）"
say "安全补丁            = $(p ro.build.version.security_patch)"
say "槽位                = $(p ro.boot.slot_suffix)"
if [ -r /proc/config.gz ]; then
	say "/proc/config.gz 存在 —— 可以直接读出当前内核的真配置"
	for k in CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_MODULES CONFIG_KPROBES CONFIG_ZRAM_MULTI_COMP CONFIG_LRU_GEN; do
		v="$(zcat /proc/config.gz 2>/dev/null | grep -E "^$k=" | head -1)"
		[ -n "$v" ] && say "    $v"
	done
else
	say "/proc/config.gz 不存在（CONFIG_IKCONFIG_PROC 没开）—— 无法直接读当前内核配置"
fi

echo
echo "=== 现有 root 方案（这是本脚本存在的理由） ==="
ROOT_FOUND="none"

if has su; then
	V="$(su -v 2>/dev/null | head -1)"
	[ -n "$V" ] && say "su -v = $V"
fi

if [ -d /data/adb/magisk ] || has magisk; then
	say "[检测到] Magisk"
	[ -f /data/adb/magisk/util_functions.sh ] && say "    /data/adb/magisk 存在"
	has magisk && say "    magisk 版本: $(magisk -V 2>/dev/null || magisk -v 2>/dev/null)"
	ROOT_FOUND="magisk"
fi

if [ -d /data/adb/ksu ] || has ksud || has ksu; then
	say "[检测到] KernelSU 系"
	has ksud && say "    ksud 版本: $(ksud -V 2>/dev/null | head -1)"
	if has ksu_susfs; then
		say "    ksu_susfs 存在: $(ksu_susfs show version 2>/dev/null | head -1)"
		say "    SUSFS 已启用特性:"
		ksu_susfs show enabled_features 2>/dev/null | sed 's/^/        /'
		ROOT_FOUND="kernelsu+susfs"
	else
		say "    ksu_susfs 不存在 —— 当前内核没有 SUSFS 支持"
		[ "$ROOT_FOUND" = "none" ] && ROOT_FOUND="kernelsu"
	fi
fi

if has apd; then say "[检测到] APatch (apd)"; [ "$ROOT_FOUND" = "none" ] && ROOT_FOUND="apatch"; fi

[ "$ROOT_FOUND" = "none" ] && {
	say "没有检测到已知的 root 管理器。"
	say "可能情况：没有 root；或者 root 方案不在上面这些路径里。"
	say "→ 不要假设有 root。先确认，再决定要不要打 KernelSU 补丁。"
}

echo
echo "=== 判断是 LKM 还是 GKI 内置 ==="
if [ -r /proc/config.gz ] && zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_KSU=y'; then
	say "CONFIG_KSU=y 出现在运行中的内核配置里 → 这是 GKI 内置模式"
else
	say "运行中的内核配置里看不到 CONFIG_KSU=y（或读不到配置）"
	say "若 su 能用但不是内置，通常是 LKM 模式（KernelSU-Next 的 .ko 由模块加载）"
	say "关键结论：**LKM 模式拿不到 SUSFS**。SUSFS 是内核源码级补丁，"
	say "         要 SUSFS 就必须自编译内核并以 GKI 模式刷入。"
fi

echo
echo "=== 已装模块（迁移时会受影响的东西） ==="
if [ -d /data/adb/modules ]; then
	n=0
	for d in /data/adb/modules/*/; do
		[ -d "$d" ] || continue
		n=$((n+1))
		say "$(basename "$d")$([ -f "$d/disable" ] && echo '  [已禁用]')"
	done
	say "共 $n 个模块"
	say "注意：Magisk 模块与 KernelSU 模块的兼容性不保证。换 root 方案后逐个验证。"
else
	say "/data/adb/modules 不存在"
fi

echo
echo "=== 刷入前必须回答的问题 ==="
cat <<'TXT'
  1. 当前 root 是什么？（见上）
  2. 换成内置 KernelSU 之后，原来那个 root 还要不要？
     要 → 备份当前 boot 分区（它里面就有 root 补丁），这是唯一的退路。
     不要 → 还是要备份，因为"不要"这个判断可能改主意。
  3. 有没有 /data/adb 下的重要状态（模块、隐藏列表、白名单）需要先导出？
  4. 目标内核的 KMI 与设备当前 KMI 是否一致？
     Android 16 → Linux 6.12.23 / KMI 5；Android 17 → Linux 6.12.69 / KMI 6。
     KMI 不匹配时，厂商预编译模块会拒绝加载。
TXT
