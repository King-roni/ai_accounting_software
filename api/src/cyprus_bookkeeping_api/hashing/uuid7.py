"""UUID v7 generation per RFC 9562.

Layout (128 bits / 16 bytes):
    | 48 bits unix-ms | 4 bits version=7 | 12 bits rand_a |
    |  2 bits variant=10 | 62 bits rand_b |

The leading 48-bit millisecond timestamp gives lexical sorting in
insertion order — useful as a primary key (we already use it via the
Postgres `gen_uuid_v7()` helper from B02·P01). Python's stdlib has no
v7 generator as of 3.12; this implementation matches the SQL helper
byte-for-byte.
"""
from __future__ import annotations

import secrets
import time


def new_uuid() -> str:
    """Generate a fresh UUID v7 as the canonical lowercase-hex string
    with dashes, e.g. `019e4138-677c-726b-b427-c90b1215d350`.
    """
    ms = int(time.time() * 1000) & ((1 << 48) - 1)
    rand_a = secrets.randbits(12)
    rand_b = secrets.randbits(62)

    b = bytearray(16)
    b[0] = (ms >> 40) & 0xFF
    b[1] = (ms >> 32) & 0xFF
    b[2] = (ms >> 24) & 0xFF
    b[3] = (ms >> 16) & 0xFF
    b[4] = (ms >> 8) & 0xFF
    b[5] = ms & 0xFF
    b[6] = (7 << 4) | ((rand_a >> 8) & 0xF)
    b[7] = rand_a & 0xFF
    b[8] = (0b10 << 6) | ((rand_b >> 56) & 0x3F)
    b[9] = (rand_b >> 48) & 0xFF
    b[10] = (rand_b >> 40) & 0xFF
    b[11] = (rand_b >> 32) & 0xFF
    b[12] = (rand_b >> 24) & 0xFF
    b[13] = (rand_b >> 16) & 0xFF
    b[14] = (rand_b >> 8) & 0xFF
    b[15] = rand_b & 0xFF

    hex_str = b.hex()
    return f"{hex_str[0:8]}-{hex_str[8:12]}-{hex_str[12:16]}-{hex_str[16:20]}-{hex_str[20:]}"


def parse_uuid7_timestamp(uuid_str: str) -> int:
    """Extract the unix-ms timestamp from a UUID v7 string. Useful for
    debugging and for B05 audit-log retention sweeps.
    """
    hex_only = uuid_str.replace("-", "")
    if len(hex_only) != 32:
        raise ValueError("not a 16-byte UUID")
    version = (int(hex_only[12], 16) >> 0) & 0xF  # high nibble of byte 6
    # Actually the version is the high nibble of byte 6: hex_only[12] is
    # the high nibble. Read both for clarity.
    version = int(hex_only[12], 16)
    if version != 7:
        raise ValueError(f"not a UUID v7 (version={version})")
    ms = int(hex_only[0:12], 16)
    return ms
