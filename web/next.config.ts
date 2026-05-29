import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactCompiler: true,
  // Allow dev resources to be fetched when the browser opens the app via
  // 127.0.0.1 (Playwright uses this) — Next.js 16 blocks by default.
  allowedDevOrigins: ["127.0.0.1"],
  turbopack: {
    root: __dirname,
  },
  // B05·P01: HSTS + browser-side security headers on every response.
  // The hosting layer (Vercel) enforces TLS 1.3 at the edge; HSTS tells
  // compliant browsers to refuse plaintext re-attempts to this origin for
  // a year. includeSubDomains + preload prepare the origin for HSTS preload
  // submission.
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          {
            key: "Strict-Transport-Security",
            value: "max-age=31536000; includeSubDomains; preload",
          },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "X-Frame-Options", value: "DENY" },
        ],
      },
    ];
  },
};

export default nextConfig;
