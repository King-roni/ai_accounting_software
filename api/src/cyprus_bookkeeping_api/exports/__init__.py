"""Export file-generation (R7.1).

A thin, transport-agnostic serializer layer for the export-generation worker:
the DB composes every byte of report *data* (the ``_compose_*`` helpers); this
package renders it to the requested format (CSV/XLSX/PDF/JSON/XML/ZIP), uploads
to the ``export-artifacts`` bucket, and marks the export COMPLETED/FAILED.

PDF and XLSX writers are dependency-free (no reportlab/openpyxl) so the worker
stays light and its output is stable for identical input.
"""
