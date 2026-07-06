"""Recording-device enumeration and the PortAudio<->voxtype name mapping.

One device choice in the tuner drives two audio stacks that name devices
differently:

- the tuner's own Record captures through sounddevice -> PortAudio -> ALSA, and
  opens a stream by PortAudio device INDEX.
- voxtype (the daemon and a live Stream session) captures through cpal 0.15's
  ALSA host, and selects a device by its ``[audio] device`` string, which it
  matches case-insensitively as a SUBSTRING against cpal's own device names.

The two never share an index, and their name strings are formatted differently,
so a row here is a triple: the label the dropdown shows (the PortAudio name),
the PortAudio index to capture with, and the voxtype device string to write.
The index is the tuner's handle, the string is voxtype's. A pure function maps
one PortAudio name to its voxtype string, so the whole model is unit-testable
without an audio device.

Enumeration is deliberately defensive: a headless host with no input device (or
one where PortAudio cannot even initialise) yields just the synthetic
``System default`` row rather than an exception, and the ALSA/PortAudio probe's
stderr chatter is silenced at the file-descriptor level (the C libraries write
straight to fd 2, so redirecting ``sys.stderr`` would not catch it).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

import sounddevice as sd

from voxtype_tuner.stderr_guard import suppress_c_stderr

if TYPE_CHECKING:
    from collections.abc import Callable

# voxtype's [audio] device default, and the value that always resolves in both
# stacks: PortAudio's default input and cpal's default device.
DEFAULT_DEVICE = "default"

# ALSA/PulseAudio/PipeWire bridge PCMs share one name across PortAudio and cpal,
# so their name is a safe cross-tool voxtype device string verbatim. A hardware
# card, by contrast, is named differently by each stack and needs the mapping
# below. Matched on the head before any ``:CARD=...`` qualifier.
_VIRTUAL_BRIDGES = frozenset({"default", "pulse", "pipewire", "sysdefault"})

# PortAudio's ALSA device names trail the raw hardware address, e.g.
# "HDA Intel PCH: ALC892 Analog (hw:0,0)". Strip it so the card/product
# description is left as the distinctive substring.
_HW_ADDRESS = re.compile(r"\s*\(hw:[^)]*\)\s*$")


@dataclass(frozen=True)
class InputDevice:
    """One selectable recording device.

    ``label`` is what the dropdown shows (the PortAudio device name, or the
    synthetic ``System default``). ``index`` is the PortAudio device index the
    tuner opens its capture stream with (``None`` = PortAudio's own default).
    ``voxtype_device`` is the ``[audio] device`` string voxtype's daemon and a
    live Stream session capture with, mapped from the PortAudio name (see
    :func:`voxtype_device_for`).
    """

    label: str
    index: int | None
    voxtype_device: str


# The always-present first row: neither stack is pinned to a specific device, so
# both fall back to their own default. Its voxtype string is DEFAULT_DEVICE and
# its index None, so Record opens the default input and Apply writes "default".
SYSTEM_DEFAULT = InputDevice(
    label="System default", index=None, voxtype_device=DEFAULT_DEVICE
)


def _is_virtual_bridge(name: str) -> bool:
    head = name.split(":", 1)[0].strip().lower()
    return head in _VIRTUAL_BRIDGES


def _hardware_substring(name: str) -> str:
    """The distinctive card/product substring of a hardware PortAudio name.

    Drops the trailing ``(hw:C,D)`` address, then keeps the card description
    ahead of the ``: <PCM description>`` split. voxtype matches its ``[audio]
    device`` case-insensitively as a substring of cpal's device name, so a short
    distinctive token (the card/product name) is the most likely to match.
    """
    without_address = _HW_ADDRESS.sub("", name).strip()
    return without_address.split(": ", 1)[0].strip()


def voxtype_device_for(name: str) -> str:
    """Map a PortAudio input-device name to voxtype's ``[audio] device`` string.

    A virtual bridge (default/pulse/pipewire/sysdefault, with or without a
    ``:CARD=...`` qualifier) is passed through verbatim, since both stacks name
    it identically. A hardware card maps to its distinctive card/product
    substring. Anything that leaves no usable substring falls back to
    ``"default"``, which always resolves.
    """
    if _is_virtual_bridge(name):
        return name
    return _hardware_substring(name) or DEFAULT_DEVICE


def enumerate_input_devices(
    query: Callable[[], Any] = sd.query_devices,
) -> list[InputDevice]:
    """Build the device dropdown's rows: System default plus every input device.

    Re-run on every dropdown open (there is no hot-reload), so a device plugged
    in after launch appears the next time the list is opened. The synthetic
    ``System default`` row is always first. Real devices are those with at least
    one input channel, deduplicated by name in PortAudio index order, each
    carrying its capture index and mapped voxtype device string.

    Never raises: a host with no input device (or one where PortAudio cannot
    initialise) yields just the ``System default`` row, so the caller degrades
    to a meterless default-capture UI rather than crashing. The probe's stderr
    chatter is suppressed.
    """
    rows: list[InputDevice] = [SYSTEM_DEFAULT]
    try:
        with suppress_c_stderr():
            catalog = query()
    except (sd.PortAudioError, OSError):
        return rows

    seen: set[str] = set()
    for index, device in enumerate(catalog):
        try:
            channels = int(device["max_input_channels"])
            name = str(device["name"])
        except (KeyError, TypeError, ValueError):
            continue
        if channels <= 0 or not name or name in seen:
            continue
        seen.add(name)
        rows.append(
            InputDevice(
                label=name, index=index, voxtype_device=voxtype_device_for(name)
            )
        )
    return rows


def has_input_device(query: Callable[[], Any] = sd.query_devices) -> bool:
    """Whether the host has at least one usable recording input.

    True when enumeration finds a real input-capable device (one with an input
    channel), False when every device is output-only, the catalog is empty, or
    the PortAudio/ALSA probe itself fails. The always-present synthetic
    ``System default`` row does NOT count as a device here: it is a fallback
    label, not evidence that a real microphone exists.

    Built on :func:`enumerate_input_devices`, so the same output-only filtering,
    dedup, crash-proofing and fd-level stderr suppression apply. The app gates
    the idle input meter on this so a no-microphone host never even reaches
    ``open_meter_stream`` (whose PortAudio open would spew ALSA warnings to fd 2
    before failing). ``query`` is injectable so tests can feed a fake list.
    """
    # enumerate always returns the System-default row first, then one row per
    # real input-capable device. More than that lone fallback row means there
    # is a microphone to tap.
    return len(enumerate_input_devices(query)) > 1


# sounddevice exposes PortAudio re-init only through these underscore-prefixed
# module functions (its documented way to force a device re-scan), so the
# private-member lint is acknowledged here with cause rather than worked around.
_pa_terminate = sd._terminate  # noqa: SLF001
_pa_initialize = sd._initialize  # noqa: SLF001


def reinitialize_portaudio(
    terminate: Callable[[], None] = _pa_terminate,
    initialize: Callable[[], None] = _pa_initialize,
) -> None:
    """Force PortAudio to rebuild its device list for a hotplug rescan.

    PortAudio caches the device catalog at ``Pa_Initialize`` time, so a
    microphone plugged in AFTER the process started is invisible to
    ``sd.query_devices`` until PortAudio is torn down and re-initialised. This
    terminate+initialize dance IS that re-init: it is deliberate, not dead code
    (drop it and a hotplugged mic never appears without an app restart).

    The terminate invalidates every open PortAudio stream, so the caller MUST
    close the idle meter first and MUST NOT call this while a recording,
    playback or meter stream is live. ``terminate``/``initialize`` are
    injectable so a test drives the rescan without touching the real audio
    system. The C-level ALSA chatter the re-init can emit is suppressed at the
    fd level.
    """
    with suppress_c_stderr():
        terminate()
        initialize()


def select_index(rows: list[InputDevice], voxtype_device: str) -> int:
    """The row to select for a seeded/target ``[audio] device`` string.

    The reverse of :func:`voxtype_device_for` for seeding from a config: an
    empty value or ``"default"`` selects the System default row, and any string
    that matches no row (an admin-written hardware substring the tuner cannot
    reconstruct, say) does too, so an unresolvable device reads as System
    default rather than a bogus selection. Otherwise the first row whose voxtype
    string matches (case-insensitively) is chosen.
    """
    target = (voxtype_device or DEFAULT_DEVICE).strip()
    if target.lower() == DEFAULT_DEVICE:
        return 0
    for i, row in enumerate(rows):
        if row.voxtype_device.lower() == target.lower():
            return i
    return 0
