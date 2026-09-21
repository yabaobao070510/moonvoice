///|
/// 双二阶滤波器与响度测试。
///
/// 验证分三层：
/// 1. **系数**：K 加权两级与 RBJ 公式复算一致（交叉核对设计公式）
/// 2. **频响**：用幅度响应验证"滤波器确实在做它该做的事"（-3 dB 点、增益点）
/// 3. **响度**：与 pyloudnorm（BS.1770-4 的独立实现）对拍，并验证门控行为

test "K 加权：系数与 RBJ 公式复算一致（16 kHz）" {
  let (b0, b1, b2, a1, a2) = golden_kshelf_coeffs()
  let shelf = @feature.Biquad::new(HighShelf(0.7071752369554196, 3.999843853973347), 1681.974450955533, 16000)
  if (shelf.b0() - b0).abs() > 1.0e-12 ||
    (shelf.b1() - b1).abs() > 1.0e-12 ||
    (shelf.b2() - b2).abs() > 1.0e-12 ||
    (shelf.a1() - a1).abs() > 1.0e-12 ||
    (shelf.a2() - a2).abs() > 1.0e-12 {
    fail("高架系数不符：b0=" + shelf.b0().to_string() + " vs " + b0.to_string())
  }
  let (c0, c1, c2, d1, d2) = golden_khighpass_coeffs()
  let hp = @feature.Biquad::new(Highpass(0.5003270373238773), 38.13547087602444, 16000)
  if (hp.b0() - c0).abs() > 1.0e-12 ||
    (hp.b1() - c1).abs() > 1.0e-12 ||
    (hp.b2() - c2).abs() > 1.0e-12 ||
    (hp.a1() - d1).abs() > 1.0e-12 ||
    (hp.a2() - d2).abs() > 1.0e-12 {
    fail("高通系数不符")
  }
}

test "双二阶：-3 dB 点与增益点符合滤波器定义" {
  let sr = 48000
  // 低通 Q=1/√2（Butterworth）：在 fc 处应为 -3 dB
  let lp = @feature.Biquad::new(Lowpass(0.7071067811865476), 1000.0, sr)
  let at_fc = lp.magnitude_db_at(1000.0, sr)
  if (at_fc + 3.0103).abs() > 0.01 {
    fail("低通在 fc 处应为 -3.01 dB，实际 " + at_fc.to_string())
  }
  // 远低于 fc 应接近 0 dB，远高于应大幅衰减
  if lp.magnitude_db_at(50.0, sr).abs() > 0.01 {
    fail("低通通带应接近 0 dB")
  }
  if lp.magnitude_db_at(10000.0, sr) > -35.0 {
    fail("低通阻带衰减不足：" + lp.magnitude_db_at(10000.0, sr).to_string())
  }
  // 高通同理
  let hp = @feature.Biquad::new(Highpass(0.7071067811865476), 1000.0, sr)
  if (hp.magnitude_db_at(1000.0, sr) + 3.0103).abs() > 0.01 {
    fail("高通在 fc 处应为 -3.01 dB")
  }
  // 峰值滤波器：中心频率处应给到指定增益
  let peak = @feature.Biquad::new(Peak(2.0, 6.0), 2000.0, sr)
  if (peak.magnitude_db_at(2000.0, sr) - 6.0).abs() > 0.01 {
    fail("峰值滤波器在 fc 处应为 +6 dB，实际 " + peak.magnitude_db_at(2000.0, sr).to_string())
  }
  // 高架：高频端应给到指定增益
  let shelf = @feature.Biquad::new(HighShelf(0.7071752369554196, 4.0), 1681.97, sr)
  let hf = shelf.magnitude_db_at(20000.0, sr)
  if (hf - 4.0).abs() > 0.5 {
    fail("高架在高频端应接近 +4 dB，实际 " + hf.to_string())
  }
  // 直流处高架应接近 0 dB
  if shelf.magnitude_db_at(1.0, sr).abs() > 0.5 {
    fail("高架在直流处应接近 0 dB，实际 " + shelf.magnitude_db_at(1.0, sr).to_string())
  }
}

test "双二阶：直流增益与滤波稳定性（长时间不发散）" {
  // 低通对直流信号的稳态增益应为 1
  let lp = @feature.Biquad::new(Lowpass(0.7071067811865476), 1000.0, 48000)
  let mut y = 0.0
  for i = 0; i < 5000; i = i + 1 {
    y = lp.process_sample(1.0)
  }
  if (y - 1.0).abs() > 1.0e-6 {
    fail("低通直流增益应为 1，实际 " + y.to_string())
  }
  // 高通对直流的稳态输出应为 0
  let hp = @feature.Biquad::new(Highpass(0.7071067811865476), 1000.0, 48000)
  let mut z = 1.0
  for i = 0; i < 5000; i = i + 1 {
    z = hp.process_sample(1.0)
  }
  if z.abs() > 1.0e-9 {
    fail("高通直流输出应为 0，实际 " + z.to_string())
  }
}

///| 读金标信号
fn golden_loudness_audio() -> @audio.Audio {
  let (rate, _) = golden_loudness_expected()
  let ints = golden_loudness_input()
  let samples : FixedArray[Float] = FixedArray::make(ints.length(), 0.0)
  for i = 0; i < ints.length(); i = i + 1 {
    samples[i] = Float::from_double(ints[i].to_double() / 32768.0)
  }
  @audio.Audio::new(rate, 1, samples)
}

test "响度：积分响度与 pyloudnorm 一致（±0.1 LU）" {
  let audio = golden_loudness_audio()
  let (_, expected) = golden_loudness_expected()
  let got = @feature.loudness_lufs(audio)
  if (got - expected).abs() > 0.1 {
    fail(
      "积分响度 " + got.to_string() + " LUFS，参照 " + expected.to_string() + " LUFS",
    )
  }
}

test "响度：样本峰值与 numpy 一致" {
  let audio = golden_loudness_audio()
  let r = @feature.measure_loudness(audio)
  let expected = golden_loudness_peak_dbfs()
  if (r.sample_peak_dbfs() - expected).abs() > 1.0e-3 {
    fail(
      "峰值 " + r.sample_peak_dbfs().to_string() + " dBFS，参照 " + expected.to_string(),
    )
  }
}

test "响度：加长静音不改变积分响度（门控的核心性质）" {
  // 检验门控该有的性质：**静音段变长，读数不变**。
  // （早先写成"带静音 vs 不带静音读数接近"，那是错的——短信号的块网格里
  //  没有跨边界的半静音块，两者本就不该相等。测试要测性质，不是测巧合。）
  let rate = 16000
  let tone_len = rate / 2 // 0.5 s 有声
  let make = fn(silence_ms : Int) -> @audio.Audio {
    let total = tone_len + rate * silence_ms / 1000
    let buf : FixedArray[Float] = FixedArray::make(total, 0.0)
    for i = 0; i < tone_len; i = i + 1 {
      buf[i] = Float::from_double(
        0.4 * @math.sin(2.0 * @math.PI * 440.0 * i.to_double() / rate.to_double()),
      )
    }
    @audio.Audio::new(rate, 1, buf)
  }
  let short = @feature.loudness_lufs(make(1000))
  let long = @feature.loudness_lufs(make(4000))
  if (short - long).abs() > 0.01 {
    fail(
      "静音从 1 s 加到 4 s 后读数从 " + short.to_string() + " 变成 " + long.to_string() + "（门控未生效）",
    )
  }
  // 且读数应明显高于"把静音也算进去"的平均值
  let ungated = @feature.measure_loudness(make(4000)).ungated_lufs()
  if ungated >= short {
    fail("未加门限的读数应低于加门限后的读数（说明门控确实剔除了静音）")
  }
}

test "响度：纯静音返回极小值而不是 NaN" {
  let rate = 16000
  let silence : FixedArray[Float] = FixedArray::make(rate, 0.0)
  let r = @feature.measure_loudness(@audio.Audio::new(rate, 1, silence))
  if r.integrated_lufs() != r.integrated_lufs() {
    fail("静音输入产生了 NaN")
  }
  if r.integrated_lufs() > -100.0 {
    fail("静音响度应极低，实际 " + r.integrated_lufs().to_string())
  }
  assert_eq(r.gated_blocks(), 0)
}

test "响度：电平翻倍应增加约 6 LU" {
  let rate = 16000
  let n = rate
  let a : FixedArray[Float] = FixedArray::make(n, 0.0)
  let b : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let v = @math.sin(2.0 * @math.PI * 440.0 * i.to_double() / rate.to_double())
    a[i] = Float::from_double(0.2 * v)
    b[i] = Float::from_double(0.4 * v)
  }
  let la = @feature.loudness_lufs(@audio.Audio::new(rate, 1, a))
  let lb = @feature.loudness_lufs(@audio.Audio::new(rate, 1, b))
  let delta = lb - la
  if (delta - 6.0206).abs() > 0.05 {
    fail("电平翻倍应增加 6.02 LU，实际 " + delta.to_string())
  }
}
