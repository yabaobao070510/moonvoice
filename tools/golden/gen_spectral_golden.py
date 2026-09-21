#!/usr/bin/env python3
"""生成 feature 包的窗函数与 STFT 金标。

与 gen_audio_golden.py 分开的理由：金标来源不同（这里是 scipy.signal.windows
与 numpy.fft），拆开后各自可单独重跑，也避免一个脚本越滚越大。

用法：
    python tools/golden/gen_spectral_golden.py
"""

from __future__ import annotations

import json
import pathlib

import numpy as np
import scipy.signal.windows as win

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT_MBT = ROOT / "feature" / "golden_spectral_test.mbt"
MANIFEST = ROOT / "fixtures" / "audio" / "manifest.json"

WINDOW_N = 16
STFT_N = 32
STFT_HOP = 8
STFT_LEN = 100


def fmt_double(v: float) -> str:
    if v == 0.0:
        return "0.0"
    if v == int(v) and abs(v) < 1e15:
        return f"{v:.1f}"
    return repr(float(v))


def mbt_array(values) -> str:
    return ", ".join(fmt_double(float(v)) for v in values)


def main() -> None:
    lines: list[str] = []
    add = lines.append

    add("///|")
    add("/// **自动生成，请勿手改** —— 由 tools/golden/gen_spectral_golden.py 生成。")
    add("///")
    add("/// 期望值来自 scipy.signal.windows 与 numpy.fft（独立参照实现）。")
    add("")

    # --- 窗函数 ---
    windows = {
        "hann": win.hann(WINDOW_N, sym=True),
        "hamming": win.hamming(WINDOW_N, sym=True),
        "blackman": win.blackman(WINDOW_N, sym=True),
        "bartlett": win.bartlett(WINDOW_N, sym=True),
        "kaiser6": win.kaiser(WINDOW_N, 6.0, sym=True),
    }
    add(f"///| 窗系数（n={WINDOW_N}）")
    add("fn golden_window_len() -> Int {")
    add(f"  {WINDOW_N}")
    add("}")
    add("")
    for name, w in windows.items():
        add(f"///| {name}")
        add(f"fn golden_window_{name}() -> Array[Double] {{")
        add(f"  [{mbt_array(w)}]")
        add("}")
        add("")

    # --- STFT ---
    n = np.arange(STFT_LEN)
    x = 0.4 * np.sin(2 * np.pi * 3.0 * n / STFT_N) + 0.2 * np.sin(
        2 * np.pi * 7.0 * n / STFT_N
    )
    xi = np.round(x * 10000.0).astype(np.int32)
    xd = xi.astype(np.float64) / 10000.0

    w = win.hann(STFT_N, sym=True)
    n_frames = (len(xd) - STFT_N) // STFT_HOP + 1
    mags = []
    for f in range(n_frames):
        seg = xd[f * STFT_HOP : f * STFT_HOP + STFT_N] * w
        mags.append(np.abs(np.fft.rfft(seg)))
    mags = np.array(mags)

    add("///|")
    add("/// STFT 输入：100 个样本，量化到 1/10000")
    add("fn golden_stft_input() -> Array[Int] {")
    add("  [" + ", ".join(str(int(v)) for v in xi) + "]")
    add("}")
    add("")
    add("///| (n_fft, hop)")
    add("fn golden_stft_meta() -> (Int, Int) {")
    add(f"  ({STFT_N}, {STFT_HOP})")
    add("}")
    add("")
    add("///| 逐帧幅度谱，帧优先排列（帧数 × (n_fft/2+1)）")
    add("fn golden_stft_magnitude() -> Array[Double] {")
    add("  [" + mbt_array(mags.reshape(-1)) + "]")
    add("}")
    add("")

    OUT_MBT.write_text("\n".join(lines), encoding="utf-8")
    print(f"生成 {OUT_MBT.relative_to(ROOT)}（{len(windows)} 个窗 + 1 组 STFT）")

    # 追加到 manifest（保持单一事实来源）
    if MANIFEST.exists():
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    else:
        data = {"cases": []}
    data["cases"] = [c for c in data.get("cases", []) if c.get("kind") != "spectral"]
    data["cases"].append({
        "kind": "spectral",
        "windows": list(windows.keys()),
        "stft": {"n_fft": STFT_N, "hop": STFT_HOP, "frames": int(n_frames)},
        "expected_source": "scipy.signal.windows + numpy.fft.rfft",
    })
    MANIFEST.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"更新 {MANIFEST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
