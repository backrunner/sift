import taxonomy from "../taxonomy.json" with { type: "json" };

export type SystemAction = "none" | "transaction" | "promotion" | "junk";

export interface LeafLabel {
  readonly id: string;
  readonly title: string;
  readonly groupId: string;
  readonly groupTitle: string;
  readonly systemAction: Exclude<SystemAction, "none">;
}

export interface LabelGroup {
  readonly id: string;
  readonly title: string;
  readonly systemAction: Exclude<SystemAction, "none">;
  readonly leaves: readonly LeafLabel[];
}

export interface TaxonomyDocument {
  readonly schemaVersion: number;
  readonly groups: readonly LabelGroup[];
}

interface RawLeafLabel {
  readonly id: string;
  readonly title: string;
}

interface RawLabelGroup {
  readonly id: string;
  readonly title: string;
  readonly systemAction: Exclude<SystemAction, "none">;
  readonly leaves: readonly RawLeafLabel[];
}

interface RawTaxonomyDocument {
  readonly schemaVersion: number;
  readonly groups: readonly RawLabelGroup[];
}

const rawDocument = taxonomy as RawTaxonomyDocument;

const document: TaxonomyDocument = {
  schemaVersion: rawDocument.schemaVersion,
  groups: rawDocument.groups.map((group) => ({
    ...group,
    leaves: group.leaves.map((leaf) => ({
      ...leaf,
      groupId: group.id,
      groupTitle: group.title,
      systemAction: group.systemAction
    }))
  }))
};

export const taxonomyDocument = document;

export const labelGroups = document.groups;

export const leafLabels = document.groups.flatMap((group) => group.leaves);

export const leafLabelMap = new Map(leafLabels.map((label) => [label.id, label] as const));

export function isLeafLabel(id: string): id is string {
  return leafLabelMap.has(id);
}

export function assertLeafLabel(id: string): string {
  if (!isLeafLabel(id)) {
    throw new Error(`Unknown leaf label: ${id}`);
  }
  return id;
}

export function groupForLabel(id: string): LabelGroup | undefined {
  return document.groups.find((group) => group.leaves.some((leaf) => leaf.id === id));
}

export function systemActionForLabel(id: string, confidence = 1): SystemAction {
  if (confidence < 0.6) {
    return "none";
  }

  const label = leafLabelMap.get(id);
  if (!label) {
    return "none";
  }

  return label.systemAction;
}
