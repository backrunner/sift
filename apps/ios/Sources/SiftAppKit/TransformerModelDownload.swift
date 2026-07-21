@preconcurrency import Foundation
import MessageFilterCore

#if canImport(Network)
import Network
#endif

public struct TransformerNetworkCondition: Hashable, Sendable {
    public let isExpensive: Bool
    public let isConstrained: Bool

    public init(isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public var requiresTrafficConfirmation: Bool {
        isExpensive || isConstrained
    }
}

public struct TransformerModelDownloadArtifact: Hashable, Sendable {
    public let remoteURL: URL
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64

    public init(remoteURL: URL, relativePath: String, sha256: String, byteCount: Int64) {
        self.remoteURL = remoteURL
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public struct TransformerModelDownloadPlan: Hashable, Sendable {
    public let manifest: TransformerModelManifest
    public let manifestURL: URL
    public let artifacts: [TransformerModelDownloadArtifact]
    public let exactByteCount: Int64?
    public let estimatedByteCount: Int64?
    public let networkCondition: TransformerNetworkCondition

    public init(
        manifest: TransformerModelManifest,
        manifestURL: URL,
        artifacts: [TransformerModelDownloadArtifact],
        exactByteCount: Int64?,
        estimatedByteCount: Int64?,
        networkCondition: TransformerNetworkCondition
    ) {
        self.manifest = manifest
        self.manifestURL = manifestURL
        self.artifacts = artifacts
        self.exactByteCount = exactByteCount
        self.estimatedByteCount = estimatedByteCount
        self.networkCondition = networkCondition
    }

    public var displayByteCount: Int64? {
        exactByteCount ?? estimatedByteCount
    }
}

public struct TransformerModelDownloadProgress: Hashable, Sendable {
    public let receivedBytes: Int64
    public let totalBytes: Int64?

    public init(receivedBytes: Int64, totalBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }
}

public enum TransformerModelDownloadPhase: Hashable, Sendable {
    case notDownloaded
    case checking
    case waitingForTrafficConfirmation
    case downloading
    case installing
    case ready
    case failed(String)
}

public enum TransformerModelDownloadWorkPhase: Hashable, Sendable {
    case downloading
    case installing
}

public enum TransformerModelDownloadError: Error, LocalizedError, Hashable, Sendable {
    case missingRemoteManifestURL
    case invalidChannelManifest
    case incompatibleModel
    case invalidManifestSignature
    case invalidManifestResponse
    case missingRemoteArtifactList
    case unsupportedTokenizerArtifact
    case unsafeArtifactPath(String)
    case checksumMismatch(String)
    case installFailed

    public var errorDescription: String? {
        switch self {
        case .missingRemoteManifestURL:
            return String(localized: "高级模型下载地址未配置")
        case .invalidChannelManifest:
            return String(localized: "高级模型更新信息不可用")
        case .incompatibleModel:
            return String(localized: "此模型版本与当前 App 不兼容")
        case .invalidManifestSignature:
            return String(localized: "高级模型签名校验失败")
        case .invalidManifestResponse:
            return String(localized: "高级模型清单不可用")
        case .missingRemoteArtifactList:
            return String(localized: "高级模型缺少可下载文件清单")
        case .unsupportedTokenizerArtifact:
            return String(localized: "高级模型下载格式已更新，请稍后重试")
        case let .unsafeArtifactPath(path):
            return String(format: String(localized: "高级模型文件路径不安全：%@"), path)
        case let .checksumMismatch(path):
            return String(format: String(localized: "高级模型文件校验失败：%@"), path)
        case .installFailed:
            return String(localized: "高级模型安装失败")
        }
    }
}

public protocol TransformerNetworkConditionChecking: Sendable {
    func currentCondition() async -> TransformerNetworkCondition
}

public protocol TransformerModelDownloading: Sendable {
    func prepareDownload() async throws -> TransformerModelDownloadPlan
    @concurrent
    func download(
        _ plan: TransformerModelDownloadPlan,
        progress: @Sendable @escaping (TransformerModelDownloadProgress) -> Void,
        phase: @Sendable @escaping (TransformerModelDownloadWorkPhase) -> Void
    ) async throws
}

public protocol TransformerModelUpdateChecking: Sendable {
    func checkForUpdate(currentIdentity: ModelArtifactIdentity?) async -> TransformerUpdateState
}

public protocol TransformerModelRemoving: Sendable {
    @concurrent
    func removeInstalledModel() async throws
}

public struct TransformerModelStoreRemover: TransformerModelRemoving {
    public init() {}

    @concurrent
    public func removeInstalledModel() async throws {
        try TransformerModelStore.remove()
    }
}

public struct PathNetworkConditionChecker: TransformerNetworkConditionChecking {
    public init() {}

    public func currentCondition() async -> TransformerNetworkCondition {
        #if canImport(Network)
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let box = NetworkConditionContinuation(continuation: continuation, monitor: monitor)
            let queue = DispatchQueue(label: "io.alkinum.sift.network-condition")
            monitor.pathUpdateHandler = { path in
                box.resume(
                    TransformerNetworkCondition(
                        isExpensive: path.isExpensive,
                        isConstrained: path.isConstrained
                    )
                )
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.0) {
                box.resume(TransformerNetworkCondition())
            }
        }
        #else
        TransformerNetworkCondition()
        #endif
    }
}

#if canImport(Network)
private final class NetworkConditionContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TransformerNetworkCondition, Never>?
    private let monitor: NWPathMonitor

    init(continuation: CheckedContinuation<TransformerNetworkCondition, Never>, monitor: NWPathMonitor) {
        self.continuation = continuation
        self.monitor = monitor
    }

    func resume(_ condition: TransformerNetworkCondition) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else {
            return
        }
        monitor.cancel()
        continuation.resume(returning: condition)
    }
}
#endif

public final class TransformerModelDownloadClient: TransformerModelDownloading, TransformerModelUpdateChecking, @unchecked Sendable {
    private let manifestURL: URL
    private let channelURL: URL?
    private let manifestVerifier: TransformerManifestVerifier?
    private let appBuild: Int
    private let operatingSystemVersion: OperatingSystemVersion
    private let estimatedByteCount: Int64?
    private let resourceName: String
    private let session: URLSession
    private let networkConditionChecker: any TransformerNetworkConditionChecking
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var channelETag: String?
    private var cachedChannel: TransformerChannelManifestV2?

    public init(
        manifestURL: URL,
        estimatedByteCount: Int64? = nil,
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        session: URLSession = .shared,
        networkConditionChecker: any TransformerNetworkConditionChecking = PathNetworkConditionChecker(),
        fileManager: FileManager = .default
    ) {
        self.manifestURL = manifestURL
        self.channelURL = nil
        self.manifestVerifier = nil
        self.appBuild = 0
        self.operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        self.estimatedByteCount = estimatedByteCount
        self.resourceName = resourceName
        self.session = session
        self.networkConditionChecker = networkConditionChecker
        self.fileManager = fileManager
    }

    public init(
        channelURL: URL,
        publicKeys: [String: String],
        appBuild: Int,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        estimatedByteCount: Int64? = nil,
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        session: URLSession = .shared,
        networkConditionChecker: any TransformerNetworkConditionChecking = PathNetworkConditionChecker(),
        fileManager: FileManager = .default
    ) {
        self.manifestURL = channelURL
        self.channelURL = channelURL
        self.manifestVerifier = TransformerManifestVerifier(publicKeys: publicKeys)
        self.appBuild = appBuild
        self.operatingSystemVersion = operatingSystemVersion
        self.estimatedByteCount = estimatedByteCount
        self.resourceName = resourceName
        self.session = session
        self.networkConditionChecker = networkConditionChecker
        self.fileManager = fileManager
    }

    public static func configured(bundle: Bundle = .main) -> TransformerModelDownloadClient? {
        let keys = ["SiftTransformerModelChannelURL", "SIFT_TRANSFORMER_MODEL_CHANNEL_URL"]
        let channelURL = keys.compactMap { key -> URL? in
            guard
                let value = bundle.object(forInfoDictionaryKey: key) as? String,
                let url = URL(string: value),
                url.scheme != nil
            else {
                return nil
            }
            return url
        }.first

        let keyID = bundle.object(forInfoDictionaryKey: "SiftTransformerModelPublicKeyID") as? String ?? "release-2026"
        let configuredKey = bundle.object(forInfoDictionaryKey: "SiftTransformerModelPublicKey") as? String
        let dictionaryKeys = bundle.object(forInfoDictionaryKey: "SiftTransformerModelPublicKeys") as? [String: String] ?? [:]
        var publicKeys = dictionaryKeys
        if let configuredKey, !configuredKey.isEmpty {
            publicKeys[keyID] = configuredKey
        }
        guard let channelURL, !publicKeys.isEmpty else {
            return nil
        }

        let estimatedBytes = (bundle.object(forInfoDictionaryKey: "SiftTransformerModelEstimatedBytes") as? NSNumber)?.int64Value
        let appBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        return TransformerModelDownloadClient(
            channelURL: channelURL,
            publicKeys: publicKeys,
            appBuild: appBuild,
            estimatedByteCount: estimatedBytes
        )
    }

    public func prepareDownload() async throws -> TransformerModelDownloadPlan {
        let condition = await networkConditionChecker.currentCondition()
        let releaseURL: URL
        let manifest: TransformerModelManifest
        if let channelURL, let manifestVerifier {
            let channel = try await fetchChannel(at: channelURL, verifier: manifestVerifier)
            let currentSequence = TransformerClassifierLoader.manifest()?.releaseSequence ?? 0
            guard manifestVerifier.compatibility(
                of: channel,
                appBuild: appBuild,
                operatingSystemVersion: operatingSystemVersion,
                currentReleaseSequence: currentSequence
            ) == .compatible else {
                throw TransformerModelDownloadError.incompatibleModel
            }
            guard let url = URL(string: channel.releaseManifestURL), url.scheme == "https" else {
                throw TransformerModelDownloadError.invalidChannelManifest
            }
            releaseURL = url
            let (data, response) = try await session.data(from: releaseURL)
            guard response.isSuccessfulHTTPResponse else {
                throw TransformerModelDownloadError.invalidManifestResponse
            }
            guard manifestVerifier.checksum(for: data) == channel.releaseManifestSHA256 else {
                throw TransformerManifestValidationError.releaseManifestChecksumMismatch
            }
            manifest = try JSONDecoder().decode(TransformerModelManifest.self, from: data)
            do {
                try manifestVerifier.verifySignature(of: manifest)
                try manifestVerifier.validateRelease(manifest, for: channel)
            } catch {
                throw TransformerModelDownloadError.invalidManifestSignature
            }
        } else {
            releaseURL = manifestURL
            manifest = try await fetchManifest(at: releaseURL)
        }
        try Self.validateManifestForDownload(manifest)
        let artifacts = try await resolveArtifacts(for: manifest, manifestURL: releaseURL)
        let exactBytes = exactByteCount(for: manifest, artifacts: artifacts)

        return TransformerModelDownloadPlan(
            manifest: manifest,
            manifestURL: releaseURL,
            artifacts: artifacts,
            exactByteCount: exactBytes,
            estimatedByteCount: estimatedByteCount,
            networkCondition: condition
        )
    }

    public func checkForUpdate(currentIdentity: ModelArtifactIdentity?) async -> TransformerUpdateState {
        guard let channelURL, let manifestVerifier else {
            return .failed(TransformerModelDownloadError.missingRemoteManifestURL.localizedDescription)
        }
        do {
            let channel = try await fetchChannel(at: channelURL, verifier: manifestVerifier)
            let currentSequence = currentIdentity?.variant == .transformer
                ? currentIdentity?.releaseSequence ?? 0
                : 0
            let compatibility = manifestVerifier.compatibility(
                of: channel,
                appBuild: appBuild,
                operatingSystemVersion: operatingSystemVersion,
                currentReleaseSequence: currentSequence
            )
            switch compatibility {
            case .compatible:
                return channel.releaseSequence > currentSequence ? .updateAvailable(channel) : .current
            case .appBuildTooOld:
                return .requiresAppUpdate(channel)
            case .unsupportedSchema, .unsupportedABI, .appBuildTooNew,
                 .operatingSystemTooOld, .releaseRollback:
                return .incompatible(channel)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func validateManifestForDownload(_ manifest: TransformerModelManifest) throws {
        guard
            manifest.schemaVersion == TransformerManifestVerifier.supportedSchemaVersion,
            TransformerManifestVerifier.supportedModelABIs.contains(manifest.modelABI),
            manifest.runtimeProfile.computeUnits == "all",
            [4, 8].contains(manifest.quantizationProfile.weightBits),
            manifest.tokenizerKind == "bpe",
            manifest.tokenizerArtifact.hasSuffix(".siftbpe"),
            TransformerModelStore.isSHA256(manifest.sha256),
            TransformerModelStore.isSHA256(manifest.tokenizerSHA256)
        else {
            throw TransformerModelDownloadError.unsupportedTokenizerArtifact
        }
        guard !manifest.remoteArtifacts.isEmpty else {
            throw TransformerModelDownloadError.missingRemoteArtifactList
        }
        let paths = manifest.remoteArtifacts.map(\.path)
        guard
            Set(paths).count == paths.count,
            paths.contains(manifest.tokenizerArtifact),
            paths.contains(where: {
                $0 == manifest.modelArtifact || $0.hasPrefix(manifest.modelArtifact + "/")
            }),
            manifest.remoteArtifacts.allSatisfy({
                TransformerModelStore.isSafeRelativePath($0.path)
                    && TransformerModelStore.isSHA256($0.sha256)
                    && $0.byteCount > 0
            })
        else {
            throw TransformerModelDownloadError.invalidManifestResponse
        }
        guard
            manifest.validationMetrics.fixedAccuracy >= 0.99,
            manifest.validationMetrics.promotionAccuracy >= 0.97,
            manifest.validationMetrics.fp16Agreement >= 0.985,
            manifest.languages.contains("zh"),
            manifest.languages.contains("en"),
            manifest.languages.contains("ja")
        else {
            throw TransformerModelDownloadError.invalidManifestResponse
        }
    }

    @concurrent
    public func download(
        _ plan: TransformerModelDownloadPlan,
        progress: @Sendable @escaping (TransformerModelDownloadProgress) -> Void,
        phase: @Sendable @escaping (TransformerModelDownloadWorkPhase) -> Void
    ) async throws {
        phase(.downloading)
        let staging = TransformerModelStore.stagingDirectory(resourceName: resourceName, fileManager: fileManager)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let manifestData = try JSONEncoder().encode(plan.manifest)
            try manifestData.write(
                to: TransformerModelStore.manifestURL(resourceName: resourceName, in: staging, fileManager: fileManager),
                options: [.atomic]
            )

            var completedBytes: Int64 = 0
            for artifact in plan.artifacts {
                try Task.checkCancellation()
                let targetURL = staging.appendingPathComponent(artifact.relativePath, isDirectory: false)
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let baseCompletedBytes = completedBytes
                let received = try await downloadArtifact(artifact, to: targetURL) { partial in
                    progress(TransformerModelDownloadProgress(
                        receivedBytes: baseCompletedBytes + partial,
                        totalBytes: plan.displayByteCount
                    ))
                }
                try Task.checkCancellation()
                completedBytes += received
                progress(TransformerModelDownloadProgress(receivedBytes: completedBytes, totalBytes: plan.displayByteCount))

                if try TransformerModelStore.fileSHA256(at: targetURL) != artifact.sha256 {
                    throw TransformerModelDownloadError.checksumMismatch(artifact.relativePath)
                }
            }

            try Task.checkCancellation()
            phase(.installing)
            if
                let modelURL = TransformerModelStore.artifactURL(
                    named: plan.manifest.modelArtifact,
                    in: staging,
                    fileManager: fileManager
                ),
                try TransformerModelStore.directorySHA256(at: modelURL, fileManager: fileManager) != plan.manifest.sha256
            {
                throw TransformerModelDownloadError.checksumMismatch(plan.manifest.modelArtifact)
            }

            guard
                TransformerModelStore.model(
                    in: staging,
                    resourceName: resourceName,
                    fileManager: fileManager,
                    validateChecksums: false
                ) != nil
            else {
                throw TransformerModelDownloadError.installFailed
            }
            try Task.checkCancellation()
            try TransformerClassifierLoader.prepareDownloadedModel(
                in: staging,
                resourceName: resourceName,
                fileManager: fileManager
            )
            try Task.checkCancellation()
            try TransformerModelStore.activate(stagedDirectory: staging, resourceName: resourceName, fileManager: fileManager)
            FilterConfigurationSnapshotStore.refreshModelArtifactIdentity()
            let resumeDirectory = TransformerModelStore.downloadResumeDataDirectory(
                resourceName: resourceName,
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: resumeDirectory.path) {
                try? fileManager.removeItem(at: resumeDirectory)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func fetchManifest(at url: URL) async throws -> TransformerModelManifest {
        let (data, response) = try await session.data(from: url)
        guard response.isSuccessfulHTTPResponse else {
            throw TransformerModelDownloadError.invalidManifestResponse
        }
        return try JSONDecoder().decode(TransformerModelManifest.self, from: data)
    }

    private func fetchChannel(
        at url: URL,
        verifier: TransformerManifestVerifier
    ) async throws -> TransformerChannelManifestV2 {
        var request = URLRequest(url: url)
        let (etag, cached) = stateLock.withLock {
            (channelETag, cachedChannel)
        }
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 304, let cached {
            return cached
        }
        guard response.isSuccessfulHTTPResponse else {
            throw TransformerModelDownloadError.invalidChannelManifest
        }
        let channel = try JSONDecoder().decode(TransformerChannelManifestV2.self, from: data)
        do {
            try verifier.verifySignature(of: channel)
        } catch {
            throw TransformerModelDownloadError.invalidManifestSignature
        }
        stateLock.withLock {
            channelETag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            cachedChannel = channel
        }
        return channel
    }

    private func resolveArtifacts(
        for manifest: TransformerModelManifest,
        manifestURL: URL
    ) async throws -> [TransformerModelDownloadArtifact] {
        let remoteArtifacts = try remoteArtifacts(for: manifest)
        let baseURL = remoteBaseURL(for: manifest, manifestURL: manifestURL)
        var artifacts: [TransformerModelDownloadArtifact] = []
        artifacts.reserveCapacity(remoteArtifacts.count)

        for artifact in remoteArtifacts {
            guard TransformerModelStore.isSafeRelativePath(artifact.path) else {
                throw TransformerModelDownloadError.unsafeArtifactPath(artifact.path)
            }
            let remoteURL = baseURL.appendingPathComponent(artifact.path, isDirectory: false)
            artifacts.append(TransformerModelDownloadArtifact(
                remoteURL: remoteURL,
                relativePath: artifact.path,
                sha256: artifact.sha256,
                byteCount: artifact.byteCount
            ))
        }
        return artifacts
    }

    private func remoteArtifacts(for manifest: TransformerModelManifest) throws -> [TransformerRemoteArtifact] {
        guard !manifest.remoteArtifacts.isEmpty else {
            throw TransformerModelDownloadError.missingRemoteArtifactList
        }
        return manifest.remoteArtifacts
    }

    private func remoteBaseURL(for manifest: TransformerModelManifest, manifestURL: URL) -> URL {
        if
            let raw = manifest.remoteBaseURL,
            let url = URL(string: raw),
            url.scheme != nil
        {
            return url
        }
        return manifestURL.deletingLastPathComponent()
    }

    private func exactByteCount(
        for manifest: TransformerModelManifest,
        artifacts: [TransformerModelDownloadArtifact]
    ) -> Int64? {
        if manifest.downloadBytes > 0 {
            return manifest.downloadBytes
        }
        return artifacts.map(\.byteCount).reduce(0, +)
    }

    private func downloadArtifact(
        _ artifact: TransformerModelDownloadArtifact,
        to targetURL: URL,
        progress: @Sendable @escaping (Int64) -> Void
    ) async throws -> Int64 {
        guard let resumeDataURL = TransformerModelStore.downloadResumeDataURL(
            artifactSHA256: artifact.sha256,
            resourceName: resourceName,
            fileManager: fileManager
        ) else {
            throw TransformerModelDownloadError.invalidManifestResponse
        }
        let operation = TransformerArtifactDownloadOperation(
            targetURL: targetURL,
            resumeDataURL: resumeDataURL,
            fileManager: fileManager,
            progress: progress
        )
        let receivedBytes = try await operation.run(using: session, url: artifact.remoteURL)
        try Task.checkCancellation()

        guard operation.response?.isSuccessfulHTTPResponse == true else {
            if fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.removeItem(at: targetURL)
            }
            throw TransformerModelDownloadError.invalidManifestResponse
        }

        if !fileManager.fileExists(atPath: targetURL.path) {
            throw TransformerModelDownloadError.installFailed
        }

        let finalBytes: Int64
        if receivedBytes > 0 {
            finalBytes = receivedBytes
        } else {
            let attributes = try fileManager.attributesOfItem(atPath: targetURL.path)
            finalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        progress(finalBytes)
        return finalBytes
    }
}

private final class TransformerArtifactDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let progressIntervalNanoseconds: UInt64 = 100_000_000

    private let targetURL: URL
    private let resumeDataURL: URL
    private let fileManager: FileManager
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Int64, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancellationRequested = false
    private var responseValue: URLResponse?
    private var lastProgressUptimeNanoseconds: UInt64 = 0
    private var latestReceivedBytes: Int64 = 0
    private var installationError: Error?

    init(
        targetURL: URL,
        resumeDataURL: URL,
        fileManager: FileManager,
        progress: @Sendable @escaping (Int64) -> Void
    ) {
        self.targetURL = targetURL
        self.resumeDataURL = resumeDataURL
        self.fileManager = fileManager
        self.progress = progress
    }

    var response: URLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responseValue
    }

    func run(using baseSession: URLSession, url: URL) async throws -> Int64 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                lock.lock()
                self.continuation = continuation
                let wasCancelled = cancellationRequested
                lock.unlock()

                let session = URLSession(
                    configuration: baseSession.configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let task: URLSessionDownloadTask
                if let resumeData = try? Data(contentsOf: resumeDataURL), !resumeData.isEmpty {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }

                lock.lock()
                self.session = session
                self.task = task
                let shouldCancel = cancellationRequested || wasCancelled
                lock.unlock()

                task.resume()
                if shouldCancel {
                    task.cancel()
                }
            }
        }, onCancel: {
            cancel()
        })
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel(byProducingResumeData: { [weak self] resumeData in
            self?.persistResumeData(resumeData)
        })
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite _: Int64
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        latestReceivedBytes = max(latestReceivedBytes, totalBytesWritten)
        let shouldEmit = lastProgressUptimeNanoseconds == 0
            || (now >= lastProgressUptimeNanoseconds
                && now - lastProgressUptimeNanoseconds >= Self.progressIntervalNanoseconds)
        if shouldEmit {
            lastProgressUptimeNanoseconds = now
        }
        lock.unlock()

        if shouldEmit {
            progress(totalBytesWritten)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        responseValue = downloadTask.response
        lock.unlock()

        do {
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: location, to: targetURL)
            try? fileManager.removeItem(at: resumeDataURL)
        } catch {
            lock.lock()
            installationError = error
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        responseValue = task.response ?? responseValue
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.task = nil
        self.session = nil
        let completionError = error ?? installationError
        let receivedBytes = latestReceivedBytes
        lock.unlock()

        if let error = completionError as NSError? {
            let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if let resumeData {
                persistResumeData(resumeData)
            } else if error.code != NSURLErrorCancelled {
                try? fileManager.removeItem(at: resumeDataURL)
            }
        }

        session?.finishTasksAndInvalidate()
        guard let continuation else {
            return
        }
        if let completionError {
            continuation.resume(throwing: completionError)
        } else {
            continuation.resume(returning: receivedBytes)
        }
    }

    private func persistResumeData(_ data: Data?) {
        guard let data, !data.isEmpty else {
            return
        }
        do {
            try fileManager.createDirectory(
                at: resumeDataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: resumeDataURL, options: .atomic)
        } catch {
            // Resume data is an optimization. A failed write falls back to a
            // clean download without weakening artifact checksum validation.
        }
    }
}

private extension URLResponse {
    var isSuccessfulHTTPResponse: Bool {
        guard let response = self as? HTTPURLResponse else {
            return true
        }
        return (200..<300).contains(response.statusCode)
    }
}
