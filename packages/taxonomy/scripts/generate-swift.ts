import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

interface RawLeaf {
  readonly id: string;
  readonly title: string;
  readonly titles?: Readonly<Record<string, string>>;
  readonly systemAction?: "transaction" | "promotion" | "junk";
}

interface RawGroup {
  readonly id: string;
  readonly title: string;
  readonly titles?: Readonly<Record<string, string>>;
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

function titlesDict(entry: { title: string; titles?: Readonly<Record<string, string>> }): string {
  const titles = entry.titles ?? { zh: entry.title };
  if (!titles.zh) {
    throw new Error(`Missing zh title for entry titled ${entry.title}`);
  }
  const pairs = ["zh", "en", "ja"]
    .filter((language) => titles[language])
    .map((language) => `${swiftString(language)}: ${swiftString(titles[language]!)}`);
  return `[${pairs.join(", ")}]`;
}

const groups = taxonomy.groups
  .map((group) => {
    const leaves = group.leaves
      .map(
        (leaf) => {
          const leafSystemAction = leaf.systemAction ?? group.systemAction;
          return `                .init(id: ${swiftString(leaf.id)}, titles: ${titlesDict(leaf)}, groupId: ${swiftString(group.id)}, groupTitles: ${titlesDict(group)}, systemAction: ${systemAction(leafSystemAction)})`;
        }
      )
      .join(",\n");

    return `        .init(
            id: ${swiftString(group.id)},
            titles: ${titlesDict(group)},
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
    /// Localized display names keyed by language (zh / en / ja).
    public let titles: [String: String]
    public let groupId: String
    public let groupTitles: [String: String]
    public let systemAction: SystemAction

    public init(id: String, titles: [String: String], groupId: String, groupTitles: [String: String], systemAction: SystemAction) {
        self.id = id
        self.titles = titles
        self.groupId = groupId
        self.groupTitles = groupTitles
        self.systemAction = systemAction
    }

    /// Display name in the user's preferred language (zh fallback).
    public var title: String {
        SiftTaxonomy.localizedTitle(from: titles)
    }

    public var groupTitle: String {
        SiftTaxonomy.localizedTitle(from: groupTitles)
    }
}

public struct LabelGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let titles: [String: String]
    public let systemAction: SystemAction
    public let leaves: [LeafLabel]

    public init(id: String, titles: [String: String], systemAction: SystemAction, leaves: [LeafLabel]) {
        self.id = id
        self.titles = titles
        self.systemAction = systemAction
        self.leaves = leaves
    }

    public var title: String {
        SiftTaxonomy.localizedTitle(from: titles)
    }
}

public enum SiftTaxonomy {
    /// Resolves a titles dictionary against the user's preferred languages
    /// (zh / en / ja supported; Chinese is the base language).
    public static func localizedTitle(
        from titles: [String: String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        for language in preferredLanguages {
            if language.hasPrefix("zh"), let title = titles["zh"] { return title }
            if language.hasPrefix("ja"), let title = titles["ja"] { return title }
            if language.hasPrefix("en"), let title = titles["en"] { return title }
        }
        return titles["zh"] ?? titles["en"] ?? titles.values.sorted().first ?? ""
    }

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
