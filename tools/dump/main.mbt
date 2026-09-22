///|
/// moonvoice/tools/dump —— 把分析中间量导出成 JSON（**开发工具，不是技能**）
///
/// 用途：给对照网页供数——网页要展示"我们的 mel 与 librosa 差多少"，
/// 就得先把我们算出来的矩阵拿出去。
///
/// 用法：
///   moon run --target wasm tools/dump -- --n-fft 512 --hop 256 --n-mels 40 < in.wav
///
/// 输出 JSON 字段：
///   meta / stft_mag（线性幅度谱）/ mel（线性能量）/ log_mel（dB）/ segments（VAD）

///| JSON 报告（用结构体 + ToJson，比手写字面量不易出错）
struct Report {
  sample_rate : Int
  channels : Int
  frames : Int
  bins : Int
  n_mels : Int
  n_fft : Int
  hop : Int
  duration_ms : Int
  stft_mag : FixedArray[Double]
  mel : FixedArray[Double]
  log_mel : FixedArray[Double]
  speech_ms : Int
  segments : Array[SegmentJson]
} derive(ToJson)

pub extend Report with ToJson::{to_json}

struct SegmentJson {
  start_ms : Int
  end_ms : Int
} derive(ToJson)

pub extend SegmentJson with ToJson::{to_json}

struct Options {
  n_fft : Int
  hop : Int
  n_mels : Int
  do_vad : Bool
}

fn parse_int(name : String, s : String) -> Int raise {
  let mut v = 0
  if s.length() == 0 {
    raise @audio.InvalidFormat(name + " 需要一个整数")
  }
  for c in s.to_array() {
    let d = c.to_int() - 48
    if d < 0 || d > 9 {
      raise @audio.InvalidFormat(name + " 不是合法整数: " + s)
    }
    v = v * 10 + d
  }
  v
}

fn parse_args(args : Array[String]) -> Options raise {
  let mut o : Options = { n_fft: 512, hop: 256, n_mels: 40, do_vad: true }
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    let next = if i + 1 < args.length() { args[i + 1] } else { "" }
    if a == "--n-fft" {
      o = { ..o, n_fft: parse_int(a, next) }
      i = i + 2
    } else if a == "--hop" {
      o = { ..o, hop: parse_int(a, next) }
      i = i + 2
    } else if a == "--n-mels" {
      o = { ..o, n_mels: parse_int(a, next) }
      i = i + 2
    } else if a == "--no-vad" {
      o = { ..o, do_vad: false }
      i = i + 1
    } else {
      i = i + 1
    }
  }
  o
}

fn run() -> Unit raise {
  let opts = parse_args(@miniio.args_get())
  let raw = @miniio.stdin.read_all().binary()
  let audio = @audio.decode_wav(raw)
  let rate = audio.sample_rate()
  let stft = @feature.Stft::new(opts.n_fft, opts.hop)
  let mel = @feature.MelFilterbank::new(opts.n_mels, opts.n_fft, rate)
  // 统一走单声道（与 librosa 的对照需要同一路信号）
  let mono = audio.to_mono()
  let mags = stft.magnitude(mono)
  let mel_e = @feature.mel_energies(stft, mel, mono)
  let logm = @feature.log_mel(stft, mel, mono)
  let segs : Array[SegmentJson] = []
  let mut speech_ms = 0
  if opts.do_vad {
    let params = @vad.VadParams::default()
    for s in @vad.detect_segments(audio, params, @vad.VadEngine::Fused) {
      segs.push({ start_ms: s.start_ms(), end_ms: s.end_ms() })
      speech_ms = speech_ms + s.duration_ms()
    }
  }
  let report : Report = {
    sample_rate: rate,
    channels: audio.channels(),
    frames: stft.frame_count(mono.length()),
    bins: stft.bins(),
    n_mels: opts.n_mels,
    n_fft: opts.n_fft,
    hop: opts.hop,
    duration_ms: (audio.frames().to_double() * 1000.0 / rate.to_double()).to_int(),
    stft_mag: mags,
    mel: mel_e,
    log_mel: logm,
    speech_ms,
    segments: segs,
  }
  @miniio.stdout.write_text(report.to_json().stringify() + "\n")
}

fn main {
  try {
    run()
  } catch {
    e => {
      @miniio.stderr.write_text("dump: \{e}\n") catch {
        _ => ()
      }
      @miniio.exit(1)
    }
  }
}
