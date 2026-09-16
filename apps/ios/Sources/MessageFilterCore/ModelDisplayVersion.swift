import Foundation

/// Presentation only. Never use these labels as artifact identities or paths.
public enum ModelDisplayVersion {
    public static func classic(_ manifest: ModelManifest) -> String {
        if let version = manifest.displayVersion, isValid(version) { return version }
        if manifest.version == "maxent-generalization-v50-seed29-r32" { return "1.0" }
        if isValid(manifest.version) { return manifest.version }
        return String(manifest.sha256.prefix(8))
    }

    public static func transformer(modelABI: String, releaseSequence: Int) -> String {
        let generation = modelABI == MappedTokenEmbedding.modelABI ? 2 : 1
        return "\(generation).\(releaseSequence)"
    }

    public static func isValid(_ version: String) -> Bool {
        version.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$"#, options: .regularExpression) != nil
    }
}
