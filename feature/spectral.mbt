///|
/// moonvoice/feature — 逐帧谱特征
///
/// 这些是音频分析的"形容词"：一段声音亮不亮（质心）、宽不宽（带宽）、
/// 变化快不快（流量）、有没有结构（平坦度/熵）。
/// 单个特征都不强，但组合起来是音乐信息检索、异常检测、VAD 的通用素材。
///
/// 全部以**功率谱**为输入（长度 n_bins），单位一致性由调用者保证。

///| 一帧的谱特征集合
pub struct SpectralFrame {
  /// 谱质心（Hz）：能量的"重心"，直观对应亮度
  centroid_hz : Double
  /// 谱带宽（Hz）：围绕质心的展开程度
  bandwidth_hz : Double
  /// 谱滚降（Hz）：累积能量达到 `roll_percent` 处的频率
  rolloff_hz : Double
  /// 谱平坦度（0~1）：几何均值/算术均值，噪声接近上限、谐波接近 0
  flatness : Double
  /// 归一化谱熵（0~1）：能量分布的分散程度
  entropy : Double
  /// 过零率（0~1）：时域特征，清辅音高、浊音低
  zcr : Double
}

pub fn SpectralFrame::centroid_hz(self : SpectralFrame) -> Double {
  self.centroid_hz
}

pub fn SpectralFrame::bandwidth_hz(self : SpectralFrame) -> Double {
  self.bandwidth_hz
}

pub fn SpectralFrame::rolloff_hz(self : SpectralFrame) -> Double {
  self.rolloff_hz
}

pub fn SpectralFrame::flatness(self : SpectralFrame) -> Double {
  self.flatness
}

pub fn SpectralFrame::entropy(self : SpectralFrame) -> Double {
  self.entropy
}

pub fn SpectralFrame::zcr(self : SpectralFrame) -> Double {
  self.zcr
}

///|
/// 从功率谱算谱特征。
///
/// `bin_hz` = sample_rate / n_fft；`roll_percent` 是滚降阈值（常用 0.85）。
pub fn spectral_frame(
  power : FixedArray[Double],
  bin_hz : Double,
  roll_percent? : Double = 0.85,
) -> SpectralFrame {
  let n = power.length()
  let mut total = 0.0
  for i = 0; i < n; i = i + 1 {
    total = total + power[i]
  }
  if n == 0 || total <= 0.0 {
    return {
      centroid_hz: 0.0,
      bandwidth_hz: 0.0,
      rolloff_hz: 0.0,
      flatness: 0.0,
      entropy: 0.0,
      zcr: 0.0,
    }
  }
  let mut centroid = 0.0
  for i = 0; i < n; i = i + 1 {
    centroid = centroid + i.to_double() * bin_hz * power[i]
  }
  centroid = centroid / total
  let mut var_sum = 0.0
  for i = 0; i < n; i = i + 1 {
    let d = i.to_double() * bin_hz - centroid
    var_sum = var_sum + d * d * power[i]
  }
  let bandwidth = (var_sum / total).sqrt()
  // 滚降：从低到高累积，第一次达到阈值处
  let target = total * roll_percent
  let mut acc = 0.0
  let mut rolloff = 0.0
  for i = 0; i < n; i = i + 1 {
    acc = acc + power[i]
    if acc >= target {
      rolloff = i.to_double() * bin_hz
      break
    }
  }
  {
    centroid_hz: centroid,
    bandwidth_hz: bandwidth,
    rolloff_hz: rolloff,
    flatness: spectral_flatness(power, 0, n),
    entropy: spectral_entropy(power, 0, n),
    zcr: 0.0, // 时域量，需波形才能算；由 spectral_frame_with_wave 填
  }
}

///|
/// 谱流量：相邻两帧功率谱的欧氏距离（归一化后）。
/// 衡量"这一帧比上一帧变了多少"——语音起始点检测、音乐结构分析的常用特征。
pub fn spectral_flux(
  prev : FixedArray[Double],
  cur : FixedArray[Double],
) -> Double {
  let n = if prev.length() < cur.length() { prev.length() } else { cur.length() }
  if n == 0 {
    return 0.0
  }
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let d = cur[i] - prev[i]
    acc = acc + d * d
  }
  (acc / n.to_double()).sqrt()
}

///| 过零率：波形符号变化的比例（0~1）
pub fn zero_crossing_rate(wave : FixedArray[Float], from : Int, to : Int) -> Double {
  let n = to - from
  if n <= 1 {
    return 0.0
  }
  let mut crossings = 0
  let mut prev = wave[from].to_double()
  for i = from + 1; i < to; i = i + 1 {
    let v = wave[i].to_double()
    if (v >= 0.0) != (prev >= 0.0) {
      crossings = crossings + 1
    }
    prev = v
  }
  crossings.to_double() / (n - 1).to_double()
}
