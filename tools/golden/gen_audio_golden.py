#!/usr/bin/env python3
"""生成 audio / resample / feature 三个包的金标测试。

设计原则（同时写进 README 与开发复盘）：

1. **参照物必须独立**。WAV fixture 由 ffmpeg 生成、期望值由 libsndfile 独立解码；
   重采样期望值由 scipy.signal.resample_poly 给出；频谱期望值由 numpy.fft 给出。
   都不是"拿自己的公式算一遍再自我验证"。
2. **测试不依赖文件 I/O**。数据以十六进制/字面量内嵌进生成的 .mbt 源码，
   这样 wasm / js / native 三个后端都能跑同一套金标（wasm 沙箱里没有文件系统）。
3. **可复现**。WAV fixture 同时落盘到 fixtures/audio/，任何人可重跑本脚本复核。

用法：
    python tools/golden/gen_audio_golden.py
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys

import numpy as np
import scipy.signal
import soundfile as sf

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "fixtures" / "audio"
AUDIO_MBT = ROOT / "audio" / "golden_data_test.mbt"
RESAMPLE_MBT = ROOT / "resample" / "golden_data_test.mbt"
FEATURE_MBT = ROOT / "feature" / "golden_data_test.mbt"
OUT_META = FIXTURES / "manifest.json"

# (名称, ffmpeg 采样格式, 声道, 采样率, 说明)
WAV_CASES = [
    ("sine_u8_mono", "pcm_u8", 1, 8000, "8-bit 无符号"),
    ("sine_s16_mono", "pcm_s16le", 1, 16000, "16-bit 有符号"),
    ("sine_s24_mono", "pcm_s24le", 1, 16000, "24-bit 有符号"),
    ("sine_s32_mono", "pcm_s32le", 1, 16000, "32-bit 有符号"),
    ("sine_f32_mono", "pcm_f32le", 1, 16000, "32-bit 浮点"),
    ("sine_f64_mono", "pcm_f64le", 1, 16000, "64-bit 浮点"),
    ("sine_s16_stereo", "pcm_s16le", 2, 16000, "16-bit 立体声（交错）"),
]

DURATION = 0.025  # 秒。短样本足够覆盖解析路径，且让内嵌数据保持可读。

# 重采样金标：(名称, 输入采样率, 输出采样率, 时长秒)
RESAMPLE_CASES = [
    ("resample_48k_to_16k", 48000, 16000, 0.05),
    ("resample_44100_to_48000", 44100, 48000, 0.05),
]

# 通带内分量：全部低于输出 Nyquist 的 0.45 倍，确保比较的是"通带保真"而非过渡带设计差异
TONE_HZ = [220.0, 700.0, 1500.0, 3000.0]
TONE_AMP = [0.4, 0.3, 0.2, 0.1]

# 频谱金标
FFT_N = 512
FFT_RATE = 16000
FFT_FREQS = [440.0, 1500.0, 3300.0]
FFT_AMPS = [0.5, 0.3, 0.2]

HELPERS = r'''
///| 十六进制字符串 → 字节（解析失败即测试失败，不静默产出坏数据）
fn unhex(s : String) -> Bytes raise {
  let digits = "0123456789abcdef".to_array()
  let chars = s.to_array()
  let n = chars.length() / 2
  let out : FixedArray[Byte] = FixedArray::make(n, byte_zero())
  for i = 0; i < n; i = i + 1 {
    let hi = hex_val(digits, chars[i * 2])
    let lo = hex_val(digits, chars[i * 2 + 1])
    out[i] = (hi * 16 + lo).to_byte()
  }
  Bytes::from_array(out)
}

fn byte_zero() -> Byte {
  b'\x00'
}

fn hex_val(digits : Array[Char], c : Char) -> Int raise {
  for i = 0; i < 16; i = i + 1 {
    if digits[i] == c {
      return i
    }
  }
  fail("bad hex digit")
}
'''


def fmt_double(v: float) -> str:
    if v == 0.0:
        return "0.0"
    if v == int(v) and abs(v) < 1e15:
        return f"{v:.1f}"
    return repr(float(v))


def ffmpeg_bin() -> str:
    for name in ("ffmpeg", "ffmpeg.exe"):
        try:
            subprocess.run([name, "-version"], capture_output=True, check=True)
            return name
        except Exception:
            continue
    sys.exit("找不到 ffmpeg，请先安装（winget install Gyan.FFmpeg）")


def make_wav_fixture(ff: str, name: str, codec: str, channels: int, rate: int) -> pathlib.Path:
    path = FIXTURES / f"{name}.wav"
    expr = f"sine=frequency=440:sample_rate={rate}:duration={DURATION}"
    cmd = [
        ff, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", expr,
        "-ac", str(channels), "-c:a", codec, str(path),
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    return path


def emit_wav_section(manifest: list) -> str:
    ff = ffmpeg_bin()
    blocks: list[str] = []
    for name, codec, channels, rate, desc in WAV_CASES:
        path = make_wav_fixture(ff, name, codec, channels, rate)
        raw = path.read_bytes()
        samples, samplerate = sf.read(str(path), dtype="float64", always_2d=True)
        expected = samples.reshape(-1).tolist()
        assert samplerate == rate, f"{name}: 采样率不符 {samplerate} != {rate}"
        manifest.append({
            "name": name,
            "kind": "wav",
            "codec": codec,
            "channels": channels,
            "sample_rate": rate,
            "frames": len(samples),
            "bytes": len(raw),
            "expected_source": "libsndfile (soundfile) 独立解码",
        })
        values = ", ".join(fmt_double(v) for v in expected)
        blocks.append(
            "\n///| " + desc + "：ffmpeg 生成，libsndfile 解码得到期望值\n"
            "fn golden_" + name + "_wav() -> Bytes raise {\n"
            '  unhex("' + raw.hex() + '")\n'
            "}\n\n"
            "fn golden_" + name + "_expected() -> Array[Double] {\n"
            "  [" + values + "]\n"
            "}\n\n"
            "///| (采样率, 声道数, 帧数)\n"
            "fn golden_" + name + "_meta() -> (Int, Int, Int) {\n"
            f"  ({rate}, {channels}, {len(samples)})\n"
            "}\n"
        )
    return "".join(blocks)


def make_resample_input(rate: int, seconds: float):
    n = int(rate * seconds)
    t = np.arange(n) / rate
    x = np.zeros(n)
    for f, a in zip(TONE_HZ, TONE_AMP):
        x += a * np.sin(2 * np.pi * f * t)
    # 量化到 int16：输入完全可表示，排除"输入自身有误差"的干扰
    xi = np.clip(np.round(x * 32767.0), -32768, 32767).astype(np.int16)
    return xi, xi.astype(np.float64) / 32768.0


def emit_resample_section(manifest: list) -> str:
    blocks: list[str] = []
    for name, fs_in, fs_out, seconds in RESAMPLE_CASES:
        g = int(np.gcd(fs_in, fs_out))
        up, down = fs_out // g, fs_in // g
        xi, x = make_resample_input(fs_in, seconds)
        y = scipy.signal.resample_poly(x, up, down)
        manifest.append({
            "name": name,
            "kind": "resample",
            "from_rate": fs_in,
            "to_rate": fs_out,
            "up": up,
            "down": down,
            "in_frames": len(xi),
            "out_frames": len(y),
            "tones_hz": TONE_HZ,
            "expected_source": "scipy.signal.resample_poly（默认 Kaiser 设计）",
        })
        ints = ", ".join(str(int(v)) for v in xi)
        floats = ", ".join(fmt_double(v) for v in y)
        blocks.append(
            "\n///| " + str(fs_in) + " Hz → " + str(fs_out)
            + " Hz 的输入：int16 量化值（除以 32768 还原）\n"
            "fn golden_" + name + "_input() -> Array[Int] {\n"
            "  [" + ints + "]\n"
            "}\n\n"
            "///| scipy.signal.resample_poly 的输出（独立参照实现）\n"
            "fn golden_" + name + "_expected() -> Array[Double] {\n"
            "  [" + floats + "]\n"
            "}\n\n"
            "///| (输入采样率, 输出采样率)\n"
            "fn golden_" + name + "_rates() -> (Int, Int) {\n"
            f"  ({fs_in}, {fs_out})\n"
            "}\n"
        )
    return "".join(blocks)


def fft_signal():
    n = np.arange(FFT_N)
    t = n / float(FFT_RATE)
    x = np.zeros(FFT_N)
    for f, a in zip(FFT_FREQS, FFT_AMPS):
        x += a * np.sin(2 * np.pi * f * t)
    # 量化到 1/10000，保证两侧输入完全一致
    xi = np.round(x * 10000.0).astype(np.int32)
    return xi, xi.astype(np.float64) / 10000.0


def emit_feature_section(manifest: list) -> str:
    xi, x = fft_signal()
    # 与 MoonBit 侧逐字相同的 Hann 窗定义
    w = 0.5 * (1.0 - np.cos(2 * np.pi * np.arange(FFT_N) / (FFT_N - 1)))
    spec = np.abs(np.fft.rfft(x * w)) ** 2

    # 谱平坦度 / 谱熵（bin 1..100），公式与实现一致，由 numpy 复算
    band = np.maximum(spec[1:101], 1e-30)
    flatness = float(np.exp(np.mean(np.log(band))) / np.mean(band))
    p = band / band.sum()
    entropy = float(-np.sum(p * np.log(p)) / np.log(len(band)))

    manifest.append({
        "name": "fft_tones",
        "kind": "feature",
        "n_fft": FFT_N,
        "sample_rate": FFT_RATE,
        "tones_hz": FFT_FREQS,
        "expected_source": "numpy.fft.rfft + 与实现逐字相同的 Hann 窗",
        "spectral_flatness": flatness,
        "spectral_entropy": entropy,
    })

    ints = ", ".join(str(int(v)) for v in xi)
    powers = ", ".join(repr(float(v)) for v in spec)
    return (
        "\n///| 三个单音叠加（440/1500/3300 Hz），量化到 1/10000\n"
        "fn golden_fft_input() -> Array[Int] {\n  [" + ints + "]\n}\n\n"
        "///| numpy.fft.rfft 的功率谱（|X|^2，未归一化）\n"
        "fn golden_fft_expected_power() -> Array[Double] {\n  [" + powers + "]\n}\n\n"
        "///| bin 1..100 上的谱平坦度（numpy 复算）\n"
        "fn golden_fft_expect_flatness() -> Double {\n  " + repr(flatness) + "\n}\n\n"
        "///| bin 1..100 上的归一化谱熵（numpy 复算）\n"
        "fn golden_fft_expect_entropy() -> Double {\n  " + repr(entropy) + "\n}\n"
    )


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    manifest: list = []

    # --- audio：WAV 编解码 ---
    audio_header = "\n".join([
        "///|",
        "/// **自动生成，请勿手改** —— 由 tools/golden/gen_audio_golden.py 生成。",
        "///",
        "/// fixture 来源：ffmpeg；期望值来源：libsndfile —— 与被测实现无共享代码",
        "/// 内嵌而非读文件：wasm 沙箱无文件系统，三后端要跑同一套金标。",
        "",
    ])
    AUDIO_MBT.write_text(
        audio_header + emit_wav_section(manifest) + HELPERS, encoding="utf-8"
    )

    # --- resample：对比 scipy.signal.resample_poly ---
    resample_header = "\n".join([
        "///|",
        "/// **自动生成，请勿手改** —— 由 tools/golden/gen_audio_golden.py 生成。",
        "///",
        "/// 期望值来自 scipy.signal.resample_poly（独立参照实现）。",
        "/// 输入是多音信号，全部能量位于输出 Nyquist 的 0.45 倍以内，",
        "/// 因此这里比的是通带保真度——过渡带形状属我方设计自由，不作为对拍对象。",
        "",
    ])
    RESAMPLE_MBT.write_text(
        resample_header + emit_resample_section(manifest), encoding="utf-8"
    )

    # --- feature：对比 numpy.fft ---
    feature_header = "\n".join([
        "///|",
        "/// **自动生成，请勿手改** —— 由 tools/golden/gen_audio_golden.py 生成。",
        "///",
        "/// 期望值来自 numpy.fft.rfft（独立参照实现），窗函数定义与实现逐字一致。",
        "",
    ])
    FEATURE_MBT.write_text(
        feature_header + emit_feature_section(manifest), encoding="utf-8"
    )

    OUT_META.write_text(
        json.dumps({"cases": manifest}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"生成 {AUDIO_MBT.relative_to(ROOT)}（{len(WAV_CASES)} 个 WAV fixture）")
    print(f"生成 {RESAMPLE_MBT.relative_to(ROOT)}（{len(RESAMPLE_CASES)} 个重采样金标）")
    print(f"生成 {FEATURE_MBT.relative_to(ROOT)}（1 个频谱金标）")
    print(f"生成 {OUT_META.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
