import { toExportLine, toTrainingSetLine } from "@sift/contracts";

export interface Env {
  readonly DB: D1Database;
  readonly SNAPSHOT_BUCKET: R2Bucket;
  readonly MODEL_MANIFEST?: KVNamespace;
  readonly MODEL_MANIFEST_KEY?: string;
  readonly MASTER_KEY: string;
  readonly RETENTION_DAYS?: string;
  readonly SNAPSHOT_RETENTION_DAYS?: string;
  /**
   * Path prefix this worker is mounted under, e.g. "/api/tob" when deployed at
   * https://sift.alkinum.io/api/tob/*. Empty string when the worker owns the
   * whole zone (local dev defaults to empty).
   */
  readonly BASE_PATH?: string;
}

type Json = Record<string, unknown>;

class HttpError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string
  ) {
    super(message);
  }
}

function json(body: Record<string, unknown>, init?: ResponseInit): Response {
  const headers = new Headers(init?.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("cache-control", "no-store");
  return new Response(JSON.stringify(body, null, 2), { ...init, headers });
}

function ndjson(body: string, rowCount: number): Response {
  return new Response(body + (body.length > 0 ? "\n" : ""), {
    headers: {
      "content-type": "application/x-ndjson; charset=utf-8",
      "cache-control": "no-store",
      "content-disposition": 'attachment; filename="sift-training-set.ndjson"',
      "x-sift-row-count": String(rowCount)
    }
  });
}

function requireAuth(request: Request, env: Env): boolean {
  const header = request.headers.get("authorization");
  return typeof env.MASTER_KEY === "string" && env.MASTER_KEY.length > 0 && header === `Bearer ${env.MASTER_KEY}`;
}

function routePath(url: URL, env: Env): string {
  const base = (env.BASE_PATH ?? "").replace(/\/+$/, "");
  if (base.length === 0) {
    return url.pathname;
  }
  if (url.pathname === base) {
    return "/";
  }
  if (url.pathname.startsWith(base + "/")) {
    return url.pathname.slice(base.length);
  }
  return url.pathname;
}

function optionalFilter(value: string | null, allowed: readonly string[], name: string): string | null {
  if (value === null || value.length === 0) {
    return null;
  }
  if (!allowed.includes(value)) {
    throw new Error(`invalid_${name}`);
  }
  return value;
}

function limitFromUrl(url: URL): number | null {
  const rawLimit = url.searchParams.get("limit");
  if (rawLimit === null || rawLimit.length === 0) {
    return null;
  }
  const limit = Number(rawLimit);
  if (!Number.isInteger(limit) || limit <= 0 || limit > 50_000) {
    throw new HttpError(400, "invalid_limit", "limit must be an integer between 1 and 50000");
  }
  return limit;
}

function retentionDays(value: string | undefined, fallback: number, name: string): number {
  if (value == null || value.trim().length === 0) {
    return fallback;
  }
  const days = Number(value);
  if (!Number.isInteger(days) || days <= 0 || days > 3650) {
    throw new HttpError(500, "invalid_retention_config", `${name} must be an integer between 1 and 3650`);
  }
  return days;
}

function cutoffIso(days: number, now = new Date()): string {
  return new Date(now.getTime() - days * 24 * 60 * 60 * 1000).toISOString();
}

function snapshotKeyFromPath(path: string): string {
  const encoded = path.slice("/v1/snapshots/".length);
  const key = decodeURIComponent(encoded);
  if (!key.startsWith("snapshots/") || key.includes("..")) {
    throw new HttpError(400, "invalid_snapshot_key", "snapshot key must be under snapshots/");
  }
  return key;
}

async function readJson(request: Request): Promise<Json> {
  let value: unknown;
  try {
    value = await request.json();
  } catch {
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpError(400, "invalid_json", "Request body must be a JSON object");
  }
  return value as Json;
}

async function querySampleRows(env: Env, url: URL): Promise<Record<string, unknown>[]> {
  const source = optionalFilter(url.searchParams.get("source"), ["remote", "local"], "source");
  const label = url.searchParams.get("label");
  const groupId = url.searchParams.get("groupId");
  const limit = limitFromUrl(url);

  const clauses = ["deleted_at IS NULL"];
  const bindings: Array<string | number> = [];

  if (source) {
    clauses.push("source = ?");
    bindings.push(source);
  }
  if (label) {
    clauses.push("label = ?");
    bindings.push(label);
  }
  if (groupId) {
    clauses.push("group_id = ?");
    bindings.push(groupId);
  }

  const sql = `SELECT sanitized_text, label, group_id, group_title, system_action, source, model_version, schema_version, created_at
     FROM samples
     WHERE ${clauses.join(" AND ")}
     ORDER BY created_at ASC${limit == null ? "" : " LIMIT ?"}`;
  if (limit != null) {
    bindings.push(limit);
  }

  const statement = env.DB.prepare(sql);
  const rows = bindings.length > 0 ? await statement.bind(...bindings).all() : await statement.all();
  return rows.results ?? [];
}

async function purgeOldSamples(env: Env): Promise<{ retentionDays: number; cutoff: string; deleted: number }> {
  const days = retentionDays(env.RETENTION_DAYS, 180, "RETENTION_DAYS");
  const cutoff = cutoffIso(days);
  const result = await env.DB.prepare(
    `DELETE FROM samples WHERE created_at < ? OR deleted_at IS NOT NULL`
  )
    .bind(cutoff)
    .run();

  return {
    retentionDays: days,
    cutoff,
    deleted: result.meta.changes ?? 0
  };
}

async function purgeOldSnapshots(env: Env): Promise<{ retentionDays: number; cutoff: string; deleted: number }> {
  const days = retentionDays(env.SNAPSHOT_RETENTION_DAYS, 30, "SNAPSHOT_RETENTION_DAYS");
  const cutoff = cutoffIso(days);
  const cutoffTime = Date.parse(cutoff);
  let cursor: string | undefined;
  let deleted = 0;

  do {
    const list = await env.SNAPSHOT_BUCKET.list({ prefix: "snapshots/", cursor });
    const staleKeys = list.objects
      .filter((object) => object.uploaded != null && object.uploaded.getTime() < cutoffTime)
      .map((object) => object.key);

    await Promise.all(staleKeys.map((key) => env.SNAPSHOT_BUCKET.delete(key)));
    deleted += staleKeys.length;
    cursor = list.truncated ? list.cursor : undefined;
  } while (cursor);

  return {
    retentionDays: days,
    cutoff,
    deleted
  };
}

async function runRetention(env: Env): Promise<{ samples: Awaited<ReturnType<typeof purgeOldSamples>>; snapshots: Awaited<ReturnType<typeof purgeOldSnapshots>> }> {
  const [samples, snapshots] = await Promise.all([
    purgeOldSamples(env),
    purgeOldSnapshots(env)
  ]);
  return { samples, snapshots };
}

function toExportPayload(rows: Record<string, unknown>[]): string {
  return rows
    .map((row) =>
      toExportLine({
        text: String(row.sanitized_text),
        label: String(row.label),
        labelGroupId: String(row.group_id),
        labelGroupTitle: String(row.group_title),
        systemAction: String(row.system_action) as "transaction" | "promotion" | "junk" | "none",
        source: String(row.source) as "local" | "remote",
        modelVersion: row.model_version == null ? null : String(row.model_version),
        schemaVersion: Number(row.schema_version)
      })
    )
    .join("\n");
}

function toTrainingSetPayload(rows: Record<string, unknown>[]): string {
  // Keep worker-exported training data backend-neutral; model-specific
  // conversion belongs in the trainer that consumes this NDJSON.
  return rows
    .map((row) =>
      toTrainingSetLine({
        text: String(row.sanitized_text),
        label: String(row.label)
      })
    )
    .join("\n");
}

function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return json({ error: error.code, message: error.message }, { status: error.status });
  }

  if (error instanceof Error && error.message === "invalid_source") {
    return json({ error: "invalid_source", message: "source must be remote or local" }, { status: 400 });
  }

  return json({ error: "internal_error" }, { status: 500 });
}

async function handleRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = routePath(url, env);

  if (path === "/health") {
    return json({ ok: true, service: "tob" });
  }

  if (!requireAuth(request, env)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  if (path === "/" && request.method === "GET") {
    return json({
      service: "tob",
      domain: "sift.alkinum.io",
      basePath: env.BASE_PATH ?? "",
      endpoints: {
        health: "/health",
        stats: "/v1/stats",
        export: "/v1/export",
        trainingSet: "/v1/training-set",
        snapshots: "/v1/snapshots",
        modelManifest: "/v1/model/manifest"
      }
    });
  }

  if (path === "/v1/stats" && request.method === "GET") {
    const rows = await env.DB.prepare(
      `SELECT label, group_id, group_title, system_action, source, COUNT(*) AS count
       FROM samples
       WHERE deleted_at IS NULL
       GROUP BY label, group_id, group_title, system_action, source
       ORDER BY count DESC, label ASC, source ASC`
    ).all();
    return json({ rows: rows.results ?? [] });
  }

  if (path === "/v1/export" && request.method === "GET") {
    const rows = await querySampleRows(env, url);
    const payload = toExportPayload(rows);

    return new Response(payload + (payload.length > 0 ? "\n" : ""), {
      headers: {
        "content-type": "application/x-ndjson; charset=utf-8",
        "cache-control": "no-store",
        "x-sift-row-count": String(rows.length)
      }
    });
  }

  if (path === "/v1/training-set" && request.method === "GET") {
    const rows = await querySampleRows(env, url);
    const payload = toTrainingSetPayload(rows);

    return ndjson(payload, rows.length);
  }

  if (path === "/v1/snapshots" && request.method === "GET") {
    const list = await env.SNAPSHOT_BUCKET.list({ prefix: "snapshots/" });
    return json({
      snapshots: list.objects.map((object) => ({
        key: object.key,
        size: object.size,
        uploaded: object.uploaded?.toISOString() ?? null
      }))
    });
  }

  if (path === "/v1/snapshots" && request.method === "POST") {
    const rows = await querySampleRows(env, url);
    const createdAt = new Date().toISOString().replace(/[:.]/g, "-");
    const key = `snapshots/${createdAt}.ndjson`;
    const payload = toExportPayload(rows);

    await env.SNAPSHOT_BUCKET.put(key, payload + "\n", {
      httpMetadata: { contentType: "application/x-ndjson; charset=utf-8" }
    });

    return json({
      snapshotKey: key,
      rowCount: rows.length
    });
  }

  if (path === "/v1/retention/run" && request.method === "POST") {
    return json(await runRetention(env));
  }

  if (path.startsWith("/v1/snapshots/") && request.method === "GET") {
    const key = snapshotKeyFromPath(path);
    const object = await env.SNAPSHOT_BUCKET.get(key);
    if (object == null) {
      return json({ error: "not_found" }, { status: 404 });
    }
    return new Response(object.body, {
      headers: {
        "content-type": object.httpMetadata?.contentType ?? "application/x-ndjson; charset=utf-8",
        "cache-control": "no-store",
        "content-disposition": `attachment; filename="${key.split("/").at(-1) ?? "snapshot.ndjson"}"`
      }
    });
  }

  if (path === "/v1/model/manifest" && request.method === "GET") {
    const key = env.MODEL_MANIFEST_KEY ?? "current";
    const manifest = env.MODEL_MANIFEST ? await env.MODEL_MANIFEST.get(key, "json") : null;
    return json({ key, manifest });
  }

  if (path === "/v1/model/manifest" && request.method === "PUT") {
    if (!env.MODEL_MANIFEST) {
      throw new HttpError(501, "model_manifest_not_configured", "MODEL_MANIFEST KV binding is not configured");
    }
    const payload = await readJson(request);
    const key = typeof payload.key === "string" && payload.key.trim().length > 0
      ? payload.key.trim()
      : env.MODEL_MANIFEST_KEY ?? "current";
    const manifest = payload.manifest ?? payload;
    await env.MODEL_MANIFEST.put(key, JSON.stringify(manifest, null, 2), {
      metadata: { updatedAt: new Date().toISOString() }
    });
    return json({ saved: true, key });
  }

  return json({ error: "not_found" }, { status: 404 });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handleRequest(request, env);
    } catch (error) {
      return errorResponse(error);
    }
  },

  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runRetention(env));
  }
} satisfies ExportedHandler<Env>;
