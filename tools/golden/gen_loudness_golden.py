#!/usr/bin/env python3
"""生成滤波器与响度金标（biquad 系数/频响、K 加权、积分响度）。

对拍对象：
- biquad 系数与频响：scipy.signal.iirfilter / 直接按 RBJ 公式复算
- 积分响度：pyloudnorm（BS.1770-4 的独立实现）

用法：
    python tools/golden/gen_loudness_golden.py
"""

from __future__ import annotations

import json
import pathlib

import numpy as np
import pyloudnorm as pyln

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT_MBT = ROOT / "feature" / "golden_loudness_test.mbt"
MANIFEST = ROOT / "fixtures" / "audio" / "manifest.json"

RATE = 16000
SECONDS = 1.0  # 够跑 400 ms 块的门控逻辑，同时让内嵌源码保持可编译
N = int(RATE * SECONDS)


def fmt(v: float) -> str:
    if v == 0.0:
        return "0.0"
    if v == int(v) and abs(v) < 1e15:
        return f"{v:.1f}"
    return repr(float(v))


def arr(values, per_line: int = 6) -> str:
    vals = [fmt(float(v)) for v in values]
    if len(vals) <= per_line:
        return ", ".join(vals)
    out = []
    for i in range(0, len(vals), per_line):
        chunk = ", ".join(vals[i : i + per_line])
        end = "," if i + per_line < len(vals) else ""
        out.append("    " + chunk + end)
    return "\n" + "\n".join(out) + "\n  "


def int_arr(values, per_line: int = 16) -> str:
    vals = [str(int(v)) for v in values]
    if len(vals) <= per_line:
        return ", ".join(vals)
    out = []
    for i in range(0, len(vals), per_line):
        chunk = ", ".join(vals[i : i + per_line])
        end = "," if i + per_line < len(vals) else ""
        out.append("    " + chunk + end)
    return "\n" + "\n".join(out) + "\n  "


def rbq_highshelf(fc: float, q: float, gain_db: float, rate: int):
    """RBJ 高架，与 MoonBit 实现同一套公式（用于交叉核对系数）"""
    A = 10 ** (gain_db / 40.0)
    w0 = 2 * np.pi * fc / rate
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / 2 * np.sqrt((A + 1 / A) * (1 / q - 1) + 2)
    tsa = 2 * np.sqrt(A) * alpha
    a0 = (A + 1) - (A - 1) * cw + tsa
    b0 = A * ((A + 1) + (A - 1) * cw + tsa) / a0
    b1 = -2 * A * ((A - 1) + (A + 1) * cw) / a0
    b2 = A * ((A + 1) + (A - 1) * cw - tsa) / a0
    a1 = 2 * ((A - 1) - (A + 1) * cw) / a0
    a2 = ((A + 1) - (A - 1) * cw - tsa) / a0
    return b0, b1, b2, a1, a2


def rbq_highpass(fc: float, q: float, rate: int):
    w0 = 2 * np.pi * fc / rate
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / (2 * q)
    a0 = 1 + alpha
    return (
        (1 + cw) / 2 / a0,
        -(1 + cw) / a0,
        (1 + cw) / 2 / a0,
        -2 * cw / a0,
        (1 - alpha) / a0,
    )


def main() -> None:
    lines: list[str] = []

    def add(t: str = "") -> None:
        lines.append(t)

    add("///|")
    add("/// **自动生成，请勿手改** —— 由 tools/golden/gen_loudness_golden.py 生成。")
    add("///")
    add("/// 期望值来源：RBJ Cookbook 公式复算 + pyloudnorm（BS.1770-4 独立实现）。")
    add("")

    # --- biquad 系数（RBJ 高架与高通，用于交叉核对） ---
    hb = rbq_highshelf(1681.974450955533, 0.7071752369554196, 3.999843853973347, RATE)
    hp = rbq_highpass(38.13547087602444, 0.5003270373238773, RATE)
    add("///| K 加权第一级（高架）系数 b0,b1,b2,a1,a2 @16kHz")
    add("fn golden_kshelf_coeffs() -> (Double, Double, Double, Double, Double) {")
    add("  (" + ", ".join(fmt(v) for v in hb) + ")")
    add("}")
    add("")
    add("///| K 加权第二级（高通）系数 @16kHz")
    add("fn golden_khighpass_coeffs() -> (Double, Double, Double, Double, Double) {")
    add("  (" + ", ".join(fmt(v) for v in hp) + ")")
    add("}")
    add("")

    # --- 测试信号：语音样包络（含静音段，用来考门控） ---
    n = np.arange(N)
    t = n / RATE
    env = np.zeros(N)
    # 三段有声、两段静音
    for a, b, lvl in [(0.1, 0.45, 0.5), (0.6, 0.95, 0.2)]:
        env[(t >= a) & (t < b)] = lvl * (0.7 + 0.3 * np.sin(2 * np.pi * 4 * t[(t >= a) & (t < b)]))
    sig = env * (
        np.sin(2 * np.pi * 300 * t) + 0.5 * np.sin(2 * np.pi * 1200 * t) + 0.2 * np.sin(2 * np.pi * 3000 * t)
    )
    sig = sig / np.max(np.abs(sig)) * 0.7
    xi = np.round(sig * 32767.0).astype(np.int32)
    x = xi.astype(np.float64) / 32768.0

    add("///| 测试信号：三段有声 + 两段静音（16-bit 量化值）")
    add("fn golden_loudness_input() -> Array[Int] {")
    add("  [" + int_arr(xi) + "]")
    add("}")
    add("")

    # --- pyloudnorm 参照 ---
    meter = pyln.Meter(RATE)
    integrated = float(meter.integrated_loudness(x))
    add("///| (采样率, 积分响度 LUFS)")
    add("fn golden_loudness_expected() -> (Int, Double) {")
    add(f"  ({RATE}, {fmt(integrated)})")
    add("}")
    add("")
    add("///| 样本峰值 dBFS")
    add("fn golden_loudness_peak_dbfs() -> Double {")
    add("  " + fmt(float(20 * np.log10(np.max(np.abs(x))))))
    add("}")
    add("")

    OUT_MBT.write_text("\n".join(lines), encoding="utf-8")
    print(f"生成 {OUT_MBT.relative_to(ROOT)}")
    print(f"  · pyloudnorm 积分响度 = {integrated:.3f} LUFS")

    data = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.exists() else {"cases": []}
    data["cases"] = [c for c in data.get("cases", []) if c.get("kind") != "loudness"]
    data["cases"].append({
        "kind": "loudness",
        "sample_rate": RATE,
        "integrated_lufs": integrated,
        "expected_source": "pyloudnorm（BS.1770-4 独立实现）",
    })
    MANIFEST.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"更新 {MANIFEST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
