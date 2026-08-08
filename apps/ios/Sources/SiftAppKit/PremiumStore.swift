import Foundation
import Observation

#if canImport(StoreKit)
import StoreKit
#endif

/// The single paid product: 高级版 (Premium), a non-consumable that
/// permanently unlocks the Transformer model variant.
public struct PremiumProductInfo: Hashable, Sendable {
    public let identifier: String
    public let displayName: String
    public let displayPrice: String
    /// Decimal price in the storefront currency; 0 means limited-time free.
    public let price: Decimal

    public var isFree: Bool {
        price == 0
    }

    public init(identifier: String, displayName: String, displayPrice: String, price: Decimal) {
        self.identifier = identifier
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.price = price
    }
}

public enum PremiumPurchaseOutcome: Sendable {
    case purchased
    case cancelled
    /// Deferred approval (Ask to Buy / parental controls).
    case pending
    case failed(String)
}

public enum PremiumEntitlementStatus: Equatable, Sendable {
    case entitled
    case notPurchased
    case revoked
    case unverified
}

/// Backend seam so unit tests never touch StoreKit.
public protocol PremiumPurchasing: Sendable {
    func loadProduct(identifier: String) async throws -> PremiumProductInfo?
    func purchase(identifier: String) async -> PremiumPurchaseOutcome
    func entitlementStatus(identifier: String) async -> PremiumEntitlementStatus
    /// Restores purchases (StoreKit `AppStore.sync`) and re-checks entitlement.
    func restore(identifier: String) async throws -> PremiumEntitlementStatus
    /// Long-lived stream of entitlement changes (purchases, refunds).
    func entitlementUpdates(identifier: String) -> AsyncStream<PremiumEntitlementStatus>
}

public enum PremiumProductState: Sendable {
    case loading
    case available(PremiumProductInfo)
    case unavailable(String)
}

/// Observable premium state for the app: live price, entitlement, purchase
/// and restore flows with full edge-case feedback.
@MainActor
@Observable
public final class PremiumStore {
    public static let defaultProductIdentifier = "com.alkinum.sift.premium"
    static let entitlementValidationInterval: TimeInterval = 24 * 60 * 60
    static let cachedEntitlementKey = "Sift.premiumEntitlement.v1"
    static let entitlementLastValidatedAtKey = "Sift.premiumEntitlementLastValidatedAt.v1"

    public private(set) var productState: PremiumProductState = .loading
    public private(set) var isUnlocked: Bool = false
    public private(set) var isEntitlementResolved: Bool = false
    public private(set) var isValidatingEntitlement: Bool = false
    public private(set) var isPurchasing: Bool = false
    public private(set) var isRestoring: Bool = false

    /// Optional marketing line (e.g. "限时 5 折") set per release via the
    /// `SiftPremiumPromoText` Info.plist key; live price always comes from
    /// the App Store so price drops and free campaigns show automatically.
    public let promoText: String?

    public let productIdentifier: String

    /// Fired only for authoritative StoreKit results (purchase / restore /
    /// verified entitlement lookup / refund). Cached state and unverified
    /// transactions never trigger a model-selection change.
    @ObservationIgnored
    public var onEntitlementChange: ((Bool) -> Void)? {
        didSet {
            if hasAuthoritativeEntitlementResultThisSession {
                onEntitlementChange?(isUnlocked)
            }
        }
    }

    @ObservationIgnored
    private let backend: any PremiumPurchasing

    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?

    @ObservationIgnored
    private var productRefreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var entitlementValidationTask: Task<Void, Never>?

    @ObservationIgnored
    private var entitlementValidationRequestID: UUID?

    @ObservationIgnored
    private let entitlementDefaults: UserDefaults?

    @ObservationIgnored
    private var lastEntitlementValidationDate: Date?

    @ObservationIgnored
    private var hasAuthoritativeEntitlementResultThisSession = false

    public init(
        backend: (any PremiumPurchasing)? = nil,
        productIdentifier: String? = nil,
        bundle: Bundle = .main,
        defaults: UserDefaults? = nil,
        assumeUnlocked: Bool = false
    ) {
        self.productIdentifier = productIdentifier
            ?? (bundle.object(forInfoDictionaryKey: "SiftPremiumProductIdentifier") as? String)
            ?? Self.defaultProductIdentifier
        let promo = bundle.object(forInfoDictionaryKey: "SiftPremiumPromoText") as? String
        self.promoText = (promo?.isEmpty == false) ? promo : nil
        self.backend = Self.resolveBackend(backend)
        self.entitlementDefaults = defaults
        self.lastEntitlementValidationDate = defaults?.object(
            forKey: Self.entitlementLastValidatedAtKey
        ) as? Date

        let hasCachedEntitlement = defaults?.object(forKey: Self.cachedEntitlementKey) != nil
        let cachedUnlock = defaults?.bool(forKey: Self.cachedEntitlementKey) == true
        let shouldMigrateUnlock = assumeUnlocked && !hasCachedEntitlement
        let initialUnlock = cachedUnlock || assumeUnlocked
        self.isUnlocked = initialUnlock
        self.isEntitlementResolved = initialUnlock || hasCachedEntitlement
        if shouldMigrateUnlock {
            defaults?.set(true, forKey: Self.cachedEntitlementKey)
        }

        // A persisted Signal selection wins for the first frame. If it
        // conflicts with a cached negative, require a fresh StoreKit result
        // this launch before changing the shared model selection.
        let requiresFreshValidation = assumeUnlocked && hasCachedEntitlement && !cachedUnlock
        refresh(forceEntitlementValidation: requiresFreshValidation)
        observeEntitlementUpdates()
    }

    deinit {
        updatesTask?.cancel()
        productRefreshTask?.cancel()
        entitlementValidationTask?.cancel()
    }

    public func refresh(forceEntitlementValidation: Bool = false) {
        refreshEntitlementIfNeeded(force: forceEntitlementValidation)
        refreshProduct()
    }

    public func refreshEntitlementIfNeeded(force: Bool = false) {
        guard entitlementValidationTask == nil else {
            return
        }
        let now = Date()
        if
            !force,
            let lastEntitlementValidationDate,
            now.timeIntervalSince(lastEntitlementValidationDate) < Self.entitlementValidationInterval
        {
            return
        }

        let backend = backend
        let identifier = productIdentifier
        let requestID = UUID()
        entitlementValidationRequestID = requestID
        isValidatingEntitlement = true
        entitlementValidationTask = Task { [weak self] in
            let status = await backend.entitlementStatus(identifier: identifier)
            guard
                let self,
                !Task.isCancelled,
                self.entitlementValidationRequestID == requestID
            else {
                return
            }
            self.entitlementValidationTask = nil
            self.entitlementValidationRequestID = nil
            self.isValidatingEntitlement = false
            self.recordEntitlementValidation(at: Date())

            switch status {
            case .entitled:
                self.persistAndPublishUnlocked(true, authoritative: true)
            case .notPurchased, .revoked:
                self.persistAndPublishUnlocked(false, authoritative: true)
            case .unverified:
                break
            }
        }
    }

    private func refreshProduct() {
        guard productRefreshTask == nil else {
            return
        }
        let backend = backend
        let identifier = productIdentifier
        productState = .loading
        productRefreshTask = Task { [weak self] in
            let state: PremiumProductState
            do {
                if let product = try await backend.loadProduct(identifier: identifier) {
                    state = .available(product)
                } else {
                    state = .unavailable(Self.priceUnavailableMessage)
                }
            } catch {
                state = .unavailable(Self.priceUnavailableMessage)
            }
            guard let self, !Task.isCancelled else { return }
            self.productRefreshTask = nil
            self.productState = state
        }
    }

    /// Buys premium. Returns user-facing feedback for every edge case; nil
    /// means the user cancelled and no feedback should be shown.
    public func purchase() async -> (kind: SiftToast.Kind, message: String)? {
        guard !isPurchasing else {
            return nil
        }
        isPurchasing = true
        defer { isPurchasing = false }

        switch await backend.purchase(identifier: productIdentifier) {
        case .purchased:
            applyAuthoritativeEntitlement(.entitled)
            return (.success, String(localized: "高级版已解锁，感谢支持！"))
        case .cancelled:
            return nil
        case .pending:
            return (.info, String(localized: "购买等待批准中（家长/管理者审批通过后自动解锁）"))
        case .failed(let message):
            return (.error, String(localized: "购买失败：\(message)"))
        }
    }

    public func restorePurchases() async -> (kind: SiftToast.Kind, message: String) {
        guard !isRestoring else {
            return (.info, String(localized: "正在恢复购买…"))
        }
        isRestoring = true
        defer { isRestoring = false }

        do {
            let status = try await backend.restore(identifier: productIdentifier)
            switch status {
            case .entitled:
                applyAuthoritativeEntitlement(.entitled)
                return (.success, String(localized: "已恢复高级版购买"))
            case .notPurchased, .revoked:
                applyAuthoritativeEntitlement(status)
                return (.info, String(localized: "此 Apple 账户下没有可恢复的购买"))
            case .unverified:
                return (.error, String(localized: "购买凭证暂时无法验证，请稍后再试"))
            }
        } catch {
            return (.error, String(localized: "恢复购买失败：\(Self.storefrontErrorMessage(for: error))"))
        }
    }

    private func observeEntitlementUpdates() {
        let backend = backend
        let identifier = productIdentifier
        updatesTask = Task { [weak self] in
            for await status in backend.entitlementUpdates(identifier: identifier) {
                guard let self else { return }
                self.applyAuthoritativeEntitlement(status)
            }
        }
    }

    private func applyAuthoritativeEntitlement(_ status: PremiumEntitlementStatus) {
        guard status != .unverified else {
            return
        }
        entitlementValidationTask?.cancel()
        entitlementValidationTask = nil
        entitlementValidationRequestID = nil
        isValidatingEntitlement = false
        recordEntitlementValidation(at: Date())
        switch status {
        case .entitled:
            persistAndPublishUnlocked(true, authoritative: true)
        case .notPurchased, .revoked:
            persistAndPublishUnlocked(false, authoritative: true)
        case .unverified:
            break
        }
    }

    private func persistAndPublishUnlocked(_ unlocked: Bool, authoritative: Bool) {
        entitlementDefaults?.set(unlocked, forKey: Self.cachedEntitlementKey)
        publishUnlocked(unlocked, authoritative: authoritative)
    }

    private func publishUnlocked(_ unlocked: Bool, authoritative: Bool) {
        let shouldNotify = authoritative || unlocked != isUnlocked || !isEntitlementResolved
        if authoritative {
            hasAuthoritativeEntitlementResultThisSession = true
        }
        isUnlocked = unlocked
        isEntitlementResolved = true
        if shouldNotify {
            onEntitlementChange?(unlocked)
        }
    }

    private func recordEntitlementValidation(at date: Date) {
        lastEntitlementValidationDate = date
        entitlementDefaults?.set(date, forKey: Self.entitlementLastValidatedAtKey)
    }

    private static func resolveBackend(
        _ backend: (any PremiumPurchasing)?
    ) -> any PremiumPurchasing {
        if let backend {
            return backend
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SIFT_DEBUG_PREMIUM_UNLOCKED"] == "1" {
            return DebugUnlockedPremiumBackend()
        }
        #endif
        #if canImport(StoreKit)
        return StoreKitPremiumBackend()
        #else
        return UnavailablePremiumBackend()
        #endif
    }

    private static var priceUnavailableMessage: String {
        String(localized: "价格信息不可用，请稍后再试")
    }

    private static func storefrontErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return String(localized: "网络不可用，请检查网络后重试")
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

#if canImport(StoreKit)
/// StoreKit 2 backend.
struct StoreKitPremiumBackend: PremiumPurchasing {
    func loadProduct(identifier: String) async throws -> PremiumProductInfo? {
        guard let product = try await Product.products(for: [identifier]).first else {
            return nil
        }
        return PremiumProductInfo(
            identifier: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            price: product.price
        )
    }

    func purchase(identifier: String) async -> PremiumPurchaseOutcome {
        do {
            guard let product = try await Product.products(for: [identifier]).first else {
                return .failed(String(localized: "商品暂不可用"))
            }
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    return .purchased
                case .unverified:
                    return .failed(String(localized: "购买凭证校验失败，请通过恢复购买重试"))
                }
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(String(localized: "未知的购买结果"))
            }
        } catch StoreKitError.notAvailableInStorefront {
            return .failed(String(localized: "当前商店区域暂不提供此商品"))
        } catch StoreKitError.networkError {
            return .failed(String(localized: "网络不可用，请检查网络后重试"))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func entitlementStatus(identifier: String) async -> PremiumEntitlementStatus {
        guard let result = await Transaction.latest(for: identifier) else {
            // `nil` is StoreKit's explicit "no transaction for this product"
            // result. Verification failures remain a separate fail-open state.
            return .notPurchased
        }
        switch result {
        case .verified(let transaction):
            return transaction.revocationDate == nil ? .entitled : .revoked
        case .unverified:
            return .unverified
        }
    }

    func restore(identifier: String) async throws -> PremiumEntitlementStatus {
        try await AppStore.sync()
        return await entitlementStatus(identifier: identifier)
    }

    func entitlementUpdates(identifier: String) -> AsyncStream<PremiumEntitlementStatus> {
        AsyncStream { continuation in
            let task = Task {
                for await update in Transaction.updates {
                    switch update {
                    case .verified(let transaction) where transaction.productID == identifier:
                        await transaction.finish()
                        continuation.yield(transaction.revocationDate == nil ? .entitled : .revoked)
                    case .unverified(let transaction, _) where transaction.productID == identifier:
                        continuation.yield(.unverified)
                    case .verified, .unverified:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
#endif

#if DEBUG
private struct DebugUnlockedPremiumBackend: PremiumPurchasing {
    func loadProduct(identifier: String) async throws -> PremiumProductInfo? {
        PremiumProductInfo(
            identifier: identifier,
            displayName: String(localized: "已解锁"),
            displayPrice: String(localized: "限时免费"),
            price: 0
        )
    }

    func purchase(identifier: String) async -> PremiumPurchaseOutcome { .purchased }
    func entitlementStatus(identifier: String) async -> PremiumEntitlementStatus { .entitled }
    func restore(identifier: String) async throws -> PremiumEntitlementStatus { .entitled }
    func entitlementUpdates(identifier: String) -> AsyncStream<PremiumEntitlementStatus> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
#endif

/// Placeholder backend for platforms without StoreKit.
struct UnavailablePremiumBackend: PremiumPurchasing {
    func loadProduct(identifier: String) async throws -> PremiumProductInfo? { nil }
    func purchase(identifier: String) async -> PremiumPurchaseOutcome { .failed(String(localized: "此平台不支持内购")) }
    func entitlementStatus(identifier: String) async -> PremiumEntitlementStatus { .unverified }
    func restore(identifier: String) async throws -> PremiumEntitlementStatus { .unverified }
    func entitlementUpdates(identifier: String) -> AsyncStream<PremiumEntitlementStatus> {
        AsyncStream { $0.finish() }
    }
}
