---
name: moonvoice-resample
description: Convert a WAV file to a different sample rate with a high-quality polyphase resampler. Use when an agent needs to bring audio to a target rate (e.g. 16000 Hz for ASR) or normalize sample rates across files. Pure MoonBit, runs sandboxed, no network, no external codecs.
---

# moonvoice/resample

把 WAV 重采样到任意目标采样率，输出 16-bit PCM WAV。
纯 MoonBit 实现，抗混叠滤波器为多相窗函数 sinc（Kaiser 窗），**不依赖任何 C 库或系统编解码器**。

## 何时用

- 识别器要求固定采样率（语音识别常用 16000 Hz）
- 把来源不一的素材统一采样率，便于批处理
- 需要在沙箱里做高质量重采样（没有 ffmpeg 可用时）

## 用法

```bash
moonx <user>/moonvoice/cmd/resample -- --rate 16000 < input.wav > output.wav
```

输入走 stdin、输出走 stdout（沙箱内没有文件系统）。

### 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--rate HZ` | 必填 | 目标采样率 |
| `--quality fast\|balanced\|best` | `balanced` | 滤波器长度与阻带衰减的取舍 |

**质量档实测**（48k→16k，对 9 kHz 折回分量的抑制）：

| 档 | 滤波器长度 | 对 9 kHz 的抑制 | 对 20 kHz 的抑制 |
|---|---|---|---|
| `fast` | 49 抽头 | 21.0 dB | 76.4 dB |
| `balanced` | 145 抽头 | 87.8 dB | 102.9 dB |
| `best` | 385 抽头 | 112.3 dB | 128.5 dB |

若输入本身已带限（如已经是 16 k 上采样来的素材），`fast` 足够；
来源不明或含高频噪声时用 `balanced`（默认）。

## 输出

16-bit PCM WAV 字节（stdout）。原文件的 RIFF 保留块（ffmpeg 写的 `LIST`/`INFO` 等）
会原样带过去——**但含有字节偏移的块（如 `cue `）在重采样后偏移已失效**，
需要精确元数据的场景请自行处理。

## 失败时

非 WAV 输入、未知质量档、缺少 `--rate` 都会在 stderr 给出可读原因并以非 0 退出。

## 已知边界

- 只在 WAV（RIFF）上工作，不做容器解封装
- 不做声道转换：需要单声道请先用 `moonvoice/vad --resample`（它内部会混单声道）
