///|
/// moonvoice/feature — mel 标度、mel 滤波器组、log-mel 与 MFCC
///
/// 这是语音识别前端的标准链路：
///   波形 → STFT → 功率谱 → mel 滤波器组 → log → (DCT → MFCC)
///
/// 为什么用 mel 而不是线性频率：人耳对低频的分辨力远高于高频，
/// mel 标度把"等听觉距离"映射成等间隔，让后面的模型不必自己学这件事。
///
/// 标度约定：默认用 **Slaney**（`hz_to_mel` 在 1 kHz 以下线性、以上对数，
/// 与 librosa 默认一致），滤波器用 **Slaney 面积归一化**。
/// 这两条约定直接决定数值，不按它们实现就对不上任何现有工具链。

///| mel 标度类型
pub(all) enum MelScale {
  /// Slaney（librosa 默认）：1 kHz 以下线性，以上对数
  Slaney
  /// HTK（Kaldi/传统语音工具常用）：单一对数公式
  Htk
}

///| Hz → mel
pub fn hz_to_mel(f : Double, scale? : MelScale = Slaney) -> Double {
  match scale {
    Htk => 2595.0 * @math.log10(1.0 + f / 700.0)
    Slaney => {
      let f_sp = 200.0 / 3.0 // 1 kHz 以下每 mel 200/3 Hz
      let min_log_hz = 1000.0
      let min_log_mel = min_log_hz / f_sp // = 15
      let logstep = @math.ln(6.4) / 27.0
      if f < min_log_hz {
        f / f_sp
      } else {
        min_log_mel + @math.ln(f / min_log_hz) / logstep
      }
    }
  }
}

///| mel → Hz
pub fn mel_to_hz(m : Double, scale? : MelScale = Slaney) -> Double {
  match scale {
    Htk => 700.0 * (@math.pow(10.0, m / 2595.0) - 1.0)
    Slaney => {
      let f_sp = 200.0 / 3.0
      let min_log_hz = 1000.0
      let min_log_mel = min_log_hz / f_sp
      let logstep = @math.ln(6.4) / 27.0
      if m < min_log_mel {
        m * f_sp
      } else {
        min_log_hz * @math.exp(logstep * (m - min_log_mel))
      }
    }
  }
}

///| 等间隔 mel 点上对应的频率（共 count 个，从 f_min 到 f_max）
pub fn mel_frequencies(
  count : Int,
  f_min : Double,
  f_max : Double,
  scale? : MelScale = Slaney,
) -> FixedArray[Double] {
  let out : FixedArray[Double] = FixedArray::make(count, 0.0)
  if count <= 0 {
    return out
  }
  let m_lo = hz_to_mel(f_min, scale~)
  let m_hi = hz_to_mel(f_max, scale~)
  for i = 0; i < count; i = i + 1 {
    let t = if count == 1 { 0.0 } else { i.to_double() / (count - 1).to_double() }
    out[i] = mel_to_hz(m_lo + (m_hi - m_lo) * t, scale~)
  }
  out
}

///|
/// mel 滤波器组：一组三角滤波器，把线性频率的功率谱压成 n_mels 个带。
///
/// 与 librosa.filters.mel(norm='slaney') 一致：每个三角滤波器按
/// **2 / (上边界频率 - 下边界频率)** 归一化——这是"面积归一化"，
/// 让每个 mel 带对白噪声给出等能量输出。不做这一步，高频带会系统性偏小。
pub struct MelFilterbank {
  n_mels : Int
  n_bins : Int
  scale : MelScale
  /// 扁平存储的三角权重：第 i 个滤波器覆盖 [start[i], start[i]+len[i])
  weights : FixedArray[Double]
  offsets : Array[Int]
  lengths : Array[Int]
}

pub fn MelFilterbank::new(
  n_mels : Int,
  n_fft : Int,
  sample_rate : Int,
  f_min? : Double = 0.0,
  f_max? : Double = 0.0,
  scale? : MelScale = Slaney,
) -> MelFilterbank {
  let n_bins = n_fft / 2 + 1
  let nyquist = sample_rate.to_double() / 2.0
  let f_hi = if f_max <= 0.0 || f_max > nyquist { nyquist } else { f_max }
  // n_mels + 2 个边界点：每个滤波器用相邻三点构成三角
  let edges = mel_frequencies(n_mels + 2, f_min, f_hi, scale~)
  let bin_hz = sample_rate.to_double() / n_fft.to_double()
  let weights : FixedArray[Double] = FixedArray::make(n_mels * n_bins, 0.0)
  let offsets : Array[Int] = []
  let lengths : Array[Int] = []
  for m = 0; m < n_mels; m = m + 1 {
    let lo = edges[m]
    let mid = edges[m + 1]
    let hi = edges[m + 2]
    let enorm = 2.0 / (hi - lo)
    let first = if lo > 0.0 {
      (lo / bin_hz).ceil().to_int()
    } else {
      0
    }
    let mut last = (hi / bin_hz).floor().to_int() + 1
    if last > n_bins {
      last = n_bins
    }
    let mut start = -1
    let mut len = 0
    for b = first; b < last; b = b + 1 {
      let f = b.to_double() * bin_hz
      // 上升沿 / 下降沿
      let w = if f <= mid {
        (f - lo) / (mid - lo)
      } else {
        (hi - f) / (hi - mid)
      }
      if w > 0.0 {
        if start < 0 {
          start = b
        }
        len = len + 1
        weights[m * n_bins + b] = w * enorm
      }
    }
    if start < 0 {
      start = 0
    }
    offsets.push(start)
    lengths.push(len)
  }
  { n_mels, n_bins, scale, weights, offsets, lengths }
}

pub fn MelFilterbank::n_mels(self : MelFilterbank) -> Int {
  self.n_mels
}

pub fn MelFilterbank::n_bins(self : MelFilterbank) -> Int {
  self.n_bins
}

///| 把一帧功率谱（长度 n_bins）投影到 mel 带
pub fn MelFilterbank::apply(
  self : MelFilterbank,
  power : FixedArray[Double],
) -> FixedArray[Double] {
  let out : FixedArray[Double] = FixedArray::make(self.n_mels, 0.0)
  for m = 0; m < self.n_mels; m = m + 1 {
    let start = self.offsets[m]
    let len = self.lengths[m]
    let mut acc = 0.0
    for k = 0; k < len; k = k + 1 {
      let b = start + k
      if b < power.length() {
        acc = acc + power[b] * self.weights[m * self.n_bins + b]
      }
    }
    out[m] = acc
  }
  out
}

///| 滤波器组矩阵（n_mels × n_bins），便于与外部实现逐点比对
pub fn MelFilterbank::matrix(self : MelFilterbank) -> FixedArray[Double] {
  self.weights
}

///|
/// 功率 → dB。与 librosa.power_to_db 的约定一致：
/// 相对 `ref` 取对数，并对结果做 `top_db` 下限截断（默认 80 dB 动态范围）。
pub fn power_to_db(
  power : FixedArray[Double],
  ref_power? : Double = 1.0,
  top_db? : Double = 80.0,
) -> FixedArray[Double] {
  let out : FixedArray[Double] = FixedArray::make(power.length(), 0.0)
  let floor = 1.0e-10
  for i = 0; i < power.length(); i = i + 1 {
    let p = if power[i] > floor { power[i] } else { floor }
    out[i] = 10.0 * @math.log10(p / ref_power)
  }
  if top_db > 0.0 {
    let mut peak = -1.0e30
    for v in out {
      if v > peak {
        peak = v
      }
    }
    let lowest = peak - top_db
    for i = 0; i < out.length(); i = i + 1 {
      if out[i] < lowest {
        out[i] = lowest
      }
    }
  }
  out
}
