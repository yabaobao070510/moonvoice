///|
/// FFT 与谱特征的结构性测试。
///
/// 金标对拍（golden_run_test.mbt）负责"和 numpy 是否一致"，
/// 这里负责"性质和边界是否成立"——例如能量守恒、单音定位、退化输入不崩。

test "next_pow2" {
  assert_eq(@feature.next_pow2(1), 1)
  assert_eq(@feature.next_pow2(2), 2)
  assert_eq(@feature.next_pow2(3), 4)
  assert_eq(@feature.next_pow2(512), 512)
  assert_eq(@feature.next_pow2(513), 1024)
}

test "FFT：直流信号的能量全部落在 bin 0" {
  let n = 64
  let re : FixedArray[Double] = FixedArray::make(n, 1.0)
  let im : FixedArray[Double] = FixedArray::make(n, 0.0)
  @feature.fft_in_place(re, im)
  // X[0] = N，其余为 0
  assert_eq((re[0] - n.to_double()).abs() < 1.0e-9, true)
  for i = 1; i < n; i = i + 1 {
    if re[i].abs() > 1.0e-9 || im[i].abs() > 1.0e-9 {
      fail("第 " + i.to_string() + " 个频点应为 0")
    }
  }
}

test "FFT：整数 bin 上的单音能量集中在该 bin" {
  let n = 128
  let k = 9
  let re : FixedArray[Double] = FixedArray::make(n, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    re[i] = @math.cos(2.0 * @math.PI * k.to_double() * i.to_double() / n.to_double())
  }
  @feature.fft_in_place(re, im)
  // 余弦在 bin k 与 bin n-k 各分 N/2 的能量
  let half = n.to_double() / 2.0
  if (re[k] - half).abs() > 1.0e-6 {
    fail("bin " + k.to_string() + " 实部 = " + re[k].to_string())
  }
  if (re[n - k] - half).abs() > 1.0e-6 {
    fail("bin " + (n - k).to_string() + " 实部 = " + re[n - k].to_string())
  }
}

test "FFT：能量守恒（Parseval）" {
  let n = 256
  let re : FixedArray[Double] = FixedArray::make(n, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n, 0.0)
  let mut time_energy = 0.0
  for i = 0; i < n; i = i + 1 {
    let v = @math.sin(0.1 * i.to_double()) + 0.3 * @math.cos(0.7 * i.to_double())
    re[i] = v
    time_energy = time_energy + v * v
  }
  @feature.fft_in_place(re, im)
  let mut freq_energy = 0.0
  for i = 0; i < n; i = i + 1 {
    freq_energy = freq_energy + re[i] * re[i] + im[i] * im[i]
  }
  // Σ|X|² = N·Σ|x|²
  let rel = (freq_energy - time_energy * n.to_double()).abs() /
    (time_energy * n.to_double())
  if rel > 1.0e-12 {
    fail("Parseval 相对误差 " + rel.to_string())
  }
}

test "功率谱：白噪声的谱平坦度显著高于单音" {
  let n = 512
  // 确定的伪随机序列（LCG），保证测试可复现
  let noise : FixedArray[Float] = FixedArray::make(n, 0.0)
  // 16 位 LCG：乘数选得足够小，保证 Int(32 位) 下不会回绕
  let mut seed : Int = 12345
  for i = 0; i < n; i = i + 1 {
    seed = (seed * 25173 + 13849) % 65536
    noise[i] = Float::from_double((seed.to_double() / 65536.0 - 0.5) * 0.5)
  }
  let tone : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    tone[i] = Float::from_double(0.5 * @math.sin(2.0 * @math.PI * 40.0 * i.to_double() / n.to_double()))
  }
  let f_noise = @feature.spectral_flatness(@feature.power_spectrum(noise, n), 1, n / 2)
  let f_tone = @feature.spectral_flatness(@feature.power_spectrum(tone, n), 1, n / 2)
  if f_noise <= f_tone {
    fail(
      "噪声平坦度 " + f_noise.to_string() + " 未高于单音 " + f_tone.to_string(),
    )
  }
  // 单音应非常"不平坦"
  if f_tone > 0.1 {
    fail("单音的谱平坦度偏高：" + f_tone.to_string())
  }
}

test "频带能量：单音的能量应落在其所在频带" {
  let n = 512
  let rate = 16000
  let tone : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    tone[i] = Float::from_double(0.5 * @math.sin(2.0 * @math.PI * 2000.0 * i.to_double() / rate.to_double()))
  }
  let spec = @feature.power_spectrum(tone, n)
  // 四带：0-500, 500-1000, 1000-2000, 2000-8000
  let bands = @feature.band_energies(
    spec,
    rate,
    n,
    [500.0, 1000.0, 2000.0, 8000.0],
  )
  assert_eq(bands.length(), 4)
  // 2000 Hz 落在第 4 带（>2000）
  if bands[3] <= bands[0] || bands[3] <= bands[1] {
    fail("2000 Hz 单音能量未落在高频带")
  }
}
