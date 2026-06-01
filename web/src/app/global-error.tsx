"use client";
import { useEffect } from "react";
import "./globals.css";

/**
 * Global error boundary — catches errors thrown in the root layout/template,
 * which the segment-level (app)/error.tsx can't reach. It replaces the root
 * layout when active, so it must render its own <html>/<body> and pull in the
 * global stylesheet for design tokens.
 */
export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <html lang="en" data-theme="light">
      <body className="min-h-screen bg-bg-base text-text-primary antialiased">
        <div className="flex min-h-screen items-center justify-center px-4 py-12">
          <div className="w-full max-w-md rounded-xl border border-border-subtle bg-surface-default p-8 text-center shadow-1">
            <h1 className="text-lg font-semibold text-text-primary">Something went wrong</h1>
            <p className="mx-auto mt-1 max-w-sm text-sm text-text-secondary">
              TimeFuserBooks hit an unexpected error. Please try again.
            </p>
            {error.digest && <p className="mt-2 font-mono text-xs text-text-muted">Reference: {error.digest}</p>}
            <button
              type="button"
              onClick={() => reset()}
              className="mt-5 inline-flex h-9 items-center rounded-lg bg-action-primary px-3.5 text-sm font-medium text-text-on-primary transition-colors hover:bg-action-hover"
            >
              Try again
            </button>
          </div>
        </div>
      </body>
    </html>
  );
}
