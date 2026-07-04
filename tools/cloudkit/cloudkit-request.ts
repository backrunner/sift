import { createHash, createSign } from "node:crypto";

/**
 * CloudKit Web Services server-to-server request signing.
 *
 * Apple's scheme: sign `${date}:${base64(sha256(body))}:${path}` with the
 * ECDSA P-256 private key registered in the CloudKit Console, then send the
 * key id, date, and base64 DER signature as request headers.
 */

export interface CloudKitCredentials {
  readonly keyId: string;
  /** PEM-encoded EC private key (`ecdsa-key.pem` from the CloudKit Console). */
  readonly privateKeyPem: string;
}

/** CloudKit expects seconds precision without fractional part. */
export function cloudKitDate(now: Date = new Date()): string {
  return `${now.toISOString().slice(0, 19)}Z`;
}

export function signPayload(
  credentials: CloudKitCredentials,
  date: string,
  body: string,
  path: string,
): string {
  const bodyHash = createHash("sha256").update(body, "utf8").digest("base64");
  const message = [date, bodyHash, path].join(":");
  return createSign("sha256").update(message, "utf8").sign(credentials.privateKeyPem, "base64");
}

export function signedHeaders(
  credentials: CloudKitCredentials,
  body: string,
  path: string,
  now: Date = new Date(),
): Record<string, string> {
  const date = cloudKitDate(now);
  return {
    "X-Apple-CloudKit-Request-KeyID": credentials.keyId,
    "X-Apple-CloudKit-Request-ISO8601Date": date,
    "X-Apple-CloudKit-Request-SignatureV1": signPayload(credentials, date, body, path),
    "Content-Type": "application/json",
  };
}

export interface CloudKitQueryOptions {
  readonly container: string;
  readonly environment: "development" | "production";
  readonly credentials: CloudKitCredentials;
  readonly baseUrl?: string;
  readonly fetchImpl?: typeof fetch;
}

export interface CloudKitRecordField {
  readonly value: unknown;
  readonly type?: string;
}

export interface CloudKitRecord {
  readonly recordName: string;
  readonly recordType: string;
  readonly created?: { readonly timestamp?: number };
  readonly fields: Readonly<Record<string, CloudKitRecordField>>;
}

interface QueryResponse {
  readonly records?: readonly CloudKitRecord[];
  readonly continuationMarker?: string;
  readonly serverErrorCode?: string;
  readonly reason?: string;
}

/**
 * Runs a public-database records/query and follows continuation markers until
 * the result set is exhausted (or `maxRecords` is reached).
 */
export async function queryAllRecords(
  options: CloudKitQueryOptions,
  query: Record<string, unknown>,
  maxRecords: number = Number.POSITIVE_INFINITY,
): Promise<CloudKitRecord[]> {
  const base = options.baseUrl ?? "https://api.apple-cloudkit.com";
  const path = `/database/1/${options.container}/${options.environment}/public/records/query`;
  const fetchImpl = options.fetchImpl ?? fetch;
  const records: CloudKitRecord[] = [];
  let continuationMarker: string | undefined;

  do {
    const body = JSON.stringify({
      zoneID: { zoneName: "_defaultZone" },
      resultsLimit: Math.min(200, Math.max(1, maxRecords - records.length)),
      query,
      ...(continuationMarker ? { continuationMarker } : {}),
    });

    const response = await fetchImpl(`${base}${path}`, {
      method: "POST",
      headers: signedHeaders(options.credentials, body, path),
      body,
    });

    const payload = (await response.json()) as QueryResponse;
    if (!response.ok || payload.serverErrorCode) {
      const detail = payload.serverErrorCode
        ? `${payload.serverErrorCode}: ${payload.reason ?? "unknown reason"}`
        : `HTTP ${response.status}`;
      throw new Error(`CloudKit query failed (${detail})`);
    }

    records.push(...(payload.records ?? []));
    continuationMarker = payload.continuationMarker;
  } while (continuationMarker && records.length < maxRecords);

  return records.slice(0, Number.isFinite(maxRecords) ? maxRecords : records.length);
}
