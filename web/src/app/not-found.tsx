import Link from "next/link";
import { Compass } from "lucide-react";

/**
 * Branded 404. Rendered (inside the root layout) for the `notFound()` helper
 * and for any URL that doesn't match a route.
 */
export default function NotFound() {
  return (
    <div className="flex flex-1 items-center justify-center px-4 py-12">
      <div className="w-full max-w-md rounded-xl border border-border-subtle bg-surface-default p-8 text-center shadow-1">
        <Compass size={32} strokeWidth={1.5} className="mx-auto text-text-muted" aria-hidden="true" />
        <p className="mt-4 font-mono text-sm text-text-muted">404</p>
        <h1 className="mt-1 text-lg font-semibold text-text-primary">Page not found</h1>
        <p className="mx-auto mt-1 max-w-sm text-sm text-text-secondary">
          The page you’re looking for doesn’t exist or may have moved.
        </p>
        <Link
          href="/"
          className="mt-5 inline-flex h-9 items-center rounded-lg bg-action-primary px-3.5 text-sm font-medium text-text-on-primary transition-colors hover:bg-action-hover"
        >
          Back to dashboard
        </Link>
      </div>
    </div>
  );
}
