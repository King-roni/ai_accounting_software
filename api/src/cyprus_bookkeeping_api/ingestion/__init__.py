"""Statement ingestion (R7.2).

Drives the B07 bank-statement pipeline for uploaded files so transactions
actually appear: read the uploaded bytes → parse (``parsers``) → normalize +
hash (``ingestion.normalize``) → dedup → ``transactions`` rows, via the existing
``*_statement_parse`` / ``*_statement_normalization`` / ``*_statement_dedup``
RPCs. The app-tier worker is the missing piece the DB primitives expected.
"""
