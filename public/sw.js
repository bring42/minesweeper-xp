/**
 * sw.js — Service Worker
 *
 * Intercepts GET requests for /disk.img and transparently reassembles
 * the response from numbered chunk files stored under /chunks/.
 *
 * This lets us store a large disk image as many small files
 * (each < 25 MiB) on Cloudflare Pages while still serving the image
 * as a single URL that supports HTTP Range requests, which v86 requires
 * when `async: true` is set.
 *
 * Chunk files on disk:  /chunks/disk.img.0000, .0001, …
 * Metadata:             /chunks/meta.json  →  { totalSize, chunkSize, count }
 */

const CACHE = 'minesweeper-chunks-v1';

// ── Lifecycle ──────────────────────────────────────────────────────────────

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(clients.claim()));

// ── Fetch interception ─────────────────────────────────────────────────────

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (url.pathname === '/disk.img') {
    event.respondWith(handleDiskRequest(event.request));
  }
});

// ── Metadata (cached after first fetch) ───────────────────────────────────

let _meta = null;

async function getMeta() {
  if (_meta) return _meta;
  const r = await fetch('/chunks/meta.json');
  if (!r.ok) throw new Error(`Could not fetch /chunks/meta.json: HTTP ${r.status}`);
  _meta = await r.json();
  return _meta;
}

// ── Chunk fetching with Cache API ──────────────────────────────────────────

async function fetchChunk(index) {
  const padded = String(index).padStart(4, '0');
  const url    = `/chunks/disk.img.${padded}`;

  const cache  = await caches.open(CACHE);
  const cached = await cache.match(url);
  if (cached) return cached.arrayBuffer();

  const res = await fetch(url);
  if (!res.ok) throw new Error(`Chunk ${index} not found (HTTP ${res.status})`);

  // Cache immutable chunk for subsequent accesses
  await cache.put(url, res.clone());
  return res.arrayBuffer();
}

// ── Range request handler ──────────────────────────────────────────────────

async function handleDiskRequest(request) {
  const meta = await getMeta();
  const { totalSize, chunkSize } = meta;

  const rangeHeader = request.headers.get('Range');

  if (!rangeHeader) {
    // v86 may probe the size with a bare HEAD/GET before enabling async mode.
    // Return an empty 200 with the correct Content-Length so it can infer size.
    return new Response(new ArrayBuffer(0), {
      status: 200,
      headers: {
        'Content-Length':  String(totalSize),
        'Content-Type':    'application/octet-stream',
        'Accept-Ranges':   'bytes',
      },
    });
  }

  // Parse: "bytes=<start>-[<end>]"
  const m = rangeHeader.match(/^bytes=(\d+)-(\d*)$/);
  if (!m) {
    return new Response('Bad Range header', { status: 416 });
  }

  const start = parseInt(m[1], 10);
  const end   = m[2] ? parseInt(m[2], 10) : totalSize - 1;

  if (start >= totalSize) {
    return new Response(null, {
      status: 416,
      headers: { 'Content-Range': `bytes */${totalSize}` },
    });
  }

  const clampedEnd = Math.min(end, totalSize - 1);
  const length     = clampedEnd - start + 1;

  // Which chunks overlap [start, clampedEnd]?
  const firstIdx = Math.floor(start / chunkSize);
  const lastIdx  = Math.floor(clampedEnd / chunkSize);

  // Fetch all required chunks in parallel
  const buffers = await Promise.all(
    Array.from({ length: lastIdx - firstIdx + 1 }, (_, i) => fetchChunk(firstIdx + i))
  );

  // Concatenate
  const totalBytes = buffers.reduce((s, b) => s + b.byteLength, 0);
  const combined   = new Uint8Array(totalBytes);
  let offset       = 0;
  for (const buf of buffers) {
    combined.set(new Uint8Array(buf), offset);
    offset += buf.byteLength;
  }

  // Slice to the exact requested byte range
  const sliceStart = start - firstIdx * chunkSize;
  const slice      = combined.slice(sliceStart, sliceStart + length);

  return new Response(slice, {
    status: 206,
    headers: {
      'Content-Range':  `bytes ${start}-${clampedEnd}/${totalSize}`,
      'Content-Length': String(slice.byteLength),
      'Content-Type':   'application/octet-stream',
    },
  });
}
