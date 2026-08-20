/**
 * Privacy second pass for CloudKit exports.
 *
 * This intentionally mirrors the conservative rules in
 * tools/pii-trainer/privacy_redaction.py and PrivacySanitizer.swift.  It is
 * kept dependency-free so an export can never depend on the model-training
 * environment.  Contextual identifiers (including QQ/WeChat handles) are
 * emitted as the existing {{ID}} token; the curation stage rehydrates tokens
 * with deterministic synthetic values before training.
 */

export type SensitiveKind =
  | "url"
  | "email"
  | "phone"
  | "card"
  | "id"
  | "address"
  | "order_id"
  | "amount"
  | "code"
  | "name";

export interface Redaction {
  readonly start: number;
  readonly end: number;
  readonly token: string;
  readonly kind: SensitiveKind;
}

export interface SanitizationResult {
  readonly text: string;
  readonly redactions: readonly Redaction[];
  readonly changed: boolean;
  readonly kinds: readonly SensitiveKind[];
}

const PLACEHOLDER = /\{\{(?:PHONE|URL|EMAIL|ADDRESS|CARD|ID|ORDER_ID|AMOUNT|CODE|PLATE|NAME)\}\}/g;
const TOKEN_PRIORITY = [
  "{{URL}}",
  "{{EMAIL}}",
  "{{PHONE}}",
  "{{CARD}}",
  "{{ID}}",
  "{{ADDRESS}}",
  "{{ORDER_ID}}",
  "{{AMOUNT}}",
  "{{CODE}}",
  "{{NAME}}",
] as const;

const URL = /(?<![A-Za-z0-9])https?:\/\/[^\s<>"'（）()\[\]{},，。！？；：、]+/giu;
const EMAIL = /(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?![A-Za-z0-9.-])/gu;
const PHONE = /(?<![\dA-Za-z])\+?\d[\d ()-]{5,}\d(?![\dA-Za-z])/gu;
const CARD = /(?<!\d)(?:\d[ -]?){15,18}\d(?!\d)/gu;
const CHINESE_ID = /(?<![0-9Xx])\d{6}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01])\d{3}[\dXx](?![0-9Xx])/gu;
const CHINESE_ID_OLD = /(?<!\d)\d{6}\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01])\d{3}(?!\d)/gu;
const PASSPORT = /(?<![A-Za-z0-9])[EG][A-Z]?\d{8}(?![A-Za-z0-9])/giu;
const ACCOUNT_ID = /(?:账号(?:\s*(?:id|编号|号码))?|账户(?:\s*(?:id|编号|号码))?|用户账号|客户账号|account\s+(?:id|number|no\.?)|user\s+(?:id|number|no\.?)|customer\s+(?:id|number|no\.?)|アカウント(?:\s*(?:ID|番号))?|ユーザー(?:\s*(?:ID|番号))|顧客番号|(?:account|user|customer)(?=\s*[:：=#]))\s*[:：=#]?\s*((?:[A-Za-z0-9][A-Za-z0-9_*.-]{2,}|[*#][A-Za-z0-9_*.-]{2,}))(?![A-Za-z0-9_*.-])/giu;
const ACCOUNT_SUFFIX = /(?:账户|账号|银行卡|信用卡)\s*尾号\s*([0-9]{4,8})(?!\d)/gu;
const RESOURCE_ID = /(?:实例\s*(?:ID|编号)|资源\s*(?:ID|编号)|项目\s*(?:ID|编号)|云数据库实例|database\s+instance|instance\s+id|resource\s+id|project\s+id|インスタンス\s*ID|リソース\s*ID|プロジェクト\s*ID)\s*[:：=#]?\s*([A-Za-z][A-Za-z0-9_-]{3,})(?![A-Za-z0-9_-])/giu;
const SOCIAL_ACCOUNT = /(?:QQ(?:\s*(?:号|号码|番号|账号|帐号|ID|number|account)|\s*[:：=])|微信(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|微博(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|小红书(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|抖音(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|快手(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|知乎(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|WeChat(?:\s*(?:ID|account|username))?|(?:LINE|Telegram|Discord|WhatsApp|Facebook|Instagram|TikTok|Twitter)\s*(?:ID|账号|帐号|username|handle|tag|account)|X\s*(?:ID|username|handle))\s*(?:是|为|：|:|=|#)?\s*(@?(?:[A-Za-z0-9][A-Za-z0-9_*#._-]{4,31}|[*#][A-Za-z0-9_*#._-]{4,31}))(?![A-Za-z0-9_*#._-])/giu;
const NICKNAME = /(?:(?:昵称|用户名|显示名|称呼|ニックネーム|ユーザー名|表示名)\s*[:：=]?|(?:nickname|username|display\s+name)\s*[:：=])\s*([^,，、。；;：:\n()（）]{1,40})/giu;
const AMOUNT = /(?:[¥￥$€£]|(?:RMB|CNY|USD|EUR|GBP|JPY)(?![A-Z]))\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d{1,2})?|(?<!\d)(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d{1,2})?\s*(?:元|块|円|USD|EUR|GBP|JPY)(?![A-Z])/giu;
const CODE = /(?:验证码|校验码|动态码|安全码|确认码|認証コード|確認コード|verification\s+code|security\s+code|one[- ]time\s+(?:code|password)|otp|passcode)\s*(?:是|为|：|:|is|は)?\s*([A-Z0-9-]{4,10})(?![A-Z0-9-])/giu;
const ORDER_ID = /(?:订单号|订单编号|运单号|快递单号|流水号|取件码|注文番号|追跡番号|order(?:\s+id|\s+number)?|tracking(?:\s+id|\s+number)?)\s*(?:是|为|：|:|#)?\s*([A-Z0-9-]{4,24})(?![A-Z0-9-])/giu;

function kindForToken(token: string): SensitiveKind {
  return token.slice(2, -2).toLowerCase() as SensitiveKind;
}

function makeRedaction(start: number, end: number, token: string): Redaction {
  return { start, end, token, kind: kindForToken(token) };
}

function regexRedactions(text: string, pattern: RegExp, token: string, group = 0): Redaction[] {
  pattern.lastIndex = 0;
  const result: Redaction[] = [];
  for (const match of text.matchAll(pattern)) {
    const value = match[group];
    const index = match.index;
    if (value === undefined || index === undefined) continue;
    // All non-zero groups in this module are trailing value captures. Using
    // lastIndexOf avoids replacing a repeated platform name in the context
    // (for example `WeChat ID: WeChat`) instead of the actual handle.
    const relativeStart = group === 0 ? 0 : match[0].lastIndexOf(value);
    if (relativeStart < 0) continue;
    const start = index + relativeStart;
    if (start < index || value.length === 0) continue;
    result.push(makeRedaction(start, start + value.length, token));
  }
  return result;
}

const CONTEXTUAL_STOPWORDS = new Set([
  "account", "active", "available", "online", "offline", "pending", "status",
  "number", "username", "handle", "music", "version", "is", "are", "none",
  "null", "已绑定", "已认证", "已登录", "状态", "可用", "在线", "离线",
]);

function plausibleContextualValue(value: string): boolean {
  const normalized = value.trim().toLocaleLowerCase();
  return normalized.length > 0
    && !CONTEXTUAL_STOPWORDS.has(normalized)
    && [...normalized].some((character) => /[\p{L}\p{N}]/u.test(character));
}

function contextualRegexRedactions(text: string, pattern: RegExp, token: string, group: number): Redaction[] {
  pattern.lastIndex = 0;
  const result: Redaction[] = [];
  for (const match of text.matchAll(pattern)) {
    const value = match[group];
    const index = match.index;
    if (value === undefined || index === undefined || !plausibleContextualValue(value)) continue;
    const relativeStart = group === 0 ? 0 : match[0].lastIndexOf(value);
    if (relativeStart < 0) continue;
    const start = index + relativeStart;
    result.push(makeRedaction(start, start + value.length, token));
  }
  return result;
}

function overlapsPlaceholder(text: string, start: number, end: number): boolean {
  PLACEHOLDER.lastIndex = 0;
  for (const match of text.matchAll(PLACEHOLDER)) {
    const index = match.index;
    if (index !== undefined && index < end && start < index + match[0].length) return true;
  }
  return false;
}

function plausiblePhone(value: string): boolean {
  const digits = [...value].filter((character) => /\d/u.test(character));
  if (digits.length < 7 || digits.length > 15) return false;
  if (digits.length < 11 && !value.includes("+") && !/[ ()-]/u.test(value)) return false;
  return !(digits.length === 8 && (value.match(/-/g)?.length ?? 0) === 2 && !value.includes("."));
}

function passesLuhn(value: string): boolean {
  const digits = [...value].filter((character) => /\d/u.test(character)).map(Number);
  if (digits.length < 13 || digits.length > 19) return false;
  const parity = digits.length % 2;
  let total = 0;
  digits.forEach((digit, index) => {
    let current = digit;
    if (index % 2 === parity) {
      current *= 2;
      if (current > 9) current -= 9;
    }
    total += current;
  });
  return total % 10 === 0;
}

function collect(text: string): Redaction[] {
  const redactions: Redaction[] = [];
  for (const [pattern, token] of [
    [EMAIL, "{{EMAIL}}"],
    [CHINESE_ID, "{{ID}}"],
    [CHINESE_ID_OLD, "{{ID}}"],
    [PASSPORT, "{{ID}}"],
  ] as const) {
    redactions.push(...regexRedactions(text, pattern, token));
  }

  for (const match of text.matchAll(URL)) {
    const index = match.index;
    if (index === undefined) continue;
    let end = index + match[0].length;
    while (end > index && ".,!?;:，。！？；：、)]}>".includes(text[end - 1] ?? "")) end -= 1;
    if (end > index) redactions.push(makeRedaction(index, end, "{{URL}}"));
  }
  for (const match of text.matchAll(CARD)) {
    const index = match.index;
    if (index !== undefined && passesLuhn(match[0])) redactions.push(makeRedaction(index, index + match[0].length, "{{CARD}}"));
  }
  for (const match of text.matchAll(PHONE)) {
    const index = match.index;
    if (index !== undefined && plausiblePhone(match[0])) redactions.push(makeRedaction(index, index + match[0].length, "{{PHONE}}"));
  }
  for (const [pattern, token, group] of [
    [ACCOUNT_ID, "{{ID}}", 1],
    [ACCOUNT_SUFFIX, "{{ID}}", 1],
    [RESOURCE_ID, "{{ID}}", 1],
    [SOCIAL_ACCOUNT, "{{ID}}", 1],
    [NICKNAME, "{{NAME}}", 1],
    [CODE, "{{CODE}}", 1],
    [ORDER_ID, "{{ORDER_ID}}", 1],
    [AMOUNT, "{{AMOUNT}}", 0],
  ] as const) {
    if ((token === "{{ID}}" || token === "{{NAME}}") && (pattern === ACCOUNT_ID || pattern === SOCIAL_ACCOUNT || pattern === NICKNAME)) {
      redactions.push(...contextualRegexRedactions(text, pattern, token, group));
    } else {
      redactions.push(...regexRedactions(text, pattern, token, group));
    }
  }
  return redactions.filter((redaction) => !overlapsPlaceholder(text, redaction.start, redaction.end));
}

function priority(token: string): number {
  const position = TOKEN_PRIORITY.indexOf(token as (typeof TOKEN_PRIORITY)[number]);
  return position < 0 ? TOKEN_PRIORITY.length : position;
}

function merge(redactions: readonly Redaction[]): Redaction[] {
  const ordered = [...redactions].sort((left, right) =>
    left.start - right.start || (left.end - left.start) - (right.end - right.start) || priority(left.token) - priority(right.token),
  );
  const merged: Redaction[] = [];
  for (const candidate of ordered) {
    const previous = merged.at(-1);
    if (!previous || candidate.start >= previous.end) {
      merged.push(candidate);
      continue;
    }
    const token = priority(previous.token) <= priority(candidate.token) ? previous.token : candidate.token;
    merged[merged.length - 1] = makeRedaction(
      Math.min(previous.start, candidate.start),
      Math.max(previous.end, candidate.end),
      token,
    );
  }
  return merged;
}

export function sanitizeText(text: string): SanitizationResult {
  const redactions = merge(collect(text));
  let output = text;
  for (const redaction of [...redactions].reverse()) {
    output = `${output.slice(0, redaction.start)}${redaction.token}${output.slice(redaction.end)}`;
  }
  const kinds = [...new Set(redactions.map((redaction) => redaction.kind))];
  return { text: output, redactions, changed: redactions.length > 0, kinds };
}

export function residualSensitiveKinds(text: string): readonly SensitiveKind[] {
  return [...new Set(merge(collect(text)).map((redaction) => redaction.kind))];
}
