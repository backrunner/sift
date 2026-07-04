import IdentityLookup
import MessageFilterCore
import MessageFilterExtensionKit

@objc(MessageFilterExtension)
final class MessageFilterExtension: ILMessageFilterExtension, ILMessageFilterQueryHandling {
    /// Honors the model variant the user picked in the app; the selection and
    /// custom rules are shared through the app-group defaults. iOS may keep
    /// this process alive across queries, so the selection is re-checked per
    /// query and the pipeline rebuilt when the user switched models in the
    /// app meanwhile. Falls back to the classic stack when transformer
    /// artifacts are missing.
    private var activeVariant: ModelVariant
    private var pipeline: ClassificationPipeline
    private var rules: [CustomRule]
    private let statistics = FilterStatisticsStore()

    override init() {
        let variant = ModelSelectionStore.load()
        self.activeVariant = variant
        self.pipeline = ClassificationPipeline(classifier: AppleClassifierLoader.classifier(for: variant))
        self.rules = SharedRuleStore.load()
        super.init()
    }

    func handle(_ queryRequest: ILMessageFilterQueryRequest, context: ILMessageFilterExtensionContext, completion: @escaping (ILMessageFilterQueryResponse) -> Void) {
        refreshSharedStateIfNeeded()

        let decision = pipeline.classify(
            sender: queryRequest.sender,
            body: queryRequest.messageBody ?? "",
            rules: rules
        )
        statistics.record(decision: decision)

        let response = ILMessageFilterQueryResponse()
        response.action = MessageFilterActionMapper.filterAction(for: decision)
        completion(response)
    }

    private func refreshSharedStateIfNeeded() {
        let variant = ModelSelectionStore.load()
        if variant != activeVariant {
            activeVariant = variant
            pipeline = ClassificationPipeline(classifier: AppleClassifierLoader.classifier(for: variant))
        }
        rules = SharedRuleStore.load()
    }
}
