///|
/// moonvoice/audio — 音频容器与样本表示
///
/// 设计决策（汇总见 docs/retrospective.md「关键架构决策」）：
/// - 内部统一用 `Float`(f32) 交错存储、归一化到 [-1, 1]。
///   理由：f32 有 24 位尾数，足以无损承载 32-bit PCM 的动态范围，
///   同时内存只有 f64 的一半——语音段处理量级下这是正确取舍。
/// - 整数样本的读写全程走 `Double` 运算：Double 有 53 位尾数，
///   32-bit 整数在其上精确可表示，避免 Int(32 位) 在 u32→i32 处溢出回绕。
/// - 本包不依赖任何平台 I/O（不引入 miniio），因此 wasm/js/native 三后端都能测试。

///| WAV 存储侧的采样格式
pub(all) enum SampleFormat {
  U8 // 8-bit 无符号 PCM（WAV 规范如此）
  I16 // 16-bit 小端有符号 PCM
  I24 // 24-bit 小端有符号 PCM
  I32 // 32-bit 小端有符号 PCM
  F32 // 32-bit IEEE 浮点
  F64 // 64-bit IEEE 浮点
} derive(Eq)

pub extend SampleFormat with Eq::{equal, not_equal}

pub impl Show for SampleFormat with fn output(self, logger) {
  match self {
    U8 => logger <+ "u8"
    I16 => logger <+ "i16"
    I24 => logger <+ "i24"
    I32 => logger <+ "i32"
    F32 => logger <+ "f32"
    F64 => logger <+ "f64"
  }
}

pub extend SampleFormat with Show::{to_string, output}

///| 解析/编码错误。MoonBit 的 checked error：调用方必须显式处理，不会静默漏抛。
pub(all) suberror AudioError {
  NotRiff
  Truncated(String)
  InvalidFormat(String)
  UnsupportedFormat(String)
}

pub impl Show for AudioError with fn output(self, logger) {
  match self {
    NotRiff => logger.write_string("not a RIFF/WAVE stream")
    Truncated(what) => logger.write_string("truncated: " + what)
    InvalidFormat(what) => logger.write_string("invalid format: " + what)
    UnsupportedFormat(what) => logger.write_string("unsupported format: " + what)
  }
}

pub extend AudioError with Show::{to_string, output}

///|
/// 音频数据：交错存储、归一化到 [-1, 1] 的 f32 样本。
///
/// 不变式：`channels > 0`、`sample_rate > 0`、`samples.length() % channels == 0`。
pub struct Audio {
  sample_rate : Int
  channels : Int
  samples : FixedArray[Float]
  extra_chunks : Array[(String, Bytes)]
  /// 解码来源的采样格式。带上它，`encode_wav` 就能默认做"保格式往返"——
  /// 24-bit 素材重采样后不会无声降级成 16-bit。手工构造的 Audio 为 None。
  source_format : SampleFormat?
}

///| 构造。调用方须保证不变式（解码器会校验后才会构造）。
pub fn Audio::new(
  sample_rate : Int,
  channels : Int,
  samples : FixedArray[Float],
) -> Audio {
  { sample_rate, channels, samples, extra_chunks: [], source_format: None }
}

pub fn Audio::sample_rate(self : Audio) -> Int {
  self.sample_rate
}

pub fn Audio::channels(self : Audio) -> Int {
  self.channels
}

///| 帧数（每声道样本数）
pub fn Audio::frames(self : Audio) -> Int {
  self.samples.length() / self.channels
}

///| 交错样本数组（零拷贝共享）
pub fn Audio::samples(self : Audio) -> FixedArray[Float] {
  self.samples
}

///| 解码来源的采样格式（手工构造的 Audio 为 None）
pub fn Audio::source_format(self : Audio) -> SampleFormat? {
  self.source_format
}

///| 未识别的 RIFF 块（原样保留，写出时回写）
pub fn Audio::extra_chunks(self : Audio) -> Array[(String, Bytes)] {
  self.extra_chunks
}

pub fn Audio::duration_ms(self : Audio) -> Double {
  self.frames().to_double() * 1000.0 / self.sample_rate.to_double()
}

///| 取指定帧、指定声道的样本
pub fn Audio::sample_at(self : Audio, frame : Int, ch : Int) -> Float {
  self.samples[frame * self.channels + ch]
}

///|
/// 原样保真复制（用于写出时携带 extra_chunks）。
pub fn Audio::with_extra_chunks(
  self : Audio,
  extra_chunks : Array[(String, Bytes)],
) -> Audio {
  {
    sample_rate: self.sample_rate,
    channels: self.channels,
    samples: self.samples,
    extra_chunks,
    source_format: self.source_format,
  }
}

///| 带上（可选的）来源格式：多声道→单声道这类重建场景用，避免丢掉格式标记
pub fn Audio::with_source_format_opt(
  self : Audio,
  format : SampleFormat?,
) -> Audio {
  {
    sample_rate: self.sample_rate,
    channels: self.channels,
    samples: self.samples,
    extra_chunks: self.extra_chunks,
    source_format: format,
  }
}

///| 带上来源格式（解码器与重采样用；普通调用者一般不需要）
pub fn Audio::with_source_format(self : Audio, format : SampleFormat) -> Audio {
  {
    sample_rate: self.sample_rate,
    channels: self.channels,
    samples: self.samples,
    extra_chunks: self.extra_chunks,
    source_format: Some(format),
  }
}

// ---------------------------------------------------------------------------
// 样本 ↔ 浮点 转换
// ---------------------------------------------------------------------------

///| 四舍五入（远离零方向），不依赖标准库，可单独测试
pub fn round_half_away(x : Double) -> Int {
  if x >= 0.0 {
    (x + 0.5).to_int()
  } else {
    -((-x + 0.5).to_int())
  }
}

fn clamp_int(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///| 把整数样本值（已按满量程标定）转成 [-1, 1] 浮点
pub fn int_to_float(value : Double, scale : Double) -> Float {
  Float::from_double(value / scale)
}

///| 把 [-1, 1] 浮点转成整数样本值（比例 scale，上限 hi，下限 lo）
pub fn float_to_int(x : Float, scale : Double, lo : Int, hi : Int) -> Int {
  clamp_int(round_half_away(x.to_double() * scale), lo, hi)
}

// ---------------------------------------------------------------------------
// 小端读取（全部用 Double 累加，规避 Int 32 位溢出）
// ---------------------------------------------------------------------------

///| 读无符号 8 位
fn u8_at(b : Bytes, off : Int) -> Double {
  b[off].to_double()
}

///| 读无符号 16 位小端
fn u16_at(b : Bytes, off : Int) -> Double {
  b[off].to_double() + b[off + 1].to_double() * 256.0
}

///| 读无符号 24 位小端
fn u24_at(b : Bytes, off : Int) -> Double {
  b[off].to_double() +
  b[off + 1].to_double() * 256.0 +
  b[off + 2].to_double() * 65536.0
}

///| 读无符号 32 位小端
fn u32_at(b : Bytes, off : Int) -> Double {
  b[off].to_double() +
  b[off + 1].to_double() * 256.0 +
  b[off + 2].to_double() * 65536.0 +
  b[off + 3].to_double() * 16777216.0
}

///| 读无符号 32 位小端（整数形式，供按位重组使用）
fn u32_uint_at(b : Bytes, off : Int) -> UInt {
  b[off].to_uint() |
  (b[off + 1].to_uint() << 8) |
  (b[off + 2].to_uint() << 16) |
  (b[off + 3].to_uint() << 24)
}

///| 读 32 位小端 IEEE 浮点（按位重组，纯 MoonBit，无 FFI）
fn f32_at(b : Bytes, off : Int) -> Double {
  Float::reinterpret_from_uint(u32_uint_at(b, off)).to_double()
}

///| 读 64 位小端 IEEE 浮点
fn f64_at(b : Bytes, off : Int) -> Double {
  let lo = u32_uint_at(b, off).to_uint64()
  let hi = u32_uint_at(b, off + 4).to_uint64()
  UInt64::reinterpret_as_double((hi << 32) | lo)
}

// ---------------------------------------------------------------------------
// WAV 存储格式 ↔ 归一化浮点
// ---------------------------------------------------------------------------

///| 8-bit PCM 是**无符号**存储，128 为零点
pub fn decode_u8(byte : Double) -> Float {
  Float::from_double((byte - 128.0) / 128.0)
}

pub fn decode_i16(u : Double) -> Float {
  let s = if u >= 32768.0 { u - 65536.0 } else { u }
  int_to_float(s, 32768.0)
}

pub fn decode_i24(u : Double) -> Float {
  let s = if u >= 8388608.0 { u - 16777216.0 } else { u }
  int_to_float(s, 8388608.0)
}

pub fn decode_i32(u : Double) -> Float {
  let s = if u >= 2147483648.0 { u - 4294967296.0 } else { u }
  int_to_float(s, 2147483648.0)
}

pub fn encode_u8(x : Float) -> Int {
  float_to_int(x, 128.0, 0, 255)
}

pub fn encode_i16(x : Float) -> Int {
  float_to_int(x, 32768.0, -32768, 32767)
}

pub fn encode_i24(x : Float) -> Int {
  float_to_int(x, 8388608.0, -8388608, 8388607)
}

pub fn encode_i32(x : Float) -> Int {
  // 上限用 2147483647（Int 可表示），比例取 2147483648
  float_to_int(x, 2147483648.0, -2147483648, 2147483647)
}

///|
/// 混成单声道（多声道取平均）。放在 audio 包而不是 vad 包：
/// 这是音频数据操作，与"是否做语音检测"无关。
pub fn Audio::to_mono(self : Audio) -> FixedArray[Float] {
  let ch = self.channels
  let frames = self.frames()
  let out : FixedArray[Float] = FixedArray::make(frames, 0.0)
  if ch == 1 {
    for i = 0; i < frames; i = i + 1 {
      out[i] = self.samples[i]
    }
    return out
  }
  let scale = 1.0 / ch.to_double()
  for i = 0; i < frames; i = i + 1 {
    let mut acc = 0.0
    for c = 0; c < ch; c = c + 1 {
      acc = acc + self.samples[i * ch + c].to_double()
    }
    out[i] = Float::from_double(acc * scale)
  }
  out
}

// ---------------------------------------------------------------------------
// 可组合原语：切片 / 拼接 / 增益 / 归一化 / 混音
//
// 设计原则：这里只放**与"语音"无关**的音频操作。
// 语音相关的组合（如"只保留语音段"）放在 vad 包，由这些原语拼出来——
// 这样原语可以脱离语音场景复用（音频编辑、数据集制作、播放器……）。
// ---------------------------------------------------------------------------

///| 按帧切片（左闭右开，自动夹到合法范围）
pub fn Audio::slice_frames(self : Audio, start : Int, end : Int) -> Audio {
  let frames = self.frames()
  let s = if start < 0 {
    0
  } else if start > frames {
    frames
  } else {
    start
  }
  let e = if end < s {
    s
  } else if end > frames {
    frames
  } else {
    end
  }
  let n = (e - s) * self.channels
  let out : FixedArray[Float] = FixedArray::make(n, 0.0)
  let base = s * self.channels
  for i = 0; i < n; i = i + 1 {
    out[i] = self.samples[base + i]
  }
  {
    sample_rate: self.sample_rate,
    channels: self.channels,
    samples: out,
    extra_chunks: [],
    source_format: self.source_format,
  }
}

///| 按毫秒切片
pub fn Audio::slice_ms(self : Audio, start_ms : Int, end_ms : Int) -> Audio {
  let to_frame = fn(ms : Int) -> Int {
    ms * self.sample_rate / 1000
  }
  self.slice_frames(to_frame(start_ms), to_frame(end_ms))
}

///|
/// 顺序拼接。要求采样率与声道数一致——不一致时**报错而不是偷偷重采样**：
/// 隐式转换会让调用者不知道自己的数据被改过。
pub fn Audio::concat(parts : Array[Audio]) -> Audio raise AudioError {
  if parts.length() == 0 {
    raise InvalidFormat("concat: 空的片段列表")
  }
  let first = parts[0]
  let rate = first.sample_rate
  let ch = first.channels
  let mut total = 0
  for p in parts {
    if p.sample_rate != rate || p.channels != ch {
      raise InvalidFormat(
        "concat: 采样率/声道不一致（" +
        rate.to_string() +
        "Hz/" +
        ch.to_string() +
        "ch vs " +
        p.sample_rate.to_string() +
        "Hz/" +
        p.channels.to_string() +
        "ch）",
      )
    }
    total = total + p.samples.length()
  }
  let out : FixedArray[Float] = FixedArray::make(total, 0.0)
  let mut pos = 0
  for p in parts {
    for i = 0; i < p.samples.length(); i = i + 1 {
      out[pos + i] = p.samples[i]
    }
    pos = pos + p.samples.length()
  }
  {
    sample_rate: rate,
    channels: ch,
    samples: out,
    extra_chunks: [],
    source_format: first.source_format,
  }
}

///| 施加增益（dB）。可选钳位到 [-1, 1]（默认不钳位，避免无声损失峰值）
pub fn Audio::apply_gain_db(self : Audio, db : Double, clamp? : Bool = false) -> Audio {
  let g = @math.pow(10.0, db / 20.0)
  let n = self.samples.length()
  let out : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let v = self.samples[i].to_double() * g
    out[i] = Float::from_double(
      if clamp {
        if v > 1.0 {
          1.0
        } else if v < -1.0 {
          -1.0
        } else {
          v
        }
      } else {
        v
      },
    )
  }
  {
    sample_rate: self.sample_rate,
    channels: self.channels,
    samples: out,
    extra_chunks: self.extra_chunks,
    source_format: self.source_format,
  }
}

///| 峰值（绝对值最大）
pub fn Audio::peak(self : Audio) -> Double {
  let mut peak = 0.0
  for i = 0; i < self.samples.length(); i = i + 1 {
    let a = if self.samples[i].to_double() < 0.0 {
      -self.samples[i].to_double()
    } else {
      self.samples[i].to_double()
    }
    if a > peak {
      peak = a
    }
  }
  peak
}

///|
/// 峰值归一化到 `target`（默认 0.98，留一点余量给编码与后续滤波）。
/// 典型用法：拼接/混音之后、编码之前调一次，避免削波。
pub fn Audio::normalize_peak(self : Audio, target? : Double = 0.98) -> Audio {
  let p = self.peak()
  if p <= 0.0 {
    return self
  }
  self.apply_gain_db(20.0 * @math.log10(target / p))
}

///|
/// 两路等长混音（`ratio` 是 b 的比例，默认 0.5）。
/// 不做自动增益补偿——要什么比例由调用者决定，混完可以用 normalize_peak。
pub fn Audio::mix(a : Audio, b : Audio, ratio? : Double = 0.5) -> Audio raise AudioError {
  if a.sample_rate != b.sample_rate || a.channels != b.channels {
    raise InvalidFormat("mix: 采样率/声道不一致")
  }
  if a.samples.length() != b.samples.length() {
    raise InvalidFormat("mix: 长度不一致")
  }
  let n = a.samples.length()
  let out : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = Float::from_double(
      a.samples[i].to_double() * (1.0 - ratio) + b.samples[i].to_double() * ratio,
    )
  }
  {
    sample_rate: a.sample_rate,
    channels: a.channels,
    samples: out,
    extra_chunks: [],
    source_format: a.source_format,
  }
}
