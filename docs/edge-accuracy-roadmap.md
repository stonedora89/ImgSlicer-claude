# ImgSlicer 边缘准确度优化 Roadmap（落在现有实现上）

> 本文件是对 `m4-accuracy-roadmap.md` 的补充，**不替代**它。
> 前者是长期架构方向；本文件聚焦"在当前代码基础上，分阶段提升边缘/主体识别准确度"，
> 每条都锚定到现有函数（`Sources/ImgSlicer/ImageProcessor.swift` 为主），避免架空。

---

## 0. 问题与诉求（来自实际使用）

**痛点**
1. 照片边缘风格多样（暗 gutter / 白边框 / 几乎无边）
2. 色彩风格变化大
3. 颜色、曝光参差不齐
4. 照片类型与画质差异大
5. 同一画布内可能有多种曝光程度
6. 边距不固定、分隔颜色不确定
7. 设备来源多（哈苏 / 柯达 / 富士 …），边框/齿孔风格各异
8. 因边距或光线，两张照片被合并，或识别串到相邻照片

**诉求**
1. 主体识别准确，**尤其是边缘**
2. 需要切割的主体不遗漏、不多切
3. 能根据照片实际情况，有多种识别方式
4. 边缘有毛刺/不齐时仍要准
5. 不能因光线变化把主体切掉
6. 不能因边距/光线把两张照片合并或串到相邻

---

## 1. 总根因（必须先认清）

当前检测的**分隔区（gutter）判定，默认"暗 + 平、且只看亮度"**，且大量使用**绝对阈值**：

- `snapVerticalBoundaries`（`ImageProcessor.swift:1660`）：`darkMax = 70`、`textureMin = 22`、`stretchedStd <= 15`（:1664–1701）。
- `detectByDarkGutters`（:3541）：`darkCutoff` 取 18% 分位（:3543），`contentBands` 中 `value > 0.55` 判 gutter（:3597）。
- `detectProjectionRows`（:1865）/ `detectColumnsInRow`（:1935）同源思路。

已有的缓解：`snapVerticalBoundaries` 做了**逐帧 auto-levels**（2–98% 拉伸，:1717–1730），方向正确——
但**只在这一处**，且仍只看亮度、仍假设 gutter 偏暗。

> 结论：痛点 1/2/3/5/6/7/8 的大部分，根子是这**一个假设**。
> 因此 roadmap 的主线 = **把"分隔判定"做成 极性无关 + 颜色感知 + 相对化/分块**，并以**逐边评测**驱动。

---

## 2. 阶段总览

| 阶段 | 主题 | 主要解决 | 风险 |
|---|---|---|---|
| P0 | 逐边评测 benchmark | 让一切可量化（前置，不可跳） | 低 |
| P1 | 统一 `separatorScore`（极性无关+颜色感知） | 1,2,6,7,8 / 诉求5,6 | 中 |
| P2 | 阈值相对化 + 分块归一化 | 3,5 / 诉求5 | 中 |
| P3 | 逐边局部精修（亚像素+直线拟合） | 诉求1,4 | 中 |
| P4 | 几何兜底（切分/补全/防合并） | 6,8 / 诉求2,6 | 低 |
| P5 | 候选统一 + 集中评分 + 置信门控 | 4 / 诉求2,3 | 中 |
| P6 | 厂商/边框风格泛化验证 | 1,7,8 | 低 |
| P7（可选） | 轻量学习排序 | 仅当 ranking 成瓶颈 | 高 |

> 原则：**P0 先行**；P1/P2 是根因；P3 直接提边缘精度；P4 用现有几何能力兜底；P5 收口；P6 验证泛化。

---

## P0 — 逐边评测 Benchmark（前置，不可跳）

**目标**：在改任何算法前，让"边缘准不准"可量化、回归可见。

**现状**：`AlgorithmComparisonCommand`（`Processing/AlgorithmComparisonCommand.swift`）只有
`--compare-algorithms`（Swift vs Python 互比 IoU，:299-303）、`--export-overlay`、`--detect-count`，
**没有与 ground truth 比**，更没有逐边误差。

**工作项**
- 真值来源：直接用 App 的**手动修正 + 保存**（`CropEditStore.save`）。手动把框拖到像素级正确，保存即真值，**不另造标注系统**。
- 新增 CLI 模式 `--evaluate <folder>`：对每图跑全新检测，加载该图的保存真值，输出：
  - **逐边像素误差**（top/bottom/left/right 各一个）
  - IoU、角点误差、漏检/多检计数
  - 按**子文件夹=场景桶**汇总，并列最差样本路径
- 评测集按桶组织目录：
  `胶片条 / 联系片 / 低对比边框 / 暗内容边框 / 倾斜 / 复杂背景`（对应痛点分布）
- 输出 machine-readable（JSON）+ 人读表格 + 失败样本 overlay（复用 `--export-overlay`）。

**交付/验收**：跑一遍得到 baseline 报告（逐边误差 + 分桶）。**这是后续所有阶段的判定标准。**

**风险**：评测集过拟合自己的库 → 预留 held-out 桶，不参与调参。

---

## P1 — 统一、极性无关、颜色感知的 `separatorScore`（根因主线）

**目标**：分隔判定不再假设"暗"，不再只看亮度。覆盖痛点 1/2/6/7/8、诉求 5/6。

**现状**：分隔/gutter 判据散落在 `snapVerticalBoundaries`、`detectByDarkGutters`、
`detectProjectionRows`/`detectColumnsInRow`，各写各的暗亮度阈值。

**工作项**
- 抽出**单一** `separatorScore(line, neighbors) -> (isSeparator: Bool, strength: Double)`：
  - 输入：一列/一行的 **RGB**（不只 `gray`）+ 相邻内容统计；
  - 判据：**局部低方差** ∧ **与相邻内容差异大**，差异同时考虑
    **亮度对比**与**色度对比（RGB 通道最大梯度 / Lab 方差）**，且**双极性**（亮分隔与暗分隔同等对待）；
  - 现有"暗 gutter"成为它的一个特例。
- 先**只接到 `snapVerticalBoundaries` 一条边缘路径**做试点（不动其它检测器），用 P0 验证。
- 验证通过后，再让 `detectByDarkGutters`、`detectProjectionRows` 复用同一函数。

**交付/验收**：白边框/浅色分隔/暗内容三个桶的逐边误差与漏切率明显下降，且不回退暗 gutter 桶。

**风险**：色度线索在灰度/低饱和扫描上退化 → 退回亮度分量，保证不劣于现状。

---

## P2 — 阈值相对化 + 分块（tiled）归一化

**目标**：消除绝对阈值；解决同画布多曝光（痛点 3/5、诉求 5）。

**现状**：`darkMax=70`、`textureMin=22`、`stretchedStd<=15`（snap）、`darkCutoff` 全局分位（darkGutters）、
`contentBands value>0.55`——要么绝对、要么全图一个参考。

**工作项**
- 把上述阈值改为**相对量**：局部 std / 局部百分位 / 相对相邻带的对比度。
- 把 `snapVerticalBoundaries` 已有的逐帧 auto-levels 思路**推广**到 `detectByDarkGutters` 与 projection 路径。
- **分块归一化**：图像（或每帧）切成网格 tile，各 tile 用自身参考；一个亮区一个暗区不再共用一个 cutoff。

**交付/验收**：`同画布多曝光`、`暗内容边框` 桶的"误切主体"率下降；其它桶不回退。

**风险**：分块过细引入噪声 → tile 尺寸与帧尺寸挂钩，并设最小样本数。

---

## P3 — 逐边局部全分辨率精修（直接提边缘精度）

**目标**：诉求 1/4。把"找到符合阈值的列"升级为"拟合真实边线"。

**现状**：`snapVerticalBoundaries` 是在窗口里找满足 gutter-run 的列（:1765-1779），非边线拟合；
`edgeReliabilities`（:1509/:1514）已能给每条边打可靠度，可复用为精修前置。

**工作项**
- 选定框后，对**每条边**在窄带内：1D 投影找最强过渡 → **抛物线插值取亚像素** → 必要时**鲁棒直线拟合**（RANSAC/最小二乘 + 沿边离群剔除，应对毛刺/不齐）。
- 边强度用 P1 的 `separatorScore`（颜色感知），而非亮度梯度。
- 仅在 4 条边的窄带计算（M4 上廉价），避免全图重扫。

**交付/验收**：逐边像素误差中位数下降；`倾斜`、`复杂背景` 桶毛刺边改善。

**风险**：低证据边过度拟合 → `edgeReliabilities` 低于阈值的边不精修，交给 P4 几何兜底。

---

## P4 — 几何兜底：切分 / 补全 / 防合并（用现有能力）

**目标**：痛点 6/8、诉求 2/6。光度线索失效处，用栅格规律强制正确。

**现状（已具备，扩展即可）**：
- `regularizeStripGrid`（:1333）、`gridFallbackUnreliableEdges`（:1278）：单排重定位。
- `completeGridLattice`（:1414，本分支新增）：多排补缺失格（黑格）。
- `splitMergedFrames`（:1605）、`splitWideColumnsByLocalEdges`（:2064）：拆合并帧。

**工作项**
- **防合并/串扰（痛点 8）**：当相邻框间距 ≈ 整排 pitch 的整数倍、或某框宽 ≈ 2× 中位宽时，用 pitch 强制在预测分隔处切分（给 `splitWideColumnsByLocalEdges` 增加"pitch 期望"线索 + P1 的 `separatorScore` 复核）。
- **不遗漏/不多（诉求 2）**：跨排计数共识 + `completeGridLattice` 补缺；多检时按栅格剔除越界框。
- 把 `regularizeStripGrid` 的单排闸门放宽到多排（与 `completeGridLattice` 对齐）。

**交付/验收**：`联系片`、`胶片条` 桶的漏检/多检/合并率下降。

**风险**：几何兜底误伤非栅格布局 → 保持保守闸门（需多帧一致才触发）。

---

## P5 — 候选统一 + 集中评分 + 置信门控

**目标**：痛点 4、诉求 2/3。让"多种识别方式"显式化，由评分选择而非单检测器拍板。

**现状**：已有多检测家族（projection / darkGutters / film / vision / foreground / localContrast），
`detectCropCandidates`（:91）做编排，`score`（:508）/`alignmentScore`（:470）/`areaConsistencyScore`（:463）已有打分雏形。

**工作项**
- 统一 candidate 结构，记录来源 stage、preprocess、原始/精修分、特征向量、置信度（对接 `m4-accuracy-roadmap.md` Phase1-3）。
- 评分特征加入 P1/P3 的**逐边 edge support、色度一致性、grid regularity、相邻 overlap 一致性**。
- **置信门控**：低置信结果走 fallback（保守裁切 / 外部检测器 / 人工确认），不静默输出。

**交付/验收**：整体 crop success rate 提升；最差两个桶收敛。

---

## P6 — 厂商/边框风格泛化验证

**目标**：痛点 1/7/8。验证"极性无关 + 颜色感知"是否真的覆盖哈苏/柯达/富士各风格。

**工作项**
- 评测集补齐各厂商样本（含齿孔/白框/帧号），复核 `trimSprocketBands`（:700）/`detectSprocketSubjectFrames`（:2814）是否还需保留，能否被统一度量替代。
- 任何"为某厂硬编码"的逻辑，逐一用 P1 度量回归后删除或泛化。

**交付/验收**：各厂商桶逐边误差达标，硬编码分支减少。

---

## P7（可选）— 轻量学习排序

**硬性前置门槛（缺一不可）**：
- P0 benchmark 稳定；
- P5 候选特征已稳定记录；
- 失败分析表明"ranking"已是主要瓶颈（而非候选生成或边缘度量）。

满足后：用候选特征训练 logistic regression / GBDT 排序，先离线对比手工线性分，明确收益再考虑 Core ML。
**否则不启动**，更不要跳到 end-to-end 重型检测器。

---

## 执行顺序与"现在就做"

1. **P0**（逐边评测 + 分桶）——一切的前提。
2. **P1 试点**（`separatorScore` 接 `snapVerticalBoundaries`）——最高杠杆的根因修复。
3. 用 P0 量到收益后，再推进 P2 → P3 → P4 → P5。
4. P6 贯穿验证；P7 仅在数据支撑下。

**最高优先：P0 → P1。** 没有 P0，P1/P2 这类底层度量改动极易"修一个桶坏另一个桶"。

---

## 成功指标（沿用并细化 `m4-accuracy-roadmap.md`）

- 单图 crop success rate
- **逐边像素误差**（top/bottom/left/right 分开，本 roadmap 的核心新增指标）
- 平均/分桶 IoU、角点误差
- 漏检率 / 多检率 / 合并率
- 单图平均 + P95 latency
- 全部**按场景桶**报告，并保留 held-out 桶防过拟合
