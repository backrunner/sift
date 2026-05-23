import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index";

type DbMockState = {
  runs: Array<{ sql: string; bindings: unknown[] }>;
};

function createDbMock(rows: Record<string, unknown>[] = [], state: DbMockState = { runs: [] }): D1Database {
  return {
    prepare(sql: string) {
      let bindings: unknown[] = [];
      return {
        bind(...args: unknown[]) {
          bindings = args;
          return this;
        },
        async all() {
          return { results: rows, success: true, meta: { sql, bindings } };
        },
        async run() {
          state.runs.push({ sql, bindings });
          return { success: true, meta: { sql, bindings, changes: 1 } };
        }
      } as unknown as D1PreparedStatement;
    }
  } as unknown as D1Database;
}

function createBucketMock(
  objects: Map<string, string> = new Map(),
  uploadedAt: Map<string, Date> = new Map()
): R2Bucket {
  return {
    async put(key: string, value: string | ArrayBuffer | ArrayBufferView | ReadableStream<Uint8Array>) {
      if (typeof value === "string") {
        objects.set(key, value);
      } else if (value instanceof ArrayBuffer) {
        objects.set(key, new TextDecoder().decode(value));
      } else if (ArrayBuffer.isView(value)) {
        objects.set(key, new TextDecoder().decode(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)));
      } else {
        objects.set(key, await new Response(value).text());
      }
      return {
        key,
        size: objects.get(key)?.length ?? 0,
        etag: "etag",
        uploaded: new Date("2026-05-09T00:00:00Z")
      } as unknown as R2Object;
    },
    async get(key: string) {
      const value = objects.get(key);
      if (value == null) {
        return null;
      }
      return {
        key,
        size: value.length,
        etag: "etag",
        uploaded: uploadedAt.get(key) ?? new Date("2026-05-09T00:00:00Z"),
        httpMetadata: { contentType: "application/x-ndjson; charset=utf-8" },
        body: new Response(value).body
      } as unknown as R2ObjectBody;
    },
    async list(options?: { prefix?: string }) {
      const prefix = options?.prefix ?? "";
      return {
        objects: [...objects.entries()]
          .filter(([key]) => key.startsWith(prefix))
          .map(([key, value]) => ({
            key,
            size: value.length,
            uploaded: uploadedAt.get(key) ?? new Date("2026-05-09T00:00:00Z")
          })),
        truncated: false,
        cursor: ""
      } as unknown as R2Objects;
    },
    async delete(key: string) {
      objects.delete(key);
    }
  } as unknown as R2Bucket;
}

function createKvMock(store: Map<string, string> = new Map()): KVNamespace {
  return {
    async get(key: string, type?: "text" | "json" | "arrayBuffer") {
      const value = store.get(key);
      if (value == null) {
        return null;
      }
      if (type === "json") {
        return JSON.parse(value) as unknown;
      }
      return value;
    },
    async put(key: string, value: string | ArrayBuffer | ArrayBufferView | ReadableStream<Uint8Array>) {
      if (typeof value === "string") {
        store.set(key, value);
      } else if (value instanceof ArrayBuffer) {
        store.set(key, new TextDecoder().decode(value));
      } else if (ArrayBuffer.isView(value)) {
        store.set(key, new TextDecoder().decode(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)));
      } else {
        store.set(key, await new Response(value).text());
      }
      return;
    }
  } as unknown as KVNamespace;
}

test("health is public", async () => {
  const response = await worker.fetch(new Request("https://example.test/api/tob/health"), {
    DB: createDbMock(),
    SNAPSHOT_BUCKET: createBucketMock(),
    MODEL_MANIFEST: createKvMock(),
    MASTER_KEY: "secret",
    BASE_PATH: "/api/tob"
  });

  assert.equal(response.status, 200);
});

test("unauthenticated export is rejected", async () => {
  const response = await worker.fetch(new Request("https://example.test/api/tob/v1/export"), {
    DB: createDbMock(),
    SNAPSHOT_BUCKET: createBucketMock(),
    MODEL_MANIFEST: createKvMock(),
    MASTER_KEY: "secret",
    BASE_PATH: "/api/tob"
  });

  assert.equal(response.status, 401);
});

test("training set exports ndjson for apple trainer", async () => {
  const response = await worker.fetch(
    new Request("https://sift.alkinum.io/api/tob/v1/training-set?source=remote&label=verification&limit=1", {
      headers: { authorization: "Bearer secret" }
    }),
    {
      DB: createDbMock([
        {
          sanitized_text: "您的验证码是 {{CODE}}",
          label: "verification",
          group_id: "verification",
          group_title: "验证码",
          system_action: "transaction",
          source: "remote",
          model_version: "corpus-0.1",
          schema_version: 1,
          created_at: "2026-05-09T00:00:00Z"
        }
      ]),
      SNAPSHOT_BUCKET: createBucketMock(),
      MODEL_MANIFEST: createKvMock(),
      MASTER_KEY: "secret",
      BASE_PATH: "/api/tob"
    }
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "application/x-ndjson; charset=utf-8");
  assert.equal(response.headers.get("x-sift-row-count"), "1");

  const rows = (await response.text())
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as { text: string; label: string });

  assert.deepEqual(rows[0], { text: "您的验证码是 {{CODE}}", label: "verification" });
});

test("snapshot list and read work", async () => {
  const snapshots = new Map<string, string>([
    ["snapshots/2026-05-09T00-00-00Z.ndjson", "{\"text\":\"hi\",\"label\":\"verification\"}\n"]
  ]);

  const listResponse = await worker.fetch(
    new Request("https://sift.alkinum.io/api/tob/v1/snapshots", {
      headers: { authorization: "Bearer secret" }
    }),
    {
      DB: createDbMock(),
      SNAPSHOT_BUCKET: createBucketMock(snapshots),
      MODEL_MANIFEST: createKvMock(),
      MASTER_KEY: "secret",
      BASE_PATH: "/api/tob"
    }
  );

  assert.equal(listResponse.status, 200);
  const listBody = (await listResponse.json()) as { snapshots: Array<{ key: string }> };
  assert.equal(listBody.snapshots[0]?.key, "snapshots/2026-05-09T00-00-00Z.ndjson");

  const readResponse = await worker.fetch(
    new Request(
      "https://sift.alkinum.io/api/tob/v1/snapshots/" +
        encodeURIComponent("snapshots/2026-05-09T00-00-00Z.ndjson"),
      { headers: { authorization: "Bearer secret" } }
    ),
    {
      DB: createDbMock(),
      SNAPSHOT_BUCKET: createBucketMock(snapshots),
      MODEL_MANIFEST: createKvMock(),
      MASTER_KEY: "secret",
      BASE_PATH: "/api/tob"
    }
  );

  assert.equal(readResponse.status, 200);
  assert.match(await readResponse.text(), /"label":"verification"/);
});

test("model manifest can be written and read", async () => {
  const kv = createKvMock();

  const writeResponse = await worker.fetch(
    new Request("https://sift.alkinum.io/api/tob/v1/model/manifest", {
      method: "PUT",
      headers: {
        authorization: "Bearer secret",
        "content-type": "application/json"
      },
      body: JSON.stringify({ manifest: { version: "2026-05-09", state: "ready" } })
    }),
    {
      DB: createDbMock(),
      SNAPSHOT_BUCKET: createBucketMock(),
      MODEL_MANIFEST: kv,
      MASTER_KEY: "secret",
      BASE_PATH: "/api/tob"
    }
  );

  assert.equal(writeResponse.status, 200);
  const writeBody = (await writeResponse.json()) as { saved: boolean; key: string };
  assert.equal(writeBody.saved, true);
  assert.equal(writeBody.key, "current");

  const readResponse = await worker.fetch(
    new Request("https://sift.alkinum.io/api/tob/v1/model/manifest", {
      headers: { authorization: "Bearer secret" }
    }),
    {
      DB: createDbMock(),
      SNAPSHOT_BUCKET: createBucketMock(),
      MODEL_MANIFEST: kv,
      MASTER_KEY: "secret",
      BASE_PATH: "/api/tob"
    }
  );

  assert.equal(readResponse.status, 200);
  const readBody = (await readResponse.json()) as { key: string; manifest: { version: string } };
  assert.equal(readBody.key, "current");
  assert.equal(readBody.manifest.version, "2026-05-09");
});

test("retention run purges old sample rows and stale snapshots", async () => {
  const dbState: DbMockState = { runs: [] };
  const snapshots = new Map<string, string>([
    ["snapshots/old.ndjson", "{\"text\":\"old\",\"label\":\"verification\"}\n"],
    ["snapshots/fresh.ndjson", "{\"text\":\"fresh\",\"label\":\"verification\"}\n"]
  ]);
  const uploadedAt = new Map<string, Date>([
    ["snapshots/old.ndjson", new Date("2000-01-01T00:00:00Z")],
    ["snapshots/fresh.ndjson", new Date("2999-01-01T00:00:00Z")]
  ]);

  const response = await worker.fetch(
    new Request("https://sift.alkinum.io/api/tob/v1/retention/run", {
      method: "POST",
      headers: { authorization: "Bearer secret" }
    }),
    {
      DB: createDbMock([], dbState),
      SNAPSHOT_BUCKET: createBucketMock(snapshots, uploadedAt),
      MODEL_MANIFEST: createKvMock(),
      MASTER_KEY: "secret",
      BASE_PATH: "/api/tob",
      RETENTION_DAYS: "180",
      SNAPSHOT_RETENTION_DAYS: "30"
    }
  );

  assert.equal(response.status, 200);
  const body = (await response.json()) as {
    samples: { deleted: number };
    snapshots: { deleted: number };
  };
  assert.equal(body.samples.deleted, 1);
  assert.equal(body.snapshots.deleted, 1);
  assert.match(dbState.runs[0]?.sql ?? "", /^DELETE FROM samples/);
  assert.equal(snapshots.has("snapshots/old.ndjson"), false);
  assert.equal(snapshots.has("snapshots/fresh.ndjson"), true);
});
