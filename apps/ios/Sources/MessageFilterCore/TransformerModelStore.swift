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

    public static func baseDirectory(
        appGroupIdentifier: String = ModelSelectionStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> URL {
        let root = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("Sift", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func modelDirectory(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory(fileManager: fileManager)
            .appendingPathComponent(resourceName, isDirectory: true)
    }

    public static func stagingDirectory(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory(fileManager: fileManager)
            .appendingPathComponent(".\(resourceName).staging-\(UUID().uuidString)", isDirectory: true)
    }

    public static func manifestURL(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        (directory ?? modelDirectory(resourceName: resourceName, fileManager: fileManager))
            .appendingPathComponent("\(resourceName).manifest.json", isDirectory: false)
    }

    public static func installedModel(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> InstalledTransformerModel? {
        let directory = modelDirectory(resourceName: resourceName, fileManager: fileManager)
        return model(in: directory, resourceName: resourceName, fileManager: fileManager)
    }

    public static func model(
        in directory: URL,
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) -> InstalledTransformerModel? {
        let manifestURL = manifestURL(resourceName: resourceName, in: directory, fileManager: fileManager)
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(TransformerModelManifest.self, from: data),
            let tokenizerURL = tokenizerURL(for: manifest, in: directory, fileManager: fileManager),
            let modelURL = artifactURL(named: manifest.modelArtifact, in: directory, fileManager: fileManager)
        else {
            return nil
        }

        guard validateInstalledArtifacts(manifest: manifest, directory: directory, modelURL: modelURL, fileManager: fileManager) else {
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
        let activeDirectory = modelDirectory(resourceName: resourceName, fileManager: fileManager)
        let parent = activeDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let backup = parent.appendingPathComponent(".\(resourceName).previous-\(UUID().uuidString)", isDirectory: true)
        let hadActive = fileManager.fileExists(atPath: activeDirectory.path)
        if hadActive {
            try fileManager.moveItem(at: activeDirectory, to: backup)
        }

        do {
            try fileManager.moveItem(at: stagedDirectory, to: activeDirectory)
            if hadActive {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if hadActive, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: activeDirectory)
            }
            throw error
        }
    }

    public static func remove(
        resourceName: String = TransformerClassifierLoader.defaultResourceName,
        fileManager: FileManager = .default
    ) throws {
        let directory = modelDirectory(resourceName: resourceName, fileManager: fileManager)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    public static func tokenizerURL(
        for manifest: TransformerModelManifest,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        if let tokenizerArtifact = manifest.tokenizerArtifact {
            return artifactURL(named: tokenizerArtifact, in: directory, fileManager: fileManager)
        }
        guard let vocabularyArtifact = manifest.vocabularyArtifact else {
            return nil
        }
        return artifactURL(named: vocabularyArtifact, in: directory, fileManager: fileManager)
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

    public static func fileSHA256(at url: URL) throws -> String {
        #if canImport(CryptoKit)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
            digest.update(data: try Data(contentsOf: file))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    private static func validateInstalledArtifacts(
        manifest: TransformerModelManifest,
        directory: URL,
        modelURL: URL,
        fileManager: FileManager
    ) -> Bool {
        if let remoteArtifacts = manifest.remoteArtifacts {
            for artifact in remoteArtifacts {
                guard
                    let artifactURL = artifactURL(named: artifact.path, in: directory, fileManager: fileManager)
                else {
                    return false
                }
                if let expected = artifact.sha256, (try? fileSHA256(at: artifactURL)) != expected {
                    return false
                }
            }
        }

        if let expected = manifest.sha256 {
            return (try? directorySHA256(at: modelURL, fileManager: fileManager)) == expected
        }
        return true
    }
}
