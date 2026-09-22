# PROJECT_STATE — moonvoice

> 每完成一步更新本文件；结构锚点（包结构/契约/进度）以此为准。

## 当前状态

- **阶段**：**交付就绪**（五个库包 + 三个技能 + SKILL.md + README + 开发复盘）
- **交付截止**：2026-09-30
- **测试**：**89 项 × 四后端（wasm / wasm-gc / js / native）全绿**；`moon check --deny-warn` 零警告
- **发布链路**：`moon package` 已验证通过（产物 `_build/publish/yabaobao-moonvoice-0.1.0.zip`），
  只差 `moon register` 账号即可 `moon publish`
- **剩余**：发布 mooncakes（需账号）；v0.2 路线图：语音增强（降噪，基于现有 STFT/VAD 原语；v0.1 明确不做——见决策记录）、基础库扩展（流式/PCM/FLAC）
- **阻塞项**（需用户本人）：GitHub 公开仓库；mooncakes 账号；报名流程

## 已完成（按倒排）

| 日 | 内容 | 证据 |
|---|---|---|
| D0 | 工具链安装与验证、仓库骨架、R1/R2 风险打掉 | 三后端可跑 |
| D1 | `audio`：WAV/RIFF 编解码 + 样本表示 | 23 项测试（含 8 项 libsndfile 金标） |
| D2 | `resample`：多相窗函数 sinc 重采样 | 38 项测试（含 scipy 对拍、指标快照） |
| D3 | `feature`：FFT + 功率谱/谱平坦度/谱熵 | 47 项测试（含 numpy 金标） |
| D4 | `vad` + `segments`：三引擎 VAD + 段模型 | 合成基准四类场景 |
| D5 | `cmd/vad`、`cmd/resample` 技能 + SKILL.md + README | 端到端实测 + libsndfile 复核 |
| D5+ | `feature` 扩展：窗函数/STFT/mel/MFCC/双二阶/EBU R128 响度 | 对拍 librosa / pyloudnorm |
| D5+ | `cmd/loudness` 第三个技能 + 开发复盘 + 一页说明 | 89 项测试四后端全绿 |

### VAD 关键实测（详见 vad/vad.mbt 注释）

- **谱平坦度标尺**：单帧周期图下白噪声 GM/AM 期望 = e^-γ ≈ 0.56（每 bin 指数分布）。
  实测语音 0.19~0.28、白噪 0.54~0.56 → 否决阈值 0.5、奖励参考 0.2，全部按实测定。
- **噪声底**：语音期冻结 + 初值取全局最小 + 下分位均值估计噪声水平（最小值偏低 3~4 dB）。
- **融合价值**：突发噪声场景 fused 79.7% > energy 74.4% > spectral 40.6%。
- **调参方法论教训**：单种子调参会过拟合（调参说 0.917、换种子实测 0.789）；
  改为最差场景目标 + 多种子 + 边界容差（collar 宽度 = 设计上的 hangover 宽度）。
- **主指标用精确率/召回率**：两类错误代价不同，准确率会把它们平均掉。

## D0 结论（2026-09-21，全部实跑验证）

| 项 | 结论 |
|---|---|
| 工具链 | moon 0.1.20260920（2026-09-20）装于 `~/.moon`；Windows 装在 PATH 需重开终端 |
| **R2** `runwasm` | **已废弃**。官方口径：本地 `moon run --target wasm`，registry 包用 **`moonx <module>/<pkg>@<ver>`**（moonx.exe 随工具链安装） |
| **R1** wasm 二进制 stdin | **通过**：`miniio.stdin.read_all().binary()`，4112 字节流 len/sum/hash/首尾字节与 Python 计算完全一致 |
| 后端能力 | wasm / js / native 三后端均可编译（native 走 MSVC，本机有） |
| **miniio 限制** | **只支持 wasm 后端**（`supports [wasm]`）→ **架构定调：库包后端无关（不依赖 miniio），仅 cmd 薄壳用 miniio** |
| 配置格式 | 新格式：`moon.mod` 用 TOML（`preferred_target`/`license`/`repository`…）；`moon.pkg` 用 `pkgtype(kind: "executable")`，库包可空 |
| 产物 | `_build/wasm/debug/build/<pkg>/<pkg>.wasm`（hello world debug 4.7 KB） |
| 多技能布局 | 一模块多 main 包 = `cmd/vad`、`cmd/resample`，与生态一致（如 `mizchi/markdown/cmd/mmmd`） |
| 快速试验 | `moon run -c '<带 import 头的源码>'` 可免建包直接跑（spike 用此法） |

**Int32 陷阱**：Int 是 32 位有符号，`h*31+v` 这类累乘会溢出回绕（不是报错）。哈希/累加类代码要显式取模收窄。

## 关键事实（2026-09-21 实测，改动需重测）

- mooncakes.io：2,552 模块 / 23,369 包 / 3,454 万行 / 729 万下载
- skills.mooncakes.io：已发布技能 **22 个**（含 `moonbit-community/meta-skill` 脚手架、`miniio` WASI I/O）
- 缺口实测（命中数）：`vad`=0、`voice activity`=0、`resample`=0、`loudness`=0、`mel`=0
- 竞争红海（勿入）：JSON Schema ≥5、MCP ≥4、向量库 ≥3、RAG ≥4、agent 框架 ≥3
- 音频现状：仅解码/播放（moon-wav、moonwavkit、moonvorbis、mizchi/audio）；whisper 仅 C 绑定（native-only）
- MoonBit：稳定版 v0.10.13（2026-09-15）；1.0 计划 2026 年内；`moon runwasm` 自 v0.10.0 起为实验性命令
- 安装（Windows，需先有 git）：`Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm https://cli.moonbitlang.com/install/powershell.ps1 | iex`

## 决策记录

| 日期 | 决策 | 理由 |
|---|---|---|
| 2026-09-21 | 选题 = 纯 MoonBit 语音前端工具包（A 案） | 缺口实测为 0；用户有配音/ASR/对话段识别实战优势；C 绑定路线进不了 wasm 沙箱，纯实现是结构性机会 |
| 2026-09-21 | 打 9 月赛（9 天冲刺） | 用户选择；季度划分 8–10 月，9/30 前验收即进第一赛季度池 |
| 2026-09-21 | 许可证 Apache-2.0 | 生态主流；若移植 WebRTC VAD 需 BSD-3 披露 |
| 2026-09-21 | 不碰红海方向 | registry 实测同质竞争严重，避免"移植型"浅项目 |
| 2026-09-21 | 不写代码前先验证 wasm stdin / runwasm / publish | R1/R2 是叙事前提，D0 必须先打掉 |
| 2026-09-22 | 定位收窄：定位为"语音活动 / 格式 / 电平 / 特征"前端，明确不做语音增强；演示页移除复杂噪声场景（只留办公室 + 上传） | 实测：强噪声下无有效噪声底可跟踪 → 判定退化为全语音（公交/街道 99–100%）；降噪无权威金标参照、工期风险高 → v0.2 |

## 契约（冻结前可改）

- 输出 JSON：`{"version":1,"source":{...},"params":{...},"segments":[{"start_ms","end_ms","rms_dbfs","confidence"}],"stats":{...}}`
- 技能调用（registry 包）：`moonx <user>/moonvoice/cmd/vad -- <opts> < in.wav > segments.json`
- 技能调用（本地开发）：`moon run --target wasm cmd/vad -- <opts> < in.wav`
