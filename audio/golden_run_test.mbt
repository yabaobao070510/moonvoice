///|
/// 金标对拍：被测实现 vs libsndfile（第三方独立解码器）。
///
/// 容差怎么定的（不是拍脑袋）：
/// - u8 / s16 / s24 / f32：样本是 k/2^n 且 n ≤ 24，f32 尾数 24 位可精确表示
///   → 容差 0，要求逐样本完全相等。
/// - s32 / f64：需 31/53 位尾数，落进 f32 会舍入，理论相对误差 ≤ 2^-24 ≈ 6e-8
///   → 容差取 1e-7（约 1.7 倍理论界，留一点余量但不放水）。

fn check_golden(
  name : String,
  wav : Bytes,
  meta : (Int, Int, Int),
  expected : Array[Double],
  eps : Double,
) -> Unit raise {
  let (rate, channels, frames) = meta
  let a = @audio.decode_wav(wav)
  if a.sample_rate() != rate {
    fail(
      name +
      ": 采样率 " +
      a.sample_rate().to_string() +
      " != " +
      rate.to_string(),
    )
  }
  if a.channels() != channels {
    fail(
      name +
      ": 声道数 " +
      a.channels().to_string() +
      " != " +
      channels.to_string(),
    )
  }
  if a.frames() != frames {
    fail(
      name +
      ": 帧数 " +
      a.frames().to_string() +
      " != " +
      frames.to_string(),
    )
  }
  let got = a.samples()
  if got.length() != expected.length() {
    fail(name + ": 样本数不符")
  }
  let mut worst = 0.0
  let mut worst_at = 0
  for i = 0; i < expected.length(); i = i + 1 {
    let d = got[i].to_double() - expected[i]
    let ad = if d < 0.0 { -d } else { d }
    if ad > worst {
      worst = ad
      worst_at = i
    }
  }
  if worst > eps {
    fail(
      name +
      ": 与 libsndfile 的最大偏差 " +
      worst.to_string() +
      "（第 " +
      worst_at.to_string() +
      " 个样本）超过容差 " +
      eps.to_string(),
    )
  }
}

test "golden: 8-bit 无符号（要求逐样本相等）" {
  check_golden(
    "u8",
    golden_sine_u8_mono_wav(),
    golden_sine_u8_mono_meta(),
    golden_sine_u8_mono_expected(),
    0.0,
  )
}

test "golden: 16-bit 有符号（要求逐样本相等）" {
  check_golden(
    "s16",
    golden_sine_s16_mono_wav(),
    golden_sine_s16_mono_meta(),
    golden_sine_s16_mono_expected(),
    0.0,
  )
}

test "golden: 24-bit 有符号（要求逐样本相等）" {
  check_golden(
    "s24",
    golden_sine_s24_mono_wav(),
    golden_sine_s24_mono_meta(),
    golden_sine_s24_mono_expected(),
    0.0,
  )
}

test "golden: 32-bit 有符号（f32 表示，容差 1e-7）" {
  check_golden(
    "s32",
    golden_sine_s32_mono_wav(),
    golden_sine_s32_mono_meta(),
    golden_sine_s32_mono_expected(),
    1.0e-7,
  )
}

test "golden: 32-bit 浮点（要求逐样本相等）" {
  check_golden(
    "f32",
    golden_sine_f32_mono_wav(),
    golden_sine_f32_mono_meta(),
    golden_sine_f32_mono_expected(),
    0.0,
  )
}

test "golden: 64-bit 浮点（f32 表示，容差 1e-7）" {
  check_golden(
    "f64",
    golden_sine_f64_mono_wav(),
    golden_sine_f64_mono_meta(),
    golden_sine_f64_mono_expected(),
    1.0e-7,
  )
}

test "golden: 16-bit 立体声交错（要求逐样本相等）" {
  check_golden(
    "s16_stereo",
    golden_sine_s16_stereo_wav(),
    golden_sine_s16_stereo_meta(),
    golden_sine_s16_stereo_expected(),
    0.0,
  )
}

///| ffmpeg 写 WAV 时会附带 LIST/INFO 元数据块，解析器必须原样保留
test "golden: ffmpeg 的元数据块被保留" {
  let a = @audio.decode_wav(golden_sine_u8_mono_wav())
  let chunks = a.extra_chunks()
  if chunks.length() == 0 {
    fail("ffmpeg fixture 应带有 LIST/INFO 等元数据块")
  }
}
