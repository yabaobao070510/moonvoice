///|
/// 用户视角的 API 测试：这两段代码就是别人用这个库时会写的代码。
///
/// 放在这里的理由：接口好用不好用，只能通过在"使用者的位置"写一遍来验证。
/// 这两条测试同时是用法文档——如果哪天接口改得难用了，这里会先红。

///| 造一段 1 秒 16 kHz 的音频：前半静音、后半语音样
fn demo_audio() -> @audio.Audio {
  let rate = 16000
  let n = rate
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  let mut seed = 99
  for i = 0; i < n; i = i + 1 {
    seed = (seed * 25173 + 13849) % 65536
    let noise = 0.002 * (seed.to_double() / 32768.0 - 1.0)
    if i >= n / 2 {
      // 后半段：120 Hz 谐波堆（模拟浊音）
      let t = (i - n / 2).to_double() / rate.to_double()
      let mut v = 0.0
      for k = 1; k <= 8; k = k + 1 {
        v = v + @math.sin(2.0 * @math.PI * 120.0 * k.to_double() * t) / k.to_double()
      }
      samples[i] = Float::from_double(v * 0.25 + noise)
    } else {
      samples[i] = Float::from_double(noise)
    }
  }
  @audio.Audio::new(rate, 1, samples)
}

///| 用法一：只要分段数据 —— 一步到位，不经过 JSON
test "API: detect_segments 直接返回段数组，字段可直接读" {
  let audio = demo_audio()
  let segs = @vad.detect_segments(
    audio,
    @vad.VadParams::default(),
    @vad.VadEngine::Fused,
  )
  if segs.length() == 0 {
    fail("后半段有语音，应该至少检出 1 段")
  }
  // 段字段可直接消费（不必解析 JSON）
  let s = segs[0]
  if s.start_ms() < 300 || s.start_ms() > 700 {
    fail("起点应在语音开始（500 ms）附近，实际 " + s.start_ms().to_string())
  }
  if s.duration_ms() <= 0 {
    fail("段时长应为正")
  }
  if s.confidence() <= 0.0 || s.confidence() > 1.0 {
    fail("置信度应在 (0,1]，实际 " + s.confidence().to_string())
  }
  // 能量应为负 dBFS（归一化样本的 RMS）
  if s.rms_dbfs() > 0.0 {
    fail("RMS 应为负值，实际 " + s.rms_dbfs().to_string())
  }
}

///| 用法二：要 JSON 交给下游 —— 结果对象本身也可读，不必回头解析
test "API: build_result 的每个字段都有访问器" {
  let audio = demo_audio()
  let result = @vad.build_result(
    audio,
    @vad.VadParams::default(),
    @vad.VadEngine::Fused,
  )
  assert_eq(result.source().sample_rate(), 16000)
  assert_eq(result.source().channels(), 1)
  assert_eq(result.params().engine(), "fused")
  assert_eq(result.params().frame_ms(), 30)
  let segs = result.segments()
  if segs.length() == 0 {
    fail("应检出至少 1 段")
  }
  if result.stats().speech_ms() <= 0 {
    fail("语音总时长应为正")
  }
  let ratio = result.stats().ratio()
  if ratio <= 0.0 || ratio > 1.0 {
    fail("语音占比应在 (0,1]，实际 " + ratio.to_string())
  }
  // JSON 仍可正常产出（两条路都通）
  let json = result.to_json_string()
  if json.length() < 20 {
    fail("JSON 过短：" + json)
  }
}

///| 用法三：重采样 + 分段 —— 前端链路的两步各自都能单独用
test "API: 重采样与分段可以各自单独调用、组合使用" {
  let audio = demo_audio()
  // 单独重采样
  let up = @resample.resample_audio(audio, 48000)
  assert_eq(up.sample_rate(), 48000)
  // 再单独分段（此时已是 48k）
  let segs = @vad.detect_segments(
    up,
    @vad.VadParams::default(),
    @vad.VadEngine::Fused,
  )
  if segs.length() == 0 {
    fail("重采样后仍应检出语音段")
  }
  // 段仍然落在正确的时间位置（毫秒不随采样率变化）
  if segs[0].start_ms() < 300 || segs[0].start_ms() > 700 {
    fail("重采样不应改变时间轴，实际起点 " + segs[0].start_ms().to_string())
  }
}
