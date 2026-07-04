# 训练管线操作手册

从零到把两个 Core ML 模型装进 App,一条命令或分步执行都可以。本文是唯一
权威操作文档;架构背景见 `agents/architecture.md`,分类规范见
`docs/TAXONOMY.md`。

## 0. 前置条件

- macOS + Xcode 16(Create ML 需要;`xcode-select --install` 不够,要完整 Xcode)
- `pnpm install`(仓库根)
- [uv](https://docs.astral.sh/uv)(transformer / PII 训练器与 curate 模型级过滤)
- 可选:CloudKit 服务端密钥(拉取用户提交样本)

```bash
export CLOUDKIT_KEY_ID=<console 里创建的 key id>
export CLOUDKIT_PRIVATE_KEY=~/.keys/sift-ck.pem
```

## 1. 一条命令全流程

```bash
pnpm pipeline -- all --install-ios
```

依次执行 `fetch-public → fetch-remote → curate → train-classic →
train-transformer`,产物在 `build/pipeline/`,`--install-ios` 把模型装进
`apps/ios/GeneratedModels/`。没有 CloudKit 凭据时 `fetch-remote` 自动跳过
(`--require-remote` 改为硬失败)。

常用变体:

```bash
pnpm pipeline -- all --skip fetch-remote            # 完全离线
pnpm pipeline -- all --strict-audit                 # 三语覆盖不达标直接失败
pnpm pipeline -- curate --model-filter off          # 轻量重跑过筛(不需要 uv)
pnpm pipeline -- train-transformer --device mps     # 指定训练设备
```

## 2. 分步执行

### 2.1 数据获取

```bash
pnpm pipeline -- fetch-public \
  --per-label 80 --core-per-label 60 --intl-per-label 16 --public-per-label 500
pnpm pipeline -- fetch-remote --cloudkit-env production
```

`fetch-public` = 合成种子(zh 全标签 80/标签,en/ja 全标签 60/标签,
es/pt/fr/de/ru/ko/id/vi/th 核心 12 标签 16/标签)+ 公共数据集下载。

### 2.2 质量过筛与审计(curate)

```bash
pnpm pipeline -- curate --model-filter auto --strict-audit
```

两级过滤:

1. **规则级**(纯标准库):taxonomy 校验 → 规范化 → 长度(8–500)→ 垃圾
   启发(低信息量/重复字符/词数不足/纯占位符)→ **脱敏占位符再水化**
   (`{{PHONE}}`→逼真假值,消除训练/推理分布差)→ 精确+近重复去重 →
   跨标签冲突剔除 → 语言白名单。
2. **模型级**(`--model-filter auto|on`,需 uv):embedding 质心三段式 —
   margin < `--hard-floor`(-0.15)必丢;灰区 [hard-floor, 0) 按 margin
   排名每标签保留 `--gray-keep`(70%);≥0 全保留。既压噪声又保留用户
   纠错样本。

产物:`train.ndjson` / `rejected.ndjson`(带拒绝原因与 margin)/
`curation-report.json`(逐来源、逐原因、标签×语言矩阵)。

审计:每个标签在 zh/en/ja 各 ≥ `--min-core-rows`(默认 10),不达标
`--strict-audit` 下退出码 2。单独体检任意数据集:

```bash
python3 tools/transformer-trainer/curate_dataset.py \
  --inputs some.ndjson --audit-only --strict-audit
```

### 2.3 训练经典模型(Create ML)

```bash
pnpm pipeline -- train-classic --version-classic corpus-0.2 --install-ios
```

`--language auto`:≥90% 单语语料按该语言训练,混合语料自动语言无关。
训练完打印**最弱 12 个标签 + Top 混淆对** —— 这是该模型的主要提升回路:
按报告去补种子模板/样本,重训。

### 2.4 训练 Transformer(SetFit → Core ML)

```bash
pnpm pipeline -- train-transformer \
  --version-transformer setfit-0.2 --quantize int8 --install-ios
```

- 设备:`--device auto` = cuda(NVIDIA/AMD ROCm)→ mps(Apple Silicon)→ cpu;
  ROCm 需先 `uv pip install torch --index-url https://download.pytorch.org/whl/rocm6.2`。
- 每次训练写 `transformer-model/checkpoint/`(**裁剪词表之前**的完整模型)
  与 `training-report.html`(loss 曲线 / 每标签准确率 / 混淆对)。
- 体积:`--quantize int8` + `--prune-vocab`(默认开)+ `--truncate-layers N`。

### 2.5 增量微调(补数据后不重训)

```bash
pnpm pipeline -- finetune          # 默认从最近 checkpoint,LR 1e-5
pnpm pipeline -- finetune --resume-from build/pipeline/transformer-model/checkpoint \
  --body-learning-rate 5e-6
```

流程:新数据 → `curate` → `finetune`。关于"RL":分类任务没有独立奖励
信号,工程等价物即"置信度分层过筛 + 低学习率增量对比微调",不建议引入
真正的 RL 训练。

### 2.6 可选:PII 脱敏模型

```bash
cd tools/pii-trainer && uv sync
uv run train_pii.py --input ../../build/pipeline/train.ndjson --install-ios
```

App 侧自动与规则脱敏取并集;不装则纯规则运行(见 `tools/pii-trainer/README.md`)。

## 3. 多语言策略(决策记录)

**结论:单一多语言模型,不按语言拆分。**

- 两个模型的底座天然多语言(Apple contextual embedding 按文字系统覆盖;
  SetFit 用 multilingual sentence-transformer),50 类 × 每类几十到几百样本
  的量级下,跨语言共享类别语义使单模型的每语言准确率 ≥ 独立小模型
  (独立模型每语言数据被切薄,长尾类别会塌)。
- 中英混排(码切换)短信只有单模型能自然处理;三模型还意味着 3× 体积、
  extension 内存与切换/维护成本。
- 若某语言准确率显著落后:用训练报告定位 → 补该语言模板/样本 →
  `finetune`,而不是拆模型。

**样本语言标注:必要,已实现两处。** 设备 locale ≠ 文本语言(英文用户会
提交中文短信),因此客户端提交时用 `NLLanguageRecognizer` 检测文本语言写入
`textLanguage` 字段(质量高于训练侧启发式);curate 的脚本检测作为兜底与
交叉校验。该字段用于语言配额、审计矩阵与按语言评估。

## 4. 产物清单

| 文件 | 去向 |
| --- | --- |
| `build/pipeline/train.ndjson` | 两个训练器的输入 |
| `build/pipeline/apple-model/SiftSMSClassifier.{mlmodel,manifest.json}` | App/扩展(经典) |
| `build/pipeline/transformer-model/SiftTransformerClassifier.{mlpackage,vocab.txt,manifest.json}` | App/扩展(高级版) |
| `build/pipeline/transformer-model/checkpoint/` | finetune 起点 |
| `build/pipeline/transformer-model/training-report.html` | 训练可视化 |
| `build/pii-model/SiftPIIDetector.*` | App(可选脱敏模型) |

装进 App 后:`cd apps/ios && xcodegen generate`,构建即生效。
