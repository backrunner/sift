import IdentityLookup
import MessageFilterCore
import MessageFilterExtensionKit

@objc(MessageFilterExtension)
final class MessageFilterExtension: ILMessageFilterExtension, ILMessageFilterQueryHandling {
    private let pipeline = ClassificationPipeline(classifier: AppleClassifierLoader.defaultClassifier())

    func handle(_ queryRequest: ILMessageFilterQueryRequest, context: ILMessageFilterExtensionContext, completion: @escaping (ILMessageFilterQueryResponse) -> Void) {
        let decision = pipeline.classify(
            sender: queryRequest.sender,
            body: queryRequest.messageBody ?? "",
            rules: []
        )

        let response = ILMessageFilterQueryResponse()
        response.action = MessageFilterActionMapper.filterAction(for: decision)
        completion(response)
    }
}
