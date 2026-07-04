# Sift 短信分类体系(taxonomy)设计与标注指南

50 个叶子标签,9 个分组。分组决定系统过滤动作(`systemAction`):`spam → junk`、
`promotion → promotion`、其余 → `transaction`(iOS IdentityLookup 只有这三档 +
放行)。叶子粒度服务于**统计展示与训练**,不影响拦截档位。

## 设计原则

1. **id 永不改动**——训练语料、已发布模型与 CloudKit 数据都以 id 为键;
   展示名(title)可以随时润色。
2. **每组保留 `*.other`** 兜底,避免标注者硬塞错类。
3. **组间边界以"发信方意图"为准,而不是文本关键词**(见下)。

## 易混淆边界(标注/补充模板时必读)

| 边界 | 判定 |
| --- | --- |
| `finance.bank` vs `finance.income` vs `finance.consumption` | 银行=账户/管理类通知(余额、卡片、网点);入账=**钱进来**(工资、转账到账、报销);消费=**钱出去且面向商户**(POS、扫码、订阅扣费)。银行动账短信按资金方向归入后两者,纯管理类才是 bank。 |
| `life.express` vs `life.logistics` vs `life.pickup_code` | 快递=面向收件人的派送状态;物流=干线/仓配/货运视角(分拨、装车、冷链);取件码=**含取件凭证码**的到件通知(有码优先归取件码)。 |
| `promotion` vs `carrier.promotion` vs `spam` | promotion=一般商户营销(可含退订);carrier.promotion=**运营商自营**套餐/流量/宽带营销;spam=违法违规或欺诈(仿冒、贷款诈骗、刷单、色情、钓鱼链接)。"烦人但合法"是 promotion,"骗人/违法"才是 spam。 |
| `verification` vs `transaction.account_security` | 有一次性验证码=verification;无码的登录提醒/密码变更/异地登录=账号安全。 |
| `transaction.message` vs `transaction.other` | 平台消息=站内信/评论/客服回复等**内容型**通知;other=状态型兜底。 |
| `government.notice` vs `government.policy` | notice=针对个人事项的办理进度;policy=面向公众的政策发布。 |

## 统计口径

App 内统计按 `systemAction` 三档(拦截/推广/正常)+ 分组两级展示;
每日计数桶存 App Group,并以用户 **CloudKit 私有库** 做跨设备备份
(`FilterStats` 记录,详见 `infra/cloudkit/README.md`)。统计数据永远
不含短信内容,只有计数。

## 变更流程

改 `packages/taxonomy/taxonomy.json` 后运行:

```bash
pnpm --filter @sift/taxonomy generate:swift
```

新增叶子必须同步补齐 zh/en/ja 三语种子模板(`tools/apple-trainer` 会在生成期
硬校验),并跑 `pnpm pipeline -- curate --strict-audit` 确认覆盖。
