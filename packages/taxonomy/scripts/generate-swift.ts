import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

interface RawLeaf {
  readonly id: string;
  readonly title: string;
}

interface RawGroup {
  readonly id: string;
  readonly title: string;
  readonly systemAction: "transaction" | "promotion" | "junk";
  readonly leaves: readonly RawLeaf[];
}

interface RawTaxonomy {
  readonly groups: readonly RawGroup[];
}

const here = dirname(fileURLToPath(import.meta.url));
const taxonomyPath = resolve(here, "../taxonomy.json");
const outputPath = resolve(process.cwd(), process.argv[2] ?? "../../apps/ios/Sources/MessageFilterCore/Taxonomy.swift");
const taxonomy = JSON.parse(readFileSync(taxonomyPath, "utf8")) as RawTaxonomy;

function swiftString(value: string): string {
  return JSON.stringify(value);
}

function systemAction(value: string): string {
  return `.${value}`;
}

const groups = taxonomy.groups
  .map((group) => {
    const leaves = group.leaves
      .map(
        (leaf) =>
          `                .init(id: ${swiftString(leaf.id)}, title: ${swiftString(leaf.title)}, groupId: ${swiftString(group.id)}, groupTitle: ${swiftString(group.title)}, systemAction: ${systemAction(group.systemAction)})`
      )
      .join(",\n");

    return `        .init(
            id: ${swiftString(group.id)},
            title: ${swiftString(group.title)},
            systemAction: ${systemAction(group.systemAction)},
            leaves: [
${leaves}
            ]
        )`;
  })
  .join(",\n");

const source = `import Foundation

public enum SystemAction: String, Codable, Sendable {
    case none
    case transaction
    case promotion
    case junk
}

public struct LeafLabel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let groupId: String
    public let groupTitle: String
    public let systemAction: SystemAction
}

public struct LabelGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemAction: SystemAction
    public let leaves: [LeafLabel]
}

public enum SiftTaxonomy {
    public static let groups: [LabelGroup] = [
${groups}
    ]

    public static let leaves: [LeafLabel] = groups.flatMap(\\.leaves)
    public static let leafLookup: [String: LeafLabel] = Dictionary(uniqueKeysWithValues: leaves.map { ($0.id, $0) })

    public static func leaf(id: String) -> LeafLabel? {
        leafLookup[id]
    }

    public static func group(id: String) -> LabelGroup? {
        groups.first(where: { $0.id == id })
    }
}
`;

writeFileSync(outputPath, source);

