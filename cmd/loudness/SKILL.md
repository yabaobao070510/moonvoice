---
name: moonvoice-loudness
description: Measure audio loudness in LUFS (EBU R128 / ITU-R BS.1770-4) and get the exact gain needed to hit a target loudness. Use when an agent needs to normalize audio levels for a podcast, streaming platform, or broadcast deliverable, or to check whether audio is too quiet/loud/clipped. Pure MoonBit, runs sandboxed, no network.
---

# moonvoice/loudness

按 **EBU R128 / ITU-R BS.1770-4** 测响度，并直接给出**到目标响度需要多少 dB 增益**——
拿到的不是一个数字，而是一个可以接着执行的动作。

## 何时用

- 交付前对齐响度（播客常用 -16 LUFS、流媒体多为 -14 LUFS、广播 -23 LUFS）
- 检查素材是否过轻/过响/削波
- 批量处理前先摸底，决定统一加多少增益

## 用法

```bash
moonx <user>/moonvoice/cmd/loudness -- --target -16 < input.wav
# 输出：
# 积分响度   : -18.2 LUFS
# 响度范围   : 0.72 LU
# 样本峰值   : -8.25 dBFS
# 参与块数   : 26 / 37
# 目标响度   : -16 LUFS
# 建议增益   : 2.2 dB

moonx <user>/moonvoice/cmd/loudness -- --target -14 --json < input.wav
```

### 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--target LUFS` | `-16` | 目标积分响度（播客/口播 -16，流媒体 -14，广播 -23） |
| `--json` | 关 | 输出机器可读 JSON（含 `gain_to_target_db`） |

JSON 字段：`integrated_lufs` / `loudness_range_lu` / `sample_peak_dbfs` /
`gated_blocks` / `total_blocks` / `target_lufs` / `gain_to_target_db`。

## 为什么不是 RMS

RMS 测的是"能量有多大"，LUFS 测的是"人听着有多响"——差了一个 **K 加权**
（模拟头部与耳道的频响）和一个**门控**（静音段不该拉低整体读数）。
拿 RMS 对齐音量，上了平台就是忽大忽小。

## 已知边界

- `sample_peak_dbfs` 是**样本峰值**，不是真峰值（dBTP）。真峰值需要 4× 以上过采样
  才能测准，本工具不做——判"是否可能削波"够用，做母带交付请用专业工具。
- 响度范围 LRA 需要至少 3 秒音频才有意义，短素材会返回 0。
