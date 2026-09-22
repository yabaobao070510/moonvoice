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

///| 用法四：原语组合 —— 检出语音段后把它们拼成"干净人声"
test "API: 检出 + 切片 + 拼接 = 去掉静音的干净语音" {
  let audio = demo_audio()
  let segs = @vad.detect_segments(
    audio,
    @vad.VadParams::default(),
    @vad.VadEngine::Fused,
  )
  if segs.length() == 0 {
    fail("应检出语音段")
  }
  // 单段提取
  let parts = @vad.extract_segments(audio, segs)
  assert_eq(parts.length(), segs.length())
  assert_eq(parts[0].frames(), segs[0].duration_ms() * 16000 / 1000)
  // 拼成一条：长度应等于各段之和，且短于原音频（静音被去掉）
  let joined = @vad.speech_only(audio, segs)
  let expected = @segments.total_speech_ms(segs) * 16000 / 1000
  if (joined.frames() - expected).abs() > 8 {
    fail(
      "拼接长度 " +
      joined.frames().to_string() +
      " 与各段之和 " +
      expected.to_string() +
      " 不符",
    )
  }
  if joined.frames() >= audio.frames() {
    fail("去掉静音后应短于原音频")
  }
  // 采样率与声道保持不变
  assert_eq(joined.sample_rate(), 16000)
  assert_eq(joined.channels(), 1)
}

///| 用法五：音频原语可脱离语音场景单独组合
test "API: 音频原语（切片/拼接/增益/归一化/混音）独立可用" {
  let a = demo_audio()
  // 切片 + 增益
  let head = a.slice_ms(0, 200)
  assert_eq(head.frames(), 3200)
  let louder = head.apply_gain_db(6.0)
  if louder.peak() <= head.peak() {
    fail("+6 dB 后峰值应变大")
  }
  // 归一化：峰值应落到目标附近
  let norm = louder.normalize_peak(target=0.5)
  if (norm.peak() - 0.5).abs() > 1.0e-4 {
    fail("归一化后峰值应为 0.5，实际 " + norm.peak().to_string())
  }
  // 拼接：两段相同音频拼起来，长度翻倍
  let doubled = @audio.Audio::concat([head, head])
  assert_eq(doubled.frames(), head.frames() * 2)
  // 混音：a 与静音按 0.5 混，峰值应减半
  let silence = head.apply_gain_db(-200.0)
  let mixed = @audio.Audio::mix(head, silence, ratio=0.5)
  if (mixed.peak() - head.peak() * 0.5).abs() > 1.0e-4 {
    fail("混音后峰值应减半")
  }
  // 错误路径：长度不一致的混音必须报错而不是静默截断
  let raised = try @audio.Audio::mix(head, a, ratio=0.5) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
}

///| 用法六（回归）：rms_dbfs 必须在**最终边界**上实测——合并链路不能让它变成"最轻碎片"的值。
/// 2026-09-22 修复：旧实现里 merge_close 的保守取最小会外泄到输出字段
/// （实测案例：AMI 会议素材段内真实 RMS -46.6 dBFS、字段却报 -85.9——某个门控静音碎片的电平）。
test "API: 段 rms 在最终边界上实测（不被合并的最轻碎片污染）" {
  let rate = 16000
  let n = rate * 2
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  let mut seed = 7
  let voiced = fn(i : Int, amp : Double) {
    let t = i.to_double() / rate.to_double()
    let mut v = 0.0
    for k = 1; k <= 8; k = k + 1 {
      v = v + @math.sin(2.0 * @math.PI * 120.0 * k.to_double() * t) / k.to_double()
    }
    v * amp
  }
  for i = 0; i < n; i = i + 1 {
    seed = (seed * 25173 + 13849) % 65536
    let noise = 0.002 * (seed.to_double() / 32768.0 - 1.0)
    let ms = i * 1000 / rate
    // 0-800ms 响段；800-950ms 低噪间隙（< min_silence 250ms → 会被合并）；
    // 950-1750ms 轻段（仍判语音，但比响段低约 22 dB）；其后静音
    let v = if ms < 800 {
      voiced(i, 0.25)
    } else if ms < 950 {
      0.0
    } else if ms < 1750 {
      voiced(i, 0.02)
    } else {
      0.0
    }
    samples[i] = Float::from_double(v + noise)
  }
  let audio = @audio.Audio::new(rate, 1, samples)
  let segs = @vad.detect_segments(audio, @vad.VadParams::default(), @vad.VadEngine::Fused)
  if segs.length() == 0 {
    fail("应检出语音段")
  }
  // 通用不变式：每个段的 rms 都应等于其最终 [start,end) 区间上的直接实测值
  for s in segs {
    let from = s.start_ms() * rate / 1000
    let to = if s.end_ms() * rate / 1000 < n { s.end_ms() * rate / 1000 } else { n }
    let mut acc = 0.0
    for i = from; i < to; i = i + 1 {
      acc = acc + samples[i].to_double() * samples[i].to_double()
    }
    let cnt = (to - from).to_double()
    let expected = if cnt > 0.0 && acc > 0.0 { 10.0 * @math.log10(acc / cnt) } else { -160.0 }
    if (s.rms_dbfs() - expected).abs() > 0.05 {
      fail(
        "段 [" + s.start_ms().to_string() + "," + s.end_ms().to_string() +
        ") 的 rms 应为实测 " + expected.to_string() + "，实际 " + s.rms_dbfs().to_string(),
      )
    }
  }
  // 定向回归：若响段与轻段被合并成一段，该段不能上报"轻段/碎片"的电平
  for s in segs {
    if s.start_ms() <= 400 && s.end_ms() >= 1400 {
      let qf = 950 * rate / 1000
      let qt = 1750 * rate / 1000
      let mut acc = 0.0
      for i = qf; i < qt; i = i + 1 {
        acc = acc + samples[i].to_double() * samples[i].to_double()
      }
      let quiet_rms = 10.0 * @math.log10(acc / (qt - qf).to_double())
      if s.rms_dbfs() - quiet_rms < 6.0 {
        fail(
          "合并段的 rms 疑似取了最轻碎片（旧版 bug 回归）：段报 " +
          s.rms_dbfs().to_string() + "，轻段实测 " + quiet_rms.to_string(),
        )
      }
    }
  }
}
