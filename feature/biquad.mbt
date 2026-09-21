///|
/// moonvoice/feature — 双二阶（biquad）IIR 滤波器
///
/// 双二阶是数字滤波的"通用零件"：任意二阶（两个极点两个零点）传递函数，
/// 串几级就能拼出均衡器、分频器、加权滤波器。这里用 RBJ Audio EQ Cookbook
/// 的标准设计公式——它是业界事实标准，系数与 scipy.signal 对得上。
///
/// 实现用**转置直接 II 型**（DF2T）：只需要两个状态量、数值性质最好，
/// 是实时音频里的默认选择。

///|
/// 二阶传递函数 H(z) = (b0 + b1 z⁻¹ + b2 z⁻²) / (1 + a1 z⁻¹ + a2 z⁻²)
/// 注意 a0 已归一化到 1（设计公式算出后统一除）。
pub struct Biquad {
  b0 : Double
  b1 : Double
  b2 : Double
  a1 : Double
  a2 : Double
  // 转置直接 II 型的两个状态量（可变：滤波就是逐样本更新它们）
  mut z1 : Double
  mut z2 : Double
}

///| 滤波器的幅频响应类型
pub(all) enum FilterKind {
  Lowpass(Double) // 参数：Q
  Highpass(Double)
  Bandpass(Double)
  Peak(Double, Double) // (Q, 增益 dB)
  LowShelf(Double, Double) // (Q, 增益 dB)
  HighShelf(Double, Double)
}

///|
/// 按 RBJ Cookbook 设计双二阶系数。
/// `fc` 是截止/中心频率（Hz），`sample_rate` 是采样率。
fn design(kind : FilterKind, fc : Double, sample_rate : Int) -> (Double, Double, Double, Double, Double) {
  let w0 = 2.0 * @math.PI * fc / sample_rate.to_double()
  let cw = @math.cos(w0)
  let sw = @math.sin(w0)
  match kind {
    Lowpass(q) => {
      let alpha = sw / (2.0 * q)
      let b1 = 1.0 - cw
      let a0 = 1.0 + alpha
      (
        b1 / 2.0 / a0,
        b1 / a0,
        b1 / 2.0 / a0,
        -2.0 * cw / a0,
        (1.0 - alpha) / a0,
      )
    }
    Highpass(q) => {
      let alpha = sw / (2.0 * q)
      let a0 = 1.0 + alpha
      (
        (1.0 + cw) / 2.0 / a0,
        -(1.0 + cw) / a0,
        (1.0 + cw) / 2.0 / a0,
        -2.0 * cw / a0,
        (1.0 - alpha) / a0,
      )
    }
    Bandpass(q) => {
      // 常数峰值增益形式（中心频率处增益为 1）
      let alpha = sw / (2.0 * q)
      let a0 = 1.0 + alpha
      (alpha / a0, 0.0, -alpha / a0, -2.0 * cw / a0, (1.0 - alpha) / a0)
    }
    Peak(q, gain_db) => {
      let a = @math.pow(10.0, gain_db / 40.0)
      let alpha = sw / (2.0 * q)
      let a0 = 1.0 + alpha / a
      (
        (1.0 + alpha * a) / a0,
        -2.0 * cw / a0,
        (1.0 - alpha * a) / a0,
        -2.0 * cw / a0,
        (1.0 - alpha / a) / a0,
      )
    }
    LowShelf(q, gain_db) => {
      let a = @math.pow(10.0, gain_db / 40.0)
      let alpha = sw / 2.0 * ((a + 1.0 / a) * (1.0 / q - 1.0) + 2.0).sqrt()
      let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha
      let a0 = (a + 1.0) + (a - 1.0) * cw + two_sqrt_a_alpha
      (
        a * ((a + 1.0) - (a - 1.0) * cw + two_sqrt_a_alpha) / a0,
        2.0 * a * ((a - 1.0) - (a + 1.0) * cw) / a0,
        a * ((a + 1.0) - (a - 1.0) * cw - two_sqrt_a_alpha) / a0,
        -2.0 * ((a - 1.0) + (a + 1.0) * cw) / a0,
        ((a + 1.0) + (a - 1.0) * cw - two_sqrt_a_alpha) / a0,
      )
    }
    HighShelf(q, gain_db) => {
      let a = @math.pow(10.0, gain_db / 40.0)
      let alpha = sw / 2.0 * ((a + 1.0 / a) * (1.0 / q - 1.0) + 2.0).sqrt()
      let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha
      let a0 = (a + 1.0) - (a - 1.0) * cw + two_sqrt_a_alpha
      (
        a * ((a + 1.0) + (a - 1.0) * cw + two_sqrt_a_alpha) / a0,
        -2.0 * a * ((a - 1.0) + (a + 1.0) * cw) / a0,
        a * ((a + 1.0) + (a - 1.0) * cw - two_sqrt_a_alpha) / a0,
        2.0 * ((a - 1.0) - (a + 1.0) * cw) / a0,
        ((a + 1.0) - (a - 1.0) * cw - two_sqrt_a_alpha) / a0,
      )
    }
  }
}

pub fn Biquad::new(kind : FilterKind, fc : Double, sample_rate : Int) -> Biquad {
  let (b0, b1, b2, a1, a2) = design(kind, fc, sample_rate)
  { b0, b1, b2, a1, a2, z1: 0.0, z2: 0.0 }
}

///| 直接给系数构造（做加权滤波器等需要按标准给定系数时用）
pub fn Biquad::from_coeffs(
  b0 : Double,
  b1 : Double,
  b2 : Double,
  a1 : Double,
  a2 : Double,
) -> Biquad {
  { b0, b1, b2, a1, a2, z1: 0.0, z2: 0.0 }
}

pub fn Biquad::b0(self : Biquad) -> Double {
  self.b0
}

pub fn Biquad::b1(self : Biquad) -> Double {
  self.b1
}

pub fn Biquad::b2(self : Biquad) -> Double {
  self.b2
}

pub fn Biquad::a1(self : Biquad) -> Double {
  self.a1
}

pub fn Biquad::a2(self : Biquad) -> Double {
  self.a2
}

///| 清空状态（换信号时要清，否则上一段的尾巴会漏进来）
pub fn Biquad::reset(self : Biquad) -> Unit {
  self.z1 = 0.0
  self.z2 = 0.0
}

///| 单样本处理（转置直接 II 型）
pub fn Biquad::process_sample(self : Biquad, x : Double) -> Double {
  let y = self.b0 * x + self.z1
  self.z1 = self.b1 * x - self.a1 * y + self.z2
  self.z2 = self.b2 * x - self.a2 * y
  y
}

///| 就地处理整段信号
pub fn Biquad::process(self : Biquad, x : FixedArray[Float]) -> FixedArray[Float] {
  let out : FixedArray[Float] = FixedArray::make(x.length(), 0.0)
  for i = 0; i < x.length(); i = i + 1 {
    out[i] = Float::from_double(self.process_sample(x[i].to_double()))
  }
  out
}

///|
/// 该双二阶在频率 f 处的幅度响应（dB）。
/// 判断"这个滤波器到底做了什么"的直读手段，也用于测试与设计核对。
pub fn Biquad::magnitude_db_at(self : Biquad, f : Double, sample_rate : Int) -> Double {
  let w = 2.0 * @math.PI * f / sample_rate.to_double()
  let cw = @math.cos(w)
  let sw = @math.sin(w)
  let c2 = @math.cos(2.0 * w)
  let s2 = @math.sin(2.0 * w)
  // 分子 |b0 + b1 e^-jw + b2 e^-j2w|
  let nr = self.b0 + self.b1 * cw + self.b2 * c2
  let ni = -(self.b1 * sw + self.b2 * s2)
  // 分母 |1 + a1 e^-jw + a2 e^-j2w|
  let dr = 1.0 + self.a1 * cw + self.a2 * c2
  let di = -(self.a1 * sw + self.a2 * s2)
  let num = (nr * nr + ni * ni).sqrt()
  let den = (dr * dr + di * di).sqrt()
  if den <= 0.0 {
    -300.0
  } else {
    20.0 * @math.log10(num / den)
  }
}
