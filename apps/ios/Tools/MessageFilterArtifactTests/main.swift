import CoreML
import Darwin
import Foundation
import MessageFilterCore

private struct Arguments {
    let model: URL
    let tokenizer: URL
    let manifest: URL
    let fixed: URL
    let promotion: URL
    let conversation: URL
    let output: URL
    let runtimeBenchmarkOutput: URL?
    let installsDynamicRelease: Bool
    let runsReadableCases: Bool
    let inspectsComputePlan: Bool

    init(_ raw: [String]) throws {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        while index < raw.count {
            let argument = raw[index]
            guard argument.hasPrefix("--") else {
                throw ArtifactSuiteError.invalidArguments
            }
            if ["--install-dynamic", "--readable-cases", "--inspect-compute-plan"].contains(argument) {
                flags.insert(argument)
                index += 1
            } else {
                guard index + 1 < raw.count else {
                    throw ArtifactSuiteError.invalidArguments
                }
                values[argument] = raw[index + 1]
                index += 2
            }
        }
        guard
            let model = values["--model"],
            let tokenizer = values["--tokenizer"],
            let manifest = values["--manifest"],
            let fixed = values["--fixed"],
            let promotion = values["--promotion"],
            let conversation = values["--conversation"],
            let output = values["--output"]
        else {
            throw ArtifactSuiteError.invalidArguments
        }
        self.model = URL(fileURLWithPath: model)
        self.tokenizer = URL(fileURLWithPath: tokenizer)
        self.manifest = URL(fileURLWithPath: manifest)
        self.fixed = URL(fileURLWithPath: fixed)
        self.promotion = URL(fileURLWithPath: promotion)
        self.conversation = URL(fileURLWithPath: conversation)
        self.output = URL(fileURLWithPath: output)
        self.runtimeBenchmarkOutput = values["--runtime-benchmark-output"].map(URL.init(fileURLWithPath:))
        self.installsDynamicRelease = flags.contains("--install-dynamic")
        self.runsReadableCases = flags.contains("--readable-cases")
        self.inspectsComputePlan = flags.contains("--inspect-compute-plan")
    }
}

private enum ArtifactSuiteError: Error {
    case invalidArguments
    case invalidManifest
    case invalidDataset(String)
    case missingLocalArtifact(String)
    case checksumMismatch(String)
    case dynamicInstallFailed
    case readableCaseGateFailed
    case conversationGateFailed
}

private struct DatasetRow: Decodable, Sendable {
    let text: String
    let label: String
}

private struct DatasetMetrics: Sendable {
    let actionCorrect: Int
    let count: Int
    let benignOrTransactionToJunk: Int
    let promotionFalsePositives: Int
    let promotionNegatives: Int
    let scamCorrect: Int
    let scamCount: Int
}

private struct ArtifactActionReport: Encodable {
    let readableCaseSuiteVersion: Int
    let readableCaseCount: Int
    let fixedAccuracy: Double
    let promotionAccuracy: Double
    let conversationAccuracy: Double
    let benignOrTransactionToJunk: Int
    let promotionFalsePositiveRate: Double
    let scamJunkRecall: Double
    let rulesOverrideRate: Double
    let artifactIdentity: ModelArtifactIdentity
    let installedDynamically: Bool
    let installedDirectory: String?
    let computePlan: TransformerComputePlanReport?
    let readableCases: [ReadableCaseReport]
}

private struct ReadableCase: Sendable {
    let id: String
    let language: String
    let sender: String?
    let body: String
    let expectedAction: SystemAction
    var expectedSource: ClassificationSource? = nil
    let rule: CustomRule?
}

private struct ReadableCaseReport: Encodable, Sendable {
    let id: String
    let language: String
    let sender: String?
    let body: String
    let expectedAction: SystemAction
    let labelID: String
    let confidence: Double
    let source: ClassificationSource
    let systemAction: SystemAction
    let systemSubAction: SystemSubAction
    let artifactIdentity: ModelArtifactIdentity
    let fallbackReason: MessageFilterFallbackReason
    let passed: Bool
}

private struct ArtifactRuntimeLoader: TransformerRuntimeLoading {
    let identity: ModelArtifactIdentity
    let classifier: any MessageClassifier

    @concurrent
    func loadTransformer(identity: ModelArtifactIdentity) async -> (any MessageClassifier)? {
        identity == self.identity ? classifier : nil
    }
}

private struct RuntimeContext {
    let engine: MessageFilterEngine
    let identity: ModelArtifactIdentity
    let installedDirectory: URL?
    let computePlanModelURL: URL
    let temporaryCompiledURL: URL?
}

private func loadRows(at url: URL) throws -> [DatasetRow] {
    let decoder = JSONDecoder()
    let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
    let rows = try lines.map { line in
        try decoder.decode(DatasetRow.self, from: Data(line.utf8))
    }
    guard !rows.isEmpty else {
        throw ArtifactSuiteError.invalidDataset(url.path)
    }
    return rows
}

private func evaluate(
    _ rows: [DatasetRow],
    engine: MessageFilterEngine,
    configuration: FilterConfigurationSnapshot
) async throws -> DatasetMetrics {
    var actionCorrect = 0
    var benignOrTransactionToJunk = 0
    var promotionFalsePositives = 0
    var promotionNegatives = 0
    var scamCorrect = 0
    var scamCount = 0

    for row in rows {
        let label = SiftTaxonomy.leaf(id: row.label)
        guard label != nil || TransformerModelContract.isAbstainLabel(row.label) else {
            throw ArtifactSuiteError.invalidDataset(row.label)
        }
        let result = await engine.classify(
            MessageFilterRequest(sender: nil, body: row.text),
            configuration: configuration,
            transformerBudget: .seconds(60)
        )
        let expected = label?.systemAction ?? .none
        let sourceCorrect = !TransformerModelContract.isAbstainLabel(row.label)
            || result.decision.source == .fallback
        actionCorrect += result.systemAction == expected && sourceCorrect ? 1 : 0
        if expected == .none || expected == .transaction {
            benignOrTransactionToJunk += result.systemAction == .junk ? 1 : 0
        }
        if expected != .promotion {
            promotionNegatives += 1
            promotionFalsePositives += result.systemAction == .promotion ? 1 : 0
        }
        if expected == .junk {
            scamCount += 1
            scamCorrect += result.systemAction == .junk ? 1 : 0
        }
    }
    return DatasetMetrics(
        actionCorrect: actionCorrect,
        count: rows.count,
        benignOrTransactionToJunk: benignOrTransactionToJunk,
        promotionFalsePositives: promotionFalsePositives,
        promotionNegatives: promotionNegatives,
        scamCorrect: scamCorrect,
        scamCount: scamCount
    )
}

private func rulesOverrideRate(
    engine: MessageFilterEngine,
    identity: ModelArtifactIdentity
) async -> Double {
    let cases: [(String, RuleAction, SystemAction)] = [
        ("allow-sender", .allow, .none),
        ("block-sender", .block, .junk),
    ]
    var correct = 0
    for (sender, action, expected) in cases {
        let rule = CustomRule(
            name: sender,
            sender: SenderMatcher(kind: .exact, pattern: sender),
            action: action
        )
        let configuration = FilterConfigurationSnapshot(
            generation: 1,
            selectedVariant: .transformer,
            modelArtifactIdentity: identity,
            rules: [rule],
            categoryMappings: ["transaction.message": .junk]
        )
        let result = await engine.classify(
            MessageFilterRequest(sender: sender, body: "model must not run"),
            configuration: configuration
        )
        if result.decision.source == .rule, result.systemAction == expected {
            correct += 1
        }
    }
    return Double(correct) / Double(cases.count)
}

private func installDynamicRelease(
    arguments: Arguments,
    manifest: TransformerModelManifest,
    manifestData: Data,
    fileManager: FileManager = .default
) throws -> InstalledTransformerModel {
    let resourceName = TransformerClassifierLoader.defaultResourceName
    if
        let installed = TransformerModelStore.installedModel(
            resourceName: resourceName,
            fileManager: fileManager,
            validateChecksums: true
        ),
        installed.manifest.artifactIdentity == manifest.artifactIdentity,
        TransformerClassifierLoader.isReady(
            installed,
            resourceName: resourceName,
            fileManager: fileManager
        )
    {
        return installed
    }
    guard
        TransformerModelStore.isSafeRelativePath(manifest.modelArtifact),
        TransformerModelStore.isSafeRelativePath(manifest.tokenizerArtifact)
    else {
        throw ArtifactSuiteError.invalidManifest
    }
    guard fileManager.fileExists(atPath: arguments.model.path) else {
        throw ArtifactSuiteError.missingLocalArtifact(arguments.model.path)
    }
    guard fileManager.fileExists(atPath: arguments.tokenizer.path) else {
        throw ArtifactSuiteError.missingLocalArtifact(arguments.tokenizer.path)
    }

    let staging = TransformerModelStore.stagingDirectory(
        resourceName: resourceName,
        fileManager: fileManager
    )
    if fileManager.fileExists(atPath: staging.path) {
        try fileManager.removeItem(at: staging)
    }
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

    do {
        let stagedModel = staging.appendingPathComponent(manifest.modelArtifact, isDirectory: true)
        let stagedTokenizer = staging.appendingPathComponent(manifest.tokenizerArtifact, isDirectory: false)
        try fileManager.createDirectory(
            at: stagedModel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: stagedTokenizer.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: arguments.model, to: stagedModel)
        try fileManager.copyItem(at: arguments.tokenizer, to: stagedTokenizer)
        try manifestData.write(
            to: TransformerModelStore.manifestURL(
                resourceName: resourceName,
                in: staging,
                fileManager: fileManager
            ),
            options: .atomic
        )

        for artifact in manifest.remoteArtifacts {
            guard
                TransformerModelStore.isSafeRelativePath(artifact.path),
                let artifactURL = TransformerModelStore.artifactURL(
                    named: artifact.path,
                    in: staging,
                    fileManager: fileManager
                ),
                try TransformerModelStore.fileSHA256(at: artifactURL) == artifact.sha256
            else {
                throw ArtifactSuiteError.checksumMismatch(artifact.path)
            }
        }
        guard
            try TransformerModelStore.directorySHA256(at: stagedModel, fileManager: fileManager) == manifest.sha256,
            try TransformerModelStore.fileSHA256(at: stagedTokenizer) == manifest.tokenizerSHA256,
            TransformerModelStore.model(
                in: staging,
                resourceName: resourceName,
                fileManager: fileManager,
                validateChecksums: false
            ) != nil
        else {
            throw ArtifactSuiteError.checksumMismatch(manifest.modelArtifact)
        }

        try TransformerClassifierLoader.prepareDownloadedModel(
            in: staging,
            resourceName: resourceName,
            fileManager: fileManager
        )
        try TransformerModelStore.activate(
            stagedDirectory: staging,
            resourceName: resourceName,
            fileManager: fileManager
        )
        FilterConfigurationSnapshotStore.refreshModelArtifactIdentity()
        guard
            let installed = TransformerModelStore.installedModel(
                resourceName: resourceName,
                fileManager: fileManager,
                validateChecksums: true
            ),
            installed.manifest.artifactIdentity == manifest.artifactIdentity,
            TransformerClassifierLoader.isReady(
                installed,
                resourceName: resourceName,
                fileManager: fileManager
            )
        else {
            throw ArtifactSuiteError.dynamicInstallFailed
        }
        return installed
    } catch {
        try? fileManager.removeItem(at: staging)
        throw error
    }
}

private func makeRuntimeContext(
    arguments: Arguments,
    manifest: TransformerModelManifest,
    manifestData: Data
) async throws -> RuntimeContext {
    if arguments.installsDynamicRelease {
        let installed = try installDynamicRelease(
            arguments: arguments,
            manifest: manifest,
            manifestData: manifestData
        )
        let identity = installed.manifest.artifactIdentity
        let compiledModelURL = installed.modelURL.pathExtension == "mlmodelc"
            ? installed.modelURL
            : TransformerModelStore.compiledModelURL(
                resourceName: TransformerClassifierLoader.defaultResourceName,
                in: installed.directoryURL
            )
        return RuntimeContext(
            engine: MessageFilterEngine(
                classicClassifier: HeuristicClassifier(),
                transformerLoader: InstalledTransformerRuntimeLoader()
            ),
            identity: identity,
            installedDirectory: installed.directoryURL,
            computePlanModelURL: compiledModelURL,
            temporaryCompiledURL: nil
        )
    }

    let compiledURL: URL
    let temporaryCompiledURL: URL?
    if arguments.model.pathExtension == "mlmodelc" {
        compiledURL = arguments.model
        temporaryCompiledURL = nil
    } else {
        compiledURL = try await MLModel.compileModel(at: arguments.model)
        temporaryCompiledURL = compiledURL
    }
    let tokenizer = try BPETokenizer(
        tokenizerURL: arguments.tokenizer,
        configuration: .init(maxSequenceLength: manifest.maxSequenceLength)
    )
    let classifier = try TransformerTextClassifier(
        modelURL: compiledURL,
        tokenizer: tokenizer,
        labels: manifest.labels
    )
    let identity = manifest.artifactIdentity
    return RuntimeContext(
        engine: MessageFilterEngine(
            classicClassifier: HeuristicClassifier(),
            transformerLoader: ArtifactRuntimeLoader(identity: identity, classifier: classifier)
        ),
        identity: identity,
        installedDirectory: nil,
        computePlanModelURL: compiledURL,
        temporaryCompiledURL: temporaryCompiledURL
    )
}

private func readableCases() -> [ReadableCase] {
    [
        ReadableCase(
            id: "zh-order-transaction",
            language: "zh",
            sender: "GAME-MARKET",
            body: "您的游戏道具订单EC20260711已支付，卖家正在准备交付。",
            expectedAction: .transaction,
            rule: nil
        ),
        ReadableCase(
            id: "en-points-transaction",
            language: "en",
            sender: "METRO-REWARDS",
            body: "You earned 860 points on today's card purchase; the available balance is now 12,430.",
            expectedAction: .transaction,
            rule: nil
        ),
        ReadableCase(
            id: "ja-update-transaction",
            language: "ja",
            sender: "SYSTEM",
            body: "システム通知：フォロー中のサービスに更新があります。",
            expectedAction: .transaction,
            rule: nil
        ),
        ReadableCase(
            id: "zh-carrier-promotion",
            language: "zh",
            sender: "10086",
            body: "老用户升级5G畅享套餐可获半年视频会员与20GB加赠流量。",
            expectedAction: .promotion,
            rule: nil
        ),
        ReadableCase(
            id: "ja-general-promotion",
            language: "ja",
            sender: "POINT-MALL",
            body: "銀行ポイントは今月末に失効します。モール交換は必要ポイント割引と送料無料の対象です。",
            expectedAction: .promotion,
            rule: nil
        ),
        ReadableCase(
            id: "en-advance-fee-scam",
            language: "en",
            sender: "FAST-CASH",
            body: "Instant gaming loan with no checks: pay an unlock fee first and message the agent for release.",
            expectedAction: .junk,
            rule: nil
        ),
        ReadableCase(
            id: "zh-personal-benign",
            language: "zh",
            sender: "+8613800000000",
            body: "我已经到地铁站了，晚饭想吃什么？我顺路带回来。",
            expectedAction: .none,
            expectedSource: .fallback,
            rule: nil
        ),
        ReadableCase(
            id: "zh-bank-transaction",
            language: "zh",
            sender: "BANK",
            body: "您尾号6218的银行卡于18:42消费人民币86.50元，当前可用余额4,231.08元。",
            expectedAction: .transaction,
            rule: nil
        ),
        ReadableCase(
            id: "zh-phishing-scam",
            language: "zh",
            sender: "SECURITY-CENTER",
            body: "账户存在异常登录，请立即点击陌生链接补录身份证和银行卡，否则今晚冻结。",
            expectedAction: .junk,
            rule: nil
        ),
        ReadableCase(
            id: "en-carrier-promotion",
            language: "en",
            sender: "MOBILE",
            body: "Upgrade to our 5G family plan this weekend and receive 25 GB bonus data for six months.",
            expectedAction: .promotion,
            rule: nil
        ),
        ReadableCase(
            id: "en-delivery-transaction",
            language: "en",
            sender: "PARCEL",
            body: "Your parcel has reached the local depot and is scheduled for delivery tomorrow between 9 and 12.",
            expectedAction: .transaction,
            rule: nil
        ),
        ReadableCase(
            id: "en-personal-benign",
            language: "en",
            sender: "+14155550123",
            body: "I am outside the library now. Should I wait here or meet you by the cafe?",
            expectedAction: .none,
            expectedSource: .fallback,
            rule: nil
        ),
        ReadableCase(
            id: "ja-verification-transaction",
            language: "ja",
            sender: "SECURE",
            body: "ログイン認証コードは482731です。5分以内に入力し、他人には教えないでください。",
            expectedAction: .transaction,
            rule: nil
        ),
        ReadableCase(
            id: "ja-gift-card-scam",
            language: "ja",
            sender: "BILLING",
            body: "未払い料金があります。逮捕を避けるため、今すぐコンビニでギフトカードを購入して番号を送ってください。",
            expectedAction: .junk,
            rule: nil
        ),
        ReadableCase(
            id: "ja-personal-benign",
            language: "ja",
            sender: "+819012345678",
            body: "駅に着いたよ。改札の前で待っているね。",
            expectedAction: .none,
            expectedSource: .fallback,
            rule: nil
        ),
        ReadableCase(
            id: "rule-allow-overrides-scam",
            language: "en",
            sender: "TRUSTED-SENDER",
            body: "Pay an unlock fee first to release your prize.",
            expectedAction: .none,
            rule: CustomRule(
                name: "trusted sender",
                sender: SenderMatcher(kind: .exact, pattern: "TRUSTED-SENDER"),
                action: .allow
            )
        ),
        ReadableCase(
            id: "rule-block-overrides-order",
            language: "zh",
            sender: "BLOCKED-SENDER",
            body: "您的订单已支付，商家正在准备发货。",
            expectedAction: .junk,
            rule: CustomRule(
                name: "blocked sender",
                sender: SenderMatcher(kind: .exact, pattern: "BLOCKED-SENDER"),
                action: .block
            )
        ),
    ]
}

private func evaluateReadableCases(
    engine: MessageFilterEngine,
    identity: ModelArtifactIdentity
) async -> [ReadableCaseReport] {
    var reports: [ReadableCaseReport] = []
    for testCase in readableCases() {
        let configuration = FilterConfigurationSnapshot(
            generation: UInt64(identity.releaseSequence),
            selectedVariant: .transformer,
            modelArtifactIdentity: identity,
            rules: testCase.rule.map { [$0] } ?? [],
            categoryMappings: [:]
        )
        let result = await engine.classify(
            MessageFilterRequest(sender: testCase.sender, body: testCase.body),
            configuration: configuration,
            transformerBudget: .seconds(60)
        )
        let expectedSource = testCase.expectedSource
            ?? (testCase.rule == nil ? ClassificationSource.model : .rule)
        reports.append(ReadableCaseReport(
            id: testCase.id,
            language: testCase.language,
            sender: testCase.sender,
            body: testCase.body,
            expectedAction: testCase.expectedAction,
            labelID: result.decision.labelID,
            confidence: result.decision.confidence,
            source: result.decision.source,
            systemAction: result.systemAction,
            systemSubAction: result.systemSubAction,
            artifactIdentity: result.modelArtifactIdentity,
            fallbackReason: result.fallbackReason,
            passed: result.systemAction == testCase.expectedAction
                && result.decision.source == expectedSource
                && result.fallbackReason == .none
                && result.modelArtifactIdentity == identity
        ))
    }
    return reports
}

private func run() async throws {
    let arguments = try Arguments(CommandLine.arguments)
    let manifestData = try Data(contentsOf: arguments.manifest)
    let manifest = try JSONDecoder().decode(TransformerModelManifest.self, from: manifestData)
    guard !manifest.labels.isEmpty else {
        throw ArtifactSuiteError.invalidManifest
    }
    let runtime = try await makeRuntimeContext(
        arguments: arguments,
        manifest: manifest,
        manifestData: manifestData
    )
    defer {
        if let temporaryCompiledURL = runtime.temporaryCompiledURL {
            try? FileManager.default.removeItem(at: temporaryCompiledURL)
        }
    }
    let configuration = FilterConfigurationSnapshot(
        generation: UInt64(manifest.releaseSequence),
        selectedVariant: .transformer,
        modelArtifactIdentity: runtime.identity,
        rules: [],
        categoryMappings: [:]
    )
    let fixed = try await evaluate(
        loadRows(at: arguments.fixed),
        engine: runtime.engine,
        configuration: configuration
    )
    let promotion = try await evaluate(
        loadRows(at: arguments.promotion),
        engine: runtime.engine,
        configuration: configuration
    )
    let conversation = try await evaluate(
        loadRows(at: arguments.conversation),
        engine: runtime.engine,
        configuration: configuration
    )
    let readable = arguments.runsReadableCases
        ? await evaluateReadableCases(engine: runtime.engine, identity: runtime.identity)
        : []
    let computePlan = arguments.inspectsComputePlan
        ? try await TransformerComputePlanInspector.inspect(modelURL: runtime.computePlanModelURL)
        : nil
    if let runtimeBenchmarkOutput = arguments.runtimeBenchmarkOutput {
        let tokenizer = try BPETokenizer(
            tokenizerURL: arguments.tokenizer,
            configuration: .init(maxSequenceLength: manifest.maxSequenceLength)
        )
        let benchmark = try await TransformerRuntimeBenchmark.run(
            modelURL: runtime.computePlanModelURL,
            tokenizer: tokenizer,
            labels: manifest.labels,
            requests: readableCases().map { MessageFilterRequest(sender: $0.sender, body: $0.body) },
            artifactIdentity: runtime.identity,
            warmupIterations: 10,
            measuredIterations: 100
        )
        try JSONEncoder.pretty.encode(benchmark).write(to: runtimeBenchmarkOutput, options: .atomic)
    }
    let report = ArtifactActionReport(
        readableCaseSuiteVersion: 2,
        readableCaseCount: readable.count,
        fixedAccuracy: Double(fixed.actionCorrect) / Double(fixed.count),
        promotionAccuracy: Double(promotion.actionCorrect) / Double(promotion.count),
        conversationAccuracy: Double(conversation.actionCorrect) / Double(conversation.count),
        benignOrTransactionToJunk: fixed.benignOrTransactionToJunk + promotion.benignOrTransactionToJunk,
        promotionFalsePositiveRate: Double(promotion.promotionFalsePositives) / Double(max(promotion.promotionNegatives, 1)),
        scamJunkRecall: Double(fixed.scamCorrect + promotion.scamCorrect) / Double(max(fixed.scamCount + promotion.scamCount, 1)),
        rulesOverrideRate: await rulesOverrideRate(engine: runtime.engine, identity: runtime.identity),
        artifactIdentity: runtime.identity,
        installedDynamically: arguments.installsDynamicRelease,
        installedDirectory: runtime.installedDirectory?.path,
        computePlan: computePlan,
        readableCases: readable
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: arguments.output, options: .atomic)
    guard conversation.actionCorrect == conversation.count else {
        throw ArtifactSuiteError.conversationGateFailed
    }
    guard readable.allSatisfy(\.passed) else {
        throw ArtifactSuiteError.readableCaseGateFailed
    }
}

do {
    try await run()
} catch {
    fputs("MessageFilterArtifactTests failed: \(error)\n", stderr)
    exit(1)
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
