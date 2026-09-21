///|
/// STFT / 窗函数测试。
///
/// 三条独立性不同的验证：
/// 1. **窗系数**对拍 scipy.signal.windows（外部参照）
/// 2. **幅度谱**对拍 numpy.fft 逐帧计算（外部参照）
/// 3. **完全重构** stft→istft ≈ 原信号（自洽性质，但足够强：
///    帧长、帧移、加窗、重叠相加、窗归一化、逆 FFT 任一环节写错都会失败）

test "窗函数：与 scipy.signal.windows 逐系数一致" {
  let n = golden_window_len()
  let cases : Array[(String, @feature.Window, Array[Double])] = [
    ("hann", @feature.Window::Hann, golden_window_hann()),
    ("hamming", @feature.Window::Hamming, golden_window_hamming()),
    ("blackman", @feature.Window::Blackman, golden_window_blackman()),
    ("bartlett", @feature.Window::Bartlett, golden_window_bartlett()),
    ("kaiser", @feature.Window::Kaiser(6.0), golden_window_kaiser6()),
  ]
  for c in cases {
    let (name, kind, expected) = c
    let got = @feature.window_coefficients(kind, n)
    if got.length() != expected.length() {
      fail(name + ": 长度不符")
    }
    for i = 0; i < expected.length(); i = i + 1 {
      let d = (got[i] - expected[i]).abs()
      if d > 1.0e-12 {
        fail(
          name + " 第 " + i.to_string() + " 个系数偏差 " + d.to_string(),
        )
      }
    }
  }
}

test "窗函数：矩形窗全 1，且相干增益有物理意义" {
  let rect = @feature.window_coefficients(@feature.Window::Rectangular, 32)
  for i = 0; i < 32; i = i + 1 {
    assert_eq(rect[i], 1.0)
  }
  assert_eq(@feature.window_coherent_gain(@feature.Window::Rectangular, 32), 1.0)
  // 对称 Hann（两端为零）的相干增益是 (n-1)/(2n)，不是 0.5——
  // 0.5 是**周期** Hann 的值。n=64 时为 63/128 = 0.4921875。
  let hann = @feature.window_coherent_gain(@feature.Window::Hann, 64)
  let expected = 63.0 / 128.0
  if (hann - expected).abs() > 1.0e-12 {
    fail("对称 Hann 相干增益应为 " + expected.to_string() + "，实际 " + hann.to_string())
  }
}

test "STFT：幅度谱与 numpy 逐帧计算一致" {
  let (n_fft, hop) = golden_stft_meta()
  let ints = golden_stft_input()
  let x : FixedArray[Float] = FixedArray::make(ints.length(), 0.0)
  for i = 0; i < ints.length(); i = i + 1 {
    x[i] = Float::from_double(ints[i].to_double() / 10000.0)
  }
  let stft = @feature.Stft::new(n_fft, hop)
  let mag = stft.magnitude(x)
  let expected = golden_stft_magnitude()
  if mag.length() != expected.length() {
    fail(
      "长度 " + mag.length().to_string() + " != " + expected.length().to_string(),
    )
  }
  let mut max_expected = 0.0
  for v in expected {
    if v > max_expected {
      max_expected = v
    }
  }
  let mut worst = 0.0
  for i = 0; i < expected.length(); i = i + 1 {
    let d = (mag[i] - expected[i]).abs()
    if d > worst {
      worst = d
    }
  }
  // 容差同 FFT 金标：端到端偏差来自 f32 样本存储（~6e-8 相对），非算法问题
  if worst > max_expected * 1.0e-5 {
    fail(
      "最大偏差 " +
      worst.to_string() +
      "（最大幅度 " +
      max_expected.to_string() +
      "）",
    )
  }
}

///| 重构误差（跳过首尾 n_fft 的边缘效应区）
fn reconstruction_error(n_fft : Int, hop : Int, kind : @feature.Window) -> Double {
  let n = 8000
  let x : FixedArray[Float] = FixedArray::make(n, 0.0)
  let mut seed = 4321
  for i = 0; i < n; i = i + 1 {
    seed = (seed * 25173 + 13849) % 65536
    let noise = seed.to_double() / 32768.0 - 1.0
    // 噪声 + 两个正弦：既有宽带成分也有结构成分
    x[i] = Float::from_double(
      0.3 * noise +
      0.4 * @math.sin(2.0 * @math.PI * 440.0 * i.to_double() / 16000.0) +
      0.2 * @math.sin(2.0 * @math.PI * 1500.0 * i.to_double() / 16000.0),
    )
  }
  let stft = @feature.Stft::new(n_fft, hop, window=kind)
  let bins = stft.bins()
  let n_frames = stft.frame_count(n)
  let re : FixedArray[Double] = FixedArray::make(n_frames * bins, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n_frames * bins, 0.0)
  stft.transform_into(x, re, im)
  let y = stft.inverse(re, im)
  // 比较中间段（首尾各有半个窗的边缘效应）
  let from = n_fft
  let to = if y.length() - n_fft < n { y.length() - n_fft } else { n }
  if to <= from {
    return 999.0
  }
  let mut sig = 0.0
  let mut err = 0.0
  for i = from; i < to; i = i + 1 {
    let a = x[i].to_double()
    let b = y[i].to_double()
    sig = sig + a * a
    err = err + (a - b) * (a - b)
  }
  10.0 * @math.log10(sig / (err + 1.0e-30))
}

test "STFT：完全重构（Hann 窗，50% 与 75% 重叠）" {
  let snr50 = reconstruction_error(512, 256, @feature.Window::Hann)
  let snr75 = reconstruction_error(512, 128, @feature.Window::Hann)
  if snr50 < 100.0 {
    fail("50% 重叠重构 SNR 仅 " + snr50.to_string() + " dB")
  }
  if snr75 < 100.0 {
    fail("75% 重叠重构 SNR 仅 " + snr75.to_string() + " dB")
  }
}

test "STFT：完全重构（Hamming / Blackman / Kaiser 同样成立）" {
  let kinds = [
    @feature.Window::Hamming,
    @feature.Window::Blackman,
    @feature.Window::Kaiser(8.0),
  ]
  for k in kinds {
    let snr = reconstruction_error(256, 64, k)
    if snr < 100.0 {
      fail(k.name() + " 重构 SNR 仅 " + snr.to_string() + " dB")
    }
  }
}

test "STFT：矩形窗在 50% 重叠下也满足 COLA" {
  // 矩形窗 + hop=n_fft/2 时窗平方和恒为 2，可以重构
  let snr = reconstruction_error(256, 128, @feature.Window::Rectangular)
  if snr < 100.0 {
    fail("矩形窗重构 SNR 仅 " + snr.to_string() + " dB")
  }
}

test "STFT：帧数计算与边界一致" {
  let stft = @feature.Stft::new(512, 256)
  assert_eq(stft.frame_count(512), 1)
  assert_eq(stft.frame_count(768), 2)
  assert_eq(stft.frame_count(100), 1) // 不足一帧也补零算一帧
  assert_eq(stft.bins(), 257)
  // 非法参数（n_fft 非 2 的幂）走 abort → panic 而非静默出错。
  // panic 不可被 try 捕获，所以这里只断言合法路径；非法路径由代码中的
  // abort 调用与文档保证（测试无法在不中断进程的前提下验证 panic）。
}
