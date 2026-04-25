/**
 * sw.js — Service Worker
 *
 * Two modes:
 *
 * 1. STUB mode (default): /chunks/meta.json has { totalSize, stub: true }
 *    Intercepts GET /disk.img Range requests and returns zero-filled bytes.
 *    v86 restores from a pre-saved state file (windows98_state-v2.bin.zst)
 *    whose sector cache covers everything minesweeper needs, so the disk
 *    is rarely hit; any cache miss returns zeros which Windows handles
 *    gracefully for unimportant sectors.
 *
 * 2. CHUNK mode: /chunks/meta.json has { totalSize, chunkSize, count }
 *    Reassembles the disk image from numbered chunk files stored under
 *    /chunks/ (each chunk < 25 MiB, compatible with Cloudflare Pages).
 *    Used when you have your own disk image and want to self-host it.
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
  const { totalSize } = meta;

  const rangeHeader = request.headers.get('Range');

  if (!rangeHeader) {
    // v86 probes size with a bare HEAD/GET before enabling async mode.
    return new Response(new ArrayBuffer(0), {
      status: 200,
      headers: {
        'Content-Length': String(totalSize),
        'Content-Type':   'application/octet-stream',
        'Accept-Ranges':  'bytes',
      },
    });
  }

  // Parse: "bytes=<start>-[<end>]"
  const m = rangeHeader.match(/^bytes=(\d+)-(\d*)$/);
  if (!m) return new Response('Bad Range header', { status: 416 });

  const start      = parseInt(m[1], 10);
  const end        = m[2] ? parseInt(m[2], 10) : totalSize - 1;
  const clampedEnd = Math.min(end, totalSize - 1);
  const length     = clampedEnd - start + 1;

  if (start >= totalSize) {
    return new Response(null, {
      status: 416,
      headers: { 'Content-Range': `bytes */${totalSize}` },
    });
  }

  let slice;

  if (meta.stub) {
    // ── Stub mode: return zeros for any range ─────────────────────────────
    slice = new Uint8Array(length); // zero-filled by default
  } else {
    // ── Chunk mode: reassemble from stored chunks ─────────────────────────
    const { chunkSize } = meta;
    const firstIdx  = Math.floor(start / chunkSize);
    const lastIdx   = Math.floor(clampedEnd / chunkSize);

    const buffers = await Promise.all(
      Array.from({ length: lastIdx - firstIdx + 1 }, (_, i) => fetchChunk(firstIdx + i))
    );

    const totalBytes = buffers.reduce((s, b) => s + b.byteLength, 0);
    const combined   = new Uint8Array(totalBytes);
    let offset       = 0;
    for (const buf of buffers) {
      combined.set(new Uint8Array(buf), offset);
      offset += buf.byteLength;
    }

    const sliceStart = start - firstIdx * chunkSize;
    slice = combined.slice(sliceStart, sliceStart + length);
  }

  return new Response(slice, {
    status: 206,
    headers: {
      'Content-Range':  `bytes ${start}-${clampedEnd}/${totalSize}`,
      'Content-Length': String(slice.byteLength),
      'Content-Type':   'application/octet-stream',
    },
  });
}
