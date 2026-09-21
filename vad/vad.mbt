///|
/// moonvoice/vad — 语音活动检测（三引擎 + 融合）
///
/// 引擎设计（都不依赖任何外部模型，纯 MoonBit）：
/// - **Energy**：自适应噪声底 + 门限。快、稳，但对音乐/突发噪声会误判。
/// - **Spectral**：谱平坦度。稳态噪声的谱是"平坦"的，语音有共振峰结构 → 平坦度低。
///   对稳态噪声强，但清辅音（/s/ /f/）本身接近噪声，容易漏检。
/// - **Fused（默认）**：能量做门控、谱结构做修正，在**帧级得分**上融合，
///   而不是两个独立判决再投票——投票会丢掉"语气不足但结构明确"这类边界帧的信息。
///
/// 噪声底跟踪：非语音期快降慢升的指数跟踪 + 滑动窗最小值兜底。
/// 前者跟得上缓慢变化的背景，后者防止把持续噪声当成语音底。

///| 判决引擎
pub(all) enum VadEngine {
  Energy
  Spectral
  Fused
}

pub fn VadEngine::name(self : VadEngine) -> String {
  match self {
    Energy => "energy"
    Spectral => "spectral"
    Fused => "fused"
  }
}

///| VAD 参数（默认值由 benchmark 调参得出，见 docs/vad-tuning.md）
pub struct VadParams {
  frame_ms : Int // 帧长（同时也是帧移，无重叠）
  threshold_db : Double // 判决门限（得分 dB）
  energy_offset_db : Double // 仅 Energy 引擎用：相对噪声底的高出量
  spectral_bonus_db : Double // 谱结构最多能加多少 dB
  max_flatness : Double // 平坦度归一化的上界：到此值不再加分
  veto_flatness : Double // 平坦度超过此值直接判非语音（响亮噪声突发的唯一否决手段）。
  // 标尺是实测的：单帧周期图下白噪声的 GM/AM 期望为 e^-γ ≈ 0.56（每个 bin 服从指数分布），
  // 实测语音 0.19~0.28、白噪声 0.54~0.56 —— 所以阈值取 0.35/0.5 这一档，而不是"想当然的 0.8"。
  smooth_frames : Int // 帧级多数表决窗（奇数）：同时压掉孤立误检与孤立漏检
  hangover_ms : Int // 语音结束后继续保持的时长
  min_speech_ms : Int // 短于此的段丢弃
  min_silence_ms : Int // 间隔短于此的段合并
  pad_ms : Int // 段前后补白
}

///|
/// 自定义参数：只覆盖你想改的项，其余取默认值。
/// 默认值来自合成基准上的两阶段网格搜索（见 docs/vad-tuning.md），不是拍脑袋：
/// 门限/谱权/否决阈值按**最差场景**选（门限越松越保召回），时间平滑按**段级 IoU** 选。
/// 一个反直觉但有据的结论：谱结构的"渐进加分"在基准上不划算（最优权重为 0），
/// 真正管用的是它的**否决权**——响亮白噪声突发只能靠"谱形状不对就否掉"来挡。
pub fn VadParams::custom(
  frame_ms? : Int = 30,
  threshold_db? : Double = 2.0,
  energy_offset_db? : Double = 8.0,
  spectral_bonus_db? : Double = 0.0,
  max_flatness? : Double = 0.2,
  veto_flatness? : Double = 0.5,
  smooth_frames? : Int = 3,
  hangover_ms? : Int = 90,
  min_speech_ms? : Int = 180,
  min_silence_ms? : Int = 250,
  pad_ms? : Int = 60,
) -> VadParams {
  {
    frame_ms,
    threshold_db,
    energy_offset_db,
    spectral_bonus_db,
    max_flatness,
    veto_flatness,
    smooth_frames,
    hangover_ms,
    min_speech_ms,
    min_silence_ms,
    pad_ms,
  }
}

pub fn VadParams::default() -> VadParams {
  VadParams::custom()
}

///| 逐帧结果（暴露出来是为了可调参、可诊断、可画图）
pub struct FrameDecision {
  start_ms : Int
  end_ms : Int
  energy_db : Double
  flatness : Double
  noise_floor_db : Double
  score_db : Double
  speech : Bool
}

pub fn FrameDecision::start_ms(self : FrameDecision) -> Int {
  self.start_ms
}

pub fn FrameDecision::end_ms(self : FrameDecision) -> Int {
  self.end_ms
}

pub fn FrameDecision::energy_db(self : FrameDecision) -> Double {
  self.energy_db
}

pub fn FrameDecision::flatness(self : FrameDecision) -> Double {
  self.flatness
}

pub fn FrameDecision::noise_floor_db(self : FrameDecision) -> Double {
  self.noise_floor_db
}

pub fn FrameDecision::score_db(self : FrameDecision) -> Double {
  self.score_db
}

pub fn FrameDecision::is_speech(self : FrameDecision) -> Bool {
  self.speech
}

///| 帧级 RMS（dBFS，满刻度为 1.0）
fn frame_rms_db(mono : FixedArray[Float], from : Int, to : Int) -> Double {
  let mut acc = 0.0
  let n = to - from
  if n <= 0 {
    return -160.0
  }
  for i = from; i < to; i = i + 1 {
    let v = mono[i].to_double()
    acc = acc + v * v
  }
  let rms = (acc / n.to_double()).sqrt()
  if rms < 1.0e-8 {
    -160.0
  } else {
    20.0 * @math.log10(rms)
  }
}

///|
/// 帧级**统计量**（分帧 + 频谱特征）。与判决无关，可以算一次、反复用于参数扫描。
pub struct FrameStats {
  frame_ms : Int
  energies_db : Array[Double]
  flatness : Array[Double]
}

pub fn FrameStats::frame_ms(self : FrameStats) -> Int {
  self.frame_ms
}

pub fn FrameStats::n_frames(self : FrameStats) -> Int {
  self.energies_db.length()
}

pub fn FrameStats::energy_db(self : FrameStats, i : Int) -> Double {
  self.energies_db[i]
}

pub fn FrameStats::flatness(self : FrameStats, i : Int) -> Double {
  self.flatness[i]
}

///| 分帧并计算每帧能量与谱平坦度
pub fn compute_frame_stats(
  mono : FixedArray[Float],
  sample_rate : Int,
  frame_ms : Int,
) -> FrameStats {
  let frame_len = sample_rate * frame_ms / 1000
  let energies : Array[Double] = []
  let flatness : Array[Double] = []
  if frame_len <= 0 {
    return { frame_ms, energies_db: energies, flatness }
  }
  let n_frames = mono.length() / frame_len
  let n_fft = @feature.next_pow2(frame_len)
  let bin_hz = sample_rate.to_double() / n_fft.to_double()
  let from_bin = (100.0 / bin_hz).to_int()
  let mut to_bin = (3600.0 / bin_hz).to_int()
  let max_bin = n_fft / 2
  if to_bin > max_bin {
    to_bin = max_bin
  }
  // 逐帧热路径：FFT 分析器与两个缓冲都在循环外建一次，循环内零分配。
  // （用自由函数版 power_spectrum 时每帧要分配 8 KB，实测把 VAD 卡在 419 倍实时。）
  let fft = @feature.Fft::new(n_fft)
  let frame : FixedArray[Float] = FixedArray::make(frame_len, 0.0)
  let spec : FixedArray[Double] = FixedArray::make(fft.spectrum_len(), 0.0)
  for f = 0; f < n_frames; f = f + 1 {
    let from = f * frame_len
    let to = from + frame_len
    for i = from; i < to && i < mono.length(); i = i + 1 {
      frame[i - from] = mono[i]
    }
    energies.push(frame_rms_db(mono, from, to))
    fft.power_into(frame, spec)
    flatness.push(@feature.spectral_flatness(spec, from_bin, to_bin))
  }
  { frame_ms, energies_db: energies, flatness }
}

///|
/// 噪声底跟踪。**必须受语音判决门控**——否则在没有静音的素材里，
/// 它会一路追着语音最轻的音节往下跑，最后把语音当成噪声底（经典的 VAD 失效模式）。
///
/// - 非语音帧：快降（跟得住背景）慢升（不被瞬态带走）
/// - 语音帧：冻结，只留极缓慢的上升（防止长期冻结后再也升不回来）
fn track_noise_floor(
  energies : Array[Double],
  speech : Array[Bool],
  window : Int,
) -> Array[Double] {
  let n = energies.length()
  let floors : Array[Double] = []
  if n == 0 {
    return floors
  }
  // 初值取全局最小能量：比"从第 0 帧起步"稳健得多——
  // 第 0 帧很可能是语音，而语音期噪声底是冻结的，从语音电平起步就再也降不下来。
  let mut floor_db = energies[0]
  for e in energies {
    if e < floor_db {
      floor_db = e
    }
  }
  let force_up_frames = 33 // 约 1 秒（30ms 帧）
  let mut speech_run = 0
  let scratch : Array[Double] = []
  for f = 0; f < n; f = f + 1 {
    // 噪声水平估计：窗口内**非语音**帧能量的下分位均值。
    // 为什么不用最小值：最小值取的是噪声分布的下尾，比噪声平均水平低 3~4 dB，
    // 会让静音帧的 (e - floor) 虚高，直接表现为精确率崩。
    scratch.clear()
    let w_from = if f - window > 0 { f - window } else { 0 }
    for i = w_from; i <= f; i = i + 1 {
      if !speech[i] {
        scratch.push(energies[i])
      }
    }
    let mut noise_level = floor_db
    if scratch.length() > 0 {
      let sorted = sort_copy(scratch)
      let take = if sorted.length() / 5 > 0 { sorted.length() / 5 } else { 1 }
      let mut acc = 0.0
      for i = 0; i < take; i = i + 1 {
        acc = acc + sorted[i]
      }
      noise_level = acc / take.to_double()
    }
    if speech[f] {
      // 语音期**冻结**噪声底——这是整个估计器的关键约束。
      // 只在"连续语音久到不合理"时才允许极缓慢上移，作为防卡死的安全阀
      // （否则一段长语音会把噪声底永久压在最低点，后续真实静音也判不出来）。
      speech_run = speech_run + 1
      if speech_run > force_up_frames {
        floor_db = floor_db * 0.999 + energies[f] * 0.001
      }
    } else {
      speech_run = 0
      if noise_level < floor_db {
        floor_db = floor_db * 0.7 + noise_level * 0.3
      } else {
        floor_db = floor_db * 0.995 + noise_level * 0.005
      }
    }
    floors.push(floor_db)
  }
  floors
}

///| 升序副本（窗口很小，插入排序足够）
fn sort_copy(xs : Array[Double]) -> Array[Double] {
  let a = xs.copy()
  for i = 1; i < a.length(); i = i + 1 {
    let v = a[i]
    let mut j = i - 1
    while j >= 0 && a[j] > v {
      a[j + 1] = a[j]
      j = j - 1
    }
    a[j + 1] = v
  }
  a
}

///| 按给定噪声底做一轮判决（含 hangover），返回是否语音
fn decide_with_floor(
  stats : FrameStats,
  floors : Array[Double],
  params : VadParams,
  engine : VadEngine,
) -> Array[Bool] {
  let n = stats.n_frames()
  let out : Array[Bool] = []
  let hangover_frames = if params.frame_ms <= 0 {
    1
  } else {
    (params.hangover_ms / params.frame_ms) + 1
  }
  let mut hangover_left = 0
  for f = 0; f < n; f = f + 1 {
    let bonus = spectral_bonus(stats.flatness[f], params)
    let score = match engine {
      Energy => stats.energies_db[f] - floors[f]
      Spectral => bonus - params.spectral_bonus_db / 2.0
      Fused => (stats.energies_db[f] - floors[f]) + bonus
    }
    let threshold = match engine {
      Energy => params.energy_offset_db
      Spectral => params.spectral_bonus_db / 2.0
      Fused => params.threshold_db
    }
    // 噪声样否决：白噪声突发的能量可以比语音高 40 dB，加法得分无论如何压不住它，
    // 必须有这条"谱形状不对就直接否掉"的硬规则。阈值放到 0.85 是为了不误伤擦音。
    // Energy 引擎是"纯能量"基线，不享用谱信息的否决权——否则三引擎对比失去意义
    let use_spectral = match engine {
      Energy => false
      Spectral | Fused => true
    }
    let noise_like = use_spectral && stats.flatness[f] > params.veto_flatness
    let mut speech = score > threshold && !noise_like
    if speech {
      hangover_left = hangover_frames
    } else if hangover_left > 0 {
      hangover_left = hangover_left - 1
      speech = true
    }
    out.push(speech)
  }
  majority_smooth(out, params.smooth_frames)
}

///|
/// 谱结构项（dB），**有符号**：
/// - 平坦度低（谐波结构）→ 加分，能救回"气声小但结构明确"的帧
/// - 平坦度高（白噪/噪声突发）→ **减分**，这是谱特征唯一的否决权所在。
///|
/// 帧级多数表决：孤立的一两帧误检/漏检会被邻域投票改掉。
/// 这是"能量门限调不高"的直接补丁——门限受限于低信噪比下的召回，
/// 而误检大多是孤立的，投票能把它们拿掉而不牺牲召回。
fn majority_smooth(flags : Array[Bool], window : Int) -> Array[Bool] {
  if window <= 1 || flags.length() == 0 {
    return flags
  }
  let half = window / 2
  let out : Array[Bool] = []
  for i = 0; i < flags.length(); i = i + 1 {
    let from = if i - half > 0 { i - half } else { 0 }
    let to = if i + half < flags.length() { i + half } else { flags.length() - 1 }
    let mut yes = 0
    let mut total = 0
    for k = from; k <= to; k = k + 1 {
      total = total + 1
      if flags[k] {
        yes = yes + 1
      }
    }
    out.push(yes * 2 > total)
  }
  out
}

///   只加不减的融合在"响亮的白噪声突发"面前毫无办法——那样它退化成纯能量 VAD。
fn spectral_bonus(flatness : Double, params : VadParams) -> Double {
  let ref_flat = params.max_flatness
  if ref_flat <= 0.0 {
    return 0.0
  }
  let rel = (ref_flat - flatness) / ref_flat
  let clamped = if rel > 1.0 {
    1.0
  } else if rel < -1.0 {
    -1.0
  } else {
    rel
  }
  params.spectral_bonus_db * clamped
}

///|
/// 逐帧分析：两遍噪声底跟踪。
/// 第一遍用 min-statistics 粗判，第二遍用粗判结果门控噪声底再重判——
/// 这样"整段都是语音"的素材不会被自己的最低音节拖垮。
pub fn analyze(
  stats : FrameStats,
  params : VadParams,
  engine : VadEngine,
) -> Array[FrameDecision] {
  let n = stats.n_frames()
  let out : Array[FrameDecision] = []
  if n == 0 {
    return out
  }
  let window = (1500 / params.frame_ms) + 1
  // 第一遍：无门控（全按非语音处理）的 min-statistics
  let no_speech : Array[Bool] = []
  for i = 0; i < n; i = i + 1 {
    no_speech.push(false)
  }
  let floors1 = track_noise_floor(stats.energies_db, no_speech, window)
  let speech1 = decide_with_floor(stats, floors1, params, engine)
  // 第二遍：用粗判结果门控
  let floors2 = track_noise_floor(stats.energies_db, speech1, window)
  let speech2 = decide_with_floor(stats, floors2, params, engine)
  for f = 0; f < n; f = f + 1 {
    let bonus = spectral_bonus(stats.flatness[f], params)
    let score = match engine {
      Energy => stats.energies_db[f] - floors2[f]
      Spectral => bonus - params.spectral_bonus_db / 2.0
      Fused => (stats.energies_db[f] - floors2[f]) + bonus
    }
    out.push({
      start_ms: f * params.frame_ms,
      end_ms: (f + 1) * params.frame_ms,
      energy_db: stats.energies_db[f],
      flatness: stats.flatness[f],
      noise_floor_db: floors2[f],
      score_db: score,
      speech: speech2[f],
    })
  }
  out
}

///|
/// 便利入口：分帧统计 + 判决一次做完。
pub fn analyze_frames(
  mono : FixedArray[Float],
  sample_rate : Int,
  params : VadParams,
  engine : VadEngine,
) -> Array[FrameDecision] {
  analyze(compute_frame_stats(mono, sample_rate, params.frame_ms), params, engine)
}

///|
/// 帧判决 → 语音段（时间平滑：合并/丢弃/补白）。
pub fn frames_to_segments(
  frames : Array[FrameDecision],
  mono : FixedArray[Float],
  sample_rate : Int,
  params : VadParams,
) -> Array[@segments.Segment] {
  let raw : Array[@segments.Segment] = []
  let mut i = 0
  let frame_len = sample_rate * params.frame_ms / 1000
  while i < frames.length() {
    if frames[i].speech {
      let start_f = i
      let mut end_f = i
      let mut score_sum = 0.0
      let mut count = 0
      while end_f + 1 < frames.length() && frames[end_f + 1].speech {
        end_f = end_f + 1
      }
      for k = start_f; k <= end_f; k = k + 1 {
        score_sum = score_sum + frames[k].score_db
        count = count + 1
      }
      let start_ms = frames[start_f].start_ms
      let end_ms = frames[end_f].end_ms
      // 段内实际 RMS（比逐帧平均更准）
      let from = start_f * frame_len
      let to = if (end_f + 1) * frame_len < mono.length() {
        (end_f + 1) * frame_len
      } else {
        mono.length()
      }
      let rms = frame_rms_db(mono, from, to)
      let margin = if count > 0 { score_sum / count.to_double() - params.threshold_db } else { 0.0 }
      let conf = if margin <= 0.0 {
        0.0
      } else if margin >= 15.0 {
        1.0
      } else {
        margin / 15.0
      }
      raw.push(@segments.Segment::new(start_ms, end_ms, rms, conf))
      i = end_f + 1
    } else {
      i = i + 1
    }
  }
  let total_ms = frames.length() * params.frame_ms
  let merged = @segments.merge_close(raw, params.min_silence_ms)
  let kept = @segments.drop_short(merged, params.min_speech_ms)
  let padded = @segments.pad_segments(kept, params.pad_ms, total_ms)
  @segments.resolve_overlaps(padded)
}

///|
/// 完整流程：音频 → 分段结果（含源信息、参数、统计，可直接序列化为 JSON）。
pub fn build_result(
  audio : @audio.Audio,
  params : VadParams,
  engine : VadEngine,
) -> @segments.SegmentsResult {
  let mono = audio.to_mono()
  let frames = analyze_frames(mono, audio.sample_rate(), params, engine)
  let segs = frames_to_segments(frames, mono, audio.sample_rate(), params)
  @segments.SegmentsResult::of(
    audio.sample_rate(),
    audio.channels(),
    (audio.frames().to_double() * 1000.0 / audio.sample_rate().to_double()).to_int(),
    engine.name(),
    params.frame_ms,
    segs,
  )
}

///|
/// 一步到位：音频 → 语音段数组。
/// 只想要分段、不需要 JSON 包装时用它（`build_result` 是给技能输出用的）。
pub fn detect_segments(
  audio : @audio.Audio,
  params : VadParams,
  engine : VadEngine,
) -> Array[@segments.Segment] {
  let mono = audio.to_mono()
  let frames = analyze_frames(mono, audio.sample_rate(), params, engine)
  frames_to_segments(frames, mono, audio.sample_rate(), params)
}

// ---------------------------------------------------------------------------
// 组合：把原语拼成"能用的产物"
//
// 这两条不是新算法，是 audio 原语 + segments 的组合——
// 放在这里是因为它们依赖"语音段"这个概念，而原语本身不依赖。
// ---------------------------------------------------------------------------

///| 把每个语音段单独切出来（保留采样率与格式标记）
pub fn extract_segments(
  audio : @audio.Audio,
  segs : Array[@segments.Segment],
) -> Array[@audio.Audio] {
  let out : Array[@audio.Audio] = []
  for s in segs {
    out.push(audio.slice_ms(s.start_ms(), s.end_ms()))
  }
  out
}

///|
/// 只保留语音：把语音段顺序拼成一条音频（去掉静音）。
///
/// 典型用途：把一段带停顿的录音变成"干净人声"，直接喂给识别器或配音流水线。
/// 拼接要求各段采样率/声道一致——它们都来自同一路输入，所以恒成立。
pub fn speech_only(
  audio : @audio.Audio,
  segs : Array[@segments.Segment],
) -> @audio.Audio raise @audio.AudioError {
  @audio.Audio::concat(extract_segments(audio, segs))
}
