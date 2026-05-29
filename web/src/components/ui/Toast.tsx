"use client";
import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { AlertCircle, AlertTriangle, CheckCircle2, Info, X, type LucideIcon } from "lucide-react";
import { Z_INDEX } from "@/theme/tokens";
import { useMounted } from "./overlay-utils";

export type ToastVariant = "success" | "error" | "info" | "warning";

export interface ToastOptions {
  variant?: ToastVariant;
  title: ReactNode;
  description?: ReactNode;
  /** ms before auto-dismiss; default 4000. Pass 0 to keep until dismissed. */
  duration?: number;
}

interface ToastItem extends ToastOptions {
  id: number;
}

const V: Record<ToastVariant, { icon: LucideIcon; token: string; role: "status" | "alert" }> = {
  success: { icon: CheckCircle2, token: "--color-status-success", role: "status" },
  info: { icon: Info, token: "--color-status-info", role: "status" },
  warning: { icon: AlertTriangle, token: "--color-status-warning", role: "status" },
  error: { icon: AlertCircle, token: "--color-status-danger", role: "alert" },
};

const ToastContext = createContext<{ toast: (o: ToastOptions) => void } | null>(null);

/** Access the toast dispatcher. Must be inside <ToastProvider>. */
export function useToast() {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error("useToast must be used within <ToastProvider>");
  return ctx;
}

const MAX_STACK = 3;

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const idRef = useRef(0);
  const mounted = useMounted();

  const dismiss = useCallback((id: number) => {
    setItems((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const toast = useCallback((o: ToastOptions) => {
    const id = ++idRef.current;
    const item: ToastItem = { id, variant: "info", duration: 4000, ...o };
    setItems((prev) => [...prev, item].slice(-MAX_STACK));
    const d = item.duration ?? 4000;
    if (d > 0) setTimeout(() => dismiss(id), d);
  }, [dismiss]);

  return (
    <ToastContext.Provider value={{ toast }}>
      {children}
      {mounted &&
        createPortal(
          <div
            className="pointer-events-none fixed bottom-4 right-4 flex w-[min(22rem,calc(100vw-2rem))] flex-col gap-2"
            style={{ zIndex: Z_INDEX.toast }}
          >
            {items.map((t) => {
              const cfg = V[t.variant ?? "info"];
              const Icon = cfg.icon;
              return (
                <div
                  key={t.id}
                  role={cfg.role}
                  data-component="toast"
                  className="pointer-events-auto flex gap-3 rounded-md border border-border-subtle bg-bg-overlay p-3 shadow-2"
                  style={{ borderLeftWidth: 3, borderLeftColor: `var(${cfg.token})` }}
                >
                  <Icon size={18} strokeWidth={1.5} aria-hidden="true" className="mt-0.5 shrink-0" style={{ color: `var(${cfg.token})` }} />
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium text-text-primary">{t.title}</p>
                    {t.description && <p className="mt-0.5 text-sm text-text-secondary">{t.description}</p>}
                  </div>
                  <button
                    type="button"
                    onClick={() => dismiss(t.id)}
                    aria-label="Dismiss notification"
                    className="shrink-0 cursor-pointer rounded-sm p-0.5 text-text-muted hover:text-text-primary"
                  >
                    <X size={16} strokeWidth={1.5} aria-hidden="true" />
                  </button>
                </div>
              );
            })}
          </div>,
          document.body,
        )}
    </ToastContext.Provider>
  );
}
