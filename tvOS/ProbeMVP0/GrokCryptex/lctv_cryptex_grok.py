#!/usr/bin/env python3
"""Grok overlays for LiveContainerTV cryptex install.

Safe changes only:

* send the XPC file-transfer preamble with the same flow-control loop used
  for the payload (the original code ignored the returned byte count);
* log announced vs sent sizes for the five install assets;
* allow LCTV_CRYPTEX_IMAGE_TYPE_INDEX to override the captured default of 10
  without baking an unconfirmed tvOS table into the client.

This module does not sweep indexes and does not uninstall anything.
"""

from __future__ import annotations

import os
import sys


GROK_TAG = "LCTV GROK"


def _log(message: str) -> None:
    print(f"{GROK_TAG}: {message}", flush=True)


def _image_type_index(default: int) -> int:
    raw = os.environ.get("LCTV_CRYPTEX_IMAGE_TYPE_INDEX", "").strip()
    if not raw:
        return default
    try:
        value = int(raw, 10)
    except ValueError as exc:
        raise RuntimeError(
            f"LCTV_CRYPTEX_IMAGE_TYPE_INDEX inválido: {raw!r}"
        ) from exc
    if value < 0 or value >= 12:
        raise RuntimeError(
            f"LCTV_CRYPTEX_IMAGE_TYPE_INDEX fuera de rango (0-11): {value}"
        )
    return value


def _patch_send_file_transfer() -> None:
    from pymobiledevice3.remote.remotexpc import RemoteXPCConnection
    from pymobiledevice3.remote.xpc_message import XpcFlags, XpcWrapper
    from hyperframe.frame import DataFrame, HeadersFrame

    if getattr(RemoteXPCConnection.send_file_transfer, "_lctv_grok_preamble", False):
        return

    original = RemoteXPCConnection.send_file_transfer

    async def send_file_transfer(self, transfer_id: int, data: bytes) -> None:
        stream_id = self._next_outbound_stream_id
        self._next_outbound_stream_id += 2

        await self._send_frame(HeadersFrame(stream_id=stream_id, flags=["END_HEADERS"]))
        preamble = XpcWrapper.build({
            "flags": XpcFlags.FILE_TX_STREAM_REQUEST | XpcFlags.ALWAYS_SET,
            "message": {"message_id": transfer_id, "payload": None},
        })

        sent = 0
        while sent < len(preamble):
            sent += await self._send_flow_controlled(
                stream_id, preamble, sent, len(preamble)
            )
        if sent != len(preamble):
            raise RuntimeError(
                f"preámbulo incompleto id={transfer_id} stream={stream_id}: "
                f"{sent}/{len(preamble)}"
            )

        offset = 0
        while offset < len(data):
            offset += await self._send_flow_controlled(
                stream_id, data, offset, len(data)
            )
        await self._send_frame(DataFrame(stream_id=stream_id, data=b"", flags=["END_STREAM"]))
        self._finished_file_transfer_streams.add(stream_id)
        _log(
            f"transfer id={transfer_id} stream={stream_id} "
            f"preamble={sent} payload={offset}"
        )

    send_file_transfer._lctv_grok_preamble = True  # type: ignore[attr-defined]
    send_file_transfer._lctv_grok_wrapped = original  # type: ignore[attr-defined]
    RemoteXPCConnection.send_file_transfer = send_file_transfer  # type: ignore[method-assign]
    _log("preámbulo file-transfer: bucle de ventana aplicado")


def _patch_cryptexd() -> None:
    from pymobiledevice3.services import cryptexd as cryptexd_mod

    default_index = int(cryptexd_mod.DDI_IMAGE_TYPE_INDEX)
    chosen = _image_type_index(default_index)
    if chosen != default_index:
        cryptexd_mod.DDI_IMAGE_TYPE_INDEX = chosen
        _log(f"image-type-index override {default_index} -> {chosen}")
    else:
        _log(f"image-type-index={chosen} (default capturado de devicectl)")

    original_install = cryptexd_mod.CryptexdService.install
    if getattr(original_install, "_lctv_grok_logged", False):
        return

    async def install(self, image, trustcache, im4m, info, volumehash, *args, **kwargs):
        planned = (
            ("image", image),
            ("trustcache", trustcache),
            ("im4m", im4m),
            ("info", info),
            ("volumehash", volumehash),
        )
        for name, payload in planned:
            _log(f"install envía {name}={len(payload)} bytes")
        if len(volumehash) == len(image):
            _log(
                "WARN volumehash tiene el mismo tamaño que image; "
                "no continuar si esto no es un ticket/hash real"
            )
        index = kwargs.get("image_type_index", cryptexd_mod.DDI_IMAGE_TYPE_INDEX)
        kwargs["image_type_index"] = index
        _log(f"install image-type-index={index}")
        return await original_install(
            self, image, trustcache, im4m, info, volumehash, *args, **kwargs
        )

    install._lctv_grok_logged = True  # type: ignore[attr-defined]
    cryptexd_mod.CryptexdService.install = install  # type: ignore[method-assign]


def apply_grok_cryptex_patches() -> None:
    """Patch the imported pymobiledevice3 modules in this process."""
    _patch_send_file_transfer()
    _patch_cryptexd()


def main() -> int:
    apply_grok_cryptex_patches()
    _log("parches cargados; no hay conexión de dispositivo en este comando")
    return 0


if __name__ == "__main__":
    sys.exit(main())
