/**
 * sw.js — Service Worker
 *
 * Intercepts GET /boxedwine.zip and streams it from numbered chunks stored
 * under /chunks/ (each chunk < 25 MB, compatible with Cloudflare Pages).
 * Boxedwine (Emscripten Wine) fetches boxedwine.zip as its Wine filesystem;
 * this SW transparently reassembles the file from pieces.
 *
 * Chunk metadata is in /chunks/meta.json:
 *   { filename, totalSize, chunkSize, count }
 */

// ── Lifecycle ──────────────────────────────────────────────────────────────

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(clients.claim()));

// ── Fetch interception ─────────────────────────────────────────────────────

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (url.pathname === '/boxedwine.zip') {
    event.respondWith(serveBoxedWineZip());
  }
});

// ── Metadata ──────────────────────────────────────────────────────────────

let _meta = null;

async function getMeta() {
  if (_meta) return _meta;
  const r = await fetch('/chunks/meta.json');
  if (!r.ok) throw new Error(`meta.json: HTTP ${r.status}`);
  _meta = await r.json();
  return _meta;
}

// ── Stream chunks as a single /boxedwine.zip response ────────────────────

async function serveBoxedWineZip() {
  const meta = await getMeta();

  const stream = new ReadableStream({
    async start(controller) {
      for (let i = 0; i < meta.count; i++) {
        const name = `/chunks/boxedwine.zip.${String(i).padStart(4, '0')}`;
        const r = await fetch(name);
        if (!r.ok) throw new Error(`chunk ${i}: HTTP ${r.status}`);
        controller.enqueue(new Uint8Array(await r.arrayBuffer()));
      }
      controller.close();
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      'Content-Type':   'application/zip',
      'Content-Length': String(meta.totalSize),
    },
  });
}
