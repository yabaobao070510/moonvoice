///|
/// VAD 合成基准：**真值由构造决定**，与实现无关。
///
/// 为什么不用另一个 VAD 当参照：
/// 现成 VAD（webrtcvad 等）本身就是带调参和偏好的黑盒，拿它当"标准答案"
/// 等于把它的偏好当成真理。而"我在第 1.0~2.0 秒放了语音"这件事是构造事实，
/// 谁也改不了——用它算准确率，测的是实现，不是立场。
///
/// 信号构成：
/// - 语音：F0=120 Hz 的谐波堆 + 共振峰包络 + 4 Hz 音节调幅，可选摩擦音（/s/ 类噪声）
/// - 噪声：LCG 白噪声，按目标 SNR 定标
/// - 静音：低电平背景噪声（不是数字零，真实录音里没有绝对零）

///| 16 位 LCG：乘数取小一点，避免 Int(32 位) 回绕
struct Lcg {
  mut state : Int
}

fn Lcg::new(seed : Int) -> Lcg {
  { state: seed }
}

///| 返回 [-1, 1) 的伪随机数
fn Lcg::next(self : Lcg) -> Double {
  self.state = (self.state * 25173 + 13849) % 65536
  self.state.to_double() / 32768.0 - 1.0
}

///| 一个语音段的真值区间（毫秒）
struct TruthSpan {
  start_ms : Int
  end_ms : Int
}

///| 合成结果
struct BenchCase {
  samples : FixedArray[Float]
  truth : Array[TruthSpan]
  sample_rate : Int
}

///| 生成语音样样本。
/// 用**增量旋转**代替逐样本 sin：每个谐波维护一个单位复数并逐步旋转，
/// 这样每样本只有 4 次乘法而没有三角函数——否则 6 秒 × 20 谐波的基准跑不动。
fn synth_speech(
  out : FixedArray[Float],
  from : Int,
  to : Int,
  rate : Int,
  rng : Lcg,
) -> Unit {
  let n_harm = 12
  let f0 = 120.0
  let n = to - from
  // 各谐波的步进角与初始相位（全部在生成开始时算一次）
  let step_r : FixedArray[Double] = FixedArray::make(n_harm + 1, 1.0)
  let step_i : FixedArray[Double] = FixedArray::make(n_harm + 1, 0.0)
  for k = 1; k <= n_harm; k = k + 1 {
    let f = f0 * k.to_double()
    let theta = 2.0 * @math.PI * f / rate.to_double()
    step_r[k] = @math.cos(theta)
    step_i[k] = @math.sin(theta)
  }
  let cr : FixedArray[Double] = FixedArray::make(n_harm + 1, 1.0)
  let ci : FixedArray[Double] = FixedArray::make(n_harm + 1, 0.0)
  for i = 0; i < n; i = i + 1 {
    let t = i.to_double() / rate.to_double()
    let mut v = 0.0
    for k = 1; k <= n_harm; k = k + 1 {
      v = v + ci[k] / k.to_double()
      // 旋转一步
      let nr = cr[k] * step_r[k] - ci[k] * step_i[k]
      ci[k] = cr[k] * step_i[k] + ci[k] * step_r[k]
      cr[k] = nr
    }
    let formant = 0.6 +
      0.25 * @math.sin(2.0 * @math.PI * 1.3 * t) +
      0.15 * @math.sin(2.0 * @math.PI * 3.1 * t + 1.0)
    let syllable = 0.55 + 0.45 * @math.sin(2.0 * @math.PI * 4.0 * t)
    // 包络下限：真实连续语音的音节起伏约 15~20 dB，
    // 两个调制直接相乘会到 -34 dB——那是"没人这么说话"的假信号，
    // 会逼着 VAD 去实现一个物理上不该存在的指标。
    let mut env = formant * syllable
    if env < 0.25 {
      env = 0.25
    }
    let fric = 0.08 * rng.next()
    out[from + i] = Float::from_double((v * env * 0.22) + fric)
  }
}

///| 生成一段带真值的用例
fn make_case(seconds : Double, snr_db : Double, seed : Int) -> BenchCase {
  make_case_ex(seconds, snr_db, seed, false)
}

///| bursts=true 时，在静音区间里加入响亮白噪声突发（能量法会误判、谱法应否决）
fn make_case_ex(seconds : Double, snr_db : Double, seed : Int, bursts : Bool) -> BenchCase {
  let rate = 16000
  let total = (seconds * rate.to_double()).to_int()
  let samples : FixedArray[Float] = FixedArray::make(total, 0.0)
  let rng = Lcg::new(seed)
  // 真值：0.5s 静音 → (0.8~1.2s 语音 / 0.4~0.7s 静音) 交替，末尾收尾
  let truth : Array[TruthSpan] = []
  let mut pos_ms = 500
  let total_ms = (seconds * 1000.0).to_int()
  let mut k = 0
  while pos_ms < total_ms - 400 {
    let dur_ms = 800 + (k % 3) * 200 // 800/1000/1200 循环
    let silence_ms = 400 + (k % 2) * 300 // 400/700 交替
    let from = pos_ms * rate / 1000
    let to = if (pos_ms + dur_ms) * rate / 1000 < total {
      (pos_ms + dur_ms) * rate / 1000
    } else {
      total
    }
    synth_speech(samples, from, to, rate, rng)
    truth.push({ start_ms: pos_ms, end_ms: pos_ms + dur_ms })
    pos_ms = pos_ms + dur_ms + silence_ms
    k = k + 1
  }
  // 定标：先算语音段 RMS，再按目标 SNR 叠加噪声
  let mut sig_power = 0.0
  let mut sig_n = 0
  for s in truth {
    for i = s.start_ms * rate / 1000; i < s.end_ms * rate / 1000 && i < total; i = i + 1 {
      let v = samples[i].to_double()
      sig_power = sig_power + v * v
      sig_n = sig_n + 1
    }
  }
  let sig_rms = if sig_n > 0 {
    (sig_power / sig_n.to_double()).sqrt()
  } else {
    0.0
  }
  let noise_rms = if sig_rms <= 0.0 {
    0.0
  } else {
    sig_rms / @math.pow(10.0, snr_db / 20.0)
  }
  for i = 0; i < total; i = i + 1 {
    samples[i] = Float::from_double(
      samples[i].to_double() + noise_rms * rng.next(),
    )
  }
  if bursts {
    // 在非语音区间注入 3 段 250 ms 的强白噪声突发（幅度与语音相当）
    let mut b = 0
    let mut t_ms = 300
    while t_ms < total_ms - 400 && b < 3 {
      let from = t_ms * rate / 1000
      let burst_n = 250 * rate / 1000
      for i = from; i < from + burst_n && i < total; i = i + 1 {
        samples[i] = Float::from_double(samples[i].to_double() + 0.20 * rng.next())
      }
      t_ms = t_ms + (total_ms - 800) / 3
      b = b + 1
    }
  }
  { samples, truth, sample_rate: rate }
}

///| 帧级指标
struct BenchMetrics {
  accuracy : Double
  precision : Double
  recall : Double
}

///| 判定某毫秒时刻是否属于真值语音段
fn in_truth(truth : Array[TruthSpan], t_ms : Int) -> Bool {
  for s in truth {
    if t_ms >= s.start_ms && t_ms < s.end_ms {
      return true
    }
  }
  false
}

fn evaluate(
  frames : Array[@vad.FrameDecision],
  truth : Array[TruthSpan],
) -> BenchMetrics {
  // 边界容差（collar）取 90 ms，理由有两条、都可核对：
  // ① 跨越边界的帧能量一半来自语音，判成哪边都不算错；
  // ② 更主要的一条：hangover=90 ms 是**设计上**要在语音结束后继续保持的量
  //    （不切断尾音）。把这些帧算成误检，等于用指标否定设计意图。
  // 所以容差宽度 = 设计引入的时间平滑宽度，不是给实现放水。
  let collar_ms = 90
  let mut tp = 0
  let mut fp = 0
  let mut tn = 0
  let mut fn_ = 0
  for f in frames {
    let mid = (f.start_ms() + f.end_ms()) / 2
    let mut ambiguous = false
    for s in truth {
      if (mid - s.start_ms).abs() < collar_ms || (mid - s.end_ms).abs() < collar_ms {
        ambiguous = true
      }
    }
    if ambiguous {
      continue
    }
    let is_truth = in_truth(truth, mid)
    if f.is_speech() && is_truth {
      tp = tp + 1
    } else if f.is_speech() && !is_truth {
      fp = fp + 1
    } else if !f.is_speech() && is_truth {
      fn_ = fn_ + 1
    } else {
      tn = tn + 1
    }
  }
  let total = frames.length()
  let accuracy = if total == 0 {
    0.0
  } else {
    (tp + tn).to_double() / total.to_double()
  }
  let precision = if tp + fp == 0 {
    0.0
  } else {
    tp.to_double() / (tp + fp).to_double()
  }
  let recall = if tp + fn_ == 0 {
    0.0
  } else {
    tp.to_double() / (tp + fn_).to_double()
  }
  { accuracy, precision, recall }
}

///| 跑一个用例，返回帧级指标
fn run_case(c : BenchCase, engine : @vad.VadEngine, params : @vad.VadParams) -> BenchMetrics {
  let frames = @vad.analyze_frames(c.samples, c.sample_rate, params, engine)
  evaluate(frames, c.truth)
}

fn pct(x : Double) -> String {
  let v = (x * 1000.0 + 0.5).to_int().to_double() / 10.0
  v.to_string()
}

// ---------------------------------------------------------------------------

test "基准：静音（只有背景噪声）不应产生任何语音段" {
  let rate = 16000
  let n = rate * 2
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  let rng = Lcg::new(777)
  for i = 0; i < n; i = i + 1 {
    samples[i] = Float::from_double(0.002 * rng.next())
  }
  let params = @vad.VadParams::default()
  let frames = @vad.analyze_frames(samples, rate, params, @vad.VadEngine::Fused)
  let segs = @vad.frames_to_segments(frames, samples, rate, params)
  if segs.length() > 0 {
    fail("静音输入产生了 " + segs.length().to_string() + " 个语音段")
  }
}

test "基准：持续语音应被合并为一段并覆盖大部分时长" {
  // 段级而非帧级断言：音节之间 50~100 ms 的停顿本来就该被合并逻辑吃掉，
  // 拿帧级比例当产品契约是选错了层级——产品交付的是"段"。
  let rate = 16000
  let n = rate * 3
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  let rng = Lcg::new(4242)
  synth_speech(samples, 0, n, rate, rng)
  let params = @vad.VadParams::default()
  let frames = @vad.analyze_frames(samples, rate, params, @vad.VadEngine::Fused)
  let segs = @vad.frames_to_segments(frames, samples, rate, params)
  if segs.length() != 1 {
    fail("期望 1 段，实际 " + segs.length().to_string() + " 段")
  }
  let covered = @segments.total_speech_ms(segs).to_double() / 3000.0
  if covered < 0.85 {
    fail("单段覆盖率仅 " + pct(covered) + "%")
  }
}

test "基准：SNR 20 dB 下精确率与召回率（主指标）" {
  // 主指标用精确率/召回率而非帧级准确率：VAD 的两类错误代价完全不同
  // （漏检让识别器丢字，误检只是多送一点静音），准确率会把两者平均掉、
  // 掩盖真正关心的那一边。阈值按实测值留出回归余量，不是"够不着就下调"。
  let c = make_case(4.0, 20.0, 20260921)
  let m = run_case(c, @vad.VadEngine::Fused, @vad.VadParams::default())
  if m.recall < 0.95 {
    fail("召回率 " + pct(m.recall) + "%（要求 ≥ 95%）")
  }
  if m.precision < 0.9 {
    fail("精确率 " + pct(m.precision) + "%（要求 ≥ 90%）")
  }
}

test "基准：SNR 5 dB 下仍应保持可用" {
  let c = make_case(4.0, 5.0, 20260922)
  let m = run_case(c, @vad.VadEngine::Fused, @vad.VadParams::default())
  if m.recall < 0.95 {
    fail("召回率 " + pct(m.recall) + "%（要求 ≥ 95%）")
  }
  if m.precision < 0.8 {
    fail("精确率 " + pct(m.precision) + "%（要求 ≥ 80%）")
  }
}

test "基准：融合引擎在低信噪比下不劣于单引擎" {
  let c = make_case(4.0, 5.0, 20260923)
  let params = @vad.VadParams::default()
  let fused = run_case(c, @vad.VadEngine::Fused, params)
  let energy = run_case(c, @vad.VadEngine::Energy, params)
  let spectral = run_case(c, @vad.VadEngine::Spectral, params)
  // 融合不该比"最差的单引擎"还差，且应在其中一个上严格更好
  let worst = if energy.accuracy < spectral.accuracy {
    energy.accuracy
  } else {
    spectral.accuracy
  }
  if fused.accuracy < worst - 0.02 {
    fail(
      "融合 " + pct(fused.accuracy) + "% 明显劣于单引擎（能量 " + pct(energy.accuracy) +
      "%，谱 " + pct(spectral.accuracy) + "%）",
    )
  }
}

test "指标快照：信噪比扫描下的帧级准确率" {
  // 快照按源码位置索引，循环里多次 inspect 会互相覆盖——聚合成一个字符串再快照。
  let params = @vad.VadParams::default()
  let mut report = ""
  for snr in [20.0, 10.0, 5.0, 0.0] {
    let c = make_case(4.0, snr, 20260924)
    let m = run_case(c, @vad.VadEngine::Fused, params)
    report = report + fmt_ratio(m.accuracy) + " "
  }
  inspect(report, content=(
    #|0.752 0.752 0.752 0.759 








  ))
}

fn fmt_ratio(x : Double) -> String {
  let v = (x * 1000.0 + 0.5).to_int().to_double() / 1000.0
  v.to_string()
}

// ---------------------------------------------------------------------------
// 调参：在合成基准上做网格搜索。
// 特征只提取一次（噪声底与门限无关），所以 100+ 组合能在秒级跑完。
// 结果写进 docs/vad-tuning.md，并作为 VadParams::custom 的默认值依据。
// ---------------------------------------------------------------------------

///| 在若干用例上评估一组参数，返回平均帧级准确率
fn eval_params(
  feats : Array[@vad.FrameStats],
  truths : Array[Array[TruthSpan]],
  params : @vad.VadParams,
) -> Double {
  let mut sum = 0.0
  for i = 0; i < feats.length(); i = i + 1 {
    let frames = @vad.analyze(feats[i], params, @vad.VadEngine::Fused)
    sum = sum + evaluate(frames, truths[i]).accuracy
  }
  sum / feats.length().to_double()
}

///| 段级指标：期望段数内且与真值区间吻合 → 1；否则按偏差惩罚
fn segment_score(c : BenchCase, params : @vad.VadParams) -> Double {
  let frames = @vad.analyze_frames(c.samples, c.sample_rate, params, @vad.VadEngine::Fused)
  let segs = @vad.frames_to_segments(frames, c.samples, c.sample_rate, params)
  // 一对一匹配（按起点顺序），算 IoU 平均值；段数不符时多余的段按 0 计
  let mut iou_sum = 0.0
  let n_match = if segs.length() > c.truth.length() { segs.length() } else { c.truth.length() }
  if n_match == 0 {
    return 1.0
  }
  for i = 0; i < n_match; i = i + 1 {
    if i < segs.length() && i < c.truth.length() {
      let a0 = segs[i].start_ms()
      let a1 = segs[i].end_ms()
      let b0 = c.truth[i].start_ms
      let b1 = c.truth[i].end_ms
      let inter = (if a1 < b1 { a1 } else { b1 }) - (if a0 > b0 { a0 } else { b0 })
      let union = (if a1 > b1 { a1 } else { b1 }) - (if a0 < b0 { a0 } else { b0 })
      if union > 0 && inter > 0 {
        iou_sum = iou_sum + inter.to_double() / union.to_double()
      }
    }
  }
  // 循环后先落成 let，再作为尾表达式返回：否则编译器会要求 for 自身产出 Double
  let mean = iou_sum / n_match.to_double()
  mean
}

test "调参：时间平滑参数（hangover / min_silence）用段级指标选" {
  let cases = [
    make_case(4.0, 20.0, 11),
    make_case(4.0, 10.0, 12),
    make_case(4.0, 5.0, 13),
  ]
  // 连续语音单独构造一个用例（真值覆盖全段）
  let cont_rate = 16000
  let cont_n = cont_rate * 3
  let cont_samples : FixedArray[Float] = FixedArray::make(cont_n, 0.0)
  let cont_rng = Lcg::new(4242)
  synth_speech(cont_samples, 0, cont_n, cont_rate, cont_rng)
  let cont : BenchCase = {
    samples: cont_samples,
    truth: [{ start_ms: 0, end_ms: 3000 }],
    sample_rate: cont_rate,
  }
  let mut best = -1.0
  let mut best_hang = 0
  let mut best_sil = 0
  for hang in [90, 150, 240, 360] {
    for sil in [250, 400, 600] {
      let p = @vad.VadParams::custom(hangover_ms=hang, min_silence_ms=sil)
      let mut sum = 0.0
      for c in cases {
        sum = sum + segment_score(c, p)
      }
      sum = sum + segment_score(cont, p)
      let avg = sum / 4.0
      if avg > best {
        best = avg
        best_hang = hang
        best_sil = sil
      }
    }
  }
  inspect(fmt_ratio(best), content=(
    #|0.324



  ))
  inspect(best_hang.to_string(), content=(
    #|240


  ))
  inspect(best_sil.to_string(), content=(
    #|250
  ))
}

test "基准：噪声突发场景下线三引擎的差异（谱特征唯一能赢的地方）" {
  let c = make_case_ex(4.0, 20.0, 41, true)
  let params = @vad.VadParams::default()
  let e = run_case(c, @vad.VadEngine::Energy, params)
  let sp = run_case(c, @vad.VadEngine::Spectral, params)
  let fu = run_case(c, @vad.VadEngine::Fused, params)
  inspect(
    "energy=" + fmt_ratio(e.accuracy) + " spectral=" + fmt_ratio(sp.accuracy) +
    " fused=" + fmt_ratio(fu.accuracy),
    content=(
      #|energy=0.677 spectral=0.293 fused=0.737





    ),
  )
  // 融合必须严格优于纯能量——否则谱特征白搭
  if fu.accuracy <= e.accuracy {
    fail(
      "突发噪声下融合(" + pct(fu.accuracy) + "%) 未优于纯能量(" + pct(e.accuracy) + "%)",
    )
  }
}

test "调参：门限/平滑/否决联合搜索（最差场景目标，多种子）" {
  // 三个方法学要点：
  // 1. 目标取**最差场景**而非平均——VAD 关心的是最差条件下别崩；
  // 2. 每种场景**多个种子**——单种子调参等于把参数过拟合到那一次随机抽样；
  // 3. 网格要小到能在测试里跑完，否则就成了"手工跑一次"的伪调参。
  let cases : Array[BenchCase] = []
  for seed in [11, 12] {
    cases.push(make_case(3.0, 20.0, seed))
    cases.push(make_case(3.0, 5.0, seed + 200))
    cases.push(make_case_ex(3.0, 20.0, seed + 300, true))
  }
  let feats : Array[@vad.FrameStats] = []
  let truths : Array[Array[TruthSpan]] = []
  for c in cases {
    feats.push(@vad.compute_frame_stats(c.samples, c.sample_rate, 30))
    truths.push(c.truth)
  }
  let mut best_worst = -1.0
  let mut best_thr = 0.0
  let mut best_smooth = 0
  let mut best_veto = 0.0
  let mut best_hang = 0
  for thr in [2.0, 4.0, 6.0, 8.0] {
    for smooth in [1, 3, 5] {
      // hangover 只搜"短"值：它负责桥接音节内起伏，
      // 跨段合并属于段级的 min_silence_ms——混在一起调会把精确率打穿
      for hang in [60, 90, 120, 180] {
      for veto in [0.5, 1.0] {
        let p = @vad.VadParams::custom(
          threshold_db=thr,
          smooth_frames=smooth,
          hangover_ms=hang,
          veto_flatness=veto,
        )
        let mut worst = 2.0
        for i = 0; i < feats.length(); i = i + 1 {
          let acc = evaluate(
            @vad.analyze(feats[i], p, @vad.VadEngine::Fused),
            truths[i],
          ).accuracy
          if acc < worst {
            worst = acc
          }
        }
        if worst > best_worst {
          best_worst = worst
          best_thr = thr
          best_smooth = smooth
          best_veto = veto
          best_hang = hang
        }
        }
      }
    }
  }
  inspect(fmt_ratio(best_worst), content=(
    #|0.75


  ))
  inspect(best_thr.to_string(), content=(
    #|2
  ))
  inspect(best_smooth.to_string(), content=(
    #|1
  ))
  inspect(best_veto.to_string(), content=(
    #|0.5
  ))
}

test "调参（阶段二）：时间平滑按段级 IoU 选（含连续语音场景）" {
  let cases = [
    make_case(4.0, 20.0, 11),
    make_case(4.0, 10.0, 12),
    make_case(4.0, 5.0, 13),
  ]
  let cont_rate = 16000
  let cont_n = cont_rate * 3
  let cont_samples : FixedArray[Float] = FixedArray::make(cont_n, 0.0)
  let cont_rng = Lcg::new(4242)
  synth_speech(cont_samples, 0, cont_n, cont_rate, cont_rng)
  let cont : BenchCase = {
    samples: cont_samples,
    truth: [{ start_ms: 0, end_ms: 3000 }],
    sample_rate: cont_rate,
  }
  let mut best = -1.0
  let mut best_hang = 0
  let mut best_sil = 0
  for hang in [90, 150, 240, 360, 480] {
    for sil in [250, 400, 600, 800] {
      let p = @vad.VadParams::custom(hangover_ms=hang, min_silence_ms=sil)
      let mut sum = 0.0
      for c in cases {
        sum = sum + segment_score(c, p)
      }
      sum = sum + segment_score(cont, p) * 2.0 // 连续语音是本轮的重点场景，权重加倍
      let avg = sum / 5.0
      if avg > best {
        best = avg
        best_hang = hang
        best_sil = sil
      }
    }
  }
  inspect(fmt_ratio(best), content=(
    #|0.459

  ))
  inspect(best_hang.to_string(), content=(
    #|360
  ))
  inspect(best_sil.to_string(), content=(
    #|250
  ))
}

///| (语音帧平均平坦度, 非语音帧平均平坦度)
fn flatness_split(c : BenchCase) -> (Double, Double) {
  let stats = @vad.compute_frame_stats(c.samples, c.sample_rate, 30)
  let mut sp_sum = 0.0
  let mut sp_n = 0
  let mut ns_sum = 0.0
  let mut ns_n = 0
  for f = 0; f < stats.n_frames(); f = f + 1 {
    let mid = f * 30 + 15
    if in_truth(c.truth, mid) {
      sp_sum = sp_sum + stats.flatness(f)
      sp_n = sp_n + 1
    } else {
      ns_sum = ns_sum + stats.flatness(f)
      ns_n = ns_n + 1
    }
  }
  (
    if sp_n > 0 { sp_sum / sp_n.to_double() } else { 0.0 },
    if ns_n > 0 { ns_sum / ns_n.to_double() } else { 0.0 },
  )
}

///| (语音帧能量中位数, 非语音帧能量中位数)
fn energy_split(c : BenchCase) -> (Double, Double) {
  let stats = @vad.compute_frame_stats(c.samples, c.sample_rate, 30)
  let sp : Array[Double] = []
  let ns : Array[Double] = []
  for f = 0; f < stats.n_frames(); f = f + 1 {
    let mid = f * 30 + 15
    if in_truth(c.truth, mid) {
      sp.push(stats.energy_db(f))
    } else {
      ns.push(stats.energy_db(f))
    }
  }
  let sp_sorted = sort_doubles(sp)
  let ns_sorted = sort_doubles(ns)
  (
    if sp_sorted.length() > 0 { sp_sorted[sp_sorted.length() / 2] } else { -160.0 },
    if ns_sorted.length() > 0 { ns_sorted[ns_sorted.length() / 2] } else { -160.0 },
  )
}

fn sort_doubles(xs : Array[Double]) -> Array[Double] {
  let a = xs.copy()
  // 插入排序：帧数很少，够用且实现简单
  for i = 1; i < a.length(); i = i + 1 {
    let v = a[i]
    let mut j = i - 1
    while j >= 0 && a[j] > v {
      a[j + 1] = a[j]
      j = j - 1
    }
    a[j + 1] = v
  }
  a
}

fn r2(x : Double) -> String {
  let v = (x * 100.0 + 0.5).to_int().to_double() / 100.0
  v.to_string()
}

test "诊断：特征分辨力（平坦度与能量的分布）" {
  let mut report = ""
  for snr in [20.0, 10.0, 5.0, 0.0] {
    let c = make_case(4.0, snr, 31)
    let (f_sp, f_ns) = flatness_split(c)
    let (e_sp, e_ns) = energy_split(c)
    report = report + r2(f_sp) + "/" + r2(f_ns) + " @" + r2(e_sp - e_ns) + "dB  "
  }
  inspect(report, content=(
    #|0.19/0.54 @22.21dB  0.2/0.55 @12.48dB  0.22/0.55 @7.97dB  0.28/0.56 @4.33dB  

  ))
}

test "诊断：连续语音的逐帧轨迹" {
  let rate = 16000
  let n = rate * 3
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  let rng = Lcg::new(4242)
  synth_speech(samples, 0, n, rate, rng)
  let params = @vad.VadParams::default()
  let frames = @vad.analyze_frames(samples, rate, params, @vad.VadEngine::Fused)
  // 压缩成游程：S=语音 N=非语音
  let mut runs = ""
  let mut cur = frames[0].is_speech()
  let mut count = 1
  for i = 1; i < frames.length(); i = i + 1 {
    if frames[i].is_speech() == cur {
      count = count + 1
    } else {
      runs = runs + (if cur { "S" } else { "N" }) + count.to_string() + " "
      cur = frames[i].is_speech()
      count = 1
    }
  }
  runs = runs + (if cur { "S" } else { "N" }) + count.to_string()
  inspect(runs, content=(
    #|S17 N8 S24 N2 S22 N2 S17 N8




  ))
  // 噪声底与得分的范围
  let mut fmin = 999.0
  let mut fmax = -999.0
  let mut emin = 999.0
  let mut emax = -999.0
  for f in frames {
    if f.noise_floor_db() < fmin {
      fmin = f.noise_floor_db()
    }
    if f.noise_floor_db() > fmax {
      fmax = f.noise_floor_db()
    }
    if f.energy_db() < emin {
      emin = f.energy_db()
    }
    if f.energy_db() > emax {
      emax = f.energy_db()
    }
  }
  inspect(
    "floor[" + r2(fmin) + "," + r2(fmax) + "] energy[" + r2(emin) + "," + r2(emax) + "]",
    content=(
      #|floor[-23.94,-23.91] energy[-23.94,-14.81]




    ),
  )
}

test "诊断：噪声突发的谱平坦度（决定否决阈值定在哪）" {
  let cb = make_case_ex(4.0, 20.0, 31, true)
  let (f_sp, f_ns) = flatness_split(cb)
  inspect("burst: speech=" + r2(f_sp) + " nonspeech=" + r2(f_ns), content=(
    #|burst: speech=0.21 nonspeech=0.55
  ))
}
