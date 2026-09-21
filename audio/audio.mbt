///|
/// moonvoice/audio — 音频容器与样本表示
///
/// 设计决策（见 proposals/moonbit-hackathon-2026.md 第 3 节）：
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
}

impl Show for SampleFormat with fn output(self, logger) {
  match self {
    U8 => logger <+ "u8"
    I16 => logger <+ "i16"
    I24 => logger <+ "i24"
    I32 => logger <+ "i32"
    F32 => logger <+ "f32"
    F64 => logger <+ "f64"
  }
}

///| 解析/编码错误。MoonBit 的 checked error：调用方必须显式处理，不会静默漏抛。
pub(all) suberror AudioError {
  NotRiff
  Truncated(String)
  InvalidFormat(String)
  UnsupportedFormat(String)
}

impl Show for AudioError with fn output(self, logger) {
  match self {
    NotRiff => logger.write_string("not a RIFF/WAVE stream")
    Truncated(what) => logger.write_string("truncated: " + what)
    InvalidFormat(what) => logger.write_string("invalid format: " + what)
    UnsupportedFormat(what) => logger.write_string("unsupported format: " + what)
  }
}

///|
/// 音频数据：交错存储、归一化到 [-1, 1] 的 f32 样本。
///
/// 不变式：`channels > 0`、`sample_rate > 0`、`samples.length() % channels == 0`。
pub struct Audio {
  sample_rate : Int
  channels : Int
  samples : FixedArray[Float]
  extra_chunks : Array[(String, Bytes)]
}

///| 构造。调用方须保证不变式（解码器会校验后才会构造）。
pub fn Audio::new(
  sample_rate : Int,
  channels : Int,
  samples : FixedArray[Float],
) -> Audio {
  { sample_rate, channels, samples, extra_chunks: [] }
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
