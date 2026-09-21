# PROJECT_STATE — moonvoice

> 每完成一步更新本文件；结构锚点（包结构/契约/进度）以此为准。

## 当前状态

- **阶段**：D1–D4 完成（audio / resample / feature / vad+segments 全部实现并测试）
- **赛期**：2026 MoonBit 黑客松 · 九月赛，**2026-09-30 24:00 截止报名与验收**
- **测试**：**60 项 × 三后端（wasm/js/native）全绿**；`moon check` 0 警告
- **剩余**：cmd 技能壳 + SKILL.md + 发布 mooncakes + README/文档 + 浏览器 demo + 开发复盘
- **阻塞项**（需用户本人）：
  1. `moon register` / `moon login`（发布技能必须）
  2. GitHub 公开仓库（报名要填 GitHub ID）
  3. 提交飞书报名表 + 加赛事微信群

## 已完成（按倒排）

| 日 | 内容 | 证据 |
|---|---|---|
| D0 | 工具链安装与验证、仓库骨架、R1/R2 风险打掉 | 三后端可跑 |
| D1 | `audio`：WAV/RIFF 编解码 + 样本表示 | 23 项测试（含 8 项 libsndfile 金标） |
| D2 | `resample`：多相窗函数 sinc 重采样 | 38 项测试（含 scipy 对拍、指标快照） |
| D3 | `feature`：FFT + 功率谱/谱平坦度/谱熵 | 47 项测试（含 numpy 金标） |
| D4 | `vad` + `segments`：三引擎 VAD + 段模型 | 60 项测试（合成基准四类场景） |

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

## 赛事口径（速查，来源：官方赛事页）

- 验收六条：MoonBit 为主语言 / 公开仓库持续提交 / README+可运行示例+必要测试 / 已有项目须本期实质新增 / 开源合规并披露移植来源 / AI 可解释（开发复盘）
- 方向：工具库、数据处理、AI 应用、开发者工具
- 奖励：月度 150+350 元；季度一等奖 12,000（1–2 名）、二等 6,000（3–4）、三等 3,000（5）；季度池 80,000；半年度一等 24,000；年度一等 36,000；单人最高约 7.5 万；晋级季度决赛可免笔试进 MVP 计划（2k–5k/月）
- 硬性流程：报名需提交参赛信息 + 公开仓库 + 一页项目说明；**必须加入赛事交流群**（否则影响奖金）
- 报名入口：飞书表单 `https://bxup9uklfcb.feishu.cn/share/base/form/shrcnWUMlgpbwHaXgzV7HmNhNhg`
- 赛事章程：`https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd`

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

## 9 天冲刺清单

- [ ] D0 装工具链 → `moon new` → 最小 wasm skill 跑通 `moon runwasm` → 试 `moon publish`
- [ ] D0 建公开 GitHub 仓库 + 报名 + 加赛事群
- [ ] D1 `audio` 包：WAV 读写 + 单测 + golden 脚本骨架
- [ ] D2 `resample`：多相 sinc，对拍 scipy SNR ≥ 60 dB
- [ ] D3 `vad` E1+E2
- [ ] D4 E3 + 三引擎融合，对拍 webrtcvad ≥ 90%
- [ ] D5 `cmd/vad`、`cmd/resample` + SKILL.md + 发布 + 云端验证
- [ ] D6 真实数据回归 + 基准 + README + `moon doc`
- [ ] D7 浏览器 demo（或终端 GIF）
- [ ] D8 开发复盘 + 申报材料 → **冻结**
- [ ] D9 验收提交（上午）

## 契约（冻结前可改）

- 输出 JSON：`{"version":1,"source":{...},"params":{...},"segments":[{"start_ms","end_ms","rms_dbfs","confidence"}],"stats":{...}}`
- 技能调用：`moon runwasm <user>/moonvoice/cmd/vad -- <opts> < in.wav > segments.json`
