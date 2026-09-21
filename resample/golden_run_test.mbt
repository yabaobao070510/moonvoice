///|
/// 重采样金标对拍：被测实现 vs scipy.signal.resample_poly。
///
/// 比的是**通带保真**：输入多音信号的能量全在输出 Nyquist 的 0.45 倍以内，
/// 两个实现都不该动它。过渡带形状是各自的设计自由，拿来对拍没有意义。
///
/// 对齐检查：如果主对拍失败，会额外报告"最佳平移量下的 SNR"，
/// 用来区分"滤波器设计差异"与"时间轴没对齐"这两类完全不同的根因。

fn input_to_float(ints : Array[Int]) -> FixedArray[Float] {
  let n = ints.length()
  let x : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    x[i] = Float::from_double(ints[i].to_double() / 32768.0)
  }
  x
}

///| 以 shift 平移后计算 SNR（用于诊断对齐）
fn snr_with_shift(
  expected : Array[Double],
  got : FixedArray[Float],
  shift : Int,
  skip : Int,
) -> Double {
  let mut sig = 0.0
  let mut err = 0.0
  let from = skip
  let to = expected.length() - skip
  for i = from; i < to; i = i + 1 {
    let j = i + shift
    if j >= 0 && j < got.length() {
      let e = expected[i]
      let d = e - got[j].to_double()
      sig = sig + e * e
      err = err + d * d
    }
  }
  if err <= 0.0 {
    999.0
  } else {
    10.0 * @math.log10(sig / err)
  }
}

fn fmt1(x : Double) -> String {
  let rounded = (x * 10.0 + 0.5).to_int().to_double() / 10.0
  rounded.to_string()
}

fn check_resample_golden(
  name : String,
  ints : Array[Int],
  expected : Array[Double],
  rates : (Int, Int),
  min_snr : Double,
) -> Unit raise {
  let (fs_in, fs_out) = rates
  let r = @resample.Resampler::new(fs_in, fs_out)
  let x = input_to_float(ints)
  let y = r.process(x, x.length(), 1)
  if y.length() != expected.length() {
    fail(
      name +
      ": 输出长度 " +
      y.length().to_string() +
      " != scipy 的 " +
      expected.length().to_string(),
    )
  }
  let skip = 100
  let snr = snr_with_shift(expected, y, 0, skip)
  if snr < min_snr {
    // 诊断：是滤波器差异还是没对齐？
    let mut best = snr
    let mut best_shift = 0
    for s = -4; s <= 4; s = s + 1 {
      let v = snr_with_shift(expected, y, s, skip)
      if v > best {
        best = v
        best_shift = s
      }
    }
    fail(
      name +
      ": 与 scipy 的 SNR 仅 " + fmt1(snr) + " dB（阈值 " + fmt1(min_snr) +
      "）；最佳平移 " + best_shift.to_string() + " 时 SNR = " + fmt1(best) + " dB",
    )
  }
}

test "golden: 48k→16k 通带保真对齐 scipy（SNR ≥ 60 dB）" {
  check_resample_golden(
    "48k→16k",
    golden_resample_48k_to_16k_input(),
    golden_resample_48k_to_16k_expected(),
    golden_resample_48k_to_16k_rates(),
    60.0,
  )
}

test "golden: 44.1k→48k 通带保真对齐 scipy（SNR ≥ 60 dB）" {
  check_resample_golden(
    "44.1k→48k",
    golden_resample_44100_to_48000_input(),
    golden_resample_44100_to_48000_expected(),
    golden_resample_44100_to_48000_rates(),
    60.0,
  )
}
