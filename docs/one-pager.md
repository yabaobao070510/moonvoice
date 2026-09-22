# 一页项目说明（申报用）

> 报名表需提交「参赛信息 + 公开仓库 + 一页项目说明」。以下正文可直接粘贴。

---

## moonvoice —— 纯 MoonBit 语音前端工具包

**目标用户**：需要处理语音、又要保证数据不出本机的开发者与 AI agent 作者。

**要解决的问题**：现在要做语音处理，绕不开 whisper.cpp / rodio 这类 C 绑定库——它们只能原生运行，
**进不了 WebAssembly 沙箱**。而 MoonBit 生态里音频只有解码器（moon-wav、moonvorbis），
分析层完全空白：实测 `vad` / `resample` / `loudness` / `mel` 四个关键词在 mooncakes 上命中数均为 0。

**做法**：用纯 MoonBit 实现语音前端全链——

```
WAV 解码 → 重采样 → 语音活动检测（VAD）→ 语音段
                  ↘ STFT → mel → log-mel / MFCC（识别器前端）
                  ↘ K 加权 → EBU R128 响度 + 增益建议
```

以 agent 技能形式发布到 skills.mooncakes.io。同一份代码在 **wasm / wasm-gc / js / native**
四个后端运行，**不访问文件系统、不联网、不加载模型权重**——音频数据不离开调用方。

**范围边界（明确不做）**：不做语音增强 / 人声析出——VAD 只回答"哪里是语音"，不改变信号；
噪声大到盖过人声、无有效噪声底可跟踪时，该判定会退化。复杂环境的增强列入 v0.2 路线图。

**工程重点在"可验证"**（而不是"能跑"）：

| 环节 | 独立参照实现 | 实测 |
|---|---|---|
| WAV 解码 | libsndfile | 逐样本相等（容差 0） |
| 重采样 | scipy.signal.resample_poly | 对 9 kHz 折回抑制 87.8 dB |
| STFT / ISTFT | numpy.fft + 完全重构性质 | 重构 SNR ≥ 100 dB |
| mel / log-mel / MFCC | librosa | 偏差 < 0.5 dB |
| 响度 | pyloudnorm（BS.1770-4） | < 0.1 LU |
| VAD | 构造真值（四类场景） | SNR 20 dB 召回 100%、精确率 ≥ 90% |

VAD 不用别的 VAD 当标准答案——现成 VAD 是带偏好的黑盒，拿它当真理等于测立场。

**性能**（`benches/` 可复跑）：VAD **1171× 实时**（wasm）/ 1916×（native）；
重采样 244×/509× 实时；WAV 解码 210/234 MB/s。

**交付物**：5 个库包 + **3 个可运行技能**（`vad` / `resample` / `loudness`）+ 89 项测试 × 四后端全绿 + README + 开发复盘。

**开源**：Apache-2.0。参考实现（libsndfile / scipy / numpy / librosa / pyloudnorm）仅用于生成测试期望值，
其代码不进入本库；运行期唯一依赖 `moonbit-community/miniio`，且只被技能壳使用。

---

## moonvoice — A pure-MoonBit speech front-end toolkit

**Who it's for**: developers and agent authors who need to process speech while keeping audio on-device.

**The gap**: speech processing today requires C-backed libraries (whisper.cpp, rodio) that cannot run
inside a WebAssembly sandbox. In the MoonBit ecosystem, audio has decoders but **no analysis layer**
(measured: `vad` / `resample` / `loudness` / `mel` all return zero hits on mooncakes).

**What it does**: the full speech front-end in pure MoonBit — WAV decode → resample → VAD →
speech segments; STFT → mel → log-mel/MFCC; K-weighting → EBU R128 loudness with gain advice.
Shipped as agent skills, running identically on wasm / wasm-gc / js / native, with no filesystem,
no network, and no model weights.

**Scope limit**: no speech enhancement / separation — VAD answers *where speech is* and does not
modify the signal; when noise is louder than the speech (no usable noise floor), the decision
degrades. Enhancement for noisy environments is on the v0.2 roadmap.

**Verification first**: every stage is checked against an independent reference —
libsndfile (WAV), scipy (resampling), numpy (STFT), librosa (mel/MFCC), pyloudnorm (EBU R128) —
plus property tests such as perfect STFT reconstruction (SNR ≥ 100 dB).
VAD is validated against *constructed ground truth*, not another VAD.

**Performance**: VAD at 1171× realtime (wasm) / 1916× (native); 89 tests green across four backends.
