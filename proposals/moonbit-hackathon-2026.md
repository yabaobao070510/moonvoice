# moonvoice — 2026 MoonBit 黑客松（九月赛）选题方案

- 状态：**待用户评审**（评审通过后由用户写入 `SPEC.md`，AI 不擅自开工编码）
- 日期：2026-09-21
- 赛期：2026-09-01 ~ 2026-09-30（**报名与项目验收同为 9/30 24:00 截止**，剩 9 天）
- 选手：乔禹森

---

## 0. 一句话立意

> 语音处理在 MoonBit 生态里还停留在"能解码"，没有"能分析"；而现有分析路径（whisper.cpp / rodio）全是 C 绑定，**在 wasm 沙箱里根本跑不起来**。
> moonvoice 用纯 MoonBit 把「任意音频 → 可直接送进识别器的语音段与特征」做成零依赖、可沙箱运行的 agent 技能。

**为什么这个立意只有 MoonBit 能做**（语言特点 → 立意的因果链，不是贴标签）：

| MoonBit 特点 | 事实状态 | 对本题的意义 |
|---|---|---|
| 同一份源码 → wasm / wasm-gc / js / native | 稳定版 v0.10.13（2026-09-15） | 一份实现同时服务浏览器、CLI、沙箱 |
| 默认 wasm 沙箱：无 fs / 无网络 | skills.mooncakes.io 预构建 wasm + wasm-opt | **用户音频不出本机**，agent 可安全调用 |
| 语言级技能市场（SKILL.md + `moon runwasm`） | 市场实测仅 **22 个**技能 | 生态位空，且官方在押注 |
| 纯 MoonBit 无 FFI | whisper 只有 C 绑定（仅 native）；moon_rodio 明写 native-only | **纯实现是唯一能进沙箱的路径** |

---

## 1. 缺口证据（2026-09-21 对 mooncakes.io registry 实测）

| 关键词 | 命中 | 说明 |
|---|---|---|
| `vad` / `voice activity` | **0** | 语音活动检测完全空白 |
| `resample` | **0** | 无重采样实现 |
| `loudness` | **0** | 无 EBU R128 响度 |
| `mel` | **0** | 无 mel 特征 |
| `spectrogram` | 2（dl=8、16） | hwlxmm/dsp、HK-SHAO/dsp，迷你库 |
| 音频类包 | 全部是**解码/播放** | moon-wav、moonwavkit、moonvorbis、mizchi/audio |

**生态全景**（同日实测）：2,552 模块 / 23,369 包 / 3,454 万行 / 729 万下载。
**红海警告**：JSON Schema 校验器 ≥5、MCP ≥4、向量库 ≥3、RAG ≥4、agent 框架 ≥3，下载量普遍 5–600 —— 月度黑客松已催生大量"移植型"浅项目，**进去就是同质竞争**。
**官方口味信号**（社区周报"本周优质包"）：公开规范的完整实现 + 完整测试（JVMS ClassFile、WebIDL、PDF 2.0、MIDI SMF 均按此轨迹上榜）。

---

## 2. 产品定义

**做**：把一段音频变成"可识别"的形态。

```
WAV/FLAC 读入 → 单声道化 → 重采样(16k) → VAD 语音段切分 → 片段 JSON / 响度 / mel 特征
```

**以 agent 技能分发**：每个能力 = 一个 wasm skill，stdin 进、stdout 出，零依赖、沙箱内可跑。

**不做**（边界，防摊薄）：
- 不做 ASR 本身（不做识别模型，只做识别前端）
- 不做编码器/播放器（解码已有 moon-wav / moonvorbis）
- 不做神经网络 VAD（Silero 需 ONNX 权重，超出 9 天且违背"零依赖"卖点）

---

## 3. 技术方案

### 3.1 包结构（模块 `moonvoice`，一模块多包）

| 包 | 类型 | 内容 | 优先级 |
|---|---|---|---|
| `moonvoice/audio` | lib | RIFF/WAV 读写：PCM 8/16/24/32、float32、多声道、任意采样率；单声道化、分帧 | P0 |
| `moonvoice/resample` | lib | 多相窗函数 sinc 重采样，任意比率，抗混叠 | P0 |
| `moonvoice/vad` | lib | 三引擎 + 融合（见 3.2） | P0 |
| `moonvoice/segments` | lib | 语音段时间轴模型：合并/切分/最短时长/前后补白；JSON 输出 | P0 |
| `moonvoice/loudness` | lib | ITU-R BS.1770-4 K 加权 + EBU R128 门限 LUFS | P1 |
| `moonvoice/feature` | lib | FFT(radix-2) → STFT → mel 滤波器组(Slaney) → log-mel | P1 |
| `cmd/vad` | exec/skill | stdin WAV → stdout 片段 JSON | P0 |
| `cmd/resample` | exec/skill | stdin WAV → stdout 16k 单声道 WAV | P0 |
| `cmd/lufs`、`cmd/mel` | exec/skill | 同上模式 | P1 |

### 3.2 多方案并行测试与融合（核心方法论）

**VAD 三引擎全部实现，实测后融合，不投票淘汰**：

| 引擎 | 原理 | 预期优势 | 预期短板 |
|---|---|---|---|
| E1 自适应能量+过零率 | 噪声底自适应 + 迟滞 | 快、鲁棒于平稳噪声 | 音乐/突发噪声误判 |
| E2 谱平坦度/谱熵 | 谐波性判别 | 抗稳态噪声 | 清辅音漏检 |
| E3 GMM 频带模型（WebRTC 风格） | 6 频带 GMM 似然比 | 精度最高、有公开参照可对拍 | 移植工作量大、授权披露 |

**融合策略**：以 E1 的能量包络做**候选门控**（快速筛掉静音，省算力），E2/E3 在候选区内做**判决**，再叠 hangover/最短时长平滑。融合点在帧级得分层完成（不是事后投票），逐条记录"为什么这样融"——直接成为赛事要求的**开发复盘**素材。

**重采样**：多相 FIR（窗函数 sinc，Kaiser 窗），48k→16k 为 3:1 整数抽取特例（可退化到单级多相，零相位失真最小）。

### 3.3 验证策略（评委明确关心"测试质量"——这是我们的差异化）

1. **金标对拍（golden）**：Python 侧用 scipy / librosa / pyloudnorm / webrtcvad 生成参考向量 → 入库 `goldens/` → MoonBit 测试断言：
   - 重采样：与 `scipy.signal.resample_poly` 对比 **SNR ≥ 60 dB**
   - LUFS：与 `pyloudnorm` 偏差 **≤ 0.1 LU**
   - mel：与 `librosa.feature.melspectrogram` 偏差 ≤ 1e-3
   - VAD：与 `webrtcvad` 帧级一致率 **≥ 90%**（同一批 fixture）
2. **真实音频回归**：自有版权短音频 → 期望片段 JSON 快照测试
3. **属性测试**：1:1 重采样恒等；纯静音/纯音/类语音合成信号的行为断言
4. **跨后端一致性**（P1）：同一 fixture 在 native 与 wasm 下输出 diff
5. **性能基准**：重采样 Msamples/s、VAD 实时率、wasm 体积（README 给出数字）

### 3.4 接口契约

```
# wasm skill 形态（沙箱内，stdin/stdout）
moon runwasm <user>/moonvoice/cmd/vad -- --min-silence 300 < in.wav > segments.json

# native 形态（开发者本机）
moon run cmd/vad -- in.wav --out segments.json
```

输出 JSON（稳定契约，写进 README 与 SKILL.md）：

```json
{"version":1,"source":{"sample_rate":16000,"channels":1,"duration_ms":12345},
 "params":{"engine":"fused","frame_ms":30},
 "segments":[{"start_ms":120,"end_ms":3420,"rms_dbfs":-21.3,"confidence":0.91}],
 "stats":{"speech_ms":8100,"ratio":0.66}}
```

### 3.5 风险与退路

| # | 风险 | 处理 |
|---|---|---|
| R1 | **wasm 沙箱内二进制 stdin 是否可用**（未经验证） | **D0 必验**；退路：文件路径参数（native）+ base64/hex 文本 stdin（wasm） |
| R2 | `moon.pkg` 目标声明写法（`is-main` vs `pkgtype`）与 `runwasm` 实际行为 | D0 以 `moon help` + 实跑为准，**不凭记忆写** |
| R3 | E3 GMM 移植超时 | E1+E2 融合即为主引擎，E3 降级为 stretch；对拍仍保留 |
| R4 | 9 天内用户有课/学生工作 | AI 先并行产出文档/测试/脚本，用户只做 review 与决策 |
| R5 | 音频测试数据版权 | 只用自录/合成音频，LICENSE 内注明来源 |

**许可证**：Apache-2.0（生态主流，`moon.mod` 用 SPDX 声明）。若移植 WebRTC VAD：**必须**在 README 与源文件头披露 BSD-3 来源与许可，符合赛事"开源合规/披露来源"要求。

---

## 4. 9 天倒排（D0=9/21，截止 9/30）

| 日 | 任务 | 出口标准 |
|---|---|---|
| **D0 9/21** | ①装工具链 ②`moon new` 建项目骨架 ③**最小 wasm skill 跑通 `moon runwasm`** ④试 `moon publish` ⑤建公开 GitHub 仓库 ⑥**报名（含一页说明）+ 加赛事群** | R1/R2 结论落地；仓库公开；报名完成 |
| D1 9/22 | `audio` 包：WAV 读写 + 单测 + golden 生成脚本骨架 | WAV 往返测试绿 |
| D2 9/23 | `resample`：多相 sinc + 对拍 scipy（SNR≥60dB） | 对拍数字进 README |
| D3 9/24 | `vad` E1+E2 实现，接真实音频 | 段级输出可视化可看 |
| D4 9/25 | E3 GMM（或降级）+ **三引擎融合** + 对拍 webrtcvad ≥90% | 融合策略写清"为什么" |
| D5 9/26 | `cmd/vad`、`cmd/resample` CLI + SKILL.md；发布 mooncakes；云端验证 `moon runwasm` | 技能市场上线可跑 |
| D6 9/27 | 真实数据回归 + 性能基准 + README + `moon doc` | README 数字齐全 |
| D7 9/28 | 浏览器 demo（WAV 拖入看片段）或降级终端 GIF | demo 可演示 |
| D8 9/29 | `loudness`/`feature`（若前面提前）+ **开发复盘** + 申报材料；**材料冻结** | 冻结，不再动代码 |
| D9 9/30 | 验收提交（上午交，不留到 23:59） | 提交完成 |

**关键路径**：D0 的 R1/R2 验证 → 若不通过，整个"wasm skill 分发"叙事要换形态，必须最先打掉。

---

## 5. 交付清单（逐条对应赛事验收标准）

| 赛事要求 | 我们的对应物 |
|---|---|
| MoonBit 为主实现语言 | 全部代码纯 MoonBit，零 C 依赖 |
| 仓库公开 + 连续提交记录 | GitHub 公开仓库 + 每日 commit + Issues 驱动 + 小 PR |
| README + 可运行示例 + 必要测试 | README（含性能数字）、`examples/`、单测 + 金标对拍 + 属性测试 |
| 已有项目须有本期实质新增 | 本项目为全新项目 |
| 开源合规 + 移植披露 | Apache-2.0；E3 若移植 → BSD-3 披露 |
| AI 可解释（开发复盘） | `docs/retrospective.md`：关键架构决策 + 三引擎评测数据 + AI 工具起的作用 |
| 用户体验 | 技能形态（一条命令）；浏览器 demo；JSON 稳定契约 |

---

## 6. 一页项目说明（报名用，可直接提交）

> **moonvoice — 纯 MoonBit 语音前端工具包**
>
> 目标用户是"需要处理语音但要保持数据不出本机"的开发者与 AI agent 作者。
> 现在要做语音处理，绕不开 whisper.cpp / rodio 这类 C 绑定库——它们只能原生运行，进不了 WebAssembly 沙箱；而 MoonBit 生态里音频只有解码器（moon-wav、moonvorbis），分析层完全空白（registry 实测：`vad`/`resample`/`loudness`/`mel` 四个关键词命中数均为 0）。
>
> moonvoice 用纯 MoonBit 实现语音前端：WAV 读写 → 重采样 → VAD 语音段切分 → 片段 JSON / 响度 / mel 特征，并以 agent 技能形式发布到 skills.mooncakes.io。同一份代码在浏览器、命令行和 wasm 沙箱里运行，零依赖、无文件系统与网络访问，音频数据不离开调用方。
>
> 工程重点在"可验证"：重采样与 `scipy.signal.resample_poly` 对拍 SNR ≥ 60 dB，响度与 `pyloudnorm` 偏差 ≤ 0.1 LU，VAD 与 `webrtcvad` 帧级一致率 ≥ 90%。VAD 并行实现能量/谱/统计模型三种引擎，实测后做帧级融合，全过程记录在开发复盘中。
>
> 交付：MoonBit 库 + 可运行技能（`moon runwasm`）+ 测试与金标对拍 + 浏览器演示。

---

## 7. D0 待验证清单（**不猜 API，全部实跑确认**）

1. `moon version` / `moon help` 实际子命令；确认 `runwasm` 存在与其参数形态
2. `moon.pkg` 目标声明：`pkgtype(kind:"executable")` 还是 `is-main`；wasm 目标声明字段
3. wasm 后端能否读 **二进制 stdin**；`miniio` 或 `wasip1` 是否是必要依赖
4. `moon publish` 账号/命名规则（`moon register` → 模块名可否用 `moonvoice`）
5. `moon test` 在 wasm/native 下的差异；golden 文件如何被测试读取

---

## 8. 待用户确认

1. **选题与方案是否通过**（通过后请写入 `SPEC.md`，我按 SPEC 实现）
2. **是否现在执行 D0**：安装工具链（Windows PowerShell 官方一键脚本 `irm https://cli.moonbitlang.com/install/powershell.ps1 | iex`，会写入 `~/.moon` 并改 PATH）
3. **GitHub 仓库名与账号**（报名要填 GitHub ID；建议仓库名 `moonvoice`）
4. **是否要我代拟报名表填写内容**（赛事交流群需本人微信加入）
