#!/usr/bin/env python3
"""ab-stats.py — 判断 A/B 两组测量值之间的差异是否真实存在。

为什么需要它：手机上的功耗与性能测量里，最常见的错误不是测错，而是
**从噪声里读出结论**。跑 3 次取平均，发现新内核"省电 2%"，实际上那
2% 完全在测量噪声里。本脚本把"这个差异能不能算数"变成一个数字判断。

规则（写在代码里，不靠记忆）：
  * 先算控制组的变异系数 CV = std/mean。CV 就是这台设备的噪声地板。
  * 主判据：比值的 bootstrap 95% 置信区间是否跨 1.0（不是 p 值）。
  * CI 跨过 1.0 → 测不出来。CI 排除 1.0 才算"有证据"。
  * |Δ| < 2×CV 是**幅度提醒**，不是判据：这时即使 CI 排除 1.0，也只能
    判"暂时通过/暂时无差异"，必须再独立复测一轮。顺序不能颠倒——
    先拿 2×CV 否掉结论，会把一个已经被 CI 证实的真实小效应误判成
    "测不出来"（本脚本早期版本就犯过这个错）。
  * 样本量建议 n/臂 ≈ 15.7 × (CV/Δ)²。

用法:
  python3 ab-stats.py --a stock.txt --b modded.txt --metric energy
  python3 ab-stats.py --a a.txt --b b.txt --metric throughput --draw 20000
  # 文件里每行一个测量值，允许空行与 # 注释

退出码: 0 = 有可判定的结论；3 = 测不出来（噪声大于效应）；2 = 用法错误
"""

import argparse
import random
import statistics
import sys

# Windows 控制台默认是 GBK，输出里的 × ≈ Δ 之类字符会让脚本在最后一步崩掉。
# 这个脚本要在手机（UTF-8）和电脑（可能是 GBK）上都跑得完。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# 判据阈值，集中在这里便于调整与审查
THRESH = {
    # metric: (更好方向, 通过阈值, 无差异区间)
    "energy":     ("lower",  0.97, (0.97, 1.03)),   # E_uj/work，越低越省电
    "throughput": ("higher", 1.02, (0.98, 1.02)),
    "latency":    ("lower",  1.05, (0.95, 1.05)),   # p99 允许劣化到 1.05
}


def read_values(path):
    vals = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            ln = ln.split("#", 1)[0].strip()
            if not ln:
                continue
            try:
                vals.append(float(ln))
            except ValueError:
                print(f"  [警告] 跳过无法解析的行: {ln!r}", file=sys.stderr)
    return vals


def bootstrap_ratio_ci(a, b, draws, rng):
    """对 median(b)/median(a) 做 bootstrap，返回 (low, high, point)。"""
    ma, mb = statistics.median(a), statistics.median(b)
    point = mb / ma if ma else float("nan")
    n_a, n_b = len(a), len(b)
    out = []
    for _ in range(draws):
        sa = [a[rng.randrange(n_a)] for _ in range(n_a)]
        sb = [b[rng.randrange(n_b)] for _ in range(n_b)]
        da, db = statistics.median(sa), statistics.median(sb)
        if da:
            out.append(db / da)
    out.sort()
    lo = out[int(0.025 * len(out))]
    hi = out[int(0.975 * len(out)) - 1]
    return lo, hi, point


def cv_of(vals):
    if len(vals) < 2:
        return float("nan")
    m = statistics.mean(vals)
    return statistics.stdev(vals) / m if m else float("nan")


def main():
    ap = argparse.ArgumentParser(description="A/B 测量值的比值与 bootstrap 置信区间")
    ap.add_argument("--a", required=True, help="基线（对照组）测量值文件，每行一个")
    ap.add_argument("--b", required=True, help="改动组测量值文件，每行一个")
    ap.add_argument("--metric", default="energy", choices=sorted(THRESH))
    ap.add_argument("--draw", type=int, default=10000, help="bootstrap 次数（默认 10000）")
    ap.add_argument("--target-delta", type=float, default=None,
                    help="想分辨的最小相对差异，如 0.03 表示 3%%；给了才算样本量建议")
    args = ap.parse_args()

    a, b = read_values(args.a), read_values(args.b)
    if len(a) < 3 or len(b) < 3:
        print("每组至少需要 3 个测量值（拿 CV 都拿不到就不要谈结论）", file=sys.stderr)
        return 2

    rng = random.Random(20260101)  # 固定种子，让同样的数据得到同样的结论

    print("=== 原始数据 ===")
    for name, v in (("A 基线", a), ("B 改动", b)):
        print(f"  {name}: n={len(v)}  median={statistics.median(v):.6g}  "
              f"mean={statistics.mean(v):.6g}  CV={cv_of(v)*100:.2f}%")

    cv_a, cv_b = cv_of(a), cv_of(b)
    cv = max(cv_a, cv_b)
    print(f"  噪声地板 CV = {cv*100:.2f}%（取两组较大者）")

    lo, hi, point = bootstrap_ratio_ci(a, b, args.draw, rng)
    delta = point - 1.0
    print()
    print("=== 比值 B/A（median(B)/median(A)） ===")
    print(f"  点估计 = {point:.4f}  ({(delta)*100:+.2f}%)")
    print(f"  bootstrap {args.draw} 次 95% CI = [{lo:.4f}, {hi:.4f}]")
    print(f"  CI 是否跨 1.0 = {'是' if lo <= 1.0 <= hi else '否'}")

    direction, threshold, midband = THRESH[args.metric]
    print()
    print(f"=== 判据（metric={args.metric}，更好方向={direction}，通过阈值={threshold}） ===")

    # 先做阈值/区间判定，再由置信区间决定这份判定算不算数。
    # 顺序很关键：CI 是主判据，2×CV 只是对幅度的一句提醒。
    crossed = lo <= 1.0 <= hi
    in_midband = midband[0] < point < midband[1]
    if direction == "lower":
        meets_threshold = point <= threshold and hi < 1.0
    else:  # higher 更好
        meets_threshold = point >= threshold and lo > 1.0
    marginal = abs(delta) < 2 * cv

    verdict = None
    if crossed:
        print("  结论: 测不出来。置信区间跨过 1.0，这个差异分不出是不是噪声。")
        print("        这不是「没差别」，而是「这台设备、这个样本量分辨不了」。")
        print("        要么加大样本量，要么换一个效应更大的改动。")
        verdict = "inconclusive"
    else:
        if meets_threshold:
            print(f"  结论: 通过。比值 {point:.4f} 达到阈值 {threshold}，"
                  f"且 CI [{lo:.4f}, {hi:.4f}] 整体落在 1.0 的好的一侧。")
            verdict = "pass"
        elif in_midband:
            print(f"  结论: 无差异。比值 {point:.4f} 落在无差异区间 {midband}。")
            verdict = "no-difference"
        else:
            print(f"  结论: 未通过。比值 {point:.4f} 未达到 {threshold}。")
            verdict = "fail"

        if marginal:
            print(f"  注意: |Δ|={abs(delta)*100:.2f}% < 2×CV={2*cv*100:.2f}%，"
                  "幅度贴着噪声地板。")
            print("        置信区间已排除 1.0（有统计证据），但这么小的效应很容易")
            print("        被温度漂移、后台进程、频点差异伪造。结论降级为「暂时」，")
            print("        必须再独立复测一轮才算数。")
            verdict = "marginal-" + verdict

    if cv == cv and cv > 0:
        print()
        print("=== 样本量建议 ===")
        print("  n/branch ≈ 15.7 × (CV/Δ)^2   （n 为每臂样本数）")
        for d in ([args.target_delta] if args.target_delta else [0.02, 0.03, 0.05, 0.10]):
            need = 15.7 * (cv / d) ** 2
            print(f"    想分辨 Δ={d*100:.1f}%  →  每臂约 {need:.0f} 次"
                  f"{'（当前样本量不足）' if need > min(len(a), len(b)) else '（当前样本量够）'}")

    print()
    print("提醒：本脚本只处理数字。它无法发现的是——两端测量条件不一致")
    print("      （不同温度、不同网络、不同 tunable、没有交叉配对 A B A B）。")
    print("      条件不一致时，再漂亮的 CI 也没有意义。")

    return 3 if verdict == "inconclusive" else 0


if __name__ == "__main__":
    sys.exit(main())
