import Link from "next/link";
import { requestReset } from "./actions";

export default function ForgotPasswordPage() {
  return (
    <div>
      <h2 className="mb-4 text-lg font-medium text-zinc-900 dark:text-zinc-50">
        Reset your password
      </h2>
      <form action={requestReset} className="space-y-4">
        <label className="block">
          <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
            Email
          </span>
          <input
            name="email"
            type="email"
            autoComplete="email"
            required
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
          />
        </label>
        <button
          type="submit"
          className="w-full rounded-md bg-action-primary px-4 py-2 text-sm font-medium text-text-on-primary hover:bg-action-hover"
        >
          Send reset link
        </button>
      </form>
      <p className="mt-6 text-sm text-zinc-500 dark:text-zinc-400">
        <Link href="/login" className="hover:underline">
          Back to sign in
        </Link>
      </p>
    </div>
  );
}
