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

/// Backend seam so unit tests never touch StoreKit.
public protocol PremiumPurchasing: Sendable {
    func loadProduct(identifier: String) async throws -> PremiumProductInfo?
    func purchase(identifier: String) async -> PremiumPurchaseOutcome
    func isEntitled(identifier: String) async -> Bool
    /// Restores purchases (StoreKit `AppStore.sync`) and re-checks entitlement.
    func restore(identifier: String) async throws -> Bool
    /// Long-lived stream of entitlement changes (purchases, refunds).
    func entitlementUpdates(identifier: String) -> AsyncStream<Bool>
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

    public private(set) var productState: PremiumProductState = .loading
    public private(set) var isUnlocked: Bool = false
    public private(set) var isPurchasing: Bool = false
    public private(set) var isRestoring: Bool = false

    /// Optional marketing line (e.g. "限时 5 折") set per release via the
    /// `SiftPremiumPromoText` Info.plist key; live price always comes from
    /// the App Store so price drops and free campaigns show automatically.
    public let promoText: String?

    public let productIdentifier: String

    /// Fired on entitlement transitions (purchase / restore / refund) so the
    /// app model can react (e.g. revert the Transformer selection on refund).
    @ObservationIgnored
    public var onEntitlementChange: ((Bool) -> Void)?

    @ObservationIgnored
    private let backend: any PremiumPurchasing

    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?

    public init(
        backend: (any PremiumPurchasing)? = nil,
        productIdentifier: String? = nil,
        bundle: Bundle = .main
    ) {
        self.productIdentifier = productIdentifier
            ?? (bundle.object(forInfoDictionaryKey: "SiftPremiumProductIdentifier") as? String)
            ?? Self.defaultProductIdentifier
        let promo = bundle.object(forInfoDictionaryKey: "SiftPremiumPromoText") as? String
        self.promoText = (promo?.isEmpty == false) ? promo : nil
        #if canImport(StoreKit)
        self.backend = backend ?? StoreKitPremiumBackend()
        #else
        self.backend = backend ?? UnavailablePremiumBackend()
        #endif

        refresh()
        observeEntitlementUpdates()
    }

    deinit {
        updatesTask?.cancel()
    }

    public func refresh() {
        let backend = backend
        let identifier = productIdentifier
        productState = .loading
        Task {
            setUnlocked(await backend.isEntitled(identifier: identifier))
            do {
                if let product = try await backend.loadProduct(identifier: identifier) {
                    productState = .available(product)
                } else {
                    productState = .unavailable(String(localized: "暂时无法获取商品信息，请稍后重试"))
                }
            } catch {
                productState = .unavailable(Self.storefrontErrorMessage(for: error))
            }
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
            setUnlocked(true)
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
            let restored = try await backend.restore(identifier: productIdentifier)
            setUnlocked(restored)
            return restored
                ? (.success, String(localized: "已恢复高级版购买"))
                : (.info, String(localized: "此 Apple 账户下没有可恢复的购买"))
        } catch {
            return (.error, String(localized: "恢复购买失败：\(Self.storefrontErrorMessage(for: error))"))
        }
    }

    private func observeEntitlementUpdates() {
        let backend = backend
        let identifier = productIdentifier
        updatesTask = Task { [weak self] in
            for await entitled in backend.entitlementUpdates(identifier: identifier) {
                guard let self else { return }
                self.setUnlocked(entitled)
            }
        }
    }

    private func setUnlocked(_ unlocked: Bool) {
        let changed = unlocked != isUnlocked
        isUnlocked = unlocked
        if changed {
            onEntitlementChange?(unlocked)
        }
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

    func isEntitled(identifier: String) async -> Bool {
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == identifier,
               transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func restore(identifier: String) async throws -> Bool {
        try await AppStore.sync()
        return await isEntitled(identifier: identifier)
    }

    func entitlementUpdates(identifier: String) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update, transaction.productID == identifier {
                        await transaction.finish()
                        continuation.yield(transaction.revocationDate == nil)
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

/// Placeholder backend for platforms without StoreKit.
struct UnavailablePremiumBackend: PremiumPurchasing {
    func loadProduct(identifier: String) async throws -> PremiumProductInfo? { nil }
    func purchase(identifier: String) async -> PremiumPurchaseOutcome { .failed(String(localized: "此平台不支持内购")) }
    func isEntitled(identifier: String) async -> Bool { false }
    func restore(identifier: String) async throws -> Bool { false }
    func entitlementUpdates(identifier: String) -> AsyncStream<Bool> {
        AsyncStream { $0.finish() }
    }
}
