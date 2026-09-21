#!/usr/bin/env python3
"""生成 feature 包的谱学金标（窗函数 / STFT / mel / MFCC / 谱特征）。

与 gen_audio_golden.py 分开：金标来源不同（这里是 scipy.signal.windows、
numpy.fft、librosa、scipy.fftpack），拆开后可各自单独重跑。

对拍约定（决定数值，写清楚免得后人以为对不上是 bug）：
- STFT 用**周期窗**（scipy/librosa 默认 fftbins=True），帧起点 0, hop, 2*hop, ...
  不做中心填充（librosa 的 center=True 要显式关掉）
- mel 用 Slaney 标度 + Slaney 面积归一化（librosa 默认）
- MFCC = log-mel(dB) 再做正交归一 DCT-II（librosa.feature.mfcc(S=...))

用法：
    python tools/golden/gen_spectral_golden.py
"""

from __future__ import annotations

import json
import pathlib

import librosa
import numpy as np
import scipy.fftpack
import scipy.signal.windows as win

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT_MBT = ROOT / "feature" / "golden_spectral_test.mbt"
MANIFEST = ROOT / "fixtures" / "audio" / "manifest.json"

WINDOW_N = 16
STFT_N = 512
STFT_HOP = 128
SAMPLE_RATE = 16000
N_MELS = 13
N_MFCC = 13
SIG_LEN = 4000


def fmt_double(v: float) -> str:
    if v == 0.0:
        return "0.0"
    if v == int(v) and abs(v) < 1e15:
        return f"{v:.1f}"
    return repr(float(v))


def mbt_array(values, per_line: int = 8) -> str:
    """MoonBit 对单行长度有限制，长数组必须换行（错误 0033）。"""
    vals = [fmt_double(float(v)) for v in values]
    if len(vals) <= per_line:
        return ", ".join(vals)
    lines = []
    for i in range(0, len(vals), per_line):
        chunk = ", ".join(vals[i : i + per_line])
        end = "," if i + per_line < len(vals) else ""
        lines.append("    " + chunk + end)
    return "\n" + "\n".join(lines) + "\n  "


def mbt_int_array(values, per_line: int = 16) -> str:
    vals = [str(int(v)) for v in values]
    if len(vals) <= per_line:
        return ", ".join(vals)
    lines = []
    for i in range(0, len(vals), per_line):
        chunk = ", ".join(vals[i : i + per_line])
        end = "," if i + per_line < len(vals) else ""
        lines.append("    " + chunk + end)
    return "\n" + "\n".join(lines) + "\n  "


def test_signal() -> np.ndarray:
    """确定性的测试信号：两个正弦 + 低频调幅（模拟语音的音节起伏）"""
    n = np.arange(SIG_LEN)
    env = 0.5 + 0.5 * np.sin(2 * np.pi * 4.0 * n / SAMPLE_RATE)
    x = env * (
        0.5 * np.sin(2 * np.pi * 440.0 * n / SAMPLE_RATE)
        + 0.3 * np.sin(2 * np.pi * 1500.0 * n / SAMPLE_RATE)
        + 0.1 * np.sin(2 * np.pi * 3000.0 * n / SAMPLE_RATE)
    )
    xi = np.round(x * 10000.0).astype(np.int32)
    return xi


def main() -> None:
    lines: list[str] = []

    def add(t: str = "") -> None:
        lines.append(t)

    add("///|")
    add("/// **自动生成，请勿手改** —— 由 tools/golden/gen_spectral_golden.py 生成。")
    add("///")
    add("/// 期望值来源：scipy.signal.windows / numpy.fft / librosa / scipy.fftpack。")
    add("/// 注意：STFT 用的是**周期窗**（与 scipy/librosa 默认一致），不是对称窗。")
    add("")

    # --- 窗函数（对称与周期各一套） ---
    add(f"///| 窗长度（n={WINDOW_N}）")
    add("fn golden_window_len() -> Int {")
    add(f"  {WINDOW_N}")
    add("}")
    add("")
    for name, w in {
        "hann": win.hann(WINDOW_N, sym=True),
        "hamming": win.hamming(WINDOW_N, sym=True),
        "blackman": win.blackman(WINDOW_N, sym=True),
        "bartlett": win.bartlett(WINDOW_N, sym=True),
        "kaiser6": win.kaiser(WINDOW_N, 6.0, sym=True),
    }.items():
        add(f"///| {name}（对称）")
        add(f"fn golden_window_{name}() -> Array[Double] {{")
        add("  [" + mbt_array(w) + "]")
        add("}")
        add("")
    for name, w in {
        "hann": win.hann(WINDOW_N, sym=False),
        "hamming": win.hamming(WINDOW_N, sym=False),
        "blackman": win.blackman(WINDOW_N, sym=False),
        "bartlett": win.bartlett(WINDOW_N, sym=False),
        "kaiser6": win.kaiser(WINDOW_N, 6.0, sym=False),
    }.items():
        add(f"///| {name}（周期，STFT 用）")
        add(f"fn golden_window_periodic_{name}() -> Array[Double] {{")
        add("  [" + mbt_array(w) + "]")
        add("}")
        add("")

    # --- 测试信号 ---
    xi = test_signal()
    x = xi.astype(np.float64) / 10000.0
    add("///| 测试信号：双正弦 + 4 Hz 调幅，量化到 1/10000")
    add("fn golden_sig_input() -> Array[Int] {")
    add("  [" + mbt_int_array(xi) + "]")
    add("}")
    add("")

    # --- STFT（周期窗） ---
    w_periodic = win.hann(STFT_N, sym=False)
    n_frames = (SIG_LEN - STFT_N) // STFT_HOP + 1
    mags = []
    for f in range(n_frames):
        seg = x[f * STFT_HOP : f * STFT_HOP + STFT_N] * w_periodic
        mags.append(np.abs(np.fft.rfft(seg)))
    mags = np.array(mags)

    add("///| (n_fft, hop, 帧数)")
    add("fn golden_stft_meta() -> (Int, Int, Int) {")
    add(f"  ({STFT_N}, {STFT_HOP}, {n_frames})")
    add("}")
    add("")
    add("///| 逐帧幅度谱（帧优先，帧数 × n_fft/2+1）")
    add("fn golden_stft_magnitude() -> Array[Double] {")
    add("  [" + mbt_array(mags.reshape(-1)) + "]")
    add("}")

    # --- mel 滤波器组 ---
    mel_basis = librosa.filters.mel(
        sr=SAMPLE_RATE, n_fft=STFT_N, n_mels=N_MELS, fmin=0.0, norm="slaney", htk=False
    )
    add("")
    add("///| (n_mels, n_fft)")
    add("fn golden_mel_meta() -> (Int, Int, Int) {")
    add(f"  ({N_MELS}, {STFT_N}, {SAMPLE_RATE})")
    add("}")
    add("")
    add("///| mel 滤波器组矩阵（n_mels × n_fft/2+1，Slaney 归一化）")
    add("fn golden_mel_matrix() -> Array[Double] {")
    add("  [" + mbt_array(mel_basis.reshape(-1)) + "]")
    add("}")

    # --- log-mel 与 MFCC ---
    S = librosa.feature.melspectrogram(
        y=x,
        sr=SAMPLE_RATE,
        n_fft=STFT_N,
        hop_length=STFT_HOP,
        window="hann",
        center=False,
        power=2.0,
        n_mels=N_MELS,
    )
    S_db = librosa.power_to_db(S, ref=1.0, top_db=80.0)
    mfcc = librosa.feature.mfcc(S=S_db, n_mfcc=N_MFCC)

    add("")
    add("///| log-mel（dB）（帧优先，帧数 × n_mels）")
    add("fn golden_log_mel() -> Array[Double] {")
    add("  [" + mbt_array(S_db.T.reshape(-1)) + "]")
    add("}")
    add("")
    add(f"///| MFCC（前 {N_MFCC} 个系数，帧优先）")
    add("fn golden_mfcc() -> Array[Double] {")
    add("  [" + mbt_array(mfcc.T.reshape(-1)) + "]")
    add("}")

    # --- DCT-II ---
    dct_in = np.array([1.0, 2.0, 3.0, 4.0, 5.0, 4.0, 3.0, 2.0])
    dct_out = scipy.fftpack.dct(dct_in, type=2, norm="ortho")
    add("")
    add("///| DCT-II 输入")
    add("fn golden_dct_input() -> Array[Double] {")
    add("  [" + mbt_array(dct_in) + "]")
    add("}")
    add("")
    add("///| DCT-II 输出（scipy.fftpack.dct type=2 norm='ortho'）")
    add("fn golden_dct_expected() -> Array[Double] {")
    add("  [" + mbt_array(dct_out) + "]")
    add("}")

    # --- 谱特征（用 librosa 的谱特征做参照） ---
    S_mag = np.abs(librosa.stft(x, n_fft=STFT_N, hop_length=STFT_HOP, window="hann", center=False))
    power = S_mag**2
    freqs = np.fft.rfftfreq(STFT_N, 1.0 / SAMPLE_RATE)
    total = power.sum(axis=0)
    centroid = (freqs[:, None] * power).sum(axis=0) / total
    bandwidth = np.sqrt(((freqs[:, None] - centroid) ** 2 * power).sum(axis=0) / total)
    cum = np.cumsum(power, axis=0)
    roll_idx = np.argmax(cum >= 0.85 * total, axis=0)
    rolloff = freqs[roll_idx]
    # 取第 3 帧作为样本（避开首帧边界）
    frame_idx = 3
    add("")
    add("///| 谱特征参照：质心/带宽/滚降（Hz），取自第 3 帧")
    add("fn golden_spectral_expected() -> (Double, Double, Double) {")
    add(
        f"  ({fmt_double(float(centroid[frame_idx]))}, "
        f"{fmt_double(float(bandwidth[frame_idx]))}, "
        f"{fmt_double(float(rolloff[frame_idx]))})"
    )
    add("}")
    add("")
    add(f"///| 该帧号")
    add("fn golden_spectral_frame_index() -> Int {")
    add(f"  {frame_idx}")
    add("}")
    add("")

    OUT_MBT.write_text("\n".join(lines), encoding="utf-8")
    print(f"生成 {OUT_MBT.relative_to(ROOT)}")
    print(f"  · 窗：10 个（对称 5 + 周期 5）")
    print(f"  · STFT：{n_frames} 帧 × {STFT_N // 2 + 1} 频点")
    print(f"  · mel：{N_MELS} × {STFT_N // 2 + 1}，log-mel 与 MFCC {n_frames} 帧")
    print(f"  · DCT-II 与谱特征各 1 组")

    data = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.exists() else {"cases": []}
    data["cases"] = [c for c in data.get("cases", []) if c.get("kind") != "spectral"]
    data["cases"].append({
        "kind": "spectral",
        "windows": ["hann", "hamming", "blackman", "bartlett", "kaiser6"],
        "stft": {"n_fft": STFT_N, "hop": STFT_HOP, "frames": int(n_frames), "window": "periodic hann"},
        "mel": {"n_mels": N_MELS, "norm": "slaney", "scale": "slaney"},
        "mfcc": {"n_mfcc": N_MFCC},
        "expected_source": "scipy.signal.windows + numpy.fft + librosa + scipy.fftpack",
    })
    MANIFEST.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"更新 {MANIFEST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
