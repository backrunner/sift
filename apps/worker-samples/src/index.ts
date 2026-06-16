import { normalizeSubmission, rejectIdentityFields, submissionSchemaVersion } from "@sift/contracts";
import { systemActionForLabel, taxonomyDocument } from "@sift/taxonomy";
import { sanitizeSubmissionText } from "./sanitize";

export interface Env {
  readonly DB: D1Database;
  readonly MODEL_MANIFEST_KEY: string;
  readonly MODEL_MANIFEST?: KVNamespace;
  /**
   * Optional mount path when sharing an origin. Production owns the API subdomain
   * root and leaves this empty.
   * Empty in local development when the worker owns the whole localhost origin.
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

function corsHeaders(init?: HeadersInit): Headers {
  const headers = new Headers(init);
  headers.set("access-control-allow-origin", "*");
  headers.set("access-control-allow-methods", "GET,POST,DELETE,OPTIONS");
  headers.set("access-control-allow-headers", "content-type, authorization");
  headers.set("access-control-max-age", "86400");
  return headers;
}

function json(body: Json, init?: ResponseInit): Response {
  const headers = corsHeaders(init?.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body, null, 2), { ...init, headers });
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

async function hashReceiptToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
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

function withTimestamp(): string {
  return new Date().toISOString();
}

function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return json({ error: error.code, message: error.message }, { status: error.status });
  }

  return json({ error: "internal_error" }, { status: 500 });
}

async function handleRequest(request: Request, env: Env): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  const url = new URL(request.url);
  const path = routePath(url, env);

  if (path === "/" && request.method === "GET") {
    return json({
      service: "samples",
      domain: "api.sift.alkinum.io",
      basePath: env.BASE_PATH ?? "",
      endpoints: {
        health: "/health",
        taxonomy: "/v1/taxonomy",
        modelManifest: "/v1/model/manifest",
        samples: "/v1/samples"
      }
    });
  }

  if (path === "/health") {
    return json({ ok: true, service: "samples" });
  }

  if (path === "/v1/taxonomy" && request.method === "GET") {
    return json({ taxonomy: taxonomyDocument });
  }

  if (path === "/v1/model/manifest" && request.method === "GET") {
    const key = env.MODEL_MANIFEST_KEY ?? "current";
    const manifest = env.MODEL_MANIFEST ? await env.MODEL_MANIFEST.get(key, "json") : null;
    return json({ key, manifest });
  }

  if (path === "/v1/samples" && request.method === "POST") {
    const payload = await readJson(request);
    try {
      rejectIdentityFields(payload);
    } catch (error) {
      throw new HttpError(
        400,
        "identity_field_forbidden",
        error instanceof Error ? error.message : "Identity fields are not accepted"
      );
    }

    try {
      const submission = normalizeSubmission({
        text: String(payload.text ?? ""),
        label: String(payload.label ?? ""),
        source: "remote",
        modelVersion: typeof payload.modelVersion === "string" ? payload.modelVersion : undefined,
        schemaVersion: typeof payload.schemaVersion === "number" ? payload.schemaVersion : submissionSchemaVersion
      });

      const sanitizedText = sanitizeSubmissionText(submission.text);
      const receiptToken = crypto.randomUUID();
      const receiptHash = await hashReceiptToken(receiptToken);
      const id = crypto.randomUUID();
      const now = withTimestamp();

      await env.DB.prepare(
        `INSERT INTO samples
          (id, receipt_hash, sanitized_text, label, group_id, group_title, system_action, source, model_version, schema_version, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
        .bind(
          id,
          receiptHash,
          sanitizedText,
          submission.label,
          submission.labelGroupId,
          submission.labelGroupTitle,
          systemActionForLabel(submission.label),
          submission.source,
          submission.modelVersion,
          submission.schemaVersion,
          now
        )
        .run();

      return json(
        {
          accepted: true,
          receiptToken,
          sanitizedTextPreview: sanitizedText,
          schemaVersion: submission.schemaVersion,
          label: submission.label,
          groupId: submission.labelGroupId,
          systemAction: submission.systemAction
        },
        { status: 201 }
      );
    } catch (error) {
      if (error instanceof Error) {
        const code = error.message.split(":")[0] ?? "invalid_submission";
        throw new HttpError(400, code, error.message);
      }
      throw error;
    }
  }

  if (path.startsWith("/v1/samples/") && request.method === "GET") {
    const receiptToken = decodeURIComponent(path.slice("/v1/samples/".length));
    if (receiptToken.length === 0) {
      throw new HttpError(400, "missing_receipt_token", "Receipt token is required");
    }
    const receiptHash = await hashReceiptToken(receiptToken);
    const row = await env.DB.prepare(
      `SELECT deleted_at FROM samples WHERE receipt_hash = ?`
    )
      .bind(receiptHash)
      .first<{ deleted_at: string | null }>();

    return json({
      found: row != null,
      deleted: row?.deleted_at != null
    });
  }

  if (path.startsWith("/v1/samples/") && request.method === "DELETE") {
    const receiptToken = decodeURIComponent(path.slice("/v1/samples/".length));
    if (receiptToken.length === 0) {
      throw new HttpError(400, "missing_receipt_token", "Receipt token is required");
    }
    const receiptHash = await hashReceiptToken(receiptToken);
    const result = await env.DB.prepare(
      `DELETE FROM samples WHERE receipt_hash = ?`
    )
      .bind(receiptHash)
      .run();

    return json({
      deleted: (result.meta.changes ?? 0) > 0
    });
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
  }
} satisfies ExportedHandler<Env>;
