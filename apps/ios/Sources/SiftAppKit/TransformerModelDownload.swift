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
    public let sha256: String?
    public let byteCount: Int64?

    public init(remoteURL: URL, relativePath: String, sha256: String? = nil, byteCount: Int64? = nil) {
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

public enum TransformerModelDownloadError: Error, LocalizedError, Sendable {
    case missingRemoteManifestURL
    case invalidManifestResponse
    case invalidArtifactList
    case missingRemoteArtifactList
    case unsafeArtifactPath(String)
    case checksumMismatch(String)
    case installFailed

    public var errorDescription: String? {
        switch self {
        case .missingRemoteManifestURL:
            return String(localized: "高级模型下载地址未配置")
        case .invalidManifestResponse:
            return String(localized: "高级模型清单不可用")
        case .invalidArtifactList:
            return String(localized: "高级模型清单格式不正确")
        case .missingRemoteArtifactList:
            return String(localized: "高级模型缺少可下载文件清单")
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
        progress: @Sendable @escaping (TransformerModelDownloadProgress) -> Void
    ) async throws
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

public final class TransformerModelDownloadClient: TransformerModelDownloading, @unchecked Sendable {
    private let manifestURL: URL
    private let estimatedByteCount: Int64?
    private let resourceName: String
    private let session: URLSession
    private let networkConditionChecker: any TransformerNetworkConditionChecking
    private let fileManager: FileManager

    public init(
        manifestURL: URL,
        estimatedByteCount: Int64? = nil,
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        session: URLSession = .shared,
        networkConditionChecker: any TransformerNetworkConditionChecking = PathNetworkConditionChecker(),
        fileManager: FileManager = .default
    ) {
        self.manifestURL = manifestURL
        self.estimatedByteCount = estimatedByteCount
        self.resourceName = resourceName
        self.session = session
        self.networkConditionChecker = networkConditionChecker
        self.fileManager = fileManager
    }

    public static func configured(bundle: Bundle = .main) -> (any TransformerModelDownloading)? {
        let keys = ["SiftTransformerModelManifestURL", "SIFT_TRANSFORMER_MODEL_MANIFEST_URL"]
        let manifestURL = keys.compactMap { key -> URL? in
            guard
                let value = bundle.object(forInfoDictionaryKey: key) as? String,
                let url = URL(string: value),
                url.scheme != nil
            else {
                return nil
            }
            return url
        }.first

        guard let manifestURL else {
            return nil
        }

        let estimatedBytes = (bundle.object(forInfoDictionaryKey: "SiftTransformerModelEstimatedBytes") as? NSNumber)?.int64Value
        return TransformerModelDownloadClient(manifestURL: manifestURL, estimatedByteCount: estimatedBytes)
    }

    public func prepareDownload() async throws -> TransformerModelDownloadPlan {
        let condition = await networkConditionChecker.currentCondition()
        let manifest = try await fetchManifest()
        let artifacts = try await resolveArtifacts(for: manifest)
        let exactBytes = exactByteCount(for: manifest, artifacts: artifacts)

        return TransformerModelDownloadPlan(
            manifest: manifest,
            manifestURL: manifestURL,
            artifacts: artifacts,
            exactByteCount: exactBytes,
            estimatedByteCount: estimatedByteCount,
            networkCondition: condition
        )
    }

    @concurrent
    public func download(
        _ plan: TransformerModelDownloadPlan,
        progress: @Sendable @escaping (TransformerModelDownloadProgress) -> Void
    ) async throws {
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

                if let expected = artifact.sha256, try TransformerModelStore.fileSHA256(at: targetURL) != expected {
                    throw TransformerModelDownloadError.checksumMismatch(artifact.relativePath)
                }
            }

            try Task.checkCancellation()
            guard TransformerModelStore.model(in: staging, resourceName: resourceName, fileManager: fileManager) != nil else {
                throw TransformerModelDownloadError.installFailed
            }
            try Task.checkCancellation()
            try TransformerModelStore.activate(stagedDirectory: staging, resourceName: resourceName, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func fetchManifest() async throws -> TransformerModelManifest {
        let (data, response) = try await session.data(from: manifestURL)
        guard response.isSuccessfulHTTPResponse else {
            throw TransformerModelDownloadError.invalidManifestResponse
        }
        return try JSONDecoder().decode(TransformerModelManifest.self, from: data)
    }

    private func resolveArtifacts(for manifest: TransformerModelManifest) async throws -> [TransformerModelDownloadArtifact] {
        let remoteArtifacts = try remoteArtifacts(for: manifest)
        let baseURL = remoteBaseURL(for: manifest)
        var artifacts: [TransformerModelDownloadArtifact] = []
        artifacts.reserveCapacity(remoteArtifacts.count)

        for artifact in remoteArtifacts {
            guard TransformerModelStore.isSafeRelativePath(artifact.path) else {
                throw TransformerModelDownloadError.unsafeArtifactPath(artifact.path)
            }
            let remoteURL = baseURL.appendingPathComponent(artifact.path, isDirectory: false)
            let byteCount: Int64?
            if let artifactByteCount = artifact.byteCount {
                byteCount = artifactByteCount
            } else {
                byteCount = try? await remoteContentLength(for: remoteURL)
            }
            artifacts.append(TransformerModelDownloadArtifact(
                remoteURL: remoteURL,
                relativePath: artifact.path,
                sha256: artifact.sha256,
                byteCount: byteCount
            ))
        }

        guard !artifacts.isEmpty else {
            throw TransformerModelDownloadError.invalidArtifactList
        }
        return artifacts
    }

    private func remoteArtifacts(for manifest: TransformerModelManifest) throws -> [TransformerRemoteArtifact] {
        if let remoteArtifacts = manifest.remoteArtifacts, !remoteArtifacts.isEmpty {
            return remoteArtifacts
        }

        guard !manifest.modelArtifact.hasSuffix(".mlpackage"), !manifest.modelArtifact.hasSuffix(".mlmodelc") else {
            throw TransformerModelDownloadError.missingRemoteArtifactList
        }

        let tokenizerArtifact = manifest.tokenizerArtifact ?? manifest.vocabularyArtifact
        guard let tokenizerArtifact else {
            throw TransformerModelDownloadError.invalidArtifactList
        }

        return [
            TransformerRemoteArtifact(path: manifest.modelArtifact),
            TransformerRemoteArtifact(path: tokenizerArtifact)
        ]
    }

    private func remoteBaseURL(for manifest: TransformerModelManifest) -> URL {
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
        if let downloadBytes = manifest.downloadBytes, downloadBytes > 0 {
            return downloadBytes
        }
        let sizes = artifacts.compactMap(\.byteCount)
        guard sizes.count == artifacts.count else {
            return nil
        }
        return sizes.reduce(0, +)
    }

    private func remoteContentLength(for url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard response.isSuccessfulHTTPResponse else {
            throw TransformerModelDownloadError.invalidManifestResponse
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : 0
    }

    private func downloadArtifact(
        _ artifact: TransformerModelDownloadArtifact,
        to targetURL: URL,
        progress: @Sendable @escaping (Int64) -> Void
    ) async throws -> Int64 {
        let operation = TransformerArtifactDownloadOperation(
            targetURL: targetURL,
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
        fileManager: FileManager,
        progress: @Sendable @escaping (Int64) -> Void
    ) {
        self.targetURL = targetURL
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
                let task = session.downloadTask(with: url)

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
        task?.cancel()
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
}

private extension URLResponse {
    var isSuccessfulHTTPResponse: Bool {
        guard let response = self as? HTTPURLResponse else {
            return true
        }
        return (200..<300).contains(response.statusCode)
    }
}
