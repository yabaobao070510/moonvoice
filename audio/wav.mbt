///|
/// moonvoice/audio — RIFF/WAVE 编解码（纯 MoonBit，无 FFI）
///
/// 支持：
/// - PCM 8/16/24/32-bit、IEEE float 32/64-bit
/// - WAVE_FORMAT_EXTENSIBLE(0xFFFE) 的 subformat 解析
/// - 多声道（交错）、任意采样率
/// - 未知块原样保留并在写出时回写（元数据不丢）

///| 读四字节块 ID。可打印 ASCII 原样输出，其余转义为 \xNN：
/// 错误消息里绝不能出现原始控制字符（会污染日志、破坏结构化输出）。
fn tag_at(b : Bytes, off : Int) -> String {
  let mut out = ""
  for i = 0; i < 4; i = i + 1 {
    let v = b[off + i].to_int()
    if v >= 0x20 && v < 0x7F {
      out = out + b[off + i].to_char().to_string()
    } else {
      out = out + "\\x" + v.to_string()
    }
  }
  out
}

///| 由 (format_tag, bits) 解析出采样格式
fn resolve_format(tag : Int, bits : Int) -> SampleFormat raise AudioError {
  if tag == 1 {
    // WAVE_FORMAT_PCM
    if bits == 8 {
      SampleFormat::U8
    } else if bits == 16 {
      SampleFormat::I16
    } else if bits == 24 {
      SampleFormat::I24
    } else if bits == 32 {
      SampleFormat::I32
    } else {
      raise UnsupportedFormat("PCM with " + bits.to_string() + " bits")
    }
  } else if tag == 3 {
    // WAVE_FORMAT_IEEE_FLOAT
    if bits == 32 {
      SampleFormat::F32
    } else if bits == 64 {
      SampleFormat::F64
    } else {
      raise UnsupportedFormat("float with " + bits.to_string() + " bits")
    }
  } else {
    raise UnsupportedFormat("format tag " + tag.to_string())
  }
}

fn bytes_per_sample(f : SampleFormat) -> Int {
  match f {
    U8 => 1
    I16 => 2
    I24 => 3
    I32 => 4
    F32 => 4
    F64 => 8
  }
}

///| 单个样本解码：字节偏移 → 归一化浮点
fn decode_sample(b : Bytes, off : Int, f : SampleFormat) -> Float {
  match f {
    U8 => decode_u8(u8_at(b, off))
    I16 => decode_i16(u16_at(b, off))
    I24 => decode_i24(u24_at(b, off))
    I32 => decode_i32(u32_at(b, off))
    F32 => Float::from_double(f32_at(b, off))
    F64 => Float::from_double(f64_at(b, off))
  }
}

///|
/// 解析 WAV 字节流为 `Audio`。
pub fn decode_wav(bytes : Bytes) -> Audio raise AudioError {
  let total = bytes.length()
  if total < 12 {
    raise Truncated("RIFF header")
  }
  if tag_at(bytes, 0) != "RIFF" {
    raise NotRiff
  }
  if tag_at(bytes, 8) != "WAVE" {
    raise NotRiff
  }
  let mut pos = 12
  let mut format : SampleFormat? = None
  let mut n_channels = 0
  let mut rate = 0
  let mut data_off = -1
  let mut data_len = 0
  let extras : Array[(String, Bytes)] = []
  while pos + 8 <= total {
    let id = tag_at(bytes, pos)
    let size = u32_at(bytes, pos + 4).to_int()
    let body = pos + 8
    if size < 0 || body + size > total {
      raise Truncated("chunk " + id)
    }
    if id == "fmt " {
      if size < 16 {
        raise InvalidFormat("fmt chunk too small")
      }
      let mut tag = u16_at(bytes, body).to_int()
      n_channels = u16_at(bytes, body + 2).to_int()
      rate = u32_at(bytes, body + 4).to_int()
      let bits = u16_at(bytes, body + 14).to_int()
      if tag == 0xFFFE {
        // WAVE_FORMAT_EXTENSIBLE：真正的格式在 subformat GUID 前两字节
        if size < 40 {
          raise InvalidFormat("extensible fmt chunk too small")
        }
        tag = u16_at(bytes, body + 24).to_int()
      }
      if n_channels <= 0 {
        raise InvalidFormat("channels = " + n_channels.to_string())
      }
      if rate <= 0 {
        raise InvalidFormat("sample rate = " + rate.to_string())
      }
      format = Some(resolve_format(tag, bits))
    } else if id == "data" {
      data_off = body
      data_len = size
    } else {
      extras.push((id, exact_view_bytes(bytes, body, size)))
    }
    // 块按偶数字节对齐，奇数长度后有一字节填充
    pos = body + size + size % 2
  }
  let fmt = match format {
    Some(f) => f
    None => raise InvalidFormat("no fmt chunk")
  }
  if data_off < 0 {
    raise InvalidFormat("no data chunk")
  }
  let bps = bytes_per_sample(fmt)
  let frame_bytes = bps * n_channels
  if frame_bytes <= 0 || data_len % frame_bytes != 0 {
    raise InvalidFormat("data size " + data_len.to_string() + " not frame-aligned")
  }
  let n_samples = data_len / bps
  let samples : FixedArray[Float] = FixedArray::make(n_samples, 0.0)
  for i = 0; i < n_samples; i = i + 1 {
    samples[i] = decode_sample(bytes, data_off + i * bps, fmt)
  }
  Audio::new(rate, n_channels, samples).with_extra_chunks(extras)
}

///| 从 Bytes 取一段副本
fn exact_view_bytes(b : Bytes, off : Int, len : Int) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(len, byte_of(0))
  for i = 0; i < len; i = i + 1 {
    out[i] = b[off + i]
  }
  Bytes::from_array(out)
}

// ---------------------------------------------------------------------------
// 写出
// ---------------------------------------------------------------------------

///| 由 Int 构造 Byte。必须走函数而不能直接写字节字面量：
/// `fa[i] = b''` 会触发 moonc v0.10.14 的编译期 ICE（见 docs/known-issues.md）。
fn byte_of(v : Int) -> Byte {
  v.to_byte()
}

fn put_u16le(fa : FixedArray[Byte], off : Int, v : Int) -> Unit {
  fa[off] = (v & 0xFF).to_byte()
  fa[off + 1] = ((v >> 8) & 0xFF).to_byte()
}

fn put_u32le(fa : FixedArray[Byte], off : Int, v : Int) -> Unit {
  fa[off] = (v & 0xFF).to_byte()
  fa[off + 1] = ((v >> 8) & 0xFF).to_byte()
  fa[off + 2] = ((v >> 16) & 0xFF).to_byte()
  fa[off + 3] = ((v >> 24) & 0xFF).to_byte()
}

///| 按位写 32 位（用于 IEEE 浮点的位模式，可能超出 Int 正区间）
fn put_u32_bits(fa : FixedArray[Byte], off : Int, u : UInt) -> Unit {
  fa[off] = (u & 0xFF).to_byte()
  fa[off + 1] = ((u >> 8) & 0xFF).to_byte()
  fa[off + 2] = ((u >> 16) & 0xFF).to_byte()
  fa[off + 3] = ((u >> 24) & 0xFF).to_byte()
}

///| 写 ASCII 块 ID
fn put_tag(fa : FixedArray[Byte], off : Int, tag : String) -> Unit {
  let bs = @utf8.encode(tag)
  for i = 0; i < 4; i = i + 1 {
    fa[off + i] = if i < bs.length() { bs[i] } else { byte_of(32) }
  }
}

///| 整数样本 → 小端字节（用掩码取字节，规避 Int 溢出）
fn put_sample_int(
  fa : FixedArray[Byte],
  off : Int,
  v : Int,
  bps : Int,
) -> Unit {
  for i = 0; i < bps; i = i + 1 {
    fa[off + i] = ((v >> (8 * i)) & 0xFF).to_byte()
  }
}

///| 单个样本编码
fn encode_sample(
  fa : FixedArray[Byte],
  off : Int,
  x : Float,
  f : SampleFormat,
) -> Unit {
  match f {
    U8 => put_sample_int(fa, off, encode_u8(x), 1)
    I16 => put_sample_int(fa, off, encode_i16(x), 2)
    I24 => put_sample_int(fa, off, encode_i24(x), 3)
    I32 => put_sample_int(fa, off, encode_i32(x), 4)
    F32 => put_u32_bits(fa, off, x.reinterpret_as_uint())
    F64 => {
      let u = Double::reinterpret_as_int64(x.to_double()).reinterpret_as_uint64()
      put_u32_bits(fa, off, u.to_uint())
      put_u32_bits(fa, off + 4, (u >> 32).to_uint())
    }
  }
}

///|
/// 编码为 WAV 字节流。默认 16-bit PCM（兼容性最好）；
/// 声道数 > 2 时自动使用 WAVE_FORMAT_EXTENSIBLE。
pub fn encode_wav(audio : Audio, format? : SampleFormat = I16) -> Bytes raise AudioError {
  let n_channels = audio.channels()
  let rate = audio.sample_rate()
  if n_channels <= 0 || rate <= 0 {
    raise InvalidFormat("invalid audio parameters")
  }
  let n_samples = audio.samples().length()
  if n_samples % n_channels != 0 {
    raise InvalidFormat("sample count not frame-aligned")
  }
  let bps = bytes_per_sample(format)
  let data_size = n_samples * bps
  if data_size >= 2147483647 {
    raise UnsupportedFormat("data too large for RIFF (>2 GiB)")
  }
  let extensible = n_channels > 2
  let fmt_size = if extensible { 40 } else { 16 }
  let extras = audio.extra_chunks()
  let mut extra_total = 0
  for chunk in extras {
    extra_total = extra_total + 8 + chunk.1.length() + chunk.1.length() % 2
  }
  let total = 12 +
    (8 + fmt_size) +
    (8 + data_size) +
    extra_total +
    (data_size % 2)
  let fa : FixedArray[Byte] = FixedArray::make(total, byte_of(0))
  // RIFF 头
  put_tag(fa, 0, "RIFF")
  put_u32le(fa, 4, total - 8)
  put_tag(fa, 8, "WAVE")
  // fmt 块
  put_tag(fa, 12, "fmt ")
  put_u32le(fa, 16, fmt_size)
  let tag = match format {
    U8 | I16 | I24 | I32 => 1
    F32 | F64 => 3
  }
  put_u16le(fa, 20, if extensible { 0xFFFE } else { tag })
  put_u16le(fa, 22, n_channels)
  put_u32le(fa, 24, rate)
  let bits = bps * 8
  let block_align = n_channels * bps
  put_u32le(fa, 28, rate * block_align)
  put_u16le(fa, 32, block_align)
  put_u16le(fa, 34, bits)
  if extensible {
    put_u16le(fa, 36, 22) // cbSize
    put_u16le(fa, 38, bits) // valid bits（等于容器位宽）
    put_u32le(fa, 40, default_channel_mask(n_channels))
    // subformat GUID = KSDATAFORMAT_SUBTYPE_PCM/IEEE_FLOAT 的小端布局：
    //   00000001-0000-0010-8000-00AA00389B71
    put_u16le(fa, 44, tag) // Data1 低 16 位（= 真实 format tag）
    fa[46] = byte_of(0x00)
    fa[47] = byte_of(0x00)
    fa[48] = byte_of(0x00) // Data2
    fa[49] = byte_of(0x00)
    put_u16le(fa, 50, 0x0010) // Data3
    fa[52] = byte_of(0x80) // Data4（8 字节大端字面量）
    fa[53] = byte_of(0x00)
    fa[54] = byte_of(0x00)
    fa[55] = byte_of(0xAA)
    fa[56] = byte_of(0x00)
    fa[57] = byte_of(0x38)
    fa[58] = byte_of(0x9B)
    fa[59] = byte_of(0x71)
  }
  // data 块
  let data_hdr = 12 + 8 + fmt_size
  put_tag(fa, data_hdr, "data")
  put_u32le(fa, data_hdr + 4, data_size)
  let body = data_hdr + 8
  for i = 0; i < n_samples; i = i + 1 {
    encode_sample(fa, body + i * bps, audio.samples()[i], format)
  }
  // 保留块回写（置于 data 之后，避免影响 data 偏移语义）
  let mut p = body + data_size + data_size % 2
  for chunk in extras {
    let (id, payload) = chunk
    put_tag(fa, p, id)
    put_u32le(fa, p + 4, payload.length())
    for i = 0; i < payload.length(); i = i + 1 {
      fa[p + 8 + i] = payload[i]
    }
    p = p + 8 + payload.length() + payload.length() % 2
  }
  Bytes::from_array(fa)
}

///| 常见声道布局掩码（EXTENSIBLE 用）
fn default_channel_mask(n : Int) -> Int {
  if n == 1 {
    0x4 // 前中
  } else if n == 2 {
    0x3 // 前左 + 前右
  } else {
    (1 << n) - 1
  }
}
