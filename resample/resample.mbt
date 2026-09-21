///|
/// moonvoice/resample — 多相窗函数 sinc 重采样（纯 MoonBit，无 FFI）
///
/// 做法与取舍：
/// - **有理数速率变换**：把 from/to 约分成 up/down（L/M），滤波器在"上采样域"设计，
///   再做多相分解——复杂度是 O(输出样本数 × 每相抽头数)，与 L 无关。
///   直接做"插零 + 全卷积 + 抽取"会是 O(N×L×taps)，44100→48000 这种 L=160 的比
///   会慢 160 倍，不可接受。
/// - **窗函数 sinc（Kaiser 窗）**：阻带衰减由 β 控制，过渡带宽度由抽头数控制。
///   截止频率取输出 Nyquist（0.5/max(L,M)），所以通带内平坦、Nyquist 处 -6 dB，
///   再往上是阻带——这正是抽取需要的抗混叠形状。
/// - **边界补零**：与 scipy.signal.resample_poly 的默认约定一致，便于对拍。
/// - 系数算在 Double、存 Float，累加用 Double：f32 累加 150 抽头仍够用，
///   但 Double 累加让"与参照实现比对"的信噪比不受累加误差污染。
///
/// 质量档由**零交叉数 ZC** 与**目标阻带衰减 A(dB)** 共同决定，实测值见 README。

///| 重采样质量档
pub(all) enum Quality {
  Fast // ZC=8
  Balanced // ZC=24（默认）
  Best // ZC=64
}

fn zero_crossings(q : Quality) -> Int {
  match q {
    Fast => 8
    Balanced => 24
    Best => 64
  }
}

///| 目标阻带衰减（Kaiser β 由它推出）
fn stopband_db(q : Quality) -> Double {
  match q {
    Fast => 60.0
    Balanced => 80.0
    Best => 100.0
  }
}

///| 欧几里得最大公约数
pub fn gcd(a : Int, b : Int) -> Int {
  let mut x = if a < 0 { -a } else { a }
  let mut y = if b < 0 { -b } else { b }
  while y != 0 {
    let t = x % y
    x = y
    y = t
  }
  x
}

///| 第 0 类修正贝塞尔函数 I0(x)，级数展开足够（x ≤ 12 时 30 项远超精度需求）
fn bessel_i0(x : Double) -> Double {
  let half = x / 2.0
  let mut term = 1.0
  let mut sum = 1.0
  for k = 1; k < 40; k = k + 1 {
    term = term * (half / k.to_double()) * (half / k.to_double())
    sum = sum + term
    if term < 1.0e-18 * sum {
      break
    }
  }
  sum
}

///| 归一化 sinc：sin(πx)/(πx)
fn sinc(x : Double) -> Double {
  if x == 0.0 {
    1.0
  } else {
    let px = @math.PI * x
    @math.sin(px) / px
  }
}

///|
/// 设计多相滤波器组。
///
/// - `up`/`down`：上/下采样因子（已约分）
/// - 返回 `(coeffs, taps)`：coeffs 按相位优先排布，长度 up*taps
fn design_polyphase(
  up : Int,
  down : Int,
  zc : Int,
  atten_db : Double,
) -> (FixedArray[Float], Int) {
  let max_rate = if up > down { up } else { down }
  let n_taps = 2 * zc * max_rate + 1 // 总长度（上采样域），保证奇数以对齐中心
  let center = n_taps / 2
  let taps = (n_taps + up - 1) / up
  let coeffs : FixedArray[Float] = FixedArray::make(up * taps, 0.0)
  // Kaiser：A > 50 dB 时 beta = 0.1102(A - 8.7)
  let beta = 0.1102 * (atten_db - 8.7)
  let denom = bessel_i0(beta)
  let fc = 0.5 / max_rate.to_double() // 截止（周期/上采样样本）
  let gain = up.to_double() // 补偿插零带来的能量下降
  for phase = 0; phase < up; phase = phase + 1 {
    for k = 0; k < taps; k = k + 1 {
      let n = phase + k * up
      if n < n_taps {
        let t = (n - center).to_double()
        let u = 2.0 * n.to_double() / (n_taps - 1).to_double() - 1.0
        let w = bessel_i0(beta * (1.0 - u * u).sqrt()) / denom
        let h = gain * 2.0 * fc * sinc(2.0 * fc * t) * w
        coeffs[phase * taps + k] = Float::from_double(h)
      }
    }
  }
  (coeffs, taps)
}

///|
/// 重采样器：构造一次，可反复用于多段音频。
pub struct Resampler {
  up : Int
  down : Int
  taps : Int
  center : Int
  coeffs : FixedArray[Float]
  from_rate : Int
  to_rate : Int
}

///|
/// 由采样率构造。同速率会退化成恒等（过滤器退化为单位冲激）。
pub fn Resampler::new(
  from_rate : Int,
  to_rate : Int,
  quality? : Quality = Balanced,
) -> Resampler raise @audio.AudioError {
  if from_rate <= 0 || to_rate <= 0 {
    raise @audio.InvalidFormat(
      "invalid sample rates: " + from_rate.to_string() + " -> " + to_rate.to_string(),
    )
  }
  let g = gcd(from_rate, to_rate)
  let up = to_rate / g
  let down = from_rate / g
  let zc = zero_crossings(quality)
  let (coeffs, taps) = design_polyphase(up, down, zc, stopband_db(quality))
  let center = (2 * zc * (if up > down { up } else { down }) + 1) / 2
  { up, down, taps, center, coeffs, from_rate, to_rate }
}

pub fn Resampler::up(self : Resampler) -> Int {
  self.up
}

pub fn Resampler::down(self : Resampler) -> Int {
  self.down
}

pub fn Resampler::taps(self : Resampler) -> Int {
  self.taps
}

///| 滤波器组长度（上采样域抽头总数）
pub fn Resampler::filter_length(self : Resampler) -> Int {
  2 * self.center + 1
}

///| 给定输入帧数时的输出帧数（与 scipy.signal.resample_poly 一致：向上取整）
pub fn Resampler::output_frames(self : Resampler, in_frames : Int) -> Int {
  if in_frames <= 0 {
    0
  } else {
    let n = in_frames.to_double() * self.up.to_double() / self.down.to_double()
    let floored = n.to_int()
    if floored.to_double() < n {
      floored + 1
    } else {
      floored
    }
  }
}

///|
/// 处理交错多声道样本。
///
/// 边界按零填充（与 scipy 默认一致）。相位/基址用增量推进而不是每帧重算
/// `j*down`，既省乘法也避免长音频下的 Int 溢出。
pub fn Resampler::process(
  self : Resampler,
  input : FixedArray[Float],
  in_frames : Int,
  channels : Int,
) -> FixedArray[Float] {
  let n_out = self.output_frames(in_frames)
  let out : FixedArray[Float] = FixedArray::make(n_out * channels, 0.0)
  if channels <= 0 {
    return out
  }
  // 恒等直通：同速率必须逐位相同。走卷积虽然理论上也是单位冲激，
  // 但 sinc(整数) 在浮点下并不精确为 0（残差 ~1e-17），没必要付这个代价。
  if self.up == 1 && self.down == 1 {
    let n = in_frames * channels
    for i = 0; i < n && i < input.length(); i = i + 1 {
      out[i] = input[i]
    }
    return out
  }
  let mut j = 0
  // idx = j*down + center 拆成 (base, phase)，phase 恒在 [0, up)
  let mut base = self.center / self.up
  let mut phase = self.center % self.up
  let phase_k = self.taps
  let coeffs = self.coeffs
  while j < n_out {
    // 有效抽头区间先算一次，内层循环里**不再做边界判断**。
    // 原实现在每个抽头上都要比两次（xi >= 0 && xi < in_frames），
    // 而边界只影响首尾各 taps 个输出样本——把判断提到循环外是纯粹的净收益。
    let k_lo = if base - in_frames + 1 > 0 { base - in_frames + 1 } else { 0 }
    let k_hi = if base < phase_k - 1 { base } else { phase_k - 1 }
    let cbase = phase * phase_k
    for ch = 0; ch < channels; ch = ch + 1 {
      let mut acc = 0.0
      for k = k_lo; k <= k_hi; k = k + 1 {
        acc = acc +
          input[(base - k) * channels + ch].to_double() *
          coeffs[cbase + k].to_double()
      }
      out[j * channels + ch] = Float::from_double(acc)
    }
    j = j + 1
    phase = phase + self.down
    if phase >= self.up {
      base = base + phase / self.up
      phase = phase % self.up
    }
  }
  out
}

///|
/// 对 `Audio` 做重采样（声道数、交错布局保持不变）。
///
/// 注意：RIFF 保留块会原样带过去。对 `cue `/`adtl` 这类**含字节偏移**的块，
/// 重采样后其偏移已失效——需要精确保留元数据的场景请自行处理。
pub fn resample_audio(
  audio : @audio.Audio,
  to_rate : Int,
  quality? : Quality = Balanced,
) -> @audio.Audio raise @audio.AudioError {
  let from_rate = audio.sample_rate()
  if from_rate == to_rate {
    return audio
  }
  let r = Resampler::new(from_rate, to_rate, quality~)
  let channels = audio.channels()
  let in_frames = audio.frames()
  let out = r.process(audio.samples(), in_frames, channels)
  let resampled = @audio.Audio::new(to_rate, channels, out).with_extra_chunks(
    audio.extra_chunks(),
  )
  // 保留来源格式：否则 24-bit 素材重采样后会被无声降级成 16-bit
  match audio.source_format() {
    Some(f) => resampled.with_source_format(f)
    None => resampled
  }
}
