///|
/// 频谱金标对拍：被测实现 vs numpy.fft.rfft。
///
/// 比较方式：功率谱的动态范围可以从 1e+6 跨到 1e-6，用逐点相对误差会在
/// 接近零的 bin 上炸掉，所以用"相对最大值的绝对误差"作判据。
///
/// 容差 1e-6 是怎么定出来的（不是拍的）：把同一算法在 numpy 里重写一遍，
/// 与 numpy.fft 的相对误差只有 3.4e-16 —— 说明 FFT 本身没问题。
/// 端到端偏差的真正来源是**输入样本以 f32 存储**（我们的设计取舍）：
/// 每个样本 ~6e-8 的相对量化误差进入频谱后随机抵消，量级落在 1e-9~1e-8。
/// 所以这里卡 1e-6 是"给 f32 输入留够余量，同时仍能抓出真正的算法错误"。

fn fft_input_floats() -> FixedArray[Float] {
  let ints = golden_fft_input()
  let x : FixedArray[Float] = FixedArray::make(ints.length(), 0.0)
  for i = 0; i < ints.length(); i = i + 1 {
    x[i] = Float::from_double(ints[i].to_double() / 10000.0)
  }
  x
}

test "golden: 功率谱与 numpy.fft.rfft 一致" {
  let x = fft_input_floats()
  let spec = @feature.power_spectrum(x, 512)
  let expected = golden_fft_expected_power()
  if spec.length() != expected.length() {
    fail(
      "谱长度 " + spec.length().to_string() + " != " + expected.length().to_string(),
    )
  }
  let mut max_power = 0.0
  for i = 0; i < expected.length(); i = i + 1 {
    if expected[i] > max_power {
      max_power = expected[i]
    }
  }
  let mut worst = 0.0
  let mut worst_at = 0
  for i = 0; i < expected.length(); i = i + 1 {
    let d = (spec[i] - expected[i]).abs()
    if d > worst {
      worst = d
      worst_at = i
    }
  }
  let tol = max_power * 1.0e-6
  if worst > tol {
    fail(
      "第 " +
      worst_at.to_string() +
      " 个 bin 偏差 " +
      worst.to_string() +
      "（最大功率 " +
      max_power.to_string() +
      "，容差 " +
      tol.to_string() +
      "）",
    )
  }
}

test "golden: 谱平坦度与 numpy 复算一致" {
  let spec = @feature.power_spectrum(fft_input_floats(), 512)
  let got = @feature.spectral_flatness(spec, 1, 101)
  let want = golden_fft_expect_flatness()
  if (got - want).abs() > 1.0e-9 {
    fail("谱平坦度 " + got.to_string() + " != " + want.to_string())
  }
}

test "golden: 谱熵与 numpy 复算一致" {
  let spec = @feature.power_spectrum(fft_input_floats(), 512)
  let got = @feature.spectral_entropy(spec, 1, 101)
  let want = golden_fft_expect_entropy()
  if (got - want).abs() > 1.0e-9 {
    fail("谱熵 " + got.to_string() + " != " + want.to_string())
  }
}
