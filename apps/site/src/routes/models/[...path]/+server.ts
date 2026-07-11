import type { RequestHandler } from './$types';

const MANIFEST_CACHE_CONTROL = 'public, max-age=300, must-revalidate';
const ARTIFACT_CACHE_CONTROL = 'public, max-age=31536000, immutable';

interface ByteRange {
  offset: number;
  length: number;
  end: number;
}

type ModelMetadata = NonNullable<Awaited<ReturnType<App.Platform['env']['MODEL_BUCKET']['head']>>>;

export const prerender = false;

export const GET: RequestHandler = ({ params, platform, request }) => (
  serveModel(params.path, request, platform)
);

export const HEAD: RequestHandler = ({ params, platform, request }) => (
  serveModel(params.path, request, platform)
);

async function serveModel(path: string, request: Request, platform: App.Platform | undefined): Promise<Response> {
  const key = modelObjectKey(path);
  if (!key) return new Response('Not Found', { status: 404 });

  const bucket = platform?.env.MODEL_BUCKET;
  if (!bucket) return new Response('Model storage unavailable', { status: 503 });

  try {
    const rangeHeader = request.method === 'GET' ? request.headers.get('range') : null;
    if (rangeHeader) {
      const metadata = await bucket.head(key);
      if (!metadata) return new Response('Not Found', { status: 404 });

      const headers = modelHeaders(metadata, key);
      if (etagMatches(request.headers.get('if-none-match'), metadata)) {
        return new Response(null, { status: 304, headers });
      }

      const range = parseByteRange(rangeHeader, metadata.size);
      if (!range) {
        headers.set('content-range', `bytes */${metadata.size}`);
        headers.delete('content-length');
        return new Response('Range Not Satisfiable', { status: 416, headers });
      }

      const object = await bucket.get(key, {
        range: { offset: range.offset, length: range.length }
      });
      if (!object) return new Response('Not Found', { status: 404 });

      headers.set('content-range', `bytes ${range.offset}-${range.end}/${metadata.size}`);
      headers.set('content-length', String(range.length));
      return new Response(object.body, { status: 206, headers });
    }

    const object = request.method === 'HEAD'
      ? await bucket.head(key)
      : await bucket.get(key);
    if (!object) return new Response('Not Found', { status: 404 });

    const headers = modelHeaders(object, key);
    if (etagMatches(request.headers.get('if-none-match'), object)) {
      return new Response(null, { status: 304, headers });
    }

    return new Response(request.method === 'HEAD' ? null : object.body, { headers });
  } catch (error) {
    console.error(JSON.stringify({
      message: 'model read failed',
      method: request.method,
      key,
      error: error instanceof Error ? error.message : String(error)
    }));
    return new Response('Model storage temporarily unavailable', { status: 503 });
  }
}

function modelHeaders(object: ModelMetadata, key: string): Headers {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('etag', object.httpEtag);
  headers.set('content-length', String(object.size));
  headers.set('accept-ranges', 'bytes');
  headers.set('x-content-type-options', 'nosniff');
  if (!headers.has('cache-control')) {
    headers.set(
      'cache-control',
      key.endsWith('.manifest.json') ? MANIFEST_CACHE_CONTROL : ARTIFACT_CACHE_CONTROL
    );
  }
  return headers;
}

function etagMatches(ifNoneMatch: string | null, object: ModelMetadata): boolean {
  if (!ifNoneMatch) return false;
  const etags = ifNoneMatch.split(',').map((value) => value.trim());
  return etags.some((etag) => (
    etag === '*'
    || etag === object.httpEtag
    || etag === `W/${object.httpEtag}`
    || etag === `"${object.etag}"`
  ));
}

function parseByteRange(value: string, size: number): ByteRange | undefined {
  const match = /^bytes=(\d*)-(\d*)$/.exec(value.trim());
  if (!match || (!match[1] && !match[2]) || size <= 0) return undefined;

  if (!match[1]) {
    const suffixLength = parseDecimal(match[2]);
    if (!suffixLength || suffixLength <= 0) return undefined;

    const length = Math.min(suffixLength, size);
    return { offset: size - length, length, end: size - 1 };
  }

  const offset = parseDecimal(match[1]);
  if (offset === undefined || offset >= size) return undefined;

  const requestedEnd = match[2] ? parseDecimal(match[2]) : size - 1;
  if (requestedEnd === undefined || requestedEnd < offset) return undefined;

  const end = Math.min(requestedEnd, size - 1);
  return { offset, length: end - offset + 1, end };
}

function parseDecimal(value: string): number | undefined {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : undefined;
}

function modelObjectKey(path: string): string | undefined {
  let decoded;
  try {
    decoded = decodeURIComponent(path);
  } catch {
    return undefined;
  }

  if (!decoded || decoded.endsWith('/') || decoded.split('/').includes('..')) {
    return undefined;
  }
  return `models/${decoded}`;
}
