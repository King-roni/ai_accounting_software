import Link from "next/link";
import { login } from "./actions";

export default function LoginPage() {
  return (
    <div>
      <h2 className="mb-4 text-lg font-medium text-zinc-900 dark:text-zinc-50">
        Sign in
      </h2>
      <form action={login} className="space-y-4">
        <Field name="email" label="Email" type="email" autoComplete="email" required />
        <Field name="password" label="Password" type="password" autoComplete="current-password" required />
        <button
          type="submit"
          className="w-full rounded-md bg-action-primary px-4 py-2 text-sm font-medium text-text-on-primary hover:bg-action-hover disabled:opacity-50"
        >
          Sign in
        </button>
      </form>
      <div className="mt-6 flex justify-between text-sm text-zinc-500 dark:text-zinc-400">
        <Link href="/signup" className="hover:underline">
          Create account
        </Link>
        <Link href="/forgot-password" className="hover:underline">
          Forgot password?
        </Link>
      </div>
    </div>
  );
}

function Field(props: {
  name: string;
  label: string;
  type: string;
  autoComplete?: string;
  required?: boolean;
}) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
        {props.label}
      </span>
      <input
        name={props.name}
        type={props.type}
        autoComplete={props.autoComplete}
        required={props.required}
        className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
      />
    </label>
  );
}
