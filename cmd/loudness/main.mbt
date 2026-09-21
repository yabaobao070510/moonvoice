///|
/// moonvoice/loudness —— 响度测量技能（WASIp1，stdin → stdout）
///
/// 契约（见 SKILL.md）：
///   stdin  ← WAV 字节
///   stdout → 响度报告（文本或 JSON）
///
/// 不只是"测一个数"：同时给出**到目标响度的增益建议**——
/// agent 拿到的是"该调多少 dB"，可以直接接着做。
///
/// 用法：
///   moonx <user>/moonvoice/cmd/loudness -- --target -16 < in.wav

///| 命令行用法错误
suberror CliError {
  BadUsage(String)
}

impl Show for CliError with fn output(self, logger) {
  match self {
    BadUsage(msg) => logger.write_string(msg)
  }
}

const USAGE : String = "moonvoice/loudness — 测响度（EBU R128 / ITU-R BS.1770-4）\n" +
  "用法: moonx <user>/moonvoice/cmd/loudness -- [选项] < in.wav\n" +
  "\n" +
  "选项:\n" +
  "  --target LUFS   目标响度（默认 -16，播客/口播常用；流媒体多为 -14）\n" +
  "  --json          输出 JSON（默认人类可读文本）\n" +
  "  --help          显示本帮助\n" +
  "\n" +
  "输出包含：积分响度、响度范围 LRA、样本峰值、以及到目标响度所需的增益。"

///| 测量报告（JSON 输出用；结构体 + ToJson 比手写 JSON 字面量更不容易出错）
struct Measurement {
  standard : String
  sample_rate : Int
  channels : Int
} derive(ToJson)

pub extend Measurement with ToJson::{to_json}

struct Report {
  measurement : Measurement
  integrated_lufs : Double
  loudness_range_lu : Double
  sample_peak_dbfs : Double
  gated_blocks : Int
  total_blocks : Int
  target_lufs : Double
  gain_to_target_db : Double
  note : String
} derive(ToJson)

pub extend Report with ToJson::{to_json}

struct Options {
  target : Double
  json : Bool
  help : Bool
}

fn parse_double(name : String, s : String) -> Double raise CliError {
  // 支持负号与小数点（String 没有 char_at，先转成字符数组）
  let chars = s.to_array()
  let mut i = 0
  let mut neg = false
  if chars.length() > 0 && chars[0] == '-' {
    neg = true
    i = 1
  }
  let mut v = 0.0
  let mut frac = 1.0
  let mut in_frac = false
  let mut seen = false
  while i < chars.length() {
    let c = chars[i]
    if c == '.' {
      in_frac = true
    } else {
      let d = c.to_int() - 48
      if d < 0 || d > 9 {
        raise BadUsage(name + " 不是合法数字: " + s)
      }
      seen = true
      if in_frac {
        frac = frac / 10.0
        v = v + d.to_double() * frac
      } else {
        v = v * 10.0 + d.to_double()
      }
    }
    i = i + 1
  }
  if !seen {
    raise BadUsage(name + " 不是合法数字: " + s)
  }
  if neg {
    -v
  } else {
    v
  }
}

fn parse_args(args : Array[String]) -> Options raise CliError {
  let mut opts : Options = { target: -16.0, json: false, help: false }
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    let next = if i + 1 < args.length() { args[i + 1] } else { "" }
    if a == "--help" || a == "-h" {
      opts = { ..opts, help: true }
      i = i + 1
    } else if a == "--json" {
      opts = { ..opts, json: true }
      i = i + 1
    } else if a == "--target" {
      opts = { ..opts, target: parse_double(a, next) }
      i = i + 2
    } else if a.has_prefix("--") {
      raise BadUsage("未知选项: " + a + "\n\n" + USAGE)
    } else {
      i = i + 1
    }
  }
  opts
}

fn fmt2(x : Double) -> String {
  if x != x {
    return "nan"
  }
  if x < -199.0 {
    return "-inf"
  }
  let v = (x * 100.0 + 0.5 * (if x < 0.0 { -1.0 } else { 1.0 })).to_int().to_double() / 100.0
  v.to_string()
}

fn run() -> Unit raise {
  let opts = parse_args(@miniio.args_get())
  if opts.help {
    @miniio.stdout.write_text(USAGE + "\n")
    return
  }
  let input = @miniio.stdin.read_all().binary()
  if input.length() == 0 {
    raise BadUsage("stdin 为空：请把 WAV 字节通过 stdin 传入")
  }
  let audio = @audio.decode_wav(input)
  let r = @feature.measure_loudness(audio)
  let gain = opts.target - r.integrated_lufs()
  if opts.json {
    let report : Report = {
      measurement: {
        standard: "ITU-R BS.1770-4 / EBU R128",
        sample_rate: audio.sample_rate(),
        channels: audio.channels(),
      },
      integrated_lufs: r.integrated_lufs(),
      loudness_range_lu: r.loudness_range_lu(),
      sample_peak_dbfs: r.sample_peak_dbfs(),
      gated_blocks: r.gated_blocks(),
      total_blocks: r.total_blocks(),
      target_lufs: opts.target,
      gain_to_target_db: gain,
      note: "sample_peak_dbfs 是样本峰值，非真峰值（dBTP 需过采样）",
    }
    @miniio.stdout.write_text(report.to_json().stringify() + "\n")
    return
  }
  @miniio.stdout.write_text(
    "积分响度   : " + fmt2(r.integrated_lufs()) + " LUFS\n" +
    "响度范围   : " + fmt2(r.loudness_range_lu()) + " LU\n" +
    "样本峰值   : " + fmt2(r.sample_peak_dbfs()) + " dBFS\n" +
    "参与块数   : " + r.gated_blocks().to_string() + " / " + r.total_blocks().to_string() + "\n" +
    "目标响度   : " + fmt2(opts.target) + " LUFS\n" +
    "建议增益   : " + fmt2(gain) + " dB\n",
  )
}

fn main {
  try {
    run()
  } catch {
    e => {
      @miniio.stderr.write_text("moonvoice/loudness: \{e}\n") catch {
        _ => ()
      }
      @miniio.exit(1)
    }
  }
}
