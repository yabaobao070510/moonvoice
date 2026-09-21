///|
/// moonvoice 性能基准
///
/// 为什么要有这个包：README 里写"零依赖、快"而不给数字，等于没写。
/// 这个工具把三条热路径的吞吐量测出来，数字直接进 README。
///
/// 跑法：
///   moon run --target wasm --release benches
///   moon run --target native --release benches    # 与 wasm 对比

///| 计时一次调用，返回**秒**。
/// 注意：@bench.monotonic_clock_end 的返回值单位是**微秒**（与外部 wall clock 核对过：
/// 内部 8159.4 vs 外部总耗时 0.387 s，反推 8.16 ms），这里统一换算成秒。
fn time_once(f : () -> Unit raise) -> Double raise {
  let t0 = @bench.monotonic_clock_start()
  f()
  @bench.monotonic_clock_end(t0) / 1000000.0
}

///| 取多轮中位数（避免首次分配/预热影响）
fn median_seconds(iters : Int, f : () -> Unit raise) -> Double raise {
  let samples : Array[Double] = []
  for i = 0; i < iters; i = i + 1 {
    // 每轮前先跑一次预热，避免把冷启动算进去
    ignore(time_once(f))
    samples.push(time_once(f))
  }
  let a = samples.copy()
  for i = 1; i < a.length(); i = i + 1 {
    let v = a[i]
    let mut j = i - 1
    while j >= 0 && a[j] > v {
      a[j + 1] = a[j]
      j = j - 1
    }
    a[j + 1] = v
  }
  a[a.length() / 2]
}

fn fmt2(x : Double) -> String {
  let v = (x * 100.0 + 0.5).to_int().to_double() / 100.0
  v.to_string()
}

///| 造一段可解码的 WAV（伪随机样本，避免压成静音被优化掉）
fn make_test_wav(rate : Int, seconds : Int, channels : Int) -> Bytes raise {
  let frames = rate * seconds
  let samples : FixedArray[Float] = FixedArray::make(frames * channels, 0.0)
  let mut seed = 1
  for i = 0; i < samples.length(); i = i + 1 {
    seed = (seed * 25173 + 13849) % 65536
    samples[i] = Float::from_double(seed.to_double() / 65536.0 - 0.5)
  }
  @audio.encode_wav(@audio.Audio::new(rate, channels, samples))
}

fn main raise {
  let line = "─────────────────────────────────────────────────────────────"
  println("moonvoice 性能基准\n" + line + "\n")

  // ---- WAV 解码 ----
  let wav = make_test_wav(16000, 30, 2) // 30 秒立体声 16-bit
  let bytes = wav.length()
  let n_samples = 16000 * 30 * 2
  let dt_decode = median_seconds(5, fn() raise {
    ignore(@audio.decode_wav(wav))
  })
  println(
    "WAV 解码      : " +
    fmt2(bytes.to_double() / 1048576.0 / dt_decode) +
    " MB/s   （" +
    fmt2(n_samples.to_double() / 1000000.0 / dt_decode) +
    " M样本/s）\n",
  )

  // ---- 重采样 48k → 16k ----
  let frames48 = 48000 * 10
  let src : FixedArray[Float] = FixedArray::make(frames48, 0.0)
  let mut seed = 7
  for i = 0; i < frames48; i = i + 1 {
    seed = (seed * 25173 + 13849) % 65536
    src[i] = Float::from_double(seed.to_double() / 65536.0 - 0.5)
  }
  let rs = @resample.Resampler::new(48000, 16000)
  let dt_rs = median_seconds(3, fn() {
    ignore(rs.process(src, frames48, 1))
  })
  println(
    "重采样 48k→16k: " +
    fmt2(frames48.to_double() / 1000000.0 / dt_rs) +
    " M输入样本/s   （" +
    fmt2(10.0 / dt_rs) +
    " 倍实时）  滤波器 " +
    rs.filter_length().to_string() +
    " 抽头\n",
  )

  // ---- VAD（16k 单声道，30 秒）----
  let vad_rate = 16000
  let vad_secs = 30
  let mono : FixedArray[Float] = FixedArray::make(vad_rate * vad_secs, 0.0)
  let mut s2 = 11
  for i = 0; i < mono.length(); i = i + 1 {
    s2 = (s2 * 25173 + 13849) % 65536
    mono[i] = Float::from_double((s2.to_double() / 65536.0 - 0.5) * 0.4)
  }
  let params = @vad.VadParams::default()
  let dt_vad = median_seconds(3, fn() {
    ignore(@vad.analyze_frames(mono, vad_rate, params, @vad.VadEngine::Fused))
  })
  println(
    "VAD (fused)   : " + fmt2(vad_secs.to_double() / dt_vad) + " 倍实时\n",
  )

  // ---- FFT ----
  let fft_in : FixedArray[Float] = FixedArray::make(512, 0.0)
  for i = 0; i < 512; i = i + 1 {
    fft_in[i] = Float::from_double(@math.sin(i.to_double() * 0.1))
  }
  let fft_iters = 2000
  let dt_fft = median_seconds(3, fn() {
    for i = 0; i < fft_iters; i = i + 1 {
      ignore(@feature.power_spectrum(fft_in, 512))
    }
  })
  println(
    "FFT 512 点    : " +
    fmt2(fft_iters.to_double() / dt_fft / 1000.0) +
    " 千次/s\n",
  )

  println(line + "\n")
}
