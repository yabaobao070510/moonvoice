// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "yabaobao/moonvoice"

version = "0.1.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = ["audio", "speech", "vad", "wav", "resample", "fft", "agent-skill", "wasm"]

preferred_target = "wasm"

description = "纯 MoonBit 语音前端：WAV 编解码 + 高质量重采样 + 三引擎 VAD 分段。零依赖，可在 wasm 沙箱里运行，以 agent 技能形式发布。"

import {
  "moonbit-community/miniio@0.2.1",
}
