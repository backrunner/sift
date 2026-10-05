import Foundation
import MessageFilterCore

#if canImport(IdentityLookup) && os(iOS)
import IdentityLookup
#endif

public struct MessageFilterExtensionRoute: Equatable, Sendable {
    public static let unclassified = MessageFilterExtensionRoute(action: .none, subAction: .none)
    public let action: SystemAction
    public let subAction: SystemSubAction

    public init(action: SystemAction, subAction: SystemSubAction) {
        self.action = action
        self.subAction = subAction
    }
}

public enum MessageFilterActionMapper {
    public static let supportedTransactionalSubActions = MessageFilterCapabilities.transactionalSubActions
    public static let supportedPromotionalSubActions = MessageFilterCapabilities.promotionalSubActions

    public static func systemAction(for decision: ClassificationDecision) -> SystemAction {
        MessageFilterRouting.systemAction(for: decision)
    }

    public static func systemSubAction(for decision: ClassificationDecision) -> SystemSubAction {
        MessageFilterRouting.systemSubAction(for: decision)
    }

    public static func extensionRoute(for result: MessageFilterResult) -> MessageFilterExtensionRoute {
        guard MessageFilterRouting.systemAction(for: result.decision) != .none else {
            return .unclassified
        }
        return MessageFilterExtensionRoute(
            action: result.systemAction,
            subAction: MessageFilterCapabilities.subAction(for: result.systemAction, requested: result.systemSubAction)
        )
    }

    #if canImport(IdentityLookup) && os(iOS)
    /// The only production response builder: always revalidate the final pair.
    public static func filterResponse(for route: MessageFilterExtensionRoute) -> ILMessageFilterQueryResponse {
        let response = ILMessageFilterQueryResponse()
        response.action = filterAction(for: route.action)
        response.subAction = filterSubAction(for: MessageFilterCapabilities.subAction(
            for: route.action, requested: route.subAction
        ))
        return response
    }

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
