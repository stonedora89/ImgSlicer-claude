# ImgSlicer 接口架构 & 性能效率 Roadmap（落在现有实现上）

> 第三份 roadmap，**不替代** `m4-accuracy-roadmap.md` 与 `edge-accuracy-roadmap.md`。
> 前两者讲准确度；本文件讲**代码接口/架构**与**运行性能/效率**，两条轴与准确度并行推进。
> 所有结论锚定真实代码（`Sources/ImgSlicer/` 为主）。

---

## 0. 现状量化（事实，非估计）

| 文件 | 行数 | 问题 |
|---|---|---|
| `ImageProcessor.swift` | **3962** | god-object，163 个方法：IO/缓冲/6+ 检测家族/评分/合并/拆分/精修/几何全在一起 |
| `AppStore.swift` | 1022 | 状态 + 持久化 + 检测编排 + 样本库混在一起 |
| `AppShell.swift` | 1556 | 单文件巨型视图 |
| `CropDetectionPipeline.swift` | 105 | stage 调度——**好的接缝，但被低估** |

**接口现状**
- 检测器签名各自为政：`detectByProjectionSeparators(gray:width:height:settings:)`、
  `detectByDarkGutters(luminances:…)`、`detectFilmFrames(luminances:…)`…**无统一协议**。
- `detectCropCandidates`（:91）内用 `preprocessModes × stages` 双重循环编排（:163-176），
  检测家族与编排逻辑耦合在一个超大函数里。
- 公有/可见方法 ~45 个，公共 API 边界不清。

**性能现状**
- 已有：下采样分析宽度 `performance.maxAnalysisWidth`（:98）、luminance 缓冲 memoize（:118、:165）、
  早停标志 `shouldStopDetection`（:162）、并发 `maxConcurrentTasks=3`（`AppStore`）。
- 短板：
  - `NSImage(contentsOf:)`（:92）**整图全解码**后再下采样——几千张时解码占大头。
  - **零 Accelerate/vDSP/simd**：所有行列投影、均值、方差、阈值都是标量循环。
  - `preprocessModes × stages` 多轮全图重扫，每个检测器各自 O(面积) 扫描。
  - luminance 用 `[Double]`（:127/:171），每像素 8 字节，分析缓冲内存偏大。
  - `editStore.save` 调用频繁（如边距重烘焙每次落盘），磁盘写放大。
  - 外部 Python 检测器按图起子进程，开销大。

---

## 1. 两条轴、与准确度的关系

- **接口/架构轴**：把 god-object 拆成有边界的模块，定义统一检测器协议与共享上下文。
  这条轴**同时服务准确度**（`edge-accuracy-roadmap.md` 的 P5「候选统一+集中评分」依赖它）。
- **性能/效率轴**：减少解码、向量化热点、整合像素表（integral image）、控制重复扫描与落盘。
- **共同前提**：两条轴都属"重构 / 等价变换"，**必须被 P0 评测 + 现有测试守住**，否则容易静默回退。
  - 现有测试：`Tests/ImgSlicerTests/FilmDeskewValidationTests.swift`（去斜/角度）。重构前应补几条检测快照测试。

---

## 接口/架构轴

### A0 — 重构安全网（前置）
**目标**：让"等价重构"可验证。
**工作项**
- 复用 `edge-accuracy-roadmap.md` 的 **P0 逐边评测**作为行为基线。
- 为 2–3 个代表图加**检测结果快照测试**（regions 数量 + 关键边坐标），重构前后必须一致。
**验收**：重构后 benchmark + 快照零变化。

### A1 — 统一 `DetectionContext`（消灭满天飞的参数）
**目标**：用一个值类型承载共享数据，替代到处传 `(gray, width, height, settings)`。
**现状**：`baseGray`、`luminances()`、`width/height`、`settings` 在 100+ 函数间手动传递。
**工作项**
- 定义 `struct DetectionContext { gray: [UInt8]; width; height; scale; settings; lazy luminances; lazy integral }`。
- 缓冲只算一次，按需懒加载（把现有 `cachedLuminances` 逻辑收进来）。
- 检测器签名统一为 `func generate(_ ctx: DetectionContext) -> [CropCandidate]`。
**验收**：检测器入参从 4+ 降到 1；缓冲计算次数不增。
**风险**：一次性改面大 → 先并存适配层，逐个迁移。

### A2 — `CropCandidateGenerator` 协议（家族即插件）
**目标**：把 6+ 检测家族变成实现同一协议的独立类型，`CropDetectionPipeline` 只负责编排。
**现状**：`detectByProjectionSeparators` / `detectByDarkGutters` / `detectFilmFrames` /
`detectForegroundComponents` / `detectLocalContrastComponents` / `detectWithVision` / `detectWithExternalDetector`。
**工作项**
- 定义 `protocol CropCandidateGenerator { var stage; func generate(_:) -> [CropCandidate] }`。
- 每个家族抽到 `Detectors/` 下独立文件，实现协议。
- `detectCropCandidates` 的双重循环简化为"对启用的 generators 收集候选"。
**验收**：`ImageProcessor.swift` 显著瘦身；新增检测家族无需改编排代码。
**对接准确度**：直接支撑 `edge-accuracy-roadmap.md` P5 候选统一。

### A3 — 模块拆分（纯机械搬运，零逻辑改动）
**目标**：把 god-object 拆成职责清晰的文件/类型。
**建议切分**
- `ImageBuffers`（IO + 解码/下采样 + gray/luminance/integral）
- `Detectors/*`（A2 的各家族）
- `Refinement`（`trimWhiteEdge` / `snapVerticalBoundaries` / `locallyRefinedEdges` / `splitMergedFrames`）
- `Scoring`（`score` / `alignmentScore` / `areaConsistencyScore` / `edgeReliabilities`）
- `GridGeometry`（`regularizeStripGrid` / `gridFallbackUnreliableEdges` / `completeGridLattice`）
**工作项**：一次搬一组，每次 benchmark + 快照零变化才提交。
**验收**：单文件 < ~800 行；职责单一。

### A4 — 收敛公共 API
**目标**：明确对外接口，其余降为 internal/private。
**工作项**：保留 `detectCropCandidates`、CLI 入口（`--evaluate`/`--compare-algorithms`/`--export-overlay`）等少量公共面；其余收口。
**验收**：公共方法数从 ~45 降到个位数。

---

## 性能/效率轴

### B0 — 性能基线（前置）
**目标**：性能改动可量化、防回退。
**工作项**
- 在 P0 评测里加 **单图平均 latency + P95** 与**分阶段耗时**（解码 / 各检测家族 / 精修 / 评分）。
- 加 `--bench <folder>` 输出吞吐（images/s）与峰值内存。
**验收**：得到 baseline 数字；后续每个 B 阶段对照它。

### B1 — 解码即下采样（最高性价比）
**目标**：消除"全解码再缩小"。
**现状**：`NSImage(contentsOf:)`（:92）全解码，再 `context.draw` 到 `maxAnalysisWidth`（:115）。
**工作项**
- 改用 `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize = maxAnalysisWidth`，
  **一步解码到分析尺寸**；全分辨率仅在 P3 局部精修时按窗口区域读取（`CGImageSourceCreateImageAtIndex` 裁剪）。
**验收**：单图解码耗时与峰值内存显著下降（大图尤甚）。
**风险**：缩略图采样质量 → 校验 benchmark 不回退。

### B2 — 热点向量化（Accelerate/vImage/vDSP）
**目标**：把标量像素循环换成 SIMD。
**现状**：零 Accelerate；行列投影/均值/方差/阈值都是 for 循环。
**工作项**
- gray 转换用 `vImage`；行/列投影、`darkDensity`、`classify` 的 mean/std 用 `vDSP`。
- 优先改最热的：`detectByDarkGutters` 行列暗密度（:3547-3560）、projection rows/cols、`snapVerticalBoundaries.classify`。
**验收**：相关阶段耗时下降（用 B0 分阶段计时定位）。

### B3 — 积分图（Integral Image / 行列前缀和）
**目标**：把大量"区域/带的 mean/var"从 O(面积) 降到 O(1)。
**现状**：`trim*` / `snap*` / `score` / `contentBands` 反复对带或框做求和、计数。
**工作项**
- 在 `DetectionContext`（A1）里预计算 **summed-area table**（和、平方和）。
- 让上述函数改用积分图常数时间查询。
**验收**：trim/snap/score 阶段耗时下降；结果与基线一致。

### B4 — 控制重复扫描 + 候选池截断
**目标**：减少 `preprocessModes × stages` 的浪费。
**现状**：每个 preprocess 变体被多个检测家族全图重扫；已有 `shouldStopDetection`（:162）未充分利用。
**工作项**
- 代价感知早停：高置信候选出现即停后续昂贵家族（强化 `shouldStopDetection`）。
- 进入精修前**截断候选池**（top-K），对接准确度 roadmap P5。
**验收**：平均家族执行数下降，准确度不回退。

### B5 — 内存与数据表示
**目标**：降低分析缓冲内存。
**工作项**：luminance 由 `[Double]` 改 `[Float]` 或直接基于 `[UInt8]` gray + 积分图；避免每 preprocess 模式复制大数组。
**验收**：峰值内存下降；几千张批处理更稳。

### B6 — 落盘与并发
**目标**：减少磁盘写放大，吃满 M4 多核。
**工作项**
- `editStore.save` **去抖/批量**（拖动结束或定时落盘，而非每 tick）。当前 `reapplySelectedCandidateMargins` 批量重烘焙会逐张保存，是典型放大点。
- 并发度按核数自适应（现 `maxConcurrentTasks=3` 写死）。
**验收**：批处理吞吐提升；UI 拖动不卡。

### B7 — 外部 Python 仅作 fallback
**目标**：降低子进程开销与生产依赖。
**工作项**：`ExternalDetector` 退为低置信 fallback（对接准确度 P5 置信门控）；如需保留，改持久 worker 而非每图起进程。
**验收**：主路径不再依赖 Python；端到端吞吐提升。

---

## 推进顺序与"现在就做"

> 两条轴都以"等价重构"为主，**必须先有 A0/B0 安全网 + 准确度 P0 评测**。

1. **A0 + B0 + 准确度 P0** —— 三个基线/安全网先建（可合并为一次评测扩展）。
2. **B1（解码即下采样）** —— 性能侧最高性价比、风险低，先落。
3. **A1 + A2（DetectionContext + Generator 协议）** —— 接口侧地基，**同时服务准确度 P5**。
4. 之后并行：A3/A4（拆分收口）与 B2/B3（向量化+积分图）。
5. B4/B5/B6/B7 收尾。

**最高优先：把 A0/B0 并进准确度 P0 的同一次评测扩展里**——一份 `--evaluate`/`--bench` 同时产出
准确度（逐边误差）+ 性能（latency/吞吐/内存）+ 重构回归（快照）三类信号，后续所有改动共用这一把尺子。

---

## 与另外两份 roadmap 的关系

- 准确度（`edge-accuracy-roadmap.md`）：P5「候选统一+集中评分」**依赖**本文件 A1/A2。
- 长期架构（`m4-accuracy-roadmap.md`）：Phase 6「Apple Silicon 原生收敛」与本文件 B2/B3/B7 同向。
- 三份共用**同一套 benchmark/bench 工具**，避免各测各的。

---

## 指标

- 单图平均 / P95 latency，分阶段耗时
- 吞吐（images/s）、峰值内存
- 重构回归：benchmark 逐边误差 + 检测快照**零变化**
- 代码健康：最大文件行数、god-object 方法数、公共 API 数（逐阶段下降）
