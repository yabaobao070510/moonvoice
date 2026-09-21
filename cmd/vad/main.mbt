///|
/// moonvoice/vad —— 语音分段技能（WASIp1，stdin → stdout）
///
/// 契约（见 SKILL.md）：
///   stdin  ← WAV 字节（任意采样率/位深/声道，走 audio 包解码）
///   stdout → 语音片段 JSON
///   stderr ← 人类可读的错误信息（退出码非 0）
///
/// 一条命令做完"任意音频 → 可识别语音段"：
///   解码 → 重采样(可选) → 混单声道 → VAD → 时间平滑 → JSON
///
/// 用法：
///   moonx <user>/moonvoice/cmd/vad -- --resample 16000 --engine fused < in.wav


///| 命令行用法错误
suberror CliError {
  BadUsage(String)
}

impl Show for CliError with fn output(self, logger) {
  match self {
    BadUsage(msg) => logger.write_string(msg)
  }
}

///| 解析后的选项
struct Options {
  engine : @mbvad.VadEngine
  frame_ms : Int
  min_silence_ms : Int
  min_speech_ms : Int
  pad_ms : Int
  target_rate : Int // 0 表示不重采样
  indent : Int // 0 表示紧凑输出
  speech_only : Bool // 输出"去掉静音的干净语音"而不是 JSON
  help : Bool
}

const USAGE : String = "moonvoice/vad — 把音频切成可识别的语音段\n" +
  "用法: moonx <user>/moonvoice/cmd/vad -- [选项] < input.wav > segments.json\n" +
  "\n" +
  "选项:\n" +
  "  --engine energy|spectral|fused  判决引擎（默认 fused）\n" +
  "  --frame-ms N                    帧长，10/20/30（默认 30）\n" +
  "  --min-silence MS                间隔小于此值的段合并（默认 250）\n" +
  "  --min-speech MS                 短于此值的段丢弃（默认 180）\n" +
  "  --pad MS                        段前后补白（默认 60）\n" +
  "  --resample HZ                   先重采样到此采样率（如 16000）\n" +
  "  --indent N                      JSON 缩进（默认 0，紧凑）\n" +
  "  --help                          显示本帮助\n" +
  "\n" +
  "输入必须是 WAV（stdin）；输出为 JSON（stdout）。"

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
    engine: @mbvad.VadEngine::Fused,
    frame_ms: 30,
    min_silence_ms: 250,
    min_speech_ms: 180,
    pad_ms: 60,
    target_rate: 0,
    indent: 0,
    speech_only: false,
    help: false,
  }
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    let next = if i + 1 < args.length() { args[i + 1] } else { "" }
    if a == "--help" || a == "-h" {
      opts = { ..opts, help: true }
      i = i + 1
    } else if a == "--engine" {
      opts = {
        ..opts,
        engine: if next == "energy" {
          @mbvad.VadEngine::Energy
        } else if next == "spectral" {
          @mbvad.VadEngine::Spectral
        } else if next == "fused" {
          @mbvad.VadEngine::Fused
        } else {
          raise BadUsage("未知引擎: " + next)
        },
      }
      i = i + 2
    } else if a == "--frame-ms" {
      let v = parse_int("--frame-ms", next)
      if v != 10 && v != 20 && v != 30 {
        raise BadUsage("--frame-ms 只支持 10/20/30（VAD 的帧长约定）")
      }
      opts = { ..opts, frame_ms: v }
      i = i + 2
    } else if a == "--min-silence" {
      opts = { ..opts, min_silence_ms: parse_int(a, next) }
      i = i + 2
    } else if a == "--min-speech" {
      opts = { ..opts, min_speech_ms: parse_int(a, next) }
      i = i + 2
    } else if a == "--pad" {
      opts = { ..opts, pad_ms: parse_int(a, next) }
      i = i + 2
    } else if a == "--resample" {
      opts = { ..opts, target_rate: parse_int(a, next) }
      i = i + 2
    } else if a == "--speech-only" {
      opts = { ..opts, speech_only: true }
      i = i + 1
    } else if a == "--indent" {
      opts = { ..opts, indent: parse_int(a, next) }
      i = i + 2
    } else if a.has_prefix("--") {
      raise BadUsage("未知选项: " + a + "\n\n" + USAGE)
    } else {
      // 非选项参数（含 moonx 可能传入的程序名）直接跳过
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
  let input = @miniio.stdin.read_all().binary()
  if input.length() == 0 {
    raise BadUsage("stdin 为空：请把 WAV 字节通过 stdin 传入")
  }
  let decoded = @audio.decode_wav(input)
  let audio = if opts.target_rate > 0 {
    @mbres.resample_audio(decoded, opts.target_rate)
  } else {
    decoded
  }
  let params = @mbvad.VadParams::custom(
    frame_ms=opts.frame_ms,
    min_silence_ms=opts.min_silence_ms,
    min_speech_ms=opts.min_speech_ms,
    pad_ms=opts.pad_ms,
  )
  let result = @mbvad.build_result(audio, params, opts.engine)
  if opts.speech_only {
    // 只保留语音：检出 → 切片 → 拼接（原语组合，见 vad.speech_only）
    let joined = @mbvad.speech_only(audio, result.segments())
    @miniio.stdout.write(@audio.encode_wav(joined))
    return
  }
  let json = if opts.indent > 0 {
    result.to_json().stringify(indent=opts.indent)
  } else {
    result.to_json_string()
  }
  @miniio.stdout.write_text(json + "\n")
}

fn main {
  try {
    run()
  } catch {
    e => {
      @miniio.stderr.write_text("moonvoice/vad: \{e}\n") catch {
        _ => ()
      }
      @miniio.exit(1)
    }
  }
}
