#!/usr/bin/env python3
"""Enable the debug/JIT runtime state for LiveContainerTV over RemotePairing.

Two modes are supported:

* ``current`` attaches to the already-running host, then cleanly detaches.  This
  is the hardware-proven MVP7J flow that leaves CS_DEBUGGED set for that process.
* ``launch`` asks DVT to kill/relaunch the host *suspended*, attaches debugserver
  before application main executes, then detaches.  This is required for MVP8:
  an armed guest starts from process main, so JIT must already be enabled before
  guest entry is reached.

The helper is intentionally RemotePairing-only.  pymobiledevice3's no-root
userspace tunnel normally probes CoreDeviceProxy through usbmuxd first; that
probe cannot work in our Android/Termux proot because there is no usbmuxd.  We
therefore select an already-paired Apple TV directly through Bonjour
RemotePairing, then let pymobiledevice3 build its normal userspace TCP tunnel and
RSD stack.
"""

from __future__ import annotations

import asyncio
import sys
from typing import Optional

from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.remote.tunnel_service import get_remote_pairing_tunnel_services
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

DEBUG_SERVICE = "com.apple.internal.dt.remote.debugproxy"
DEFAULT_BUNDLE_ID = "dev.andre.livecontainertv.mvp3"
VALID_MODES = {"current", "launch"}


class JITEnableError(RuntimeError):
    pass


async def _close_services(services) -> None:
    for service in services:
        try:
            await service.close()
        except Exception:
            pass


async def _remote_pairing_only(serial: Optional[str], autopair: bool, remotepairing_fallback: bool = True):
    del autopair, remotepairing_fallback

    services = await get_remote_pairing_tunnel_services(udid=serial or None)
    if not services:
        if serial:
            raise JITEnableError(f"no se encontró RemotePairing para {serial}")
        raise JITEnableError("no se encontró ningún Apple TV emparejado por RemotePairing")

    by_identifier = {}
    for service in services:
        by_identifier.setdefault(service.remote_identifier, []).append(service)

    if serial:
        selected_identifier = serial
        if selected_identifier not in by_identifier:
            await _close_services(services)
            raise JITEnableError(f"RemotePairing {serial} no está disponible")
    else:
        identifiers = sorted(by_identifier)
        if len(identifiers) != 1:
            await _close_services(services)
            pretty = ", ".join(identifiers) if identifiers else "ninguno"
            raise JITEnableError(
                "hay varios dispositivos RemotePairing; configura "
                f"LCTV_REMOTE_PAIRING_ID. Detectados: {pretty}"
            )
        selected_identifier = identifiers[0]

    selected = by_identifier[selected_identifier][0]
    for service in services:
        if service is selected:
            continue
        try:
            await service.close()
        except Exception:
            pass

    print(f"LCTV JIT: RemotePairing {selected_identifier}", flush=True)
    return selected, None


async def _rsp_read(reader, writer, timeout: float = 30.0) -> str:
    while True:
        ch = await asyncio.wait_for(reader.readexactly(1), timeout)

        if ch == b"+":
            continue
        if ch == b"-":
            raise JITEnableError("debugserver respondió NACK")
        if ch != b"$":
            continue

        payload = bytearray()
        while True:
            ch = await asyncio.wait_for(reader.readexactly(1), timeout)
            if ch == b"#":
                break
            payload.extend(ch)

        checksum_raw = await asyncio.wait_for(reader.readexactly(2), timeout)
        try:
            expected = int(checksum_raw.decode("ascii"), 16)
        except ValueError as exc:
            raise JITEnableError("checksum RSP inválido") from exc

        actual = sum(payload) & 0xFF
        if actual != expected:
            writer.write(b"-")
            await writer.drain()
            continue

        writer.write(b"+")
        await writer.drain()
        return payload.decode("ascii", errors="replace")


async def _rsp(reader, writer, payload: str, timeout: float = 30.0) -> str:
    raw = payload.encode("ascii")
    checksum = sum(raw) & 0xFF
    packet = b"$" + raw + b"#" + f"{checksum:02x}".encode("ascii")
    writer.write(packet)
    await writer.drain()
    return await _rsp_read(reader, writer, timeout)


def _decode_error(reply: str) -> str:
    if not reply.startswith("E") or ";" not in reply:
        return reply
    code, encoded = reply.split(";", 1)
    try:
        return f"{code}: {bytes.fromhex(encoded).decode('utf-8', errors='replace')}"
    except Exception:
        return reply


async def _pid_for_bundle(rsd, bundle_id: str) -> int:
    async with DvtProvider(rsd) as dvt:
        async with ProcessControl(dvt) as process_control:
            return await process_control.process_identifier_for_bundle_identifier(bundle_id)


async def _prepare_pid(rsd, bundle_id: str, mode: str) -> int:
    if mode == "current":
        pid = await _pid_for_bundle(rsd, bundle_id)
        if pid <= 0:
            raise JITEnableError(
                f"{bundle_id} no está ejecutándose; abre LiveContainerTV en el Apple TV y reintenta"
            )
        return pid

    print("LCTV JIT: relanzando suspendido antes de main...", flush=True)
    async with DvtProvider(rsd) as dvt:
        async with ProcessControl(dvt) as process_control:
            old_pid = await process_control.process_identifier_for_bundle_identifier(bundle_id)
            if old_pid > 0:
                print(f"LCTV JIT: proceso anterior PID {old_pid} será reemplazado", flush=True)
            pid = await process_control.launch(
                bundle_id=bundle_id,
                kill_existing=True,
                start_suspended=True,
            )
    if pid <= 0:
        raise JITEnableError("DVT no pudo relanzar LiveContainerTV suspendido")
    print(f"LCTV JIT: lanzamiento suspendido PID {pid}", flush=True)
    return pid


async def enable_jit(bundle_id: str, remote_pairing_id: Optional[str], mode: str) -> None:
    if mode not in VALID_MODES:
        raise JITEnableError(f"modo inválido {mode!r}; usa current o launch")

    # Hardware-tested workaround for Termux/proot: skip the usbmux/CoreDeviceProxy
    # probe and feed UserspaceRsdTunnel an already-connected RemotePairing service.
    userspace_tunnel._create_no_root_tunnel_provider = _remote_pairing_only

    tunnel = userspace_tunnel.UserspaceRsdTunnel(
        serial=remote_pairing_id or None,
        autopair=False,
    )

    service = None
    attached = False
    reader = None
    writer = None

    print(f"LCTV JIT: modo={mode}", flush=True)
    print("LCTV JIT: abriendo túnel userspace...", flush=True)
    rsd = await tunnel.aopen()

    try:
        print(f"LCTV JIT: tvOS {rsd.product_version}", flush=True)
        pid = await _prepare_pid(rsd, bundle_id, mode)

        print(f"LCTV JIT: PID {pid}", flush=True)
        debug_port = rsd.get_service_port(DEBUG_SERVICE)
        print(f"LCTV JIT: debugproxy {debug_port}", flush=True)

        service = await rsd.start_lockdown_developer_service(DEBUG_SERVICE)
        await service.start()
        reader = service.reader
        writer = service.writer
        if reader is None or writer is None:
            raise JITEnableError("debugserver no abrió reader/writer")

        supported = await _rsp(reader, writer, "qSupported")
        if not supported:
            raise JITEnableError("debugserver no respondió qSupported")

        # Optional packets. Older debugservers may not support one of them.
        try:
            await _rsp(reader, writer, "QEnableErrorStrings")
        except Exception:
            pass
        try:
            await _rsp(reader, writer, "QSetDetachOnError:1")
        except Exception:
            pass

        reply = await _rsp(reader, writer, f"vAttach;{pid:x}", timeout=45.0)
        if not (reply.startswith("T") or reply.startswith("S")):
            raise JITEnableError(f"attach falló: {_decode_error(reply)}")

        attached = True
        print("LCTV JIT: ATTACH OK", flush=True)

        # Give tvOS a moment to commit the runtime debug state before detach.
        await asyncio.sleep(1.0)

        # RSP detach resumes the debuggee. In launch mode this releases the process
        # that DVT started suspended, allowing application main (and an armed MVP8
        # guest) to run only after CS_DEBUGGED has been established.
        detach_reply = await _rsp(reader, writer, "D", timeout=15.0)
        if detach_reply != "OK":
            raise JITEnableError(f"detach inesperado: {detach_reply}")
        attached = False
        print("LCTV JIT: DETACH OK", flush=True)

        await asyncio.sleep(0.35)
        pid_after = await _pid_for_bundle(rsd, bundle_id)

        if mode == "current":
            if pid_after != pid:
                raise JITEnableError(
                    f"el proceso cambió durante el attach (antes {pid}, después {pid_after}); vuelve a ejecutar lctv jit"
                )
            print("LCTV JIT: PASS — JIT habilitado para el proceso actual", flush=True)
            print("LCTV JIT: si la app se reinicia o se reinstala, ejecuta 'lctv jit' otra vez", flush=True)
        else:
            if pid_after == pid:
                print("LCTV JIT: proceso relanzado continúa ejecutándose", flush=True)
            else:
                print(
                    "LCTV JIT: WARN — el proceso salió después del detach; JIT sí se aplicó antes de main. "
                    "Revisa el trace/crash del guest.",
                    flush=True,
                )
            print("LCTV JIT: PASS — lanzamiento debugged completado", flush=True)

    finally:
        if attached and reader is not None and writer is not None:
            try:
                await _rsp(reader, writer, "D", timeout=5.0)
            except Exception:
                pass
        if service is not None:
            try:
                await service.close()
            except Exception:
                pass
        await tunnel.aclose()


def main() -> int:
    bundle_id = sys.argv[1].strip() if len(sys.argv) > 1 and sys.argv[1].strip() else DEFAULT_BUNDLE_ID
    remote_pairing_id = sys.argv[2].strip() if len(sys.argv) > 2 and sys.argv[2].strip() else None
    mode = sys.argv[3].strip().lower() if len(sys.argv) > 3 and sys.argv[3].strip() else "current"

    try:
        asyncio.run(enable_jit(bundle_id, remote_pairing_id, mode))
    except KeyboardInterrupt:
        print("LCTV JIT: cancelado", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"LCTV JIT: ERROR — {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
