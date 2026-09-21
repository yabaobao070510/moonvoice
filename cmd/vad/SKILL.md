---
name: moonvoice-vad
description: Detect speech segments in an audio file and return their timestamps as JSON. Use when an agent needs to split a recording into speech/silence, prepare audio for ASR, or find where speech actually happens before transcribing or dubbing. Pure MoonBit, runs sandboxed, no network and no model files.
---

# moonvoice/vad

把一段音频切成"可识别"的语音段，输出每段的起止时间、能量与置信度。
纯 MoonBit 实现，**不加载任何模型权重、不访问网络、不写文件**——适合在沙箱里直接跑。

## 何时用

- 转录前的前处理：先把长录音切成语音段，避免把静音也送进识别器
- 配音/剪辑：找出一段素材里"人声真正出现在哪"
- 质检：统计一段音频的语音占比（`stats.ratio`）

## 用法

```bash
moonx <user>/moonvoice/cmd/vad -- --resample 16000 < input.wav > segments.json
```

输入必须是 **WAV 字节走 stdin**（沙箱内没有文件系统）。若来源是 mp4/mp3，先在沙箱外转成 WAV。

### 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--engine fused\|energy\|spectral` | `fused` | `fused` 在噪声突发场景显著优于纯能量（基准实测 79.7% vs 74.4%） |
| `--frame-ms 10\|20\|30` | `30` | 帧长；10 ms 时间分辨率更高但更易受噪声影响 |
| `--min-silence MS` | `250` | 间隔小于此值的相邻段合并（防止一句话被换气切开） |
| `--min-speech MS` | `180` | 短于此值的段丢弃（去毛刺） |
| `--pad MS` | `60` | 段前后各补白，避免切掉起始辅音与收尾 |
| `--resample HZ` | 不变 | 先重采样再分析（识别器常用 16000） |
| `--indent N` | `0` | JSON 缩进；`2` 便于人读 |

## 输出

```json
{
  "version": 1,
  "source": {"sample_rate": 16000, "channels": 2, "duration_ms": 4000},
  "params": {"engine": "fused", "frame_ms": 30},
  "segments": [{"start_ms": 420, "end_ms": 1680, "rms_dbfs": -19.5, "confidence": 1.0}],
  "stats": {"speech_ms": 2520, "ratio": 0.63}
}
```

`params` 会随结果一起输出，保证结果可复现；`rms_dbfs` 越接近 0 越响；
`confidence` 是判决裕量的归一化值（0~1），可用来过滤低置信段。

## 失败时

非 WAV 输入、截断文件、空 stdin 都会在 **stderr** 给出可读原因并以非 0 退出码结束。
把 stderr 原样交给上层判断，不要吞掉。

## 已知边界

- **音乐/鸣笛等有结构的噪声**会被判成语音：谱特征靠"是否像噪声"来否决，
  有调性的声音天然不像噪声。需要区分音乐与语音请在上层另做处理。
- 只在 **WAV** 上工作（RIFF）；容器格式请先解封装。
