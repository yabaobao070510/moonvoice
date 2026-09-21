///|
/// moonvoice/resample —— 重采样技能（WASIp1，stdin → stdout）
///
/// 契约（见 SKILL.md）：
///   stdin  ← WAV 字节（任意采样率/位深/声道）
///   stdout → 重采样后的 WAV 字节（16-bit PCM，保持原声道数）
///   stderr ← 人类可读的错误信息（退出码非 0）
///
/// 用途：把任意来源的音频统一到识别器要求的采样率（通常是 16 kHz 单声道）。
/// 需要单声道时先自行混音，或用 `cmd/vad --resample`（它内部会混单声道）。
///
/// 用法：
///   moonx <user>/moonvoice/cmd/resample -- --rate 16000 < in.wav > out.wav

///| 命令行用法错误
suberror CliError {
  BadUsage(String)
}

impl Show for CliError with fn output(self, logger) {
  match self {
    BadUsage(msg) => logger.write_string(msg)
  }
}

const USAGE : String = "moonvoice/resample — 把 WAV 重采样到目标采样率\n" +
  "用法: moonx <user>/moonvoice/cmd/resample -- --rate HZ [选项] < in.wav > out.wav\n" +
  "\n" +
  "选项:\n" +
  "  --rate HZ              目标采样率（必填，如 16000）\n" +
  "  --quality fast|balanced|best  滤波器质量档（默认 balanced）\n" +
  "  --help                 显示本帮助\n" +
  "\n" +
  "输出为 16-bit PCM WAV；RIFF 保留块（如 ffmpeg 写的 LIST/INFO）会原样带过去。"

struct Options {
  rate : Int
  quality : @mbrs.Quality
  format : SampleFormatChoice
  dither : Bool
  help : Bool
}

///| 输出格式选择：默认沿用输入格式（24-bit 素材不会被无声降级）
enum SampleFormatChoice {
  KeepInput
  Explicit(@audio.SampleFormat)
}

fn parse_int(name : String, s : String) -> Int raise CliError {
  let mut v = 0
  if s.length() == 0 {
    raise BadUsage(name + " 需要一个整数")
  }
  for c in s {
    let d = c.to_int() - 48
    if d < 0 || d > 9 {
      raise BadUsage(name + " 不是合法整数: " + s)
    }
    v = v * 10 + d
  }
  v
}

fn parse_args(args : Array[String]) -> Options raise CliError {
  let mut opts : Options = {
    rate: 0,
    quality: @mbrs.Quality::Balanced,
    format: KeepInput,
    dither: false,
    help: false,
  }
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    let next = if i + 1 < args.length() { args[i + 1] } else { "" }
    if a == "--help" || a == "-h" {
      opts = { ..opts, help: true }
      i = i + 1
    } else if a == "--rate" {
      opts = { ..opts, rate: parse_int(a, next) }
      i = i + 2
    } else if a == "--dither" {
      opts = { ..opts, dither: true }
      i = i + 1
    } else if a == "--format" {
      opts = {
        ..opts,
        format: if next == "i16" {
          Explicit(@audio.SampleFormat::I16)
        } else if next == "i24" {
          Explicit(@audio.SampleFormat::I24)
        } else if next == "i32" {
          Explicit(@audio.SampleFormat::I32)
        } else if next == "f32" {
          Explicit(@audio.SampleFormat::F32)
        } else if next == "u8" {
          Explicit(@audio.SampleFormat::U8)
        } else {
          raise BadUsage("未知输出格式: " + next + "（可选 i16/i24/i32/f32/u8）")
        },
      }
      i = i + 2
    } else if a == "--quality" {
      opts = {
        ..opts,
        quality: if next == "fast" {
          @mbrs.Quality::Fast
        } else if next == "best" {
          @mbrs.Quality::Best
        } else if next == "balanced" {
          @mbrs.Quality::Balanced
        } else {
          raise BadUsage("未知质量档: " + next)
        },
      }
      i = i + 2
    } else if a.has_prefix("--") {
      raise BadUsage("未知选项: " + a + "\n\n" + USAGE)
    } else {
      i = i + 1
    }
  }
  opts
}

fn run() -> Unit raise {
  let opts = parse_args(@miniio.args_get())
  if opts.help {
    @miniio.stdout.write_text(USAGE + "\n")
    return
  }
  if opts.rate <= 0 {
    raise BadUsage("必须用 --rate 指定目标采样率\n\n" + USAGE)
  }
  let input = @miniio.stdin.read_all().binary()
  if input.length() == 0 {
    raise BadUsage("stdin 为空：请把 WAV 字节通过 stdin 传入")
  }
  let decoded = @audio.decode_wav(input)
  let out = @mbrs.resample_audio(decoded, opts.rate, quality=opts.quality)
  // 输出格式：默认沿用输入（除非显式指定）
  let format = match opts.format {
    KeepInput =>
      match out.source_format() {
        Some(f) => f
        None => @audio.SampleFormat::I16
      }
    Explicit(f) => f
  }
  let report = @audio.encode_wav_ex(
    out,
    @audio.EncodeOptions::new(format, dither=opts.dither),
  )
  // 削波必须报出来：重采样过冲导致的削波是"无声的幅度损失"，
  // 静默钳位会让使用者以为输出没问题。
  if report.has_clipping() {
    @miniio.stderr.write_text(
      "警告: 输出有 " +
      report.clipped_samples().to_string() +
      " 个样本被钳位（峰值 " +
      fmt_peak(report.peak()) +
      "×满刻度）。建议降低增益或改用浮点输出（--format f32）。\n",
    ) catch {
      _ => ()
    }
  }
  @miniio.stdout.write(report.bytes())
}

fn fmt_peak(x : Double) -> String {
  let v = (x * 1000.0 + 0.5).to_int().to_double() / 1000.0
  v.to_string()
}

fn main {
  try {
    run()
  } catch {
    e => {
      @miniio.stderr.write_text("moonvoice/resample: \{e}\n") catch {
        _ => ()
      }
      @miniio.exit(1)
    }
  }
}
