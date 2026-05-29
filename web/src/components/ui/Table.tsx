"use client";
import { useMemo, useState, type ReactNode } from "react";
import { ChevronDown, ChevronsUpDown, ChevronUp } from "lucide-react";
import { cn } from "@/lib/cn";
import { Skeleton } from "./Skeleton";

export interface Column<T> {
  id: string;
  header: ReactNode;
  cell: (row: T) => ReactNode;
  align?: "left" | "right" | "center";
  /** Right-aligns + tabular figures. */
  numeric?: boolean;
  sortable?: boolean;
  /** Comparable value for client-side sort (required if sortable). */
  sortValue?: (row: T) => string | number;
  width?: number | string;
}

export interface TableProps<T> {
  columns: Column<T>[];
  data: T[];
  rowKey: (row: T) => string;
  density?: "compact" | "comfortable";
  loading?: boolean;
  /** Rendered when not loading and data is empty. */
  empty?: ReactNode;
  onRowClick?: (row: T) => void;
  selectable?: boolean;
  selected?: Set<string>;
  onSelectedChange?: (next: Set<string>) => void;
  className?: string;
}

type SortState = { id: string; dir: "asc" | "desc" } | null;

/**
 * Table — sortable (aria-sort) + density + sticky header + optional row
 * selection (header = select-all-on-page) + loading skeletons + empty slot.
 * Numeric columns right-align with tabular figures. Built on a native <table>
 * for semantics. NB: row virtualization (50+ rows) is deferred — render upstream
 * with pagination for large sets until then.
 */
export function Table<T>({
  columns,
  data,
  rowKey,
  density = "comfortable",
  loading = false,
  empty,
  onRowClick,
  selectable = false,
  selected,
  onSelectedChange,
  className,
}: TableProps<T>) {
  const [sort, setSort] = useState<SortState>(null);
  const rowH = density === "compact" ? "h-8" : "h-12";

  const sorted = useMemo(() => {
    if (!sort) return data;
    const col = columns.find((c) => c.id === sort.id);
    if (!col?.sortValue) return data;
    const sv = col.sortValue;
    return [...data].sort((a, b) => {
      const av = sv(a), bv = sv(b);
      const r = av < bv ? -1 : av > bv ? 1 : 0;
      return sort.dir === "asc" ? r : -r;
    });
  }, [data, sort, columns]);

  const toggleSort = (id: string) =>
    setSort((s) => (s?.id === id ? (s.dir === "asc" ? { id, dir: "desc" } : null) : { id, dir: "asc" }));

  const allKeys = sorted.map(rowKey);
  const allSelected = selectable && allKeys.length > 0 && allKeys.every((k) => selected?.has(k));
  const toggleAll = () => {
    if (!onSelectedChange) return;
    onSelectedChange(allSelected ? new Set() : new Set(allKeys));
  };
  const toggleRow = (k: string) => {
    if (!onSelectedChange || !selected) return;
    const next = new Set(selected);
    if (next.has(k)) next.delete(k);
    else next.add(k);
    onSelectedChange(next);
  };

  const colSpan = columns.length + (selectable ? 1 : 0);
  const alignCls = (c: Column<T>) =>
    c.numeric || c.align === "right" ? "text-right" : c.align === "center" ? "text-center" : "text-left";

  return (
    <div className={cn("overflow-auto rounded-md border border-border-subtle", className)}>
      <table className="w-full border-collapse text-sm">
        <thead className="sticky top-0 z-[1] bg-bg-raised">
          <tr className="border-b border-border-subtle">
            {selectable && (
              <th scope="col" className="w-10 px-3">
                <input
                  type="checkbox"
                  aria-label="Select all rows"
                  checked={allSelected}
                  onChange={toggleAll}
                  className="cursor-pointer accent-[var(--color-action-primary)]"
                />
              </th>
            )}
            {columns.map((c) => {
              const ariaSort = sort?.id === c.id ? (sort.dir === "asc" ? "ascending" : "descending") : c.sortable ? "none" : undefined;
              const SortIcon = sort?.id === c.id ? (sort.dir === "asc" ? ChevronUp : ChevronDown) : ChevronsUpDown;
              return (
                <th
                  key={c.id}
                  scope="col"
                  aria-sort={ariaSort}
                  style={{ width: c.width }}
                  className={cn("px-3 py-2 font-semibold text-text-secondary", alignCls(c))}
                >
                  {c.sortable ? (
                    <button
                      type="button"
                      onClick={() => toggleSort(c.id)}
                      className={cn("inline-flex cursor-pointer items-center gap-1 hover:text-text-primary", c.numeric || c.align === "right" ? "flex-row-reverse" : "")}
                    >
                      {c.header}
                      <SortIcon size={14} strokeWidth={1.5} aria-hidden="true" className={sort?.id === c.id ? "text-text-primary" : "text-text-muted"} />
                    </button>
                  ) : (
                    c.header
                  )}
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {loading ? (
            Array.from({ length: 6 }).map((_, i) => (
              <tr key={i} className={cn("border-b border-border-subtle", rowH)}>
                {selectable && <td className="px-3" />}
                {columns.map((c) => (
                  <td key={c.id} className="px-3">
                    <Skeleton height={12} className="w-3/4" />
                  </td>
                ))}
              </tr>
            ))
          ) : sorted.length === 0 ? (
            <tr>
              <td colSpan={colSpan} className="p-0">
                {empty ?? <div className="px-6 py-12 text-center text-sm text-text-muted">No data</div>}
              </td>
            </tr>
          ) : (
            sorted.map((row) => {
              const k = rowKey(row);
              const isSel = selected?.has(k);
              return (
                <tr
                  key={k}
                  data-selected={isSel || undefined}
                  onClick={onRowClick ? () => onRowClick(row) : undefined}
                  className={cn(
                    "border-b border-border-subtle last:border-0",
                    rowH,
                    onRowClick && "cursor-pointer",
                    "hover:bg-bg-raised data-[selected]:bg-[color-mix(in_srgb,var(--color-action-primary)_8%,transparent)]",
                  )}
                >
                  {selectable && (
                    <td className="px-3" onClick={(e) => e.stopPropagation()}>
                      <input
                        type="checkbox"
                        aria-label="Select row"
                        checked={isSel ?? false}
                        onChange={() => toggleRow(k)}
                        className="cursor-pointer accent-[var(--color-action-primary)]"
                      />
                    </td>
                  )}
                  {columns.map((c) => (
                    <td key={c.id} className={cn("px-3 text-text-primary", alignCls(c), c.numeric && "tabular-nums")}>
                      {c.cell(row)}
                    </td>
                  ))}
                </tr>
              );
            })
          )}
        </tbody>
      </table>
    </div>
  );
}
