const phonePatterns = [
  /\+?\d[\d\s-]{6,}\d/g,
  /\b1[3-9]\d{9}\b/g
];

const emailPattern = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
const urlPattern = /\bhttps?:\/\/[^\s]+/gi;
const addressPattern = /(?:收件地址|地址)[:：]?\s*[^，。；\n]{4,}/g;
const codePattern = /(?<!\d)\d{4,8}(?!\d)/g;
const amountPattern = /(?:¥|￥|RMB|CNY)\s*\d+(?:\.\d{1,2})?|\b\d+(?:\.\d{1,2})?\s*(?:元|块)\b/g;
const orderPattern = /(订单号|运单号|单号|流水号|取件码|验证码)[:：]?\s*[A-Z0-9-]{4,}/gi;
const cardPattern = /(?:\d[ -]?){12,19}/g;

type Replacement = {
  readonly start: number;
  readonly end: number;
  readonly token: string;
};

function collectMatches(text: string): Replacement[] {
  const hits: Replacement[] = [];

  const pushMatches = (regex: RegExp, token: string) => {
    for (const match of text.matchAll(regex)) {
      if (typeof match.index === "number" && match[0].length > 0) {
        hits.push({ start: match.index, end: match.index + match[0].length, token });
      }
    }
  };

  for (const pattern of phonePatterns) {
    pushMatches(pattern, "{{PHONE}}");
  }
  pushMatches(emailPattern, "{{EMAIL}}");
  pushMatches(urlPattern, "{{URL}}");
  pushMatches(addressPattern, "{{ADDRESS}}");
  pushMatches(orderPattern, "{{ORDER_ID}}");
  pushMatches(cardPattern, "{{CARD}}");
  pushMatches(amountPattern, "{{AMOUNT}}");
  pushMatches(codePattern, "{{CODE}}");

  return hits.sort((left, right) => left.start - right.start || right.end - left.end);
}

export function sanitizeSubmissionText(input: string): string {
  if (input.length === 0) {
    return input;
  }

  const matches = collectMatches(input);
  if (matches.length === 0) {
    return input;
  }

  let cursor = 0;
  let output = "";

  for (const match of matches) {
    if (match.start < cursor) {
      continue;
    }

    output += input.slice(cursor, match.start);
    output += match.token;
    cursor = match.end;
  }

  output += input.slice(cursor);
  return output;
}
