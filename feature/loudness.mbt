///|
/// moonvoice/feature — 响度（ITU-R BS.1770-4 / EBU R128）
///
/// 为什么不能用 RMS 代替响度：RMS 是"能量有多大"，响度是"人听着有多响"——
/// 两者差了一个 K 加权（模拟头部与耳道的频响）和一个门控（安静段不该拉低整体）。
/// 广播与流媒体平台交付都用 LUFS；拿 RMS 对齐音量，上了平台就是忽大忽小。
///
/// 链路：K 加权滤波（高架 + 高通两级双二阶）→ 400 ms 块均方 → 双门限积分
///
/// K 加权系数按 RBJ 公式从标准给出的模拟指标**现算**，
/// 因此任意采样率都成立（不是只在 48 kHz 有效的那组固定数字）。

///|
/// K 加权滤波器（两级串联）。参数取 ITU-R BS.1770 附录 1 的规定值：
/// - 第一级高架：fc ≈ 1681.97 Hz，Q ≈ 0.7072，增益 ≈ +4.0 dB
/// - 第二级高通：fc ≈ 38.14 Hz，Q ≈ 0.5003
pub struct KWeighting {
  shelf : Biquad
  highpass : Biquad
}

pub fn KWeighting::new(sample_rate : Int) -> KWeighting {
  {
    shelf: Biquad::new(
      HighShelf(0.7071752369554196, 3.999843853973347),
      1681.974450955533,
      sample_rate,
    ),
    highpass: Biquad::new(Highpass(0.5003270373238773), 38.13547087602444, sample_rate),
  }
}

///| 一个样本依次过两级滤波
pub fn KWeighting::process_sample(self : KWeighting, x : Double) -> Double {
  self.highpass.process_sample(self.shelf.process_sample(x))
}

pub fn KWeighting::reset(self : KWeighting) -> Unit {
  self.shelf.reset()
  self.highpass.reset()
}

///| 响度测量结果（LUFS = 相对满刻度的响度单位）
pub struct LoudnessResult {
  /// 积分响度（整段的 LUFS，加过门限）
  integrated_lufs : Double
  /// 未加门限的块响度均值（用来看门限是否起作用）
  ungated_lufs : Double
  /// 响度范围（EBU R128 LRA，单位 LU）：短时响度的 10%~95% 分位差
  loudness_range_lu : Double
  /// 参与积分的块数
  gated_blocks : Int
  /// 总块数
  total_blocks : Int
  /// 样本峰值（dBFS）。**注意**：真峰值（dBTP）需过采样到 4× 以上才能准确，
  /// 这里给的是样本峰值，用于快速判断是否可能削波。
  sample_peak_dbfs : Double
}

pub fn LoudnessResult::integrated_lufs(self : LoudnessResult) -> Double {
  self.integrated_lufs
}

pub fn LoudnessResult::ungated_lufs(self : LoudnessResult) -> Double {
  self.ungated_lufs
}

pub fn LoudnessResult::loudness_range_lu(self : LoudnessResult) -> Double {
  self.loudness_range_lu
}

pub fn LoudnessResult::gated_blocks(self : LoudnessResult) -> Int {
  self.gated_blocks
}

pub fn LoudnessResult::total_blocks(self : LoudnessResult) -> Int {
  self.total_blocks
}

pub fn LoudnessResult::sample_peak_dbfs(self : LoudnessResult) -> Double {
  self.sample_peak_dbfs
}

///| 满刻度参考：L = -0.691 + 10·log10(Σ G_i · z_i)
const LOUDNESS_OFFSET : Double = -0.691

///| 声道权重（BS.1770 表 3）：L/R/C = 1.0，环绕 = 1.41
fn channel_weight(ch : Int, channels : Int) -> Double {
  if channels <= 3 {
    1.0 // 单声道 / 立体声 / 3 声道（L R C）
  } else if ch < 3 {
    1.0
  } else {
    1.41
  }
}

///| 400 ms 块的均方（含 75% 重叠，即 100 ms 步进）
fn block_mean_squares(
  weighted : FixedArray[Float],
  channels : Int,
  frames : Int,
  block : Int,
  hop : Int,
) -> (Array[Double], Array[Double]) {
  // 返回 (每块的加权功率和, 每块所有声道的和)——先做加权和
  let per_block : Array[Double] = []
  let per_block_raw : Array[Double] = []
  if frames < block || block <= 0 {
    return (per_block, per_block_raw)
  }
  let mut start = 0
  while start + block <= frames {
    let mut weighted_sum = 0.0
    let mut raw_sum = 0.0
    for ch = 0; ch < channels; ch = ch + 1 {
      let w = channel_weight(ch, channels)
      let mut acc = 0.0
      for i = 0; i < block; i = i + 1 {
        // 必须带 start 偏移——漏了它就是每个块都在量开头那一段
        let v = weighted[(start + i) * channels + ch].to_double()
        acc = acc + v * v
      }
      weighted_sum = weighted_sum + w * (acc / block.to_double())
      raw_sum = raw_sum + acc / block.to_double()
    }
    per_block.push(weighted_sum)
    per_block_raw.push(raw_sum)
    start = start + hop
  }
  (per_block, per_block_raw)
}

fn to_lufs(weighted_mean_square_sum : Double) -> Double {
  if weighted_mean_square_sum <= 1.0e-12 {
    -200.0
  } else {
    LOUDNESS_OFFSET + 10.0 * @math.log10(weighted_mean_square_sum)
  }
}

///| 分位数（线性插值），输入须已升序
fn percentile_sorted(sorted : Array[Double], p : Double) -> Double {
  let n = sorted.length()
  if n == 0 {
    return 0.0
  }
  if n == 1 {
    return sorted[0]
  }
  let pos = p * (n - 1).to_double()
  let lo = pos.floor().to_int()
  let hi = if lo + 1 < n { lo + 1 } else { lo }
  let frac = pos - lo.to_double()
  sorted[lo] * (1.0 - frac) + sorted[hi] * frac
}

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

///|
/// 测量一段音频的响度（BS.1770-4 / EBU R128）。
///
/// 门限是两级的：先去掉低于 -70 LUFS 的绝对静音块，
/// 再按"已保留块的均值 - 10 LU"设相对门限——这样一段长静音不会拉低整体读数。
pub fn measure_loudness(audio : @audio.Audio) -> LoudnessResult {
  let channels = audio.channels()
  let frames = audio.frames()
  let rate = audio.sample_rate()
  let samples = audio.samples()
  // K 加权（每个声道独立滤波器状态）
  let weighted : FixedArray[Float] = FixedArray::make(frames * channels, 0.0)
  for ch = 0; ch < channels; ch = ch + 1 {
    let k = KWeighting::new(rate)
    for i = 0; i < frames; i = i + 1 {
      weighted[i * channels + ch] = Float::from_double(
        k.process_sample(samples[i * channels + ch].to_double()),
      )
    }
  }
  // 样本峰值
  let mut peak = 0.0
  for i = 0; i < samples.length(); i = i + 1 {
    let a = if samples[i].to_double() < 0.0 {
      -samples[i].to_double()
    } else {
      samples[i].to_double()
    }
    if a > peak {
      peak = a
    }
  }
  let peak_db = if peak <= 1.0e-12 {
    -200.0
  } else {
    20.0 * @math.log10(peak)
  }
  // 400 ms 块，100 ms 步进
  let block = (rate * 4) / 10
  let hop = rate / 10
  let (blocks, _) = block_mean_squares(weighted, channels, frames, block, hop)
  let total = blocks.length()
  if total == 0 {
    return {
      integrated_lufs: -200.0,
      ungated_lufs: -200.0,
      loudness_range_lu: 0.0,
      gated_blocks: 0,
      total_blocks: 0,
      sample_peak_dbfs: peak_db,
    }
  }
  // 块响度
  let block_lufs : Array[Double] = []
  for b in blocks {
    block_lufs.push(to_lufs(b))
  }
  let mut ungated_sum = 0.0
  for b in blocks {
    ungated_sum = ungated_sum + b
  }
  let ungated = to_lufs(ungated_sum / total.to_double())
  // 绝对门限 -70 LUFS
  let kept : Array[Double] = []
  for i = 0; i < total; i = i + 1 {
    if block_lufs[i] > -70.0 {
      kept.push(blocks[i])
    }
  }
  if kept.length() == 0 {
    return {
      integrated_lufs: -200.0,
      ungated_lufs: ungated,
      loudness_range_lu: 0.0,
      gated_blocks: 0,
      total_blocks: total,
      sample_peak_dbfs: peak_db,
    }
  }
  // 相对门限：已保留块的均值 - 10 LU
  let mut kept_sum = 0.0
  for b in kept {
    kept_sum = kept_sum + b
  }
  let relative_threshold = to_lufs(kept_sum / kept.length().to_double()) - 10.0
  let gated : Array[Double] = []
  for b in kept {
    if to_lufs(b) > relative_threshold {
      gated.push(b)
    }
  }
  let mut gated_sum = 0.0
  for b in gated {
    gated_sum = gated_sum + b
  }
  let integrated = if gated.length() == 0 {
    -200.0
  } else {
    to_lufs(gated_sum / gated.length().to_double())
  }
  // 响度范围：3 秒短时块、1 秒步进，取 10%~95% 分位差
  let st_block = rate * 3
  let st_hop = rate
  let (st_blocks, _) = block_mean_squares(weighted, channels, frames, st_block, st_hop)
  let st_lufs : Array[Double] = []
  for b in st_blocks {
    let l = to_lufs(b)
    if l > -70.0 {
      st_lufs.push(l)
    }
  }
  let lra = if st_lufs.length() < 2 {
    0.0
  } else {
    let sorted = sort_copy(st_lufs)
    percentile_sorted(sorted, 0.95) - percentile_sorted(sorted, 0.10)
  }
  {
    integrated_lufs: integrated,
    ungated_lufs: ungated,
    loudness_range_lu: lra,
    gated_blocks: gated.length(),
    total_blocks: total,
    sample_peak_dbfs: peak_db,
  }
}

///| 便捷入口：直接拿积分响度（LUFS）
pub fn loudness_lufs(audio : @audio.Audio) -> Double {
  measure_loudness(audio).integrated_lufs
}
