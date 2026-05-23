import CoreML
import CreateML
import CryptoKit
import Foundation
import NaturalLanguage

struct SampleRow: Codable, Hashable, Sendable {
    let text: String
    let label: String
}

struct TaxonomyDocument: Decodable {
    let groups: [LabelGroup]
}

struct LabelGroup: Decodable {
    let leaves: [LeafLabel]
}

struct LeafLabel: Decodable {
    let id: String
}

enum AlgorithmChoice: String {
    case auto
    case bert
    case maxent
}

enum TrainerMode {
    case train
    case generateSynthetic
    case buildPublicCorpus
}

struct TrainerArguments {
    var mode: TrainerMode = .train
    var inputURL: URL?
    var syntheticOutputURL: URL?
    var publicCorpusOutputURL: URL?
    var outputDirectory: URL?
    var taxonomyURL: URL?
    var version = "0.1.0"
    var modelName = "SiftSMSClassifier"
    var algorithm: AlgorithmChoice = .auto
    var validationFraction = 0.15
    var perLabel = 50
    var publicPerLabel = 500
    var installToIOS = false
    var compileModel = true

    static func parse(_ raw: [String]) throws -> TrainerArguments {
        var arguments = TrainerArguments()
        var index = 0

        func value(after flag: String) throws -> String {
            let next = index + 1
            guard next < raw.count else {
                throw TrainerError.missingValue(flag)
            }
            index = next
            return raw[next]
        }

        while index < raw.count {
            let token = raw[index]
            switch token {
            case "--generate-synthetic":
                arguments.mode = .generateSynthetic
                arguments.syntheticOutputURL = URL(fileURLWithPath: try value(after: token).expandedPath)
            case "--build-public-corpus":
                arguments.mode = .buildPublicCorpus
                arguments.publicCorpusOutputURL = URL(fileURLWithPath: try value(after: token).expandedPath)
            case "--input":
                arguments.inputURL = URL(fileURLWithPath: try value(after: token).expandedPath)
            case "--out":
                arguments.outputDirectory = URL(fileURLWithPath: try value(after: token).expandedPath)
            case "--taxonomy":
                arguments.taxonomyURL = URL(fileURLWithPath: try value(after: token).expandedPath)
            case "--version":
                arguments.version = try value(after: token)
            case "--model-name":
                arguments.modelName = try value(after: token)
            case "--algorithm":
                let rawValue = try value(after: token)
                guard let algorithm = AlgorithmChoice(rawValue: rawValue) else {
                    throw TrainerError.invalidArgument("Unknown algorithm: \(rawValue). Use auto, bert, or maxent.")
                }
                arguments.algorithm = algorithm
            case "--validation-fraction":
                let rawValue = try value(after: token)
                guard let fraction = Double(rawValue), fraction >= 0, fraction < 0.5 else {
                    throw TrainerError.invalidArgument("--validation-fraction must be >= 0 and < 0.5")
                }
                arguments.validationFraction = fraction
            case "--per-label":
                let rawValue = try value(after: token)
                guard let count = Int(rawValue), count > 0 else {
                    throw TrainerError.invalidArgument("--per-label must be greater than 0")
                }
                arguments.perLabel = count
            case "--public-per-label":
                let rawValue = try value(after: token)
                guard let count = Int(rawValue), count > 0 else {
                    throw TrainerError.invalidArgument("--public-per-label must be greater than 0")
                }
                arguments.publicPerLabel = count
            case "--install-ios":
                arguments.installToIOS = true
            case "--skip-compile":
                arguments.compileModel = false
            case "--help", "-h":
                throw TrainerError.helpRequested
            default:
                throw TrainerError.invalidArgument("Unknown argument: \(token)")
            }
            index += 1
        }

        return arguments
    }
}

enum TrainerError: Error, CustomStringConvertible {
    case helpRequested
    case missingInput
    case missingSyntheticOutput
    case missingPublicCorpusOutput
    case missingValue(String)
    case invalidArgument(String)
    case invalidDataset(String)
    case missingRepoRoot
    case unsupportedBERT

    var description: String {
        switch self {
        case .helpRequested:
            return Self.help
        case .missingInput:
            return "Missing required --input <samples.ndjson>."
        case .missingSyntheticOutput:
            return "Missing required --generate-synthetic <samples.ndjson> output path."
        case .missingPublicCorpusOutput:
            return "Missing required --build-public-corpus <samples.ndjson> output path."
        case let .missingValue(flag):
            return "Missing value after \(flag)."
        case let .invalidArgument(message):
            return message
        case let .invalidDataset(message):
            return message
        case .missingRepoRoot:
            return "Could not locate repo root containing packages/taxonomy/taxonomy.json."
        case .unsupportedBERT:
            return "BERT transfer learning requires macOS 14 or newer."
        }
    }

    static let help = """
    Usage:
      swift run SiftAppleTrainer --generate-synthetic <samples.ndjson> [--per-label 50]
      swift run SiftAppleTrainer --build-public-corpus <samples.ndjson> [--per-label 50] [--public-per-label 500]
      swift run SiftAppleTrainer --input <samples.ndjson> [options]

    Options:
      --generate-synthetic <path>
                                  Generate synthetic seed rows as Apple-trainer NDJSON.
      --build-public-corpus <path>
                                  Generate synthetic rows, fetch public SMS corpora, and write balanced NDJSON.
      --per-label <n>             Synthetic rows per leaf label. Defaults to 50.
      --public-per-label <n>      Max public rows retained per leaf label. Defaults to 500.
      --out <dir>                 Output directory. Defaults to <repo>/build/apple-model.
      --taxonomy <path>           Taxonomy JSON. Defaults to <repo>/packages/taxonomy/taxonomy.json.
      --version <version>         Model version written into metadata and manifest.
      --model-name <name>         Base artifact name. Defaults to SiftSMSClassifier.
      --algorithm <auto|bert|maxent>
                                  auto prefers Create ML BERT transfer learning, then falls back to MaxEnt.
      --validation-fraction <n>   Per-label holdout fraction. Defaults to 0.15.
      --install-ios              Copy .mlmodel and manifest into apps/ios/GeneratedModels.
      --skip-compile             Skip local .mlmodelc compilation smoke artifact.
    """
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xA0761D6478BD642F : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func integer(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }

    mutating func choice(_ values: [String]) -> String {
        values[Int(next() % UInt64(values.count))]
    }
}

struct TrainingSplit {
    let training: [SampleRow]
    let validation: [SampleRow]
}

struct PublicCorpusRow: Hashable, Sendable {
    let row: SampleRow
    let source: String
    let sourceLabel: String
}

enum SyntheticSeedCorpus {
    static let templates: [String: [String]] = [
        "finance.bank": [
            "您尾号 {tail} 的账户完成扣款 {amount} 元，如非本人操作请联系银行。",
            "账户余额变动提醒：入账 {amount} 元，交易时间 {time}。",
            "{bank}通知：跨行转账 {amount} 元已提交，预计 {minutes} 分钟内到账。",
            "借记卡尾号 {tail} 在 {time} 完成一笔支出 {amount} 元。",
            "您的账户状态已更新，预约取现业务将于 {date} 生效。",
            "电子回单已生成，可在手机银行查看交易编号 {order}。",
            "{bank}APP 升级提醒，新版本已支持人脸识别。",
            "您的 U 盾即将过期，请于 {date} 前到柜台更换。",
            "{bank}存款产品到期，{amount} 元本息已自动续存。",
            "您预约的开户业务办理时间为 {date} {time}。"
        ],
        "finance.insurance": [
            "保单已生效，保障金额 {amount} 元，生效日期 {date}。",
            "理赔资料已受理，预计 {days} 个工作日完成审核。",
            "{brand}保险提醒：续保报价已生成，请在 {date} 前确认。",
            "您的车险保单批改已完成，最新保费为 {amount} 元。",
            "健康险核保结果已更新，可登录服务号查看详情。",
            "保险缴费提醒：本期应缴 {amount} 元，扣款日 {date}。"
        ],
        "finance.wealth": [
            "理财产品 {brand} 今日净值更新，参考收益率 {percent}%。",
            "产品到期提醒：请在 {date} 前处理赎回或续投。",
            "基金定投扣款 {amount} 元已确认，份额将在下个交易日更新。",
            "{bank}理财提醒：持仓产品风险等级信息已调整。",
            "理财赎回申请已受理，预计 {days} 个工作日内到账。",
            "现金管理产品收益已发放，金额 {amount} 元。"
        ],
        "finance.credit_card": [
            "信用卡账单已出，本期应还 {amount} 元，最后还款日 {date}。",
            "信用卡尾号 {tail} 交易 {amount} 元，请按时还款。",
            "信用卡自动还款已预约，将于 {date} 从绑定账户扣款。",
            "您尾号 {tail} 的信用卡额度调整申请已受理。",
            "分期账单提醒：本期分期应还 {amount} 元。",
            "信用卡还款成功，入账金额 {amount} 元。"
        ],
        "finance.consumption": [
            "消费提醒：您在 {brand} 完成支付 {amount} 元。",
            "商户扣款成功，交易时间 {time}，金额 {amount} 元。",
            "您通过 {platform} 向 {merchant} 支付 {amount} 元。",
            "收款方 {merchant} 已确认收款，订单号 {order}。",
            "扫码支付成功，金额 {amount} 元，交易时间 {time}。",
            "银行卡尾号 {tail} 完成快捷支付 {amount} 元。"
        ],
        "finance.income": [
            "您尾号 {tail} 的账户收到一笔转账 {amount} 元，余额 {amount2} 元。",
            "工资到账提醒：本月工资 {amount} 元已发放至工资卡。",
            "{brand} 转账已入账，金额 {amount} 元，付款方 {name}。",
            "收款成功，对方 {name} 已向您转账 {amount} 元。",
            "您的账户于 {time} 收到一笔款项 {amount} 元。",
            "ATM 存款提醒：账户尾号 {tail} 存入现金 {amount} 元。",
            "代发款项 {amount} 元已到账，付款单位 {brand}。"
        ],
        "finance.refund": [
            "您的退款 {amount} 元已原路返回，预计 {minutes} 分钟内到账。",
            "订单退款成功，金额 {amount} 元已退回原支付账户。",
            "{platform}退款提醒：售后单 {order} 已完成退款。",
            "商户已发起退款 {amount} 元，请留意账户变动。",
            "退款审核通过，资金将在 {days} 个工作日内返回。",
            "部分退款已到账，退款金额 {amount} 元。"
        ],
        "finance.stock": [
            "股票 {brand} 今日涨跌幅 {percent}%，请及时关注市场变化。",
            "证券账户持仓有更新，委托成交 {count} 股。",
            "新股申购提醒：您可申购额度 {count} 股。",
            "证券账户资金余额已变动，变动金额 {amount} 元。",
            "委托撤单成功，委托编号 {order}。",
            "持仓风险提示：标的价格波动较大，请关注账户风险。"
        ],
        "finance.other": [
            "您的账户有一条新通知，请登录网银查看。",
            "财务服务提醒：请确认最新业务状态。",
            "电子发票抬头信息已更新，请在 {date} 前确认。",
            "资金证明申请已受理，办理进度可在线查看。",
            "财务资料补充提醒：请上传最新证明文件。",
            "账户服务协议已更新，请查看变更摘要。"
        ],
        "transaction.order": [
            "订单 {order} 已支付成功，商家正在备货。",
            "您有一笔订单已发货，物流信息已更新。",
            "{platform}提醒：预约订单将在 {time} 开始服务。",
            "订单 {order} 已取消，相关费用将按规则处理。",
            "商家已接单，预计 {minutes} 分钟后完成准备。",
            "订单尾款已支付，发票申请已同步提交。"
        ],
        "transaction.points": [
            "本次消费获得积分 {points}，可在下次下单时抵扣。",
            "会员积分即将到期，请尽快使用。",
            "{brand}积分到账 {points} 分，当前积分余额已更新。",
            "积分兑换申请已受理，兑换码将在稍后发放。",
            "您有 {points} 积分将在 {date} 到期。",
            "积分抵扣成功，本次抵扣 {amount} 元。"
        ],
        "transaction.member": [
            "会员等级已升级至 {tier}，专属权益已生效。",
            "您的会员卡即将到期，续费后可继续享受服务。",
            "{brand}会员生日权益已发放，请在 {date} 前使用。",
            "会员资料审核通过，会员编号 {order}。",
            "您已成功开通 {tier} 会员，有效期至 {date}。",
            "会员权益变更提醒：可用权益数量已更新。"
        ],
        "transaction.message": [
            "您有一条站内消息：{task}。",
            "消息中心已更新，{count} 条未读信息。",
            "{platform}通知：客服已回复您的咨询。",
            "互动消息提醒：您收到一条新的评论回复。",
            "系统消息：您关注的服务状态有更新。",
            "消息提醒：协同成员已完成 {task}。"
        ],
        "transaction.account_security": [
            "账号安全提醒：检测到新设备登录，请确认是否本人操作。",
            "登录保护已开启，若非本人请立即修改密码。",
            "您的账号在 {time} 进行了密码修改。",
            "安全验证已通过，本次操作设备已加入可信列表。",
            "异地登录提醒：账号在新位置完成登录。",
            "账号绑定手机号变更申请已提交，如非本人请冻结账号。"
        ],
        "transaction.other": [
            "交易中心有新的状态更新，请进入应用查看。",
            "账户服务通知：系统已完成一次信息同步。",
            "服务单 {order} 状态已变更，请查看处理进度。",
            "您有一项待确认事项，请在 {date} 前完成确认。",
            "平台通知：订阅服务状态已更新。",
            "业务记录已归档，可在历史记录中查看。"
        ],
        "life.takeaway": [
            "外卖已送达，请到门口取餐。",
            "您的餐品已出餐，骑手正在配送中。",
            "{merchant}已接单，预计 {minutes} 分钟送达。",
            "骑手已到达取餐点，正在等待商家出餐。",
            "外卖订单已取消，退款将按原路返回。",
            "餐品配送异常，骑手将与您联系确认地址。"
        ],
        "life.express": [
            "您的快递已到达 {station}，请凭取件码 {code} 领取。",
            "包裹正在派送，预计今天送达。",
            "{courier}快递提醒：包裹已由快递员开始派送。",
            "您的包裹已签收，签收地点为 {station}。",
            "快递派送失败，将于明日再次投递。",
            "包裹已转入代收点，取件信息稍后发送。"
        ],
        "life.utility": [
            "水费账单 {amount} 元已生成，请在 {date} 前缴费。",
            "电费提醒：本月应缴 {amount} 元。",
            "燃气费账单已出，本期应缴 {amount} 元。",
            "物业缴费提醒：{date} 前缴清可避免滞纳金。",
            "宽带账单 {amount} 元已生成，扣费日为 {date}。",
            "停车费缴费成功，金额 {amount} 元。"
        ],
        "life.logistics": [
            "物流单号 {order} 已进入运输节点，预计明天到达。",
            "您的包裹已到分拨中心，物流状态已更新。",
            "货物已完成装车，运输路线已同步更新。",
            "物流异常提醒：收件地址需补充门牌信息。",
            "订单 {order} 已离开发货仓，下一站为 {station}。",
            "大件物流预约派送时间为 {date} {time}。"
        ],
        "life.pickup_code": [
            "您有一件包裹已到驿站，取件码 {code}。",
            "快递柜已投递完成，取件码 {code}。",
            "{station}提醒：凭码 {code} 领取包裹。",
            "取件通知：尾号 {tail} 包裹取件码 {code}。",
            "代收点已入库，请在 {days} 天内凭取件码领取。",
            "自提柜门号已生成，取件码 {code}。"
        ],
        "life.medical": [
            "挂号成功，预约时间 {date} {time}。",
            "检查报告已出，请登录医院小程序查看。",
            "{hospital}提醒：就诊号 {count}，请提前到院取号。",
            "体检预约成功，请于 {date} 空腹到院。",
            "复诊提醒：您的预约医生将在 {time} 接诊。",
            "处方已开具，可在医院服务平台查看取药信息。"
        ],
        "life.weather": [
            "天气预警：{city} 预计 {time} 有强降雨，请注意防范。",
            "高温预警：{city} 今日最高气温 {temp} 度。",
            "{city}气象台发布大风预警，请减少户外活动。",
            "未来 {days} 天降温明显，请及时添衣。",
            "暴雨黄色预警已发布，请注意道路积水。",
            "空气质量提醒：今日污染扩散条件较差。",
            "{city}今日有阵雨，建议出门携带雨具。",
            "寒潮预警：未来 {days} 天最低气温 {temp} 度。"
        ],
        "life.other": [
            "生活服务通知：您的申请已受理。",
            "社区服务提醒：请留意最新公告。",
            "家政服务预约成功，服务时间为 {date} {time}。",
            "维修工单 {order} 已派单，请保持电话畅通。",
            "社区活动报名成功，请按时到场签到。",
            "门禁授权已更新，有效期至 {date}。"
        ],
        "travel.tourism": [
            "您的旅行订单已确认，酒店入住时间为 {date}。",
            "行程提醒：景点门票已出票。",
            "酒店预订成功，入住人为尾号 {tail} 用户。",
            "旅游团集合提醒：请于 {time} 到达集合点。",
            "行程变更通知：导游将在 {minutes} 分钟内联系您。",
            "民宿订单已确认，入住验证码 {code}。"
        ],
        "travel.transport": [
            "交通出行提醒：您的班次将于 {time} 出发。",
            "航班延误通知，请留意后续改签信息。",
            "打车订单已完成，行程金额 {amount} 元。",
            "公交到站提醒：下一班车预计 {minutes} 分钟后到达。",
            "停车场出场缴费成功，车牌尾号 {tail}。",
            "接送机司机已出发，预计 {minutes} 分钟后到达。"
        ],
        "travel.ticketing": [
            "您购买的机票已出票，航班号 {flight}。",
            "车票预订成功，乘车信息已发送。",
            "火车票出票成功，车次 {train}，发车时间 {time}。",
            "演出票已出票，请凭取票码 {code} 入场。",
            "退票申请已受理，手续费以页面显示为准。",
            "改签成功，新班次将在 {date} {time} 出发。"
        ],
        "travel.other": [
            "出行服务通知：订单状态已更新。",
            "旅程安排已完成，请查看详情。",
            "租车订单已确认，取车时间为 {date} {time}。",
            "签证材料审核进度已更新，请查看补充要求。",
            "行李寄送服务已下单，物流单号 {order}。",
            "出行保障服务已生效，保障期至 {date}。"
        ],
        "work.reminder": [
            "待办提醒：{task} 需要在 {time} 前完成。",
            "日程提醒：{task} 即将开始。",
            "项目提醒：{task} 的截止日期为 {date}。",
            "值班提醒：您将在今晚 {time} 开始值班。",
            "回复提醒：{name} 在 {time} 等待您的反馈。",
            "周报提醒：请于 {date} 前提交本周工作总结。"
        ],
        "work.alert": [
            "系统告警：{task} 发生异常，请立即处理。",
            "监控提醒：接口响应时间超过阈值。",
            "告警恢复：服务 {task} 已恢复正常。",
            "安全告警：检测到异常登录尝试。",
            "服务器磁盘空间不足，请尽快扩容。",
            "监控通知：任务失败次数达到阈值。",
            "Pager 告警：值班人员请立即登录处理 P{count}。",
            "构建失败提醒：流水线 {brand} 在 {time} 出错。"
        ],
        "work.meeting": [
            "会议提醒：{time} 开始，请提前进入会议室。",
            "线上会议邀请：链接已发送至邮箱。",
            "{platform}会议提醒：会议将在 {minutes} 分钟后开始。",
            "会议室预订成功，地点 {city} 大厦 {count} 楼。",
            "周会通知：{date} {time}，议题已发布。",
            "腾讯会议邀请：会议号 {order}，请准时出席。",
            "Zoom 会议提醒：{date} {time}，密码已发送。"
        ],
        "work.approval": [
            "审批提醒：有一条流程等待您处理。",
            "您提交的请假单已通过审批。",
            "报销审批提醒：金额 {amount} 元的报销已进入复核。",
            "OA 通知：流程 {order} 待审批，请尽快处理。",
            "{name} 已驳回您的审批申请，请查看意见。",
            "调休申请已通过，可在系统查看明细。"
        ],
        "work.attendance": [
            "考勤提醒：今日打卡记录已同步。",
            "请假记录已生效，请假时长 {count} 小时。",
            "外勤打卡提醒：您在 {city} 完成了上班打卡。",
            "考勤异常提醒：{date} 缺少下班打卡。",
            "排班通知：本周您将在 {date} 值班。",
            "加班记录已生成，时长 {count} 小时。"
        ],
        "work.announcement": [
            "公司公告：节假日安排请关注详情。",
            "组织公告已发布，请查看最新安排。",
            "全员通知：本周五下午 {time} 召开月度大会。",
            "新员工入职公告：{name} 已加入 {brand} 团队。",
            "公司福利通知：{date} 起调整餐补政策。",
            "团建活动报名提醒：请在 {date} 前确认参加。"
        ],
        "work.training": [
            "培训通知：课程将在 {date} 开始。",
            "在线课程提醒：{task} 已分配给您。",
            "考试提醒：在线考试将在 {date} {time} 开始。",
            "认证培训提醒：您的证书将在 {date} 到期。",
            "学习计划已更新，请按时完成本周课程。",
            "新员工培训提醒：第 {count} 节课程将在 {time} 开课。"
        ],
        "work.other": [
            "工作消息中心有新的更新。",
            "任务协同提醒：存在一条未读消息。",
            "报销单 {order} 已进入财务审核。",
            "工作邮件 {task} 已分配给 {name}。",
            "项目协作平台有新的评论待回复。",
            "团队管理通知：成员权限已调整。"
        ],
        "carrier.call_reminder": [
            "您有一通未接来电，来电提醒已生成。",
            "来电助手通知：近期有 {count} 次未接通话。",
            "{carrier}提醒：号码尾号 {tail} 曾在 {time} 呼叫您。",
            "漏话提醒：对方未留言，可选择回拨。",
            "语音信箱有新留言，请拨打服务号码收听。",
            "来电管家已为您拦截疑似骚扰来电 {count} 次。"
        ],
        "carrier.data_reminder": [
            "本月流量已使用 {count}GB，套餐剩余 {remain}GB。",
            "套餐提醒：您的流量包即将到期。",
            "{carrier}提醒：国内通用流量剩余 {remain}GB。",
            "话费余额不足 {amount} 元，请及时充值。",
            "本月语音通话已使用 {count} 分钟。",
            "流量封顶保护已开启，达到阈值后将暂停上网。"
        ],
        "carrier.service": [
            "业务办理已受理，处理结果将通过短信通知。",
            "您的套餐变更申请已经提交。",
            "{carrier}通知：实名信息校验已通过。",
            "补换卡申请已提交，请携带证件到营业厅领取。",
            "宽带移机预约成功，师傅将在 {date} 联系您。",
            "国际漫游功能已开通，有效期至 {date}。"
        ],
        "carrier.promotion": [
            "宽带提速活动开启，回复 T 了解详情。",
            "通信优惠推荐：办理新套餐可享折扣。",
            "{carrier}优惠：充值满 {amount} 元可获流量礼包。",
            "老用户专享套餐升级活动，回复数字办理。",
            "办理家庭宽带可享设备优惠，活动截止 {date}。",
            "视频会员联合权益限时领取，详询营业厅。"
        ],
        "carrier.other": [
            "运营商通知：您的账户状态已更新。",
            "通信服务提醒：请注意最新公告。",
            "{carrier}服务评价邀请：请对本次服务进行评分。",
            "网络维护通知：{date} 凌晨部分业务可能短暂中断。",
            "号码状态提醒：副卡资料已同步更新。",
            "通信账单明细已生成，可在掌厅查看。"
        ],
        "government.notice": [
            "政务服务通知：{task} 已受理，请留意后续消息。",
            "官方通知：请按照流程完成信息确认。",
            "社区通知：请在 {date} 前完成信息采集。",
            "证件办理进度已更新，请查看政务平台。",
            "出入境业务申请进入下一步，请关注短信通知。",
            "户籍办理结果已出，请到指定窗口领取。"
        ],
        "government.traffic": [
            "交管提醒：业务预约成功，请于 {date} 到窗口办理。",
            "您的车辆 {tail} 在 {date} 有违章记录，请及时处理。",
            "驾驶证年审提醒：请于 {date} 前完成审验。",
            "ETC 通行通知：本次通行扣费 {amount} 元。",
            "车辆年检预约已确认，请按时到检测站。",
            "12123 通知：您的处罚决定书已生成。"
        ],
        "government.tax": [
            "税务通知：申报事项已提交，审核结果将短信告知。",
            "电子税务局：本月增值税申报已完成。",
            "个税年度汇算开始，请登录 App 办理。",
            "您的退税申请已审核通过，金额 {amount} 元。",
            "税收宣传月活动通知，请关注最新政策。",
            "发票领用申请审批通过，请到办税厅领取。"
        ],
        "government.social_security": [
            "社保缴费成功，本月缴费金额 {amount} 元。",
            "医保提醒：账户余额 {amount} 元，可在定点机构使用。",
            "公积金通知：本月缴存额已入账。",
            "社保转移业务办理完成，请查看明细。",
            "医保电子凭证已激活，可在医院结算使用。",
            "公积金贷款审批进度已更新，请到柜台确认。"
        ],
        "government.court": [
            "法院通知：案号 {order}，请在 {date} 到庭。",
            "司法送达提醒：电子送达文书请及时签收。",
            "调解通知：调解时间为 {date} {time}。",
            "执行通知：请在 {date} 前履行义务。",
            "立案登记通知：您的诉讼材料已受理。",
            "庭审排期变更通知，请关注法院公告。"
        ],
        "government.policy": [
            "民生政策提醒：补贴资格审核已开始。",
            "新规发布：自 {date} 起施行，请关注详情。",
            "就业扶持政策更新，请查阅政府网站。",
            "住房保障申请通道开放，详情请咨询社区。",
            "防疫政策调整通知，请按要求执行。",
            "国务院最新通告已发布，请前往官网查看。"
        ],
        "government.other": [
            "政务中心提醒：请关注最新公告。",
            "公共服务消息：您的事项已进入下一流程。",
            "公共缴费服务已恢复，可继续办理相关事项。",
            "民生服务提醒：预约排队号为 {count}。",
            "便民服务申请已提交，结果将在 {days} 个工作日内反馈。",
            "公共平台账号资料已更新。"
        ],
        "verification": [
            "您的验证码是 {code}，{minutes} 分钟内有效，请勿泄露。",
            "登录验证：{code}，如非本人操作请忽略。",
            "{platform}安全校验码 {code}，用于本次身份确认。",
            "支付验证码 {code}，请勿转发给他人。",
            "注册验证码为 {code}，有效期 {minutes} 分钟。",
            "修改密码验证码 {code}，工作人员不会索要。",
            "{brand} 验证码 {code}，{minutes} 分钟内输入。",
            "Verification code: {code}. Do not share with anyone.",
            "您的动态密码是 {code}，请尽快完成验证。",
            "OTP code: {code}, valid for {minutes} mins.",
            "{platform} 提醒：登录二步验证码 {code}。",
            "找回密码请使用验证码 {code}。",
            "Your {brand} security code is {code}.",
            "短信验证码 {code}，仅用于本次申请。"
        ],
        "promotion": [
            "限时优惠，{brand} 会员立减 {amount} 元，回复T退订。",
            "{brand} 活动开启，前 {count} 名下单可享折扣。",
            "{merchant}新品上架，今日下单享满减优惠。",
            "会员日活动开始，优惠券已放入账户。",
            "门店周年庆，凭短信到店可领小礼品。",
            "直播专场今晚 {time} 开始，前 {count} 名享特价。",
            "{merchant} 双 11 大促，跨店满 300 减 50，详见 {url}",
            "{merchant} 618 狂欢节，全场 {percent} 折，戳 {url} 抢购。",
            "{brand} 黑五专场，会员 {tier} 加赠 {points} 积分。",
            "{merchant} 新店开业，到店领取 {amount} 元代金券。",
            "{brand} 圣诞礼包限时领，{url} 一键参与。",
            "{merchant}周二会员日，第二件半价。",
            "您绑定的 {brand} 账户有 {count} 张优惠券待领取。",
            "{merchant} 端午专场，部分商品 {percent} 折起。",
            "感恩回馈：{brand} 老用户专享 {amount} 元红包。",
            "{merchant} 春装上新，新客立减 {amount} 元，{url}",
            "{brand} 自营美妆 {percent} 折，限今晚 {time} 前。",
            "{merchant} 火锅 {amount} 元代金券请查收，回 T 退订。",
            "{merchant}咖啡满 4 件第 5 件免费，限 {date} 使用。",
            "{brand} 健身房 {city} 店年卡 {amount} 元，详情 {url}",
            "{merchant} 早教课程体验价 {amount} 元/节，{url}",
            "{brand} 教育平台秋季招生，名师试听课预约通道开启。",
            "{merchant}美容院新客 {amount} 元体验项目，到店核销。",
            "{brand} 二手车检测惠民活动，免费上门，{url}",
            "{merchant} 装修公司免设计 + 5 年质保，回复 1 预约。",
            "{merchant} 房产顾问推送：{city} 新盘开盘，特惠房源 {count} 套。",
            "{brand} 母婴店奶粉满 3 罐 8 折，下单即送湿巾。",
            "{merchant} 宠物医院疫苗 {amount} 元起，老客 {percent} 折。",
            "{brand} 在线英语，0 元领 7 天体验包，{url}",
            "{merchant} 早鸟价 {amount} 元抢购，限 {count} 个。",
            "您的 {brand} 银行积分将在 {date} 到期，{url} 兑换好礼。",
            "{platform} 跨境购满减开启，最高省 {amount} 元，戳 {url}",
            "{merchant}双倍积分日，会员消费可获 {points} 积分。",
            "{brand} VIP 客户专享，预约即赠精美伴手礼。"
        ],
        "spam": [
            "高收益理财推荐，立即加入领取福利，回复T退订。",
            "中奖通知：请尽快联系客服领取奖品。",
            "兼职刷单日结 {amount} 元，加客服领取任务。",
            "您的账户异常，请点击链接完成认证，否则将冻结。",
            "低息贷款秒批，凭身份证最高可借 {amount} 元。",
            "出售发票和证件办理服务，详情联系在线客服。",
            "[警告] 您账户存在风险，请点击 {url} 立即处理。",
            "恭喜您被抽中 iPhone 一部，请联系 QQ {order} 领取。",
            "兼职在家做单 {amount} 元/天，加微信 {order} 详谈。",
            "黑户秒下款，无视征信，详询 {url}",
            "代办各类证件、文凭，价格优惠，QQ {order}",
            "{name} 您还款 {amount} 元已逾期，立即处理 {url}",
            "彩票内幕计划稳赚 {percent}%，加客服 {order}",
            "您预订的快递无法签收，请通过 {url} 重新认证。",
            "您的 {brand} 账号涉嫌违规，请立即处理 {url}",
            "邀请您加入 {brand} 高净值理财群，年化 {percent}%。",
            "您的 ETC 已失效，请通过 {url} 完成激活。",
            "您 {bank} 卡升级，立即点击 {url} 完成验证。",
            "色情服务/伴游联系 QQ {order}，绝对保密。",
            "代写论文/代发表，加微信 {order}",
            "您的话费可兑换 {amount} 元话费券，{url} 领取。",
            "海外购房黄金机会，{percent}% 收益保证，{url}"
        ]
    ]
}

struct ReleaseManifest: Encodable {
    let version: String
    let trainedAt: String
    let taxonomyHash: String
    let featureHasherVersion: String
    let sha256: String
    let modelURL: String?
    let modelArtifact: String
    let compiledArtifact: String?
    let algorithm: String
    let language: String
    let labels: [String]
    let trainingCount: Int
    let validationCount: Int
    let trainingClassificationError: Double
    let validationClassificationError: Double?
}

@main
enum SiftAppleTrainer {
    static func main() {
        do {
            let arguments = try TrainerArguments.parse(Array(CommandLine.arguments.dropFirst()))
            try run(arguments: arguments)
        } catch TrainerError.helpRequested {
            print(TrainerError.help)
        } catch {
            writeError("error: \(error)")
            exit(1)
        }
    }

    static func run(arguments initialArguments: TrainerArguments) throws {
        var arguments = initialArguments

        let repoRoot = try locateRepoRoot()
        if arguments.taxonomyURL == nil {
            arguments.taxonomyURL = repoRoot.appendingPathComponent("packages/taxonomy/taxonomy.json")
        }

        guard let taxonomyURL = arguments.taxonomyURL else {
            throw TrainerError.missingRepoRoot
        }

        switch arguments.mode {
        case .generateSynthetic:
            guard let outputURL = arguments.syntheticOutputURL else {
                throw TrainerError.missingSyntheticOutput
            }
            let labels = try loadTaxonomyLabels(from: taxonomyURL)
            let rows = try generateSyntheticRows(perLabel: arguments.perLabel, validLabels: labels)
            try writeNDJSON(rows, to: outputURL)
            print("synthetic rows: \(rows.count)")
            print("output: \(outputURL.path)")
            return
        case .buildPublicCorpus:
            guard let outputURL = arguments.publicCorpusOutputURL else {
                throw TrainerError.missingPublicCorpusOutput
            }
            let labels = try loadTaxonomyLabels(from: taxonomyURL)
            let syntheticRows = try generateSyntheticRows(perLabel: arguments.perLabel, validLabels: labels)
            let publicRows = try fetchPublicCorpusRows(publicPerLabel: arguments.publicPerLabel)
            let rows = deduplicate(syntheticRows + publicRows.map(\.row))
            try validate(rows: rows, validLabels: labels)
            try writeNDJSON(rows, to: outputURL)

            print("synthetic rows: \(syntheticRows.count)")
            print("public rows retained: \(publicRows.count)")
            print("total rows: \(rows.count)")
            print("output: \(outputURL.path)")
            printLabelCounts(rows)
            printPublicSourceSummary(publicRows)
            printPublicLabelCounts(publicRows)
            return
        case .train:
            break
        }

        guard let inputURL = arguments.inputURL else {
            throw TrainerError.missingInput
        }

        if arguments.outputDirectory == nil {
            arguments.outputDirectory = repoRoot.appendingPathComponent("build/apple-model", isDirectory: true)
        }

        guard let outputDirectory = arguments.outputDirectory else {
            throw TrainerError.missingRepoRoot
        }

        let rows = try loadRows(from: inputURL)
        let validLabels = try loadTaxonomyLabels(from: taxonomyURL)
        try validate(rows: rows, validLabels: validLabels)

        let split = stratifiedSplit(rows: rows, validationFraction: arguments.validationFraction, seed: 42)
        let labels = Array(Set(rows.map(\.label))).sorted()
        let algorithmResult = try trainWithFallback(
            arguments: arguments,
            trainingRows: split.training,
            validationRows: split.validation
        )

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let modelURL = outputDirectory.appendingPathComponent("\(arguments.modelName).mlmodel")
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }

        let metadata = MLModelMetadata(
            author: "Sift",
            shortDescription: "Create ML SMS text classifier for Sift.",
            license: "Apache-2.0",
            version: arguments.version
        )
        try algorithmResult.classifier.write(to: modelURL, metadata: metadata)

        let compiledURL = try compileIfNeeded(
            modelURL: modelURL,
            outputDirectory: outputDirectory,
            modelName: arguments.modelName,
            enabled: arguments.compileModel
        )

        let manifest = ReleaseManifest(
            version: arguments.version,
            trainedAt: isoTimestamp(),
            taxonomyHash: try sha256(ofFile: taxonomyURL),
            featureHasherVersion: "create-ml-text-v1",
            sha256: try sha256(ofFile: modelURL),
            modelURL: nil,
            modelArtifact: modelURL.lastPathComponent,
            compiledArtifact: compiledURL?.lastPathComponent,
            algorithm: algorithmResult.algorithmName,
            language: NLLanguage.simplifiedChinese.rawValue,
            labels: labels,
            trainingCount: split.training.count,
            validationCount: split.validation.count,
            trainingClassificationError: algorithmResult.classifier.trainingMetrics.classificationError,
            validationClassificationError: algorithmResult.validationMetrics?.classificationError
        )

        let manifestURL = outputDirectory.appendingPathComponent("\(arguments.modelName).manifest.json")
        try writeJSON(manifest, to: manifestURL)

        if arguments.installToIOS {
            try installIntoIOSResources(
                modelURL: modelURL,
                manifestURL: manifestURL,
                repoRoot: repoRoot,
                modelName: arguments.modelName
            )
        }

        print("Create ML model trained.")
        print("algorithm: \(algorithmResult.algorithmName)")
        print("training samples: \(split.training.count)")
        print("validation samples: \(split.validation.count)")
        print("model: \(modelURL.path)")
        if let compiledURL {
            print("compiled: \(compiledURL.path)")
        }
        print("manifest: \(manifestURL.path)")
        if arguments.installToIOS {
            print("installed: \(repoRoot.appendingPathComponent("apps/ios/GeneratedModels").path)")
        }
    }
}

struct AlgorithmResult {
    let classifier: MLTextClassifier
    let algorithmName: String
    let validationMetrics: MLClassifierMetrics?
}

func trainWithFallback(
    arguments: TrainerArguments,
    trainingRows: [SampleRow],
    validationRows: [SampleRow]
) throws -> AlgorithmResult {
    do {
        return try train(
            choice: arguments.algorithm,
            trainingRows: trainingRows,
            validationRows: validationRows
        )
    } catch {
        guard arguments.algorithm == .auto else {
            throw error
        }
        writeError("warning: BERT transfer learning failed, falling back to MaxEnt: \(error)")
        return try train(choice: .maxent, trainingRows: trainingRows, validationRows: validationRows)
    }
}

func train(
    choice: AlgorithmChoice,
    trainingRows: [SampleRow],
    validationRows: [SampleRow]
) throws -> AlgorithmResult {
    let algorithm: MLTextClassifier.ModelAlgorithmType
    let algorithmName: String

    switch choice {
    case .auto, .bert:
        guard #available(macOS 14.0, *) else {
            if choice == .auto {
                return try train(choice: .maxent, trainingRows: trainingRows, validationRows: validationRows)
            }
            throw TrainerError.unsupportedBERT
        }
        algorithm = .transferLearning(.bertEmbedding, revision: nil)
        algorithmName = "create-ml-bert-transfer"
    case .maxent:
        algorithm = .maxEnt(revision: 1)
        algorithmName = "create-ml-maxent"
    }

    let validationData: MLTextClassifier.ModelParameters.ValidationData = validationRows.isEmpty
        ? .none
        : .dictionary(groupedTexts(validationRows))
    let parameters = MLTextClassifier.ModelParameters(
        validation: validationData,
        algorithm: algorithm,
        language: .simplifiedChinese
    )
    let classifier = try MLTextClassifier(trainingData: groupedTexts(trainingRows), parameters: parameters)
    let validationMetrics = validationRows.isEmpty ? nil : classifier.validationMetrics

    return AlgorithmResult(
        classifier: classifier,
        algorithmName: algorithmName,
        validationMetrics: validationMetrics
    )
}

func loadRows(from url: URL) throws -> [SampleRow] {
    let data = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    let rows = try data
        .split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { line in
            try decoder.decode(SampleRow.self, from: Data(line.utf8))
        }

    guard !rows.isEmpty else {
        throw TrainerError.invalidDataset("Dataset is empty: \(url.path)")
    }
    return rows
}

func fetchPublicCorpusRows(publicPerLabel: Int) throws -> [PublicCorpusRow] {
    var rows: [PublicCorpusRow] = []
    rows.append(contentsOf: try fetchFBSRows())
    rows.append(contentsOf: try fetchCodeSignalSMSRows())
    rows.append(contentsOf: try fetchReportSmishingRows())
    rows.append(contentsOf: try fetchHrwhisperChineseRows())

    rows = deduplicatePublic(rows)

    var retained: [PublicCorpusRow] = []
    for (label, bucket) in Dictionary(grouping: rows, by: { $0.row.label }).sorted(by: { $0.key < $1.key }) {
        var shuffled = bucket
        var generator = SeededGenerator(seed: stableHash("public:\(label)"))
        shuffled.shuffle(using: &generator)
        retained.append(contentsOf: shuffled.prefix(publicPerLabel))
    }

    var shuffleGenerator = SeededGenerator(seed: 84)
    retained.shuffle(using: &shuffleGenerator)
    return retained
}

func fetchFBSRows() throws -> [PublicCorpusRow] {
    let mappings: [String] = [
        "AD:Loan",
        "AD:Network_service",
        "AD:Other",
        "AD:Real_estate",
        "AD:Retail",
        "FR:Financial",
        "FR:Other",
        "FR:Phishing(Bank)",
        "FR:Phishing(Other)",
        "IL:Escort_service",
        "IL:Fake_ID_and_invoice",
        "IL:Gambling",
        "IL:Political_propaganda",
        "Other"
    ]

    var rows: [PublicCorpusRow] = []
    for file in mappings {
        let escaped = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        let url = "https://raw.githubusercontent.com/Cypher-Z/FBS_SMS_Dataset/master/\(escaped)"
        let text = try downloadText(url)
        rows.append(
            contentsOf: text
                .split(separator: "\n")
                .compactMap { line -> PublicCorpusRow? in
                    let body = normalizePublicText(String(line))
                    guard isUsablePublicText(body) else { return nil }
                    guard let label = inferFBSLabel(file: file, text: body) else {
                        return nil
                    }
                    return PublicCorpusRow(
                        row: SampleRow(text: body, label: label),
                        source: "github:Cypher-Z/FBS_SMS_Dataset",
                        sourceLabel: file
                    )
                }
        )
    }
    return rows
}

func inferFBSLabel(file: String, text: String) -> String? {
    let lower = text.lowercased()

    switch file {
    case "FR:Financial", "FR:Other", "FR:Phishing(Bank)", "FR:Phishing(Other)",
         "IL:Escort_service", "IL:Fake_ID_and_invoice", "IL:Gambling", "IL:Political_propaganda":
        return "spam"
    case "AD:Loan":
        return "promotion"
    case "AD:Network_service":
        return inferCarrierAdvertisingLabel(lower)
    case "AD:Retail", "AD:Real_estate":
        return "promotion"
    case "AD:Other":
        if containsAny(lower, ["刷单", "兼职", "在家 操作", "日 赚", "qq", "wechat"]) {
            return "spam"
        }
        return "promotion"
    case "Other":
        return inferGeneralFBSLabel(lower)
    default:
        return "spam"
    }
}

func inferCarrierAdvertisingLabel(_ text: String) -> String {
    if containsAny(text, ["来电提醒", "未接来电", "漏话", "呼叫转移"]) {
        return "carrier.call_reminder"
    }

    let hasUsageSignal = containsAny(text, ["已 使用", "剩余", "余额", "本月", "免费 项目", "话费", "流量"])
    let hasPromotionSignal = containsAny(text, ["优惠", "活动", "赠送", "免费 领取", "送", "抽奖", "下载", "折", "特价", "办理 新", "回复", "开通"])
    if hasUsageSignal && !hasPromotionSignal {
        return "carrier.data_reminder"
    }

    if containsAny(text, ["套餐 变更", "业务 办理", "申请 已经 提交", "办理 结果", "实名", "补卡", "换卡"]) && !hasPromotionSignal {
        return "carrier.service"
    }

    return "carrier.promotion"
}

func inferGeneralFBSLabel(_ text: String) -> String? {
    if containsAny(text, ["验证码", "校验码", "动态码"]) {
        return "verification"
    }
    if containsAny(text, ["气象台", "天气", "气温", "高温", "强降雨", "阵雨", "预警", "台风", "降温", "寒潮", "空气 质量"]) {
        return "life.weather"
    }
    if containsAny(text, ["交警", "12123", "违章", "驾驶证", "etc", "车辆 年检", "通行 扣费"]) {
        return "government.traffic"
    }
    if containsAny(text, ["税务", "电子 税务", "增值税", "个税", "退税", "发票 领用", "纳税"]) {
        return "government.tax"
    }
    if containsAny(text, ["社保", "医保", "公积金", "缴存", "社会 保险"]) {
        return "government.social_security"
    }
    if containsAny(text, ["法院", "司法", "立案", "庭审", "判决", "调解 通知", "执行 通知", "诉讼"]) {
        return "government.court"
    }
    if containsAny(text, ["政策", "国务院", "规划", "新规", "条例", "通告"]) {
        return "government.policy"
    }
    if containsAny(text, ["公安", "政务", "政府", "通信 管理局", "公共服务"]) {
        return "government.notice"
    }
    if containsAny(text, ["取件码", "快递柜", "驿站", "收发室", "自取"]) {
        return "life.pickup_code"
    }
    if containsAny(text, ["快递", "包裹", "派送", "物流", "中通", "圆通", "申通", "顺丰", "韵达", "投递"]) {
        return "life.express"
    }
    if containsAny(text, ["医院", "挂号", "检查报告", "门诊", "手术", "患者", "体检", "医保 卡"]) {
        return "life.medical"
    }
    if containsAny(text, ["电费", "水费", "燃气", "物业费", "宽带 账单"]) {
        return "life.utility"
    }
    if containsAny(text, ["腾讯 会议", "zoom", "视频会议", "会议 邀请", "会议室", "周会"]) {
        return "work.meeting"
    }
    if containsAny(text, ["审批", "请假", "调休", "报销 审批", "oa", "驳回"]) {
        return "work.approval"
    }
    if containsAny(text, ["打卡", "考勤", "外勤", "排班", "值班", "加班 记录"]) {
        return "work.attendance"
    }
    if containsAny(text, ["公司 公告", "全员 通知", "组织 公告", "团建", "公司 福利"]) {
        return "work.announcement"
    }
    if containsAny(text, ["培训", "课程", "在线 学习", "认证", "考试 提醒"]) {
        return "work.training"
    }
    if containsAny(text, ["待办", "日程", "周报", "项目 截止", "回复 提醒"]) {
        return "work.reminder"
    }
    if containsAny(text, ["告警", "异常", "故障", "监控", "报警", "pager", "构建 失败"]) {
        return "work.alert"
    }
    if containsAny(text, ["还款", "白条", "账单", "欠款", "应 还", "逾期"]) {
        return "finance.credit_card"
    }
    if containsAny(text, ["退款", "退回", "原路 返回", "售后 单"]) {
        return "finance.refund"
    }
    if containsAny(text, ["工资 到账", "代发", "转账 入账", "存入 现金", "向您 转账", "收到 一笔 转账", "收到 一笔 款项"]) {
        return "finance.income"
    }
    if containsAny(text, ["余额", "入账", "扣款", "转账", "到账", "银行"]) && !containsAny(text, ["贷款", "借款", "中奖", "客服", "url"]) {
        return "finance.bank"
    }
    if containsAny(text, ["会员", "会员卡", "续费", "等级"]) && !containsAny(text, ["折", "优惠", "抽奖", "退订"]) {
        return "transaction.member"
    }
    if containsAny(text, ["积分", "兑换", "累积"]) && !containsAny(text, ["url", "中奖", "退订"]) {
        return "transaction.points"
    }
    if containsAny(text, ["机顶盒", "广电 网络", "套餐 变更", "业务 办理", "服务厅"]) {
        return "carrier.service"
    }
    if containsAny(text, ["流量", "话费", "套餐", "中国移动", "联通", "电信"]) {
        return inferCarrierAdvertisingLabel(text)
    }
    if containsAny(text, ["优惠", "折", "活动", "退订", "促销", "特价", "抽奖", "会员 购物"]) {
        return "promotion"
    }

    return nil
}

func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
}

func fetchCodeSignalSMSRows() throws -> [PublicCorpusRow] {
    let csv = try downloadText("https://huggingface.co/datasets/codesignal/sms-spam-collection/resolve/main/sms-spam-collection.csv")
    return parseCSVRecords(csv).compactMap { record in
        guard record["label"]?.lowercased() == "spam" else {
            return nil
        }
        let body = normalizePublicText(record["message"] ?? "")
        guard isUsablePublicText(body) else { return nil }
        return PublicCorpusRow(
            row: SampleRow(text: body, label: "spam"),
            source: "huggingface:codesignal/sms-spam-collection",
            sourceLabel: "spam"
        )
    }
}

func fetchReportSmishingRows() throws -> [PublicCorpusRow] {
    let csv = try downloadText("https://raw.githubusercontent.com/reportsmishing/Smishing-Dataset-IMC25/main/dataset/final_dataset_output.csv")
    return parseCSVRecords(csv).compactMap { record in
        let body = normalizePublicText(record["text"] ?? record["translation"] ?? "")
        guard isUsablePublicText(body) else { return nil }
        return PublicCorpusRow(
            row: SampleRow(text: body, label: "spam"),
            source: "github:reportsmishing/Smishing-Dataset-IMC25",
            sourceLabel: record["scam_type"] ?? "smishing"
        )
    }
}

/// hrwhisper/SpamMessage: ~800k labelled Chinese SMS (label\ttext).
/// label "1" => spam, "0" => ham. We only ingest spam rows (label "1") and
/// heuristically split them into Sift's `spam` (fraud / illegal / phishing)
/// vs `promotion` buckets — this is exactly the "real-world merchant
/// promotion" distribution we lack. Ham rows are skipped entirely because
/// the dataset's ham is generic Chinese sentences, not labelled per
/// transactional sub-category, so content-inference would inject noisy
/// labels and hurt accuracy.
func fetchHrwhisperChineseRows() throws -> [PublicCorpusRow] {
    let url = "https://raw.githubusercontent.com/hrwhisper/SpamMessage/master/data/%E5%B8%A6%E6%A0%87%E7%AD%BE%E7%9F%AD%E4%BF%A1.txt"
    let text = try downloadText(url)
    var rows: [PublicCorpusRow] = []
    rows.reserveCapacity(80_000)

    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "1" else { continue }
        let body = normalizePublicText(String(parts[1]))
        guard isUsablePublicText(body) else { continue }
        let leaf = inferChineseSpamSplit(body)
        rows.append(PublicCorpusRow(
            row: SampleRow(text: body, label: leaf),
            source: "github:hrwhisper/SpamMessage",
            sourceLabel: "spam"
        ))
    }
    return rows
}

/// Distinguish hard fraud / illegal-services from "annoying-but-legal" promo.
private func inferChineseSpamSplit(_ text: String) -> String {
    let lower = text.lowercased()
    let fraudKeywords = [
        "中奖", "诈骗", "贷款", "借款", "代办", "代开", "代理", "刷单", "兼职", "日结", "高薪",
        "色情", "博彩", "赌博", "六合彩", "彩票", "私彩", "钓鱼", "冻结", "认证 链接",
        "qq", "vx", "微信 加", "wechat", "联系 客服", "联系 在线", "证件", "发票"
    ]
    if fraudKeywords.contains(where: { lower.contains($0) }) {
        return "spam"
    }
    return "promotion"
}

func downloadText(_ urlString: String) throws -> String {
    guard let url = URL(string: urlString) else {
        throw TrainerError.invalidArgument("Invalid URL: \(urlString)")
    }
    let data = try Data(contentsOf: url)
    return String(decoding: data, as: UTF8.self)
}

func parseCSVRecords(_ csv: String) -> [[String: String]] {
    let rows = parseCSVRows(csv)
    guard let header = rows.first else {
        return []
    }

    return rows.dropFirst().map { row in
        Dictionary(uniqueKeysWithValues: header.enumerated().map { index, key in
            (key, index < row.count ? row[index] : "")
        })
    }
}

func parseCSVRows(_ csv: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var index = csv.startIndex

    while index < csv.endIndex {
        let character = csv[index]
        switch character {
        case "\"":
            let next = csv.index(after: index)
            if inQuotes, next < csv.endIndex, csv[next] == "\"" {
                field.append("\"")
                index = next
            } else {
                inQuotes.toggle()
            }
        case "," where !inQuotes:
            row.append(field)
            field = ""
        case "\n" where !inQuotes:
            row.append(field)
            if row.contains(where: { !$0.isEmpty }) {
                rows.append(row)
            }
            row = []
            field = ""
        case "\r":
            break
        default:
            field.append(character)
        }

        index = csv.index(after: index)
    }

    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) {
            rows.append(row)
        }
    }

    return rows
}

func normalizePublicText(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

func isUsablePublicText(_ text: String) -> Bool {
    let count = text.count
    return count >= 8 && count <= 500
}

func deduplicatePublic(_ rows: [PublicCorpusRow]) -> [PublicCorpusRow] {
    var seen = Set<String>()
    var retained: [PublicCorpusRow] = []
    for row in rows {
        let key = "\(row.row.label)\u{1F}\(row.row.text)"
        if seen.insert(key).inserted {
            retained.append(row)
        }
    }
    return retained
}

func generateSyntheticRows(perLabel: Int, validLabels: Set<String>) throws -> [SampleRow] {
    let missing = validLabels.subtracting(SyntheticSeedCorpus.templates.keys)
    guard missing.isEmpty else {
        throw TrainerError.invalidDataset("Missing synthetic templates: \(missing.sorted().joined(separator: ", "))")
    }

    var rows: [SampleRow] = []
    rows.reserveCapacity(validLabels.count * perLabel)

    for label in validLabels.sorted() {
        guard let templates = SyntheticSeedCorpus.templates[label] else {
            continue
        }

        var labelRows: [SampleRow] = []
        var seenTexts = Set<String>()
        var attempt = 0
        let maxAttempts = max(perLabel * 100, 1_000)

        while labelRows.count < perLabel && attempt < maxAttempts {
            var generator = SeededGenerator(seed: stableHash("\(label):\(attempt)"))
            let template = templates[attempt % templates.count]
            var text = fillSyntheticTemplate(template, generator: &generator)
            if seenTexts.contains(text) {
                text = "\(text)通知编号 \(100000 + (attempt % 900000))。"
            }
            if seenTexts.insert(text).inserted {
                labelRows.append(SampleRow(text: text, label: label))
            }
            attempt += 1
        }

        guard labelRows.count == perLabel else {
            throw TrainerError.invalidDataset("Could only generate \(labelRows.count) unique synthetic rows for \(label).")
        }

        rows.append(contentsOf: labelRows)
    }

    var shuffleGenerator = SeededGenerator(seed: 42)
    rows.shuffle(using: &shuffleGenerator)
    return rows
}

func fillSyntheticTemplate(_ template: String, generator: inout SeededGenerator) -> String {
    let brand = generator.choice([
        "星云", "云闪付", "麦芽", "安心", "晨光", "拾光", "青禾", "松果", "云鹿", "海岚",
        "知乎严选", "得物", "花田", "好物社", "悠选", "甄品", "壹号", "百果", "鲜乐",
        "蜜柚", "橙子优选", "白咖啡", "唐宁书店", "山月", "野象", "米淘", "拾贝", "锦绣",
        "禾木", "山下", "途客", "悦享", "时光里", "云上", "Today", "OBOR", "Easy购"
    ])
    let bank = generator.choice([
        "东湖银行", "海川银行", "银杉银行", "城市银行", "中信银行", "招商银行", "平安银行",
        "建设银行", "工商银行", "农业银行", "交通银行", "邮储银行", "民生银行", "光大银行",
        "兴业银行", "浦发银行", "广发银行", "华夏银行", "渤海银行", "北京银行", "上海银行"
    ])
    let platform = generator.choice([
        "星云生活", "麦芽到家", "云仓", "安心服务", "美团", "饿了么", "拼多多", "淘宝", "京东",
        "天猫", "抖音", "快手", "小红书", "得物", "唯品会", "携程", "去哪儿", "飞猪",
        "马蜂窝", "高德", "滴滴", "T3 出行", "曹操出行", "瑞幸", "肯德基", "星巴克", "喜茶"
    ])
    let merchant = generator.choice([
        "青禾超市", "拾光餐厅", "松果便利", "云鹿商行", "好嘉超市", "鲜丰水果", "永辉超市",
        "全家便利", "罗森", "7-Eleven", "M Stand", "瑞幸咖啡", "Manner", "茶颜悦色", "霸王茶姬",
        "海底捞", "西贝莜面村", "巴奴毛肚", "九毛九", "外婆家", "奈雪", "蜜雪冰城", "古茗",
        "肯德基", "麦当劳", "汉堡王", "塔斯汀", "南城香", "家乐福", "山姆会员店", "盒马鲜生",
        "ZARA", "优衣库", "海澜之家", "森马", "李宁", "安踏", "迪卡侬", "屈臣氏", "万宁",
        "丝芙兰", "完美日记", "花西子", "INTO YOU", "护肤研习社", "宠物之家", "怡和书店"
    ])
    let courier = generator.choice([
        "云达", "顺捷", "丰行", "中联", "顺丰", "中通", "圆通", "申通", "韵达", "百世",
        "京东物流", "极兔", "德邦", "EMS", "菜鸟", "天天", "宅急送"
    ])
    let carrier = generator.choice([
        "中国移动", "中国联通", "中国电信", "广电网络", "中国广电"
    ])
    let hospital = generator.choice([
        "市一医院", "和康门诊", "仁安医院", "中心医院", "协和医院", "同仁医院", "瑞金医院",
        "华山医院", "中山医院", "人民医院", "妇幼保健院", "口腔医院", "儿童医院", "肿瘤医院"
    ])
    let city = generator.choice([
        "北京", "上海", "杭州", "深圳", "广州", "成都", "武汉", "南京", "西安", "重庆",
        "苏州", "天津", "长沙", "青岛", "厦门", "宁波", "无锡", "合肥", "佛山", "东莞"
    ])
    let name = generator.choice([
        "李先生", "王女士", "张老师", "刘工", "陈同学", "赵经理", "黄主任", "周顾问",
        "吴先生", "徐女士", "孙老师", "马总", "朱医生", "胡客户经理", "林女士",
        "Mr. Lee", "Ms. Wang", "Tony", "Linda", "James"
    ])
    let url = generator.choice([
        "h5.brand.cn/p/", "m.shop.com/i/", "promo.app/", "act.brand.com/d/",
        "go.platform.cn/x/", "v.merchant.io/c/", "u.brand.cn/r/", "t.cn/", "dwz.cn/"
    ]) + String(generator.integer(in: 100000...999999))

    let replacements = [
        "{tail}": String(generator.integer(in: 1000...9999)),
        "{amount}": "\(generator.integer(in: 1...999)).\(String(format: "%02d", generator.integer(in: 0...99)))",
        "{amount2}": "\(generator.integer(in: 100...99999)).\(String(format: "%02d", generator.integer(in: 0...99)))",
        "{time}": "\(String(format: "%02d", generator.integer(in: 0...23))):\(String(format: "%02d", generator.integer(in: 0...59)))",
        "{date}": "2026-\(String(format: "%02d", generator.integer(in: 1...12)))-\(String(format: "%02d", generator.integer(in: 1...28)))",
        "{days}": String(generator.integer(in: 1...30)),
        "{percent}": "\(generator.integer(in: 1...45)).\(generator.integer(in: 0...9))",
        "{brand}": brand,
        "{minutes}": String(generator.integer(in: 1...30)),
        "{count}": String(generator.integer(in: 1...99)),
        "{points}": String(generator.integer(in: 10...9999)),
        "{tier}": generator.choice(["白银", "黄金", "铂金", "钻石", "黑金", "至尊", "至臻", "PLUS", "PRO"]),
        "{task}": generator.choice([
            "提交周报", "确认订单", "完成审批", "检查账单", "处理告警", "审核合同",
            "回复邮件", "更新文档", "上传材料", "完成签字", "校对数据", "录入凭证"
        ]),
        "{station}": generator.choice([
            "北门驿站", "幸福里驿站", "云仓站点", "丰巢快递柜", "菜鸟驿站", "蜂收站",
            "小区物业", "校区收发室", "便利店代收", "顺丰柜机"
        ]),
        "{code}": String(generator.integer(in: 100000...999999)),
        "{order}": String(generator.integer(in: 100000000...999999999)),
        "{flight}": generator.choice(["CA", "MU", "CZ", "HU", "FM", "9C", "ZH"]) + String(generator.integer(in: 1000...9999)),
        "{train}": generator.choice(["G", "D", "K", "T", "Z", "C"]) + String(generator.integer(in: 100...9999)),
        "{remain}": String(generator.integer(in: 1...100)),
        "{city}": city,
        "{temp}": String(generator.integer(in: 30...42)),
        "{bank}": bank,
        "{platform}": platform,
        "{merchant}": merchant,
        "{courier}": courier,
        "{carrier}": carrier,
        "{hospital}": hospital,
        "{name}": name,
        "{url}": url
    ]

    let body = replacements.reduce(template) { text, replacement in
        text.replacingOccurrences(of: replacement.key, with: replacement.value)
    }

    let prefixes = [
        "",
        "【\(brand)】",
        "[\(brand)] ",
        "\(brand)提醒：",
        "\(brand)通知 - ",
        "短信通知：",
        "尊敬的用户，",
        "\(brand)服务通知：",
        "您好，",
        "系统通知：",
        "Hi \(name)，",
        "亲爱的会员，",
        "\(brand) | ",
        "[官方] "
    ]
    let suffixes = [
        "",
        "请及时查看。",
        "可在App内查看详情。",
        "如已处理请忽略。",
        "感谢您的配合。",
        "详情以页面显示为准。",
        "如有疑问请联系官方渠道。",
        "本消息仅作状态提醒。",
        " 详见 \(url)",
        "（回T退订）",
        "[退订回T]",
        " 戳→ \(url)",
        "（如非本人请忽略）",
        " — \(brand)",
        "请勿回复本短信。"
    ]

    var output = "\(generator.choice(prefixes))\(body)\(generator.choice(suffixes))"
    output = applyTextNoise(output, generator: &generator)
    return output
}

/// Random surface noise: punctuation/whitespace/emoji jitter so the model
/// generalises beyond clean templates. Each transform fires with low probability
/// so the original text usually survives intact.
func applyTextNoise(_ text: String, generator: inout SeededGenerator) -> String {
    var output = text

    // 半角/全角标点互换
    if generator.integer(in: 0...9) < 3 {
        output = output
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".")
    } else if generator.integer(in: 0...9) < 2 {
        output = output
            .replacingOccurrences(of: ",", with: "，")
            .replacingOccurrences(of: ".", with: "。")
    }

    // 偶尔加 emoji
    let emojiSets: [String] = ["✨", "🎉", "💸", "📦", "🚚", "🔔", "⚡", "🛒", "❗", "💰", "🌧", "☀️"]
    if generator.integer(in: 0...9) < 2 {
        let emoji = generator.choice(emojiSets)
        output = "\(emoji) \(output)"
    }
    if generator.integer(in: 0...19) < 2 {
        let emoji = generator.choice(emojiSets)
        output = "\(output) \(emoji)"
    }

    // 偶尔大写英文段或重复感叹号
    if generator.integer(in: 0...19) < 2 {
        output = output.replacingOccurrences(of: "!", with: "!!")
    }

    // 偶尔多余空格
    if generator.integer(in: 0...19) < 2 {
        output = output.replacingOccurrences(of: " ", with: "  ")
    }

    return output
}

func loadTaxonomyLabels(from url: URL) throws -> Set<String> {
    let data = try Data(contentsOf: url)
    let taxonomy = try JSONDecoder().decode(TaxonomyDocument.self, from: data)
    return Set(taxonomy.groups.flatMap { group in
        group.leaves.map(\.id)
    })
}

func validate(rows: [SampleRow], validLabels: Set<String>) throws {
    let unknown = Set(rows.map(\.label)).subtracting(validLabels)
    guard unknown.isEmpty else {
        throw TrainerError.invalidDataset("Unknown labels: \(unknown.sorted().joined(separator: ", "))")
    }

    let labels = Set(rows.map(\.label))
    guard labels.count >= 2 else {
        throw TrainerError.invalidDataset("Training requires at least two labels.")
    }

    let emptyTextCount = rows.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    guard emptyTextCount == 0 else {
        throw TrainerError.invalidDataset("Dataset contains \(emptyTextCount) empty text rows.")
    }
}

func stratifiedSplit(rows: [SampleRow], validationFraction: Double, seed: UInt64) -> TrainingSplit {
    guard validationFraction > 0 else {
        return TrainingSplit(training: rows, validation: [])
    }

    var grouped: [String: [SampleRow]] = [:]
    for row in rows {
        grouped[row.label, default: []].append(row)
    }

    var training: [SampleRow] = []
    var validation: [SampleRow] = []

    for (label, labelRows) in grouped {
        var shuffled = labelRows
        var generator = SeededGenerator(seed: seed ^ stableHash(label))
        shuffled.shuffle(using: &generator)

        let validationCount: Int
        if shuffled.count >= 5 {
            let desired = Int((Double(shuffled.count) * validationFraction).rounded())
            validationCount = min(max(1, desired), shuffled.count - 1)
        } else {
            validationCount = 0
        }

        validation.append(contentsOf: shuffled.prefix(validationCount))
        training.append(contentsOf: shuffled.dropFirst(validationCount))
    }

    return TrainingSplit(training: training, validation: validation)
}

func groupedTexts(_ rows: [SampleRow]) -> [String: [String]] {
    var grouped: [String: [String]] = [:]
    for row in rows {
        grouped[row.label, default: []].append(row.text)
    }
    return grouped
}

func deduplicate(_ rows: [SampleRow]) -> [SampleRow] {
    var seen = Set<String>()
    var retained: [SampleRow] = []
    for row in rows {
        let key = "\(row.label)\u{1F}\(row.text)"
        if seen.insert(key).inserted {
            retained.append(row)
        }
    }
    return retained
}

func printLabelCounts(_ rows: [SampleRow]) {
    let counts = Dictionary(grouping: rows, by: \.label)
        .mapValues(\.count)
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
    print("label distribution:")
    for item in counts {
        print("  \(item.key): \(item.value)")
    }
}

func printPublicSourceSummary(_ rows: [PublicCorpusRow]) {
    let counts = Dictionary(grouping: rows, by: \.source)
        .mapValues(\.count)
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
    print("public source distribution:")
    for item in counts {
        print("  \(item.key): \(item.value)")
    }
}

func printPublicLabelCounts(_ rows: [PublicCorpusRow]) {
    let counts = Dictionary(grouping: rows, by: { $0.row.label })
        .mapValues(\.count)
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
    print("public label distribution:")
    for item in counts {
        print("  \(item.key): \(item.value)")
    }
}

func writeNDJSON(_ rows: [SampleRow], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    let payload = try rows
        .map { row in
            String(decoding: try encoder.encode(row), as: UTF8.self)
        }
        .joined(separator: "\n")
    try (payload + "\n").write(to: url, atomically: true, encoding: .utf8)
}

func compileIfNeeded(
    modelURL: URL,
    outputDirectory: URL,
    modelName: String,
    enabled: Bool
) throws -> URL? {
    guard enabled else {
        return nil
    }

    let temporaryURL = try MLModel.compileModel(at: modelURL)
    let compiledURL = outputDirectory.appendingPathComponent("\(modelName).mlmodelc", isDirectory: true)
    if FileManager.default.fileExists(atPath: compiledURL.path) {
        try FileManager.default.removeItem(at: compiledURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: compiledURL)
    return compiledURL
}

func installIntoIOSResources(
    modelURL: URL,
    manifestURL: URL,
    repoRoot: URL,
    modelName: String
) throws {
    let generatedModelsURL = repoRoot.appendingPathComponent("apps/ios/GeneratedModels", isDirectory: true)
    try FileManager.default.createDirectory(at: generatedModelsURL, withIntermediateDirectories: true)

    let installedModelURL = generatedModelsURL.appendingPathComponent("\(modelName).mlmodel")
    let installedManifestURL = generatedModelsURL.appendingPathComponent("\(modelName).manifest.json")

    for url in [installedModelURL, installedManifestURL] where FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }

    try FileManager.default.copyItem(at: modelURL, to: installedModelURL)
    try FileManager.default.copyItem(at: manifestURL, to: installedManifestURL)
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
}

func locateRepoRoot() throws -> URL {
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    while true {
        let marker = directory.appendingPathComponent("packages/taxonomy/taxonomy.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            return directory
        }

        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path {
            throw TrainerError.missingRepoRoot
        }
        directory = parent
    }
}

func sha256(ofFile url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func stableHash(_ text: String) -> UInt64 {
    var value: UInt64 = 1469598103934665603
    for byte in text.utf8 {
        value ^= UInt64(byte)
        value &*= 1099511628211
    }
    return value
}

func isoTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

extension String {
    var expandedPath: String {
        (self as NSString).expandingTildeInPath
    }
}
