///|
/// moonvoice/segments — 语音段时间轴模型与 JSON 契约
///
/// 为什么要独立成包：段的时间轴操作（合并/丢弃/补白/统计）是**产品语义**，
/// 不是 VAD 的算法细节。放在这里，VAD 换实现、CLI 换形态，契约都不动。
///
/// JSON 契约（对外承诺，见 README）：
/// ```json
/// {"version":1,
///  "source":{"sample_rate":16000,"channels":1,"duration_ms":12345},
///  "params":{"engine":"fused","frame_ms":30},
///  "segments":[{"start_ms":120,"end_ms":3420,"rms_dbfs":-21.3,"confidence":0.91}],
///  "stats":{"speech_ms":8100,"ratio":0.66}}
/// ```

///| 一个语音段（毫秒，左闭右开）
pub struct Segment {
  start_ms : Int
  end_ms : Int
  rms_dbfs : Double
  confidence : Double
} derive(ToJson, @debug.Debug)

pub extend Segment with ToJson::{to_json}
pub extend Segment with @debug.Debug::{to_repr}

pub fn Segment::new(
  start_ms : Int,
  end_ms : Int,
  rms_dbfs : Double,
  confidence : Double,
) -> Segment {
  { start_ms, end_ms, rms_dbfs, confidence }
}

pub fn Segment::start_ms(self : Segment) -> Int {
  self.start_ms
}

pub fn Segment::end_ms(self : Segment) -> Int {
  self.end_ms
}

pub fn Segment::duration_ms(self : Segment) -> Int {
  self.end_ms - self.start_ms
}

///| 段内 RMS（dBFS，越接近 0 越响）
pub fn Segment::rms_dbfs(self : Segment) -> Double {
  self.rms_dbfs
}

///| 判决裕量归一化到 0~1，可用来过滤低置信段
pub fn Segment::confidence(self : Segment) -> Double {
  self.confidence
}

///| 源音频信息
pub struct SourceInfo {
  sample_rate : Int
  channels : Int
  duration_ms : Int
} derive(ToJson, @debug.Debug)

pub extend SourceInfo with ToJson::{to_json}
pub extend SourceInfo with @debug.Debug::{to_repr}

pub fn SourceInfo::new(sample_rate : Int, channels : Int, duration_ms : Int) -> SourceInfo {
  { sample_rate, channels, duration_ms }
}

///| 分析参数（随结果一起输出，保证结果可复现）
pub struct AnalysisParams {
  engine : String
  frame_ms : Int
} derive(ToJson, @debug.Debug)

pub extend AnalysisParams with ToJson::{to_json}
pub extend AnalysisParams with @debug.Debug::{to_repr}

pub fn AnalysisParams::new(engine : String, frame_ms : Int) -> AnalysisParams {
  { engine, frame_ms }
}

///| 汇总统计
pub struct SegmentStats {
  speech_ms : Int
  ratio : Double
} derive(ToJson, @debug.Debug)

pub extend SegmentStats with ToJson::{to_json}
pub extend SegmentStats with @debug.Debug::{to_repr}

pub fn SegmentStats::new(speech_ms : Int, ratio : Double) -> SegmentStats {
  { speech_ms, ratio }
}

///| 完整结果（这就是 CLI 写给 stdout 的东西）
pub struct SegmentsResult {
  version : Int
  source : SourceInfo
  params : AnalysisParams
  segments : Array[Segment]
  stats : SegmentStats
} derive(ToJson, @debug.Debug)

pub extend SegmentsResult with ToJson::{to_json}
pub extend SegmentsResult with @debug.Debug::{to_repr}

pub fn SegmentsResult::new(
  source : SourceInfo,
  params : AnalysisParams,
  segments : Array[Segment],
  stats : SegmentStats,
) -> SegmentsResult {
  { version: 1, source, params, segments, stats }
}

///| 从分段列表与音频总时长直接组装结果（version 恒为 1）
pub fn SegmentsResult::of(
  sample_rate : Int,
  channels : Int,
  duration_ms : Int,
  engine : String,
  frame_ms : Int,
  segments : Array[Segment],
) -> SegmentsResult {
  let speech_ms = total_speech_ms(segments)
  SegmentsResult::new(
    SourceInfo::new(sample_rate, channels, duration_ms),
    AnalysisParams::new(engine, frame_ms),
    segments,
    SegmentStats::new(speech_ms, speech_ratio(segments, duration_ms)),
  )
}

pub fn SegmentsResult::segments(self : SegmentsResult) -> Array[Segment] {
  self.segments
}

pub fn SegmentsResult::source(self : SegmentsResult) -> SourceInfo {
  self.source
}

pub fn SegmentsResult::params(self : SegmentsResult) -> AnalysisParams {
  self.params
}

pub fn SegmentsResult::stats(self : SegmentsResult) -> SegmentStats {
  self.stats
}

pub fn SourceInfo::sample_rate(self : SourceInfo) -> Int {
  self.sample_rate
}

pub fn SourceInfo::channels(self : SourceInfo) -> Int {
  self.channels
}

pub fn SourceInfo::duration_ms(self : SourceInfo) -> Int {
  self.duration_ms
}

pub fn SegmentStats::speech_ms(self : SegmentStats) -> Int {
  self.speech_ms
}

pub fn SegmentStats::ratio(self : SegmentStats) -> Double {
  self.ratio
}

pub fn AnalysisParams::engine(self : AnalysisParams) -> String {
  self.engine
}

pub fn AnalysisParams::frame_ms(self : AnalysisParams) -> Int {
  self.frame_ms
}

pub fn SegmentsResult::to_json_string(self : SegmentsResult) -> String {
  self.to_json().stringify()
}

///|
/// 合并间隔小于 `min_gap_ms` 的相邻段（同一句话里的换气不该被切成两段）。
pub fn merge_close(segs : Array[Segment], min_gap_ms : Int) -> Array[Segment] {
  let out : Array[Segment] = []
  for s in segs {
    match out.last() {
      Some(prev) =>
        if s.start_ms - prev.end_ms < min_gap_ms {
          // 合并：取更低的能量（更保守）与更高的置信度
          out[out.length() - 1] = Segment::new(
            prev.start_ms,
            s.end_ms,
            if prev.rms_dbfs < s.rms_dbfs { prev.rms_dbfs } else { s.rms_dbfs },
            if prev.confidence > s.confidence { prev.confidence } else { s.confidence },
          )
        } else {
          out.push(s)
        }
      None => out.push(s)
    }
  }
  out
}

///| 丢弃过短的段（毛刺）
pub fn drop_short(segs : Array[Segment], min_ms : Int) -> Array[Segment] {
  let out : Array[Segment] = []
  for s in segs {
    if s.duration_ms() >= min_ms {
      out.push(s)
    }
  }
  out
}

///|
/// 前后各补 `pad_ms`，并夹在 [0, limit_ms] 内。
/// 补白是为了不切掉起始辅音和收尾——识别器对首尾敏感。
pub fn pad_segments(
  segs : Array[Segment],
  pad_ms : Int,
  limit_ms : Int,
) -> Array[Segment] {
  let out : Array[Segment] = []
  for s in segs {
    let start = if s.start_ms - pad_ms > 0 { s.start_ms - pad_ms } else { 0 }
    let end = if s.end_ms + pad_ms < limit_ms { s.end_ms + pad_ms } else { limit_ms }
    out.push(Segment::new(start, end, s.rms_dbfs, s.confidence))
  }
  out
}

///| 相邻段补白后可能重叠，重叠即合并
pub fn resolve_overlaps(segs : Array[Segment]) -> Array[Segment] {
  merge_close(segs, 1)
}

pub fn total_speech_ms(segs : Array[Segment]) -> Int {
  let mut total = 0
  for s in segs {
    total = total + s.duration_ms()
  }
  total
}

pub fn speech_ratio(segs : Array[Segment], total_ms : Int) -> Double {
  if total_ms <= 0 {
    0.0
  } else {
    total_speech_ms(segs).to_double() / total_ms.to_double()
  }
}
