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
  help : Bool
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
  @miniio.stdout.write(@audio.encode_wav(out))
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
