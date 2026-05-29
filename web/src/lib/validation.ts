/**
 * Zod schemas for auth forms. Mirrors the password_policy sub-doc:
 * ≥12 chars, upper, lower, digit, special. Max 128.
 *
 * Note: HIBP breach check is deferred (post-MVP — would land as a
 * Supabase Auth hook). Listed as a Stage-7-2 implementation decision.
 */
import * as z from "zod";

export const passwordSchema = z
  .string()
  .min(12, { error: "Password must be at least 12 characters." })
  .max(128, { error: "Password must be at most 128 characters." })
  .regex(/[A-Z]/, { error: "Password must contain at least one uppercase letter." })
  .regex(/[a-z]/, { error: "Password must contain at least one lowercase letter." })
  .regex(/[0-9]/, { error: "Password must contain at least one digit." })
  .regex(/[^A-Za-z0-9]/, { error: "Password must contain at least one special character." });

export const signupSchema = z.object({
  email: z.email({ error: "Please enter a valid email address." }).trim().toLowerCase(),
  password: passwordSchema,
  displayName: z
    .string()
    .min(2, { error: "Display name must be at least 2 characters." })
    .max(255)
    .trim(),
});

export const loginSchema = z.object({
  email: z.email({ error: "Please enter a valid email address." }).trim().toLowerCase(),
  password: z.string().min(1, { error: "Password is required." }),
});

export const forgotPasswordSchema = z.object({
  email: z.email({ error: "Please enter a valid email address." }).trim().toLowerCase(),
});

export const resetPasswordSchema = z
  .object({
    password: passwordSchema,
    confirm: z.string(),
  })
  .refine((data) => data.password === data.confirm, {
    error: "Passwords don't match.",
    path: ["confirm"],
  });

export type FormState = {
  errors?: Record<string, string[]>;
  message?: string;
} | undefined;
