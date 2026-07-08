import Foundation
import MessageFilterCore
import Observation

#if canImport(CloudKit)
import CloudKit
#endif

public enum SubmissionDestination: String, CaseIterable, Identifiable, Sendable {
    case local
    case remote

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local:
            return String(localized: "仅本地微调")
        case .remote:
            return String(localized: "匿名提交")
        }
    }
}

public enum RuleMatchLocation: String, CaseIterable, Identifiable, Sendable {
    case sender
    case body

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sender:
            return String(localized: "发送方")
        case .body:
            return String(localized: "短信正文")
        }
    }

    public var symbol: String {
        switch self {
        case .sender:
            return "person.text.rectangle"
        case .body:
            return "text.magnifyingglass"
        }
    }
}

public enum RulePatternKind: String, CaseIterable, Identifiable, Sendable {
    case substring
    case regex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .substring:
            return String(localized: "子串")
        case .regex:
            return String(localized: "正则")
        }
    }
}

public struct SiftToast: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case success
        case error
        case info
    }

    public let id = UUID()
    public let kind: Kind
    public let message: String
}

public struct SampleSubmissionFeedback: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let kind: SiftToast.Kind
    public let message: String
}

@MainActor
@Observable
public final class SiftAppModel {
    public var modelDate: String = "2026-05-06"
    public var modelVersion: String = "corpus-0.1"
    public private(set) var selectedModelVariant: ModelVariant = .classic
    public private(set) var isSwitchingModelVariant: Bool = false
    public private(set) var isTransformerModelAvailable: Bool
    public private(set) var transformerDownloadPhase: TransformerModelDownloadPhase = .notDownloaded
    public private(set) var transformerDownloadProgress: TransformerModelDownloadProgress?
    public private(set) var pendingTransformerDownloadPlan: TransformerModelDownloadPlan?
    public var isShowingMeteredTransformerDownloadConfirmation: Bool = false
    public var submissionDestination: SubmissionDestination = .local
    public var testBody: String = ""
    public var submissionText: String = ""
    public var selectedLabelID: String = "life.pickup_code"
    public var rules: [CustomRule] {
        didSet {
            persistRules()
        }
    }
    public var ruleDraftName: String = ""
    public var ruleDraftPattern: String = ""
    public var ruleDraftLocation: RuleMatchLocation = .body
    public var ruleDraftPatternKind: RulePatternKind = .substring
    public var ruleDraftLabelID: String = "life.pickup_code"
    public var localSampleCount: Int = 0
    public var lastReceiptToken: String? = UserDefaults.standard.string(forKey: "Sift.lastRemoteSampleReceiptToken") {
        didSet {
            if let lastReceiptToken {
                UserDefaults.standard.set(lastReceiptToken, forKey: Self.lastRemoteSampleReceiptTokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastRemoteSampleReceiptTokenKey)
            }
        }
    }
    public var lastDecision: ClassificationDecision?
    public var sanitizedPreview: String = ""
    public var statusMessage: String = ""
    public var hasAcceptedRemoteSamplePrivacy: Bool = UserDefaults.standard.bool(forKey: "Sift.hasAcceptedRemoteSamplePrivacy") {
        didSet {
            UserDefaults.standard.set(hasAcceptedRemoteSamplePrivacy, forKey: Self.remoteSamplePrivacyConsentKey)
        }
    }
    public var hasConfirmedFilterSetup: Bool = UserDefaults.standard.bool(forKey: "Sift.hasConfirmedFilterSetup") {
        didSet {
            UserDefaults.standard.set(hasConfirmedFilterSetup, forKey: "Sift.hasConfirmedFilterSetup")
        }
    }
    public var currentToast: SiftToast?
    public var sampleSubmissionFeedback: SampleSubmissionFeedback?
    public var isSubmittingSample: Bool = false
    public var isShowingPaywall: Bool = false
    public private(set) var isErasingRemoteData: Bool = false
    public private(set) var todayStats: DailyFilterStats = DailyFilterStats(day: FilterStatisticsStore.dayKey(for: .now))
    public private(set) var weeklyStats: [DailyFilterStats] = []

    /// 本地记录的已贡献样本数(App Group 计数,云端历史列表为准)。
    public private(set) var submittedSampleCount: Int = 0

    // 提交历史(下拉无限加载,最多展示最近 historyMaxItems 条)。
    public static let historyPageSize = 30
    public static let historyMaxItems = 200
    public private(set) var submissionHistory: [RemoteSubmissionSummary] = []
    public private(set) var isLoadingHistory: Bool = false
    public private(set) var historyFullyLoaded: Bool = false
    public private(set) var submissionHistoryErrorMessage: String?
    public private(set) var remoteAccountStatus: RemoteSampleAccountStatus = .checking
    public private(set) var isCheckingRemoteAccountStatus: Bool = false
    public var remoteAccountAlertMessage: String?

    /// 高级版(IAP)状态与购买流程。
    public let premium: PremiumStore

    @ObservationIgnored
    private let sanitizer = PrivacySanitizer.withBundledModel()

    @ObservationIgnored
    private var baseClassifier: any MessageClassifier

    @ObservationIgnored
    private var pipeline: ClassificationPipeline

    @ObservationIgnored
    private let sampleStore: LocalSampleStore

    @ObservationIgnored
    private let remoteSampleClient: any RemoteSampleSubmitting

    @ObservationIgnored
    private let personalizationTrainer = PersonalizationTrainer()

    @ObservationIgnored
    private let transformerDownloader: (any TransformerModelDownloading)?

    @ObservationIgnored
    private var transformerDownloadTask: Task<Void, Never>?

    @ObservationIgnored
    private let statisticsStore = FilterStatisticsStore()

    /// 注入口:测试用独立 UserDefaults suite 隔离贡献计数。
    @ObservationIgnored
    private let ledgerDefaults: UserDefaults?

    public init(
        remoteSampleClient: (any RemoteSampleSubmitting)? = nil,
        premiumBackend: (any PremiumPurchasing)? = nil,
        transformerAvailabilityOverride: Bool? = nil,
        transformerDownloader: (any TransformerModelDownloading)? = TransformerModelDownloadClient.configured(),
        ledgerDefaults: UserDefaults? = nil
    ) {
        self.ledgerDefaults = ledgerDefaults
        self.sampleStore = LocalSampleStore(fileURL: LocalSampleStore.defaultFileURL())
        self.remoteSampleClient = remoteSampleClient ?? CloudKitSampleClient(
            containerIdentifier: CloudKitSampleClient.configuredContainerIdentifier()
        )
        self.transformerDownloader = transformerDownloader
        self.premium = PremiumStore(backend: premiumBackend)

        let transformerAvailable = transformerAvailabilityOverride ?? TransformerClassifierLoader.isAvailable()
        self.isTransformerModelAvailable = transformerAvailable
        self.transformerDownloadPhase = transformerAvailable ? .ready : .notDownloaded
        let storedVariant = ModelSelectionStore.load()
        let variant: ModelVariant = (storedVariant == .transformer && !transformerAvailable) ? .classic : storedVariant
        self.selectedModelVariant = variant

        let stack = Self.makeClassifierStack(for: variant)
        self.baseClassifier = stack.base
        self.pipeline = stack.pipeline
        self.rules = Self.loadPersistedRules()

        refreshModelMetadataDisplay()
        if !variant.supportsLocalPersonalization {
            submissionDestination = .remote
        }
        refreshSanitizedPreview()
        classifyCurrentDraft()
        Task { await refreshLocalSampleCount() }

        submittedSampleCount = SubmissionLedger.count(defaults: ledgerDefaults)
        refreshStatistics()
        // 统计云备份是 best-effort:失败静默,永不打扰用户。仅在真机 App
        // 环境执行——单测/命令行环境没有 CloudKit entitlement,构造
        // CKContainer 会直接抛 ObjC 异常。
        #if os(iOS) && !targetEnvironment(simulator)
        Task.detached(priority: .utility) { [containerIdentifier = CloudKitSampleClient.configuredContainerIdentifier()] in
            await CloudKitStatsSync(containerIdentifier: containerIdentifier).sync()
        }
        #endif

        // 高级版被退款/撤销时,若正在使用 Transformer 则回退经典模型。
        premium.onEntitlementChange = { [weak self] unlocked in
            guard let self, !unlocked else {
                return
            }
            self.cancelPendingTransformerDownload()
            guard self.selectedModelVariant == .transformer else {
                return
            }
            self.selectModelVariant(.classic)
            self.showToast(.info, String(localized: "高级版授权已失效，已切换回经典模型"))
        }

        if remoteSampleClient == nil {
            refreshRemoteAccountStatus()
        } else {
            remoteAccountStatus = .available
        }
    }

    /// 刷新仪表盘统计(今日 + 近 7 天)。
    public func refreshStatistics() {
        todayStats = statisticsStore.stats()
        weeklyStats = statisticsStore.recent(days: 7)
    }

    /// Whether the active model variant allows on-device fine-tuning. The
    /// transformer variant is frozen, so all personalization UI must hide.
    public var supportsLocalPersonalization: Bool {
        selectedModelVariant.supportsLocalPersonalization
    }

    public var availableModelVariants: [ModelVariant] {
        ModelVariant.allCases
    }

    public func isModelVariantAvailable(_ variant: ModelVariant) -> Bool {
        variant != .transformer
            || isTransformerModelAvailable
            || transformerDownloader != nil
            || !premium.isUnlocked
    }

    /// Manifest version for a variant, for display in the model picker.
    public func modelVersion(for variant: ModelVariant) -> String? {
        switch variant {
        case .classic:
            return nil
        case .transformer:
            return TransformerClassifierLoader.manifest()?.version ?? pendingTransformerDownloadPlan?.manifest.version
        }
    }

    public func selectModelVariant(_ variant: ModelVariant) {
        guard variant != selectedModelVariant, !isSwitchingModelVariant else {
            return
        }
        if variant == .transformer, !premium.isUnlocked {
            // 高级版付费项:未解锁时打开购买引导,而不是直接切换。
            isShowingPaywall = true
            return
        }
        if variant == .transformer, !isTransformerModelAvailable {
            beginTransformerDownloadAndSwitch(allowMeteredNetwork: false)
            return
        }

        switchToModelVariant(variant)
    }

    private func switchToModelVariant(_ variant: ModelVariant) {
        selectedModelVariant = variant
        ModelSelectionStore.save(variant)
        refreshModelMetadataDisplay()
        if !variant.supportsLocalPersonalization {
            if submissionDestination == .local {
                submissionDestination = .remote
            }
            sampleSubmissionFeedback = nil
        }

        // Core ML loading (and possible first-launch model compilation) is
        // slow enough to hitch the UI; build the new stack off the main actor.
        isSwitchingModelVariant = true
        Task {
            let stack = await Task.detached(priority: .userInitiated) {
                Self.makeClassifierStack(for: variant)
            }.value

            // A newer switch may have started while we were loading.
            guard selectedModelVariant == variant else {
                return
            }
            baseClassifier = stack.base
            pipeline = stack.pipeline
            isSwitchingModelVariant = false

            if canClassifyCurrentDraft {
                classifyCurrentDraft()
            } else {
                clearCurrentDecision()
            }
            showToast(.success, String(localized: "已切换至\(variant.title)"))
        }
    }

    public var isTransformerDownloadActive: Bool {
        switch transformerDownloadPhase {
        case .checking, .downloading, .installing:
            return true
        case .notDownloaded, .waitingForTrafficConfirmation, .ready, .failed:
            return false
        }
    }

    public var transformerDownloadProgressText: String? {
        guard let progress = transformerDownloadProgress else {
            return nil
        }
        if let fraction = progress.fractionCompleted {
            return "\(Int((fraction * 100).rounded()))%"
        }
        return Self.formatByteCount(progress.receivedBytes)
    }

    public var transformerDownloadByteCountText: String? {
        pendingTransformerDownloadPlan?.displayByteCount.map(Self.formatByteCount)
    }

    public var canUseRemoteSubmission: Bool {
        remoteAccountStatus == .available
    }

    public var remoteAccountUnavailableMessage: String {
        switch remoteAccountStatus {
        case .available:
            return ""
        case .checking, .unknown:
            return String(localized: "暂时无法确认 iCloud 状态，请稍后重试")
        case .noAccount:
            return String(localized: "请先在系统设置中登录 iCloud，再匿名共享样本")
        case .restricted:
            return String(localized: "此设备的 iCloud 账户受限，无法提交样本")
        case .unavailable:
            return String(localized: "iCloud 服务暂不可用，请稍后重试")
        }
    }

    public func refreshRemoteAccountStatus() {
        guard !isCheckingRemoteAccountStatus else {
            return
        }
        isCheckingRemoteAccountStatus = true
        if remoteAccountStatus != .available {
            remoteAccountStatus = .checking
        }
        Task {
            let status = await remoteSampleClient.accountStatus()
            remoteAccountStatus = status
            isCheckingRemoteAccountStatus = false
        }
    }

    public func showRemoteAccountRequiredAlert() {
        remoteAccountAlertMessage = remoteAccountUnavailableMessage
    }

    public func dismissRemoteAccountAlert() {
        remoteAccountAlertMessage = nil
    }

    public var meteredTransformerDownloadMessage: String {
        let size = transformerDownloadByteCountText ?? String(localized: "约 168 MB")
        return String(
            format: String(localized: "高级模型需要下载 %@ 数据。当前网络可能按流量计费或处于低数据模式，继续下载可能产生流量费用。"),
            size
        )
    }

    public func confirmMeteredTransformerDownload() {
        isShowingMeteredTransformerDownloadConfirmation = false
        guard let pendingTransformerDownloadPlan else {
            beginTransformerDownloadAndSwitch(allowMeteredNetwork: true)
            return
        }
        downloadPreparedTransformerPlan(pendingTransformerDownloadPlan)
    }

    public func cancelPendingTransformerDownload() {
        transformerDownloadTask?.cancel()
        transformerDownloadTask = nil
        pendingTransformerDownloadPlan = nil
        transformerDownloadProgress = nil
        transformerDownloadPhase = isTransformerModelAvailable ? .ready : .notDownloaded
        isShowingMeteredTransformerDownloadConfirmation = false
    }

    private func beginTransformerDownloadAndSwitch(allowMeteredNetwork: Bool) {
        guard transformerDownloadTask == nil else {
            return
        }
        guard let transformerDownloader else {
            let message = TransformerModelDownloadError.missingRemoteManifestURL.localizedDescription
            transformerDownloadPhase = .failed(message)
            showToast(.error, message)
            return
        }

        transformerDownloadPhase = .checking
        transformerDownloadProgress = nil
        transformerDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await transformerDownloader.prepareDownload()
                guard !Task.isCancelled else { return }
                pendingTransformerDownloadPlan = plan
                if plan.networkCondition.requiresTrafficConfirmation && !allowMeteredNetwork {
                    transformerDownloadPhase = .waitingForTrafficConfirmation
                    isShowingMeteredTransformerDownloadConfirmation = true
                    transformerDownloadTask = nil
                    return
                }
                transformerDownloadTask = nil
                downloadPreparedTransformerPlan(plan)
            } catch {
                guard !Task.isCancelled else { return }
                handleTransformerDownloadFailure(error)
            }
        }
    }

    private func downloadPreparedTransformerPlan(_ plan: TransformerModelDownloadPlan) {
        guard transformerDownloadTask == nil else {
            return
        }
        guard let transformerDownloader else {
            let message = TransformerModelDownloadError.missingRemoteManifestURL.localizedDescription
            transformerDownloadPhase = .failed(message)
            showToast(.error, message)
            return
        }

        pendingTransformerDownloadPlan = plan
        transformerDownloadPhase = .downloading
        transformerDownloadTask = Task { [weak self] in
            guard let self else { return }
            let progressSink = TransformerDownloadProgressSink(model: self)
            do {
                try await transformerDownloader.download(plan) { progress in
                    progressSink.update(progress)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    transformerDownloadPhase = .installing
                    isTransformerModelAvailable = TransformerClassifierLoader.isAvailable()
                    transformerDownloadPhase = isTransformerModelAvailable ? .ready : .failed(String(localized: "高级模型安装失败"))
                    transformerDownloadTask = nil
                    if isTransformerModelAvailable {
                        switchToModelVariant(.transformer)
                    } else {
                        showToast(.error, String(localized: "高级模型安装失败"))
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.handleTransformerDownloadFailure(error)
                }
            }
        }
    }

    private func handleTransformerDownloadFailure(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        transformerDownloadPhase = .failed(message)
        transformerDownloadTask = nil
        showToast(.error, message)
    }

    fileprivate func updateTransformerDownloadProgress(_ progress: TransformerModelDownloadProgress) {
        transformerDownloadProgress = progress
    }

    /// Builds the classifier stack for a variant, layering the persisted
    /// personalization adapter on top when the variant allows local
    /// fine-tuning. Safe to call from any executor.
    private nonisolated static func makeClassifierStack(
        for variant: ModelVariant
    ) -> (base: any MessageClassifier, pipeline: ClassificationPipeline) {
        let base = AppleClassifierLoader.classifier(for: variant)
        if
            variant.supportsLocalPersonalization,
            let personalized = loadPersistedPersonalization()
        {
            return (base, ClassificationPipeline(
                classifier: CascadingClassifier(primary: personalized, fallback: base)
            ))
        }
        return (base, ClassificationPipeline(classifier: base))
    }

    private nonisolated static func loadPersistedPersonalization() -> (any MessageClassifier)? {
        let compiledURL = LocalSampleStore.defaultFileURL(filename: "personalization.mlmodelc")
        guard FileManager.default.fileExists(atPath: compiledURL.path) else {
            return nil
        }
        return AppleClassifierLoader.personalized(modelURL: compiledURL)
    }

    private func refreshModelMetadataDisplay() {
        switch selectedModelVariant {
        case .classic:
            if let manifest = BundledModelManifest.load() {
                modelDate = Self.displayDate(for: manifest.trainedAt)
                modelVersion = manifest.version
            }
        case .transformer:
            if let manifest = TransformerClassifierLoader.manifest() {
                modelDate = Self.displayDate(for: manifest.trainedAt)
                modelVersion = manifest.version
            }
        }
    }

    public var selectedLabel: LeafLabel {
        SiftTaxonomy.leaf(id: selectedLabelID) ?? SiftTaxonomy.leaves[0]
    }

    public var activeRuleCount: Int {
        rules.filter(\.enabled).count
    }

    public var customRuleCount: Int {
        rules.count
    }

    public var customRuleIndices: [Int] {
        Array(rules.indices)
    }

    public var canClassifyCurrentDraft: Bool {
        let body = testBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return !body.isEmpty
    }

    /// 单条样本的最大长度(与训练侧长度过滤一致)。
    public static let maxSubmissionTextLength = 500

    public var canSubmitSample: Bool {
        let text = submissionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maxSubmissionTextLength else {
            return false
        }
        if submissionDestination == .remote && !hasAcceptedRemoteSamplePrivacy {
            return false
        }
        if submissionDestination == .remote && !canUseRemoteSubmission {
            return false
        }
        return true
    }

    /// 提交前的即时校验提示(超长等),空则不显示。
    public var submissionValidationMessage: String? {
        let text = submissionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        if text.count > Self.maxSubmissionTextLength {
            return String(localized: "样本过长（\(text.count)/\(Self.maxSubmissionTextLength) 字符），请拆分或截取关键内容")
        }
        return nil
    }

    public var privacyPolicyURL: URL {
        Self.configuredPrivacyPolicyURL()
    }

    public var termsOfServiceURL: URL {
        Self.configuredTermsOfServiceURL()
    }

    public var shouldShowSanitizedPreview: Bool {
        let trimmed = submissionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return sanitizedPreview != submissionText
    }

    public func refreshSanitizedPreview() {
        sanitizedPreview = sanitizer.sanitize(submissionText).text
    }

    public func clearCurrentDecision() {
        lastDecision = nil
    }

    public var canAddCustomRule: Bool {
        let pattern = ruleDraftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            return false
        }
        guard ruleDraftPatternKind == .regex else {
            return true
        }
        return isValidRegex(pattern)
    }

    public var ruleDraftValidationMessage: String? {
        let pattern = ruleDraftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            return nil
        }
        guard ruleDraftPatternKind == .regex, !isValidRegex(pattern) else {
            return nil
        }
        return String(localized: "正则表达式格式不正确")
    }

    public func classifyCurrentDraft() {
        let body = testBody.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else {
            lastDecision = nil
            return
        }

        // Route through the full pipeline so the preview honors the user's
        // custom rules exactly like the message-filter extension does.
        lastDecision = pipeline.classify(sender: nil, body: body, rules: rules)
    }

    public func submitSample() {
        guard !isSubmittingSample else { return }
        sampleSubmissionFeedback = nil
        refreshSanitizedPreview()
        let selectedLabel = selectedLabel
        let text = submissionText
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            showSubmissionFeedback(.error, String(localized: "请输入样本文本"))
            return
        }
        let sanitizedText = sanitizedPreview
        switch submissionDestination {
        case .local:
            guard supportsLocalPersonalization else {
                showSubmissionFeedback(.error, String(localized: "当前模型不支持本地微调，请使用匿名提交"))
                return
            }
            isSubmittingSample = true
            Task {
                defer { isSubmittingSample = false }
                do {
                    let sample = StoredSample(
                        sender: "",
                        body: text,
                        labelID: selectedLabel.id,
                        source: "local"
                    )
                    try await sampleStore.append(sample)
                    let samples = try await sampleStore.loadAll()
                    localSampleCount = samples.count
                    let trainer = personalizationTrainer
                    let artifact = await Task.detached(priority: .utility) {
                        await trainer.updateModel(from: samples)
                    }.value
                    switch artifact.state {
                    case .personalized:
                        if
                            let modelURL = artifact.modelURL,
                            let personalized = AppleClassifierLoader.personalized(modelURL: modelURL)
                        {
                            pipeline = ClassificationPipeline(
                                classifier: CascadingClassifier(
                                    primary: personalized,
                                    fallback: baseClassifier
                                )
                            )
                            classifyCurrentDraft()
                        }
                        showToast(.success, String(localized: "本地个性化层已更新"))
                    case .ready:
                        showToast(.success, String(localized: "样本已加入本地队列"))
                    case .unsupported:
                        showToast(.info, String(localized: "样本已保存，当前系统暂不支持本地训练"))
                    case .failed:
                        showToast(.info, String(localized: "样本已保存，本地训练稍后重试"))
                    case .missingModel:
                        showToast(.info, String(localized: "样本已保存，等待基座模型"))
                    }
                    sampleSubmissionFeedback = SampleSubmissionFeedback(kind: .success, message: String(localized: "样本已保存到本地，仅用于设备上的个性化微调。"))
                    submissionText = ""
                    refreshSanitizedPreview()
                } catch {
                    showSubmissionFeedback(.error, String(localized: "本地保存失败：\(error.localizedDescription)"))
                }
            }
        case .remote:
            guard canUseRemoteSubmission else {
                showRemoteAccountRequiredAlert()
                return
            }
            guard hasAcceptedRemoteSamplePrivacy else {
                showSubmissionFeedback(.error, String(localized: "请先阅读并同意匿名提交隐私说明"))
                return
            }

            isSubmittingSample = true
            // Coarse-classify the sanitized text with the base model (no
            // custom rules) and ship the verdict with the sample: curation
            // uses agreement/confidence to weigh noisy submissions, without
            // ever blocking a correction the user is deliberately making.
            let localDecision = baseClassifier.classify(sender: nil, body: sanitizedText)
            let assessment = LocalAssessment(
                predictedLabelID: localDecision.labelID,
                confidence: localDecision.confidence
            )
            Task {
                defer { isSubmittingSample = false }
                do {
                    let receipt = try await remoteSampleClient.submit(
                        sanitizedText: sanitizedText,
                        labelID: selectedLabel.id,
                        modelVersion: modelVersion,
                        assessment: assessment
                    )
                    if receipt.accepted, let receiptToken = receipt.receiptToken {
                        lastReceiptToken = receiptToken
                        SubmissionLedger.increment(defaults: self.ledgerDefaults)
                        submittedSampleCount = SubmissionLedger.count(defaults: self.ledgerDefaults)
                        resetSubmissionHistory()
                        if assessment.predictedLabelID != selectedLabel.id, assessment.confidence >= 0.8 {
                            let predictedTitle = SiftTaxonomy.leaf(id: assessment.predictedLabelID)?.title ?? assessment.predictedLabelID
                            showSubmissionFeedback(.info, String(localized: "已按你的选择提交。本地模型倾向于「\(predictedTitle)」，若确认无误请忽略。"))
                        } else {
                            showSubmissionFeedback(.success, String(localized: "已通过 iCloud 匿名共享脱敏样本，可用回执删除。"))
                        }
                        submissionText = ""
                        refreshSanitizedPreview()
                    } else {
                        showSubmissionFeedback(.error, String(localized: "样本未被接收，请稍后重试"))
                    }
                } catch {
                    showSubmissionFeedback(.error, remoteSubmissionErrorMessage(for: error))
                }
            }
        }
    }

    public func deleteLastRemoteSample() {
        guard let receiptToken = lastReceiptToken else {
            return
        }
        guard canUseRemoteSubmission else {
            showRemoteAccountRequiredAlert()
            return
        }

        Task {
            do {
                let deleted = try await remoteSampleClient.delete(receiptToken: receiptToken)
                if deleted {
                    lastReceiptToken = nil
                    SubmissionLedger.decrement(defaults: self.ledgerDefaults)
                    submittedSampleCount = SubmissionLedger.count(defaults: self.ledgerDefaults)
                    resetSubmissionHistory()
                    showSubmissionFeedback(.success, String(localized: "远程样本已删除"))
                } else {
                    lastReceiptToken = nil
                    showSubmissionFeedback(.info, String(localized: "未找到可删除的远程样本"))
                }
            } catch {
                showSubmissionFeedback(.error, remoteDeletionErrorMessage(for: error))
            }
        }
    }

    public func refreshLocalSampleCount() async {
        do {
            localSampleCount = try await sampleStore.loadAll().count
        } catch {
            localSampleCount = 0
        }
    }

    /// 删除当前用户在云端的全部提交样本与统计备份。
    public func eraseAllRemoteData() {
        guard !isErasingRemoteData else {
            return
        }
        guard canUseRemoteSubmission else {
            showRemoteAccountRequiredAlert()
            return
        }
        isErasingRemoteData = true
        Task {
            defer { isErasingRemoteData = false }
            do {
                let deletedSamples = try await remoteSampleClient.eraseAllSubmissions()
                let deletedStats = (try? await CloudKitStatsSync(
                    containerIdentifier: CloudKitSampleClient.configuredContainerIdentifier()
                ).eraseBackup()) ?? 0
                lastReceiptToken = nil
                SubmissionLedger.reset(defaults: self.ledgerDefaults)
                submittedSampleCount = 0
                submissionHistory = []
                historyFullyLoaded = true
                if deletedSamples == 0 && deletedStats == 0 {
                    showToast(.info, String(localized: "云端没有找到你提交的数据"))
                } else if deletedSamples == 0 {
                    showToast(.success, String(localized: "已清除云端统计备份"))
                } else if deletedStats > 0 {
                    showToast(.success, String(localized: "已抹除 \(deletedSamples) 条提交样本及统计备份"))
                } else {
                    showToast(.success, String(localized: "已抹除 \(deletedSamples) 条提交样本"))
                }
            } catch {
                showToast(.error, remoteDeletionErrorMessage(for: error))
            }
        }
    }

    /// 重置提交历史(下次进入列表重新从第一页加载)。
    public func resetSubmissionHistory() {
        submissionHistory = []
        submissionHistoryErrorMessage = nil
        historyFullyLoaded = false
    }

    /// 下拉无限加载:按 createdAt 倒序取下一页,去重合并,封顶
    /// `historyMaxItems` 条。
    public func loadMoreSubmissionHistory() {
        guard !isLoadingHistory, !historyFullyLoaded else {
            return
        }
        guard canUseRemoteSubmission else {
            submissionHistory = []
            submissionHistoryErrorMessage = remoteAccountUnavailableMessage
            historyFullyLoaded = true
            return
        }
        isLoadingHistory = true
        Task {
            defer { isLoadingHistory = false }
            do {
                let anchor = submissionHistory.last?.createdAtMillis
                let page = try await remoteSampleClient.fetchMySubmissions(
                    before: anchor,
                    limit: Self.historyPageSize
                )
                let known = Set(submissionHistory.map(\.recordName))
                submissionHistory.append(contentsOf: page.filter { !known.contains($0.recordName) })
                submissionHistoryErrorMessage = nil
                if submissionHistory.count >= Self.historyMaxItems {
                    submissionHistory = Array(submissionHistory.prefix(Self.historyMaxItems))
                    historyFullyLoaded = true
                } else if page.count < Self.historyPageSize {
                    historyFullyLoaded = true
                }
                // 首次拉取时用云端信息校准本地计数(本地计数可能因重装偏低)。
                if anchor == nil, submissionHistory.count > submittedSampleCount {
                    submittedSampleCount = submissionHistory.count
                }
            } catch {
                let message = remoteDeletionErrorMessage(for: error)
                submissionHistoryErrorMessage = message
                if submissionHistory.isEmpty {
                    historyFullyLoaded = true
                }
                showToast(.error, message)
            }
        }
    }

    /// 单条抹除:从云端删除指定提交并同步列表/计数/回执。
    public func deleteSubmission(_ summary: RemoteSubmissionSummary) {
        guard canUseRemoteSubmission else {
            showRemoteAccountRequiredAlert()
            return
        }
        Task {
            do {
                let deleted = try await remoteSampleClient.delete(receiptToken: summary.recordName)
                submissionHistory.removeAll { $0.recordName == summary.recordName }
                if deleted {
                    SubmissionLedger.decrement(defaults: self.ledgerDefaults)
                    submittedSampleCount = SubmissionLedger.count(defaults: self.ledgerDefaults)
                    if lastReceiptToken == summary.recordName {
                        lastReceiptToken = nil
                    }
                    showToast(.success, String(localized: "已抹除该条提交"))
                } else {
                    showToast(.info, String(localized: "该条提交已不存在，列表已同步"))
                }
            } catch {
                showToast(.error, remoteDeletionErrorMessage(for: error))
            }
        }
    }

    /// 把当前用户的全部云端提交导出为 JSON 文本。
    public func exportMySubmissionsJSON() async -> String? {
        guard canUseRemoteSubmission else {
            showRemoteAccountRequiredAlert()
            return nil
        }
        do {
            let submissions = try await remoteSampleClient.fetchMySubmissions()
            guard !submissions.isEmpty else {
                showToast(.info, String(localized: "云端没有找到你提交的样本"))
                return nil
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(submissions)
            return String(decoding: data, as: UTF8.self)
        } catch {
            showToast(.error, remoteDeletionErrorMessage(for: error))
            return nil
        }
    }

    public func showToast(_ kind: SiftToast.Kind, _ message: String) {
        currentToast = SiftToast(kind: kind, message: message)
    }

    public func showSubmissionFeedback(_ kind: SiftToast.Kind, _ message: String) {
        sampleSubmissionFeedback = SampleSubmissionFeedback(kind: kind, message: message)
        showToast(kind, message)
    }

    @discardableResult
    public func addCustomRuleFromDraft() -> Bool {
        let pattern = ruleDraftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            showToast(.error, String(localized: "请输入匹配内容"))
            return false
        }
        guard canAddCustomRule else {
            showToast(.error, String(localized: "正则表达式格式不正确"))
            return false
        }

        let name = ruleDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleName = name.isEmpty ? defaultRuleName(for: pattern) : name

        let rule: CustomRule
        switch ruleDraftLocation {
        case .sender:
            rule = CustomRule(
                name: ruleName,
                sender: SenderMatcher(kind: ruleDraftPatternKind == .regex ? .regex : .substring, pattern: pattern),
                targetLabelID: ruleDraftLabelID
            )
        case .body:
            rule = CustomRule(
                name: ruleName,
                text: TextMatcher(kind: ruleDraftPatternKind == .regex ? .regex : .substring, pattern: pattern),
                targetLabelID: ruleDraftLabelID
            )
        }

        rules.insert(rule, at: customRuleIndices.first ?? rules.startIndex)
        normalizeRulePriorities()
        showToast(.success, String(localized: "已添加规则"))
        resetRuleDraft()
        if canClassifyCurrentDraft {
            classifyCurrentDraft()
        } else {
            clearCurrentDecision()
        }
        return true
    }

    public func resetRuleDraft() {
        ruleDraftName = ""
        ruleDraftPattern = ""
        ruleDraftLocation = .body
        ruleDraftPatternKind = .substring
        ruleDraftLabelID = "life.pickup_code"
    }

    public func updateRule(
        id: UUID,
        name: String,
        location: RuleMatchLocation,
        patternKind: RulePatternKind,
        pattern: String,
        labelID: String
    ) -> Bool {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else {
            showToast(.error, String(localized: "请输入匹配内容"))
            return false
        }
        if patternKind == .regex, !isValidRegex(trimmedPattern) {
            showToast(.error, String(localized: "正则表达式格式不正确"))
            return false
        }
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName: String
        if trimmedName.isEmpty {
            finalName = nextDefaultRuleName()
        } else {
            finalName = trimmedName
        }

        let matcherKind: SenderMatcher.Kind = patternKind == .regex ? .regex : .substring
        let textKind: TextMatcher.Kind = patternKind == .regex ? .regex : .substring

        var rule = rules[index]
        rule.name = finalName
        rule.targetLabelID = labelID
        switch location {
        case .sender:
            rule.sender = SenderMatcher(kind: matcherKind, pattern: trimmedPattern)
            rule.text = nil
        case .body:
            rule.sender = nil
            rule.text = TextMatcher(kind: textKind, pattern: trimmedPattern)
        }
        rules[index] = rule
        showToast(.success, String(localized: "规则已更新"))
        if canClassifyCurrentDraft {
            classifyCurrentDraft()
        } else {
            clearCurrentDecision()
        }
        return true
    }

    public func deleteRule(id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return
        }
        rules.remove(at: index)
        normalizeRulePriorities()
        showToast(.success, String(localized: "规则已删除"))
        if canClassifyCurrentDraft {
            classifyCurrentDraft()
        } else {
            clearCurrentDecision()
        }
    }

    public func deleteCustomRules(at offsets: IndexSet) {
        guard !offsets.isEmpty else {
            return
        }

        let ids = offsets.compactMap { index -> UUID? in
            guard rules.indices.contains(index) else {
                return nil
            }
            return rules[index].id
        }

        guard !ids.isEmpty else {
            return
        }

        rules.removeAll { ids.contains($0.id) }
        normalizeRulePriorities()
        statusMessage = String(localized: "已删除 \(ids.count) 条规则")
        if canClassifyCurrentDraft {
            classifyCurrentDraft()
        } else {
            clearCurrentDecision()
        }
    }

    public func moveCustomRules(from source: IndexSet, to destination: Int) {
        guard !rules.isEmpty else {
            return
        }
        rules.move(fromOffsets: source, toOffset: destination)
        normalizeRulePriorities()
        statusMessage = String(localized: "规则顺序已更新")
        if canClassifyCurrentDraft {
            classifyCurrentDraft()
        } else {
            clearCurrentDecision()
        }
    }

    private static let remoteSamplePrivacyConsentKey = "Sift.hasAcceptedRemoteSamplePrivacy"
    private static let lastRemoteSampleReceiptTokenKey = "Sift.lastRemoteSampleReceiptToken"

    private func persistRules() {
        SharedRuleStore.save(rules)
    }

    private static func loadPersistedRules() -> [CustomRule] {
        SharedRuleStore.load()
    }

    private static func displayDate(for timestamp: String) -> String {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        guard
            let date = fractionalFormatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp)
        else {
            return String(timestamp.prefix(10))
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func configuredPrivacyPolicyURL() -> URL {
        let keys = ["SiftPrivacyPolicyURL", "SIFT_PRIVACY_POLICY_URL"]
        for key in keys {
            guard
                let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                let url = URL(string: value),
                url.scheme != nil
            else {
                continue
            }
            return url
        }
        return URL(string: "https://sift.alkinum.io/privacy")!
    }

    private static func configuredTermsOfServiceURL() -> URL {
        let keys = ["SiftTermsOfServiceURL", "SIFT_TERMS_OF_SERVICE_URL"]
        for key in keys {
            guard
                let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                let url = URL(string: value),
                url.scheme != nil
            else {
                continue
            }
            return url
        }
        return URL(string: "https://sift.alkinum.io/terms")!
    }

    private func remoteSubmissionErrorMessage(for error: Error) -> String {
        if let message = cloudKitSampleErrorMessage(for: error, action: String(localized: "提交")) {
            return message
        }
        return String(localized: "提交失败：\(error.localizedDescription)")
    }

    private func remoteDeletionErrorMessage(for error: Error) -> String {
        if let message = cloudKitSampleErrorMessage(for: error, action: String(localized: "删除")) {
            return message
        }
        return String(localized: "删除失败：\(error.localizedDescription)")
    }

    /// Shared CloudKit error copy. Returns nil when the error is not one of
    /// the recognizable CloudKit / client conditions.
    private func cloudKitSampleErrorMessage(for error: Error, action: String) -> String? {
        if let clientError = error as? RemoteSampleClientError {
            switch clientError {
            case .cloudKitUnavailable:
                return String(localized: "当前环境不支持 iCloud，样本未\(action)")
            case .noAccount:
                return String(localized: "请先在系统设置中登录 iCloud，再匿名共享样本")
            case .accountRestricted:
                return String(localized: "此设备的 iCloud 账户受限，无法\(action)样本")
            case .accountUnknown:
                return String(localized: "暂时无法确认 iCloud 状态，请稍后重试")
            }
        }

        #if canImport(CloudKit)
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return String(localized: "请先在系统设置中登录 iCloud，再匿名共享样本")
            case .networkUnavailable, .networkFailure:
                return String(localized: "网络不可用，样本未\(action)")
            case .requestRateLimited, .zoneBusy:
                return String(localized: "操作过于频繁，请稍后重试")
            case .quotaExceeded:
                return String(localized: "iCloud 存储配额不足，样本未\(action)")
            case .serviceUnavailable:
                return String(localized: "iCloud 服务暂不可用，请稍后重试")
            case .permissionFailure:
                return String(localized: "iCloud 权限不足，样本未\(action)")
            default:
                return String(localized: "\(action)失败：iCloud 返回错误（\(ckError.code.rawValue)）")
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return String(localized: "\(action)超时，请稍后重试")
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "网络不可用，样本未\(action)")
            default:
                break
            }
        }
        #endif

        return nil
    }

    private func defaultRuleName(for pattern: String) -> String {
        nextDefaultRuleName()
    }

    public var defaultRuleNamePlaceholder: String {
        nextDefaultRuleName()
    }

    private func nextDefaultRuleName() -> String {
        let pattern = #"^规则\s*(\d+)$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        var maxIndex = 0
        for rule in rules {
            let name = rule.name
            let range = NSRange(name.startIndex..., in: name)
            if let match = regex?.firstMatch(in: name, range: range),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: name),
               let n = Int(name[r]) {
                maxIndex = max(maxIndex, n)
            }
        }
        return String(localized: "规则 \(maxIndex + 1)")
    }

    private func normalizeRulePriorities() {
        let basePriority = max(rules.count, 1) * 10
        for (offset, index) in rules.indices.enumerated() {
            rules[index].priority = basePriority - offset * 10
        }
    }

    private func isValidRegex(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil
    }
}

private final class TransformerDownloadProgressSink: @unchecked Sendable {
    weak var model: SiftAppModel?

    @MainActor
    init(model: SiftAppModel) {
        self.model = model
    }

    func update(_ progress: TransformerModelDownloadProgress) {
        Task { @MainActor in
            self.model?.updateTransformerDownloadProgress(progress)
        }
    }
}
