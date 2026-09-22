#!/usr/bin/env python3
"""生成对照网页的数据。

设计要点：**光说"我们的 mel 和 librosa 一致"没有说服力**——
必须同时给出"错误做法差多少"，读者才知道"一致"意味着什么。
所以这里生成三组 mel：

  A. moonvoice（我们的实现：Slaney 标度 + Slaney 面积归一化）
  B. librosa（参照实现，同参数）—— 用来验证 A
  C. **错误变体**（HTK 标度 / 不做面积归一化）—— 对照组，说明偏差量级

网页把 A/B 的差与 C 的差用**同一色标**画出来，差异一眼可见。

用法：
    python demo/gen_demo.py
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys

import librosa
import numpy as np
import soundfile as sf

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEMO = ROOT / "demo"
WAV = DEMO / "audio.wav"
OUT = DEMO / "data.json"

SR = 16000
N_FFT = 512
HOP = 256
N_MELS = 40
SECONDS = 3.0


def synth_audio() -> np.ndarray:
    """3 秒素材：0.4s 静音 → 1.0s 语音样 → 0.5s 静音+噪声突发 → 0.6s 语音样 → 静音

    刻意包含三样东西：语音段（考验 mel 分辨）、静音段（考验 VAD 门控）、
    噪声突发（考验"能量法会误判、谱法能否决"）。
    """
    n = int(SR * SECONDS)
    t = np.arange(n) / SR
    x = np.zeros(n)
    rng = np.random.default_rng(20260922)

    def voice(a: float, b: float, f0: float):
        m = (t >= a) & (t < b)
        tt = t[m] - a
        harm = sum((1.0 / k) * np.sin(2 * np.pi * f0 * k * tt) for k in range(1, 13))
        env = 0.55 + 0.45 * np.sin(2 * np.pi * 4 * tt)
        x[m] += 0.25 * harm * np.clip(env, 0.3, None)

    voice(0.4, 1.4, 120.0)
    voice(2.1, 2.7, 145.0)
    # 噪声突发（考察 VAD 的谱否决）
    m = (t >= 1.5) & (t < 1.75)
    x[m] += 0.12 * rng.standard_normal(m.sum())
    # 底噪
    x += 0.002 * rng.standard_normal(n)
    peak = np.max(np.abs(x))
    if peak > 0:
        x = x / peak * 0.7
    return np.round(x * 32767.0).astype(np.int16)


def run_moonbit_dump(wav: pathlib.Path) -> dict:
    """调我们的实现（wasm）导出中间量"""
    cmd = [
        "moon", "run", "--target", "wasm", "tools/dump", "--",
        "--n-fft", str(N_FFT), "--hop", str(HOP), "--n-mels", str(N_MELS),
    ]
    raw = wav.read_bytes()
    proc = subprocess.run(cmd, input=raw, capture_output=True, cwd=str(ROOT))
    if proc.returncode != 0:
        sys.exit("moonbit dump 失败:\n" + proc.stderr.decode("utf-8", "ignore")[-2000:])
    return json.loads(proc.stdout.decode("utf-8"))


def mel_db(x: np.ndarray, **kw) -> np.ndarray:
    m = librosa.feature.melspectrogram(
        y=x, sr=SR, n_fft=N_FFT, hop_length=HOP, window="hann",
        center=False, power=2.0, n_mels=N_MELS, **kw,
    )
    return librosa.power_to_db(m, ref=1.0, top_db=80.0)


def main() -> None:
    DEMO.mkdir(exist_ok=True)
    xi = synth_audio()
    x = xi.astype(np.float64) / 32768.0
    sf.write(str(WAV), xi, SR, subtype="PCM_16")

    ours = run_moonbit_dump(WAV)
    frames = ours["frames"]

    # A. 我们的（已是 dB），按帧优先扁平存储 → 转成 (frames, n_mels)
    ours_db = np.array(ours["log_mel"]).reshape(frames, N_MELS)

    # B. 参照实现（同参数）
    ref_db = mel_db(x).T[:frames]

    # C. 对照组：两种常见错误做法
    htk_db = mel_db(x, htk=True).T[:frames]                    # 用错 mel 标度
    nonorm_db = mel_db(x, norm=None).T[:frames]                # 不做面积归一化

    diff_ours = np.abs(ours_db - ref_db)
    diff_htk = np.abs(htk_db - ref_db)
    diff_nonorm = np.abs(nonorm_db - ref_db)

    data = {
        "meta": {
            "sample_rate": SR,
            "bins": ours["bins"],
            "n_fft": N_FFT,
            "hop": HOP,
            "n_mels": N_MELS,
            "frames": int(frames),
            "duration_ms": ours["duration_ms"],
            "speech_ms": ours["speech_ms"],
            "segments": ours["segments"],
            "generated_by": "demo/gen_demo.py",
        },
        "waveform": [float(v) for v in x[::16]],          # 抽稀到 1 kHz 便于网页绘制
        # 构造真值：与 synth_audio 里的 voice() 调用一一对应（网页画蓝虚线用）
        "truth_ms": [{"start_ms": 400, "end_ms": 1400}, {"start_ms": 2100, "end_ms": 2700}],
        "waveform_stride": 16,
        "spectrogram_db": [float(v) for v in
                           20 * np.log10(np.maximum(np.array(ours["stft_mag"]).reshape(frames, -1), 1e-6)).reshape(-1)],
        "mel": {
            "ours": [float(v) for v in ours_db.reshape(-1)],
            "ref": [float(v) for v in ref_db.reshape(-1)],
            "htk": [float(v) for v in htk_db.reshape(-1)],
            "nonorm": [float(v) for v in nonorm_db.reshape(-1)],
        },
        "stats": {
            "ours_vs_ref": {
                "max_abs_db": float(diff_ours.max()),
                "mean_abs_db": float(diff_ours.mean()),
            },
            "htk_vs_ref": {
                "max_abs_db": float(diff_htk.max()),
                "mean_abs_db": float(diff_htk.mean()),
            },
            "nonorm_vs_ref": {
                "max_abs_db": float(diff_nonorm.max()),
                "mean_abs_db": float(diff_nonorm.mean()),
            },
        },
    }
    OUT.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    build_page(data)
    print(f"生成 {OUT.relative_to(ROOT)}（{OUT.stat().st_size / 1024:.0f} KB）")
    print(f"  帧数 {frames}，mel {N_MELS}")
    # 注意用科学计数法：与参照的差异在 1e-7 量级（f32 输入精度的地板），
    # 用 %.4f 打印会显示成 0.0000，那是显示精度的假象。
    print(f"  A(我们) vs B(librosa) : 最大 {diff_ours.max():.3e} dB / 平均 {diff_ours.mean():.3e} dB")
    print(f"  C1(HTK 标度) vs B     : 最大 {diff_htk.max():.4f} dB / 平均 {diff_htk.mean():.4f} dB")
    print(f"  C2(无归一化) vs B     : 最大 {diff_nonorm.max():.4f} dB / 平均 {diff_nonorm.mean():.4f} dB")
    print(f"  （A 的差异量级 = f32 样本精度的地板；C 的差异是设计层面的系统性偏差）")


def build_page(data: dict) -> None:
    """把数据与音频内嵌进模板，产出**单文件 HTML**（双击即可打开，无需起服务器）。

    为什么内嵌而不是 fetch：file:// 下浏览器会拦掉本地 fetch（CORS），
    而"要能直接打开看"是这个演示页的第一要求。
    """
    import base64

    tpl = (DEMO / "page_template.html").read_text(encoding="utf-8")
    audio_b64 = base64.b64encode(WAV.read_bytes()).decode("ascii")
    html = tpl.replace("__AUDIO_SRC__", "data:audio/wav;base64," + audio_b64)
    html = html.replace("__DATA__", json.dumps(data, ensure_ascii=False))
    out = DEMO / "index.html"
    out.write_text(html, encoding="utf-8")
    print(f"生成 {out.relative_to(ROOT)}（{out.stat().st_size / 1024:.0f} KB，单文件可双击打开）")


if __name__ == "__main__":
    main()
