/**
 * Export anonymous `SmsSample` records from the CloudKit public database into
 * the framework-neutral `{"text": ..., "label": ..., "textLanguage": ...}`
 * NDJSON corpus that
 * `tools/apple-trainer` and `tools/transformer-trainer` consume.
 *
 * Auth uses a CloudKit server-to-server key (CloudKit Console → API Access):
 *
 *   export CLOUDKIT_KEY_ID=<key id>
 *   export CLOUDKIT_PRIVATE_KEY=./eckey.pem
 *   pnpm export:training -- --env production --out ../../build/remote-training.ndjson
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";
import { queryAllRecords, type CloudKitRecord } from "./cloudkit-request.ts";

interface ExportOptions {
  container: string;
  environment: "development" | "production";
  keyId: string;
  privateKeyPath: string;
  outPath: string;
  raw: boolean;
  sinceMs: number | null;
  maxRecords: number;
  minLength: number;
  maxLength: number;
}

interface TrainingRow {
  readonly text: string;
  readonly label: string;
  readonly textLanguage: string | null;
}

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "../..");

function usage(): never {
  console.log(`Usage: pnpm export:training -- [options]

Options:
  --container <id>      CloudKit container. Defaults to iCloud.com.alkinum.sift
                        or $CLOUDKIT_CONTAINER.
  --env <name>          development | production. Defaults to development or
                        $CLOUDKIT_ENV.
  --key-id <id>         Server-to-server key id ($CLOUDKIT_KEY_ID).
  --key <path>          PEM private key path ($CLOUDKIT_PRIVATE_KEY).
  --out <path>          Output NDJSON. Defaults to build/remote-training.ndjson.
  --raw                 Keep all metadata columns instead of the training-safe
                        text/label/textLanguage rows.
  --since <iso-date>    Only export records with createdAt after this instant.
  --max <n>             Stop after n records (debugging).
  --min-length <n>      Drop rows shorter than n characters. Default 8.
  --max-length <n>      Drop rows longer than n characters. Default 500.
  --help                Show this message.`);
  process.exit(0);
}

function parseArguments(argv: readonly string[]): ExportOptions {
  const options: ExportOptions = {
    container: process.env.CLOUDKIT_CONTAINER ?? "iCloud.com.alkinum.sift",
    environment: (process.env.CLOUDKIT_ENV as ExportOptions["environment"]) ?? "development",
    keyId: process.env.CLOUDKIT_KEY_ID ?? "",
    privateKeyPath: process.env.CLOUDKIT_PRIVATE_KEY ?? "",
    outPath: resolve(repoRoot, "build/remote-training.ndjson"),
    raw: false,
    sinceMs: null,
    maxRecords: Number.POSITIVE_INFINITY,
    minLength: 8,
    maxLength: 500,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const next = (): string => {
      const value = argv[index + 1];
      if (value === undefined) {
        throw new Error(`Missing value after ${flag}`);
      }
      index += 1;
      return value;
    };

    switch (flag) {
      case "--container":
        options.container = next();
        break;
      case "--env": {
        const environment = next();
        if (environment !== "development" && environment !== "production") {
          throw new Error(`--env must be development or production, got ${environment}`);
        }
        options.environment = environment;
        break;
      }
      case "--key-id":
        options.keyId = next();
        break;
      case "--key":
        options.privateKeyPath = next();
        break;
      case "--out":
        options.outPath = resolve(process.cwd(), next());
        break;
      case "--raw":
        options.raw = true;
        break;
      case "--since": {
        const parsed = Date.parse(next());
        if (Number.isNaN(parsed)) {
          throw new Error("--since expects an ISO-8601 date");
        }
        options.sinceMs = parsed;
        break;
      }
      case "--max":
        options.maxRecords = Number.parseInt(next(), 10);
        break;
      case "--min-length":
        options.minLength = Number.parseInt(next(), 10);
        break;
      case "--max-length":
        options.maxLength = Number.parseInt(next(), 10);
        break;
      case "--help":
      case "-h":
        usage();
        break;
      default:
        throw new Error(`Unknown argument: ${flag}`);
    }
  }

  if (!options.keyId) {
    throw new Error("Missing server-to-server key id (--key-id or $CLOUDKIT_KEY_ID).");
  }
  if (!options.privateKeyPath) {
    throw new Error("Missing private key path (--key or $CLOUDKIT_PRIVATE_KEY).");
  }
  return options;
}

function loadTaxonomyLeafIds(): Set<string> {
  const taxonomyPath = resolve(repoRoot, "packages/taxonomy/taxonomy.json");
  const document = JSON.parse(readFileSync(taxonomyPath, "utf8")) as {
    groups: { leaves: { id: string }[] }[];
  };
  return new Set(document.groups.flatMap((group) => group.leaves.map((leaf) => leaf.id)));
}

function fieldString(record: CloudKitRecord, name: string): string | null {
  const value = record.fields[name]?.value;
  return typeof value === "string" ? value : null;
}

function fieldNumber(record: CloudKitRecord, name: string): number | null {
  const value = record.fields[name]?.value;
  if (typeof value === "number") {
    return value;
  }
  if (typeof value === "string" && value !== "" && !Number.isNaN(Number(value))) {
    return Number(value);
  }
  return null;
}

function normalizeText(text: string): string {
  return text.trim().replace(/\s+/g, " ");
}

async function main(): Promise<void> {
  const options = parseArguments(process.argv.slice(2));
  const privateKeyPem = readFileSync(resolve(process.cwd(), options.privateKeyPath), "utf8");
  const validLabels = loadTaxonomyLeafIds();

  const query: Record<string, unknown> = {
    recordType: "SmsSample",
    sortBy: [{ fieldName: "createdAt", ascending: true }],
    ...(options.sinceMs !== null
      ? {
          filterBy: [
            {
              fieldName: "createdAt",
              comparator: "GREATER_THAN",
              fieldValue: { value: options.sinceMs, type: "INT64" },
            },
          ],
        }
      : {}),
  };

  console.log(`querying ${options.container} (${options.environment}) ...`);
  const records = await queryAllRecords(
    {
      container: options.container,
      environment: options.environment,
      credentials: { keyId: options.keyId, privateKeyPem },
    },
    query,
    options.maxRecords,
  );

  const seen = new Set<string>();
  const rows: (TrainingRow & Record<string, unknown>)[] = [];
  let unknownLabel = 0;
  let badLength = 0;
  let duplicates = 0;

  for (const record of records) {
    const text = normalizeText(fieldString(record, "text") ?? "");
    const label = fieldString(record, "label") ?? "";

    if (!validLabels.has(label)) {
      unknownLabel += 1;
      continue;
    }
    if (text.length < options.minLength || text.length > options.maxLength) {
      badLength += 1;
      continue;
    }
    const dedupeKey = `${label}\u{1F}${text}`;
    if (seen.has(dedupeKey)) {
      duplicates += 1;
      continue;
    }
    seen.add(dedupeKey);

    rows.push(
      options.raw
        ? {
            text,
            label,
            labelGroup: fieldString(record, "labelGroup"),
            locale: fieldString(record, "locale"),
            textLanguage: fieldString(record, "textLanguage"),
            modelVersion: fieldString(record, "modelVersion"),
            predictedLabel: fieldString(record, "predictedLabel"),
            predictedConfidence: fieldNumber(record, "predictedConfidence"),
            agreement: fieldNumber(record, "agreement"),
            schemaVersion: fieldNumber(record, "schemaVersion"),
            createdAt: fieldNumber(record, "createdAt"),
            recordName: record.recordName,
          }
        : { text, label, textLanguage: fieldString(record, "textLanguage") },
    );
  }

  if (!existsSync(dirname(options.outPath))) {
    mkdirSync(dirname(options.outPath), { recursive: true });
  }
  const payload = rows.length > 0 ? rows.map((row) => JSON.stringify(row)).join("\n") + "\n" : "";
  writeFileSync(options.outPath, payload, "utf8");

  const distribution = new Map<string, number>();
  for (const row of rows) {
    distribution.set(row.label, (distribution.get(row.label) ?? 0) + 1);
  }

  console.log(`fetched records: ${records.length}`);
  console.log(`exported rows:   ${rows.length}`);
  console.log(`skipped:         ${unknownLabel} unknown-label, ${badLength} bad-length, ${duplicates} duplicate`);
  console.log(`output:          ${options.outPath}`);
  console.log("label distribution:");
  for (const [label, count] of [...distribution.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${label}: ${count}`);
  }
}

main().catch((error: unknown) => {
  console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
