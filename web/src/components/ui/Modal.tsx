"use client";
import { useId, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { X } from "lucide-react";
import { Z_INDEX } from "@/theme/tokens";
import { cn } from "@/lib/cn";
import { useDialog, useMounted } from "./overlay-utils";

export interface ModalProps {
  open: boolean;
  onClose: () => void;
  title: ReactNode;
  description?: ReactNode;
  children?: ReactNode;
  footer?: ReactNode;
  size?: "sm" | "md" | "lg";
  className?: string;
}

const SIZE = { sm: "max-w-sm", md: "max-w-lg", lg: "max-w-2xl" } as const;

/**
 * Modal — centered dialog with scrim. Focus-trapped while open; Escape and
 * scrim-click close; focus returns to the trigger on close. role="dialog"
 * aria-modal with aria-labelledby/ describedby. Enters instantly under
 * prefers-reduced-motion (no scale).
 */
export function Modal({ open, onClose, title, description, children, footer, size = "md", className }: ModalProps) {
  const ref = useRef<HTMLDivElement>(null);
  const mounted = useMounted();
  const base = useId();
  useDialog(open, onClose, ref);
  if (!mounted || !open) return null;

  return createPortal(
    <div className="fixed inset-0" style={{ zIndex: Z_INDEX.modalBackdrop }}>
      <div className="fixed inset-0 bg-black/50" onClick={onClose} aria-hidden="true" />
      <div className="fixed inset-0 flex items-center justify-center p-4" style={{ zIndex: Z_INDEX.modal }}>
        <div
          ref={ref}
          role="dialog"
          aria-modal="true"
          aria-labelledby={`${base}-title`}
          aria-describedby={description ? `${base}-desc` : undefined}
          tabIndex={-1}
          className={cn("w-full rounded-lg bg-bg-overlay shadow-3 outline-none", SIZE[size], className)}
        >
          <div className="flex items-start justify-between gap-3 p-5 pb-3">
            <div className="min-w-0">
              <h2 id={`${base}-title`} className="text-lg font-semibold text-text-primary">{title}</h2>
              {description && <p id={`${base}-desc`} className="mt-1 text-sm text-text-secondary">{description}</p>}
            </div>
            <button
              type="button"
              onClick={onClose}
              aria-label="Close dialog"
              className="shrink-0 cursor-pointer rounded-sm p-1 text-text-muted hover:bg-bg-raised hover:text-text-primary"
            >
              <X size={18} strokeWidth={1.5} aria-hidden="true" />
            </button>
          </div>
          {children && <div className="px-5 pb-5 text-sm text-text-secondary">{children}</div>}
          {footer && <div className="flex items-center justify-end gap-2 border-t border-border-subtle px-5 py-3">{footer}</div>}
        </div>
      </div>
    </div>,
    document.body,
  );
}
