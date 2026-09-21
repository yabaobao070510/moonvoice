///|
/// VAD 合成基准：**真值由构造决定**，与实现无关。
///
/// 为什么不用另一个 VAD 当参照：
/// 现成 VAD（webrtcvad 等）本身就是带调参和偏好的黑盒，拿它当"标准答案"
/// 等于把它的偏好当成真理。而"我在第 1.0~2.0 秒放了语音"这件事是构造事实，
/// 谁也改不了——用它算指标，测的是实现，不是立场。
///
/// 信号构成：
/// - 语音：F0=120 Hz 的谐波堆 + 共振峰包络 + 4 Hz 音节调幅，另加少量摩擦噪声
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

///| 合成用例
struct BenchCase {
  samples : FixedArray[Float]
  truth : Array[TruthSpan]
  sample_rate : Int
}

///|
/// 帧级指标。主指标是精确率/召回率：
/// 漏检让识别器丢字、误检只是多送静音，两类错误代价不同，准确率会把它们平均掉。
struct BenchMetrics {
  precision : Double
  recall : Double
  accuracy : Double
}

///|
/// 生成语音样样本。
/// 用**增量旋转**代替逐样本 sin：每个谐波维护一个单位复数并逐步旋转，
/// 每样本只有 4 次乘法而没有三角函数——否则几秒 × 12 谐波的基准跑不动。
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
  let step_r : FixedArray[Double] = FixedArray::make(n_harm + 1, 1.0)
  let step_i : FixedArray[Double] = FixedArray::make(n_harm + 1, 0.0)
  for k = 1; k <= n_harm; k = k + 1 {
    let theta = 2.0 * @math.PI * f0 * k.to_double() / rate.to_double()
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
      let nr = cr[k] * step_r[k] - ci[k] * step_i[k]
      ci[k] = cr[k] * step_i[k] + ci[k] * step_r[k]
      cr[k] = nr
    }
    let formant = 0.6 +
      0.25 * @math.sin(2.0 * @math.PI * 1.3 * t) +
      0.15 * @math.sin(2.0 * @math.PI * 3.1 * t + 1.0)
    let syllable = 0.55 + 0.45 * @math.sin(2.0 * @math.PI * 4.0 * t)
    // 包络下限：真实连续语音的音节起伏约 15~20 dB，
    // 两个调制直接相乘会到 -34 dB——那是"没人这么说话"的假信号。
    let mut env = formant * syllable
    if env < 0.25 {
      env = 0.25
    }
    let fric = 0.08 * rng.next()
    out[from + i] = Float::from_double((v * env * 0.22) + fric)
  }
}

fn make_case(seconds : Double, snr_db : Double, seed : Int) -> BenchCase {
  make_case_ex(seconds, snr_db, seed, false)
}

///| bursts=true 时在静音区间注入强白噪声突发：能量法会误判、谱法应否决
fn make_case_ex(seconds : Double, snr_db : Double, seed : Int, bursts : Bool) -> BenchCase {
  let rate = 16000
  let total = (seconds * rate.to_double()).to_int()
  let samples : FixedArray[Float] = FixedArray::make(total, 0.0)
  let rng = Lcg::new(seed)
  let truth : Array[TruthSpan] = []
  let mut pos_ms = 500
  let total_ms = (seconds * 1000.0).to_int()
  let mut k = 0
  while pos_ms < total_ms - 400 {
    let dur_ms = 800 + (k % 3) * 200
    let silence_ms = 400 + (k % 2) * 300
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
    samples[i] = Float::from_double(samples[i].to_double() + noise_rms * rng.next())
  }
  if bursts {
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

fn in_truth(truth : Array[TruthSpan], t_ms : Int) -> Bool {
  for s in truth {
    if t_ms >= s.start_ms && t_ms < s.end_ms {
      return true
    }
  }
  false
}

///|
/// 帧级评估。边界容差（collar）= 90 ms，理由两条、都可核对：
/// ① 跨越边界的帧能量一半来自语音，判成哪边都不算错；
/// ② 更主要的一条：hangover=90 ms 是**设计上**要在语音结束后保持的量（不切断尾音），
///    把这些帧算成误检，等于用指标否定设计意图。容差宽度 = 设计引入的时间平滑宽度。
fn evaluate(frames : Array[@vad.FrameDecision], truth : Array[TruthSpan]) -> BenchMetrics {
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
  let total = tp + fp + tn + fn_
  {
    precision: if tp + fp == 0 { 0.0 } else { tp.to_double() / (tp + fp).to_double() },
    recall: if tp + fn_ == 0 { 0.0 } else { tp.to_double() / (tp + fn_).to_double() },
    accuracy: if total == 0 { 0.0 } else { (tp + tn).to_double() / total.to_double() },
  }
}

fn run_case(
  c : BenchCase,
  engine : @vad.VadEngine,
  params : @vad.VadParams,
) -> BenchMetrics {
  evaluate(@vad.analyze_frames(c.samples, c.sample_rate, params, engine), c.truth)
}

fn pct(x : Double) -> String {
  let v = (x * 1000.0 + 0.5).to_int().to_double() / 10.0
  v.to_string()
}

fn r2(x : Double) -> String {
  let v = (x * 100.0 + 0.5).to_int().to_double() / 100.0
  v.to_string()
}

fn fmt3(x : Double) -> String {
  let v = (x * 1000.0 + 0.5).to_int().to_double() / 1000.0
  v.to_string()
}

// ---------------------------------------------------------------------------
// 场景测试
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

test "基准：SNR 20 dB 下精确率与召回率" {
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

test "基准：噪声突发下融合必须优于纯能量（谱特征的价值所在）" {
  let c = make_case_ex(4.0, 20.0, 41, true)
  let params = @vad.VadParams::default()
  let e = run_case(c, @vad.VadEngine::Energy, params)
  let sp = run_case(c, @vad.VadEngine::Spectral, params)
  let fu = run_case(c, @vad.VadEngine::Fused, params)
  inspect(
    "energy=" + fmt3(e.accuracy) + " spectral=" + fmt3(sp.accuracy) +
    " fused=" + fmt3(fu.accuracy),
    content=(
      #|energy=0.874 spectral=0.379 fused=0.951
    ),
  )
  if fu.accuracy <= e.accuracy {
    fail(
      "突发噪声下融合(" + pct(fu.accuracy) + "%) 未优于纯能量(" + pct(e.accuracy) + "%)",
    )
  }
}

// ---------------------------------------------------------------------------
// 调参：网格搜索。特征只算一次（噪声底与门限无关），所以上百组合能在秒级跑完。
// 三个方法学要点：
//   1. 目标取**最差场景**而非平均——VAD 关心的是最差条件下别崩；
//   2. 每种场景**多个种子**——单种子调参等于把参数过拟合到那一次随机抽样
//      （曾经出现过：调参说 0.917，换个种子实测只有 0.789）；
//   3. 网格要小到能在测试里跑完，否则就成了"手工跑一次"的伪调参。
// ---------------------------------------------------------------------------

test "调参：门限/平滑/hangover/否决联合搜索（最差场景目标）" {
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
  let mut best_desc = ""
  for thr in [2.0, 4.0, 6.0, 8.0] {
    for smooth in [1, 3, 5] {
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
            best_desc = "thr=" + thr.to_string() + " smooth=" + smooth.to_string() +
              " hang=" + hang.to_string() + " veto=" + veto.to_string()
          }
        }
      }
    }
  }
  inspect(fmt3(best_worst) + "  " + best_desc, content=(
    #|0.987  thr=2 smooth=1 hang=60 veto=0.5
  ))
}

// ---------------------------------------------------------------------------
// 诊断：不做判决，只看特征本身的分辨力。
// 调参前必须先回答"特征是分得开，还是根本分不开"——否则调参就是在猜。
// ---------------------------------------------------------------------------

fn sort_doubles(xs : Array[Double]) -> Array[Double] {
  let a = xs.copy()
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

///| (语音帧平均谱平坦度, 非语音帧平均谱平坦度, 两类帧的中位能量差 dB)
fn feature_split(c : BenchCase) -> (Double, Double, Double) {
  let stats = @vad.compute_frame_stats(c.samples, c.sample_rate, 30)
  let mut sp_flat = 0.0
  let mut sp_n = 0
  let mut ns_flat = 0.0
  let mut ns_n = 0
  let sp_e : Array[Double] = []
  let ns_e : Array[Double] = []
  for f = 0; f < stats.n_frames(); f = f + 1 {
    let mid = f * 30 + 15
    if in_truth(c.truth, mid) {
      sp_flat = sp_flat + stats.flatness(f)
      sp_e.push(stats.energy_db(f))
      sp_n = sp_n + 1
    } else {
      ns_flat = ns_flat + stats.flatness(f)
      ns_e.push(stats.energy_db(f))
      ns_n = ns_n + 1
    }
  }
  let sp_sorted = sort_doubles(sp_e)
  let ns_sorted = sort_doubles(ns_e)
  let sp_med = if sp_sorted.length() > 0 {
    sp_sorted[sp_sorted.length() / 2]
  } else {
    -160.0
  }
  let ns_med = if ns_sorted.length() > 0 {
    ns_sorted[ns_sorted.length() / 2]
  } else {
    -160.0
  }
  (
    if sp_n > 0 { sp_flat / sp_n.to_double() } else { 0.0 },
    if ns_n > 0 { ns_flat / ns_n.to_double() } else { 0.0 },
    sp_med - ns_med,
  )
}

test "诊断：特征分辨力（谱平坦度与能量的分布）" {
  let mut report = ""
  for snr in [20.0, 10.0, 5.0, 0.0] {
    let (f_sp, f_ns, d_e) = feature_split(make_case(4.0, snr, 31))
    report = report + "snr" + r2(snr) + ":flat " + r2(f_sp) + "/" + r2(f_ns) +
      " dE=" + r2(d_e) + "dB  "
  }
  let (fb_sp, fb_ns, _) = feature_split(make_case_ex(4.0, 20.0, 31, true))
  report = report + "| burst:flat " + r2(fb_sp) + "/" + r2(fb_ns)
  // 这条快照就是阈值标尺的出处：
  // 单帧周期图下白噪声的 GM/AM 期望是 e^-gamma ≈ 0.56（每 bin 服从指数分布），
  // 实测白噪声 0.54~0.56、语音 0.19~0.28 —— veto_flatness=0.5、max_flatness=0.2 由此而来。
  inspect(report, content=(
    #|snr20:flat 0.19/0.54 dE=22.21dB  snr10:flat 0.2/0.55 dE=12.48dB  snr5:flat 0.22/0.55 dE=7.97dB  snr0:flat 0.28/0.56 dE=4.33dB  | burst:flat 0.21/0.55
  ))
}
