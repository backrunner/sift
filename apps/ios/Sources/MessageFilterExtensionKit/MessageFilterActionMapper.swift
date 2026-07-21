import Foundation
import MessageFilterCore

#if canImport(IdentityLookup) && os(iOS)
import IdentityLookup
#endif

public enum MessageFilterActionMapper {
    public static let supportedTransactionalSubActions: [SystemSubAction] = [
        .transactionalFinance,
        .transactionalOrders,
        .transactionalReminders,
        .transactionalHealth,
        .transactionalWeather,
        .transactionalCarrier,
        .transactionalRewards,
        .transactionalPublicServices,
        .transactionalOthers
    ]

    public static let supportedPromotionalSubActions: [SystemSubAction] = [
        .promotionalOffers,
        .promotionalOthers
    ]

    public static func systemAction(for decision: ClassificationDecision) -> SystemAction {
        MessageFilterRouting.systemAction(for: decision)
    }

    public static func systemSubAction(for decision: ClassificationDecision) -> SystemSubAction {
        MessageFilterRouting.systemSubAction(for: decision)
    }

    #if canImport(IdentityLookup) && os(iOS)
    public static func filterAction(for decision: ClassificationDecision) -> ILMessageFilterAction {
        switch systemAction(for: decision) {
        case .promotion:
            return .promotion
        case .junk:
            return .junk
        case .transaction:
            return .transaction
        case .none:
            return .none
        }
    }

    public static func filterAction(for action: SystemAction) -> ILMessageFilterAction {
        switch action {
        case .promotion: return .promotion
        case .junk: return .junk
        case .transaction: return .transaction
        case .none: return .none
        }
    }

    public static func filterSubAction(for decision: ClassificationDecision) -> ILMessageFilterSubAction {
        systemSubAction(for: decision).identityLookupSubAction
    }

    public static func filterSubAction(for subAction: SystemSubAction) -> ILMessageFilterSubAction {
        subAction.identityLookupSubAction
    }

    public static var filterTransactionalSubActions: [ILMessageFilterSubAction] {
        supportedTransactionalSubActions.map(\.identityLookupSubAction)
    }

    public static var filterPromotionalSubActions: [ILMessageFilterSubAction] {
        supportedPromotionalSubActions.map(\.identityLookupSubAction)
    }
    #endif
}

#if canImport(IdentityLookup) && os(iOS)
private extension SystemSubAction {
    var identityLookupSubAction: ILMessageFilterSubAction {
        switch self {
        case .none:
            return .none
        case .transactionalOthers:
            return .transactionalOthers
        case .transactionalFinance:
            return .transactionalFinance
        case .transactionalOrders:
            return .transactionalOrders
        case .transactionalReminders:
            return .transactionalReminders
        case .transactionalHealth:
            return .transactionalHealth
        case .transactionalWeather:
            return .transactionalWeather
        case .transactionalCarrier:
            return .transactionalCarrier
        case .transactionalRewards:
            return .transactionalRewards
        case .transactionalPublicServices:
            return .transactionalPublicServices
        case .promotionalOthers:
            return .promotionalOthers
        case .promotionalOffers:
            return .promotionalOffers
        case .promotionalCoupons:
            return .promotionalCoupons
        }
    }
}
#endif
