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
        // IdentityLookup may read App Group configuration and models, but
        // cannot write shared files or preferences back to the containing app.
        let diagnostics = MessageFilterOSLogDiagnosticsRecorder(persistence: .systemLogOnly)
        let engine = MessageFilterEngine(transformerCacheReleaseHandler: { event in
            // Cache release runs on the runtime actor. Keep OSLog I/O
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
        let gate = CompletionOnceGate<MessageFilterExtensionRoute> { route in
            completion(MessageFilterActionMapper.filterResponse(for: route))
        }
        let request = MessageFilterRequest(
            sender: queryRequest.sender,
            body: queryRequest.messageBody ?? ""
        )
        let configuration = FilterConfigurationSnapshotStore.load()
        let requestID = UUID()
        let observer = diagnostics.stageObserver(requestID: requestID, configuration: configuration)
        observer(.queryReceived)
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
            if gate.complete(.unclassified) {
                observer(.watchdogResponded)
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
                    appGroupContainerAvailable: hasSharedContainer,
                    requestID: requestID,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier
                ))
            }
        }
        Task { [engine, diagnostics] in
            let result = await engine.classify(request, configuration: configuration, observer: observer)
            let route = MessageFilterActionMapper.extensionRoute(for: result)
            let didComplete = gate.complete(route)
            watchdogTask.cancel()
            if didComplete {
                observer(.responseSubmitted)
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
                    systemAction: route.action,
                    systemSubAction: route.subAction,
                    appGroupContainerAvailable: hasSharedContainer,
                    requestID: requestID,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier
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
