import Dispatch
import IdentityLookup
import MessageFilterCore
import MessageFilterExtensionKit

@objc(MessageFilterExtension)
final class MessageFilterExtension: ILMessageFilterExtension, ILMessageFilterQueryHandling, ILMessageFilterCapabilitiesQueryHandling {
    private static let sessionTracker = MessageFilterSessionTracker()
    // Apple does not publish a numeric IdentityLookup deadline. This is Sift's
    // own last-resort response guard, after Signal receives its full cold-start
    // attempt budget and before completion could otherwise be lost entirely.
    private static let handlerWatchdog = MessageFilterTimingPolicy.handlerWatchdog

    private let engine: MessageFilterEngine
    private let diagnostics: MessageFilterOSLogDiagnosticsRecorder
    private let appGroupContainerAvailable: Bool
    private let memoryPressureSource: DispatchSourceMemoryPressure

    override init() {
        let diagnostics = MessageFilterOSLogDiagnosticsRecorder()
        let engine = MessageFilterEngine(transformerCacheReleaseHandler: { event in
            // Cache release runs on the runtime actor. Keep JSONL and OSLog I/O
            // outside that serialization point so the next query is not delayed.
            Task.detached(priority: .utility) {
                diagnostics.record(event)
            }
        })
        let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        self.engine = engine
        self.diagnostics = diagnostics
        self.appGroupContainerAvailable = ModelSelectionStore.sharedContainerURL() != nil
        self.memoryPressureSource = memoryPressureSource
        super.init()

        memoryPressureSource.setEventHandler { [engine] in
            Task(priority: .utility) {
                await engine.handleSignalMemoryPressure()
            }
        }
        memoryPressureSource.activate()
    }

    deinit {
        memoryPressureSource.cancel()
    }

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
        let hasSharedContainer = appGroupContainerAvailable
        let isColdStart = Self.sessionTracker.beginQuery()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let physicalFootprintBeforeBytes = MessageFilterProcessMetrics.currentPhysicalFootprintBytes()
        let handlerWatchdog = Self.handlerWatchdog
        let watchdogTask = Task { [diagnostics] in
            do {
                try await Task.sleep(for: handlerWatchdog)
            } catch {
                return
            }
            if gate.complete((.none, .none)) {
                diagnostics.record(MessageFilterDiagnosticEvent(
                    artifactIdentity: configuration.modelArtifactIdentity,
                    latencyBucket: MessageFilterLatencyBucket(elapsed: startedAt.duration(to: clock.now)),
                    fallbackReason: .handlerTimedOut,
                    errorCode: "handler_watchdog",
                    requestedArtifactIdentity: configuration.modelArtifactIdentity,
                    isColdStart: isColdStart,
                    physicalFootprintBeforeBytes: physicalFootprintBeforeBytes,
                    physicalFootprintBytes: MessageFilterProcessMetrics.currentPhysicalFootprintBytes(),
                    selectedVariant: configuration.selectedVariant,
                    configurationGeneration: configuration.generation,
                    executionPath: .noDecision,
                    appGroupContainerAvailable: hasSharedContainer
                ))
            }
        }
        Task { [engine, diagnostics] in
            let result = await engine.classify(request, configuration: configuration)
            let route = MessageFilterActionMapper.extensionRoute(for: result)
            let didComplete = gate.complete((
                MessageFilterActionMapper.filterAction(for: route.action),
                MessageFilterActionMapper.filterSubAction(for: route.subAction)
            ))
            watchdogTask.cancel()
            if didComplete {
                diagnostics.record(MessageFilterDiagnosticEvent(
                    artifactIdentity: result.modelArtifactIdentity,
                    latencyBucket: MessageFilterLatencyBucket(elapsed: startedAt.duration(to: clock.now)),
                    fallbackReason: result.fallbackReason,
                    errorCode: result.errorCode,
                    requestedArtifactIdentity: configuration.modelArtifactIdentity,
                    isColdStart: isColdStart,
                    physicalFootprintBeforeBytes: physicalFootprintBeforeBytes,
                    physicalFootprintBytes: MessageFilterProcessMetrics.currentPhysicalFootprintBytes(),
                    signalTiming: result.signalTiming,
                    selectedVariant: configuration.selectedVariant,
                    configurationGeneration: configuration.generation,
                    executionPath: result.executionPath,
                    decisionLabelID: result.decision.labelID,
                    decisionConfidence: result.decision.confidence,
                    decisionSource: result.decision.source,
                    systemAction: result.systemAction,
                    systemSubAction: result.systemSubAction,
                    appGroupContainerAvailable: hasSharedContainer
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
