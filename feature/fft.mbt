///|
/// moonvoice/feature — 频谱基元（FFT / 窗函数 / 功率谱）
///
/// 设计取舍：
/// - **就地 radix-2 迭代 FFT**：语音帧长固定为 2 的幂（256/512/1024），
///   迭代版没有递归开销、没有分配，适合逐帧调用；也不需要处理任意长度的旋转因子表。
/// - 复数用两个 `FixedArray[Double]` 表达，不引入结构体数组：
///   少一层间接、少一次解引用，逐帧热路径上划算。
/// - 全部用 Double：谱能量的动态范围大（>100 dB），f32 累加会在地板附近失真，
///   而特征值本身对精度敏感（VAD 的判决就是几 dB 的事）。

///|
/// 可复用的 FFT 分析器。
///
/// 为什么需要它（先测再改，数字来自 benches）：
/// 自由函数版 `power_spectrum` 每次调用要分配两个 n 点 Double 缓冲（n=512 时 8 KB），
/// 旋转因子又在蝶形里用递推现算——实测 61 µs/次，直接把 VAD 卡在 419 倍实时。
/// 这里做两件事：
///   1. **旋转因子查表**：构造时算一次，热路径里只剩乘加（顺带消掉递推的误差累积）；
///   2. **缓冲复用**：时域/频域缓冲归分析器所有，逐帧调用零分配。
pub struct Fft {
  n : Int
  re : FixedArray[Double]
  im : FixedArray[Double]
  cos_tab : FixedArray[Double]
  sin_tab : FixedArray[Double]
}

///| 构造。`n` 必须是 2 的幂。
pub fn Fft::new(n : Int) -> Fft {
  if n <= 0 || (n & (n - 1)) != 0 {
    abort("Fft::new: n 必须是 2 的幂")
  }
  let half = n / 2
  let cos_tab : FixedArray[Double] = FixedArray::make(half, 1.0)
  let sin_tab : FixedArray[Double] = FixedArray::make(half, 0.0)
  for k = 0; k < half; k = k + 1 {
    let ang = -2.0 * @math.PI * k.to_double() / n.to_double()
    cos_tab[k] = @math.cos(ang)
    sin_tab[k] = @math.sin(ang)
  }
  {
    n,
    re: FixedArray::make(n, 0.0),
    im: FixedArray::make(n, 0.0),
    cos_tab,
    sin_tab,
  }
}

pub fn Fft::size(self : Fft) -> Int {
  self.n
}

///| 频域缓冲（长度 n/2+1 的功率谱写到这里）
pub fn Fft::spectrum_len(self : Fft) -> Int {
  self.n / 2 + 1
}

///| 就地 FFT（用查表旋转因子），结果留在 re/im
fn Fft::transform(self : Fft) -> Unit {
  let n = self.n
  let re = self.re
  let im = self.im
  // 位反转置换
  let mut j = 0
  for i = 1; i < n; i = i + 1 {
    let mut bit = n / 2
    while (j & bit) != 0 {
      j = j ^ bit
      bit = bit / 2
    }
    j = j | bit
    if i < j {
      let tr = re[i]
      re[i] = re[j]
      re[j] = tr
      let ti = im[i]
      im[i] = im[j]
      im[j] = ti
    }
  }
  // 蝶形：旋转因子按 k*(n/len) 查表
  let mut len = 2
  while len <= n {
    let stride = n / len
    let half = len / 2
    let mut i = 0
    while i < n {
      let mut idx = 0
      for k = 0; k < half; k = k + 1 {
        let wr = self.cos_tab[idx]
        let wi = self.sin_tab[idx]
        let ur = re[i + k]
        let ui = im[i + k]
        let vr = re[i + k + half] * wr - im[i + k + half] * wi
        let vi = re[i + k + half] * wi + im[i + k + half] * wr
        re[i + k] = ur + vr
        im[i + k] = ui + vi
        re[i + k + half] = ur - vr
        im[i + k + half] = ui - vi
        idx = idx + stride
      }
      i = i + len
    }
    len = len * 2
  }
}

///|
/// 加 Hann 窗并做 FFT，功率谱写入 `out`（长度须为 n/2+1）。
/// 全程零分配——热路径上逐帧调用它。
pub fn Fft::power_into(self : Fft, x : FixedArray[Float], out : FixedArray[Double]) -> Unit {
  let n = self.n
  let re = self.re
  let im = self.im
  let last = (n - 1).to_double()
  let m = x.length()
  for i = 0; i < n; i = i + 1 {
    if i < m {
      let w = 0.5 * (1.0 - @math.cos(2.0 * @math.PI * i.to_double() / last))
      re[i] = x[i].to_double() * w
    } else {
      re[i] = 0.0
    }
    im[i] = 0.0
  }
  self.transform()
  let half = n / 2 + 1
  for i = 0; i < half && i < out.length(); i = i + 1 {
    out[i] = re[i] * re[i] + im[i] * im[i]
  }
}

///| 便利版：自己分配输出（非热路径用；热路径请用 `power_into`）
pub fn Fft::power(self : Fft, x : FixedArray[Float]) -> FixedArray[Double] {
  let out : FixedArray[Double] = FixedArray::make(self.spectrum_len(), 0.0)
  self.power_into(x, out)
  out
}

///| 不小于 n 的最小 2 的幂
pub fn next_pow2(n : Int) -> Int {
  let mut p = 1
  while p < n {
    p = p * 2
  }
  p
}

///|
/// 就地 FFT（radix-2，Cooley-Tukey，迭代实现）。
/// 要求 `re.length() == im.length()` 且长度为 2 的幂。
pub fn fft_in_place(re : FixedArray[Double], im : FixedArray[Double]) -> Unit {
  let n = re.length()
  if n <= 1 {
    return
  }
  if (n & (n - 1)) != 0 {
    abort("fft_in_place: 长度必须是 2 的幂")
  }
  // 位反转置换
  let mut j = 0
  for i = 1; i < n; i = i + 1 {
    let mut bit = n / 2
    while (j & bit) != 0 {
      j = j ^ bit
      bit = bit / 2
    }
    j = j | bit
    if i < j {
      let tr = re[i]
      re[i] = re[j]
      re[j] = tr
      let ti = im[i]
      im[i] = im[j]
      im[j] = ti
    }
  }
  // 蝶形
  let mut len = 2
  while len <= n {
    let ang = -2.0 * @math.PI / len.to_double()
    let wr = @math.cos(ang)
    let wi = @math.sin(ang)
    let mut i = 0
    while i < n {
      let mut cr = 1.0
      let mut ci = 0.0
      for k = 0; k < len / 2; k = k + 1 {
        let ur = re[i + k]
        let ui = im[i + k]
        let vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci
        let vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr
        re[i + k] = ur + vr
        im[i + k] = ui + vi
        re[i + k + len / 2] = ur - vr
        im[i + k + len / 2] = ui - vi
        let ncr = cr * wr - ci * wi
        ci = cr * wi + ci * wr
        cr = ncr
      }
      i = i + len
    }
    len = len * 2
  }
}

///|
/// 单边功率谱（周期图），长度 `n_fft/2 + 1`。
///
/// 输入帧不足 `n_fft` 时补零，超出时截断；加 Hann 窗降低旁瓣泄漏。
/// 返回值单位是"功率"（幅度平方和），未做 1/N 归一化——VAD 只关心相对关系。
pub fn power_spectrum(x : FixedArray[Float], n_fft : Int) -> FixedArray[Double] {
  let re : FixedArray[Double] = FixedArray::make(n_fft, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n_fft, 0.0)
  let n = x.length()
  for i = 0; i < n && i < n_fft; i = i + 1 {
    // Hann 窗
    let w = 0.5 * (1.0 - @math.cos(2.0 * @math.PI * i.to_double() / (n_fft - 1).to_double()))
    re[i] = x[i].to_double() * w
  }
  fft_in_place(re, im)
  let half = n_fft / 2 + 1
  let out : FixedArray[Double] = FixedArray::make(half, 0.0)
  for i = 0; i < half; i = i + 1 {
    out[i] = re[i] * re[i] + im[i] * im[i]
  }
  out
}

///|
/// 把功率谱按采样率切成若干频带，返回每带能量。
///
/// `edges_hz` 是频带上边界（升序，最后一个通常为 Nyquist），
/// 返回长度 = edges_hz.length()。
pub fn band_energies(
  spectrum : FixedArray[Double],
  sample_rate : Int,
  n_fft : Int,
  edges_hz : Array[Double],
) -> FixedArray[Double] {
  let n_bands = edges_hz.length()
  let out : FixedArray[Double] = FixedArray::make(n_bands, 0.0)
  let half = spectrum.length()
  let bin_hz = sample_rate.to_double() / n_fft.to_double()
  let mut b = 0
  for i = 0; i < half; i = i + 1 {
    let f = i.to_double() * bin_hz
    // 找到 f 所属频带（edges 升序）
    while b < n_bands - 1 && f > edges_hz[b] {
      b = b + 1
    }
    out[b] = out[b] + spectrum[i]
  }
  out
}

///|
/// 谱平坦度 = 几何平均 / 算术平均（0..1）。
/// 白噪声接近 1，谐波/语音接近 0 —— 这是区分"结构化声音"与"噪声"的核心特征。
pub fn spectral_flatness(spectrum : FixedArray[Double], from_bin : Int, to_bin : Int) -> Double {
  let mut log_sum = 0.0
  let mut arith = 0.0
  let mut n = 0
  for i = from_bin; i < to_bin && i < spectrum.length(); i = i + 1 {
    // 加下限避免 log(0)：功率谱动态范围大，用 1e-30 作地板
    let p = if spectrum[i] > 1.0e-30 { spectrum[i] } else { 1.0e-30 }
    log_sum = log_sum + @math.ln(p)
    arith = arith + p
    n = n + 1
  }
  if n == 0 || arith <= 0.0 {
    return 0.0
  }
  let geo = @math.exp(log_sum / n.to_double())
  let am = arith / n.to_double()
  if am <= 0.0 {
    0.0
  } else {
    geo / am
  }
}

///|
/// 谱熵（归一化到 [0,1]）：功率分布越集中越小，越白噪声越接近 1。
pub fn spectral_entropy(spectrum : FixedArray[Double], from_bin : Int, to_bin : Int) -> Double {
  let mut total = 0.0
  let mut n = 0
  for i = from_bin; i < to_bin && i < spectrum.length(); i = i + 1 {
    total = total + spectrum[i]
    n = n + 1
  }
  if n == 0 || total <= 0.0 {
    return 0.0
  }
  let mut h = 0.0
  for i = from_bin; i < to_bin && i < spectrum.length(); i = i + 1 {
    let p = spectrum[i] / total
    if p > 1.0e-12 {
      h = h - p * @math.ln(p)
    }
  }
  h / @math.ln(n.to_double())
}
