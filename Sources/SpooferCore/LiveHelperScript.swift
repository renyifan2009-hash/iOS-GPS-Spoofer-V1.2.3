// The Python half of the "live" location engine. Kept in its own file so the
// test suite (Tests/LiveHelperTests) can extract and exercise it without a
// Swift toolchain. The literal is raw (`#"""`) and its closing delimiter sits in
// column 0, so the script is embedded byte-for-byte.

extension LiveHelper {
    /// Bumped whenever the stdin/stdout protocol changes.
    public static let protocolVersion = 1

    public static let script: String = #"""
# iosgpsspoof live-location helper (protocol v1).
#
# Runs pymobiledevice3's own CLI in-process for a `... simulate-location set`
# command, so device selection and every tunnel transport (--native, --tunnel,
# --userspace) behave exactly like the installed pymobiledevice3. The only
# change: the location-simulation service's `set` is wrapped so that, once the
# first fix is applied, the channel stays open and further commands are read
# from stdin, one per line:
#
#   set <lat> <lon>    move the simulated location (no new tunnel needed)
#   clear              restore the real location, keep the channel open
#   ping               liveness check
#   quit [clear]       optionally clear, then close the channel and exit
#
# Replies go to stdout, each line prefixed with "@@spoof ":
#
#   READY <lat> <lon>  channel open, first fix applied
#   OK <lat> <lon>     a `set` was applied
#   CLEARED | PONG | BYE | ERROR <message>
#   PROBE <pymobiledevice3 version> <protocol>    (--probe only)
#   INCOMPATIBLE <reason>                         (exit status 86)
#   EXIT <status>
#
# EOF on stdin means the parent app died: the location is cleared and the
# helper exits, so a crashed app never leaves a phone stuck somewhere.
#
# A `set` or `clear` the iPhone doesn't answer within SET_TIMEOUT seconds means
# the channel is dead (a cable pulled, a tunnel gone). The helper then reports
# it and exits at once, so the app opens a new channel. It does not wait for
# the dead channel to close, because that can hang as well.

import asyncio
import importlib
import inspect
import os
import queue
import sys
import threading

PROTOCOL = 1
PREFIX = "@@spoof "
INCOMPATIBLE_EXIT = 86
EOF = object()
SET_TIMEOUT = 15

SERVICE_CLASSES = (
    ("pymobiledevice3.services.dvt.instruments.location_simulation", "LocationSimulation"),
    ("pymobiledevice3.services.simulate_location", "DtSimulateLocation"),
)

_out_lock = threading.Lock()


class _State:
    engaged = False


STATE = _State()


def emit(*parts):
    line = PREFIX + " ".join(str(p) for p in parts) + "\n"
    with _out_lock:
        try:
            sys.stdout.write(line)
            sys.stdout.flush()
        except Exception:
            pass


def describe(error):
    text = str(error).replace("\n", " ").strip()
    return type(error).__name__ + (": " + text if text else "")


def leave_now(status):
    # The channel is dead and closing it can hang too: go without cleaning up.
    try:
        sys.stdout.flush()
        sys.stderr.flush()
    except Exception:
        pass
    os._exit(status)


EXIT_NOW = leave_now   # tests swap this out


async def bounded(call, what):
    # Wait for the iPhone, but not for ever.
    try:
        return await asyncio.wait_for(call, timeout=SET_TIMEOUT)
    except asyncio.TimeoutError:
        emit("ERROR", "timed out: the iPhone did not answer %s within %s seconds" % (what, SET_TIMEOUT))
        EXIT_NOW(1)
        raise


def parse_command(raw):
    parts = raw.strip().split()
    if not parts:
        return None
    name = parts[0].lower()
    if name == "set":
        if len(parts) != 3:
            return ("error", "usage: set <lat> <lon>")
        try:
            lat, lon = float(parts[1]), float(parts[2])
        except ValueError:
            return ("error", "bad coordinate: " + " ".join(parts[1:]))
        if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
            return ("error", "coordinate out of range: " + " ".join(parts[1:]))
        return ("set", lat, lon)
    if name == "clear":
        return ("clear",)
    if name == "ping":
        return ("ping",)
    if name == "quit":
        return ("quit", len(parts) > 1 and parts[1].lower() == "clear")
    return ("error", "unknown command: " + name)


def superseded(items, index):
    # A `set` immediately followed by another queued `set` is stale: skip it.
    if index + 1 >= len(items) or items[index + 1] is EOF:
        return False
    following = parse_command(items[index + 1])
    return following is not None and following[0] == "set"


def start_reader(deliver, stream):
    def run():
        try:
            while True:
                raw = stream.readline()
                if not raw:
                    break
                deliver(raw)
        except Exception:
            pass
        deliver(EOF)

    thread = threading.Thread(target=run, name="iosgpsspoof-stdin", daemon=True)
    thread.start()
    return thread


# ---- async services (pymobiledevice3 >= 9) ---------------------------------

async def _clear_quietly_async(service):
    try:
        await asyncio.wait_for(service.clear(), timeout=8)
        emit("CLEARED")
    except Exception as error:
        emit("ERROR", "clear failed: " + describe(error))


async def serve_async(service, original_set, stream):
    loop = asyncio.get_running_loop()
    inbox = asyncio.Queue()
    start_reader(lambda item: loop.call_soon_threadsafe(inbox.put_nowait, item), stream)
    while True:
        items = [await inbox.get()]
        while not inbox.empty():
            items.append(inbox.get_nowait())
        for index, item in enumerate(items):
            if item is EOF:
                await _clear_quietly_async(service)
                return
            command = parse_command(item)
            if command is None or (command[0] == "set" and superseded(items, index)):
                continue
            kind = command[0]
            if kind == "set":
                try:
                    await bounded(original_set(service, command[1], command[2]), "a new location")
                except asyncio.TimeoutError:
                    raise   # `bounded` has said so
                except Exception as error:
                    emit("ERROR", describe(error))
                    raise
                emit("OK", repr(command[1]), repr(command[2]))
            elif kind == "clear":
                try:
                    await bounded(service.clear(), "the clear")
                except asyncio.TimeoutError:
                    raise
                except Exception as error:
                    emit("ERROR", describe(error))
                    raise
                emit("CLEARED")
            elif kind == "ping":
                emit("PONG")
            elif kind == "quit":
                if command[1]:
                    await _clear_quietly_async(service)
                emit("BYE")
                return
            else:
                emit("ERROR", command[1])


# ---- sync services (pymobiledevice3 < 9) -----------------------------------
# These can't be timed out from here. The app watches for an answer instead.

def _clear_quietly_sync(service):
    try:
        service.clear()
        emit("CLEARED")
    except Exception as error:
        emit("ERROR", "clear failed: " + describe(error))


def serve_sync(service, original_set, stream):
    inbox = queue.Queue()
    start_reader(inbox.put, stream)
    while True:
        items = [inbox.get()]
        while True:
            try:
                items.append(inbox.get_nowait())
            except queue.Empty:
                break
        for index, item in enumerate(items):
            if item is EOF:
                _clear_quietly_sync(service)
                return
            command = parse_command(item)
            if command is None or (command[0] == "set" and superseded(items, index)):
                continue
            kind = command[0]
            if kind == "set":
                try:
                    original_set(service, command[1], command[2])
                except Exception as error:
                    emit("ERROR", describe(error))
                    raise
                emit("OK", repr(command[1]), repr(command[2]))
            elif kind == "clear":
                try:
                    service.clear()
                except Exception as error:
                    emit("ERROR", describe(error))
                    raise
                emit("CLEARED")
            elif kind == "ping":
                emit("PONG")
            elif kind == "quit":
                if command[1]:
                    _clear_quietly_sync(service)
                emit("BYE")
                return
            else:
                emit("ERROR", command[1])


# ---- patching ----------------------------------------------------------------

def make_live_set(original, stream=None):
    if inspect.iscoroutinefunction(original):
        async def live_set(self, latitude, longitude):
            await original(self, latitude, longitude)
            if STATE.engaged:
                return
            STATE.engaged = True
            emit("READY", repr(float(latitude)), repr(float(longitude)))
            await serve_async(self, original, stream or sys.stdin)
    else:
        def live_set(self, latitude, longitude):
            original(self, latitude, longitude)
            if STATE.engaged:
                return
            STATE.engaged = True
            emit("READY", repr(float(latitude)), repr(float(longitude)))
            serve_sync(self, original, stream or sys.stdin)
    live_set.__name__ = "set"
    live_set.__wrapped__ = original
    return live_set


def find_service_classes():
    found = []
    for module_name, class_name in SERVICE_CLASSES:
        try:
            cls = getattr(importlib.import_module(module_name), class_name)
        except Exception:
            continue
        if callable(getattr(cls, "set", None)) and callable(getattr(cls, "clear", None)):
            found.append(cls)
    return found


def install_patches(classes, stream=None):
    for cls in classes:
        cls.set = make_live_set(getattr(cls, "set"), stream)


def patch_wait_return():
    # After the live loop ends, the CLI command would block in wait_return()
    # until a signal arrives; once engaged, let it return immediately instead.
    # pymobiledevice3 11.50 made wait_return() async and awaits it, so the
    # replacement has to be async whenever the original is.
    try:
        from pymobiledevice3.osu.os_utils import get_os_utils
        utils_type = type(get_os_utils())
    except Exception:
        return False
    patched = False
    for klass in utils_type.__mro__:
        original = klass.__dict__.get("wait_return")
        if original is None:
            continue

        if inspect.iscoroutinefunction(original):
            async def wait_return(self, *args, _original=original, **kwargs):
                if STATE.engaged:
                    return None
                return await _original(self, *args, **kwargs)
        else:
            def wait_return(self, *args, _original=original, **kwargs):
                if STATE.engaged:
                    return None
                return _original(self, *args, **kwargs)

        setattr(klass, "wait_return", wait_return)
        patched = True
    return patched


def pymobiledevice3_version():
    try:
        from importlib.metadata import version
        return version("pymobiledevice3")
    except Exception:
        pass
    try:
        import pymobiledevice3
        return str(getattr(pymobiledevice3, "__version__", "unknown"))
    except Exception:
        return "unknown"


def exit_status(value):
    if value is None:
        return 0
    if isinstance(value, int):
        return int(value)
    return 1


def main(argv):
    probe = False
    if argv and argv[0] == "--probe":
        probe, argv = True, argv[1:]
    if argv and argv[0] == "--":
        argv = argv[1:]
    try:
        entry = getattr(importlib.import_module("pymobiledevice3.__main__"), "main")
    except Exception as error:
        emit("INCOMPATIBLE", "cannot load the pymobiledevice3 CLI: " + describe(error))
        return INCOMPATIBLE_EXIT
    classes = find_service_classes()
    if not classes:
        emit("INCOMPATIBLE", "location-simulation service not found in this pymobiledevice3")
        return INCOMPATIBLE_EXIT
    if probe:
        emit("PROBE", pymobiledevice3_version(), PROTOCOL)
        return 0
    if not argv:
        emit("ERROR", "no pymobiledevice3 arguments given")
        return 2
    install_patches(classes)
    patch_wait_return()
    sys.argv = ["pymobiledevice3"] + list(argv)
    try:
        status = exit_status(entry())
    except SystemExit as stop:
        status = exit_status(stop.code)
    emit("EXIT", status)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
"""#
}
