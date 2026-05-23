import Foundation
import MessageFilterCore

#if canImport(IdentityLookup) && os(iOS)
import IdentityLookup
#endif

public enum MessageFilterActionMapper {
    public static func systemAction(for decision: ClassificationDecision) -> SystemAction {
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
    #endif
}
