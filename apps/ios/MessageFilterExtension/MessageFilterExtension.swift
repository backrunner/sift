import IdentityLookup
import MessageFilterCore
import MessageFilterExtensionKit

@objc(MessageFilterExtension)
final class MessageFilterExtension: ILMessageFilterExtension, ILMessageFilterQueryHandling, ILMessageFilterCapabilitiesQueryHandling {
    private static let sessionTracker = MessageFilterSessionTracker()

    private let engine = MessageFilterEngine()
    private let diagnostics = MessageFilterOSLogDiagnosticsRecorder()

    func handle(_ queryRequest: ILMessageFilterQueryRequest, context: ILMessageFilterExtensionContext, completion: @escaping (ILMessageFilterQueryResponse) -> Void) {
        let gate = CompletionOnceGate<(ILMessageFilterAction, ILMessageFilterSubAction)> { value in
            let response = ILMessageFilterQueryResponse()
            response.action = value.0
            response.subAction = value.1
            completion(response)
        }
        let request = MessageFilterRequest(
            sender: queryRequest.sender,
            body: queryRequest.messageBody ?? ""
        )
        let configuration = FilterConfigurationSnapshotStore.load()
        let isColdStart = Self.sessionTracker.beginQuery()
        let clock = ContinuousClock()
        let startedAt = clock.now
        Task { [engine, diagnostics] in
            let result = await engine.classify(request, configuration: configuration)
            let didComplete = gate.complete((
                MessageFilterActionMapper.filterAction(for: result.systemAction),
                MessageFilterActionMapper.filterSubAction(for: result.systemSubAction)
            ))
            if didComplete {
                diagnostics.record(MessageFilterDiagnosticEvent(
                    artifactIdentity: result.modelArtifactIdentity,
                    latencyBucket: MessageFilterLatencyBucket(elapsed: startedAt.duration(to: clock.now)),
                    fallbackReason: result.fallbackReason,
                    requestedArtifactIdentity: configuration.modelArtifactIdentity,
                    isColdStart: isColdStart,
                    physicalFootprintBytes: MessageFilterProcessMetrics.currentPhysicalFootprintBytes()
                ))
            }
        }
        Task { [diagnostics] in
            try? await Task.sleep(for: .milliseconds(600))
            if gate.complete((.none, .none)) {
                diagnostics.record(MessageFilterDiagnosticEvent(
                    artifactIdentity: configuration.modelArtifactIdentity,
                    latencyBucket: MessageFilterLatencyBucket(elapsed: startedAt.duration(to: clock.now)),
                    fallbackReason: .transformerTimedOut,
                    errorCode: "handler_watchdog",
                    requestedArtifactIdentity: configuration.modelArtifactIdentity,
                    isColdStart: isColdStart,
                    physicalFootprintBytes: MessageFilterProcessMetrics.currentPhysicalFootprintBytes()
                ))
            }
        }
    }

    func handle(_ capabilitiesQueryRequest: ILMessageFilterCapabilitiesQueryRequest, context: ILMessageFilterExtensionContext, completion: @escaping (ILMessageFilterCapabilitiesQueryResponse) -> Void) {
        let response = ILMessageFilterCapabilitiesQueryResponse()
        response.transactionalSubActions = MessageFilterActionMapper.filterTransactionalSubActions
        response.promotionalSubActions = MessageFilterActionMapper.filterPromotionalSubActions
        completion(response)
    }
}
