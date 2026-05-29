/**
 * Resolve the application origin used for outbound URLs (email links,
 * OAuth redirect URIs). Reads `NEXT_PUBLIC_SITE_URL`. In production-like
 * environments (NODE_ENV=production) the env var is required — silently
 * falling back to localhost would emit broken email and OAuth URLs.
 */
export function appOrigin(): string {
  const v = process.env.NEXT_PUBLIC_SITE_URL;
  if (v) return v.replace(/\/+$/, "");
  if (process.env.NODE_ENV === "production") {
    throw new Error(
      "NEXT_PUBLIC_SITE_URL is required in production (used for email " +
        "callbacks + OAuth redirect URIs).",
    );
  }
  return "http://localhost:3000";
}
