#!/usr/bin/env python3
"""生成 audio 包的金标测试。

设计原则（同时写进 README 与开发复盘）：

1. **参照物必须独立**。fixture 由 ffmpeg 生成，期望值由 libsndfile（soundfile 包）
   独立解码得到 —— 不是拿我们自己的公式算一遍再自我验证。
2. **测试不依赖文件 I/O**。fixture 以十六进制字符串内嵌进生成的 .mbt 源码，
   这样 wasm / js / native 三个后端都能跑同一套金标（wasm 沙箱里没有文件系统）。
3. **可复现**。fixture 同时落盘到 fixtures/audio/，任何人可重跑本脚本复核。

用法：
    python tools/golden/gen_audio_golden.py
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys

import soundfile as sf

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "fixtures" / "audio"
OUT_MBT = ROOT / "audio" / "golden_data_test.mbt"
OUT_META = FIXTURES / "manifest.json"

# (名称, ffmpeg 采样格式, 声道, 采样率, 说明)
CASES = [
    ("sine_u8_mono", "pcm_u8", 1, 8000, "8-bit 无符号"),
    ("sine_s16_mono", "pcm_s16le", 1, 16000, "16-bit 有符号"),
    ("sine_s24_mono", "pcm_s24le", 1, 16000, "24-bit 有符号"),
    ("sine_s32_mono", "pcm_s32le", 1, 16000, "32-bit 有符号"),
    ("sine_f32_mono", "pcm_f32le", 1, 16000, "32-bit 浮点"),
    ("sine_f64_mono", "pcm_f64le", 1, 16000, "64-bit 浮点"),
    ("sine_s16_stereo", "pcm_s16le", 2, 16000, "16-bit 立体声（交错）"),
]

DURATION = 0.025  # 秒。短样本足够覆盖解析路径，且让内嵌数据保持可读。

# MoonBit 侧固定辅助代码。单独放普通字符串，避免与 f-string 的花括号冲突。
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


def ffmpeg_bin() -> str:
    for name in ("ffmpeg", "ffmpeg.exe"):
        try:
            subprocess.run([name, "-version"], capture_output=True, check=True)
            return name
        except Exception:
            continue
    sys.exit("找不到 ffmpeg，请先安装（winget install Gyan.FFmpeg）")


def make_fixture(ff: str, name: str, codec: str, channels: int, rate: int) -> pathlib.Path:
    path = FIXTURES / f"{name}.wav"
    expr = f"sine=frequency=440:sample_rate={rate}:duration={DURATION}"
    cmd = [
        ff, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", expr,
        "-ac", str(channels), "-c:a", codec, str(path),
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    return path


def fmt_double(v: float) -> str:
    if v == 0.0:
        return "0.0"
    if v == int(v) and abs(v) < 1e15:
        return f"{v:.1f}"
    return repr(float(v))


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    ff = ffmpeg_bin()

    manifest = []
    blocks: list[str] = []

    for name, codec, channels, rate, desc in CASES:
        path = make_fixture(ff, name, codec, channels, rate)
        raw = path.read_bytes()
        # libsndfile：完全独立的第三方解码器，用它得到期望值
        samples, samplerate = sf.read(str(path), dtype="float64", always_2d=True)
        expected = samples.reshape(-1).tolist()  # 交错
        assert samplerate == rate, f"{name}: 采样率不符 {samplerate} != {rate}"

        manifest.append({
            "name": name,
            "codec": codec,
            "channels": channels,
            "sample_rate": rate,
            "frames": len(samples),
            "bytes": len(raw),
            "expected_source": "libsndfile (soundfile) 独立解码",
        })

        values = ", ".join(fmt_double(v) for v in expected)
        blocks.append(
            f"\n///| {desc}：ffmpeg 生成，libsndfile 解码得到期望值\n"
            f"fn golden_{name}_wav() -> Bytes raise {{\n"
            f'  unhex("{raw.hex()}")\n'
            f"}}\n\n"
            f"fn golden_{name}_expected() -> Array[Double] {{\n"
            f"  [{values}]\n"
            f"}}\n\n"
            f"///| (采样率, 声道数, 帧数)\n"
            f"fn golden_{name}_meta() -> (Int, Int, Int) {{\n"
            f"  ({rate}, {channels}, {len(samples)})\n"
            f"}}\n"
        )

    header = "\n".join([
        "///|",
        "/// **自动生成，请勿手改** —— 由 tools/golden/gen_audio_golden.py 生成。",
        "///",
        f"/// fixture 来源：ffmpeg（{len(CASES)} 个格式）",
        "/// 期望值来源：libsndfile / soundfile 独立解码（与被测实现无共享代码）",
        "/// 内嵌而非读文件：wasm 沙箱无文件系统，三后端要跑同一套金标。",
        "",
    ])

    OUT_MBT.write_text(header + "".join(blocks) + HELPERS, encoding="utf-8")
    OUT_META.write_text(
        json.dumps({"cases": manifest}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"生成 {OUT_MBT.relative_to(ROOT)}（{len(CASES)} 个 fixture）")
    print(f"生成 {OUT_META.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
