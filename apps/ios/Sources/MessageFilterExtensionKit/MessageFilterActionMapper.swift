import Foundation
import MessageFilterCore

#if canImport(IdentityLookup) && os(iOS)
import IdentityLookup
#endif

public enum SystemSubAction: String, Codable, Hashable, Sendable {
    case none
    case transactionalOthers
    case transactionalFinance
    case transactionalOrders
    case transactionalReminders
    case transactionalHealth
    case transactionalWeather
    case transactionalCarrier
    case transactionalRewards
    case transactionalPublicServices
    case promotionalOthers
    case promotionalOffers
    case promotionalCoupons
}

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
        if decision.labelID == "carrier.promotion" {
            return .promotion
        }

        switch decision.systemAction {
        case .promotion:
            return .promotion
        case .junk:
            return .junk
        case .transaction:
            return decision.confidence >= 0.65 ? .transaction : .none
        case .none:
            return .none
        }
    }

    public static func systemSubAction(for decision: ClassificationDecision) -> SystemSubAction {
        switch systemAction(for: decision) {
        case .promotion:
            return promotionalSubAction(for: decision)
        case .transaction:
            return transactionalSubAction(for: decision)
        case .junk, .none:
            return .none
        }
    }

    private static func promotionalSubAction(for decision: ClassificationDecision) -> SystemSubAction {
        switch decision.labelID {
        case "carrier.promotion", "promotion":
            return .promotionalOffers
        default:
            return .promotionalOthers
        }
    }

    private static func transactionalSubAction(for decision: ClassificationDecision) -> SystemSubAction {
        switch decision.labelID {
        case let labelID where labelID.hasPrefix("finance."):
            return .transactionalFinance
        case "transaction.order",
             "life.takeaway",
             "life.express",
             "life.logistics",
             "life.pickup_code",
             "travel.ticketing":
            return .transactionalOrders
        case "work.meeting",
             "work.reminder",
             "work.training",
             "travel.transport":
            return .transactionalReminders
        case "life.medical":
            return .transactionalHealth
        case "life.weather":
            return .transactionalWeather
        case let labelID where labelID.hasPrefix("carrier."):
            return .transactionalCarrier
        case "transaction.points",
             "transaction.member":
            return .transactionalRewards
        case let labelID where labelID.hasPrefix("government."):
            return .transactionalPublicServices
        default:
            return .transactionalOthers
        }
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

    public static func filterSubAction(for decision: ClassificationDecision) -> ILMessageFilterSubAction {
        systemSubAction(for: decision).identityLookupSubAction
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
