import CoreML
import CreateML
import CryptoKit
import Foundation
import NaturalLanguage

/// Canonical framework-neutral dataset row. Persisted corpora and CloudKit
/// exports stay in this shape; Core ML/Create ML adaptation happens only at
/// the training boundary.
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
    var splitSeed: UInt64 = 42
    var perLabel = 50
    var corePerLabel: Int?
    var intlPerLabel = 12
    var languages: [SeedLanguage] = SeedLanguage.allCases
    var trainingLanguage = "auto"
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
            case "--split-seed":
                let rawValue = try value(after: token)
                guard let seed = UInt64(rawValue) else {
                    throw TrainerError.invalidArgument("--split-seed must be a non-negative integer")
                }
                arguments.splitSeed = seed
            case "--per-label":
                let rawValue = try value(after: token)
                guard let count = Int(rawValue), count > 0 else {
                    throw TrainerError.invalidArgument("--per-label must be greater than 0")
                }
                arguments.perLabel = count
            case "--core-per-label":
                let rawValue = try value(after: token)
                guard let count = Int(rawValue), count >= 0 else {
                    throw TrainerError.invalidArgument("--core-per-label must be >= 0")
                }
                arguments.corePerLabel = count
            case "--intl-per-label":
                let rawValue = try value(after: token)
                guard let count = Int(rawValue), count >= 0 else {
                    throw TrainerError.invalidArgument("--intl-per-label must be >= 0")
                }
                arguments.intlPerLabel = count
            case "--languages":
                let rawValue = try value(after: token)
                guard let languages = SeedLanguage.parse(rawValue) else {
                    let supported = SeedLanguage.allCases.map(\.rawValue).joined(separator: ",")
                    throw TrainerError.invalidArgument("Unknown language list: \(rawValue). Supported: \(supported) or all.")
                }
                arguments.languages = languages
            case "--language":
                let rawValue = try value(after: token).lowercased()
                arguments.trainingLanguage = rawValue
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
                                  Generate synthetic seed rows as framework-neutral text/label NDJSON.
      --build-public-corpus <path>
                                  Generate synthetic rows, fetch public SMS corpora, and write balanced text/label NDJSON.
      --per-label <n>             Chinese synthetic rows per leaf label. Defaults to 50.
      --core-per-label <n>        Rows per label for the other first-class languages
                                  (en, ja). Defaults to the --per-label value.
      --intl-per-label <n>        Rows per covered label for every remaining language.
                                  Defaults to 12; 0 disables those rows.
      --languages <list|all>      Comma-separated seed languages (zh,en,es,pt,fr,de,ru,ja,ko,id,vi,th).
                                  Defaults to all.
      --language <code|auto>      Training language hint for Create ML. auto picks
                                  zh-Hans for pure-Chinese corpora and multilingual otherwise.
      --public-per-label <n>      Max public rows retained per leaf label. Defaults to 500.
      --out <dir>                 Output directory. Defaults to <repo>/build/apple-model.
      --taxonomy <path>           Taxonomy JSON. Defaults to <repo>/packages/taxonomy/taxonomy.json.
      --version <version>         Model version written into metadata and manifest.
      --model-name <name>         Base artifact name. Defaults to SiftSMSClassifier.
      --algorithm <auto|bert|maxent>
                                  auto prefers Create ML BERT transfer learning, then falls back to MaxEnt.
      --validation-fraction <n>   Per-label holdout fraction. Defaults to 0.15.
      --split-seed <n>            Deterministic per-label holdout seed. Defaults to 42.
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
            let rows = try generateSyntheticRows(
                perLabel: arguments.perLabel,
                corePerLabel: arguments.corePerLabel ?? arguments.perLabel,
                intlPerLabel: arguments.intlPerLabel,
                languages: arguments.languages,
                validLabels: labels
            )
            try writeNDJSON(rows, to: outputURL)
            print("languages: \(arguments.languages.map(\.rawValue).joined(separator: ","))")
            print("synthetic rows: \(rows.count)")
            print("output: \(outputURL.path)")
            return
        case .buildPublicCorpus:
            guard let outputURL = arguments.publicCorpusOutputURL else {
                throw TrainerError.missingPublicCorpusOutput
            }
            let labels = try loadTaxonomyLabels(from: taxonomyURL)
            let syntheticRows = try generateSyntheticRows(
                perLabel: arguments.perLabel,
                corePerLabel: arguments.corePerLabel ?? arguments.perLabel,
                intlPerLabel: arguments.intlPerLabel,
                languages: arguments.languages,
                validLabels: labels
            )
            let publicRows = try fetchPublicCorpusRows(publicPerLabel: arguments.publicPerLabel)
            let rows = deduplicate(syntheticRows + publicRows.map(\.row))
            try validate(rows: rows, validLabels: labels)
            try writeNDJSON(rows, to: outputURL)

            print("languages: \(arguments.languages.map(\.rawValue).joined(separator: ","))")
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

        let split = stratifiedSplit(rows: rows, validationFraction: arguments.validationFraction, seed: arguments.splitSeed)
        let labels = Array(Set(rows.map(\.label))).sorted()
        let trainingLanguage = try resolveTrainingLanguage(hint: arguments.trainingLanguage, rows: rows)
        print("training language: \(trainingLanguage?.rawValue ?? "multilingual")")
        let algorithmResult = try trainWithFallback(
            arguments: arguments,
            trainingRows: split.training,
            validationRows: split.validation,
            language: trainingLanguage
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
            language: trainingLanguage?.rawValue ?? "multilingual",
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
        printPerLabelValidationReport(
            classifier: algorithmResult.classifier,
            validationRows: split.validation
        )
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
    validationRows: [SampleRow],
    language: NLLanguage?
) throws -> AlgorithmResult {
    do {
        return try train(
            choice: arguments.algorithm,
            trainingRows: trainingRows,
            validationRows: validationRows,
            language: language
        )
    } catch {
        guard arguments.algorithm == .auto else {
            throw error
        }
        writeError("warning: BERT transfer learning failed, falling back to MaxEnt: \(error)")
        return try train(choice: .maxent, trainingRows: trainingRows, validationRows: validationRows, language: language)
    }
}

/// Maps the `--language` hint onto a Create ML training language.
/// `auto` inspects the corpus: a ≥90% single-language corpus trains with that
/// language hint; anything mixed trains language-agnostic (nil).
func resolveTrainingLanguage(hint: String, rows: [SampleRow]) throws -> NLLanguage? {
    switch hint {
    case "auto":
        return detectDominantLanguage(rows: rows)
    case "multi", "multilingual", "none":
        return nil
    default:
        return NLLanguage(rawValue: hint)
    }
}

func detectDominantLanguage(rows: [SampleRow]) -> NLLanguage? {
    let recognizer = NLLanguageRecognizer()
    var counts: [NLLanguage: Int] = [:]
    let stride = max(rows.count / 500, 1)
    var index = 0
    while index < rows.count {
        recognizer.reset()
        recognizer.processString(rows[index].text)
        if let language = recognizer.dominantLanguage {
            counts[language, default: 0] += 1
        }
        index += stride
    }

    let total = counts.values.reduce(0, +)
    guard
        total > 0,
        let dominant = counts.max(by: { $0.value < $1.value }),
        Double(dominant.value) / Double(total) >= 0.9
    else {
        return nil
    }
    return dominant.key
}

func train(
    choice: AlgorithmChoice,
    trainingRows: [SampleRow],
    validationRows: [SampleRow],
    language: NLLanguage?
) throws -> AlgorithmResult {
    let algorithm: MLTextClassifier.ModelAlgorithmType
    let algorithmName: String

    switch choice {
    case .auto, .bert:
        guard #available(macOS 14.0, *) else {
            if choice == .auto {
                return try train(choice: .maxent, trainingRows: trainingRows, validationRows: validationRows, language: language)
            }
            throw TrainerError.unsupportedBERT
        }
        algorithm = .transferLearning(.bertEmbedding, revision: nil)
        algorithmName = "create-ml-bert-transfer"
    case .maxent:
        algorithm = .maxEnt(revision: 1)
        algorithmName = "create-ml-maxent"
    }

    let trainingData = createMLTextClassifierData(from: trainingRows)
    let validationData: MLTextClassifier.ModelParameters.ValidationData = validationRows.isEmpty
        ? .none
        : .dictionary(createMLTextClassifierData(from: validationRows))
    let parameters: MLTextClassifier.ModelParameters
    if let language {
        parameters = MLTextClassifier.ModelParameters(
            validation: validationData,
            algorithm: algorithm,
            language: language
        )
    } else {
        // No language hint: Create ML infers per-sample languages, which is
        // what we want for the mixed multilingual corpus.
        parameters = MLTextClassifier.ModelParameters(
            validation: validationData,
            algorithm: algorithm
        )
    }
    let classifier = try MLTextClassifier(trainingData: trainingData, parameters: parameters)
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

func generateSyntheticRows(
    perLabel: Int,
    corePerLabel: Int,
    intlPerLabel: Int,
    languages: [SeedLanguage],
    validLabels: Set<String>
) throws -> [SampleRow] {
    // Each first-class language (zh, en, ja) must cover every taxonomy leaf
    // on its own; other languages contribute their high-volume subsets.
    for language in languages where language.isCoreLanguage {
        let missing = validLabels.subtracting(language.templates.keys)
        guard missing.isEmpty else {
            throw TrainerError.invalidDataset(
                "Missing \(language.rawValue) synthetic templates: \(missing.sorted().joined(separator: ", "))"
            )
        }
    }

    var rows: [SampleRow] = []
    rows.reserveCapacity(validLabels.count * perLabel * max(languages.count / 2, 1))

    for language in languages {
        let targetCount: Int
        if language == .zh {
            targetCount = perLabel
        } else if language.isCoreLanguage {
            targetCount = corePerLabel
        } else {
            targetCount = intlPerLabel
        }
        guard targetCount > 0 else { continue }
        let templatesByLabel = language.templates

        for label in validLabels.sorted() {
            guard let templates = templatesByLabel[label], !templates.isEmpty else {
                continue
            }

            var labelRows: [SampleRow] = []
            var seenTexts = Set<String>()
            var attempt = 0
            let maxAttempts = max(targetCount * 100, 1_000)

            while labelRows.count < targetCount && attempt < maxAttempts {
                var generator = SeededGenerator(seed: stableHash("\(language.rawValue):\(label):\(attempt)"))
                let template = templates[attempt % templates.count]
                var text = fillSyntheticTemplate(template, language: language, generator: &generator)
                if seenTexts.contains(text) {
                    text = "\(text) #\(100000 + (attempt % 900000))"
                }
                if seenTexts.insert(text).inserted {
                    labelRows.append(SampleRow(text: text, label: label))
                }
                attempt += 1
            }

            guard labelRows.count == targetCount else {
                throw TrainerError.invalidDataset(
                    "Could only generate \(labelRows.count) unique synthetic rows for \(label) (\(language.rawValue))."
                )
            }

            rows.append(contentsOf: labelRows)
        }
    }

    var shuffleGenerator = SeededGenerator(seed: 42)
    rows.shuffle(using: &shuffleGenerator)
    return rows
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

func createMLTextClassifierData(from rows: [SampleRow]) -> [String: [String]] {
    // Convert only at the Create ML boundary so NDJSON corpora remain reusable
    // by PyTorch or other training stacks.
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

/// Per-label validation report for the classic model: surfaces the weakest
/// labels and the most frequent confusion pairs so dataset supplementation
/// can target them (the main accuracy lever for the Create ML variant).
func printPerLabelValidationReport(classifier: MLTextClassifier, validationRows: [SampleRow]) {
    guard !validationRows.isEmpty else {
        return
    }

    var totals: [String: Int] = [:]
    var corrects: [String: Int] = [:]
    var confusions: [String: Int] = [:]

    for row in validationRows {
        let predicted = (try? classifier.prediction(from: row.text)) ?? "<prediction-failed>"
        totals[row.label, default: 0] += 1
        if predicted == row.label {
            corrects[row.label, default: 0] += 1
        } else {
            confusions["\(row.label) → \(predicted)", default: 0] += 1
        }
    }

    let scored = totals
        .map { label, total -> (label: String, accuracy: Double, total: Int) in
            (label, Double(corrects[label] ?? 0) / Double(total), total)
        }
        .sorted { $0.accuracy < $1.accuracy }

    print("weakest labels (validation accuracy):")
    for item in scored.prefix(12) {
        print(String(format: "  %@: %.1f%% (%d rows)", item.label, item.accuracy * 100, item.total))
    }

    let topConfusions = confusions.sorted { $0.value > $1.value }.prefix(10)
    if !topConfusions.isEmpty {
        print("top confusion pairs (expected → predicted):")
        for (pair, count) in topConfusions {
            print("  \(pair): \(count)")
        }
    }
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
