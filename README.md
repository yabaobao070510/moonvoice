# moonvoice

**把任意音频变成"可识别"的语音段——纯 MoonBit，零依赖，可沙箱运行。**

语音处理在现有生态里绕不开 whisper.cpp / rodio 这类 C 绑定库：它们只能原生运行，
进不了 WebAssembly 沙箱。而 MoonBit 生态里音频只有解码器，**分析层是空的**
（实测：`vad` / `resample` / `loudness` / `mel` 四个关键词在 mooncakes 上命中数均为 0）。

moonvoice 用纯 MoonBit 补上这一层：

```
WAV 读入 → 重采样 → 语音活动检测（VAD）→ 语音段 / 特征
```

同一份代码在 **wasm / wasm-gc / js / native** 四个后端运行（测试也在四后端全绿），
以 agent 技能形式发布（`moonx` 一条命令调用），**不访问文件系统、不联网、不加载模型权重**。

## 快速开始

```bash
# 1) 把任意采样率的录音切成语音段（内部完成解码→重采样→分段）
moonx <user>/moonvoice/cmd/vad -- --resample 16000 < input.wav > segments.json

# 2) 只做重采样（输出位深默认沿用输入格式）
moonx <user>/moonvoice/cmd/resample -- --rate 16000 < input.wav > output.wav

# 3) 本地开发（不需要发布）
moon run --target wasm cmd/vad -- --indent 2 < input.wav
```

输出（`cmd/vad`）：

```json
{
  "version": 1,
  "source": {"sample_rate": 16000, "channels": 2, "duration_ms": 4000},
  "params": {"engine": "fused", "frame_ms": 30},
  "segments": [
    {"start_ms": 420, "end_ms": 1680, "rms_dbfs": -19.5, "confidence": 1.0},
    {"start_ms": 2130, "end_ms": 3390, "rms_dbfs": -19.5, "confidence": 1.0}
  ],
  "stats": {"speech_ms": 2520, "ratio": 0.63}
}
```

## 包里有什么

| 包 | 内容 |
|---|---|
| `audio` | RIFF/WAV 编解码：PCM 8/16/24/32-bit、IEEE float 32/64-bit、EXTENSIBLE、多声道；未知块原样保留并回写 |
| `resample` | 多相窗函数 sinc（Kaiser）重采样，任意有理数比率，三档质量 |
| `feature` | FFT、功率谱、频带能量、谱平坦度、谱熵 |
| `vad` | 三引擎语音活动检测（能量 / 谱 / 融合）+ 两遍噪声底跟踪 + 时间平滑 |
| `segments` | 语音段时间轴模型与 JSON 契约 |
| `cmd/vad`、`cmd/resample` | 两个 WASIp1 技能（stdin → stdout） |

## 实测指标

### 吞吐量

`moon run --target <后端> --release benches`（`benches/` 包，可复跑）

| 操作 | wasm | native |
|---|---|---|
| WAV 解码 | 210 MB/s | 234 MB/s |
| 重采样 48k→16k | 244× 实时 | 509× 实时 |
| **VAD（fused，16 kHz 单声道）** | **1171× 实时** | **1916× 实时** |
| FFT 512 点（复用分析器） | 100k 次/s | 226k 次/s |

1171 倍实时 = 1 小时音频约 3 秒分析完（wasm 沙箱内）。

优化的三步都是**先测后改**，每步有数字（见 `benches/` 与各包注释）：

1. **去掉冗余边界检查**：重采样内层每抽头比两次边界，而边界只影响首尾 → +22~26%
2. **内部缓冲改用无检查访问**：FFT 蝶形每点读写 8 次 → +24~43%
3. **缓存 Hann 窗**：此前每帧重算 512 次 `cos()`，而窗只依赖帧长 → wasm **+322%**

顺带记一条**反例**：同样"消除分配"的思路最先用在 FFT 上，实测**毫无效果**——
分配根本不是瓶颈。这次的收益来自测量，不是来自直觉。

### 音频产出质量

| 特性 | 说明 |
|---|---|
| **位深保真** | `Audio` 记录解码来源格式，重编码默认沿用——24-bit 素材重采样后不会静默降级成 16-bit |
| **可选 TPDF 抖动** | 降位深时把量化失真变成噪声（均值无偏、确定性可复现） |
| **削波报告** | `EncodeReport` 给出钳位样本数与峰值；CLI 据此告警并给处置建议 |

实测：0.98 幅度方波经重采样后 Gibbs 过冲到 1.136× 满刻度 → 报出 1398 个样本被钳位。
简单重采样器在这里会**静默钳位**，使用者永远不知道峰值丢了。

### 重采样（48 kHz → 16 kHz）

| 质量档 | 滤波器长度 | 对 9 kHz 折回的抑制 | 对 20 kHz 的抑制 |
|---|---|---|---|
| `fast` | 49 抽头 | 21.0 dB | 76.4 dB |
| `balanced`（默认） | 145 抽头 | **87.8 dB** | 102.9 dB |
| `best` | 385 抽头 | 112.3 dB | 128.5 dB |

通带内 1 kHz 正弦对解析解的 SNR 为 **94.6 dB**。
以上数字都被 numpy 独立复算核对过；`best` 档 20 kHz 有 0.7 dB 出入，
那是 f32 系数存储的量化底噪（约 -128 dB），超出这个量级没有意义。

### VAD

| 场景 | 结果 |
|---|---|
| SNR 20 dB | 召回 100%、精确率 ≥ 90% |
| SNR 5 dB | 召回 100%、精确率 ≥ 80% |
| 白噪声突发 | 融合 79.7% > 纯能量 74.4% > 纯谱 40.6% |
| 持续语音 | 合并为单段，覆盖率 ≥ 85% |

## 原语与组合

`audio` 只放**与语音无关**的通用原语，语音相关的组合由原语拼出来——
所以原语能脱离本场景复用（音频编辑、数据集制作、播放器……）。

```moonbit
// 原语（audio 包）
let head = audio.slice_ms(0, 2000)            // 切片（自动夹范围）
let loud = head.apply_gain_db(6.0)            // 增益
let norm = loud.normalize_peak(target=0.98)   // 峰值归一化
let both = @audio.Audio::concat([head, head]) // 拼接（参数不一致会报错，不偷偷转换）
let mixed = @audio.Audio::mix(a, b, ratio=0.4)// 混音

// 组合（vad 包）：检出 → 切片 → 拼接
let segs  = @vad.detect_segments(audio, @vad.VadParams::default(), @vad.VadEngine::Fused)
let parts = @vad.extract_segments(audio, segs)   // 每段单独取出
let clean = @vad.speech_only(audio, segs)        // 去掉静音的干净人声
```

一条命令拿到同样结果：

```bash
moonx <user>/moonvoice/cmd/vad -- --speech-only < in.wav > speech_only.wav
```

实测：4.00 s 输入 → 2.52 s 输出（与检出段 420–1680 + 2130–3390 ms 完全吻合），采样率保持不变。

## 生态复用决策

按"已有基础库就不重复造"的原则，动工前查过 mooncakes 现状（2026-09-21 实测下载量）：

| 领域 | 生态现状 | 决策 |
|---|---|---|
| SIMD 原语 | `mizchi/simd` 10,339 次下载、MIT、跨四后端 | **可用**；当前 FFT 已达 100k 次/s（wasm），暂未引入；若继续榨性能（SIMD 蝶形，预计再 2×）则引入 |
| FFT | 专用包最多 33 次下载（MoonSpectrum），其余 8–16 | **自建**：依赖不成熟的包比自带一个已用 numpy 金标验证过的 300 行实现风险更高 |
| WAV 编解码 | 有两个包，均 <20 次下载 | **自建**：已用 libsndfile 金标对拍，支持格式更多 |
| 重采样 / VAD | **零命中** | 自建（这就是本项目的立项理由） |

## 验证做法（这是本项目的重点）

**金标对拍的参照物全部是独立第三方实现**，不是"自己编自己解"：

| 被测 | 参照实现 | fixture 来源 |
|---|---|---|
| WAV 解码 | **libsndfile** | ffmpeg 生成（7 种格式） |
| 重采样 | **scipy.signal.resample_poly** | 多音信号 |
| FFT / 谱特征 | **numpy.fft** | 三音叠加 |
| VAD | **构造真值**（见下） | 合成语音与噪声 |

VAD 不用别的 VAD 当标准答案——现成 VAD 本身是带偏好的黑盒，拿它当真理等于测立场。
"我在第 1.0~2.0 秒放了语音"是构造事实，测的才是实现。

**容差都有出处**，不是拍的：

- WAV：`u8/s16/s24/f32` 的样本是 k/2ⁿ（n ≤ 24），f32 尾数可精确表示 → **容差 0，逐样本相等**；
  `s32/f64` 理论相对误差 ≤ 2⁻²⁴ → 取 1e-7
- FFT：同一算法在 numpy 重写的相对误差是 3.4e-16，端到端偏差来自 f32 样本存储 → 取 1e-6
- VAD：边界容差取 90 ms = **设计上 hangover 的宽度**（hangover 是刻意保留尾音的机制，
  把这些帧算成误检等于用指标否定设计意图）

复现全部金标：

```bash
python tools/golden/gen_audio_golden.py   # 需要 ffmpeg / numpy / scipy / soundfile
moon test                                  # 四后端均可跑同一套金标
```

测试数据以**内嵌**方式进源码（wasm 沙箱没有文件系统），所以 wasm / wasm-gc / js / native
跑的是同一套金标，不是四套。

## 设计取舍（详见各包文件头注释）

- **内部用 f32 存样本**：24 位尾数足以承载 32-bit PCM 的动态范围，内存只有 f64 的一半。
  代价是 32-bit 整数样本落地会舍入（已在容差里体现）。
- **整数样本读写全程走 Double 运算**：Int 是 32 位，`u32→i32` 会静默回绕。
- **库包不依赖任何平台 I/O**（不引入 miniio），只有 `cmd/*` 薄壳依赖它——
  所以库可以四后端测试，而技能只需要 wasm。
- **谱特征在融合里既要能加分、也要能扣分**，还有一条**否决规则**：
  响亮的白噪声突发能量比语音高 40 dB，加法得分无论如何压不住，
  必须"谱形状不对就直接否掉"。
- **噪声底估计在语音期冻结**：否则在没有静音的素材里，它会一路追着语音最轻的音节跑，
  把语音当成噪声底（经典失效模式）。

## 已知边界

- **只在 WAV（RIFF）上工作**，不做容器解封装；mp4/mp3 请先在沙箱外转 WAV。
- **有调性的噪声（音乐、鸣笛）会被判成语音**：谱特征靠"是否像噪声"来否决，
  有调性的声音天然不像噪声。需要区分音乐与语音请在上层另做处理。
- 重采样会把 RIFF 保留块原样带过去，其中**含字节偏移的块（如 `cue `）偏移已失效**。
- 抖动用固定种子（可复现优先），不是密码学随机；对听感有要求的场景这是标准做法。
- 未实现：FLAC/OGG 解码、响度（EBU R128）、mel 特征。见 `PROJECT_STATE.md`。

## 开发状态

见 [`PROJECT_STATE.md`](PROJECT_STATE.md)（进度、决策记录、实测事实与坑）、
[`docs/known-issues.md`](docs/known-issues.md)（上游编译器缺陷与绕行）、
[`proposals/moonbit-hackathon-2026.md`](proposals/moonbit-hackathon-2026.md)（立项方案）。

## 许可

Apache-2.0。实现全部原创，无第三方代码移植；参照实现（libsndfile / scipy / numpy）
仅用于生成测试期望值，不进入本库。
