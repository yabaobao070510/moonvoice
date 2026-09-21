///|
/// 音频产出质量测试：位深保真、抖动、削波检测。
///
/// 这三条都是"听感/下游能不能用"层面的性质，测法要贴着性质本身，
/// 不能只测"函数没报错"。

///| 造一段 24-bit WAV（用编码器写、再用解码器读，形成真实的往返路径）
fn make_24bit_wav() -> Bytes raise {
  let n = 64
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    samples[i] = Float::from_double((i.to_double() - 32.0) / 64.0)
  }
  @audio.encode_wav(@audio.Audio::new(16000, 1, samples), format=I24)
}

test "质量：24-bit 素材往返后仍是 24-bit（不被无声降级成 16-bit）" {
  let wav = make_24bit_wav()
  let decoded = @audio.decode_wav(wav)
  // 解码应记录来源格式
  match decoded.source_format() {
    Some(f) => assert_true(f == @audio.SampleFormat::I24)
    None => fail("解码后应记录来源格式")
  }
  // 不带参数重新编码：应沿用来源格式
  let again = @audio.encode_wav(decoded)
  let decoded2 = @audio.decode_wav(again)
  match decoded2.source_format() {
    Some(f) => assert_true(f == @audio.SampleFormat::I24)
    None => fail("再编码后格式丢失")
  }
  // 两次字节应完全一致（真正的往返保真）
  assert_eq(again.length(), wav.length())
  for i = 0; i < wav.length(); i = i + 1 {
    assert_eq(again[i], wav[i])
  }
}

test "质量：重采样不改变采样格式标记" {
  let decoded = @audio.decode_wav(make_24bit_wav())
  let rs = @resample.resample_audio(decoded, 8000)
  match rs.source_format() {
    Some(f) => assert_true(f == @audio.SampleFormat::I24)
    None => fail("重采样后格式标记应保留（否则输出会被降级成 16-bit）")
  }
}

test "质量：抖动把量化失真变成噪声（且不引入直流偏移）" {
  // 输入是恒定直流，电平落在两个量化台阶之间（16-bit 的 0.5 LSB 处）
  // 无抖动时输出是**固定**的某个台阶 → 量化误差是确定性失真；
  // 有抖动时输出在两个相邻台阶间跳 → 误差变成噪声，均值仍等于原值。
  let n = 4096
  let level = 0.4 + 0.5 / 32768.0
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    samples[i] = Float::from_double(level)
  }
  let audio = @audio.Audio::new(16000, 1, samples)

  let plain = @audio.decode_wav(@audio.encode_wav(audio, format=I16))
  let dithered = @audio.decode_wav(
    @audio.encode_wav_ex(audio, @audio.EncodeOptions::new(@audio.SampleFormat::I16, dither=true)).bytes(),
  )

  // 无抖动：输出恒定
  let mut varies_plain = false
  for i = 1; i < n; i = i + 1 {
    if plain.sample_at(i, 0) != plain.sample_at(0, 0) {
      varies_plain = true
    }
  }
  assert_eq(varies_plain, false)

  // 有抖动：输出在台阶间跳（这正是抖动的作用）
  let mut varies_dither = false
  for i = 1; i < n; i = i + 1 {
    if dithered.sample_at(i, 0) != dithered.sample_at(0, 0) {
      varies_dither = true
    }
  }
  assert_eq(varies_dither, true)

  // 两者均值都应贴近原电平（抖动是无偏的）
  let mut sum_plain = 0.0
  let mut sum_dither = 0.0
  for i = 0; i < n; i = i + 1 {
    sum_plain = sum_plain + plain.sample_at(i, 0).to_double()
    sum_dither = sum_dither + dithered.sample_at(i, 0).to_double()
  }
  let mp = sum_plain / n.to_double()
  let md = sum_dither / n.to_double()
  if (mp - level).abs() > 1.0e-4 {
    fail("无抖动均值偏离 " + mp.to_string())
  }
  if (md - level).abs() > 1.0e-4 {
    fail("有抖动均值偏离 " + md.to_string())
  }
}

test "质量：抖动可复现（同输入必得同输出）" {
  let samples : FixedArray[Float] = FixedArray::make(256, 0.0)
  for i = 0; i < 256; i = i + 1 {
    samples[i] = Float::from_double(0.123456789 + i.to_double() * 1.0e-7)
  }
  let audio = @audio.Audio::new(16000, 1, samples)
  let a = @audio.encode_wav_ex(audio, @audio.EncodeOptions::new(@audio.SampleFormat::I16, dither=true)).bytes()
  let b = @audio.encode_wav_ex(audio, @audio.EncodeOptions::new(@audio.SampleFormat::I16, dither=true)).bytes()
  assert_eq(a.length(), b.length())
  for i = 0; i < a.length(); i = i + 1 {
    assert_eq(a[i], b[i])
  }
}

test "质量：削波会被报告，而不是静默钳位" {
  // 重采样过冲、混音溢出都会产生超量程样本，工具必须能报告
  let samples : FixedArray[Float] = FixedArray::make(8, 0.5)
  samples[0] = 1.5
  samples[1] = -2.0
  samples[2] = 1.0
  let audio = @audio.Audio::new(16000, 1, samples)
  let report = @audio.encode_wav_ex(audio, @audio.EncodeOptions::new(@audio.SampleFormat::I16))
  assert_eq(report.clipped_samples(), 2)
  assert_eq(report.has_clipping(), true)
  if (report.peak() - 2.0).abs() > 1.0e-9 {
    fail("峰值应为 2.0，实际 " + report.peak().to_string())
  }
}

test "质量：正常幅度不产生削波报告" {
  let samples : FixedArray[Float] = FixedArray::make(64, 0.0)
  for i = 0; i < 64; i = i + 1 {
    samples[i] = Float::from_double(0.99 * @math.sin(i.to_double() * 0.3))
  }
  let report = @audio.encode_wav_ex(
    @audio.Audio::new(16000, 1, samples),
    @audio.EncodeOptions::new(@audio.SampleFormat::I16),
  )
  assert_eq(report.has_clipping(), false)
  if report.peak() > 1.0 {
    fail("峰值不应超过 1.0")
  }
}
