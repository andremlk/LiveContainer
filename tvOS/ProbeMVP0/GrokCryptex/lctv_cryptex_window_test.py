#!/usr/bin/env python3
"""Local flow-control test for the Grok cryptex file-transfer preamble.

Does not talk to the Apple TV. It replays the same send loop used on device
against a fake peer window smaller than the preamble, then checks that:

* the unpatched one-shot send leaves a truncated preamble;
* the Grok loop delivers the full preamble plus the exact payload.
"""

from __future__ import annotations

import asyncio
import sys
from dataclasses import dataclass, field
from typing import List


PREAMBLE = b"PREAMBLE-XPC-HEADER-0123456789"
PAYLOADS = {
    "image": b"I" * 64,
    "trustcache": b"T" * 17,
    "im4m": b"M" * 19,
    "info": b"N" * 11,
    "volumehash": b"H" * 13,
}


@dataclass
class FakeLink:
    window: int
    frames: List[bytes] = field(default_factory=list)

    async def send_chunk(self, data: bytes, offset: int, limit: int) -> int:
        if self.window <= 0:
            raise RuntimeError("ventana agotada")
        n = min(self.window, limit - offset, len(data) - offset)
        self.frames.append(data[offset : offset + n])
        self.window -= n
        return n


async def send_once(link: FakeLink, preamble: bytes, payload: bytes) -> bytes:
    """Mirrors the current client: ignore the returned preamble length."""
    await link.send_chunk(preamble, 0, len(preamble))
    offset = 0
    while offset < len(payload):
        offset += await link.send_chunk(payload, offset, len(payload))
    return b"".join(link.frames)


async def send_looped(link: FakeLink, preamble: bytes, payload: bytes) -> bytes:
    """Grok client: drain preamble and payload through the same window loop."""
    sent = 0
    while sent < len(preamble):
        sent += await link.send_chunk(preamble, sent, len(preamble))
    offset = 0
    while offset < len(payload):
        offset += await link.send_chunk(payload, offset, len(payload))
    return b"".join(link.frames)


def expect(cond: bool, message: str) -> None:
    status = "PASS" if cond else "FAIL"
    print(f"LCTV GROK TEST: {status} {message}", flush=True)
    if not cond:
        raise SystemExit(1)


async def main() -> int:
    window = 8
    print(f"LCTV GROK TEST: ventana={window} preamble={len(PREAMBLE)}", flush=True)

    broken = FakeLink(window=window)
    try:
        broken_bytes = await send_once(broken, PREAMBLE, PAYLOADS["volumehash"])
    except RuntimeError:
        broken_bytes = b"".join(broken.frames)
    expect(
        not broken_bytes.startswith(PREAMBLE + PAYLOADS["volumehash"]),
        "el envío de un solo tiro no entrega preámbulo+hash con ventana corta",
    )
    expect(
        len(broken.frames[0]) < len(PREAMBLE),
        "el primer frame del envío roto es un preámbulo truncado",
    )

    for name, payload in PAYLOADS.items():
        link = FakeLink(window=window)
        original_send = link.send_chunk

        async def send_chunk(data: bytes, offset: int, limit: int, _link=link) -> int:
            if _link.window <= 0:
                _link.window = window
            return await original_send(data, offset, limit)

        link.send_chunk = send_chunk  # type: ignore[method-assign]
        wire = await send_looped(link, PREAMBLE, payload)
        expect(
            wire == PREAMBLE + payload,
            f"{name}: preámbulo+payload reconstruidos ({len(payload)} bytes)",
        )
        if name != "image":
            expect(
                not wire.endswith(PAYLOADS["image"]),
                f"{name}: no se coló el payload de image",
            )

    image = PAYLOADS["image"]
    hashed = PAYLOADS["volumehash"]
    expect(len(image) != len(hashed), "image y volumehash siguen midiendo distinto")
    print("LCTV GROK TEST: PASS local window/preamble", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
