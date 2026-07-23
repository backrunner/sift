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

extension RuleAction {
    var title: String {
        switch self {
        case .allow:
            return String(localized: "放行")
        case .block:
            return String(localized: "阻止")
        }
    }

    var symbol: String {
        switch self {
        case .allow:
            return "checkmark.shield.fill"
        case .block:
            return "hand.raised.fill"
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

@MainActor
@Observable
public final class SiftToastCenter {
    public var toast: SiftToast?

    public init() {}

    public func show(_ kind: SiftToast.Kind, _ message: String) {
        toast = SiftToast(kind: kind, message: message)
    }
}

public struct SampleSubmissionFeedback: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let kind: SiftToast.Kind
    public let message: String
}

/// Serializes the relatively expensive PII model and detector work away from
/// the main actor. A lazy sanitizer keeps Core ML model loading off app launch.
private actor SanitizationWorker {
    private var sanitizer: PrivacySanitizer?

    func sanitize(_ text: String) -> String {
        guard !Task.isCancelled else {
            return text
        }
        if sanitizer == nil {
            sanitizer = PrivacySanitizer.withBundledModel()
        }
        return sanitizer?.sanitize(text).text ?? text
    }
}

private actor DraftClassificationWorker {
    func classify(
        pipeline: ClassificationPipeline,
        body: String,
        rules: [CustomRule],
        categoryMappings: [String: CategoryMappingTarget]
    ) -> ClassificationDecision {
        pipeline.classify(sender: nil, body: body, rules: rules)
            .applying(categoryMappings: categoryMappings)
    }
}

public protocol SiftModelClassifierLoading: Sendable {
    @concurrent
    func classifier(for variant: ModelVariant) async -> (any MessageClassifier)?
}

public struct DefaultSiftModelClassifierLoader: SiftModelClassifierLoading {
    public init() {}

    @concurrent
    public func classifier(for variant: ModelVariant) async -> (any MessageClassifier)? {
        switch variant {
        case .classic:
            return AppleClassifierLoader.classifier(for: .classic)
        case .transformer:
            guard let transformer = TransformerClassifierLoader.available() else {
                return nil
            }
            return CascadingClassifier(
                primary: transformer,
                fallback: HeuristicClassifier(),
                primaryThreshold: 0.5
            )
        }
    }
}

private struct SiftClassifierStack: Sendable {
    let base: any MessageClassifier
    let pipeline: ClassificationPipeline
}

private enum TransformerDownloadUIUpdate: Sendable {
    case progress(TransformerModelDownloadProgress)
    case phase(TransformerModelDownloadWorkPhase)
}

@MainActor
@Observable
public final class SiftAppModel {
    public var modelDate: String = "2026-05-06"
    public var modelVersion: String = "corpus-0.1"
    public private(set) var selectedModelVariant: ModelVariant = .classic
    public private(set) var transformerDeviceSupport: TransformerDeviceSupport
    public private(set) var isSwitchingModelVariant: Bool = false
    public private(set) var modelVariantBeingLoaded: ModelVariant?
    public private(set) var isTransformerModelAvailable: Bool
    public private(set) var isTransformerModelDownloaded: Bool
    public private(set) var installedTransformerVersion: String?
    public private(set) var isClearingTransformerModel: Bool = false
    public private(set) var transformerDownloadPhase: TransformerModelDownloadPhase = .notDownloaded
    public private(set) var transformerDownloadProgress: TransformerModelDownloadProgress?
    public private(set) var pendingTransformerDownloadPlan: TransformerModelDownloadPlan?
    public private(set) var transformerUpdateState: TransformerUpdateState = .unknown
    public var isShowingMeteredTransformerDownloadConfirmation: Bool = false
    public var submissionDestination: SubmissionDestination = .local
    public var testBody: String = ""
    public var submissionText: String = "" {
        didSet {
            scheduleSubmissionLabelSuggestion()
            scheduleSanitizedPreview()
        }
    }
    public var selectedLabelID: String = SiftTaxonomy.leaves.first?.id ?? "finance.bank"
    public var rules: [CustomRule] {
        didSet {
            persistRules()
        }
    }
    public var categoryMappings: [String: CategoryMappingTarget] {
        didSet {
            SharedCategoryMappingStore.save(categoryMappings, defaults: categoryMappingDefaults)
        }
    }
    public var ruleDraftName: String = ""
    public var ruleDraftPattern: String = ""
    public var ruleDraftLocation: RuleMatchLocation = .body
    public var ruleDraftPatternKind: RulePatternKind = .substring
    public var ruleDraftAction: RuleAction = .block
    public var localSampleCount: Int = 0
    public var lastReceiptToken: String?
    public var lastDecision: ClassificationDecision?
    public var sanitizedPreview: String = ""
    public var statusMessage: String = ""
    public var hasAcceptedRemoteSamplePrivacy: Bool {
        didSet {
            appDefaults.set(hasAcceptedRemoteSamplePrivacy, forKey: Self.remoteSamplePrivacyConsentKey)
        }
    }
    public var hasConfirmedFilterSetup: Bool {
        didSet {
            appDefaults.set(hasConfirmedFilterSetup, forKey: Self.filterSetupConfirmationKey)
        }
    }
    public let toastCenter = SiftToastCenter()
    public var sampleSubmissionFeedback: SampleSubmissionFeedback?
    public var isSubmittingSample: Bool = false
    public var isShowingPaywall: Bool = false
    public private(set) var isErasingRemoteData: Bool = false
    /// 本地记录的已贡献样本数(App Group 计数,云端历史列表为准)。
    public private(set) var submittedSampleCount: Int = 0

    // 提交历史(下拉无限加载,最多展示最近 historyMaxItems 条)。
    public static let historyPageSize = 30
    public static let historyMaxItems = 200
    public static let historyCacheRefreshInterval: TimeInterval = 15 * 60
    public private(set) var submissionHistory: [RemoteSubmissionSummary] = []
    public private(set) var isLoadingHistory: Bool = false
    public private(set) var historyFullyLoaded: Bool = false
    public private(set) var hasLoadedSubmissionHistory: Bool = false
    public private(set) var submissionHistoryErrorMessage: String?
    public private(set) var remoteAccountStatus: RemoteSampleAccountStatus = .checking
    public private(set) var isCheckingRemoteAccountStatus: Bool = false
    public var remoteAccountAlertMessage: String?

    /// 高级版(IAP)状态与购买流程。
    public let premium: PremiumStore

    @ObservationIgnored
    private let sanitizationWorker = SanitizationWorker()

    @ObservationIgnored
    private let draftClassificationWorker = DraftClassificationWorker()

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
    private let transformerUpdateChecker: (any TransformerModelUpdateChecking)?

    @ObservationIgnored
    private let transformerNetworkConditionChecker: any TransformerNetworkConditionChecking

    @ObservationIgnored
    private let modelClassifierLoader: any SiftModelClassifierLoading

    @ObservationIgnored
    private var transformerDownloadTask: Task<Void, Never>?

    @ObservationIgnored
    private var transformerUpdateCheckTask: Task<Void, Never>?

    @ObservationIgnored
    private var automaticTransformerUpdateTask: Task<Void, Never>?

    @ObservationIgnored
    private var automaticTransformerUpdateRequestID: UUID?

    @ObservationIgnored
    private var hasPendingTransformerBackgroundDownloadEvents = false

    @ObservationIgnored
    private var installedTransformerIdentity: ModelArtifactIdentity?

    @ObservationIgnored
    private var installedTransformerTrainedAt: String?

    @ObservationIgnored
    private let transformerModelRemover: any TransformerModelRemoving

    @ObservationIgnored
    private var transformerCleanupTask: Task<Void, Never>?

    @ObservationIgnored
    private var modelSwitchTask: Task<Void, Never>?

    @ObservationIgnored
    private var modelSwitchRequestID: UUID?

    @ObservationIgnored
    private var modelVariantToRestoreAfterEntitlement: ModelVariant?

    @ObservationIgnored
    private let modelSelectionDefaults: UserDefaults?

    @ObservationIgnored
    private let appDefaults: UserDefaults

    /// 注入口:测试用独立 UserDefaults suite 隔离贡献计数。
    @ObservationIgnored
    private let ledgerDefaults: UserDefaults?

    @ObservationIgnored
    private let categoryMappingDefaults: UserDefaults?

    @ObservationIgnored
    private let ruleDefaults: UserDefaults?

    @ObservationIgnored
    private var submissionLabelSuggestionTask: Task<Void, Never>?

    @ObservationIgnored
    private var sanitizedPreviewTask: Task<Void, Never>?

    @ObservationIgnored
    private var draftClassificationTask: Task<Void, Never>?

    @ObservationIgnored
    private var draftClassificationRequestID: UUID?

    @ObservationIgnored
    private var transientReceiptGeneration = 0

    private var sanitizedPreviewSourceText = ""

    @ObservationIgnored
    private var hasManuallySelectedSubmissionLabel = false

    @ObservationIgnored
    private var submissionHistoryCacheUpdatedAt: Date?

    public init(
        remoteSampleClient: (any RemoteSampleSubmitting)? = nil,
        premiumBackend: (any PremiumPurchasing)? = nil,
        transformerAvailabilityOverride: Bool? = nil,
        transformerDownloadedOverride: Bool? = nil,
        transformerDeviceSupportOverride: TransformerDeviceSupport? = nil,
        transformerDownloader: (any TransformerModelDownloading)? = TransformerModelDownloadClient.configured(),
        transformerUpdateChecker: (any TransformerModelUpdateChecking)? = nil,
        transformerNetworkConditionChecker: any TransformerNetworkConditionChecking = PathNetworkConditionChecker(),
        transformerModelRemover: any TransformerModelRemoving = TransformerModelStoreRemover(),
        modelClassifierLoader: any SiftModelClassifierLoading = DefaultSiftModelClassifierLoader(),
        modelSelectionDefaults: UserDefaults? = nil,
        appDefaults: UserDefaults? = nil,
        ledgerDefaults: UserDefaults? = nil,
        categoryMappingDefaults: UserDefaults? = nil,
        ruleDefaults: UserDefaults? = nil,
        sampleStore: LocalSampleStore? = nil
    ) {
        let resolvedAppDefaults = appDefaults ?? .standard
        self.appDefaults = resolvedAppDefaults
        self.hasAcceptedRemoteSamplePrivacy = resolvedAppDefaults.bool(forKey: Self.remoteSamplePrivacyConsentKey)
        self.hasConfirmedFilterSetup = resolvedAppDefaults.bool(forKey: Self.filterSetupConfirmationKey)
        self.modelSelectionDefaults = modelSelectionDefaults
        self.ledgerDefaults = ledgerDefaults
        self.categoryMappingDefaults = categoryMappingDefaults
        self.ruleDefaults = ruleDefaults
        self.sampleStore = sampleStore ?? LocalSampleStore(fileURL: LocalSampleStore.defaultFileURL())
        self.remoteSampleClient = remoteSampleClient ?? CloudKitSampleClient(
            containerIdentifier: CloudKitSampleClient.configuredContainerIdentifier()
        )
        self.transformerDownloader = transformerDownloader
        self.transformerUpdateChecker = transformerUpdateChecker
            ?? (transformerDownloader as? any TransformerModelUpdateChecking)
        self.transformerNetworkConditionChecker = transformerNetworkConditionChecker
        self.transformerModelRemover = transformerModelRemover
        self.modelClassifierLoader = modelClassifierLoader
        let resolvedTransformerDeviceSupport = transformerDeviceSupportOverride ?? .current()
        self.transformerDeviceSupport = resolvedTransformerDeviceSupport
        self.premium = PremiumStore(backend: premiumBackend)

        let installedTransformer = TransformerClassifierLoader.installedModel(validateChecksums: false)
        self.installedTransformerVersion = installedTransformer?.manifest.version
        self.installedTransformerTrainedAt = installedTransformer?.manifest.trainedAt
        self.installedTransformerIdentity = installedTransformer?.manifest.artifactIdentity
        let transformerDownloaded = transformerDownloadedOverride ?? (installedTransformer != nil)
        let transformerAvailable = transformerAvailabilityOverride
            ?? (installedTransformer.map { TransformerClassifierLoader.isReady($0) } == true)
        self.isTransformerModelDownloaded = transformerDownloaded
        self.isTransformerModelAvailable = transformerAvailable
        self.transformerDownloadPhase = transformerAvailable ? .ready : .notDownloaded
        let storedVariant = ModelSelectionStore.load(defaults: modelSelectionDefaults)
        let shouldRestoreTransformer = storedVariant == .transformer
            && transformerAvailable
            && resolvedTransformerDeviceSupport.isSupported
        if shouldRestoreTransformer {
            self.modelVariantToRestoreAfterEntitlement = .transformer
        } else if storedVariant == .transformer {
            ModelSelectionStore.save(.classic, defaults: modelSelectionDefaults)
        }
        let placeholder = HeuristicClassifier()
        // Keep the persisted choice visible while the initial classifier load
        // runs, avoiding a misleading classic-model flash on launch.
        self.selectedModelVariant = shouldRestoreTransformer ? .transformer : .classic
        self.baseClassifier = placeholder
        self.pipeline = ClassificationPipeline(classifier: placeholder)
        self.rules = Self.loadPersistedRules(defaults: ruleDefaults)
        self.categoryMappings = SharedCategoryMappingStore.load(defaults: categoryMappingDefaults)

        TransformerBackgroundSessionEvents.registerReconnectHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumeTransformerBackgroundDownload()
            }
        }

        if let cachedHistory = SubmissionHistoryCache.load(defaults: ledgerDefaults) {
            self.submissionHistory = Array(cachedHistory.submissions.prefix(Self.historyMaxItems))
            self.historyFullyLoaded = cachedHistory.fullyLoaded
            self.hasLoadedSubmissionHistory = true
            self.submissionHistoryCacheUpdatedAt = cachedHistory.updatedAt
        }

        refreshModelMetadataDisplay()
        classifyCurrentDraft()
        Task { await refreshLocalSampleCount() }

        reconcileSubmittedSampleCount(
            historyIsComplete: historyFullyLoaded && submissionHistory.count < Self.historyMaxItems
        )

        // 首次授权解析后恢复选择；退款/撤销时取消工作并回退经典模型。
        premium.onEntitlementChange = { [weak self] unlocked in
            guard let self else {
                return
            }
            if unlocked {
                if self.selectedModelVariant == .transformer {
                    self.scheduleAutomaticTransformerUpdateIfEligible(force: true)
                } else {
                    self.checkForTransformerUpdate()
                }
                guard self.modelVariantToRestoreAfterEntitlement == .transformer else {
                    return
                }
                self.modelVariantToRestoreAfterEntitlement = nil
                self.switchToModelVariant(
                    .transformer,
                    showsSuccessToast: false,
                    priority: .utility
                ) { [weak self] didSwitch in
                    guard !didSwitch else { return }
                    self?.switchToModelVariant(.classic, showsSuccessToast: false, priority: .utility)
                }
                return
            }
            let wasWaitingToRestoreTransformer = self.modelVariantToRestoreAfterEntitlement == .transformer
            self.modelVariantToRestoreAfterEntitlement = nil
            self.cancelAutomaticTransformerUpdate()
            self.cancelPendingTransformerDownload()
            if self.modelVariantBeingLoaded == .transformer {
                self.cancelModelSwitch()
            }
            if wasWaitingToRestoreTransformer {
                ModelSelectionStore.save(.classic, defaults: self.modelSelectionDefaults)
                self.switchToModelVariant(.classic, showsSuccessToast: false, priority: .utility)
                return
            }
            guard self.selectedModelVariant == .transformer else {
                return
            }
            if self.modelVariantBeingLoaded == .classic {
                return
            }
            self.switchToModelVariant(.classic, showsSuccessToast: false) { [weak self] didSwitch in
                guard didSwitch else { return }
                self?.showToast(.info, String(localized: "高级版授权已失效，已切换回经典模型"))
            }
        }

        if remoteSampleClient == nil {
            refreshRemoteAccountStatus()
        } else {
            remoteAccountStatus = .available
        }

        if !shouldRestoreTransformer {
            switchToModelVariant(.classic, showsSuccessToast: false, priority: .utility)
        }
    }

    /// Whether the active model variant allows on-device fine-tuning. The
    /// transformer variant is frozen, so all personalization UI must hide.
    public var supportsLocalPersonalization: Bool {
        selectedModelVariant.supportsLocalPersonalization
    }

    public var isTransformerDeviceSupported: Bool {
        transformerDeviceSupport.isSupported
    }

    public var hasCompatibleTransformerUpdate: Bool {
        if case .updateAvailable = transformerUpdateState {
            return isTransformerModelDownloaded
        }
        return false
    }

    public var transformerUpdateReleaseID: String? {
        switch transformerUpdateState {
        case let .updateAvailable(channel), let .requiresAppUpdate(channel), let .incompatible(channel):
            return channel.releaseID
        case .unknown, .checking, .current, .failed:
            return nil
        }
    }

    public var transformerUpdateDownloadSizeText: String? {
        guard case let .updateAvailable(channel) = transformerUpdateState, channel.downloadBytes > 0 else {
            return nil
        }
        return Self.formatByteCount(channel.downloadBytes)
    }

    public var transformerUpdateStatusText: String? {
        switch transformerUpdateState {
        case .unknown, .checking, .current, .requiresAppUpdate, .incompatible, .failed:
            return nil
        case .updateAvailable:
            return String(localized: "有新版本可下载")
        }
    }

    public func checkForTransformerUpdate(force: Bool = false) {
        guard premium.isUnlocked, isTransformerDeviceSupported else {
            return
        }
        guard transformerUpdateCheckTask == nil, let transformerUpdateChecker else {
            return
        }
        let lastCheck = appDefaults.object(forKey: Self.transformerUpdateLastCheckKey) as? Date
        if
            !force,
            let lastCheck,
            Date().timeIntervalSince(lastCheck) < Self.transformerUpdateCheckInterval
        {
            return
        }
        transformerUpdateState = .checking
        let identity = installedTransformerIdentity
        transformerUpdateCheckTask = Task { [weak self] in
            guard let self else { return }
            let state = await transformerUpdateChecker.checkForUpdate(currentIdentity: identity)
            self.transformerUpdateCheckTask = nil
            guard !Task.isCancelled else { return }
            transformerUpdateState = state
            appDefaults.set(Date(), forKey: Self.transformerUpdateLastCheckKey)
        }
    }

    public func downloadTransformerUpdate() {
        guard isTransformerDeviceSupported else {
            showTransformerUnsupportedMessage()
            return
        }
        guard hasCompatibleTransformerUpdate, premium.isUnlocked else {
            return
        }
        beginTransformerDownloadAndSwitch(allowMeteredNetwork: false)
    }

    public func applicationDidBecomeActive() {
        if selectedModelVariant == .transformer {
            scheduleAutomaticTransformerUpdateIfEligible(
                force: hasPendingTransformerBackgroundDownloadEvents
            )
        } else {
            checkForTransformerUpdate()
        }
    }

    func resumeTransformerBackgroundDownload() {
        hasPendingTransformerBackgroundDownloadEvents = true
        scheduleAutomaticTransformerUpdateIfEligible(force: true)
    }

    public var availableModelVariants: [ModelVariant] {
        ModelVariant.allCases
    }

    public func isModelVariantAvailable(_ variant: ModelVariant) -> Bool {
        variant != .transformer
            || (
                isTransformerDeviceSupported
                    && (isTransformerModelAvailable || transformerDownloader != nil || !premium.isUnlocked)
            )
    }

    /// Manifest version for a variant, for display in the model picker.
    public func modelVersion(for variant: ModelVariant) -> String? {
        switch variant {
        case .classic:
            return nil
        case .transformer:
            return installedTransformerVersion ?? pendingTransformerDownloadPlan?.manifest.version
        }
    }

    public func selectModelVariant(_ variant: ModelVariant) {
        guard
            variant != selectedModelVariant,
            variant != modelVariantBeingLoaded,
            !isClearingTransformerModel
        else {
            return
        }
        if variant == .transformer, !isTransformerDeviceSupported {
            showTransformerUnsupportedMessage()
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

        if variant == .classic {
            cancelAutomaticTransformerUpdate()
        }

        switchToModelVariant(variant)
    }

    public func showTransformerUnsupportedMessage() {
        showToast(.info, String(localized: "此设备不支持 Sift Signal 高级模型"))
    }

    private func switchToModelVariant(
        _ variant: ModelVariant,
        showsSuccessToast: Bool = true,
        priority: TaskPriority = .userInitiated,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard variant != .transformer || isTransformerDeviceSupported else {
            showTransformerUnsupportedMessage()
            completion?(false)
            return
        }
        modelSwitchTask?.cancel()
        let requestID = UUID()
        modelSwitchRequestID = requestID
        modelVariantBeingLoaded = variant
        isSwitchingModelVariant = true
        let modelClassifierLoader = modelClassifierLoader

        // Core ML loading (and possible first-launch model compilation) is
        // slow enough to hitch the UI; build the new stack off the main actor.
        modelSwitchTask = Task(priority: priority) { [weak self] in
            // Automatic startup restoration yields the first frame before a
            // large Core ML graph starts competing for CPU and memory bandwidth.
            if priority == .utility {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            let stack = await Self.makeClassifierStack(for: variant, loader: modelClassifierLoader)

            guard
                let self,
                !Task.isCancelled,
                self.modelSwitchRequestID == requestID
            else {
                return
            }

            self.modelSwitchTask = nil
            self.modelSwitchRequestID = nil
            self.modelVariantBeingLoaded = nil
            self.isSwitchingModelVariant = false

            guard let stack else {
                if variant == .transformer {
                    self.transformerDownloadPhase = .failed(String(localized: "高级模型加载失败"))
                    self.showToast(.error, String(localized: "高级模型加载失败"))
                }
                completion?(false)
                return
            }

            // Keep the old Core ML graph alive across both assignments, then
            // release it on a cooperative-pool thread. Destroying a loaded
            // Transformer on the main actor can stall UI commits for seconds.
            let retiredStack = SiftClassifierStack(
                base: self.baseClassifier,
                pipeline: self.pipeline
            )
            self.baseClassifier = stack.base
            self.pipeline = stack.pipeline
            Task.detached(priority: .utility) {
                withExtendedLifetime(retiredStack) {}
            }
            self.selectedModelVariant = variant
            ModelSelectionStore.save(
                variant,
                defaults: self.modelSelectionDefaults,
                artifactIdentity: variant == .transformer ? self.installedTransformerIdentity : .classic
            )
            self.refreshModelMetadataDisplay()
            if !variant.supportsLocalPersonalization {
                if self.submissionDestination == .local {
                    self.submissionDestination = .remote
                }
                self.sampleSubmissionFeedback = nil
            }

            if self.canClassifyCurrentDraft {
                self.classifyCurrentDraft()
            } else {
                self.clearCurrentDecision()
            }
            if showsSuccessToast {
                self.showToast(.success, String(localized: "已切换至\(variant.title)"))
            }
            completion?(true)
            if variant == .transformer {
                self.scheduleAutomaticTransformerUpdateIfEligible()
            }
        }
    }

    private func cancelModelSwitch() {
        modelSwitchTask?.cancel()
        modelSwitchTask = nil
        modelSwitchRequestID = nil
        modelVariantBeingLoaded = nil
        isSwitchingModelVariant = false
    }

    public func clearDownloadedTransformerModel() {
        guard
            isTransformerModelDownloaded,
            !isClearingTransformerModel,
            !isTransformerDownloadActive,
            !isSwitchingModelVariant
        else {
            return
        }

        isClearingTransformerModel = true
        cancelAutomaticTransformerUpdate()
        if selectedModelVariant == .transformer {
            switchToModelVariant(.classic, showsSuccessToast: false) { [weak self] didSwitch in
                guard let self else { return }
                guard didSwitch else {
                    self.isClearingTransformerModel = false
                    return
                }
                self.removeDownloadedTransformerModel()
            }
        } else {
            removeDownloadedTransformerModel()
        }
    }

    private func removeDownloadedTransformerModel() {
        let remover = transformerModelRemover
        transformerCleanupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await remover.removeInstalledModel()
                guard !Task.isCancelled else { return }
                self.isTransformerModelDownloaded = false
                self.isTransformerModelAvailable = false
                self.transformerDownloadPhase = .notDownloaded
                self.pendingTransformerDownloadPlan = nil
                self.transformerDownloadProgress = nil
                self.installedTransformerVersion = nil
                self.installedTransformerTrainedAt = nil
                self.installedTransformerIdentity = nil
                self.isClearingTransformerModel = false
                self.transformerCleanupTask = nil
                self.showToast(.success, String(localized: "Sift Signal 模型已清理"))
            } catch is CancellationError {
                self.isClearingTransformerModel = false
                self.transformerCleanupTask = nil
            } catch {
                self.isClearingTransformerModel = false
                self.transformerCleanupTask = nil
                self.showToast(
                    .error,
                    String(
                        format: String(localized: "清理 Sift Signal 模型失败：%@"),
                        error.localizedDescription
                    )
                )
            }
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
        guard isTransformerDeviceSupported else {
            cancelPendingTransformerDownload()
            showTransformerUnsupportedMessage()
            return
        }
        guard let pendingTransformerDownloadPlan else {
            beginTransformerDownloadAndSwitch(allowMeteredNetwork: true)
            return
        }
        downloadPreparedTransformerPlan(pendingTransformerDownloadPlan.allowingMeteredNetwork())
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
        guard isTransformerDeviceSupported else {
            showTransformerUnsupportedMessage()
            return
        }
        guard transformerDownloadTask == nil else {
            return
        }
        guard let transformerDownloader else {
            let message = TransformerModelDownloadError.missingRemoteManifestURL.localizedDescription
            transformerDownloadPhase = .failed(message)
            showToast(.error, message)
            return
        }

        cancelAutomaticTransformerUpdate()

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
                downloadPreparedTransformerPlan(
                    allowMeteredNetwork ? plan.allowingMeteredNetwork() : plan
                )
            } catch {
                guard !Task.isCancelled else { return }
                handleTransformerDownloadFailure(error)
            }
        }
    }

    private func downloadPreparedTransformerPlan(_ plan: TransformerModelDownloadPlan) {
        guard isTransformerDeviceSupported else {
            cancelPendingTransformerDownload()
            showTransformerUnsupportedMessage()
            return
        }
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
            let (updateStream, updateContinuation) = AsyncStream<TransformerDownloadUIUpdate>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let updateConsumer = Task { @MainActor [weak self] in
                for await update in updateStream {
                    guard let self else {
                        return
                    }
                    switch update {
                    case .progress(let progress):
                        guard self.transformerDownloadPhase == .downloading else {
                            continue
                        }
                        self.updateTransformerDownloadProgress(progress)
                    case .phase(.downloading):
                        self.transformerDownloadPhase = .downloading
                    case .phase(.installing):
                        self.transformerDownloadPhase = .installing
                    }
                }
            }
            defer {
                updateContinuation.finish()
                updateConsumer.cancel()
            }

            do {
                try await transformerDownloader.download(
                    plan,
                    progress: { progress in
                        updateContinuation.yield(.progress(progress))
                    },
                    phase: { phase in
                        updateContinuation.yield(.phase(phase))
                    }
                )
                guard !Task.isCancelled else { return }
                updateContinuation.finish()
                await updateConsumer.value
                isTransformerModelDownloaded = TransformerClassifierLoader.isDownloadedModelAvailable()
                isTransformerModelAvailable = TransformerClassifierLoader.isAvailable()
                transformerDownloadPhase = isTransformerModelAvailable ? .ready : .failed(String(localized: "高级模型安装失败"))
                transformerDownloadTask = nil
                if isTransformerModelAvailable {
                    installedTransformerVersion = plan.manifest.version
                    installedTransformerTrainedAt = plan.manifest.trainedAt
                    installedTransformerIdentity = plan.manifest.artifactIdentity
                    transformerUpdateState = .current
                    if selectedModelVariant == .transformer {
                        ModelSelectionStore.save(
                            .transformer,
                            defaults: modelSelectionDefaults,
                            artifactIdentity: plan.manifest.artifactIdentity
                        )
                    }
                    switchToModelVariant(.transformer)
                } else {
                    showToast(.error, String(localized: "高级模型安装失败"))
                }
            } catch {
                guard !Task.isCancelled else { return }
                handleTransformerDownloadFailure(error)
            }
        }
    }

    private func handleTransformerDownloadFailure(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        transformerDownloadPhase = .failed(message)
        transformerDownloadTask = nil
        showToast(.error, message)
    }

    private func scheduleAutomaticTransformerUpdateIfEligible(force: Bool = false) {
        guard
            selectedModelVariant == .transformer,
            premium.isUnlocked,
            isTransformerDeviceSupported,
            isTransformerModelAvailable,
            transformerDownloadTask == nil,
            automaticTransformerUpdateTask == nil,
            let transformerDownloader,
            let transformerUpdateChecker
        else {
            return
        }

        let mustReconnectBackgroundSession = hasPendingTransformerBackgroundDownloadEvents
        let lastCheck = appDefaults.object(forKey: Self.transformerUpdateLastCheckKey) as? Date
        if
            let lastCheck,
            !force,
            !mustReconnectBackgroundSession,
            Date().timeIntervalSince(lastCheck) < Self.transformerUpdateCheckInterval
        {
            return
        }

        let identity = installedTransformerIdentity
        let networkChecker = transformerNetworkConditionChecker
        let requestID = UUID()
        automaticTransformerUpdateRequestID = requestID
        automaticTransformerUpdateTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let networkCondition = await networkChecker.currentCondition()
            guard
                self.isAutomaticTransformerUpdateCurrent(requestID, expectedIdentity: identity),
                networkCondition.allowsAutomaticModelUpdate
            else {
                self.finishAutomaticTransformerUpdate(requestID)
                return
            }

            self.hasPendingTransformerBackgroundDownloadEvents = false

            let state = await transformerUpdateChecker.checkForUpdate(currentIdentity: identity)
            guard self.isAutomaticTransformerUpdateCurrent(requestID, expectedIdentity: identity) else {
                self.finishAutomaticTransformerUpdate(requestID)
                return
            }
            self.transformerUpdateState = state
            self.appDefaults.set(Date(), forKey: Self.transformerUpdateLastCheckKey)
            guard case .updateAvailable = state else {
                self.finishAutomaticTransformerUpdate(requestID)
                return
            }

            do {
                let plan = try await transformerDownloader.prepareDownload().forAutomaticUpdate()
                guard
                    self.isAutomaticTransformerUpdateCurrent(requestID, expectedIdentity: identity),
                    plan.networkCondition.allowsAutomaticModelUpdate
                else {
                    self.finishAutomaticTransformerUpdate(requestID)
                    return
                }
                try await transformerDownloader.download(
                    plan,
                    progress: { _ in },
                    phase: { _ in }
                )
                guard self.isAutomaticTransformerUpdateCurrent(requestID, expectedIdentity: identity) else {
                    self.finishAutomaticTransformerUpdate(requestID)
                    return
                }

                self.isTransformerModelDownloaded = TransformerClassifierLoader.isDownloadedModelAvailable()
                self.isTransformerModelAvailable = TransformerClassifierLoader.isAvailable()
                guard self.isTransformerModelAvailable else {
                    self.finishAutomaticTransformerUpdate(requestID)
                    return
                }

                self.installedTransformerVersion = plan.manifest.version
                self.installedTransformerTrainedAt = plan.manifest.trainedAt
                self.installedTransformerIdentity = plan.manifest.artifactIdentity
                self.transformerUpdateState = .current
                ModelSelectionStore.save(
                    .transformer,
                    defaults: self.modelSelectionDefaults,
                    artifactIdentity: plan.manifest.artifactIdentity
                )
                self.finishAutomaticTransformerUpdate(requestID)
                self.switchToModelVariant(
                    .transformer,
                    showsSuccessToast: false,
                    priority: .utility
                )
            } catch is CancellationError {
                self.finishAutomaticTransformerUpdate(requestID)
            } catch {
                // Automatic updates are best-effort. The currently loaded and
                // installed model remain active, and the next eligible launch retries.
                self.finishAutomaticTransformerUpdate(requestID)
            }
        }
    }

    private func isAutomaticTransformerUpdateCurrent(
        _ requestID: UUID,
        expectedIdentity: ModelArtifactIdentity?
    ) -> Bool {
        !Task.isCancelled
            && automaticTransformerUpdateRequestID == requestID
            && selectedModelVariant == .transformer
            && premium.isUnlocked
            && isTransformerDeviceSupported
            && installedTransformerIdentity == expectedIdentity
    }

    private func finishAutomaticTransformerUpdate(_ requestID: UUID) {
        guard automaticTransformerUpdateRequestID == requestID else { return }
        automaticTransformerUpdateTask = nil
        automaticTransformerUpdateRequestID = nil
    }

    private func cancelAutomaticTransformerUpdate() {
        automaticTransformerUpdateTask?.cancel()
        automaticTransformerUpdateTask = nil
        automaticTransformerUpdateRequestID = nil
    }

    fileprivate func updateTransformerDownloadProgress(_ progress: TransformerModelDownloadProgress) {
        transformerDownloadProgress = progress
    }

    /// Builds the classifier stack for a variant, layering the persisted
    /// personalization adapter on top when the variant allows local
    /// fine-tuning. Safe to call from any executor.
    @concurrent
    private nonisolated static func makeClassifierStack(
        for variant: ModelVariant,
        loader: any SiftModelClassifierLoading
    ) async -> SiftClassifierStack? {
        guard !Task.isCancelled, let base = await loader.classifier(for: variant), !Task.isCancelled else {
            return nil
        }
        if variant == .classic, let personalized = loadPersistedPersonalization() {
            return SiftClassifierStack(
                base: base,
                pipeline: ClassificationPipeline(
                    classifier: CascadingClassifier(primary: personalized, fallback: base)
                )
            )
        }
        return SiftClassifierStack(
            base: base,
            pipeline: ClassificationPipeline(classifier: base)
        )
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
            if let installedTransformerVersion, let installedTransformerTrainedAt {
                modelDate = Self.displayDate(for: installedTransformerTrainedAt)
                modelVersion = installedTransformerVersion
            }
        }
    }

    public var selectedLabel: LeafLabel {
        SiftTaxonomy.leaf(id: selectedLabelID) ?? SiftTaxonomy.leaves[0]
    }

    public func selectSubmissionLabel(_ labelID: String) {
        guard SiftTaxonomy.leaf(id: labelID) != nil else {
            return
        }
        submissionLabelSuggestionTask?.cancel()
        hasManuallySelectedSubmissionLabel = true
        selectedLabelID = labelID
    }

    public var activeRuleCount: Int {
        rules.filter(\.enabled).count
    }

    public var customRuleCount: Int {
        rules.count
    }

    public var mappedCategoryCount: Int {
        categoryMappings.count
    }

    public func categoryMapping(for labelID: String) -> CategoryMappingTarget? {
        categoryMappings[labelID]
    }

    public func setCategoryMapping(_ target: CategoryMappingTarget?, for labelID: String) {
        guard CategoryMappingPolicy.isEligibleSource(labelID: labelID) else {
            return
        }
        categoryMappings[labelID] = target
        classifyCurrentDraft()
    }

    public var customRuleIndices: [Int] {
        Array(rules.indices)
    }

    public var canClassifyCurrentDraft: Bool {
        let body = testBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return !body.isEmpty && !isSwitchingModelVariant
    }

    /// 单条样本的最大长度(与训练侧长度过滤一致)。
    public static let maxSubmissionTextLength = 500

    public var canSubmitSample: Bool {
        let text = submissionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !text.isEmpty,
            text.count <= Self.maxSubmissionTextLength,
            !isSwitchingModelVariant
        else {
            return false
        }
        if submissionDestination == .remote && !hasAcceptedRemoteSamplePrivacy {
            return false
        }
        if submissionDestination == .remote && !canUseRemoteSubmission {
            return false
        }
        if submissionDestination == .remote && isErasingRemoteData {
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
        return sanitizedPreviewSourceText == submissionText && sanitizedPreview != submissionText
    }

    private func scheduleSanitizedPreview() {
        sanitizedPreviewTask?.cancel()
        let text = submissionText

        guard !text.isEmpty else {
            sanitizedPreviewSourceText = ""
            sanitizedPreview = ""
            return
        }

        let worker = sanitizationWorker
        sanitizedPreviewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(220))
                try Task.checkCancellation()
            } catch {
                return
            }

            let sanitized = await worker.sanitize(text)
            guard !Task.isCancelled else {
                return
            }
            guard let self, self.submissionText == text else {
                return
            }
            self.sanitizedPreviewSourceText = text
            self.sanitizedPreview = sanitized
        }
    }

    private func scheduleSubmissionLabelSuggestion() {
        submissionLabelSuggestionTask?.cancel()
        let text = submissionText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            hasManuallySelectedSubmissionLabel = false
            selectedLabelID = SiftTaxonomy.leaves.first?.id ?? "finance.bank"
            return
        }
        guard !hasManuallySelectedSubmissionLabel else {
            return
        }

        submissionLabelSuggestionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }

            let classifier = self.pipeline.classifier
            let decision = await Task.detached(priority: .userInitiated) {
                classifier.classify(sender: nil, body: text)
            }.value

            guard
                !Task.isCancelled,
                !self.hasManuallySelectedSubmissionLabel,
                self.submissionText.trimmingCharacters(in: .whitespacesAndNewlines) == text,
                SiftTaxonomy.leaf(id: decision.labelID) != nil
            else {
                return
            }
            self.selectedLabelID = decision.labelID
        }
    }

    public func clearCurrentDecision() {
        draftClassificationTask?.cancel()
        draftClassificationTask = nil
        draftClassificationRequestID = nil
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
            clearCurrentDecision()
            return
        }

        draftClassificationTask?.cancel()
        let requestID = UUID()
        draftClassificationRequestID = requestID
        let worker = draftClassificationWorker
        let pipeline = pipeline
        let rules = rules
        let categoryMappings = categoryMappings

        // Transformer inference must never occupy the main actor. The request
        // id prevents a stale result from replacing a newer draft or model.
        draftClassificationTask = Task { [weak self] in
            let decision = await worker.classify(
                pipeline: pipeline,
                body: body,
                rules: rules,
                categoryMappings: categoryMappings
            )
            guard
                let self,
                !Task.isCancelled,
                self.draftClassificationRequestID == requestID,
                self.testBody.trimmingCharacters(in: .whitespacesAndNewlines) == body
            else {
                return
            }
            self.lastDecision = decision
            self.draftClassificationTask = nil
            self.draftClassificationRequestID = nil
        }
    }

    public func submitSample() {
        guard !isSubmittingSample else { return }
        guard submissionDestination != .remote || !isErasingRemoteData else {
            showSubmissionFeedback(.info, String(localized: "请等待数据清空完成"))
            return
        }
        sampleSubmissionFeedback = nil
        let selectedLabel = selectedLabel
        let text = submissionText
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            showSubmissionFeedback(.error, String(localized: "请输入样本文本"))
            return
        }
        switch submissionDestination {
        case .local:
            guard supportsLocalPersonalization else {
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
                    guard try await sampleStore.appendIfUnique(sample) else {
                        showSubmissionFeedback(.info, String(localized: "您已提交过类似样本"))
                        return
                    }
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
            let worker = sanitizationWorker
            let classifier = baseClassifier
            let receiptGeneration = transientReceiptGeneration
            Task { [weak self] in
                guard let self else { return }
                defer { isSubmittingSample = false }
                do {
                    let sanitizedText = await worker.sanitize(text)
                    guard !Task.isCancelled else { return }

                    if self.submissionText == text {
                        self.sanitizedPreviewSourceText = text
                        self.sanitizedPreview = sanitizedText
                    }

                    guard !self.submissionHistory.contains(where: {
                        $0.label == selectedLabel.id && SubmissionSimilarity.isSimilar($0.text, sanitizedText)
                    }) else {
                        self.showSubmissionFeedback(.info, String(localized: "您已提交过类似样本"))
                        return
                    }

                    // Coarse-classify the sanitized text with the base model
                    // off the main actor. Curation uses this assessment to
                    // weigh noisy submissions without blocking corrections.
                    let localDecision = await Task.detached(priority: .userInitiated) {
                        classifier.classify(sender: nil, body: sanitizedText)
                    }.value
                    let assessment = LocalAssessment(
                        predictedLabelID: localDecision.labelID,
                        confidence: localDecision.confidence
                    )

                    let receipt = try await remoteSampleClient.submit(
                        sanitizedText: sanitizedText,
                        labelID: selectedLabel.id,
                        modelVersion: modelVersion,
                        assessment: assessment
                    )
                    if receipt.accepted, let receiptToken = receipt.receiptToken {
                        if transientReceiptGeneration == receiptGeneration {
                            lastReceiptToken = receiptToken
                        }
                        SubmissionLedger.increment(defaults: self.ledgerDefaults)
                        submittedSampleCount = SubmissionLedger.count(defaults: self.ledgerDefaults)
                        cacheRemoteSubmission(
                            recordName: receiptToken,
                            text: sanitizedText,
                            labelID: selectedLabel.id
                        )
                        if assessment.predictedLabelID != selectedLabel.id, assessment.confidence >= 0.8 {
                            let predictedTitle = SiftTaxonomy.leaf(id: assessment.predictedLabelID)?.title ?? assessment.predictedLabelID
                            showSubmissionFeedback(.info, String(localized: "已按你的选择提交。本地模型倾向于「\(predictedTitle)」，若确认无误请忽略。"))
                        } else {
                            showSubmissionFeedback(.success, String(localized: "已通过 iCloud 匿名共享脱敏样本，可用回执删除。"))
                        }
                        showToast(.success, String(localized: "匿名样本提交成功"))
                        submissionText = ""
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

        sampleSubmissionFeedback = nil
        Task {
            do {
                let deleted = try await remoteSampleClient.delete(receiptToken: receiptToken)
                if deleted {
                    lastReceiptToken = nil
                    SubmissionLedger.decrement(defaults: self.ledgerDefaults)
                    submittedSampleCount = SubmissionLedger.count(defaults: self.ledgerDefaults)
                    removeCachedSubmission(recordName: receiptToken)
                    showToast(.success, String(localized: "远程样本已删除"))
                } else {
                    lastReceiptToken = nil
                    SubmissionLedger.decrement(defaults: self.ledgerDefaults)
                    submittedSampleCount = SubmissionLedger.count(defaults: self.ledgerDefaults)
                    removeCachedSubmission(recordName: receiptToken)
                    showToast(.info, String(localized: "未找到可删除的远程样本"))
                }
            } catch {
                showToast(.error, remoteDeletionErrorMessage(for: error))
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

    /// 删除当前用户在云端的全部提交样本。
    public func eraseAllRemoteData() {
        guard !isErasingRemoteData else {
            return
        }
        guard canUseRemoteSubmission else {
            showRemoteAccountRequiredAlert()
            return
        }
        guard !isSubmittingSample else {
            showToast(.info, String(localized: "请等待当前提交完成"))
            return
        }

        let previousHistory = submissionHistory
        let previousHistoryFullyLoaded = historyFullyLoaded
        let previousHasLoadedHistory = hasLoadedSubmissionHistory
        let previousCount = submittedSampleCount
        let previousReceiptToken = lastReceiptToken
        let previousReceiptGeneration = transientReceiptGeneration

        isErasingRemoteData = true
        lastReceiptToken = nil
        SubmissionLedger.reset(defaults: ledgerDefaults)
        submittedSampleCount = 0
        submissionHistory = []
        historyFullyLoaded = true
        hasLoadedSubmissionHistory = true
        persistSubmissionHistoryCache()

        Task {
            defer { isErasingRemoteData = false }
            do {
                let deletedSamples = try await remoteSampleClient.eraseAllSubmissions()
                if deletedSamples == 0 {
                    showToast(.info, String(localized: "云端没有找到你提交的数据"))
                } else {
                    showToast(.success, String(localized: "已抹除 \(deletedSamples) 条提交样本"))
                }
            } catch {
                if transientReceiptGeneration == previousReceiptGeneration {
                    lastReceiptToken = previousReceiptToken
                }
                SubmissionLedger.set(previousCount, defaults: self.ledgerDefaults)
                submittedSampleCount = previousCount
                submissionHistory = previousHistory
                historyFullyLoaded = previousHistoryFullyLoaded
                hasLoadedSubmissionHistory = previousHasLoadedHistory
                persistSubmissionHistoryCache()
                showToast(.error, remoteDeletionErrorMessage(for: error))
            }
        }
    }

    /// 重置提交历史(下次进入列表重新从第一页加载)。
    public func resetSubmissionHistory() {
        submissionHistory = []
        submissionHistoryErrorMessage = nil
        historyFullyLoaded = false
        hasLoadedSubmissionHistory = false
        submissionHistoryCacheUpdatedAt = nil
        SubmissionHistoryCache.remove(defaults: ledgerDefaults)
    }

    /// Uses a fresh local snapshot immediately and only revalidates it after a
    /// short TTL. The refresh replaces page one so remote deletions do not
    /// remain in the cache indefinitely.
    public func refreshSubmissionHistoryIfNeeded(now: Date = .now) {
        guard hasLoadedSubmissionHistory else {
            loadMoreSubmissionHistory()
            return
        }
        guard
            submissionHistoryCacheUpdatedAt.map({
                now.timeIntervalSince($0) >= Self.historyCacheRefreshInterval
            }) ?? true
        else {
            return
        }
        Task {
            await refreshSubmissionHistory()
        }
    }

    public func refreshSubmissionHistory() async {
        guard !isLoadingHistory, !isErasingRemoteData else {
            return
        }
        guard canUseRemoteSubmission else {
            submissionHistoryErrorMessage = remoteAccountUnavailableMessage
            return
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await remoteSampleClient.fetchMySubmissions(
                before: nil,
                limit: Self.historyPageSize
            )
            submissionHistory = Array(page.prefix(Self.historyMaxItems))
            submissionHistoryErrorMessage = nil
            let reachedRemoteEnd = page.count < Self.historyPageSize
            historyFullyLoaded = reachedRemoteEnd
            hasLoadedSubmissionHistory = true
            reconcileSubmittedSampleCount(historyIsComplete: reachedRemoteEnd)
            persistSubmissionHistoryCache()
        } catch {
            submissionHistoryErrorMessage = remoteDeletionErrorMessage(for: error)
            showToast(.error, submissionHistoryErrorMessage ?? String(localized: "无法加载提交记录"))
        }
    }

    public func retrySubmissionHistory() {
        guard !isCheckingRemoteAccountStatus, !isLoadingHistory else {
            return
        }
        isCheckingRemoteAccountStatus = true
        remoteAccountStatus = .checking
        Task {
            let status = await remoteSampleClient.accountStatus()
            remoteAccountStatus = status
            isCheckingRemoteAccountStatus = false
            guard status == .available else {
                submissionHistoryErrorMessage = remoteAccountUnavailableMessage
                hasLoadedSubmissionHistory = true
                return
            }
            resetSubmissionHistory()
            await refreshSubmissionHistory()
        }
    }

    /// 下拉无限加载:按 createdAt 倒序取下一页,去重合并,封顶
    /// `historyMaxItems` 条。
    public func loadMoreSubmissionHistory() {
        guard !isLoadingHistory, !historyFullyLoaded, !isErasingRemoteData else {
            return
        }
        guard canUseRemoteSubmission else {
            submissionHistory = []
            submissionHistoryErrorMessage = remoteAccountUnavailableMessage
            historyFullyLoaded = true
            hasLoadedSubmissionHistory = true
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
                let reachedRemoteEnd = page.count < Self.historyPageSize
                if submissionHistory.count >= Self.historyMaxItems {
                    submissionHistory = Array(submissionHistory.prefix(Self.historyMaxItems))
                    historyFullyLoaded = true
                } else if reachedRemoteEnd {
                    historyFullyLoaded = true
                }
                hasLoadedSubmissionHistory = true
                reconcileSubmittedSampleCount(historyIsComplete: reachedRemoteEnd)
                persistSubmissionHistoryCache()
            } catch {
                let message = remoteDeletionErrorMessage(for: error)
                submissionHistoryErrorMessage = message
                if submissionHistory.isEmpty {
                    historyFullyLoaded = true
                }
                hasLoadedSubmissionHistory = true
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

        guard let index = submissionHistory.firstIndex(where: { $0.recordName == summary.recordName }) else {
            return
        }

        let wasLastReceipt = lastReceiptToken == summary.recordName
        let receiptGeneration = transientReceiptGeneration
        submissionHistory.remove(at: index)
        SubmissionLedger.decrement(defaults: ledgerDefaults)
        submittedSampleCount = SubmissionLedger.count(defaults: ledgerDefaults)
        if wasLastReceipt {
            lastReceiptToken = nil
        }
        persistSubmissionHistoryCache()

        Task {
            do {
                let deleted = try await remoteSampleClient.delete(receiptToken: summary.recordName)
                if deleted {
                    showToast(.success, String(localized: "已抹除该条提交"))
                } else {
                    showToast(.info, String(localized: "该条提交已不存在，列表已同步"))
                }
            } catch {
                if !submissionHistory.contains(where: { $0.recordName == summary.recordName }) {
                    submissionHistory.insert(summary, at: min(index, submissionHistory.endIndex))
                }
                SubmissionLedger.increment(defaults: self.ledgerDefaults)
                submittedSampleCount = SubmissionLedger.count(defaults: self.ledgerDefaults)
                if
                    wasLastReceipt,
                    lastReceiptToken == nil,
                    transientReceiptGeneration == receiptGeneration
                {
                    lastReceiptToken = summary.recordName
                }
                persistSubmissionHistoryCache()
                showToast(.error, remoteDeletionErrorMessage(for: error))
            }
        }
    }

    private func cacheRemoteSubmission(recordName: String, text: String, labelID: String) {
        let now = Date.now
        let summary = RemoteSubmissionSummary(
            recordName: recordName,
            text: text,
            label: labelID,
            submittedAt: now,
            createdAtMillis: Int64((now.timeIntervalSince1970 * 1_000).rounded())
        )
        submissionHistory.removeAll { $0.recordName == recordName }
        submissionHistory.insert(summary, at: 0)
        submissionHistory = Array(submissionHistory.prefix(Self.historyMaxItems))
        hasLoadedSubmissionHistory = true
        persistSubmissionHistoryCache()
    }

    private func removeCachedSubmission(recordName: String) {
        submissionHistory.removeAll { $0.recordName == recordName }
        if hasLoadedSubmissionHistory {
            persistSubmissionHistoryCache()
        }
    }

    private func persistSubmissionHistoryCache() {
        guard hasLoadedSubmissionHistory else {
            SubmissionHistoryCache.remove(defaults: ledgerDefaults)
            return
        }
        let updatedAt = Date.now
        submissionHistoryCacheUpdatedAt = updatedAt
        SubmissionHistoryCache.save(
            SubmissionHistoryCacheSnapshot(
                submissions: Array(submissionHistory.prefix(Self.historyMaxItems)),
                fullyLoaded: historyFullyLoaded,
                updatedAt: updatedAt
            ),
            defaults: ledgerDefaults
        )
    }

    private func reconcileSubmittedSampleCount(historyIsComplete: Bool) {
        let localCount = max(
            submittedSampleCount,
            SubmissionLedger.count(defaults: ledgerDefaults)
        )
        submittedSampleCount = historyIsComplete
            ? submissionHistory.count
            : max(localCount, submissionHistory.count)
        SubmissionLedger.set(submittedSampleCount, defaults: ledgerDefaults)
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
        toastCenter.show(kind, message)
    }

    public func showSubmissionFeedback(_ kind: SiftToast.Kind, _ message: String) {
        sampleSubmissionFeedback = SampleSubmissionFeedback(kind: kind, message: message)
    }

    public func clearTransientReceipt() {
        transientReceiptGeneration &+= 1
        lastReceiptToken = nil
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
                action: ruleDraftAction
            )
        case .body:
            rule = CustomRule(
                name: ruleName,
                text: TextMatcher(kind: ruleDraftPatternKind == .regex ? .regex : .substring, pattern: pattern),
                action: ruleDraftAction
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
        ruleDraftAction = .block
    }

    public func updateRule(
        id: UUID,
        name: String,
        location: RuleMatchLocation,
        patternKind: RulePatternKind,
        pattern: String,
        action: RuleAction
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
        rule.action = action
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
    private static let filterSetupConfirmationKey = "Sift.hasConfirmedFilterSetup"
    private static let transformerUpdateLastCheckKey = "Sift.transformerUpdateLastCheck.v1"
    private static let transformerUpdateCheckInterval: TimeInterval = 6 * 60 * 60

    private func persistRules() {
        SharedRuleStore.save(rules, defaults: ruleDefaults)
    }

    private static func loadPersistedRules(defaults: UserDefaults?) -> [CustomRule] {
        SharedRuleStore.load(defaults: defaults)
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
