#!/usr/bin/env python3
"""Ad-hoc analysis script for the Phase-1 B-wave cross-commit re-run.

Reads verify/measurements/crosscommit_final_{refc,orc}.csv and computes,
per MM: median ratio (head/base), min-max ranges + overlap verdict,
a bootstrap 95% CI on the ratio of medians (10k resamples), and a
two-sided Mann-Whitney U p-value. Host python3, stdlib only (no numpy/
scipy dependency, so it needs nothing beyond what the container/host
already has).

Not part of the harness proper -- a one-off tool used to produce
crosscommit_final_analysis.md. Kept alongside the CSVs/analysis for
reproducibility.
"""
import csv
import random
import statistics
import sys
from pathlib import Path

random.seed(1234567)  # reproducible bootstrap

def load(path):
    base, head = [], []
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            v = float(row["ns_per_op"])
            if row["side"] == "base":
                base.append(v)
            else:
                head.append(v)
    return base, head

def bootstrap_ratio_ci(base, head, n_resamples=10000, alpha=0.05):
    ratios = []
    for _ in range(n_resamples):
        b_sample = [random.choice(base) for _ in base]
        h_sample = [random.choice(head) for _ in head]
        b_med = statistics.median(b_sample)
        h_med = statistics.median(h_sample)
        if b_med == 0:
            continue
        ratios.append(h_med / b_med)
    ratios.sort()
    lo_idx = int((alpha / 2) * len(ratios))
    hi_idx = int((1 - alpha / 2) * len(ratios)) - 1
    return ratios[lo_idx], ratios[hi_idx]

def mann_whitney_u(base, head):
    # Two-sided Mann-Whitney U, normal approximation with tie correction.
    combined = [(v, "base") for v in base] + [(v, "head") for v in head]
    combined.sort(key=lambda t: t[0])
    n1, n2 = len(base), len(head)
    n = n1 + n2
    # assign ranks, averaging ties
    ranks = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j + 1 < n and combined[j + 1][0] == combined[i][0]:
            j += 1
        avg_rank = (i + 1 + j + 1) / 2.0
        for k in range(i, j + 1):
            ranks[k] = avg_rank
        i = j + 1
    R1 = sum(r for r, (v, side) in zip(ranks, combined) if side == "base")
    U1 = R1 - n1 * (n1 + 1) / 2.0
    U2 = n1 * n2 - U1
    U = min(U1, U2)
    mu = n1 * n2 / 2.0
    # tie correction
    tie_term = 0.0
    i = 0
    while i < n:
        j = i
        while j + 1 < n and combined[j + 1][0] == combined[i][0]:
            j += 1
        t = j - i + 1
        if t > 1:
            tie_term += t ** 3 - t
        i = j + 1
    sigma2 = (n1 * n2 / 12.0) * ((n + 1) - tie_term / (n * (n - 1))) if n > 1 else 0
    sigma = sigma2 ** 0.5 if sigma2 > 0 else 0
    if sigma == 0:
        return U, float("nan")
    z = (U - mu) / sigma
    # two-sided p-value via normal approx (erf)
    import math
    p = 2 * (1 - 0.5 * (1 + math.erf(abs(z) / math.sqrt(2))))
    return U, p

def analyze(mm, path):
    base, head = load(path)
    b_med = statistics.median(base)
    h_med = statistics.median(head)
    ratio = h_med / b_med
    b_range = (min(base), max(base))
    h_range = (min(head), max(head))
    overlap = not (h_range[0] > b_range[1] or h_range[1] < b_range[0])
    ci_lo, ci_hi = bootstrap_ratio_ci(base, head)
    U, p = mann_whitney_u(base, head)
    print(f"=== {mm} ===")
    print(f"  n = {len(base)} per side")
    print(f"  base median: {b_med:.2f} ns/op  range [{b_range[0]:.1f}, {b_range[1]:.1f}]")
    print(f"  head median: {h_med:.2f} ns/op  range [{h_range[0]:.1f}, {h_range[1]:.1f}]")
    print(f"  ratio (head/base median): {ratio:.3f}x")
    print(f"  overlap: {overlap}")
    print(f"  bootstrap 95% CI on ratio of medians (n=10000): [{ci_lo:.3f}, {ci_hi:.3f}]")
    print(f"  Mann-Whitney U = {U:.1f}, two-sided p = {p:.4f}")
    print()
    return dict(mm=mm, b_med=b_med, h_med=h_med, ratio=ratio, b_range=b_range,
                h_range=h_range, overlap=overlap, ci=(ci_lo, ci_hi), U=U, p=p,
                n=len(base))

if __name__ == "__main__":
    d = Path(__file__).parent
    results = []
    for mm, fname in [("refc", "crosscommit_final_refc.csv"), ("orc", "crosscommit_final_orc.csv")]:
        results.append(analyze(mm, d / fname))
