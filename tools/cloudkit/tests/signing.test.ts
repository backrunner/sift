import { strict as assert } from "node:assert";
import { createHash, createVerify, generateKeyPairSync } from "node:crypto";
import { test } from "node:test";
import { cloudKitDate, queryAllRecords, signPayload, signedHeaders } from "../cloudkit-request.ts";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const privateKeyPem = privateKey.export({ type: "sec1", format: "pem" }).toString();

test("cloudKitDate uses seconds precision with Z suffix", () => {
  const date = cloudKitDate(new Date("2026-07-04T08:09:10.123Z"));
  assert.equal(date, "2026-07-04T08:09:10Z");
});

test("signPayload produces a verifiable ECDSA signature over date:bodyHash:path", () => {
  const body = JSON.stringify({ query: { recordType: "SmsSample" } });
  const path = "/database/1/iCloud.test/development/public/records/query";
  const date = "2026-07-04T08:09:10Z";

  const signature = signPayload({ keyId: "key", privateKeyPem }, date, body, path);

  const bodyHash = createHash("sha256").update(body, "utf8").digest("base64");
  const verified = createVerify("sha256")
    .update([date, bodyHash, path].join(":"), "utf8")
    .verify(publicKey, signature, "base64");
  assert.equal(verified, true);
});

test("signedHeaders carries key id, date, and signature", () => {
  const headers = signedHeaders({ keyId: "abc123", privateKeyPem }, "{}", "/database/1/x/y/public/records/query");
  assert.equal(headers["X-Apple-CloudKit-Request-KeyID"], "abc123");
  assert.match(headers["X-Apple-CloudKit-Request-ISO8601Date"] ?? "", /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.ok((headers["X-Apple-CloudKit-Request-SignatureV1"] ?? "").length > 0);
});

test("queryAllRecords follows continuation markers and respects maxRecords", async () => {
  const pages = [
    { records: [record("a"), record("b")], continuationMarker: "next" },
    { records: [record("c")], continuationMarker: undefined },
  ];
  let call = 0;
  const fetchImpl: typeof fetch = async () => {
    const page = pages[call];
    call += 1;
    return new Response(JSON.stringify(page), { status: 200 });
  };

  const records = await queryAllRecords(
    {
      container: "iCloud.test",
      environment: "development",
      credentials: { keyId: "key", privateKeyPem },
      fetchImpl,
    },
    { recordType: "SmsSample" },
  );

  assert.equal(call, 2);
  assert.deepEqual(
    records.map((item) => item.recordName),
    ["a", "b", "c"],
  );
});

test("queryAllRecords surfaces server errors", async () => {
  const fetchImpl: typeof fetch = async () =>
    new Response(JSON.stringify({ serverErrorCode: "AUTHENTICATION_FAILED", reason: "bad key" }), { status: 401 });

  await assert.rejects(
    queryAllRecords(
      {
        container: "iCloud.test",
        environment: "development",
        credentials: { keyId: "key", privateKeyPem },
        fetchImpl,
      },
      { recordType: "SmsSample" },
    ),
    /AUTHENTICATION_FAILED/,
  );
});

function record(name: string) {
  return {
    recordName: name,
    recordType: "SmsSample",
    fields: { text: { value: "hello world sample" }, label: { value: "spam" } },
  };
}
