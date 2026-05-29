"use client";
import { useId, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { X } from "lucide-react";
import { Z_INDEX } from "@/theme/tokens";
import { cn } from "@/lib/cn";
import { useDialog, useMounted } from "./overlay-utils";

export interface DrawerProps {
  open: boolean;
  onClose: () => void;
  title: ReactNode;
  children?: ReactNode;
  footer?: ReactNode;
  /** Panel width on desktop. */
  width?: number | string;
  className?: string;
}

/**
 * Drawer — right-side slide-in panel, focus-trapped (modal behaviour). Escape
 * and scrim-click close; focus returns to the trigger. role="dialog"
 * aria-modal. (Mobile bottom-sheet variant is deferred.)
 */
export function Drawer({ open, onClose, title, children, footer, width = 480, className }: DrawerProps) {
  const ref = useRef<HTMLDivElement>(null);
  const mounted = useMounted();
  const base = useId();
  useDialog(open, onClose, ref);
  if (!mounted || !open) return null;

  return createPortal(
    <div className="fixed inset-0" style={{ zIndex: Z_INDEX.modalBackdrop }}>
      <div className="fixed inset-0 bg-black/50" onClick={onClose} aria-hidden="true" />
      <div
        ref={ref}
        role="dialog"
        aria-modal="true"
        aria-labelledby={`${base}-title`}
        tabIndex={-1}
        style={{ zIndex: Z_INDEX.modal, width: typeof width === "number" ? `${width}px` : width }}
        className={cn("fixed inset-y-0 right-0 flex max-w-[100vw] flex-col bg-bg-overlay shadow-3 outline-none", className)}
      >
        <div className="flex items-center justify-between gap-3 border-b border-border-subtle p-5">
          <h2 id={`${base}-title`} className="text-lg font-semibold text-text-primary">{title}</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close drawer"
            className="shrink-0 cursor-pointer rounded-sm p-1 text-text-muted hover:bg-bg-raised hover:text-text-primary"
          >
            <X size={18} strokeWidth={1.5} aria-hidden="true" />
          </button>
        </div>
        <div className="flex-1 overflow-y-auto p-5 text-sm text-text-secondary">{children}</div>
        {footer && <div className="flex items-center justify-end gap-2 border-t border-border-subtle p-4">{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}
