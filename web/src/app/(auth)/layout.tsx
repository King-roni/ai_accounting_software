import type { ReactNode } from "react";

export default function AuthLayout({ children }: { children: ReactNode }) {
  return (
    <div className="flex flex-1 items-center justify-center bg-zinc-50 px-4 py-12 dark:bg-zinc-950">
      <div className="w-full max-w-md rounded-xl border border-zinc-200 bg-white p-8 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mb-6 text-center">
          <h1 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">
            TimeFuser<span className="text-accent-bronze-strong">Books</span>
          </h1>
          <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
            Cyprus bookkeeping, automated
          </p>
        </div>
        {children}
      </div>
    </div>
  );
}
