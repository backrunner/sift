# 训练管线操作手册

从零到训练经典模型、上传高级版 Transformer 模型,一条命令或分步执行都可以。
本文是唯一权威操作文档;架构背景见 `agents/architecture.md`,分类规范见
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
train-transformer`,产物在 `build/pipeline/`。`--install-ios` 只会把经典
Create ML 模型装进 `apps/ios/GeneratedModels/`;高级版 Transformer 不随 App
分发,训练完成后走第 2.5 节上传到远端模型目录。没有 CloudKit 凭据时
`fetch-remote` 自动跳过(`--require-remote` 改为硬失败)。

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
pnpm pipeline -- train-classic --version-classic corpus-0.2 \
  --algorithm-classic maxent --install-ios
```

`--language auto`:≥90% 单语语料按该语言训练,混合语料自动语言无关。
当前已验证的经典模型默认结构是 Create ML MaxEnt;`bert/auto` 可用于对照实验,
但在 50 类小样本短信数据上低于 MaxEnt。
复验泛化稳定性时改变 `--split-seed-classic`,不要只看默认 seed 42。
训练完打印**最弱 12 个标签 + Top 混淆对** —— 这是该模型的主要提升回路:
按报告去补种子模板/样本,重训。

### 2.4 训练 Transformer(mmBERT → Core ML)

```bash
pnpm pipeline -- train-transformer \
  --version-transformer mmbert-0.1 --quantize int8
```

- 设备:`--device auto` = cuda(NVIDIA/AMD ROCm)→ mps(Apple Silicon)→ cpu;
  ROCm 需先 `uv pip install torch --index-url https://download.pytorch.org/whl/rocm6.2`。
- 默认底座:`jhu-clsp/mmBERT-small`(ModernBERT 架构,metaspace BPE tokenizer);
  可用 `--backbone` 覆盖。
- 每次训练写 `transformer-model/checkpoint/`
  与 `training-report.html`(loss 曲线 / 每标签准确率 / 混淆对)。
- 体积:`--quantize int8` + `--truncate-layers N`。BPE tokenizer 以
  `SiftTransformerClassifier.tokenizer.json` 输出到模型目录。
- 导出的 `SiftTransformerClassifier.manifest.json` 会写入 `remoteArtifacts`
  与 `downloadBytes`;`.mlpackage` 是目录包,远端分发按文件清单逐个下载。

### 2.5 上传高级版 Transformer 模型

App 内的高级版切换按钮会先读取:

```text
https://sift.alkinum.io/models/SiftTransformerClassifier.manifest.json
```

因此每次 Transformer 训练验收后,把 `build/pipeline/transformer-model/`
上传到这个 URL 对应的公开目录。先 dry-run 校验清单、hash 与总大小:

```bash
pnpm upload:transformer-model -- \
  --model-dir build/pipeline/transformer-model \
  --base-url https://sift.alkinum.io/models \
  --dry-run
```

上传到任意对象存储/CDN 时使用命令模板。脚本会对 manifest 和每个
`remoteArtifacts` 文件分别调用一次模板,支持 `{src}`、`{path}`、
`{content_type}`、`{cache_control}`:

```bash
pnpm upload:transformer-model -- \
  --model-dir build/pipeline/transformer-model \
  --base-url https://sift.alkinum.io/models \
  --upload-command 'rclone copyto {src} r2:sift-public/models/{path}' \
  --verify-http
```

也可以先复制到本地发布目录:

```bash
pnpm upload:transformer-model -- \
  --model-dir build/pipeline/transformer-model \
  --base-url https://sift.alkinum.io/models \
  --dest-dir /path/to/public/models
```

发布验收:

1. `--dry-run` 必须通过,并记录 `upload bytes` 与本次 Core ML 导出大小一致。
2. 使用 `--verify-http` 确认 manifest 和所有 artifact 在 CDN 上可访问。
3. 真机上未购买时点 Transformer 只出现高级版购买页;购买后再次点
   Transformer 才下载。计费网络/低数据模式会先显示流量提示。
4. 下载完成前 extension 只能使用经典模型;下载完成并校验后才切到
   Transformer。

### 2.6 增量微调(补数据后不重训)

```bash
pnpm pipeline -- finetune          # 默认从最近 checkpoint,LR 1e-5
pnpm pipeline -- finetune --resume-from build/pipeline/transformer-model/checkpoint \
  --learning-rate 5e-6
```

流程:新数据 → `curate` → `finetune`。关于"RL":分类任务没有独立奖励
信号,工程等价物即"置信度分层过筛 + 低学习率增量监督微调",不建议引入
真正的 RL 训练。

### 2.7 可选:PII 脱敏模型

```bash
cd tools/pii-trainer && uv sync
uv run train_pii.py --input ../../build/pipeline/train.ndjson --install-ios
```

App 侧自动与规则脱敏取并集;不装则纯规则运行(见 `tools/pii-trainer/README.md`)。

## 3. 多语言策略(决策记录)

**结论:单一多语言模型,不按语言拆分。**

- 两个模型的底座天然多语言(Apple contextual embedding 按文字系统覆盖;
  Transformer 用 mmBERT 多语言 encoder),50 类 × 每类几十到几百样本
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
| `build/pipeline/transformer-model/SiftTransformerClassifier.{mlpackage,tokenizer.json,manifest.json}` | 上传到 `https://sift.alkinum.io/models/` 供高级版按需下载 |
| `build/pipeline/transformer-model/checkpoint/` | finetune 起点 |
| `build/pipeline/transformer-model/training-report.html` | 训练可视化 |
| `build/pii-model/SiftPIIDetector.*` | App(可选脱敏模型) |

装进 App 后:`cd apps/ios && xcodegen generate`,构建即生效。Transformer 不
进入 `apps/ios/GeneratedModels/`;如果本地调试需要内置资源,只能临时改
`project.yml`,提交前必须移除。
