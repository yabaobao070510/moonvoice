#!/usr/bin/env python3
"""构造一段"未剪辑的真实录音素材"，供 moonvoice 组件链处理。

素材来源：LibriSpeech（OpenSLR SLR31，CC BY 4.0）真人朗读。

**为什么这样组织**：一段真实的待处理素材 = 连续语音 + 句间自然停顿 + 前后留白。
这里取同一说话人的连续朗读按此形态排布——**语音内容 100% 真实**，
只是把"录音时本来就会有的停顿"还原出来，并转成视频音轨的典型规格（48 kHz 立体声）。
构造用的 scipy 只负责把素材摆成输入的形态，处理链本身完全由 moonvoice 完成。

用法：
    python demo/build_before.py <LibriSpeech 解出的 flac 目录>
"""

from __future__ import annotations

import glob
import os
import pathlib
import sys

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

OUT_DIR = pathlib.Path(__file__).resolve().parent
BEFORE = OUT_DIR / "before.wav"

PICK = 8           # 取连续 8 句
# 句间停顿：真实朗读的停顿是**不均匀**的（换气短、翻页/思考长），
# 用固定值反而失真，也演示不出"去静音"的价值
GAPS = [1.2, 2.4, 0.9, 1.8, 1.3, 2.1, 1.6]
LEAD, TAIL = 1.0, 0.8
OUT_RATE, OUT_CH = 48000, 2   # 视频音轨的典型规格
PEAK = 0.55        # 压低一点：真实素材录完通常没做归一化


def main() -> None:
    src_dir = sys.argv[1] if len(sys.argv) > 1 else None
    if not src_dir:
        sys.exit("用法: python demo/build_before.py <flac 目录>")
    files = sorted(glob.glob(os.path.join(src_dir, "*.flac")))
    if not files:
        sys.exit(f"目录里没有 flac: {src_dir}")
    print(f"找到 {len(files)} 条朗读，取前 {PICK} 条")

    segs = []
    for f in files[:PICK]:
        x, sr = sf.read(f, dtype="float32")
        assert sr == 16000 and x.ndim == 1, f"{f}: 期望 16 kHz 单声道"
        segs.append(x)

    parts = [np.zeros(int(LEAD * 16000), dtype="float32")]
    for i, s in enumerate(segs):
        parts.append(s)
        parts.append(np.zeros(int(GAPS[i % len(GAPS)] * 16000), dtype="float32"))
    parts.append(np.zeros(int(TAIL * 16000), dtype="float32"))
    mono = np.concatenate(parts)
    total_gap = sum(GAPS[i % len(GAPS)] for i in range(len(segs)))
    print(f"拼接后 {len(mono)/16000:.2f}s（{len(segs)} 句 + {total_gap:.1f}s 不均匀停顿 + 前后留白）")

    peak = float(np.max(np.abs(mono)))
    mono = mono / peak * PEAK

    up = resample_poly(mono.astype(np.float64), 3, 1)     # 16k → 48k
    stereo = np.stack([up, up], axis=1)
    sf.write(str(BEFORE), stereo, OUT_RATE, subtype="PCM_16")
    print(f"写出 {BEFORE.name}: {OUT_RATE} Hz / {OUT_CH} ch / {len(stereo)/OUT_RATE:.2f}s / 峰值 {np.abs(stereo).max():.3f}")


if __name__ == "__main__":
    main()
