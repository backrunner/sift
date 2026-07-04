# AGENTS.md — Sift 开发指南

> 供 AI 编码代理与新成员使用的项目速览与硬性规范。细节见 `agents/` 目录:
> [architecture.md](agents/architecture.md) · [development.md](agents/development.md)

## 项目是什么

Sift 是隐私优先的 iOS 短信过滤应用:设备端分类(IdentityLookup 扩展)、
50 叶子三语分类体系(zh/en/ja 一级)、双模型(Create ML 经典可微调 +
SetFit Transformer 付费高级版)、CloudKit 匿名样本收集与用户私有库统计、
全自动训练管线。**未上线,无需向后兼容。**

## 目录速查

| 路径 | 内容 |
| --- | --- |
| `apps/ios` | SwiftPM 模块(MessageFilterCore / SiftAppKit / MessageFilterExtensionKit)+ XcodeGen 工程 |
| `packages/taxonomy` | 分类唯一事实源(`taxonomy.json`),`generate:swift` 产出 Taxonomy.swift |
| `tools/apple-trainer` | Create ML 训练器 + 多语言合成语料(zh/en/ja 全标签) |
| `tools/transformer-trainer` | SetFit→CoreML 训练器、`curate_dataset.py` 质量过筛/审计 |
| `tools/pii-trainer` | 可选 CoreML PII 脱敏模型训练器 |
| `tools/cloudkit` | CloudKit 服务端导出(TS) |
| `tools/pipeline` | `pnpm pipeline` 全自动编排(stdlib Python) |
| `infra/cloudkit` | 容器 schema(`schema.ckdb`,cktool 导入) |
| `docs/` | TAXONOMY / TRAINING / PRIVACY / legal(商店级 TOS 与隐私政策) |

## 硬性规范(违反即返工)

1. **分类 id 永不改动**;展示名走 `taxonomy.json` 的 `titles`(zh/en/ja),改后必须
   `pnpm --filter @sift/taxonomy generate:swift` 重新生成。
2. **zh/en/ja 是一级语言**:新增叶子必须三语模板齐备(trainer 生成期硬校验),
   语料改动跑 `curate --strict-audit`。
3. **用户可见文案必须本地化**:Swift 里用 `String(localized: "中文原文")`,
   并同步 `apps/ios/SiftApp/Localizable.xcstrings`(zh-Hans 为源,en/ja 必填);
   正则/键名等非 UI 字符串禁止包裹。
4. **隐私红线**:样本载荷永不携带身份字段;统计只有计数;新增云端字段必须
   同步 `schema.ckdb`、导出脚本 `--raw`、`docs/PRIVACY.md` 与 legal 文案。
5. **测试隔离**:任何触碰共享 UserDefaults/App Group 的测试必须用独立
   suite(`UUID` 后缀)并 `removePersistentDomain` 清理;禁止依赖执行顺序。
6. **副作用注入**:CloudKit/StoreKit 一律走协议缝(`RemoteSampleSubmitting` /
   `PremiumPurchasing`),单测永不触网;`CKContainer` 构造必须有
   `#if os(iOS)` 或注入保护(无 entitlement 环境会抛 ObjC 异常)。
7. **XcodeGen 是工程事实源**:改 `project.yml` 后必须 `xcodegen generate`;
   不手改 `project.pbxproj`。
8. **模型产物不进 git**:`GeneratedModels/` 里的 transformer/PII 产物由训练器
   `--install-ios` 安装,在 `project.yml` 中标记 `optional: true`。
9. Swift 6 严格并发:跨 actor 传递的类型必须显式 `Sendable`。
10. 提交前最低验证:`cd apps/ios && swift build && swift test && swift run CoreSmokeTests`
    + 涉及 TS 时 `pnpm typecheck && pnpm test`
    + 涉及语料/过筛时 `python3 -m unittest discover -s tools/transformer-trainer/tests`。

## 常用命令

```bash
pnpm pipeline -- all --install-ios      # 全自动训练管线(见 docs/TRAINING.md)
pnpm pipeline -- finetune               # 从检查点增量微调
pnpm export:training                    # CloudKit 样本导出
cd apps/ios && xcodegen generate        # 重新生成 Xcode 工程
```
