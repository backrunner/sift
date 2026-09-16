import { test } from 'node:test';
import assert from 'node:assert/strict';
import { submitSupport, type SupportEnv } from '../src/lib/server/support-intake.ts';

const payload = { email: ' Customer@Example.com ', topic: 'problem', subject: 'Filtering stops', content: 'Filtering stops after an update.', appVersion: '1.4', turnstileToken: 'test-token', locale: 'ja' };
const env: SupportEnv = { ONFIRE_API_KEY: 'private-api-key', ONFIRE_PRODUCT_ID: 'sift-product', ONFIRE_TICKET_TYPES: JSON.stringify({ problem: 'bug-type' }), SUPPORT_RATE_LIMIT: { limit: async () => ({ success: true }) } };
const request = (body: unknown = payload, origin = 'https://sift.alkinum.com') => new Request('https://sift.alkinum.com/api/support', { method: 'POST', headers: { origin, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const json = (data: unknown, status = 200) => new Response(JSON.stringify({ ok: status < 400, data }), { status });
function service(overrides: { productId?: string; formId?: string; ticketStatus?: number; ticketError?: boolean } = {}) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetcher = (async (url: string | URL | Request, init: RequestInit = {}) => {
    calls.push({ url: String(url), init });
    if (String(url).endsWith('/tokens')) return json({ token: 'private-customer-token', productId: overrides.productId ?? 'sift-product' });
    if (String(url).includes('/form?')) return json({ ticketTypeId: overrides.formId ?? 'bug-type', templateVersionId: 'current-version' });
    if (overrides.ticketError) throw new Error('private-api-key');
    return json({ ticketId: 'ticket-123', token: 'must-not-leak' }, overrides.ticketStatus ?? 201);
  }) as typeof fetch;
  return { calls, fetcher };
}

test('creates only in the configured product using the live immutable form; credentials stay server-side', async () => {
  const mock = service();
  const response = await submitSupport(request({ ...payload, productId: 'attacker-product', ticketTypeId: 'attacker-type', priority: 'high' }), env, '192.0.2.1', mock.fetcher);
  assert.equal(response.status, 201);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { ticketId: 'ticket-123' });
  assert.equal(mock.calls.length, 3);
  assert.equal(JSON.parse(mock.calls[0].init.body as string).email, 'customer@example.com');
  const body = JSON.parse(mock.calls[2].init.body as string);
  assert.equal(body.ticketTypeId, 'bug-type');
  assert.equal(body.templateVersionId, 'current-version');
  assert.deepEqual(body.metadata, { app_version: '1.4', preferred_language: 'ja' });
  assert.equal(body.priority, undefined);
  assert.equal(body.turnstileToken, 'test-token');
  assert(mock.calls.every(c => c.init.redirect === 'error' && c.init.signal));
});

test('rejects cross-origin submissions before credential use', async () => {
  const mock = service();
  assert.equal((await submitSupport(request(payload, 'https://untrusted.example'), env, 'ip', mock.fetcher)).status, 403);
  assert.equal(mock.calls.length, 0);
});

test('rejects missing or null origins before credential use', async () => {
  const mock = service();
  for (const origin of [null, 'null']) {
    const req = request();
    if (origin === null) req.headers.delete('origin');
    else req.headers.set('origin', origin);
    assert.equal((await submitSupport(req, env, 'ip', mock.fetcher)).status, 403);
  }
  assert.equal(mock.calls.length, 0);
});

test('rejects matching Host and Origin on old, preview, and lookalike domains', async () => {
  const mock = service();
  for (const origin of ['https://sift.alkinum.io', 'https://sift-docs.example.workers.dev', 'https://sift.alkinum.com.example.org', 'http://sift.alkinum.com']) {
    const req = new Request(`${origin}/api/support`, { method: 'POST', headers: { origin, 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    assert.equal((await submitSupport(req, env, 'ip', mock.fetcher)).status, 403);
  }
  assert.equal(mock.calls.length, 0);
});

test('rate limits the visitor before minting a customer identity', async () => {
  const mock = service();
  let key = '';
  const limited = { ...env, SUPPORT_RATE_LIMIT: { limit: async (input: {key:string}) => { key = input.key; return { success: false }; } } };
  assert.equal((await submitSupport(request(), limited, '192.0.2.4', mock.fetcher)).status, 429);
  assert.equal(key, 'sift:support:192.0.2.4');
  assert.equal(mock.calls.length, 0);
});

test('missing configuration fails closed', async () => {
  assert.equal((await submitSupport(request(), undefined, 'ip')).status, 503);
  assert.equal((await submitSupport(request(), { ...env, SUPPORT_RATE_LIMIT: undefined } as unknown as SupportEnv, 'ip')).status, 503);
});

for (const [label, body] of [
  ['missing CAPTCHA', { ...payload, turnstileToken: '' }],
  ['unsupported locale', { ...payload, locale: 'fr' }],
  ['oversized device detail', { ...payload, deviceModel: 'a'.repeat(121) }],
  ['invalid email', { ...payload, email: 'bad' }],
  ['empty subject', { ...payload, subject: ' ' }],
  ['unknown category', { ...payload, topic: 'admin' }],
  ['oversized body', { ...payload, content: 'a'.repeat(64001) }]
] as const) test(`rejects ${label} without an upstream call`, async () => {
  const mock = service();
  assert.equal((await submitSupport(request(body), env, 'ip', mock.fetcher)).status, 400);
  assert.equal(mock.calls.length, 0);
});

test('rejects an API key that belongs to another product', async () => {
  const mock = service({ productId: 'other-product' });
  assert.equal((await submitSupport(request(), env, 'ip', mock.fetcher)).status, 502);
  assert.equal(mock.calls.length, 1);
});

test('rejects a form returned for another category', async () => {
  const mock = service({ formId: 'other-type' });
  assert.equal((await submitSupport(request(), env, 'ip', mock.fetcher)).status, 502);
  assert.equal(mock.calls.length, 2);
});

test('reports a consumed or invalid challenge without exposing provider response', async () => {
  const mock = service({ ticketStatus: 400 });
  assert.equal((await submitSupport(request(), env, 'ip', mock.fetcher)).status, 400);
});

test('does not retry an ambiguous write or leak credentials from errors', async () => {
  const mock = service({ ticketError: true });
  const response = await submitSupport(request(), env, 'ip', mock.fetcher);
  assert.equal(response.status, 502);
  const text = await response.text();
  assert(!text.includes('private-api-key'));
  assert(!text.includes('private-customer-token'));
  assert.equal(mock.calls.filter(c => c.url.includes('/tickets?')).length, 1);
});
