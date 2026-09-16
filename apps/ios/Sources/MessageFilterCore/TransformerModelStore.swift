import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

public struct InstalledTransformerModel: Hashable, Sendable {
    public let manifest: TransformerModelManifest
    public let directoryURL: URL
    public let manifestURL: URL
    public let tokenizerURL: URL
    public let modelURL: URL

    public var embeddingURL: URL? {
        MappedTokenEmbedding.url(modelURL: modelURL, modelABI: manifest.modelABI)
    }

    public init(
        manifest: TransformerModelManifest,
        directoryURL: URL,
        manifestURL: URL,
        tokenizerURL: URL,
        modelURL: URL
    ) {
        self.manifest = manifest
        self.directoryURL = directoryURL
        self.manifestURL = manifestURL
        self.tokenizerURL = tokenizerURL
        self.modelURL = modelURL
    }
}

public enum TransformerModelStore {
    public static let directoryName = "TransformerModels"
    // Bump whenever the client inference contract changes incompatibly. Old
    // app/extension processes must never discover or overwrite this runtime.
    public static let runtimeNamespace = "runtime-v2"

    public static func baseDirectory(
        appGroupIdentifier: String = ModelSelectionStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> URL {
        let root = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("Sift", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(runtimeNamespace, isDirectory: true)
    }

    public static func modelDirectory(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> URL {
        let root = resourceDirectory(resourceName: resourceName, fileManager: fileManager)
        let pointer = root.appendingPathComponent("active.json")
        if let data = try? Data(contentsOf: pointer),
           let generation = try? JSONDecoder().decode(String.self, from: data),
           UUID(uuidString: generation) != nil {
            return root.appendingPathComponent(generation, isDirectory: true)
        }
        return root
    }

    private static func resourceDirectory(resourceName: String, fileManager: FileManager) -> URL {
        baseDirectory(fileManager: fileManager).appendingPathComponent(resourceName, isDirectory: true)
    }

    public static func stagingDirectory(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory(fileManager: fileManager)
            .appendingPathComponent(".\(resourceName).staging", isDirectory: true)
    }

    public static func previousModelDirectory(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory(fileManager: fileManager)
            .appendingPathComponent("\(resourceName).previous", isDirectory: true)
    }

    public static func downloadResumeDataDirectory(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory(fileManager: fileManager)
            .appendingPathComponent(".\(resourceName).resume", isDirectory: true)
    }

    public static func downloadResumeDataURL(
        artifactSHA256: String,
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> URL? {
        guard isSHA256(artifactSHA256) else {
            return nil
        }
        return downloadResumeDataDirectory(resourceName: resourceName, fileManager: fileManager)
            .appendingPathComponent("\(artifactSHA256).resume", isDirectory: false)
    }

    public static func manifestURL(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        (directory ?? modelDirectory(resourceName: resourceName, fileManager: fileManager))
            .appendingPathComponent("\(resourceName).manifest.json", isDirectory: false)
    }

    public static func compiledModelURL(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        (directory ?? modelDirectory(resourceName: resourceName, fileManager: fileManager))
            .appendingPathComponent("\(resourceName).mlmodelc", isDirectory: true)
    }

    public static func installedModel(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default,
        validateChecksums: Bool = true,
        identity: ModelArtifactIdentity? = nil
    ) -> InstalledTransformerModel? {
        let directory = modelDirectory(resourceName: resourceName, fileManager: fileManager)
        let active = model(
            in: directory,
            resourceName: resourceName,
            fileManager: fileManager,
            validateChecksums: validateChecksums
        )
        guard let identity else { return active }
        if active?.manifest.artifactIdentity == identity { return active }
        // A request can have captured the old configuration immediately before
        // activation. Resolve all of its resources from that same generation.
        let root = resourceDirectory(resourceName: resourceName, fileManager: fileManager)
        let generations = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        for generation in generations where UUID(uuidString: generation.lastPathComponent) != nil {
            if let candidate = model(in: generation, resourceName: resourceName,
                                     fileManager: fileManager, validateChecksums: false),
               candidate.manifest.artifactIdentity == identity {
                return validateChecksums
                    ? model(in: generation, resourceName: resourceName, fileManager: fileManager)
                    : candidate
            }
        }
        return nil
    }

    public static func model(
        in directory: URL,
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default,
        validateChecksums: Bool = true
    ) -> InstalledTransformerModel? {
        let manifestURL = manifestURL(resourceName: resourceName, in: directory, fileManager: fileManager)
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(TransformerModelManifest.self, from: data),
            TransformerManifestVerifier.supportedModelABIs.contains(manifest.modelABI)
                || (manifest.schemaVersion == 1 && manifest.modelABI == "legacy-mmbert-v1"),
            TransformerSignalReleaseContract.accepts(manifest),
            let tokenizerURL = tokenizerURL(for: manifest, in: directory, fileManager: fileManager),
            let modelURL = artifactURL(named: manifest.modelArtifact, in: directory, fileManager: fileManager),
            manifest.tokenizerKind == "bpe",
            tokenizerURL.pathExtension == "siftbpe"
        else {
            return nil
        }

        #if os(iOS)
        guard let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
              build >= manifest.minimumAppBuild, build <= manifest.maximumAppBuild,
              TransformerManifestVerifier.isOperatingSystem(
                ProcessInfo.processInfo.operatingSystemVersion, atLeast: manifest.minimumOSVersion
              ) else { return nil }
        #endif

        if let embeddingURL = MappedTokenEmbedding.url(modelURL: modelURL, modelABI: manifest.modelABI),
           !fileManager.fileExists(atPath: embeddingURL.path) {
            return nil
        }

        guard
            !validateChecksums
                || validateInstalledArtifacts(
                    manifest: manifest,
                    directory: directory,
                    modelURL: modelURL,
                    fileManager: fileManager
                )
        else {
            return nil
        }

        return InstalledTransformerModel(
            manifest: manifest,
            directoryURL: directory,
            manifestURL: manifestURL,
            tokenizerURL: tokenizerURL,
            modelURL: modelURL
        )
    }

    public static func activate(
        stagedDirectory: URL,
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) throws {
        let root = resourceDirectory(resourceName: resourceName, fileManager: fileManager)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let generation = UUID().uuidString
        let destination = root.appendingPathComponent(generation, isDirectory: true)
        try fileManager.moveItem(at: stagedDirectory, to: destination)
        do {
            try JSONEncoder().encode(generation).write(
                to: root.appendingPathComponent("active.json"), options: .atomic
            )
        } catch {
            try? fileManager.moveItem(at: destination, to: stagedDirectory)
            throw error
        }
        // Retain generations until explicit model cleanup: another process
        // can still have Core ML or an embedding mmap open at its original URL.
    }

    public static func remove(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) throws {
        let directory = resourceDirectory(resourceName: resourceName, fileManager: fileManager)
        let previous = previousModelDirectory(resourceName: resourceName, fileManager: fileManager)
        let resumeData = downloadResumeDataDirectory(resourceName: resourceName, fileManager: fileManager)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        if fileManager.fileExists(atPath: previous.path) {
            try fileManager.removeItem(at: previous)
        }
        if fileManager.fileExists(atPath: resumeData.path) {
            try fileManager.removeItem(at: resumeData)
        }
        let staging = stagingDirectory(resourceName: resourceName, fileManager: fileManager)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
    }

    @concurrent
    public static func installedModelByteCount(
        resourceName: String = TransformerClassifierLoader.defaultResourceName
    ) async -> Int64? {
        let fileManager = FileManager.default
        let directory = resourceDirectory(resourceName: resourceName, fileManager: fileManager)
        return try? directoryByteCount(at: directory, fileManager: fileManager)
    }

    public static func directoryByteCount(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !isDirectory.boolValue {
            return Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var byteCount: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                continue
            }
            let size = Int64(fileSize)
            guard byteCount <= Int64.max - size else {
                throw CocoaError(.fileReadTooLarge)
            }
            byteCount += size
        }
        return byteCount
    }

    public static func tokenizerURL(
        for manifest: TransformerModelManifest,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        artifactURL(named: manifest.tokenizerArtifact, in: directory, fileManager: fileManager)
    }

    public static func artifactURL(
        named artifactName: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard isSafeRelativePath(artifactName) else {
            return nil
        }
        let url = directory.appendingPathComponent(artifactName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty
            && !path.hasPrefix("/")
            && !components.contains("..")
            && !components.contains(".")
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    public static func fileSHA256(at url: URL) throws -> String {
        #if canImport(CryptoKit)
        var digest = SHA256()
        try update(&digest, withContentsOf: url)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    public static func directorySHA256(at url: URL, fileManager: FileManager = .default) throws -> String {
        #if canImport(CryptoKit)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !isDirectory.boolValue {
            return try fileSHA256(at: url)
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let files = enumerator.compactMap { item -> URL? in
            guard let fileURL = item as? URL else { return nil }
            let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            return values?.isRegularFile == true ? fileURL : nil
        }.sorted { lhs, rhs in
            lhs.path < rhs.path
        }

        var digest = SHA256()
        for file in files {
            let relativePath = String(file.path.dropFirst(url.path.count + 1))
            digest.update(data: Data(relativePath.utf8))
            try update(&digest, withContentsOf: file)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    #if canImport(CryptoKit)
    private static func update(_ digest: inout SHA256, withContentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
    }
    #endif

    private static func validateInstalledArtifacts(
        manifest: TransformerModelManifest,
        directory: URL,
        modelURL: URL,
        fileManager: FileManager
    ) -> Bool {
        for artifact in manifest.remoteArtifacts {
            guard
                let artifactURL = artifactURL(named: artifact.path, in: directory, fileManager: fileManager),
                (try? fileSHA256(at: artifactURL)) == artifact.sha256
            else {
                return false
            }
        }

        return (try? directorySHA256(at: modelURL, fileManager: fileManager)) == manifest.sha256
    }
}
