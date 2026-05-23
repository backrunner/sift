import test from "node:test";
import assert from "node:assert/strict";
import { sanitizeSubmissionText } from "../src/sanitize";

test("sanitizes phone, url, and amount", () => {
  const input = "请致电 13800138000，访问 https://example.com，金额 ¥128.50";
  const output = sanitizeSubmissionText(input);
  assert.match(output, /{{PHONE}}/);
  assert.match(output, /{{URL}}/);
  assert.match(output, /{{AMOUNT}}/);
});

