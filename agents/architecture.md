# 架构总览

## 运行时(iOS)

```
┌─ SiftApp (main bundle) ──────────────────────────────────────────┐
│  SiftAppKit: SiftRootView(仪表盘/统计/提交/规则)                  │
│    · SettingsView(高级版/恢复购买/我的提交/导出/GDPR 抹除)        │
│    · PremiumPaywallView(StoreKit 2, PremiumStore)                │
│    · SubmissionHistoryView(CloudKit 分页,单条抹除)              │
│  Localizable.xcstrings(zh-Hans 源,en/ja)                        │
└──────────────┬───────────────────────────────────────────────────┘
               │ App Group group.com.alkinum.sift(共享 UserDefaults)
               │  · ModelSelectionStore(模型选择)
               │  · SharedRuleStore(自定义规则)
               │  · FilterStatisticsStore(每日计数桶)
               │  · SubmissionLedger(贡献计数)
┌──────────────┴───────────────────────────────────────────────────┐
│  MessageFilterExtension (IdentityLookup)                          │
│  每次 handle() 重读共享选择/规则 → ClassificationPipeline         │
│  → MessageFilterActionMapper(junk/promotion/transaction/allow)   │
│  → FilterStatisticsStore.record()                                 │
└───────────────────────────────────────────────────────────────────┘
```

### MessageFilterCore(共享核心,无 UI 依赖)

- `ClassificationPipeline` = 自定义规则(优先) → 分类器 → 低置信回退。
- 分类器栈按 `ModelVariant`:
  - **classic**:`NLModelTextClassifier`(Create ML,`SiftSMSClassifier`)
    ⊕ 本地个性化 adapter(`PersonalizationTrainer`,逻辑回归,App 内微调)
    ⊕ `HeuristicClassifier` 兜底(zh/en/ja 关键词)。
  - **transformer**(高级版 IAP 解锁):`TransformerTextClassifier`
    (`WordPieceTokenizer` + CoreML SetFit 导出),冻结不可微调。
- `PrivacySanitizer` 双轨:规则(NSDataDetector + 正则:手机号/证件/邮箱/
  卡号/码/金额/地址/人名)∪ 可选 `CoreMLPIIDetector`(词元分类);
  并集脱敏,模型只放大召回。
- CloudKit:
  - 公共库 `SmsSample`(匿名样本 + 本地粗分元数据 + textLanguage);
    creator 关联支撑回执删除 / 全量抹除 / 历史分页(`createdAt` keyset)。
  - 私有库 `FilterStats`(统计备份,逐计数 max 合并)。

## 训练侧

```
fetch-public(合成 zh/en/ja 全标签 + 9 语言核心 + 公共数据集)
   ↘
fetch-remote(pnpm export:training,CloudKit s2s)
   ↘
curate(规则过筛 → 占位符再水化 → 去重/冲突 → 语言检测
       → 可选 embedding 三段式标签噪声过滤)→ strict-audit(zh/en/ja×50)
   ↘
train-classic(Create ML,--language auto)     train-transformer(SetFit→CoreML,
   每标签验证报告                                checkpoint + finetune + HTML 报告)
   ↘                                              ↘
        --install-ios → apps/ios/GeneratedModels/
```

多语言策略:**单一多语言模型**(非按语言拆分)—— 依据见
`docs/TRAINING.md#多语言策略`。样本语言由客户端 `NLLanguageRecognizer`
写入 `textLanguage`,训练侧检测兜底。

## 数据契约

- 训练行:`{"text": string, "label": leaf-id}` NDJSON,全工具链通用。
- 模型 sidecar:`<Name>.manifest.json`(labels/maxSequenceLength/casing/
  vocab 文件名),`TransformerClassifierLoader` / `PIIDetectorLoader` 消费。
- 分类:`packages/taxonomy/taxonomy.json` 是唯一事实源。
