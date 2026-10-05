import IdentityLookup
import MessageFilterCore
import MessageFilterExtensionKit
import XCTest

/// Verifies the production response bridge using Apple's actual iOS types.
/// These tests do not simulate SMS delivery or IdentityLookup process limits.
final class IdentityLookupRoutingTests: XCTestCase {
    func testCapabilitiesUseFiveValidSDKSubcategories() {
        let response = ILMessageFilterCapabilitiesQueryResponse()
        response.transactionalSubActions = MessageFilterActionMapper.filterTransactionalSubActions
        response.promotionalSubActions = MessageFilterActionMapper.filterPromotionalSubActions
        XCTAssertEqual(response.transactionalSubActions, [.transactionalFinance, .transactionalOrders, .transactionalReminders])
        XCTAssertEqual(response.promotionalSubActions, [.promotionalOffers, .promotionalCoupons])
        XCTAssertLessThanOrEqual(response.transactionalSubActions.count + response.promotionalSubActions.count, 5)
    }

    func testEveryTaxonomyAndMappingProducesADeclaredSDKDestination() {
        for leaf in SiftTaxonomy.leaves {
            let original = ClassificationDecision(
                labelID: leaf.id, labelTitle: leaf.title, groupID: leaf.groupId,
                groupTitle: leaf.groupTitle, confidence: 0.99, systemAction: leaf.systemAction, source: .model
            )
            for target in [nil] + CategoryMappingTarget.allCases.map(Optional.some) {
                let decision = original.applying(categoryMappings: target.map { [leaf.id: $0] } ?? [:])
                let result = MessageFilterResult(
                    decision: decision, systemAction: MessageFilterRouting.systemAction(for: decision),
                    systemSubAction: MessageFilterRouting.systemSubAction(for: decision),
                    modelArtifactIdentity: .classic, fallbackReason: .none, executionPath: .classic
                )
                let route = MessageFilterActionMapper.extensionRoute(for: result)
                let response = MessageFilterActionMapper.filterResponse(for: route)
                XCTAssertEqual(response.action, MessageFilterActionMapper.filterAction(for: target?.systemAction ?? leaf.systemAction))
                switch response.action {
                case .transaction:
                    XCTAssertTrue(response.subAction == .none || MessageFilterActionMapper.filterTransactionalSubActions.contains(response.subAction))
                case .promotion:
                    XCTAssertTrue(response.subAction == .none || MessageFilterActionMapper.filterPromotionalSubActions.contains(response.subAction))
                case .none, .allow, .junk:
                    XCTAssertEqual(response.subAction, .none)
                @unknown default:
                    XCTFail("Unexpected SDK action")
                }
            }
        }
    }

    func testUnclassifiedAndInvalidPairsUseSafeSDKResponses() {
        let unclassified = MessageFilterActionMapper.filterResponse(for: .unclassified)
        XCTAssertEqual(unclassified.action, .none)
        XCTAssertEqual(unclassified.subAction, .none)
        for route in [
            MessageFilterExtensionRoute(action: .transaction, subAction: .promotionalCoupons),
            .init(action: .transaction, subAction: .transactionalHealth),
            .init(action: .promotion, subAction: .transactionalFinance),
            .init(action: .promotion, subAction: .promotionalOthers),
            .init(action: .none, subAction: .transactionalFinance),
            .init(action: .junk, subAction: .transactionalOrders)
        ] {
            let response = MessageFilterActionMapper.filterResponse(for: route)
            XCTAssertEqual(response.action, MessageFilterActionMapper.filterAction(for: route.action))
            XCTAssertEqual(response.subAction, .none)
        }
    }
}
