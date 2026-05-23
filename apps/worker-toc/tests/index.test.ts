import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index";

type MockState = {
  lastSql?: string;
  lastBindings?: unknown[];
  deletedAt?: string | null;
  receiptRow?: { deleted_at: string | null } | null;
};

function createDbMock(state: MockState = {}): D1Database {
  return {
    prepare(sql: string) {
      let bindings: unknown[] = [];
      return {
        bind(...args: unknown[]) {
          bindings = args;
          state.lastSql = sql;
          state.lastBindings = args;
          return this;
        },
        async all() {
          return { results: [], success: true, meta: { sql, bindings } };
        },
        async first() {
          return state.receiptRow ?? null;
        },
        async run() {
          state.deletedAt = new Date().toISOString();
          return { success: true, meta: { sql, bindings, changes: 1 } };
        }
      } as unknown as D1PreparedStatement;
    }
  } as unknown as D1Database;
}

test("public worker uses /api/toc base path and forces remote submissions", async () => {
  const state: MockState = {};
  const response = await worker.fetch(
    new Request("https://sift.alkinum.io/api/toc/v1/samples", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        text: "请致电 13800138000 完成验证",
        label: "verification",
        source: "local"
      })
    }),
    {
      DB: createDbMock(state),
      MODEL_MANIFEST_KEY: "current",
      MODEL_MANIFEST: {} as KVNamespace,
      BASE_PATH: "/api/toc"
    }
  );

  assert.equal(response.status, 201);
  const body = (await response.json()) as { accepted: boolean; sanitizedTextPreview: string };
  assert.equal(body.accepted, true);
  assert.match(body.sanitizedTextPreview, /{{PHONE}}/);
  assert.equal(state.lastBindings?.[7], "remote");
});

test("public worker rejects identity fields", async () => {
  const response = await worker.fetch(
    new Request("https://sift.alkinum.io/api/toc/v1/samples", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        text: "验证码 123456",
        label: "verification",
        sender: "bank"
      })
    }),
    {
      DB: createDbMock(),
      MODEL_MANIFEST_KEY: "current",
      MODEL_MANIFEST: {} as KVNamespace,
      BASE_PATH: "/api/toc"
    }
  );

  assert.equal(response.status, 400);
  const body = (await response.json()) as { error: string };
  assert.equal(body.error, "identity_field_forbidden");
});

test("public worker exposes receipt status under the same base path", async () => {
  const response = await worker.fetch(
    new Request("https://sift.alkinum.io/api/toc/v1/samples/receipt-123"),
    {
      DB: createDbMock({ receiptRow: { deleted_at: null } }),
      MODEL_MANIFEST_KEY: "current",
      MODEL_MANIFEST: {} as KVNamespace,
      BASE_PATH: "/api/toc"
    }
  );

  assert.equal(response.status, 200);
  const body = (await response.json()) as { found: boolean; deleted: boolean };
  assert.equal(body.found, true);
  assert.equal(body.deleted, false);
});

test("public worker deletes receipt rows instead of keeping sample data", async () => {
  const state: MockState = {};
  const response = await worker.fetch(
    new Request("https://sift.alkinum.io/api/toc/v1/samples/receipt-123", { method: "DELETE" }),
    {
      DB: createDbMock(state),
      MODEL_MANIFEST_KEY: "current",
      MODEL_MANIFEST: {} as KVNamespace,
      BASE_PATH: "/api/toc"
    }
  );

  assert.equal(response.status, 200);
  const body = (await response.json()) as { deleted: boolean };
  assert.equal(body.deleted, true);
  assert.match(state.lastSql ?? "", /^DELETE FROM samples/);
});
