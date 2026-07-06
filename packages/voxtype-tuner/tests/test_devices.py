"""Tests for recording-device enumeration and the PortAudio<->voxtype mapping.

Pure logic, no real audio device: ``enumerate_input_devices`` takes an injected
``query`` returning a fake PortAudio device list (the same dict shape
``sd.query_devices`` yields), so dedup, the System-default synthesis, the
empty-host fallback and the crash-proofing are all deterministic here. The
name->device-string map and its reverse are pure functions.
"""

from __future__ import annotations

from typing import Any

import sounddevice as sd
from voxtype_tuner.devices import (
    DEFAULT_DEVICE,
    SYSTEM_DEFAULT,
    InputDevice,
    enumerate_input_devices,
    has_input_device,
    reinitialize_portaudio,
    select_index,
    voxtype_device_for,
)


def _dev(name: str, inputs: int, outputs: int = 2) -> dict[str, Any]:
    """A PortAudio device dict shaped like sd.query_devices' entries."""
    return {"name": name, "max_input_channels": inputs, "max_output_channels": outputs}


def test_empty_host_lists_only_system_default() -> None:
    rows = enumerate_input_devices(query=list)
    assert rows == [SYSTEM_DEFAULT]
    assert rows[0].label == "System default"
    assert rows[0].index is None
    assert rows[0].voxtype_device == DEFAULT_DEVICE


def test_system_default_is_always_first() -> None:
    rows = enumerate_input_devices(query=lambda: [_dev("pulse", 32)])
    assert rows[0] == SYSTEM_DEFAULT
    assert [r.label for r in rows] == ["System default", "pulse"]


def test_output_only_devices_are_filtered_out() -> None:
    rows = enumerate_input_devices(
        query=lambda: [
            _dev("Speakers", inputs=0, outputs=2),
            _dev("USB Mic: Audio (hw:1,0)", inputs=1, outputs=0),
        ]
    )
    assert [r.label for r in rows] == ["System default", "USB Mic: Audio (hw:1,0)"]


def test_index_is_the_portaudio_position_not_the_filtered_position() -> None:
    # The kept row's index must be its ORIGINAL position in the full device
    # list (its PortAudio device id), not its position after filtering, so
    # sd.InputStream(device=index) opens the right device.
    rows = enumerate_input_devices(
        query=lambda: [
            _dev("Speakers", inputs=0),  # index 0, filtered out
            _dev("Line Out", inputs=0),  # index 1, filtered out
            _dev("Blue Yeti: USB Audio (hw:2,0)", inputs=1),  # index 2, kept
        ]
    )
    assert len(rows) == 2
    assert rows[1].index == 2


def test_duplicate_names_are_deduped_keeping_the_first() -> None:
    rows = enumerate_input_devices(
        query=lambda: [
            _dev("pulse", 32),  # index 0
            _dev("pulse", 32),  # index 1, dropped as a duplicate name
            _dev("default", 32),  # index 2
        ]
    )
    assert [r.label for r in rows] == ["System default", "pulse", "default"]
    assert rows[1].index == 0


def test_a_probe_failure_degrades_to_system_default_only() -> None:
    # A headless host where PortAudio cannot even initialise must not crash the
    # tuner: enumeration swallows the PortAudioError and returns just System
    # default, so the UI degrades to default-capture rather than a traceback.
    def boom() -> list[dict[str, Any]]:
        msg = "cannot initialize PortAudio"
        raise sd.PortAudioError(msg)

    assert enumerate_input_devices(query=boom) == [SYSTEM_DEFAULT]


# --- has_input_device: the no-microphone predicate -----------------------------


def test_has_input_device_true_when_an_input_exists() -> None:
    assert has_input_device(query=lambda: [_dev("USB Mic", inputs=1)]) is True


def test_has_input_device_false_when_only_output_devices() -> None:
    rows = [_dev("Speakers", inputs=0), _dev("HDMI Out", inputs=0)]
    assert has_input_device(query=lambda: rows) is False


def test_has_input_device_false_for_an_empty_host() -> None:
    assert has_input_device(query=list) is False


def test_has_input_device_false_when_the_probe_fails() -> None:
    # A host where PortAudio cannot even initialise reads as no input rather
    # than raising, so the caller degrades to the no-microphone state.
    def boom() -> list[dict[str, Any]]:
        msg = "cannot initialize PortAudio"
        raise sd.PortAudioError(msg)

    assert has_input_device(query=boom) is False


# --- reinitialize_portaudio: the hotplug re-scan primitive ---------------------


def test_reinitialize_portaudio_terminates_then_initializes() -> None:
    # The terminate MUST precede the initialize (PortAudio rebuilds its cached
    # device list on the fresh init), so a hotplugged mic becomes visible.
    calls: list[str] = []
    reinitialize_portaudio(
        terminate=lambda: calls.append("terminate"),
        initialize=lambda: calls.append("initialize"),
    )
    assert calls == ["terminate", "initialize"]


def test_enumerated_rows_carry_the_mapped_voxtype_device() -> None:
    rows = enumerate_input_devices(
        query=lambda: [
            _dev("pulse", 32),
            _dev("HDA Intel PCH: ALC892 Analog (hw:0,0)", 2),
        ]
    )
    by_label = {r.label: r for r in rows}
    assert by_label["pulse"].voxtype_device == "pulse"
    assert (
        by_label["HDA Intel PCH: ALC892 Analog (hw:0,0)"].voxtype_device
        == "HDA Intel PCH"
    )


# --- the PortAudio name -> voxtype [audio] device map -------------------------


def test_virtual_bridges_map_verbatim() -> None:
    # default/pulse/pipewire/sysdefault name the same PCM in both stacks, so the
    # voxtype device string is the PortAudio name unchanged.
    for name in ("default", "pulse", "pipewire", "sysdefault"):
        assert voxtype_device_for(name) == name


def test_virtual_bridge_with_card_qualifier_maps_verbatim() -> None:
    # A qualified bridge (e.g. "sysdefault:CARD=PCH") is still a bridge and safe
    # cross-tool verbatim.
    assert voxtype_device_for("sysdefault:CARD=PCH") == "sysdefault:CARD=PCH"


def test_hardware_name_maps_to_the_card_substring() -> None:
    # The distinctive card/product description ahead of the ": <PCM>" split, with
    # the trailing (hw:C,D) address dropped: a short substring voxtype can match
    # case-insensitively against cpal's own device name.
    assert (
        voxtype_device_for("HDA Intel PCH: ALC892 Analog (hw:0,0)") == "HDA Intel PCH"
    )
    assert (
        voxtype_device_for("Samson C01U Pro: USB Audio (hw:2,0)") == "Samson C01U Pro"
    )
    assert voxtype_device_for("USB Audio Device: - (hw:1,0)") == "USB Audio Device"


def test_hardware_name_without_pcm_split_keeps_the_whole_label() -> None:
    assert voxtype_device_for("Scarlett 2i2 USB (hw:1,0)") == "Scarlett 2i2 USB"


def test_unresolvable_name_falls_back_to_default() -> None:
    # A name that leaves no usable substring (only an address) cannot resolve to
    # a distinctive token, so it falls back to the always-resolvable default.
    assert voxtype_device_for(" (hw:0,0)") == DEFAULT_DEVICE


# --- reverse map: seeded device string -> selected row ------------------------


def _rows() -> list[InputDevice]:
    return [
        SYSTEM_DEFAULT,
        InputDevice(label="pulse", index=0, voxtype_device="pulse"),
        InputDevice(
            label="Blue Yeti: USB Audio (hw:2,0)", index=2, voxtype_device="Blue Yeti"
        ),
    ]


def test_select_index_default_is_system_default() -> None:
    assert select_index(_rows(), "default") == 0


def test_select_index_empty_is_system_default() -> None:
    assert select_index(_rows(), "") == 0


def test_select_index_matches_a_device_string() -> None:
    assert select_index(_rows(), "pulse") == 1
    assert select_index(_rows(), "Blue Yeti") == 2


def test_select_index_is_case_insensitive() -> None:
    assert select_index(_rows(), "blue yeti") == 2


def test_select_index_unknown_string_is_system_default() -> None:
    # An admin-written hardware substring the tuner cannot reconstruct reads as
    # System default rather than a bogus selection.
    assert select_index(_rows(), "Some Other Mic") == 0
