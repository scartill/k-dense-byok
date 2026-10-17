import type { NextConfig } from "next";
import { readFileSync } from "fs";
import { resolve } from "path";

function readAppVersion(): string {
  // The server package is the source of truth for the app version (it's what
  // the README badge and release tags track). Reading it here keeps the
  // frontend's update check honest — a stale fallback makes every published
  // GitHub release look "newer" and shows a false "update available" banner.
  try {
    const pkg = readFileSync(resolve(__dirname, "..", "server", "package.json"), "utf-8");
    const version = (JSON.parse(pkg) as { version?: string }).version;
    if (version) return version;
  } catch {
    // fall through to default
  }
  return "0.0.0";
}

// Allow Next.js dev resources (HMR, _next assets) to be served to remote
// hosts such as an ngrok tunnel. Set ALLOWED_DEV_ORIGINS to a comma-separated
// list of hostnames (no scheme) to permit additional origins in dev.
const allowedDevOrigins = (process.env.ALLOWED_DEV_ORIGINS ?? "")
  .split(",")
  .map((h) => h.trim())
  .filter(Boolean);

// When the UI is reached through a remote origin (e.g. an ngrok tunnel), the
// browser cannot talk to the backend's own localhost:8000 — "localhost" there
// means the *viewer's* machine. Instead the UI calls a same-origin path
// (NEXT_PUBLIC_ADK_API_URL=https://<host>/kady-api) and a route handler
// (src/app/kady-api/[...path]/route.ts) proxies it, server-side over
// loopback, to the real backend. That handler strips the browser's Origin /
// Referer / Sec-Fetch-* headers so the backend sees an origin-less loopback
// request and its CORS + DNS-rebinding guards pass without being weakened.

const nextConfig: NextConfig = {
  devIndicators: false,
  ...(allowedDevOrigins.length > 0 ? { allowedDevOrigins } : {}),
  async headers() {
    return [{ source: "/office/:path*", headers: [
      { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
      { key: "Cross-Origin-Embedder-Policy", value: "require-corp" },
    ] }];
  },
  // Next 16.3 otherwise writes AGENTS.md/CLAUDE.md into web/ on every dev start.
  agentRules: false,
  // The repo-root package.json (npm-start wrapper, no lockfile) makes Turbopack
  // infer the monorepo root as its workspace root, which breaks module
  // resolution (e.g. tailwindcss) against web/node_modules.
  turbopack: {
    root: __dirname,
  },
  env: {
    NEXT_PUBLIC_APP_VERSION: readAppVersion(),
  },
};

export default nextConfig;
