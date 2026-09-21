///|
/// moonvoice/feature — DCT-II 与 MFCC
///
/// MFCC 是 log-mel 再做一次 DCT（去相关 + 降维）：
///   mel 带之间高度相关（相邻带能量几乎一样），DCT 把能量集中到前几个系数，
///   于是用 13 个数就能概括 26 个 mel 带——这是几十年来语音识别的默认前端。
///
/// DCT-II 用 ortho 归一化（与 scipy.fftpack.dct(norm='ortho') 一致），
/// 这样不同长度下系数能量可比，不做归一化就对不上任何现有工具链。

///|
/// DCT-II（正交归一化）。
/// X[k] = c(k) · Σ x[n]·cos(π·k·(2n+1) / (2N))，
/// 其中 c(0) = √(1/N)，c(k>0) = √(2/N)。
pub fn dct2(x : FixedArray[Double], n_out : Int) -> FixedArray[Double] {
  let n = x.length()
  let out : FixedArray[Double] = FixedArray::make(n_out, 0.0)
  if n == 0 {
    return out
  }
  let nf = n.to_double()
  for k = 0; k < n_out; k = k + 1 {
    let mut acc = 0.0
    let kf = k.to_double()
    for i = 0; i < n; i = i + 1 {
      acc = acc +
        x[i] * @math.cos(@math.PI * kf * (2.0 * i.to_double() + 1.0) / (2.0 * nf))
    }
    let c = if k == 0 {
      (1.0 / nf).sqrt()
    } else {
      (2.0 / nf).sqrt()
    }
    out[k] = acc * c
  }
  out
}

///|
/// MFCC：log-mel 谱 → DCT-II → 取前 `n_mfcc` 个系数。
///
/// 输入是**一帧**的 log-mel（长度 n_mels），输出长度 n_mfcc。
pub fn mfcc_from_log_mel(log_mel : FixedArray[Double], n_mfcc : Int) -> FixedArray[Double] {
  dct2(log_mel, n_mfcc)
}

///|
/// 一整段音频的 MFCC 矩阵（帧优先扁平存储，帧数 × n_mfcc）。
///
/// 这是把 STFT → mel → log → DCT 串起来的"一条龙"入口；
/// 中间量（功率谱、mel 能量）不保留，需要它们请直接用 MelFilterbank。
pub fn mfcc(
  stft : Stft,
  mel : MelFilterbank,
  x : FixedArray[Float],
  n_mfcc : Int,
) -> FixedArray[Double] {
  let bins = stft.bins()
  if mel.n_bins() != bins {
    abort("mfcc: MelFilterbank 的 n_bins 与 STFT 不匹配")
  }
  let n_frames = stft.frame_count(x.length())
  // 先把所有帧的 mel 能量算完，再**整体**做 dB 转换：
  // top_db 是相对"整张谱图的峰值"截断的，逐帧做会让每帧按自己的峰值截断，
  // 结果与 librosa 系统性不一致（这个坑是被金标抓出来的）。
  let mel_power = mel_energies(stft, mel, x)
  let db = power_to_db(mel_power, ref_power=1.0, top_db=80.0)
  let n_mels = mel.n_mels()
  let out : FixedArray[Double] = FixedArray::make(n_frames * n_mfcc, 0.0)
  let frame_db : FixedArray[Double] = FixedArray::make(n_mels, 0.0)
  for f = 0; f < n_frames; f = f + 1 {
    for i = 0; i < n_mels; i = i + 1 {
      frame_db[i] = db[f * n_mels + i]
    }
    let c = mfcc_from_log_mel(frame_db, n_mfcc)
    for k = 0; k < n_mfcc; k = k + 1 {
      out[f * n_mfcc + k] = c[k]
    }
  }
  out
}

///|
/// 一整段音频的 mel 带能量（**线性**，未取 dB），帧优先扁平存储。
/// 这是 mel 链路里最有复用价值的中间量：要做对数前处理、自定义压缩、
/// 或者接别的后端，都需要它。
pub fn mel_energies(
  stft : Stft,
  mel : MelFilterbank,
  x : FixedArray[Float],
) -> FixedArray[Double] {
  let bins = stft.bins()
  if mel.n_bins() != bins {
    abort("mel_energies: MelFilterbank 的 n_bins 与 STFT 不匹配")
  }
  let n_mels = mel.n_mels()
  let n_frames = stft.frame_count(x.length())
  let mag = stft.magnitude(x)
  let out : FixedArray[Double] = FixedArray::make(n_frames * n_mels, 0.0)
  let power : FixedArray[Double] = FixedArray::make(bins, 0.0)
  for f = 0; f < n_frames; f = f + 1 {
    for b = 0; b < bins; b = b + 1 {
      let m = mag[f * bins + b]
      power[b] = m * m
    }
    let e = mel.apply(power)
    for i = 0; i < n_mels; i = i + 1 {
      out[f * n_mels + i] = e[i]
    }
  }
  out
}

///|
/// 一整段音频的 log-mel 矩阵（帧优先扁平存储，帧数 × n_mels）。
///
/// 注意 `top_db` 是相对**整张谱图**的峰值截断（与 librosa 一致），
/// 不是逐帧——逐帧会让安静帧的地板被不合理地抬高。
pub fn log_mel(
  stft : Stft,
  mel : MelFilterbank,
  x : FixedArray[Float],
  top_db? : Double = 80.0,
) -> FixedArray[Double] {
  power_to_db(mel_energies(stft, mel, x), ref_power=1.0, top_db~)
}
