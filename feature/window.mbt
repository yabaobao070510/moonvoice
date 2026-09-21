///|
/// moonvoice/feature — 窗函数
///
/// 窗函数是短时分析的基本材料：FFT 之前必须加窗，否则帧边界的不连续会
/// 在频谱上产生泄漏，把弱信号淹掉。
///
/// 各窗的取舍（旁瓣高度 vs 主瓣宽度）：
/// - `Rectangular`：无窗，主瓣最窄、旁瓣最高（-13 dB）——只在你确实要原始值时用
/// - `Hann`：通用默认，旁瓣 -31 dB，主瓣适中
/// - `Hamming`：主瓣与 Hann 相近，第一旁瓣更低（-43 dB）但远端衰减慢
/// - `Blackman`：旁瓣 -58 dB，主瓣更宽——弱分量检测用
/// - `Bartlett`：三角窗，介于矩形与 Hann 之间
/// - `Kaiser(beta)`：可通过 beta 连续调节主瓣/旁瓣权衡（滤波器设计常用）

///| 窗函数类型
pub(all) enum Window {
  Rectangular
  Hann
  Hamming
  Blackman
  Bartlett
  Kaiser(Double)
}

///| 窗函数名（用于 JSON/日志）
pub fn Window::name(self : Window) -> String {
  match self {
    Rectangular => "rectangular"
    Hann => "hann"
    Hamming => "hamming"
    Blackman => "blackman"
    Bartlett => "bartlett"
    Kaiser(_) => "kaiser"
  }
}

///| 生成窗系数（长度 n）
pub fn window_coefficients(kind : Window, n : Int) -> FixedArray[Double] {
  let out : FixedArray[Double] = FixedArray::make(n, 1.0)
  if n <= 1 {
    return out
  }
  let denom = (n - 1).to_double()
  match kind {
    Rectangular => ()
    Hann => {
      for i = 0; i < n; i = i + 1 {
        out[i] = 0.5 * (1.0 - @math.cos(2.0 * @math.PI * i.to_double() / denom))
      }
    }
    Hamming => {
      for i = 0; i < n; i = i + 1 {
        out[i] = 0.54 - 0.46 * @math.cos(2.0 * @math.PI * i.to_double() / denom)
      }
    }
    Blackman => {
      for i = 0; i < n; i = i + 1 {
        let x = 2.0 * @math.PI * i.to_double() / denom
        out[i] = 0.42 - 0.5 * @math.cos(x) + 0.08 * @math.cos(2.0 * x)
      }
    }
    Bartlett => {
      for i = 0; i < n; i = i + 1 {
        let half = denom / 2.0
        let x = i.to_double()
        out[i] = 1.0 - ((x - half) / half).abs()
      }
    }
    Kaiser(beta) => {
      let denom_i0 = bessel_i0(beta)
      for i = 0; i < n; i = i + 1 {
        let u = 2.0 * i.to_double() / denom - 1.0
        out[i] = bessel_i0(beta * (1.0 - u * u).sqrt()) / denom_i0
      }
    }
  }
  out
}

///| 第 0 类修正贝塞尔函数（Kaiser 窗与滤波器设计共用）
pub fn bessel_i0(x : Double) -> Double {
  let half = x / 2.0
  let mut term = 1.0
  let mut sum = 1.0
  for k = 1; k < 40; k = k + 1 {
    term = term * (half / k.to_double()) * (half / k.to_double())
    sum = sum + term
    if term < 1.0e-18 * sum {
      break
    }
  }
  sum
}

///| 窗的相干增益（Σw / n）：做幅度谱标定时要用
pub fn window_coherent_gain(kind : Window, n : Int) -> Double {
  let w = window_coefficients(kind, n)
  let mut sum = 0.0
  for x in w {
    sum = sum + x
  }
  sum / n.to_double()
}
