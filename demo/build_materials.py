#!/usr/bin/env python3
"""从原始素材构建演示页的嵌入音频（真实录音，非合成）。

素材来源（均为公开语料，CC BY 4.0；页脚与 README 有署名）：
  办公室  AMI Meeting Corpus · ES2002a.Mix-Headset.wav（真实会议室多人对话，21.2 min）
          截取 501.7 s 起的 60 s 窗口。选此窗的依据：全段 VAD 扫描后该窗口含
          自然分句与最长约 0.7 s 的停顿；全场实测 -40.7 LUFS（录音电平过轻，
          正是本页要展示的"问题"）。
  （复杂噪声场景已按 v0.1 定位移除——不做语音增强，见 README 已知边界；
   v0.2 恢复时把 FSD50K 片段加回 FSD_SCENES 即可。）

输出（演示格式：48 kHz 立体声 16-bit，模拟手机录音形态）：
  office_before.mp3                        ← build_page.py 内嵌进单文件页面
  office_before.wav                        ← 构建中间物（.gitignore 排除）

前置：原始素材位于 MATERIALS 目录：
  ami/ES2002a.Mix-Headset.wav
  fsd/324783.wav
用法：python demo/build_materials.py
"""

from __future__ import annotations

import pathlib
import struct
import subprocess
import sys
import wave

DEMO = pathlib.Path(__file__).resolve().parent
MATERIALS = pathlib.Path(r"C:\tmp\moonvoice-materials")

OFFICE_FULL = MATERIALS / "ami" / "ES2002a.Mix-Headset.wav"
OFFICE_START_S = 501.7      # 窗口起点（该场会议内实测停顿最明显的区段）
OFFICE_DUR_S = 60.0
# v0.1 定位：不做语音增强（复杂噪声场景见 README 已知边界）。
# 场景机制保留——v0.2 恢复时在这里把 (stem, 源文件) 加回来即可。
FSD_SCENES: list[tuple[str, str]] = []


def slice_wav(src: pathlib.Path, out: pathlib.Path, start_s: float, dur_s: float) -> None:
    """切 16-bit PCM WAV（16 kHz 单声道素材的字节级精确切片，保留头部并修正长度字段）。"""
    raw = src.read_bytes()
    fmt_pos = raw.find(b"fmt ")
    fmt_tag, channels, rate, _br, _ba, bits = struct.unpack("<HHIIHH", raw[fmt_pos + 8:fmt_pos + 24])
    if (fmt_tag, channels, bits) != (1, 1, 16):
        sys.exit(f"切片仅支持 16-bit 单声道 PCM：{src} 是 tag={fmt_tag} ch={channels} bits={bits}")
    bps = rate * 2
    total_s = (len(raw) - 44) / bps
    if start_s + dur_s > total_s + 0.05:
        sys.exit(f"窗口超界：{src} 只有 {total_s:.1f}s")
    hdr = bytearray(raw[:44])
    pcm = raw[44 + int(start_s * bps): 44 + int((start_s + dur_s) * bps)]
    struct.pack_into("<I", hdr, 4, 36 + len(pcm))
    struct.pack_into("<I", hdr, 40, len(pcm))
    out.write_bytes(bytes(hdr) + pcm)
    print(f"  切片 {start_s:.1f}s + {dur_s:.0f}s -> {out.name}（{len(pcm)/bps:.2f} s）")


def to_demo_format(src: pathlib.Path, stem: str) -> None:
    """→ 48 kHz 立体声 16-bit WAV + 128 kbps MP3（双声道同为单声道素材的上采样副本）。"""
    wav = DEMO / f"{stem}.wav"
    mp3 = DEMO / f"{stem}.mp3"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(src),
                    "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", str(wav)], check=True)
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(wav),
                    "-c:a", "libmp3lame", "-b:a", "128k", str(mp3)], check=True)
    with wave.open(str(wav)) as w:
        dur = w.getnframes() / w.getframerate()
        spec = f"{w.getframerate()} Hz / {w.getnchannels()} ch / {w.getsampwidth() * 8} bit"
    print(f"  转换 {stem}: {spec} · {dur:.2f} s · mp3 {mp3.stat().st_size/1024:.0f} KB")


def main() -> None:
    missing = [p for p in [OFFICE_FULL] + [MATERIALS / "fsd" / f for _, f in FSD_SCENES] if not p.exists()]
    if missing:
        sys.exit("缺少原始素材：" + ", ".join(map(str, missing)) + f"\n（应位于 {MATERIALS}，见本文件头部说明）")

    print("办公室场景（AMI ES2002a）：")
    office_slice = DEMO / "_office_slice_16k.wav"
    slice_wav(OFFICE_FULL, office_slice, OFFICE_START_S, OFFICE_DUR_S)
    to_demo_format(office_slice, "office_before")
    office_slice.unlink()

    if FSD_SCENES:
        print("FSD50K 场景：")
        for stem, fname in FSD_SCENES:
            print(f"  {stem}  <-  {fname}")
            to_demo_format(MATERIALS / "fsd" / fname, stem)

    print("完成。下一步：python demo/build_page.py")


if __name__ == "__main__":
    main()
