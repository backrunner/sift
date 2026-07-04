# 开发流程与规范

## 环境

macOS + Xcode 16(Swift 6)、pnpm 10、uv(Python 3.10–3.12)、XcodeGen。
`pnpm install` 后即可跑 TS 侧;iOS 侧 `cd apps/ios && swift build`。

## 验证矩阵(提交前按改动范围执行)

| 改动 | 必跑 |
| --- | --- |
| Swift(App/核心) | `swift build && swift test && swift run CoreSmokeTests`(apps/ios) |
| project.yml / 资源 | `xcodegen generate` 后再构建 |
| taxonomy.json | `pnpm --filter @sift/taxonomy generate:swift` + iOS 构建 + trainer `--generate-synthetic` 冒烟 |
| 语料模板 | trainer 冒烟 + `curate --audit-only --strict-audit` |
| curate / 训练脚本 | `python3 -m py_compile` + `python3 -m unittest discover -s tools/transformer-trainer/tests` |
| TS 工具 | `pnpm typecheck && pnpm test` |
| 法律/隐私相关 | 同步 `docs/PRIVACY.md`、`docs/legal/*`、`apps/legal-site` 三处 |

## 测试铁律

- **零假阳性容忍**:断言具体值,不断言"不崩溃";轮询等待必须超时并
  `Issue.record`。
- 共享态(UserDefaults/App Group/ledger)一律注入独立 suite,测试并行安全。
- 外部服务(CloudKit/StoreKit/网络)只测协议 mock;真实后端只在真机验证。
- UI 层薄:业务断言写在 `SiftAppModel`/core 层测试上。

## 本地化流程

1. 代码中新 UI 文案:`String(localized: "中文原文")`(源语言 zh-Hans)。
2. 在 `apps/ios/SiftApp/Localizable.xcstrings` 增加 en/ja 词条
   (带插值的 key 用 `%@`/`%lld` 形态)。
3. 分类名改 `taxonomy.json` 的 `titles`,不改代码。

## 数据/隐私变更清单

新增云端字段 = `schema.ckdb` + 客户端写入 + `export --raw` + 
`infra/cloudkit/README.md` + `docs/PRIVACY.md` + legal 文案,一个都不能少。
schema 变更需 `xcrun cktool save-schema` 重新导入(dev → prod)。

## 发布物

- App:`tools/upload_ios_testflight.sh`(TestFlight)。
- 模型:`pnpm pipeline -- all --install-ios` 产出并安装;transformer/PII
  为可选资源,缺失时 App 自动降级(经典模型/纯规则脱敏)。
- IAP:App Store Connect 配置非消耗型 `com.alkinum.sift.premium`。
