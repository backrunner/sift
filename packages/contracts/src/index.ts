import { assertLeafLabel, groupForLabel, systemActionForLabel, type SystemAction } from "@sift/taxonomy";

export const submissionSchemaVersion = 1;
export const maxSubmissionTextLength = 2000;

export interface SubmissionRequest {
  readonly text: string;
  readonly label: string;
  readonly source?: "local" | "remote";
  readonly modelVersion?: string;
  readonly schemaVersion?: number;
}

export interface NormalizedSubmission {
  readonly text: string;
  readonly label: string;
  readonly labelGroupId: string;
  readonly labelGroupTitle: string;
  readonly systemAction: SystemAction;
  readonly source: "local" | "remote";
  readonly modelVersion: string | null;
  readonly schemaVersion: number;
}

/**
 * Framework-neutral training example shared by local corpora and toB exports.
 * Keep persisted datasets in this simple text/label shape; trainers should
 * adapt it to Core ML, PyTorch, or another backend at the point of use.
 */
export interface TrainingSetRow {
  readonly text: string;
  readonly label: string;
}

export interface SubmissionError {
  readonly code:
    | "missing_text"
    | "missing_label"
    | "text_too_long"
    | "unknown_label"
    | "invalid_schema";
  readonly message: string;
}

export function normalizeSubmission(input: SubmissionRequest): NormalizedSubmission {
  const error = validateSubmission(input);
  if (error) {
    throw new Error(`${error.code}: ${error.message}`);
  }

  const group = groupForLabel(input.label)!;

  return {
    text: input.text.trim(),
    label: assertLeafLabel(input.label),
    labelGroupId: group.id,
    labelGroupTitle: group.title,
    systemAction: systemActionForLabel(input.label),
    source: input.source ?? "remote",
    modelVersion: input.modelVersion ?? null,
    schemaVersion: input.schemaVersion ?? submissionSchemaVersion
  };
}

export function validateSubmission(input: Partial<SubmissionRequest>): SubmissionError | null {
  if (typeof input.schemaVersion !== "undefined" && input.schemaVersion !== submissionSchemaVersion) {
    return {
      code: "invalid_schema",
      message: `Expected schema version ${submissionSchemaVersion}`
    };
  }

  if (typeof input.text !== "string" || input.text.trim().length === 0) {
    return {
      code: "missing_text",
      message: "Submission text is required"
    };
  }

  if (input.text.length > maxSubmissionTextLength) {
    return {
      code: "text_too_long",
      message: `Submission text must be at most ${maxSubmissionTextLength} characters`
    };
  }

  if (typeof input.label !== "string" || input.label.trim().length === 0) {
    return {
      code: "missing_label",
      message: "Submission label is required"
    };
  }

  if (!groupForLabel(input.label)) {
    return {
      code: "unknown_label",
      message: `Unknown label: ${input.label}`
    };
  }

  return null;
}

const forbiddenKeys = new Set([
  "sender",
  "senderHash",
  "deviceId",
  "idfa",
  "idfv",
  "userId",
  "account",
  "accountId",
  "phone",
  "email",
  "contact",
  "name"
]);

export function rejectIdentityFields(input: Record<string, unknown>): void {
  for (const key of Object.keys(input)) {
    if (forbiddenKeys.has(key)) {
      throw new Error(`Forbidden identity field present: ${key}`);
    }
  }
}

export function toExportLine(submission: NormalizedSubmission & { readonly receiptToken?: string }): string {
  return JSON.stringify({
    text: submission.text,
    label: submission.label,
    groupId: submission.labelGroupId,
    groupTitle: submission.labelGroupTitle,
    systemAction: submission.systemAction,
    source: submission.source,
    modelVersion: submission.modelVersion,
    schemaVersion: submission.schemaVersion,
    receiptToken: submission.receiptToken ?? null
  });
}

export function toTrainingSetLine(row: TrainingSetRow): string {
  // Do not add trainer-specific fields here. This payload is the portable
  // dataset contract consumed by Apple and future non-Apple training stacks.
  return JSON.stringify({
    text: row.text,
    label: assertLeafLabel(row.label)
  });
}
