import Foundation
import MessageFilterCore
import Observation

public enum SubmissionDestination: String, CaseIterable, Identifiable, Sendable {
    case local
    case remote

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local:
            return "仅本地微调"
        case .remote:
            return "匿名提交"
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
            return "发送方"
        case .body:
            return "短信正文"
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
            return "子串"
        case .regex:
            return "正则"
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

    @ObservationIgnored
    private let sanitizer = PrivacySanitizer()

    @ObservationIgnored
    private let baseClassifier: any MessageClassifier

    @ObservationIgnored
    private var pipeline: ClassificationPipeline

    @ObservationIgnored
    private let sampleStore: LocalSampleStore

    @ObservationIgnored
    private let remoteSamplesEndpoint: URL?

    @ObservationIgnored
    private let personalizationTrainer = PersonalizationTrainer()

    public init() {
        self.sampleStore = LocalSampleStore(fileURL: LocalSampleStore.defaultFileURL())
        self.remoteSamplesEndpoint = Self.configuredRemoteSamplesEndpoint()
        if let manifest = BundledModelManifest.load() {
            self.modelDate = Self.displayDate(for: manifest.trainedAt)
            self.modelVersion = manifest.version
        }
        let classifier = AppleClassifierLoader.defaultClassifier()
        self.baseClassifier = classifier
        self.pipeline = ClassificationPipeline(classifier: classifier)
        self.rules = Self.loadPersistedRules()
        refreshSanitizedPreview()
        classifyCurrentDraft()
        Task { await refreshLocalSampleCount() }
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

    public var canSubmitSample: Bool {
        let text = submissionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return false
        }
        if submissionDestination == .remote && !hasAcceptedRemoteSamplePrivacy {
            return false
        }
        return true
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
        return "正则表达式格式不正确"
    }

    public func classifyCurrentDraft() {
        let body = testBody.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else {
            lastDecision = nil
            return
        }

        lastDecision = pipeline.classifier.classify(sender: nil, body: body)
    }

    public func submitSample() {
        guard !isSubmittingSample else { return }
        sampleSubmissionFeedback = nil
        refreshSanitizedPreview()
        let selectedLabel = selectedLabel
        let text = submissionText
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            showSubmissionFeedback(.error, "请输入样本文本")
            return
        }
        let sanitizedText = sanitizedPreview
        switch submissionDestination {
        case .local:
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
                        showToast(.success, "本地个性化层已更新")
                    case .ready:
                        showToast(.success, "样本已加入本地队列")
                    case .unsupported:
                        showToast(.info, "样本已保存，当前系统暂不支持本地训练")
                    case .failed:
                        showToast(.info, "样本已保存，本地训练稍后重试")
                    case .missingModel:
                        showToast(.info, "样本已保存，等待基座模型")
                    }
                    sampleSubmissionFeedback = SampleSubmissionFeedback(kind: .success, message: "样本已保存到本地，仅用于设备上的个性化微调。")
                    submissionText = ""
                    refreshSanitizedPreview()
                } catch {
                    showSubmissionFeedback(.error, "本地保存失败：\(error.localizedDescription)")
                }
            }
        case .remote:
            guard hasAcceptedRemoteSamplePrivacy else {
                showSubmissionFeedback(.error, "请先阅读并同意匿名提交隐私说明")
                return
            }
            guard let endpoint = remoteSamplesEndpoint else {
                showSubmissionFeedback(.error, "匿名提交服务暂未配置")
                return
            }

            isSubmittingSample = true
            Task {
                defer { isSubmittingSample = false }
                do {
                    let receipt = try await RemoteSampleClient(samplesEndpoint: endpoint).submit(
                        sanitizedText: sanitizedText,
                        labelID: selectedLabel.id,
                        modelVersion: modelVersion
                    )
                    if receipt.accepted, let receiptToken = receipt.receiptToken {
                        lastReceiptToken = receiptToken
                        showSubmissionFeedback(.success, "已匿名提交脱敏样本，可用回执删除。")
                        submissionText = ""
                        refreshSanitizedPreview()
                    } else if receipt.accepted {
                        showSubmissionFeedback(.error, "匿名提交服务未返回删除回执，样本未确认为可撤回")
                    } else {
                        showSubmissionFeedback(.error, "远程未接收样本")
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
        guard let endpoint = remoteSamplesEndpoint else {
            showToast(.error, "匿名提交服务暂未配置")
            return
        }

        Task {
            do {
                let deleted = try await RemoteSampleClient(samplesEndpoint: endpoint).delete(receiptToken: receiptToken)
                if deleted {
                    lastReceiptToken = nil
                    showSubmissionFeedback(.success, "远程样本已删除")
                } else {
                    showSubmissionFeedback(.info, "未找到可删除的远程样本")
                }
            } catch let error as URLError where error.code == .timedOut {
                showSubmissionFeedback(.error, "删除超时，请稍后重试")
            } catch {
                showSubmissionFeedback(.error, "删除失败：\(error.localizedDescription)")
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
            showToast(.error, "请输入匹配内容")
            return false
        }
        guard canAddCustomRule else {
            showToast(.error, "正则表达式格式不正确")
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
        showToast(.success, "已添加规则")
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
            showToast(.error, "请输入匹配内容")
            return false
        }
        if patternKind == .regex, !isValidRegex(trimmedPattern) {
            showToast(.error, "正则表达式格式不正确")
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
        showToast(.success, "规则已更新")
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
        showToast(.success, "规则已删除")
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
        statusMessage = "已删除 \(ids.count) 条规则"
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
        statusMessage = "规则顺序已更新"
        if canClassifyCurrentDraft {
            classifyCurrentDraft()
        } else {
            clearCurrentDecision()
        }
    }

    private static let rulesPersistenceKey = "Sift.customRules"
    private static let remoteSamplePrivacyConsentKey = "Sift.hasAcceptedRemoteSamplePrivacy"
    private static let lastRemoteSampleReceiptTokenKey = "Sift.lastRemoteSampleReceiptToken"

    private func persistRules() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: Self.rulesPersistenceKey)
        } catch {
            // 静默失败：持久化是 best-effort，错误不应中断业务流。
        }
    }

    private static func loadPersistedRules() -> [CustomRule] {
        guard let data = UserDefaults.standard.data(forKey: rulesPersistenceKey) else {
            return []
        }
        return (try? JSONDecoder().decode([CustomRule].self, from: data)) ?? []
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

    private static func configuredRemoteSamplesEndpoint() -> URL? {
        let keys = ["SiftSamplesEndpoint", "SIFT_SAMPLES_ENDPOINT"]
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
        return nil
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
        return URL(string: "https://sift.alkinum.io/tos")!
    }

    private func remoteSubmissionErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "提交超时，请稍后重试"
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络不可用，样本未提交"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "无法连接匿名提交服务，样本未提交"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "匿名提交服务证书校验失败，样本未提交"
            default:
                return "提交失败：\(urlError.localizedDescription)"
            }
        }

        if let clientError = error as? RemoteSampleClientError {
            switch clientError {
            case .invalidResponse:
                return "匿名提交服务返回异常，样本未提交"
            case .httpStatus(let status):
                return "匿名提交服务返回 \(status)，样本未提交"
            }
        }

        return "提交失败：\(error.localizedDescription)"
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
        return "规则 \(maxIndex + 1)"
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
