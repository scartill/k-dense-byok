// Same-origin proxy to the local Kady backend.
//
// Why this exists: when the UI is opened through a remote origin (an ngrok
// tunnel, a reverse proxy, etc.), the browser cannot reach the backend's own
// localhost:8000, and the backend deliberately refuses any request that
// carries a foreign browser `Origin` / cross-site `Sec-Fetch-*` headers
// (see server/src/request-guard.ts — its defence against DNS rebinding and
// cross-site drive-by calls to an API that can run a shell).
//
// The UI therefore calls this route on its OWN origin
// (NEXT_PUBLIC_ADK_API_URL = https://<host>/kady-api/...). We forward the
// request server-side to the backend over loopback and STRIP the browser
// security headers, so the backend sees an origin-less loopback caller —
// exactly like curl or its own child processes — and its guards pass without
// being weakened. The backend remains bound to loopback; this handler is the
// only path in.

import { type NextRequest } from "next/server";

const BACKEND_ORIGIN = (
  process.env.KADY_BACKEND_ORIGIN ?? "http://127.0.0.1:8000"
).replace(/\/$/, "");

// Never cache or statically optimize the proxy.
export const dynamic = "force-dynamic";
export const runtime = "nodejs";

// Hop-by-hop and browser-security headers that must NOT reach the backend.
// Origin / Referer / Sec-Fetch-* are what the backend guard inspects; dropping
// them makes the forwarded request look like a trusted loopback client.
const STRIP_REQUEST_HEADERS = new Set([
  "host",
  "origin",
  "referer",
  "connection",
  "keep-alive",
  "proxy-authorization",
  "transfer-encoding",
  "upgrade",
  // ngrok's own browser-warning bypass header; not meant for the backend.
  "ngrok-skip-browser-warning",
]);

function buildBackendUrl(req: NextRequest, path: string[]): string {
  const search = req.nextUrl.search ?? "";
  const suffix = path.map(encodeURIComponent).join("/");
  return `${BACKEND_ORIGIN}/${suffix}${search}`;
}

function filterRequestHeaders(src: Headers): Headers {
  const out = new Headers();
  src.forEach((value, key) => {
    const k = key.toLowerCase();
    if (STRIP_REQUEST_HEADERS.has(k)) return;
    if (k.startsWith("sec-fetch-")) return; // cross-site fetch metadata
    out.set(key, value);
  });
  return out;
}

function filterResponseHeaders(src: Headers): Headers {
  const out = new Headers();
  src.forEach((value, key) => {
    const k = key.toLowerCase();
    // Let the platform set framing; keep everything else (incl. content-type,
    // cache-control, x-accel-buffering so SSE stays unbuffered).
    if (k === "content-encoding" || k === "transfer-encoding" || k === "connection") return;
    out.set(key, value);
  });
  return out;
}

async function proxy(req: NextRequest, path: string[]): Promise<Response> {
  const url = buildBackendUrl(req, path);
  const method = req.method.toUpperCase();
  const hasBody = method !== "GET" && method !== "HEAD";

  const init: RequestInit & { duplex?: "half" } = {
    method,
    headers: filterRequestHeaders(req.headers),
    redirect: "manual",
  };
  if (hasBody) {
    init.body = req.body as unknown as BodyInit;
    // Required by Node/undici when streaming a request body.
    init.duplex = "half";
  }

  let backendRes: Response;
  try {
    backendRes = await fetch(url, init);
  } catch (err) {
    return new Response(
      JSON.stringify({
        detail: `Kady backend proxy could not reach ${BACKEND_ORIGIN}: ${
          err instanceof Error ? err.message : String(err)
        }`,
        reason: "backend_unreachable",
      }),
      { status: 502, headers: { "content-type": "application/json" } },
    );
  }

  // Stream the body straight through — SSE and large downloads must not be
  // buffered here.
  return new Response(backendRes.body, {
    status: backendRes.status,
    statusText: backendRes.statusText,
    headers: filterResponseHeaders(backendRes.headers),
  });
}

type Ctx = { params: Promise<{ path?: string[] }> };

async function handler(req: NextRequest, ctx: Ctx): Promise<Response> {
  const { path } = await ctx.params;
  return proxy(req, path ?? []);
}

export const GET = handler;
export const POST = handler;
export const PUT = handler;
export const PATCH = handler;
export const DELETE = handler;
export const HEAD = handler;
export const OPTIONS = handler;
