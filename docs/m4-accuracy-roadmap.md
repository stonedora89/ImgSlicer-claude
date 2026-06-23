# ImgSlicer 在 Mac mini M4 上的准确度、接口与性能优化路线图

## 目标

这份路线图用于明确一个务实的技术方向：在 Mac mini M4 上持续提升裁切检测准确度，同时优化代码接口、运行性能、批处理效率和长期可维护性。

当前最核心的目标，不再只是“找到框”，而是：

- 找到大致正确的框
- 把四条边修准
- 在不同风格图片上保持稳定
- 在批量图库处理中尽量减少离谱错误
- 保证代码接口清晰、模块职责明确
- 保证整体运行效率、可观测性和可持续优化能力

总体策略如下：

- 先补强离线评测体系和工程观测能力
- 将检测流程演进为多候选 pipeline
- 将边缘精修提升为核心能力
- 将候选评分与置信度估计集中化
- 将接口按职责拆分，避免主流程持续膨胀
- 将性能优化嵌入每个阶段，而不是最后单独补救
- 保留 Python/OpenCV 作为实验通道与 fallback 通道
- 将高价值算法逐步收敛到 Swift 原生主链路

## 当前问题判断

从现有代码结构看，项目已经具备多阶段检测能力，也已经有一定的 refinement 思路。当前真正卡住准确度和工程演进的，不是“完全找不到框”，而是下面几类问题：

- 粗框通常能找到，但边缘贴合不够准确
- 图库风格差异大，固定阈值在不同图片上不稳定
- 单张图的边界证据有时很弱，容易吃进黑边或切掉主体
- 深色主体、低对比边框、复杂背景纹理容易互相混淆
- 同一张画布内部可能存在明显不同的曝光程度和内容风格
- 图片数量、间距、边框颜色、画质和设备来源都不固定
- 当前主流程代码集中度高，职责边界还不够清晰
- 目前缺少足够清晰的 benchmark 和性能观测体系，难以稳定判断优化是否真的有效

因此，后续演进不能继续停留在“追加一点规则、微调一些参数”的方式，而要改为阶段化演进，并且把准确度、接口和性能统一考虑。

## 当前架构概览

仓库已经具备比较好的算法演进基础：

- 分阶段裁切检测调度：Sources/ImgSlicer/Processing/CropDetectionPipeline.swift
- 核心检测与精修逻辑：Sources/ImgSlicer/ImageProcessor.swift
- benchmark 与算法对比入口：Sources/ImgSlicer/Processing/AlgorithmComparisonCommand.swift
- 外部 Python 检测器接入：Sources/ImgSlicer/ExternalDetector.swift
- 基于 OpenCV 的实验检测器：Sources/ImgSlicer/Resources/detectors/opencv_detector.py

当前设计已经接近“多策略检测系统”，但如果想持续提升准确度并保持工程可维护，建议将 candidate generation、stage routing、boundary refinement、ranking、fallback、evaluation 和 diagnostics 显式拆分为独立模块。

## 为什么 Mac mini M4 会影响路线设计

Mac mini M4 非常适合作为长期部署目标，原因包括：

- 单机批处理吞吐能力强
- Apple Silicon 上原生图像处理效率高
- 对 Vision、Core Image、Accelerate、可选的 Core ML 支持良好
- 相比 Python-first 生产栈，部署更稳定、更可控

这意味着长期生产路径应优先倾向：

- 用 Swift 原生承载主检测 pipeline
- 使用“全图低分辨率分析 + 局部全分辨率精修”的模式
- 尽量减少跨进程图像转换和外部子进程开销
- 将性能优化聚焦在阶段路由、局部计算和中间结果复用上

Python/OpenCV 仍然很有价值，但更适合承担：

- 快速算法试验
- benchmark 对照
- 低置信度结果的 fallback 检测

## 产品技术方向

### 短期方向

优先通过评测体系、工程观测、候选生成、边缘精修、候选评分和接口整理来提升准确度，而不是一开始就投入重型模型。

### 中期方向

将外部检测器中真正有效、可复用的逻辑逐步迁移回 Swift 原生主链路，同时让代码结构更清晰、性能模型更稳定。

### 长期方向

只有在 benchmark 数据集和特征管线稳定之后，才引入轻量学习排序模型，并将主流程逐步收敛到更纯粹的 Swift-native 架构。

## 指导原则

- 以可量化的离线 benchmark 驱动准确度优化
- 优先使用“多个弱候选生成器”，而不是依赖单个脆弱检测器
- 将最终结果排序集中化，而不是让各 stage 直接竞争最终输出
- 将边缘精修视为核心能力，而不是检测后的附属步骤
- 对低置信度结果进行显式处理
- 将接口边界和数据结构设计纳入算法优化过程，而不是后补重构
- 将性能优化嵌入每个阶段，优先减少无效工作而不是盲目微优化
- 避免让核心生产路径长期依赖外部 Python 执行

## 成功指标

这份路线图是否有效，应通过固定 benchmark 数据集和稳定的报告格式来衡量。

建议的核心准确度指标：

- 单图 crop success rate
- 相对 ground truth 的平均 IoU
- 角点误差或边界像素误差
- false positive rate
- missed detection rate
- count deviation
- merged-frames rate

建议的工程与性能指标：

- 单图平均 latency
- 单图 P95 latency
- 各 stage 平均耗时
- 每张图触发的高成本 stage 次数
- 候选数量与最终保留数量
- 外部 detector 调用比例

建议按场景分桶统计：

- 胶片条扫描图
- 网格图或联系片图
- 低对比度边框图
- 深色内容边框图
- 倾斜或透视畸变图
- 背景复杂或纹理干扰图
- 弱边界或不规则毛刺边图

同时建议将失败进一步分类为：

- 吃进黑边
- 切掉主体
- 左右边不准
- 上下边不准
- 粘连未拆开
- 多切或少切
- 倾斜修正失败
- 低置信度无可用结果

## 演进阶段总览

整个演进方向建议统一为 4 个工程阶段：

- Phase 1：先补观测能力与接口边界
- Phase 2：补边缘精修核心能力
- Phase 3：补自适应选择与鲁棒性
- Phase 4：补性能、批处理效率与原生收敛

这 4 个阶段不是把准确度、接口和性能拆开处理，而是每个阶段同时覆盖这三类目标。

## Phase 1：先补观测能力与接口边界

### 这一阶段主要处理什么问题

当前最大的风险不是算法“完全不工作”，而是：

- 不知道最差的是哪类图
- 不知道最常错的是哪条边
- 不知道每次优化后到底有没有进步
- 不知道哪个 stage 在哪些图上更有效
- 不知道性能瓶颈到底在哪个阶段
- 当前主流程能力很多，但职责边界还不够清晰

因此这一阶段不直接追求算法变强，而是先让系统变得“看得清、分得清、量得准”。

### 主要原理

把识别流程拆成可观察、可记录、可对比的数据层，而不是只看最终成功或失败：

- 每张图有多少候选
- 最终选了哪个候选
- 四条边分别可靠不可靠
- 错误属于哪一类
- 每个 stage 花了多少时间
- 哪些高成本路径被触发

### 工作项

- 建立带场景标签的 benchmark 图集
- 定义 crop rectangle 或 corner points 的 ground truth 格式
- 扩展对比工具，输出逐图结构化结果
- 记录 stage 级 candidate 数量、最终选中来源、confidence、latency
- 记录四条边各自的 reliability
- 记录 merge/split、count deviation 等异常信息
- 为各 stage 增加耗时统计与诊断信息
- 建立统一的 candidate / diagnostics 数据结构
- 建立失败分类表和 baseline 报告

### 接口目标

这一阶段建议开始抽象统一结构，例如：

- CanvasAnalysis
- DetectionCandidate
- RefinedCandidate
- DetectionDecision
- DetectionDiagnostics

目标不是一次性重构完成，而是先让新输出结构可以逐步承接旧逻辑。

### 性能目标

这一阶段先不做重优化，但必须知道：

- 哪些 stage 最耗时
- 哪些预处理被重复执行
- 哪些图像转换最频繁
- 外部 detector 的调用成本占比多少

### 能解决什么问题

这一阶段本身不会直接提高准确率，但它会解决后续所有优化的方向问题，也会为接口整理和性能优化提供可靠依据。

### 你需要配合我做什么

- 准备 100～300 张代表性图片
- 按风格或困难场景粗分桶
- 对失败样本做最粗粒度分类
- 明确最不能接受的错误类型排序
- 提供同组图片的组织方式，例如文件夹或命名规则

### 交付物

- benchmark dataset 目录
- machine-readable evaluation output
- failure sample gallery
- 当前分支的 baseline report
- 最差场景排行榜
- 第一版 diagnostics 输出结构

### 针对当前仓库的落点

- Sources/ImgSlicer/Processing/AlgorithmComparisonCommand.swift
- Sources/ImgSlicer/ImageProcessor.swift
- Sources/ImgSlicer/Processing/CropDetectionPipeline.swift

## Phase 2：补边缘精修核心能力

### 这一阶段主要处理什么问题

当前最核心的问题是：框大致对了，但边没有贴准。

这说明粗检测已经不是唯一重点，真正影响结果观感和实用性的，是最终边界位置。

### 主要原理

把流程从“一步直接出最终框”，改成：

- 先检测粗框
- 再对四条边分别做局部精修

也就是把一个框拆成四条独立边来处理：

- 左边单独微调
- 右边单独微调
- 上边单独微调
- 下边单独微调

### 工作项

- 设计统一的 BoundaryRefiner 模块
- 让粗检测输出 coarse box，而不是直接承担最终精确边界
- 对每条边定义局部搜索带和搜索步长
- 输出每条边的 refinement result 和 reliability
- 将边缘精修与最终候选评分解耦
- 将 merged-frame split 和 count sanity check 与边界精修联动

### 接口目标

建议逐步形成边界处理层，例如：

- BoundaryRefiner
- BoundaryEvidence
- BoundaryReliability
- RefinementDiagnostics

这会把原本散落在主流程里的 trimming、snapping、merge split 和局部微调整理成更稳定的接口层。

### 性能目标

- 粗检测只做一次
- 精修只在少数 top candidates 上做
- 高分辨率分析只在局部窗口内执行
- 避免每个 stage 都做全图重扫

### 能解决什么问题

这一步最直接解决：

- 左右边吃进黑边
- 左右边切掉主体
- 上下边没有贴准
- 一侧明显偏移但整体框仍“看起来差不多”的问题
- 两张图粘连但被吞成一个大框

### 你需要配合我做什么

- 明确你更偏向“保守保留边框”还是“尽量贴紧主体”
- 告诉我你最常处理的是单张、胶片条、联系片还是混合型布局

### 交付物

- BoundaryRefiner 设计
- 四边独立 refinement 能力
- 每条边各自的 reliability 输出
- merge / split 与边界精修联动机制

### 针对当前仓库的落点

最适合新增和演进该能力的位置是 Sources/ImgSlicer/ImageProcessor.swift。

## Phase 3：补自适应选择与鲁棒性

### 这一阶段主要处理什么问题

这一阶段专门对付你当前最现实的数据复杂性：

- 边缘风格多样
- 色彩风格变化多
- 曝光参差不齐
- 同一张画布内部局部差异很大
- 设备来源风格不同
- 照片间距和边框颜色不固定

### 主要原理

让系统不再对所有图片走同一套路径，而是先做轻量画布判断，再决定更合适的 stage 组合、预处理方式和边界评分方式。

### 工作项

- 定义轻量 CanvasClassifier
- 在 CropDetectionPipeline 上增加 stage routing
- 引入局部自适应预处理
- 为每条边建立多证据评分机制
- 增加 count sanity check
- 增加 group context 与组内一致性约束

### 接口目标

这一阶段建议逐步形成更清晰的职责层：

- CanvasClassifier
- StageRouter
- CandidateGenerator
- BoundaryRefiner
- CandidateRanker
- SanityChecker

不要求一次性拆成多个文件，但逻辑边界要先清楚。

### 性能目标

- 并非所有图都跑全套 stage
- 不同图只运行更适合的候选路径
- 不同候选只在必要时做高成本精修
- 通过“更聪明地少做事”提升整体吞吐

### 能解决什么问题

这一步主要解决：

- 深色主体和黑边混淆
- 背景纹理误判
- 单一特征失效时整体判断崩掉
- 某些图总被错误 stage 主导
- 多切、少切、相邻串框和数量不合理问题

### 你需要配合我做什么

- 提供一批“最难但最重要”的图片
- 帮助将图库粗分为若干风格桶
- 提供同组图片的组织方式

### 交付物

- 画布路由策略
- 自适应预处理策略
- 多证据边界评分体系
- count sanity check 机制
- group consensus 修正策略

### 针对当前仓库的落点

- Sources/ImgSlicer/Processing/CropDetectionPipeline.swift
- Sources/ImgSlicer/ImageProcessor.swift
- Sources/ImgSlicer/Processing/AlgorithmComparisonCommand.swift

## Phase 4：补性能、批处理效率与原生收敛

### 这一阶段主要处理什么问题

这一阶段主要解决：

- 批处理速度不够
- 大量重复计算
- 图像转换成本高
- Python 外部通道开销大
- 主流程越来越重，不利于继续扩展

### 主要原理

把流程明确拆成不同成本层级：

- 低成本整图分析
- 中成本候选生成
- 高成本局部精修
- 极高成本 fallback

然后优先减少无效工作、复用中间结果、降低外部依赖，而不是一开始就做低层微优化。

### 工作项

- 为各阶段建立明确的成本分层
- 缓存灰度图、缩放图、局部 luminance 数据和预处理结果
- 减少 NSImage、CGImage、像素 buffer、外部进程之间的重复转换
- 压缩外部 detector 的常态调用比例
- 将已验证有效的外部逻辑逐步迁回 Swift
- 明确主链路与实验链路边界

### 接口目标

形成更稳定的系统边界：

- 主链路：Swift-native
- 实验链路：Python/OpenCV
- fallback：按置信度触发

### 性能目标

- 减少重复预处理
- 减少不必要的全分辨率全图扫描
- 减少所有候选都做重精修的情况
- 降低外部 detector 的进程与数据交换开销
- 提升几千张图库批处理的吞吐稳定性

### 能解决什么问题

这一阶段会显著提升：

- 批处理效率
- 大图库运行时长
- 主链路稳定性
- 后续继续优化的工程空间

### 你需要配合我做什么

- 提供真实批处理任务规模的样本
- 告诉我你最在意的是单图速度、整批速度还是稳定性优先

### 交付物

- 成本分层模型
- 缓存与复用策略
- 主链路 / 外部链路边界方案
- Swift-native 收敛路径

### 针对当前仓库的落点

- Sources/ImgSlicer/ImageProcessor.swift
- Sources/ImgSlicer/ExternalDetector.swift
- Sources/ImgSlicer/Resources/detectors/opencv_detector.py

## 和当前代码结构的对应关系

### Sources/ImgSlicer/Processing/CropDetectionPipeline.swift

主要职责：

- 组织 detection stages
- 从“阶段列表”升级为“阶段策略”
- 增加 routing、优先级和限流思路
- 让各 stage 更多承担“提供候选”的职责

### Sources/ImgSlicer/ImageProcessor.swift

主要职责：

- 承担主识别逻辑
- 逐步瘦身为更清晰的执行层
- 新增 BoundaryRefiner
- 增加边界 reliability、局部搜索、局部精修、sanity check 和 diagnostics

### Sources/ImgSlicer/Processing/AlgorithmComparisonCommand.swift

主要职责：

- 做 benchmark
- 输出 candidate、score、reliability、latency
- 输出 merge/split、count deviation、fallback 使用情况
- 作为工程观测入口，而不只是算法对比工具

### Sources/ImgSlicer/ExternalDetector.swift

主要职责：

- 保留外部 detector
- 用于 fallback 和实验对照
- 不作为长期核心路径

## 可选的轻量学习排序

### 何时启动

只有在以下条件满足时才启动：

- benchmark dataset 已稳定
- candidate features 已稳定记录
- 失败模式表明“ranking”已经成为主要瓶颈

### 建议方式

- 基于 candidate features 训练轻量 ranking 或 classification model
- 首选 logistic regression 或 gradient-boosted trees
- 先离线对比 learned ranking 与 manual linear score
- 只有在离线收益明确时，才迁移到 Core ML

### 非目标

除非 benchmark 证明规则候选生成已经根本性到达瓶颈，否则不要直接跳到重型 end-to-end detector。

## 六个月执行计划

### 第 1 个月

- 建 benchmark dataset
- 统一 evaluation output
- 增强 overlay 与 failure reporting
- 记录四条边的 reliability
- 固化当前实现的 baseline
- 建立第一版 diagnostics 结构

### 第 2 个月

- 引入统一 candidate model
- 将各 stage 输出重构为 candidate generators
- 将粗框检测与边缘精修分离
- 设计 BoundaryRefiner
- 为各 stage 增加 latency 统计

### 第 3 个月

- 实现第一版边界评分体系
- 记录 feature vector 与 confidence signal
- 增加 count sanity check
- 针对最差的两个场景桶进行调优

### 第 4 个月

- 增加画布 routing
- 引入局部自适应预处理
- 优化 trimming、snapping、merged-frame handling
- 量化边界精度提升

### 第 5 个月

- 引入 group context 和组内一致性修正
- 缩小 external detector 的角色到 fallback 与 comparison
- 缓存高频中间结果
- 开始压缩重复图像转换

### 第 6 个月

- 评估轻量 learned ranking
- 验证是否值得接入 Core ML
- 明确主链路 / 外部链路边界
- 冻结下一阶段的 production-oriented native architecture

## 当前最建议立即推进的事项

建议优先做以下五件事：

1. 扩展 Sources/ImgSlicer/Processing/AlgorithmComparisonCommand.swift 的 evaluation output
2. 在 Swift pipeline 中定义统一 candidate / diagnostics 结构
3. 增加四条边的 reliability 和 feature logging
4. 识别 ImageProcessor.swift 中适合抽离为 BoundaryRefiner 的逻辑块
5. 补充 benchmark dataset format 与 failure category 文档

## Phase 1 样本整理方案

这一部分用于把 Phase 1 从“方向”变成“可执行动作”。目标不是一次性整理完整个图库，而是先建立一套足够代表问题、足够支撑后续优化的样本体系。

### Phase 1 的目标

在第一阶段，你真正要完成的不是改算法，而是完成下面四件事：

- 选出一批有代表性的 benchmark 样本
- 把样本按问题类型和风格粗分桶
- 给失败结果建立统一记录方式
- 形成后续算法迭代的基线数据

只要这一步做对，后面每次算法优化都能有明确方向和可验证结果。

### 推荐样本规模

第一轮不建议直接整理全部几千张图库。建议先从 100～300 张开始。

推荐分配方式：

- 100 张：最小可启动集
- 200 张：比较适合第一轮调优
- 300 张：足够覆盖主要失败模式

如果你的图库分布特别复杂，建议先做 200 张。

### 样本选择原则

样本不要随机抽取，而要有意识覆盖不同难点。建议优先覆盖这些场景：

- 边界非常清晰的样本
- 深色主体和深色边框混淆的样本
- 低对比度边界样本
- 背景复杂、纹理干扰强的样本
- 两张或多张图片贴得很近的样本
- 轻微倾斜或透视畸变样本
- 联系片、胶片条、网格布局样本
- 当前算法明显容易出错的样本

目标不是“样本平均”，而是“问题覆盖全面”。

### 推荐目录结构

建议单独建立一个 benchmark 目录，例如：

enchmark/phase-1/

建议结构如下：

- enchmark/phase-1/images/
- enchmark/phase-1/metadata/
- enchmark/phase-1/overlays/
- enchmark/phase-1/reports/

其中：

- images/ 存放原始测试图
- metadata/ 存放样本标签、分桶、标注、失败记录
- overlays/ 存放可视化结果
- eports/ 存放阶段性输出报告

### 推荐文件命名规则

建议样本文件名尽量稳定、可排序、可追溯，例如：

- ilm_dark_001.jpg
- ilm_dark_002.jpg
- grid_lowcontrast_001.jpg
- contactsheet_texture_001.jpg

命名建议包含两部分：

- 场景类别
- 序号

如果原始文件名本身有业务意义，也可以保留原名，再在 metadata 里补分类标签。

### 推荐分桶方式

第一轮不要分得太细，能支撑决策就够了。建议先做两个维度：

#### 1. 布局桶

- single_frame
- ilm_strip
- contact_sheet
- grid_layout
- mixed_layout

#### 2. 难点桶

- clean_border
- dark_content
- low_contrast
- complex_texture
- merged_frames
- 	ilted_frame
- weak_edge_evidence

一张图可以同时属于多个难点桶。

### 推荐 metadata 结构

第一阶段不需要很重的标注系统，先用简单可维护的结构就行。建议每张图对应一个 JSON 或 CSV 记录。

如果用 JSON，建议字段包括：

- image_name
- layout_bucket
- difficulty_buckets
- group_id
- expected_frame_count
- priority
- 
otes

示例概念：

- image_name: 图片文件名
- layout_bucket: 布局类型
- difficulty_buckets: 难点标签列表
- group_id: 如果属于同一批扫描任务，则填相同组号
- expected_frame_count: 预期应该识别出几个框
- priority: 是否为高优先级难样本
- 
otes: 备注当前已知问题

### 第一阶段是否必须做精确标注

不一定。

建议分两层：

#### 第 1 层：轻量启动

先记录：

- 这张图属于什么类型
- 预期大致有几个框
- 当前最明显的问题是什么

这样可以快速启动 benchmark。

#### 第 2 层：重点图精标

对最关键的 30～50 张图，再做精细标注，例如：

- 精确 crop rectangle
- 或四角点坐标

这样后续才能做更精确的边界误差统计。

### 推荐失败分类表

建议在 metadata 里统一记录失败类型，先不要太复杂，第一轮只要能支持决策即可。

推荐分类：

- over_crop_border_included
- under_crop_subject_cut
- left_edge_wrong
- ight_edge_wrong
- 	op_edge_wrong
- ottom_edge_wrong
- merged_frames_not_split
- alse_extra_frame
- 	ilt_correction_failed
- low_confidence_no_good_result

如果一张图同时有多个问题，可以允许多标签。

### 你最需要给我的主观判断

在开始算法迭代之前，你要先明确下面这件事：

#### 你的容错偏好是什么

通常要选一个主要方向：

- 宁可多留一点边，也不要切掉主体
- 宁可裁得更紧，也能接受偶尔少量切边

如果不先定这个原则，后续边缘精修策略会来回摇摆。

### 推荐优先级标记方式

建议给样本加一个简单优先级：

- P0：最重要、最常见、最影响体验的问题样本
- P1：常见但可稍后处理的问题样本
- P2：边角场景或低频异常样本

后续调优时，先盯住 P0，不要被零散长尾样本带偏。

### 推荐 group 信息记录方式

如果一批图天然属于同一次扫描任务，建议记录组信息。

可以直接用：

- 文件夹名作为 group_id
- 或任务名作为 group_id
- 或按命名规则提取 group_id

这对后续的 group consensus 修正非常重要。

### 第一阶段建议输出什么报告

第一轮 benchmark 建议输出三类结果：

#### 1. 总体结果

- 总图片数
- 成功率
- 失败率
- 平均耗时

#### 2. 分桶结果

- 不同布局桶的成功率
- 不同难点桶的成功率
- 哪一类图最差

#### 3. 错误分布

- 哪类错误最多
- 哪条边最容易错
- 是否更多是吃进边框还是切掉主体

### 第一阶段你具体需要准备什么

如果你准备开始，我最希望你先给我这些内容：

- 100～300 张代表图
- 每张图所属的布局类型
- 每张图的大致难点标签
- 哪些图属于同一批次
- 你最不能接受的错误排序

如果你暂时没时间做完整 metadata，也可以先给我一个简化版表格，只要包含：

- 文件名
- 布局类型
- 难点标签
- 是否高优先级

### 推荐最小启动版本

如果你想最快开始，不要等所有数据都整理完。可以先做一个最小版本：

- 选 100 张图
- 分成 5～7 个桶
- 标记每张图 1～2 个主要难点
- 给其中 20～30 张标为 P0
- 先跑当前算法拿到 baseline

这样就足够进入下一阶段。

### Phase 1 完成标志

当下面这些条件成立时，可以认为 Phase 1 基本完成：

- 已经有稳定的 benchmark 图片集
- 已经完成粗分桶
- 已经有统一失败分类
- 已经能输出 baseline 报告
- 已经知道当前最差的前 2～3 类问题

一旦这一步完成，后面 Phase 2 的 BoundaryRefiner 设计就会非常有针对性，而不是泛泛而谈。

## 你需要配合提供的内容

为了真正推进，而不是停留在讨论阶段，你最重要的配合有 4 类：

### 1. benchmark 样本

先不要全库，先给 100～300 张代表图。

### 2. 错误优先级

告诉我你最不能接受哪种错误，例如：

1. 切掉主体
2. 吃进黑边
3. 粘连没拆开
4. 上下边不准

### 3. 风格分桶

粗分即可，不需要学术分类。

### 4. 组信息

告诉我哪些图天然属于一组，例如按文件夹、命名规则或批次关系。

## 建议的长期架构

### 生产路径

- Swift-native candidate generation
- Swift-native stage routing
- Swift-native scoring and confidence
- Swift-native boundary refinement
- Swift-native sanity check and diagnostics
- external detector 仅作为 fallback 或实验对照

### 研究路径

- Python/OpenCV 用于快速试验
- 每次实验都输出结构化 benchmark 结果
- 将验证有效的思路选择性迁入原生主链路

## 最终建议

对于这个运行在 Mac mini M4 上的项目，当前最高回报的策略不是马上引入大型 ML detector，也不是先做脱离业务问题的纯重构或纯性能优化。

更合适的路径是：

- 先补观测能力与接口边界
- 再把边缘精修做成核心模块
- 再让系统学会根据不同画布和候选自适应选路
- 再逐步压缩无效工作、收敛主链路性能和外部依赖

这条路线比继续调参数，更适合当前这种：

- 数据量大
- 图风差异大
- 主要追求边缘准确性
- 同时还要优化接口和运行效率
- 长期运行在 Mac mini M4 上

在准确度增长、性能、接口清晰度、可解释性和长期可维护性之间，这条路线通常能取得最好的平衡。
