"use client";
import { useEffect } from "react";
import Link from "next/link";
import { AlertOctagon } from "lucide-react";
import { Button, Card, CardBody } from "@/components/ui";

/**
 * Error boundary for the authenticated app shell. Catches unexpected runtime
 * errors thrown while rendering a (app) route segment and shows a branded
 * fallback with a way to retry or bail to the dashboard.
 */
export default function AppError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <div className="flex min-h-[60vh] items-center justify-center py-12">
      <Card className="w-full max-w-md">
        <CardBody className="flex flex-col items-center gap-3 px-6 py-10 text-center">
          <AlertOctagon size={32} strokeWidth={1.5} aria-hidden="true" style={{ color: "var(--color-status-danger)" }} />
          <h1 className="text-lg font-semibold text-text-primary">Something went wrong</h1>
          <p className="max-w-sm text-sm text-text-secondary">
            We hit an unexpected error loading this screen. You can try again, or head back to the dashboard.
          </p>
          {error.digest && <p className="font-mono text-xs text-text-muted">Reference: {error.digest}</p>}
          <div className="mt-2 flex flex-wrap items-center justify-center gap-2">
            <Button onClick={() => reset()}>Try again</Button>
            <Link
              href="/"
              className="inline-flex h-9 items-center rounded-lg border border-border-default bg-bg-base px-3.5 text-sm font-medium text-text-primary transition-colors hover:border-border-strong hover:bg-bg-raised"
            >
              Back to dashboard
            </Link>
          </div>
        </CardBody>
      </Card>
    </div>
  );
}
