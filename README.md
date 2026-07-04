<div align="center">

# 🛡️ Sift

**隐私优先的 iOS 智能短信过滤 · Privacy-first on-device SMS filtering**

分类在设备上完成 · 样本贡献匿名且可撤回 · 中文 / English / 日本語

[![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-black?logo=apple)](apps/ios)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](apps/ios/Package.swift)
[![License](https://img.shields.io/badge/code-Apache--2.0-blue)](LICENSE)
[![Brand](https://img.shields.io/badge/name%20%26%20icon-All%20rights%20reserved-8A2BE2)](TRADEMARKS.md)
[![i18n](https://img.shields.io/badge/i18n-zh%20%C2%B7%20en%20%C2%B7%20ja-2ea44f)](docs/TAXONOMY.md)

</div>

---

短信收件箱不该是垃圾场。Sift 在 **你的 iPhone 上** 把短信分进 50 个精细类别
(垃圾、推广、验证码、快递、银行……),内容永远不离开设备;想帮模型变得
更聪明时,可以**匿名**贡献一条脱敏样本——并且随时看到、导出、或彻底抹掉
自己贡献过的一切。

## ✨ 亮点

| | |
| --- | --- |
| 🧠 **双模型架构** | 经典 Create ML 模型(支持**设备端微调**)+ SetFit Transformer 多语言模型(高级版内购,一次买断) |
| 🌍 **三语一级支持** | 分类体系与 App 界面完整支持中 / 英 / 日;语料另覆盖 es·pt·fr·de·ru·ko·id·vi·th |
| 🔒 **双轨脱敏** | 规则引擎(手机号/证件号/邮箱/卡号/验证码/地址/人名)∪ 可选设备端 Core ML PII 模型,并集脱敏、规则兜底 |
| ☁️ **匿名可撤回的贡献** | CloudKit 公共库,零身份字段;回执删除、历史列表单条抹除、一键 GDPR 全量擦除与 JSON 导出 |
| 📊 **本地统计** | 每日拦截计数(永不含内容),备份到你自己的 iCloud 私有库 |
| 🤖 **全自动训练管线** | `pnpm pipeline -- all --install-ios`:抓数据 → 质量过筛 → 三语审计 → 双模型训练(断点续训/增量微调)→ 装进 App;训练报告 HTML 可视化 |
| 🧪 **可信的测试体系** | 45 项 Swift 测试 + TS/Python 单测,全部隔离、零外部依赖 |

## 🚀 快速开始

```bash
git clone <repo> && cd sift
pnpm install

# iOS 核心:构建 + 测试 + 冒烟
cd apps/ios && swift test && swift run CoreSmokeTests

# 打开 Xcode 工程(需要 xcodegen)
xcodegen generate && open Sift.xcodeproj

# 训练两个模型并装进 App(详见 docs/TRAINING.md)
pnpm pipeline -- all --skip fetch-remote --install-ios
```

## 🏗️ 仓库结构

```
apps/ios                  SwiftUI App + IdentityLookup 过滤扩展(SwiftPM 模块化)
apps/legal-site           隐私政策 / 服务条款静态站(SvelteKit)
packages/taxonomy         50 叶子三语分类体系(唯一事实源)
tools/apple-trainer       Create ML 训练器 + 多语言合成语料
tools/transformer-trainer SetFit→CoreML 训练器 + 数据质量过筛/审计
tools/pii-trainer         设备端 PII 脱敏模型训练器(可选)
tools/cloudkit            CloudKit 样本导出(server-to-server)
tools/pipeline            一条命令的全自动训练编排
infra/cloudkit            容器 schema(cktool 导入)
docs                      TRAINING / TAXONOMY / PRIVACY / legal(商店级文档)
```

深入阅读:**[训练管线手册](docs/TRAINING.md)** ·
[架构总览](agents/architecture.md) · [开发规范](AGENTS.md) ·
[分类设计与标注指南](docs/TAXONOMY.md) · [隐私说明](docs/PRIVACY.md)

## 🔐 隐私承诺

- 过滤永远在设备上;扩展进程不联网。
- 贡献是显式同意 + 脱敏预览后才发生;载荷零身份字段。
- 统计只有数字,存在**你的** iCloud 私有库,我们读不到。
- 应用内即可行使 GDPR 权利:导出全部提交、抹除全部提交。

完整文档:[Privacy Policy](docs/legal/PRIVACY_POLICY.md) ·
[Terms of Service](docs/legal/TERMS_OF_SERVICE.md)
(线上版本 `sift.alkinum.io/privacy` · `/tos`)

## ⚖️ 许可与商标

**代码**以 [Apache License 2.0](LICENSE) 开源。
**"Sift" 名称、应用图标与品牌资产不在开源范围内,保留所有权利** ——
Fork 发行请更换名称、图标、bundle id 与 CloudKit 容器,详见
[TRADEMARKS.md](TRADEMARKS.md)。

---

<div align="center">
<sub>Built with ❤️ for a quieter inbox · © Alkinum</sub>
</div>
