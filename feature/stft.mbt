///|
/// moonvoice/feature — 短时傅里叶变换（STFT）与其逆变换
///
/// STFT 是音频分析的**中心原语**：VAD、mel 特征、谱图、降噪、变调全都建在它上面。
/// 这里提供的是"能重构"的完整实现——不是只能画图的那一半。
///
/// 三条设计约定：
/// - **零填充**：帧不足 n_fft 时补零（与 scipy.signal.stft 一致）
/// - **完全重构**：`istft(stft(x)) ≈ x`，前提是窗满足 COLA（Hann + 50%~75% 重叠即满足）。
///   这条性质本身就是最强的一致性测试，见 stft_test.mbt
/// - **零分配热路径**：`magnitude_into` / `phase_into` 写进调用者给的缓冲

///| STFT 分析器（持有窗、FFT 与内部缓冲）
pub struct Stft {
  n_fft : Int
  hop : Int
  window_kind : Window
  window : FixedArray[Double]
  fft : Fft
  // 加窗后的时域缓冲
  frame : Array[Double]
  re : Array[Double]
  im : Array[Double]
}

///|
/// 构造。`hop` 是帧移（样本数）：hop = n_fft/2 为 50% 重叠（常用），
/// n_fft/4 为 75% 重叠（时间分辨率更高）。
pub fn Stft::new(n_fft : Int, hop : Int, window? : Window = Hann) -> Stft {
  if (n_fft & (n_fft - 1)) != 0 || n_fft <= 0 {
    abort("Stft::new: n_fft 必须是 2 的幂")
  }
  if hop <= 0 || hop > n_fft {
    abort("Stft::new: hop 必须在 (0, n_fft] 内")
  }
  {
    n_fft,
    hop,
    window_kind: window,
    window: window_coefficients(window, n_fft),
    fft: Fft::new(n_fft),
    frame: Array::make(n_fft, 0.0),
    re: Array::make(n_fft, 0.0),
    im: Array::make(n_fft, 0.0),
  }
}

pub fn Stft::n_fft(self : Stft) -> Int {
  self.n_fft
}

pub fn Stft::hop(self : Stft) -> Int {
  self.hop
}

///| 每帧的频点数（单边）
pub fn Stft::bins(self : Stft) -> Int {
  self.n_fft / 2 + 1
}

pub fn Stft::window_kind(self : Stft) -> Window {
  self.window_kind
}

///|
/// 给定信号长度时的帧数。
/// 与 scipy.signal.stft 的约定一致：帧起点取 0, hop, 2*hop, ... 直到不足一帧。
pub fn Stft::frame_count(self : Stft, n_samples : Int) -> Int {
  if n_samples < self.n_fft {
    1 // 不足一帧也会补零算一帧
  } else {
    (n_samples - self.n_fft) / self.hop + 1
  }
}

///|
/// 逐帧做 FFT，把**复数谱**写进调用者的缓冲。
/// `out_re` / `out_im` 长度须 ≥ frame_count * bins。
pub fn Stft::transform_into(
  self : Stft,
  x : FixedArray[Float],
  out_re : FixedArray[Double],
  out_im : FixedArray[Double],
) -> Unit {
  let n = self.n_fft
  let bins = self.bins()
  let n_frames = self.frame_count(x.length())
  let frame = self.frame
  let re = self.re
  let im = self.im
  let w = self.window
  let mut f = 0
  while f < n_frames {
    let offset = f * self.hop
    for i = 0; i < n; i = i + 1 {
      let s = offset + i
      let v = if s < x.length() { x[s].to_double() } else { 0.0 }
      frame[i] = v * w.unsafe_get(i)
      re[i] = frame[i]
      im[i] = 0.0
    }
    self.fft.transform_with(re, im)
    for b = 0; b < bins; b = b + 1 {
      out_re[f * bins + b] = re[b]
      out_im[f * bins + b] = im[b]
    }
    f = f + 1
  }
}

///|
/// 只要幅度谱的常用入口（长度 = frame_count * bins）。
pub fn Stft::magnitude(self : Stft, x : FixedArray[Float]) -> FixedArray[Double] {
  let bins = self.bins()
  let n_frames = self.frame_count(x.length())
  let out : FixedArray[Double] = FixedArray::make(n_frames * bins, 0.0)
  let re : FixedArray[Double] = FixedArray::make(n_frames * bins, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n_frames * bins, 0.0)
  self.transform_into(x, re, im)
  for i = 0; i < out.length(); i = i + 1 {
    out[i] = (re[i] * re[i] + im[i] * im[i]).sqrt()
  }
  out
}

///|
/// 逆变换（重叠相加 + 窗归一化），返回重建信号。
///
/// 归一化用的是**窗的平方和**（不是窗本身）：分析加了一次窗、合成再加一次，
/// 只有除以窗平方和的包络才能让幅度完全还原。
pub fn Stft::inverse(
  self : Stft,
  re : FixedArray[Double],
  im : FixedArray[Double],
) -> FixedArray[Float] {
  let n = self.n_fft
  let bins = self.bins()
  let n_frames = re.length() / bins
  // 重建长度：最后一帧的起点 + n_fft
  let out_len = if n_frames == 0 { 0 } else { (n_frames - 1) * self.hop + n }
  let acc : Array[Double] = Array::make(out_len, 0.0)
  let norm : Array[Double] = Array::make(out_len, 0.0)
  let buf_re : Array[Double] = Array::make(n, 0.0)
  let buf_im : Array[Double] = Array::make(n, 0.0)
  let w = self.window
  let mut f = 0
  while f < n_frames {
    // 填共轭对称的全谱
    for b = 0; b < bins; b = b + 1 {
      buf_re[b] = re[f * bins + b]
      buf_im[b] = im[f * bins + b]
    }
    for b = bins; b < n; b = b + 1 {
      let mirror = n - b
      buf_re[b] = re[f * bins + mirror]
      buf_im[b] = -im[f * bins + mirror]
    }
    self.fft.inverse_transform_with(buf_re, buf_im)
    let offset = f * self.hop
    for i = 0; i < n; i = i + 1 {
      let s = offset + i
      if s < out_len {
        let wv = w.unsafe_get(i)
        // 逆 FFT 已在 inverse_transform_with 里除过 n，这里不再除
        acc[s] = acc[s] + buf_re[i] * wv
        norm[s] = norm[s] + wv * wv
      }
    }
    f = f + 1
  }
  let out : FixedArray[Float] = FixedArray::make(out_len, 0.0)
  for i = 0; i < out_len; i = i + 1 {
    let d = norm[i]
    out[i] = Float::from_double(if d > 1.0e-12 { acc[i] / d } else { 0.0 })
  }
  out
}
