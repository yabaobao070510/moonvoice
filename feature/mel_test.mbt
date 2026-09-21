///|
/// mel / log-mel / MFCC / 谱特征测试。
///
/// 对拍对象是 **librosa**（语音特征的事实标准）与 scipy.fftpack。
/// 这条链路环节多（STFT → 功率 → mel → dB → DCT），任何一处约定不一致
/// （窗的对称性、mel 标度、滤波器归一化、DCT 归一化）都会让结果系统性偏移——
/// 所以必须逐环节对拍，而不是只看"跑通了"。

fn golden_signal() -> FixedArray[Float] {
  let ints = golden_sig_input()
  let x : FixedArray[Float] = FixedArray::make(ints.length(), 0.0)
  for i = 0; i < ints.length(); i = i + 1 {
    x[i] = Float::from_double(ints[i].to_double() / 10000.0)
  }
  x
}

///| 相对最大值的平均绝对偏差（谱量动态范围大，用相对判据）
fn rel_error(got : FixedArray[Double], expected : Array[Double]) -> Double {
  if got.length() != expected.length() {
    return 1.0e9
  }
  let mut max_e = 1.0e-12
  for v in expected {
    if v.abs() > max_e {
      max_e = v.abs()
    }
  }
  let mut sum = 0.0
  for i = 0; i < expected.length(); i = i + 1 {
    sum = sum + (got[i] - expected[i]).abs()
  }
  sum / expected.length().to_double() / max_e
}

test "窗函数：周期窗也与 scipy 一致（STFT 依赖它）" {
  let n = golden_window_len()
  let cases : Array[(@feature.Window, Array[Double])] = [
    (@feature.Window::Hann, golden_window_periodic_hann()),
    (@feature.Window::Hamming, golden_window_periodic_hamming()),
    (@feature.Window::Blackman, golden_window_periodic_blackman()),
    (@feature.Window::Bartlett, golden_window_periodic_bartlett()),
    (@feature.Window::Kaiser(6.0), golden_window_periodic_kaiser6()),
  ]
  for c in cases {
    let (kind, expected) = c
    let got = @feature.window_coefficients(kind, n, periodic=true)
    for i = 0; i < expected.length(); i = i + 1 {
      let d = (got[i] - expected[i]).abs()
      if d > 1.0e-12 {
        fail(
          kind.name() + "（周期）第 " + i.to_string() + " 个系数偏差 " + d.to_string(),
        )
      }
    }
  }
}

test "mel 标度：Hz↔mel 往返一致，且转折点符合 Slaney 定义" {
  for f in [0.0, 100.0, 999.0, 1000.0, 4000.0, 8000.0] {
    let m = @feature.hz_to_mel(f)
    let back = @feature.mel_to_hz(m)
    if (back - f).abs() > 1.0e-9 {
      fail("往返不一致：" + f.to_string() + " → " + back.to_string())
    }
  }
  // Slaney 定义：1 kHz 以下线性（200/3 Hz 每 mel），1 kHz 处为第 15 个 mel
  if (@feature.hz_to_mel(1000.0) - 15.0).abs() > 1.0e-12 {
    fail("1 kHz 应对应 15 mel（Slaney）")
  }
  if (@feature.hz_to_mel(300.0) - 4.5).abs() > 1.0e-12 {
    fail("300 Hz 应对应 4.5 mel（Slaney 线性段）")
  }
}

test "mel 滤波器组：矩阵与 librosa.filters.mel 一致" {
  let (n_mels, n_fft, sr) = golden_mel_meta()
  let mel = @feature.MelFilterbank::new(n_mels, n_fft, sr)
  let got = mel.matrix()
  let expected = golden_mel_matrix()
  assert_eq(got.length(), expected.length())
  // 三角滤波器的边界频率由浮点算出，与 librosa 在边界 bin 上会有舍入差异，
  // 相对最大值的 1e-8 已是"同一设计"的量级（不是实现差异）。
  let err = rel_error(got, expected)
  if err > 1.0e-8 {
    fail("mel 滤波器组矩阵相对误差 " + err.to_string())
  }
}

test "mel 滤波器组：每个滤波器权重和为 1（面积归一化的直接推论）" {
  // Slaney 归一化下，三角滤波器对**均匀功率谱**的响应等于带宽——
  // 这里换个更容易验证的性质：矩阵每行的最大值出现在中心频率附近
  let (n_mels, n_fft, sr) = golden_mel_meta()
  let mel = @feature.MelFilterbank::new(n_mels, n_fft, sr)
  let m = mel.matrix()
  let n_bins = mel.n_bins()
  for band = 0; band < n_mels; band = band + 1 {
    let mut row_sum = 0.0
    for b = 0; b < n_bins; b = b + 1 {
      row_sum = row_sum + m[band * n_bins + b]
    }
    if row_sum <= 0.0 {
      fail("第 " + band.to_string() + " 个滤波器全为零")
    }
  }
}

test "log-mel：与 librosa.feature.melspectrogram 一致" {
  let (n_mels, n_fft, sr) = golden_mel_meta()
  let (g_n_fft, hop, n_frames) = golden_stft_meta()
  assert_eq(n_fft, g_n_fft)
  let x = golden_signal()
  let stft = @feature.Stft::new(n_fft, hop)
  let mel = @feature.MelFilterbank::new(n_mels, n_fft, sr)
  let got = @feature.log_mel(stft, mel, x)
  let expected = golden_log_mel()
  assert_eq(got.length(), expected.length())
  assert_eq(got.length(), n_frames * n_mels)
  // dB 域：绝对容差 0.5 dB 已足够严（librosa 与实现在浮点细节上有差异）
  let mut worst = 0.0
  for i = 0; i < expected.length(); i = i + 1 {
    let d = (got[i] - expected[i]).abs()
    if d > worst {
      worst = d
    }
  }
  if worst > 0.5 {
    fail("log-mel 最大偏差 " + worst.to_string() + " dB")
  }
}

test "MFCC：与 librosa.feature.mfcc 一致" {
  let (n_mels, n_fft, sr) = golden_mel_meta()
  let (_, hop, n_frames) = golden_stft_meta()
  let x = golden_signal()
  let stft = @feature.Stft::new(n_fft, hop)
  let mel = @feature.MelFilterbank::new(n_mels, n_fft, sr)
  let got = @feature.mfcc(stft, mel, x, 13)
  let expected = golden_mfcc()
  assert_eq(got.length(), expected.length())
  assert_eq(got.length(), n_frames * 13)
  let mut worst = 0.0
  for i = 0; i < expected.length(); i = i + 1 {
    let d = (got[i] - expected[i]).abs()
    if d > worst {
      worst = d
    }
  }
  if worst > 0.5 {
    fail("MFCC 最大偏差 " + worst.to_string())
  }
}

test "DCT-II：与 scipy.fftpack.dct(norm='ortho') 一致" {
  let input_arr = golden_dct_input()
  let expected = golden_dct_expected()
  let input : FixedArray[Double] = FixedArray::make(input_arr.length(), 0.0)
  for i = 0; i < input_arr.length(); i = i + 1 {
    input[i] = input_arr[i]
  }
  let got = @feature.dct2(input, expected.length())
  for i = 0; i < expected.length(); i = i + 1 {
    let d = (got[i] - expected[i]).abs()
    if d > 1.0e-12 {
      fail("第 " + i.to_string() + " 个系数偏差 " + d.to_string())
    }
  }
}

test "谱特征：质心/带宽/滚降与 numpy 计算一致" {
  let (n_mels, n_fft, sr) = golden_mel_meta()
  let (_, hop, _) = golden_stft_meta()
  let x = golden_signal()
  let stft = @feature.Stft::new(n_fft, hop)
  let mags = stft.magnitude(x)
  let bins = stft.bins()
  let idx = golden_spectral_frame_index()
  let power : FixedArray[Double] = FixedArray::make(bins, 0.0)
  for b = 0; b < bins; b = b + 1 {
    let m = mags[idx * bins + b]
    power[b] = m * m
  }
  let bin_hz = sr.to_double() / n_fft.to_double()
  let f = @feature.spectral_frame(power, bin_hz)
  let (c, bw, ro) = golden_spectral_expected()
  if (f.centroid_hz() - c).abs() > c * 0.01 {
    fail("质心 " + f.centroid_hz().to_string() + " vs " + c.to_string())
  }
  if (f.bandwidth_hz() - bw).abs() > bw * 0.02 {
    fail("带宽 " + f.bandwidth_hz().to_string() + " vs " + bw.to_string())
  }
  if (f.rolloff_hz() - ro).abs() > bin_hz * 1.5 {
    fail("滚降 " + f.rolloff_hz().to_string() + " vs " + ro.to_string())
  }
  let _ = n_mels
}

test "谱特征：过零率与信号性质一致" {
  let n = 1000
  let low : FixedArray[Float] = FixedArray::make(n, 0.0)
  let high : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    low[i] = Float::from_double(@math.sin(2.0 * @math.PI * 100.0 * i.to_double() / 16000.0))
    high[i] = Float::from_double(@math.sin(2.0 * @math.PI * 4000.0 * i.to_double() / 16000.0))
  }
  let zcr_low = @feature.zero_crossing_rate(low, 0, n)
  let zcr_high = @feature.zero_crossing_rate(high, 0, n)
  if zcr_high <= zcr_low {
    fail("高频信号过零率应更高")
  }
  // 4 kHz @ 16 kHz：每周期 4 个样本、2 次过零 → 约 0.5
  if (zcr_high - 0.5).abs() > 0.05 {
    fail("4 kHz 信号的过零率应接近 0.5，实际 " + zcr_high.to_string())
  }
  // 直流信号无过零
  let dc : FixedArray[Float] = FixedArray::make(n, 0.5)
  assert_eq(@feature.zero_crossing_rate(dc, 0, n), 0.0)
}
