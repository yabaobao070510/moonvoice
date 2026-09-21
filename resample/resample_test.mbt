///|
/// resample 包黑盒测试。
///
/// 测什么、为什么这么测：
/// - **抗混叠（混叠抑制）**是抽取的核心指标，不是"看起来像"。用高于输出 Nyquist
///   的单音输入，量它折回通带后的残余能量 → 得到以 dB 计的抑制量。
/// - **通带保真**用解析正弦做参照（不是另一个实现），因为解析解与实现无关。
/// - 边界处有零填充带来的瞬态，所有指标都在"中间窗口"上统计。

fn make_sine(
  frames : Int,
  rate : Int,
  freq : Double,
  amp : Double,
) -> FixedArray[Float] {
  let out : FixedArray[Float] = FixedArray::make(frames, 0.0)
  let w = 2.0 * @math.PI * freq / rate.to_double()
  for n = 0; n < frames; n = n + 1 {
    out[n] = Float::from_double(amp * @math.sin(w * n.to_double()))
  }
  out
}

fn rms(x : FixedArray[Float], from : Int, to : Int) -> Double {
  let mut acc = 0.0
  let n = to - from
  if n <= 0 {
    return 0.0
  }
  for i = from; i < to; i = i + 1 {
    let v = x[i].to_double()
    acc = acc + v * v
  }
  (acc / n.to_double()).sqrt()
}

///| 以 reference 为基准计算 SNR（dB），跳过首尾 skip 帧的边界瞬态
fn snr_db(
  reference : FixedArray[Float],
  got : FixedArray[Float],
  skip : Int,
) -> Double raise {
  let from = skip
  let to = reference.length() - skip
  if to <= from {
    fail("窗口为空：样本太少")
  }
  let mut sig = 0.0
  let mut err = 0.0
  for i = from; i < to; i = i + 1 {
    let r = reference[i].to_double()
    let d = r - got[i].to_double()
    sig = sig + r * r
    err = err + d * d
  }
  if err <= 0.0 {
    return 999.0
  }
  10.0 * @math.log10(sig / err)
}

fn fmt_db(x : Double) -> String {
  let scale = 100.0
  let rounded = (x * scale + 0.5).to_int().to_double() / scale
  rounded.to_string()
}

// ---------------------------------------------------------------------------

test "恒等：同采样率输出与输入逐样本相同" {
  let r = @resample.Resampler::new(48000, 48000)
  let x = make_sine(1000, 48000, 440.0, 0.5)
  let y = r.process(x, 1000, 1)
  assert_eq(y.length(), 1000)
  for i = 0; i < 1000; i = i + 1 {
    assert_eq(x[i], y[i])
  }
}

test "长度：48k→16k 与 44.1k→48k 的帧数正确" {
  let r = @resample.Resampler::new(48000, 16000)
  assert_eq(r.up(), 1)
  assert_eq(r.down(), 3)
  assert_eq(r.output_frames(48000), 16000)
  assert_eq(r.output_frames(48001), 16001) // 向上取整
  let r2 = @resample.Resampler::new(44100, 48000)
  assert_eq(r2.up(), 160)
  assert_eq(r2.down(), 147)
  assert_eq(r2.output_frames(44100), 48000)
}

test "通带保真：48k→16k 的 1kHz 正弦，对解析解 SNR > 80 dB" {
  let r = @resample.Resampler::new(48000, 16000)
  let x = make_sine(48000, 48000, 1000.0, 0.5)
  let y = r.process(x, 48000, 1)
  let reference = make_sine(16000, 16000, 1000.0, 0.5)
  let snr = snr_db(reference, y, 200)
  if snr < 80.0 {
    fail("通带 SNR 仅 " + fmt_db(snr) + " dB，低于 80 dB")
  }
}

test "通带保真：44.1k→48k（非整数比）的 1kHz 正弦，SNR > 80 dB" {
  let r = @resample.Resampler::new(44100, 48000)
  let x = make_sine(44100, 44100, 1000.0, 0.5)
  let y = r.process(x, 44100, 1)
  let reference = make_sine(48000, 48000, 1000.0, 0.5)
  let snr = snr_db(reference, y, 400)
  if snr < 80.0 {
    fail("通带 SNR 仅 " + fmt_db(snr) + " dB，低于 80 dB")
  }
}

///|
/// 抗混叠：9 kHz 单音在 48k→16k 后会折到 7 kHz。
/// 输出残余越小，说明抗混叠滤波器越有效。
fn alias_rejection_db(quality : @resample.Quality, freq : Double) -> Double raise {
  let r = @resample.Resampler::new(48000, 16000, quality~)
  let x = make_sine(48000, 48000, freq, 1.0)
  let y = r.process(x, 48000, 1)
  let in_rms = rms(x, 1000, 47000)
  let out_rms = rms(y, 400, 15600)
  20.0 * @math.log10(in_rms / out_rms)
}

test "抗混叠：9kHz 折回 7kHz 的抑制量（Balanced ≥ 40 dB）" {
  let rej = alias_rejection_db(@resample.Quality::Balanced, 9000.0)
  if rej < 40.0 {
    fail("Balanced 档对 9 kHz 的抑制仅 " + fmt_db(rej) + " dB")
  }
}

test "抗混叠：远离通带的 20kHz 应被充分抑制（Balanced ≥ 70 dB）" {
  let rej = alias_rejection_db(@resample.Quality::Balanced, 20000.0)
  if rej < 70.0 {
    fail("Balanced 档对 20 kHz 的抑制仅 " + fmt_db(rej) + " dB")
  }
}

test "抗混叠：Best 档对 9kHz 的抑制优于 Fast 档" {
  let fast = alias_rejection_db(@resample.Quality::Fast, 9000.0)
  let best = alias_rejection_db(@resample.Quality::Best, 9000.0)
  if best <= fast {
    fail(
      "Best(" + fmt_db(best) + " dB) 未优于 Fast(" + fmt_db(fast) + " dB)",
    )
  }
  if best < 60.0 {
    fail("Best 档对 9 kHz 的抑制仅 " + fmt_db(best) + " dB")
  }
}

test "直流：常数信号稳态输出仍为常数" {
  let r = @resample.Resampler::new(48000, 16000)
  let x : FixedArray[Float] = FixedArray::make(48000, 0.5)
  let y = r.process(x, 48000, 1)
  for i = 400; i < 15600; i = i + 1 {
    let v = y[i].to_double()
    if (v - 0.5).abs() > 1.0e-3 {
      fail("第 " + i.to_string() + " 个样本 = " + v.to_string() + "，偏离直流 0.5")
    }
  }
}

test "多声道：左右声道互不串扰" {
  let r = @resample.Resampler::new(48000, 16000)
  let frames = 4800
  let x : FixedArray[Float] = FixedArray::make(frames * 2, 0.0)
  let w = 2.0 * @math.PI * 1000.0 / 48000.0
  for n = 0; n < frames; n = n + 1 {
    x[n * 2] = Float::from_double(0.5 * @math.sin(w * n.to_double()))
    x[n * 2 + 1] = 0.0
  }
  let y = r.process(x, frames, 2)
  assert_eq(y.length(), 1600 * 2)
  // 右声道应保持全零（不能把左声道的内容漏过去）
  for n = 100; n < 1500; n = n + 1 {
    if y[n * 2 + 1].to_double().abs() > 1.0e-6 {
      fail("右声道第 " + n.to_string() + " 帧被串扰")
    }
  }
}

test "往返：16k→48k→16k 对带限信号接近恒等（SNR > 60 dB）" {
  let up = @resample.Resampler::new(16000, 48000)
  let down = @resample.Resampler::new(48000, 16000)
  let x = make_sine(16000, 16000, 1000.0, 0.5)
  let y1 = up.process(x, 16000, 1)
  let y2 = down.process(y1, 48000, 1)
  let snr = snr_db(x, y2, 300)
  if snr < 60.0 {
    fail("往返 SNR 仅 " + fmt_db(snr) + " dB")
  }
}

test "错误：非法采样率" {
  let raised = try @resample.Resampler::new(0, 16000) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
}

// ---------------------------------------------------------------------------
// 指标快照：把实测值钉在测试里。
// 目的有二：① README 里的数字有出处；② 指标劣化会直接让测试红。
// 数值取一位小数，避免不同后端数学库的末位差异造成假失败。
// ---------------------------------------------------------------------------

test "指标快照：抗混叠抑制（9 kHz 与 20 kHz，三档质量）" {
  inspect(fmt_db(alias_rejection_db(@resample.Quality::Fast, 9000.0)), content=(
    #|20.98
  ))
  inspect(fmt_db(alias_rejection_db(@resample.Quality::Balanced, 9000.0)), content=(
    #|87.79
  ))
  inspect(fmt_db(alias_rejection_db(@resample.Quality::Best, 9000.0)), content=(
    #|112.32
  ))
  inspect(fmt_db(alias_rejection_db(@resample.Quality::Fast, 20000.0)), content=(
    #|76.36
  ))
  inspect(fmt_db(alias_rejection_db(@resample.Quality::Balanced, 20000.0)), content=(
    #|102.9
  ))
  inspect(fmt_db(alias_rejection_db(@resample.Quality::Best, 20000.0)), content=(
    #|128.47
  ))
}

test "指标快照：通带 SNR（1 kHz 正弦对解析解）" {
  let r = @resample.Resampler::new(48000, 16000)
  let x = make_sine(48000, 48000, 1000.0, 0.5)
  let y = r.process(x, 48000, 1)
  let reference = make_sine(16000, 16000, 1000.0, 0.5)
  inspect(fmt_db(snr_db(reference, y, 200)), content=(
    #|94.58
  ))
  inspect(r.filter_length().to_string(), content=(
    #|145
  ))
}
