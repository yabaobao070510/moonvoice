///|
/// audio 包黑盒测试：只通过公开 API 验证行为。
///
/// 测试数据用辅助函数**程序化构造**（不写字节字面量）：
/// 既避开 moonc 对高位置位字节字面量的 ICE（见 docs/known-issues.md），
/// 也保证期望值是外部约定的规范值，而不是"自己编自己解"的循环验证。

fn le16(v : Int) -> Array[Byte] {
  [(v & 0xFF).to_byte(), ((v >> 8) & 0xFF).to_byte()]
}

fn le24(v : Int) -> Array[Byte] {
  [(v & 0xFF).to_byte(), ((v >> 8) & 0xFF).to_byte(), ((v >> 16) & 0xFF).to_byte()]
}

fn le32(v : Int) -> Array[Byte] {
  [
    (v & 0xFF).to_byte(),
    ((v >> 8) & 0xFF).to_byte(),
    ((v >> 16) & 0xFF).to_byte(),
    ((v >> 24) & 0xFF).to_byte(),
  ]
}

fn ascii(s : String) -> Array[Byte] {
  let out : Array[Byte] = []
  for c in s {
    out.push(c.to_int().to_byte())
  }
  out
}

fn cat(parts : Array[Array[Byte]]) -> Array[Byte] {
  let out : Array[Byte] = []
  for p in parts {
    for b in p {
      out.push(b)
    }
  }
  out
}

///| 构造一段规范 WAV 字节流
fn make_wav(
  fmt_tag : Int,
  channels : Int,
  rate : Int,
  bits : Int,
  data : Array[Byte],
) -> Bytes {
  let bps = bits / 8
  let all = cat([
    ascii("RIFF"),
    le32(4 + 8 + 16 + 8 + data.length()),
    ascii("WAVE"),
    ascii("fmt "),
    le32(16),
    le16(fmt_tag),
    le16(channels),
    le32(rate),
    le32(rate * channels * bps),
    le16(channels * bps),
    le16(bits),
    ascii("data"),
    le32(data.length()),
    data,
  ])
  Bytes::from_array(all)
}

///| 浮点近似比较
fn expect_close(actual : Float, expected : Double, eps : Double, label : String) -> Unit raise {
  let d = actual.to_double() - expected
  let a = if d < 0.0 { -d } else { d }
  if a > eps {
    fail(
      label +
      ": got " +
      actual.to_double().to_string() +
      " want " +
      expected.to_string(),
    )
  }
}

// ---------------------------------------------------------------------------
// 解码：已知答案
// ---------------------------------------------------------------------------

test "decode: 16-bit mono, 满量程三点" {
  let wav = make_wav(
    1,
    1,
    16000,
    16,
    cat([le16(0), le16(0x8000), le16(0x7FFF)]),
  )
  let a = @audio.decode_wav(wav)
  assert_eq(a.sample_rate(), 16000)
  assert_eq(a.channels(), 1)
  assert_eq(a.frames(), 3)
  expect_close(a.sample_at(0, 0), 0.0, 1.0e-9, "s0")
  expect_close(a.sample_at(1, 0), -1.0, 1.0e-9, "s1")
  expect_close(a.sample_at(2, 0), 32767.0 / 32768.0, 1.0e-9, "s2")
}

test "decode: 8-bit 无符号以 128 为零点" {
  let wav = make_wav(1, 1, 8000, 8, [
    (0).to_byte(),
    (128).to_byte(),
    (255).to_byte(),
  ])
  let a = @audio.decode_wav(wav)
  expect_close(a.sample_at(0, 0), -1.0, 1.0e-9, "min")
  expect_close(a.sample_at(1, 0), 0.0, 1.0e-9, "mid")
  expect_close(a.sample_at(2, 0), 127.0 / 128.0, 1.0e-9, "max")
}

test "decode: 24-bit 有符号边界" {
  let wav = make_wav(
    1,
    1,
    16000,
    24,
    cat([le24(0x7FFFFF), le24(0x800000), le24(0)]),
  )
  let a = @audio.decode_wav(wav)
  expect_close(a.sample_at(0, 0), 8388607.0 / 8388608.0, 1.0e-9, "max")
  expect_close(a.sample_at(1, 0), -1.0, 1.0e-9, "min")
  expect_close(a.sample_at(2, 0), 0.0, 1.0e-9, "zero")
}

test "decode: 32-bit float（IEEE 位模式）" {
  // 1.0f = 0x3F800000, -0.5f = 0xBF000000, 0.0f = 0
  let wav = make_wav(
    3,
    1,
    44100,
    32,
    cat([le32(0x3F800000), le32(0xBF000000), le32(0)]),
  )
  let a = @audio.decode_wav(wav)
  expect_close(a.sample_at(0, 0), 1.0, 1.0e-6, "1.0")
  expect_close(a.sample_at(1, 0), -0.5, 1.0e-6, "-0.5")
  expect_close(a.sample_at(2, 0), 0.0, 1.0e-9, "0")
}

test "decode: 立体声交错顺序不被搞混" {
  let wav = make_wav(
    1,
    2,
    16000,
    16,
    cat([le16(0x1000), le16(0x2000), le16(0x3000), le16(0x4000)]),
  )
  let a = @audio.decode_wav(wav)
  assert_eq(a.channels(), 2)
  assert_eq(a.frames(), 2)
  expect_close(a.sample_at(0, 0), 0.125, 1.0e-9, "L0")
  expect_close(a.sample_at(0, 1), 0.25, 1.0e-9, "R0")
  expect_close(a.sample_at(1, 0), 0.375, 1.0e-9, "L1")
  expect_close(a.sample_at(1, 1), 0.5, 1.0e-9, "R1")
}

// ---------------------------------------------------------------------------
// 编码：回环与钳位
// ---------------------------------------------------------------------------

test "encode: i16 回环保真（整数样本应无误差）" {
  let n = 8
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    // 取值恰好是 1/32768 的整数倍，保证 i16 表示无误差
    samples[i] = Float::from_double((i * 1000 - 4000).to_double() / 32768.0)
  }
  let a = @audio.Audio::new(16000, 1, samples)
  let wav = @audio.encode_wav(a)
  let b = @audio.decode_wav(wav)
  assert_eq(b.frames(), n)
  for i = 0; i < n; i = i + 1 {
    assert_eq(a.sample_at(i, 0).to_double(), b.sample_at(i, 0).to_double())
  }
}

test "encode: f32 回环应完全无损" {
  let samples : FixedArray[Float] = FixedArray::make(3, 0.0)
  samples[0] = 0.5
  samples[1] = -0.25
  samples[2] = 0.125
  let a = @audio.Audio::new(48000, 1, samples)
  let b = @audio.decode_wav(@audio.encode_wav(a, format=F32))
  for i = 0; i < 3; i = i + 1 {
    assert_eq(a.sample_at(i, 0), b.sample_at(i, 0))
  }
}

test "encode: 超量程钳位而非回绕" {
  let samples : FixedArray[Float] = FixedArray::make(4, 0.0)
  samples[0] = 2.0
  samples[1] = -2.0
  samples[2] = 1.0
  samples[3] = -1.0
  let a = @audio.Audio::new(16000, 1, samples)
  let b = @audio.decode_wav(@audio.encode_wav(a))
  expect_close(b.sample_at(0, 0), 32767.0 / 32768.0, 1.0e-9, "clip hi")
  expect_close(b.sample_at(1, 0), -1.0, 1.0e-9, "clip lo")
  // 16-bit PCM 中 +1.0 不可表示：满刻度即 32767/32768
  expect_close(b.sample_at(2, 0), 32767.0 / 32768.0, 1.0e-9, "1.0")
  expect_close(b.sample_at(3, 0), -1.0, 1.0e-9, "-1.0")
}

test "encode: 3 声道走 EXTENSIBLE 且能被解回" {
  let n = 6
  let samples : FixedArray[Float] = FixedArray::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    samples[i] = Float::from_double(i.to_double() / 64.0)
  }
  let a = @audio.Audio::new(22050, 3, samples)
  let wav = @audio.encode_wav(a)
  // 0xFFFE 出现在 fmt 块的 format tag 位置（偏移 20）
  assert_eq(wav[20].to_int(), 0xFE)
  assert_eq(wav[21].to_int(), 0xFF)
  let b = @audio.decode_wav(wav)
  assert_eq(b.channels(), 3)
  assert_eq(b.frames(), 2)
  for i = 0; i < n; i = i + 1 {
    assert_eq(a.samples()[i].to_double(), b.samples()[i].to_double())
  }
}

// ---------------------------------------------------------------------------
// 元数据保真
// ---------------------------------------------------------------------------

test "未知块被保留并回写（含奇数长度块的填充边界）" {
  // 故意用奇数长度 payload：RIFF 规定块长度须补齐到偶数字节，
  // 补位字节不计入 size。解析器若忽略补位就会在后续块上错位。
  let payload = ascii("hello moonvoice") // 15 字节，奇数
  let pad = payload.length() % 2
  let pad_bytes : Array[Byte] = if pad == 1 { [(0).to_byte()] } else { [] }
  let body_size = 8 + payload.length() + pad
  let all = cat([
    ascii("RIFF"),
    le32(4 + body_size + (8 + 16) + (8 + 2)),
    ascii("WAVE"),
    ascii("JUNK"),
    le32(payload.length()),
    payload,
    pad_bytes,
    ascii("fmt "),
    le32(16),
    cat([le16(1), le16(1), le32(8000), le32(16000), le16(2), le16(16)]),
    ascii("data"),
    le32(2),
    le16(0x4000),
  ])
  let a = @audio.decode_wav(Bytes::from_array(all))
  assert_eq(a.extra_chunks().length(), 1)
  let (id, body) = a.extra_chunks()[0]
  assert_eq(id, "JUNK")
  assert_eq(body.length(), payload.length()) // 填充字节不进入块内容
  // 再写出再读回，元数据仍在
  let b = @audio.decode_wav(@audio.encode_wav(a))
  assert_eq(b.extra_chunks().length(), 1)
  assert_eq(b.extra_chunks()[0].0, "JUNK")
}

// ---------------------------------------------------------------------------
// 错误路径：checked error 必须显式抛出，而不是静默产出坏数据
// ---------------------------------------------------------------------------

test "错误：非 RIFF 输入" {
  let bad = Bytes::from_array(ascii("NOPEnope0000"))
  let raised = try @audio.decode_wav(bad) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
}

test "错误：截断的 data 块" {
  let all = cat([
    ascii("RIFF"),
    le32(100),
    ascii("WAVE"),
    ascii("data"),
    le32(9999),
    le16(0),
  ])
  let raised = try @audio.decode_wav(Bytes::from_array(all)) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
}

test "错误：不支持的编码（A-law tag=6）" {
  let wav = make_wav(6, 1, 8000, 8, [(0).to_byte(), (1).to_byte()])
  let raised = try @audio.decode_wav(wav) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
}

test "错误：缺 fmt 块" {
  let all = cat([
    ascii("RIFF"),
    le32(16),
    ascii("WAVE"),
    ascii("data"),
    le32(2),
    le16(0),
  ])
  let raised = try @audio.decode_wav(Bytes::from_array(all)) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
}
