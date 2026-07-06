"""Headless-capable Slint tuner: wires the take's record/play/transcribe
controls, the engine→model dropdown and the language checklist to the real
backends.

Blocking work (subprocess transcription, device capture/playback) runs on worker
threads. Results are marshalled back onto the Slint event loop with
``invoke_from_event_loop`` before any model/property is touched, so a slow
backend can never freeze the UI.
"""

from __future__ import annotations

import datetime
import itertools
import logging
import os
import pathlib
import sys
import threading
from typing import TYPE_CHECKING, Any

import slint

# slint._native resolves to the MCP/headless-capable "dev" binary when
# SLINT_MCP_PORT is set (run.sh sets it) and the lean release binary otherwise.
# Either way its .native carries invoke_from_event_loop, the thread→event-loop
# bridge Slint's own SlintEventLoop wraps. It is typed in slint.pyi but not
# re-exported at the top level (slint.invoke_from_event_loop does not exist), so
# reach it through the native module.
from slint import _native

from voxtype_tuner import (
    apply,
    clipboard,
    defaults,
    lifecycle,
    models,
    params,
    slots,
    streaming,
    waveform,
)
from voxtype_tuner.devices import (
    DEFAULT_DEVICE,
    SYSTEM_DEFAULT,
    InputDevice,
    enumerate_input_devices,
    reinitialize_portaudio,
    select_index,
)
from voxtype_tuner.metrics import (
    batch_caption,
    format_timing,
    streaming_caption,
    wav_duration_secs,
)
from voxtype_tuner.player import PlayerError, TakePlayer
from voxtype_tuner.transcribe import CancelHandle, transcribe
from voxtype_tuner.wiring import (
    InputMeter,
    TakeRecorder,
    build_params,
    format_download_progress,
    serialize_language,
    summarize_language,
    transcription_output,
)

if TYPE_CHECKING:
    from collections.abc import Callable

    from voxtype_tuner.params import TranscribeParams

# The loader shim resolves .native to the dev or lean binary at import time.
# Pin it once here so every marshalling call below reaches that same loop.
native = _native.native

# ui/app.slint lives at the package root, one level above this package dir.
SLINT_FILE = pathlib.Path(__file__).resolve().parent.parent / "ui" / "app.slint"

# The real voxtype binary is not on PATH on dev hosts. Tests point this at a
# fake script that echoes a known transcript.
VOXTYPE_BIN = os.environ.get("VOXTYPE_BIN", "voxtype")

# The system-clipboard writer for the transcript's Copy button. The packaged
# wrapper puts wl-clipboard on PATH, so a bare `wl-copy` resolves there. Tests
# point this at a fake that records what was copied, exactly like VOXTYPE_BIN.
WL_COPY_BIN = os.environ.get("WL_COPY_BIN", "wl-copy")

# Nemotron ships no first-use downloader, so unlike whisper/parakeet its model is
# Nix-provisioned and handed to the tuner by store path. The packaged wrapper
# --set-default's this to the realised model dir. transcribe() pins it into the
# generated [nemotron] config. Unset in a bare checkout, where a nemotron
# transcribe then surfaces voxtype's own "model not found" (no path to pin).
VOXTYPE_NEMOTRON_MODEL = os.environ.get("VOXTYPE_NEMOTRON_MODEL")

# The nix wrapper and run.sh point this at a bundled, read-only default sample
# (whisper.cpp's public-domain jfk.wav) by store path, so a fresh run is
# instantly transcribable without recording first. Unset in a bare checkout,
# where seeding is silently skipped.
SAMPLE_WAV = os.environ.get("VOXTYPE_TUNER_SAMPLE_WAV")

# The single row the device picker shows when the host has no recording input,
# instead of a bare "System default" that would imply a real microphone exists.
_NO_INPUT_DEVICE_LABEL = "No microphone detected"

# Caption per availability state. The two ready forms name their provenance
# (a user download transcribes by name, a system model only via its absolute
# config-provided path), so the caption always tells the truth about which
# bytes a transcribe would use.
_STATUS_CAPTIONS: dict[str, str] = {
    "user": "ready (user download) ✓",
    "system": "ready (system) ✓",
    "absent": "not downloaded",
}


def _run_bg(work: Callable[[], None]) -> None:
    """Run blocking work off the UI thread on a throwaway daemon thread."""
    threading.Thread(target=work, daemon=True).start()


def configure(
    instance: Any, startup: defaults.StartupDefaults | None = None
) -> tuple[InputMeter, TakePlayer]:
    """Populate the controls and bind every callback to the real backends.

    Split out from main() so the wiring (especially the engine→model
    dependency and the transcript marshalling) can be driven directly against
    a MainWindow instance without spinning the event loop. ``startup`` is
    resolved from the environment when not injected (tests inject). Two
    layers: ``startup.system`` is the baseline the indicators diff against and
    Reset restores. ``startup.initial`` (the user's effective config when one
    exists) is what the controls start at.

    Returns the idle-only input-level meter it wired but did NOT start, so
    main() starts it once the event loop owns the thread and ``_run`` tears it
    down. A caller that never starts it (every headless test) touches no audio.
    """
    if startup is None:
        startup = defaults.load_startup()
    sysdef = startup.system
    # Both seedings share one catalog (each contributes the other's
    # off-catalog values via `also`), so starting at the user's values and
    # resetting to the baseline only ever moves selections, never the lists.
    seeded_initial = defaults.seed_controls(startup.initial, also=sysdef.params)
    seeded_baseline = defaults.seed_controls(sysdef.params, also=startup.initial)

    # The language checklist's backing state. Kept in the closure so the
    # serializer never re-reads the UI models row by row through property
    # getters that Slint may proxy. Every mutation below writes both.
    language_rows: list[str] = []
    language_checked: slint.ListModel[bool] = slint.ListModel([])

    def refresh_language_summary() -> None:
        checked = [
            bool(language_checked.row_data(i)) for i in range(len(language_rows))
        ]
        instance.language_summary = summarize_language(
            bool(instance.language_auto), language_rows, checked
        )

    def current_language() -> str:
        checked = [
            bool(language_checked.row_data(i)) for i in range(len(language_rows))
        ]
        return serialize_language(bool(instance.language_auto), language_rows, checked)

    def apply_seeded(seeded: defaults.SeededControls) -> None:
        # Push the seeded catalogs AND selections into the UI (startup and the
        # Reset action). The catalogs come from seed_controls so an off-catalog
        # value (custom store-path model, unusual threshold…) is a real
        # selectable entry, not silently dropped.
        nonlocal language_rows, language_checked
        instance.engine_list = slint.ListModel(seeded.engines)
        instance.engine_index = seeded.engine_index
        instance.model_list = slint.ListModel(seeded.models)
        instance.model_index = seeded.model_index
        language_rows = list(seeded.languages)
        language_checked = slint.ListModel(list(seeded.language_checked))
        instance.language_list = slint.ListModel(language_rows)
        instance.language_checked = language_checked
        instance.language_auto = seeded.language_auto
        instance.vad_threshold_list = slint.ListModel(seeded.vad_thresholds)
        instance.vad_threshold_index = seeded.vad_threshold_index
        instance.maxdur_list = slint.ListModel(seeded.max_durations)
        instance.maxdur_index = seeded.max_duration_index
        instance.vad_checked = seeded.vad
        instance.prompt_text = seeded.prompt
        instance.param_streaming = seeded.streaming
        refresh_language_summary()

    apply_seeded(seeded_initial)
    instance.defaults_status = startup.status

    # The recording-device rows (label + PortAudio capture index + voxtype
    # [audio] device string), kept in the closure like the language rows so the
    # selected index maps to BOTH the capture index Record opens and the device
    # string Apply/Stream write. Enumerated once here (re-enumerated on every
    # dropdown open below) and re-selected on Reset.
    device_rows: list[InputDevice] = []
    # Whether the host has any usable recording input. Recomputed on every probe
    # (startup and each rescan), so a mic plugged in after launch flips it back
    # to True. Mutable so the meter's availability gate (a closure) always reads
    # the latest value without re-enumerating. The idle meter opens only when
    # this is True, so a no-microphone host never reaches open_meter_stream (and
    # its PortAudio-open ALSA stderr spew) at all.
    device_state: dict[str, bool] = {"input_available": True}

    def apply_input_available(available: bool, labels: list[str]) -> None:
        # UI thread. The one place the availability state and the visible picker
        # labels move together, so they can never disagree: True shows the real
        # device labels, False collapses to a single "No microphone detected"
        # placeholder and dims the meter / disables Record via input_available.
        device_state["input_available"] = available
        instance.input_available = available
        instance.device_list = slint.ListModel(labels)

    def reload_device_list() -> None:
        # Probe the host and push the labels into the combo. Never crashes: a
        # headless/no-mic host yields just the System-default row, which reads
        # here as "no input available" (the synthetic default row is a fallback
        # label, not a real microphone).
        nonlocal device_rows
        device_rows = enumerate_input_devices()
        available = len(device_rows) > 1
        labels = (
            [d.label for d in device_rows] if available else [_NO_INPUT_DEVICE_LABEL]
        )
        apply_input_available(available, labels)

    def current_device() -> str:
        # The voxtype [audio] device string (Y) for the selected row. Out of
        # range (never expected: the list always has System default) reads as
        # the system default rather than raising.
        idx: int = instance.device_index
        if 0 <= idx < len(device_rows):
            return device_rows[idx].voxtype_device
        return DEFAULT_DEVICE

    def current_device_index() -> int | None:
        # The PortAudio capture index (X) for the selected row, read at each
        # Record start. None (System default) opens PortAudio's own default.
        idx: int = instance.device_index
        if 0 <= idx < len(device_rows):
            return device_rows[idx].index
        return None

    reload_device_list()
    instance.device_index = select_index(device_rows, startup.initial.device)

    def current_params() -> TranscribeParams:
        return build_params(
            engine=instance.sel_engine,
            model=instance.sel_model,
            language=current_language(),
            prompt=instance.sel_prompt,
            vad=instance.sel_vad,
            vad_threshold=instance.sel_vad_threshold,
            max_duration=instance.sel_max_duration,
            streaming=bool(instance.sel_streaming),
            device=current_device(),
        )

    # Where Apply writes and how it restarts, both injectable so tests and the
    # MCP loop hit a tmp path and a fake systemctl, never the real user daemon.
    config_path = defaults.user_config_path()
    systemctl_bin = apply.default_systemctl()
    # The EFFECTIVE config the daemon runs right now (the override when present,
    # else the baseline), what the Apply preview diffs against and the source
    # label names. Updated in place as Apply/Revert change what is on disk.
    override_exists = pathlib.Path(config_path).exists()
    apply_state: dict[str, Any] = {
        "effective": startup.initial,
        "source": (
            "your current config"
            if override_exists
            else "the system defaults"
            if sysdef.loaded
            else "the built-in defaults"
        ),
    }
    instance.override_exists = override_exists

    def refresh_apply_state() -> None:
        # UI thread. One diff of the live params against the EFFECTIVE config
        # drives both the preview lines and whether Apply has anything to do,
        # so a disabled Apply and an empty preview can never disagree.
        changes = apply.config_changes(current_params(), apply_state["effective"])
        instance.apply_available = bool(changes)
        instance.apply_preview_lines = slint.ListModel([c.line() for c in changes])
        instance.apply_preview_source = apply_state["source"]

    def refresh_modified() -> None:
        # UI thread (edit callbacks and startup): direct writes. One pure diff
        # against the seeded defaults drives every per-param dot and the Reset
        # button's enabled state, so they can never disagree.
        mods = defaults.modified_fields(current_params(), sysdef.params)
        instance.mod_engine = "engine" in mods
        instance.mod_model = "model" in mods
        instance.mod_language = "language" in mods
        instance.mod_prompt = "initial_prompt" in mods
        instance.mod_vad = "vad" in mods
        instance.mod_vad_threshold = "vad_threshold" in mods
        instance.mod_max_duration = "max_duration" in mods
        instance.mod_streaming = "streaming" in mods
        instance.mod_device = "device" in mods
        instance.any_modified = bool(mods)
        # The Apply preview diffs against the effective config, a different
        # baseline than the dots use, but every param edit moves both. Refresh
        # them together so they never drift.
        refresh_apply_state()

    def show_take_status(message: str) -> None:
        # Record/playback errors from worker threads. Marshal like every other
        # cross-thread property write. A failed Record start reports here but
        # never fires on_state(False), so resume the meter here too: the mic
        # was never actually taken, and the take controls are idle again.
        def apply() -> None:
            instance.take_status = message
            meter.resume()

        native.invoke_from_event_loop(apply)

    def push_input_level(level: float) -> None:
        # PortAudio callback thread. Marshal the level like every other
        # cross-thread property write, so the bar only ever changes on the
        # event loop. The UI zeroes the bar itself while Record or a Stream
        # session owns the mic, so no flatten write is needed on this path.
        native.invoke_from_event_loop(lambda: setattr(instance, "input_level", level))

    def meter_lost() -> None:
        # PortAudio callback thread (marshalled): the idle meter's device
        # vanished mid-capture (unplugged). Degrade to the no-microphone state
        # WITHOUT a crash or a stderr spew: drop the dead stream, collapse the
        # picker to the placeholder, flip the availability gate off (so nothing
        # reopens it), and blank the bar. A later rescan re-arms everything if a
        # mic comes back.
        def apply() -> None:
            nonlocal device_rows
            meter.handle_device_lost()
            device_rows = [SYSTEM_DEFAULT]
            instance.device_index = 0
            instance.input_level = 0.0
            apply_input_available(False, [_NO_INPUT_DEVICE_LABEL])
            refresh_modified()

        native.invoke_from_event_loop(apply)

    # The idle-only input-level meter. It taps the SAME accessor Record does
    # (current_device_index), so the bar always shows the device the picker
    # shows. Created stopped: main() starts it once the loop owns the thread.
    # available_fn gates the open on device_state, so a no-microphone host never
    # opens a stream. on_lost degrades cleanly if the tapped device is unplugged.
    meter = InputMeter(
        on_level=push_input_level,
        device_for=current_device_index,
        available_fn=lambda: device_state["input_available"],
        on_lost=meter_lost,
    )

    # Take playback with a real position. The controller runs an sd.OutputStream
    # whose callback advances a frame cursor OFF the UI thread. A repeating,
    # on-loop Timer samples that cursor (the honest position) into
    # playback_progress so the waveform fill tracks the audio, not an animation.
    # Created idle: nothing opens the output device until the first Play. _run
    # stops it on every exit path so no stream outlives the tuner.
    progress_timer = slint.Timer()

    def tick_playback_progress() -> None:
        # Event-loop thread (Timer callback): sample the real playback clock.
        instance.playback_progress = player.progress()

    def on_playback_finished() -> None:
        # PortAudio callback thread: the take reached its end on its own. Marshal
        # the reset onto the loop like every cross-thread write, stop sampling,
        # and clear the fill so Play returns.
        def apply() -> None:
            progress_timer.stop()
            instance.playing = False
            instance.playback_progress = 0.0

        native.invoke_from_event_loop(apply)

    player = TakePlayer(on_finished=on_playback_finished)

    def stop_playback() -> None:
        # UI thread. Halt any running playback and clear the fill: the take is
        # about to be re-recorded or the mic taken by a Stream session, so the
        # playback clock is stale. A no-op when nothing is playing.
        player.stop()
        progress_timer.stop()
        instance.playing = False
        instance.playback_progress = 0.0

    def refresh_waveform() -> None:
        # Recompute the take card's static waveform and its trailing meta from
        # the current take WAV. An absent or unreadable take clears the row.
        # Reading a few seconds of PCM16 is cheap enough for the UI thread, and
        # this only fires on the two events that change the take (a finished
        # record, startup after the sample seeds).
        take = waveform.analyze_take(slots.take_wav_path())
        instance.waveform_bins = slint.ListModel(take.bins)
        instance.take_duration = take.duration
        instance.take_meta = take.meta

    def show_recording(active: bool) -> None:
        # The Record button relabels to Stop from this, so it follows the
        # actual device state reported by the recorder, not the click. Capture
        # released the mic on the way to idle, so resume the meter then, and
        # settle the waveform from the freshly written take.
        def apply() -> None:
            instance.recording = active
            if not active:
                meter.resume()
                refresh_waveform()

        native.invoke_from_event_loop(apply)

    def on_clear() -> None:
        # Fired by the Clear button on the UI thread, so touch the properties
        # directly. Blanks the shared field, its provenance tag and the timing
        # label back to the pre-transcribe state. The recorded/seeded WAV and
        # the params are deliberately left untouched so the same audio can be
        # re-transcribed.
        instance.transcription = ""
        instance.transcription_source = ""
        instance.transcription_timing = ""

    def on_copy() -> None:
        # UI thread. Put the current transcript on the system clipboard. Empty
        # is a no-op (the button is disabled too), so a blank field can never
        # clear the clipboard or flash the confirmation. The wl-copy call and
        # any Wayland roundtrip run off the UI thread like every other
        # subprocess here, and the transient "Copied" relabel (or a worded
        # failure) marshals back through copy_feedback.
        text = instance.transcription
        if not text:
            return

        def work() -> None:
            ok = clipboard.copy_text(text, wl_copy_bin=WL_COPY_BIN)

            def done() -> None:
                instance.copy_feedback = "ok" if ok else "fail"

            native.invoke_from_event_loop(done)

        _run_bg(work)

    recorder = TakeRecorder(
        path_for=slots.take_wav_path,
        run_bg=_run_bg,
        on_error=show_take_status,
        on_state=show_recording,
        # The take captures from the picker's currently-selected device, read
        # afresh at each Record so a mid-session change takes effect next take.
        device_for=current_device_index,
    )

    def on_record() -> None:
        # UI thread. A fresh attempt must not sit under a stale error message.
        if instance.streaming:
            # The scratch daemon owns the mic for the session. The button is
            # disabled in the UI and this guard mirrors it.
            return
        instance.take_status = ""
        # A running playback is stale the moment the take is re-recorded, so stop
        # it and clear the fill before capture opens.
        stop_playback()
        # Yield the mic to capture BEFORE toggle dispatches the worker that
        # opens it: two streams cannot share the device, so the meter must be
        # closed here, synchronously, not on the recorder's later on_state.
        meter.pause()
        recorder.toggle()

    def current_availability() -> models.ModelAvailability:
        # The three-state probe for the live selection, fed with the config
        # layers' absolute model references so a system-provisioned store-path
        # model reads as available (and transcribable) without any download.
        return models.model_availability(
            instance.sel_engine, instance.sel_model, startup.model_paths
        )

    # The one live scratch-daemon session (single-flight, like the download
    # guard: `instance.streaming` is flipped on the UI thread) plus a
    # stopping flag so a stale marshalled tick can never repaint over the
    # "finalizing…" caption after the Stop click.
    stream_state: dict[str, Any] = {"session": None, "stopping": False}

    def end_stream_session() -> None:
        # Selection change / engine switch / reset: the running session's
        # generated config no longer matches the controls, so it is reaped:
        # callbacks silenced (the reap owns this teardown, no late repaint)
        # and the kill/rmtree moved off the UI thread.
        session = stream_state["session"]
        if session is None:
            return
        stream_state["session"] = None
        instance.streaming = False
        instance.stream_status = ""
        _run_bg(session.reap)
        # The session owned the mic for its whole run, so reclaim it for the
        # idle meter now that it is gone.
        meter.resume()

    def on_stream() -> None:
        # UI thread. One button, two verbs: Stop while a session runs (the
        # single-flight re-click can only ever finalize, never stack), Stream
        # otherwise.
        session = stream_state["session"]
        if instance.streaming and session is not None:
            stream_state["stopping"] = True
            instance.stream_status = "finalizing…"
            session.stop()
            return
        if not instance.streaming_available or instance.recording:
            return
        if instance.transcribing or instance.downloading:
            return
        p = current_params()
        if p.engine == "nemotron":
            # Nemotron has no on-disk catalog, so model_availability always
            # probes "absent". The parakeet bytes-gate below would wrongly
            # refuse it. Its model is the Nix-provisioned store dir in the
            # environment. Mirror on_transcribe and pin that so the generated
            # [nemotron] config points at real bytes.
            model_path = VOXTYPE_NEMOTRON_MODEL
        else:
            avail = current_availability()
            if avail.state == "absent":
                # Mirrors the disabled control: no bytes, nothing to stream.
                return
            model_path = avail.path if avail.state == "system" else None
        instance.streaming = True
        stream_state["stopping"] = False
        instance.take_status = ""
        instance.stream_status = "starting voxtype daemon…"
        # Playback and a stream session cannot share the take card's clock: stop
        # any playback and clear the fill before the daemon takes the mic.
        stop_playback()
        # The scratch daemon owns the mic for the whole session, so yield the
        # idle meter's stream to it (resumed on_done / end_stream_session).
        meter.pause()
        # The daemon types into the (focused) transcript field: start the
        # session with a clean receiving surface and no stale provenance.
        instance.transcription = ""
        instance.transcription_source = ""
        instance.transcription_timing = ""

        def on_live() -> None:
            # Worker thread: the daemon reported the streaming state. Focus
            # the field so the typed stream lands in the tuner. Receiving
            # keystrokes as the focused window IS voxtype's product behavior.
            def apply() -> None:
                if instance.streaming:
                    instance.stream_status = "streaming…"
                    instance.focus_transcript()

            native.invoke_from_event_loop(apply)

        def on_tick(elapsed_s: float) -> None:
            def apply() -> None:
                if instance.streaming and not stream_state["stopping"]:
                    instance.stream_status = f"streaming… {format_timing(elapsed_s)}"

            native.invoke_from_event_loop(apply)

        def on_done(outcome: streaming.StreamOutcome) -> None:
            def apply() -> None:
                stream_state["session"] = None
                instance.streaming = False
                instance.stream_status = ""
                # The session released the mic. Reclaim it for the idle meter.
                meter.resume()
                if outcome.ok:
                    # The field's text (received as typed output) IS the
                    # transcript. Only provenance and the honest state-
                    # transition wall-clocks land here. Nemotron has no tuner
                    # model selection (sel_model == ""), so name just the
                    # engine there, mirroring on_transcribe's provenance.
                    instance.transcription_source = (
                        f"{p.engine} · {p.model} · streamed (typed)"
                        if p.model
                        else f"{p.engine} · streamed (typed)"
                    )
                    instance.transcription_timing = streaming_caption(
                        outcome.session_s,
                        outcome.finalize_s,
                        outcome.hit_max_duration,
                    )
                else:
                    lines = (outcome.error or "unknown error").splitlines()
                    instance.take_status = f"streaming failed: {lines[-1][:80]}"

            native.invoke_from_event_loop(apply)

        session = streaming.StreamSession(
            p,
            model_path=model_path,
            voxtype_bin=VOXTYPE_BIN,
            on_live=on_live,
            on_tick=on_tick,
            on_done=on_done,
        )
        stream_state["session"] = session
        session.start()

    def refresh_streaming_gate() -> None:
        # Streaming affordances are engine- and model-gated: the Stream control
        # exists for the engines voxtype can stream (parakeet and nemotron, since
        # a dead control on whisper would be pure chrome) and is usable only for a
        # selection the engine can actually stream, the same predicate the
        # daemon enforces at startup (parakeet's is_streaming_compatible check,
        # nemotron's one provisioned model always streams), so the UI can never
        # offer a session the engine would refuse.
        engine = instance.sel_engine
        instance.stream_visible = engine in ("parakeet", "nemotron")
        capable = params.engine_can_stream(engine, instance.sel_model)
        instance.streaming_available = capable
        # "Startable now" adds the bytes check streaming_available deliberately
        # omits (that stays CAPABILITY-only, so the config toggle and tooltips
        # still light for a capable-but-undownloaded parakeet model). Nemotron's
        # model is env/Nix-provisioned (always "present" from the UI's view), so
        # capability is enough, while parakeet needs its bytes on disk. The Stream
        # button binds this one predicate rather than re-deriving it per engine.
        if not capable:
            instance.stream_startable = False
        elif engine == "nemotron":
            instance.stream_startable = True
        else:
            instance.stream_startable = current_availability().state != "absent"
        # NEVER-INVALID: the config streaming toggle can only be ON for a
        # streaming-capable selection (the daemon refuses to start otherwise).
        # An engine/model switch that leaves capability snaps it OFF, mirroring
        # the language popup's snap-back, with a worded note so the flip isn't
        # silent. The two-way binding pushes the cleared value to the checkbox.
        if instance.param_streaming and not capable:
            instance.param_streaming = False
            instance.stream_note = "streaming turned off (this model can't stream)"
        else:
            instance.stream_note = ""

    def refresh_model_status() -> None:
        # UI thread (engine/model-changed callbacks and startup): direct writes.
        # model_state drives the Download button's primary/enabled bindings, while
        # model_status is the human caption. One probe feeds both so they can
        # never disagree. Any selection-driven refresh also clears the failure
        # tint. A past download failure must not color a fresh model's status.
        refresh_streaming_gate()
        instance.model_status_error = False
        if not instance.sel_model:
            instance.model_status = ""
            instance.model_state = "absent"
            return
        state = current_availability().state
        instance.model_state = state
        instance.model_status = _STATUS_CAPTIONS[state]

    def on_engine_changed(engine: str) -> None:
        # Fired from the combo on the UI thread, so touch the models directly.
        # Rebuilding through model_catalog_for keeps the seeded defaults
        # (custom entries included) selectable: switching engines away and
        # back lands on the system default again, not on whatever sits at
        # index 0. A running stream session belongs to the old selection:
        # reap it before anything else repaints.
        end_stream_session()
        model_list, model_index = defaults.model_catalog_for(
            engine, sysdef.params, also=startup.initial
        )
        instance.model_list = slint.ListModel(model_list)
        instance.model_index = model_index
        # Nemotron is single-target: a language selection carried over from
        # whisper that has no single-target meaning (a multi-code set, or a code
        # with no nemotron locale) would reach the daemon as "auto" via
        # nemotron_target_lang while the pill still advertised it. Normalize such
        # a selection to Auto on entry so the pill can never lie about a language
        # nemotron won't honor. A single mappable code is already valid and kept.
        if (
            engine == "nemotron"
            and not instance.language_auto
            and params.nemotron_target_lang(current_language()) == params.AUTO_LANGUAGE
        ):
            for i in range(len(language_rows)):
                language_checked.set_row_data(i, False)
            instance.language_auto = True
            refresh_language_summary()
        # The new engine's default model differs, so re-derive its status.
        refresh_model_status()
        refresh_modified()

    def on_model_changed(_value: str) -> None:
        end_stream_session()
        refresh_model_status()
        refresh_modified()

    def rescan_devices() -> None:
        # The discoverable hotplug rescan, wired to BOTH the picker opening and
        # the Rescan button. PortAudio caches its device list at init time, so a
        # mic plugged in after launch is invisible to sd.query_devices until a
        # terminate+initialize (see devices.reinitialize_portaudio). GUARD: never
        # re-init while capture or a stream session owns the mic, since re-init
        # tears down ALL streams and would glitch or kill live audio.
        if instance.recording or instance.streaming:
            return
        # The idle meter holds a stream on the OLD PortAudio instance, so close
        # it before the terminate invalidates it, then reopen on the fresh one
        # (resume opens only if an input now exists, gated by available_fn).
        meter.pause()
        reinitialize_portaudio()
        # Preserve the current selection across the rebuild by label, falling
        # back to System default if it vanished, and recompute the dot in case
        # that fallback moved the value.
        current_label = (
            device_rows[instance.device_index].label
            if 0 <= instance.device_index < len(device_rows)
            else SYSTEM_DEFAULT.label
        )
        reload_device_list()
        instance.device_index = next(
            (i for i, d in enumerate(device_rows) if d.label == current_label), 0
        )
        meter.resume()
        refresh_modified()

    def on_device_selected(index: int) -> None:
        # A picked row. A running stream session captures from the old device
        # through its scratch daemon, so reap it before repainting (mirroring
        # the engine/model switch). The take recorder reads the new selection at
        # its next Record, so an in-progress take needs no teardown.
        end_stream_session()
        instance.device_index = index
        # Re-tap the idle meter on the newly selected device (no-op while a
        # session or capture still owns the mic, reopened when they release it).
        meter.retap()
        refresh_modified()

    def on_param_edited() -> None:
        # Fired by every control without a dedicated callback (VAD, threshold,
        # max duration, prompt) so the dots track edits live.
        refresh_modified()

    def on_language_toggled(index: int) -> None:
        # UI thread (popup row click). Whisper is multi-select (checking any
        # language leaves auto, unchecking the last one snaps back), while
        # nemotron is single-target, so its picker is single-select: checking one
        # clears the others (and auto), unchecking the only one snaps back to
        # auto. Either way the state can never read as "no language at all".
        now_checked = not bool(language_checked.row_data(index))
        if instance.sel_engine == "nemotron":
            for i in range(len(language_rows)):
                language_checked.set_row_data(i, i == index and now_checked)
            instance.language_auto = not now_checked
        else:
            language_checked.set_row_data(index, now_checked)
            if now_checked:
                instance.language_auto = False
            elif not any(
                bool(language_checked.row_data(i)) for i in range(len(language_rows))
            ):
                instance.language_auto = True
        refresh_language_summary()
        refresh_modified()

    def on_language_auto_selected() -> None:
        # Auto is exclusive: every checkbox clears in the same step so the
        # state can never read as auto+codes.
        instance.language_auto = True
        for i in range(len(language_rows)):
            language_checked.set_row_data(i, False)
        refresh_language_summary()
        refresh_modified()

    def on_reset_defaults() -> None:
        # Restore the BASELINE (system defaults), not the startup values. The
        # recompute below turns every dot off and disables Reset again. Reset
        # is a selection change too: a running stream session is reaped.
        end_stream_session()
        apply_seeded(seeded_baseline)
        # Device is not part of the pure SeededControls (its list is a live
        # hardware probe), so re-select the baseline's device here. Keep the
        # already-enumerated list, only move the selection.
        instance.device_index = select_index(device_rows, sysdef.params.device)
        # Reset can move the selected device, so re-tap the idle meter onto it.
        meter.retap()
        refresh_model_status()
        refresh_modified()

    def on_apply_confirmed() -> None:
        # UI thread (the confirm popup's primary). Snapshot the live params,
        # then serialize/write/restart off the UI thread and marshal the
        # outcome back. A "system" model exists only at its config path, so
        # hand the layer map along for the serializer's path/name resolution.
        p = current_params()
        instance.applying = True
        instance.apply_status = "applying…"
        instance.apply_status_error = False

        def work() -> None:
            outcome = apply.apply_config(
                p,
                sysdef.raw,
                startup.model_paths,
                config_path,
                systemctl_bin,
                # Nemotron carries no tuner model catalog, so its provisioned
                # store dir (unavailable to the pure serializer) is threaded in
                # here to pin [nemotron].model when the baseline had none.
                nemotron_model=VOXTYPE_NEMOTRON_MODEL,
            )

            def done() -> None:
                instance.applying = False
                instance.apply_status = outcome.message
                instance.apply_status_error = not outcome.ok
                if outcome.kind in ("applied", "restart_failed"):
                    # Both landed the file on disk (a restart failure leaves the
                    # written override in place): Revert must be offered as the
                    # escape hatch either way.
                    instance.override_exists = True
                if outcome.ok:
                    # The daemon now runs exactly ``p`` from the override we
                    # just wrote: it becomes the effective config the preview
                    # diffs against, so a second Apply reads "nothing to apply".
                    # A failed restart deliberately does NOT advance effective.
                    # Apply stays available so the user can retry the restart.
                    apply_state["effective"] = p
                    apply_state["source"] = "your current config"
                    refresh_apply_state()

            native.invoke_from_event_loop(done)

        _run_bg(work)

    def on_revert_config() -> None:
        # UI thread. Delete the override and restart, returning the daemon to
        # system defaults. Recoverable (a later Apply recreates the file), so it
        # acts directly. The outcome reporting keeps it honest either way.
        instance.applying = True
        instance.apply_status = "reverting…"
        instance.apply_status_error = False

        def work() -> None:
            outcome = apply.revert_config(config_path, systemctl_bin)

            def done() -> None:
                instance.applying = False
                instance.apply_status = outcome.message
                instance.apply_status_error = not outcome.ok
                if outcome.kind != "write_failed":
                    # The override was removed (or was already gone): Revert has
                    # nothing left to do. A write_failed leaves it in place.
                    instance.override_exists = False
                if outcome.ok:
                    apply_state["effective"] = sysdef.params
                    apply_state["source"] = (
                        "the system defaults"
                        if sysdef.loaded
                        else "the built-in defaults"
                    )
                    refresh_apply_state()

            native.invoke_from_event_loop(done)

        _run_bg(work)

    # Each download gets a generation number and a CancelHandle, the same
    # stop idiom as on_transcribe below. One deliberate difference: the Stop
    # click neither clears the busy state nor renders the outcome. A download
    # persists an artifact, so completed-vs-cancelled is only decidable at
    # reap time (the child's exit status: a kill that lost the race to a
    # clean exit is a completed download), the truthful caption/button need
    # the post-cleanup availability probe, and an eagerly restarted fetch
    # would race the dying group's writes and cleanup in the shared model
    # dir. The worker's apply below is therefore the single writer of the
    # outcome in both race directions. The generation check still drops a
    # stale completion should the state ever move on underneath it.
    download_gen = itertools.count()
    download_state: dict[str, Any] = {"gen": None, "cancel": None}

    def on_download() -> None:
        # UI thread. One button, two verbs (mirroring Record→Stop and
        # Transcribe→Stop): while a fetch runs the click cancels it. A model
        # fetch is multi-GB and voxtype's downloader is lockless (two
        # concurrent downloads in one model dir delete and re-fetch each
        # other's in-flight files and crash on a hashed-then-unlinked path),
        # so the `downloading` guard (set on the UI thread, race-free)
        # enforces single-flight either way: a click can cancel the running
        # fetch, never stack a second one.
        if instance.downloading:
            handle = download_state["cancel"]
            if handle is not None:
                handle.cancel()
                # Immediate feedback: show_progress stops repainting the
                # caption from here on, and the completion renders the final
                # cancelled/completed state once the artifact is settled.
                instance.model_status = "cancelling…"
            return
        engine, model = instance.sel_engine, instance.sel_model
        if not model:
            return
        if current_availability().state != "absent":
            # The button is disabled for an available model. Mirror it here so
            # a synthetic invocation can't spawn a pointless re-fetch.
            return
        gen = next(download_gen)
        handle = CancelHandle()
        download_state["gen"] = gen
        download_state["cancel"] = handle
        instance.downloading = True
        instance.model_status = "downloading…"  # UI thread: immediate feedback
        instance.model_status_error = False

        def show_progress(progress: models.DownloadProgress) -> None:
            # Poller thread. Marshal like every other cross-thread write. The
            # poller is joined before download_model returns and the queue is
            # FIFO, so ordering already protects the completion caption. The
            # re-checks make a late drain harmless too. Once a cancel is
            # requested the caption belongs to the cancel flow: a sample from
            # the dying subprocess must not repaint fake progress over it.
            def apply_progress() -> None:
                if instance.downloading and not handle.cancelled():
                    instance.model_status = format_download_progress(progress)

            native.invoke_from_event_loop(apply_progress)

        def work() -> None:
            result = models.download_model(
                engine,
                model,
                voxtype_bin=VOXTYPE_BIN,
                on_progress=show_progress,
                cancel=handle,
            )

            def apply() -> None:
                if download_state["gen"] != gen:
                    # Superseded meanwhile: a newer run owns the surface.
                    return
                download_state["gen"] = None
                download_state["cancel"] = None
                instance.downloading = False
                fetched = models.model_availability(
                    engine, model, startup.model_paths
                ).state
                if result.ok and fetched != "absent":
                    # Re-derive from the probe (selection may have moved while
                    # the fetch ran) instead of hardcoding a caption here. A
                    # cancel that lost the race to this clean exit renders
                    # here too: the artifact is complete and ready.
                    refresh_model_status()
                elif result.cancelled:
                    # The kill landed pre-completion and the partial artifact
                    # is already removed. Re-probe so the button's
                    # primary/demoted state follows the current selection,
                    # but caption the cancelled fetch's OWN state: the
                    # selection may have moved mid-cancel, and a
                    # "cancelled, ready ✓" hybrid would pin the cancel on a
                    # model it never touched. Not a failure, so no
                    # destructive tint.
                    refresh_model_status()
                    instance.model_status = f"cancelled, {_STATUS_CAPTIONS[fetched]}"
                else:
                    short = (
                        (result.error or "").splitlines()[-1]
                        if result.error
                        else "unknown"
                    )
                    instance.model_status = f"failed: {short[:60]}"
                    instance.model_status_error = True

            native.invoke_from_event_loop(apply)

        _run_bg(work)

    # Each transcribe run gets a generation number. The Stop click clears the
    # current one, so a killed (or racing) worker's marshalled completion is
    # recognizably stale and dropped. The cancel and the completion can
    # never both render.
    transcribe_gen = itertools.count()
    transcribe_state: dict[str, Any] = {"gen": None, "cancel": None}

    def on_transcribe() -> None:
        # UI thread. One button, two verbs (mirroring Record→Stop and the
        # stream session's Stop): while a run is active the click cancels it:
        # the subprocess is killed (terminate→kill), the distinct "cancelled"
        # caption renders, and the guard clears so a fresh run can start
        # immediately, ahead of the old worker's teardown.
        if instance.streaming:
            return
        if instance.transcribing:
            handle = transcribe_state["cancel"]
            transcribe_state["gen"] = None
            transcribe_state["cancel"] = None
            instance.transcribing = False
            instance.transcription_timing = "cancelled"
            if handle is not None:
                handle.cancel()
            return
        # Snapshot the live control values on the UI thread, then run the
        # subprocess off it and push the result back. A "system" model exists
        # only at its config-provided absolute path (voxtype's name lookup
        # searches the user dir alone), so hand that path along for the
        # generated-config route. User/absent models resolve by name.
        p = current_params()
        avail = current_availability()
        model_path = avail.path if avail.state == "system" else None
        if p.engine == "nemotron":
            # Nemotron has no tuner model catalog and no downloader, so its
            # availability always probes "absent". Its model is the
            # Nix-provisioned store dir in the environment. Pin that so
            # transcribe() writes it into the generated [nemotron] config.
            model_path = VOXTYPE_NEMOTRON_MODEL
        wav = slots.take_wav_path()
        gen = next(transcribe_gen)
        handle = CancelHandle()
        transcribe_state["gen"] = gen
        transcribe_state["cancel"] = handle
        instance.transcribing = True

        def work() -> None:
            result = transcribe(
                wav, p, voxtype_bin=VOXTYPE_BIN, model_path=model_path, cancel=handle
            )
            # Timing is meaningful only for a completed run. A failure clears
            # it. The caption carries the harness-comparable numbers: wall
            # clock plus RTFx from the take's WAV header.
            timing = (
                ""
                if result.error
                else batch_caption(result.duration_s, wav_duration_secs(wav))
            )
            # With one take there is no slot to attribute. The provenance that
            # matters for A/B tuning is which engine/model produced the text.
            source = f"{p.engine} · {p.model}" if p.model else p.engine

            def apply() -> None:
                if transcribe_state["gen"] != gen:
                    # Cancelled (or superseded) meanwhile: the Stop click
                    # already rendered. This completion is stale.
                    return
                transcribe_state["gen"] = None
                transcribe_state["cancel"] = None
                instance.transcribing = False
                instance.transcription = transcription_output(result)
                instance.transcription_source = source
                instance.transcription_timing = timing

            native.invoke_from_event_loop(apply)

        _run_bg(work)

    def on_play() -> None:
        # UI thread. Toggle the single playback controller: idle→play,
        # playing→pause (freeze the fill), paused→resume. take-play is disabled
        # while a take is being rewritten, and this mirrors that guard. The path
        # is read here on the UI thread. The controller and its PortAudio
        # callback never touch the Slint instance.
        if instance.recording or instance.streaming:
            return
        try:
            player.toggle(slots.take_wav_path())
        except PlayerError as exc:
            # A failed start/pause/resume (the output device vanished, say)
            # leaves the controller stopped. Clear the UI to match, then surface.
            stop_playback()
            show_take_status(str(exc))
            return
        if player.is_playing():
            instance.playing = True
            progress_timer.start(
                slint.TimerMode.Repeated,
                datetime.timedelta(milliseconds=50),
                tick_playback_progress,
            )
        else:
            # Paused: freeze the progress fill where the clock stopped.
            instance.playing = False
            progress_timer.stop()

    def on_seek(fraction: float) -> None:
        # UI thread (waveform click/drag). Move the playback clock to the
        # pointer fraction and reflect it immediately so the fill boundary
        # tracks the scrub without waiting for the 50ms progress tick. seek is a
        # pure cursor move: a playing take keeps playing from the new position,
        # a paused or idle take stays put until the next Play (which begins from
        # the armed position). Mirror on_play's guard so a synthetic seek can't
        # fire while capture or a stream session owns the take card. Paint the
        # fill only when seek established a real position, so a click never shows
        # a phantom boundary the next Play would snap away.
        if instance.recording or instance.streaming:
            return
        clamped = min(1.0, max(0.0, fraction))
        if player.seek(clamped):
            instance.playback_progress = clamped

    instance.record = on_record
    instance.play = on_play
    instance.seeked = on_seek
    instance.transcribe = on_transcribe
    instance.engine_changed = on_engine_changed
    instance.download_model = on_download
    instance.model_changed = on_model_changed
    instance.device_opened = rescan_devices
    instance.rescan = rescan_devices
    instance.device_selected = on_device_selected
    instance.clear_transcription = on_clear
    instance.copy_transcription = on_copy
    instance.param_edited = on_param_edited
    instance.language_toggled = on_language_toggled
    instance.language_auto_selected = on_language_auto_selected
    instance.reset_defaults = on_reset_defaults
    instance.stream = on_stream
    instance.apply_confirmed = on_apply_confirmed
    instance.revert_config = on_revert_config

    # Seed the status for the default engine's default model, and compute the
    # (all-off) modified state so the Reset button starts disabled.
    refresh_model_status()
    refresh_modified()
    # Draw the seeded take (the bundled sample, or a prior recording) into the
    # take card's waveform at startup.
    refresh_waveform()

    return meter, player


def _run(
    instance: Any,
    meter: InputMeter | None = None,
    player: TakePlayer | None = None,
) -> None:
    """Enter the Slint event loop, treating Ctrl+C as a clean quit.

    The primary shutdown path is ``_install_lifecycle``'s handlers calling
    ``slint.quit_event_loop()``, after which ``instance.run()`` returns
    normally. The KeyboardInterrupt catch is a fallback for the rare delivery
    that slips through as an exception (e.g. during startup, before the loop
    owns the thread), so it can never dump a traceback. The record/transcribe/
    download workers are daemon threads, torn down with the process. No join
    or explicit teardown needed. A scratch streaming daemon is NOT: it is a
    separate process that would outlive the tuner. The idle input meter holds
    an open capture stream, which must be closed the same way. Every way out of
    the loop funnels through the finally: the lifecycle quit paths
    (Ctrl-C/SIGTERM/Ctrl-D), a plain window close, even a crashing loop, so no
    stream or daemon outlives the tuner.
    """
    try:
        instance.run()
    except KeyboardInterrupt:
        logging.getLogger(__name__).info("shutting down")
    finally:
        streaming.reap_active()
        if meter is not None:
            meter.stop()
        if player is not None:
            # Close any open output stream so no playback outlives the tuner.
            player.stop()


def _install_lifecycle() -> slint.Timer:
    """Make Ctrl-C/SIGTERM and a terminal Ctrl-D quit the event loop cleanly.

    Slint's native loop runs no Python bytecode while idle, so a pending
    SIGINT would sit undelivered forever. The returned repeating Timer wakes
    the interpreter every 200ms purely so signal handlers get a chance to
    run. The caller must keep the reference. A GC'd Timer stops firing.

    The handlers run on the loop thread and may call ``slint.quit_event_loop``
    directly. The stdin watcher runs on its own thread, where that call is NOT
    thread-safe (it silently does nothing), so it marshals through
    ``invoke_from_event_loop`` like every other cross-thread hop here.
    """
    # slint.run_event_loop() re-creates its module-global quit event when it
    # starts, so a quit requested between handler installation and loop start
    # (a Ctrl-C during the first window's setup) would be silently discarded.
    # Remember every request and have the wake-up tick (which only ever runs
    # once the loop is live) re-assert it.
    quit_requested = threading.Event()

    def request_quit() -> None:
        quit_requested.set()
        slint.quit_event_loop()

    def wake() -> None:
        if quit_requested.is_set():
            slint.quit_event_loop()

    wakeup = slint.Timer()
    wakeup.start(
        slint.TimerMode.Repeated,
        datetime.timedelta(milliseconds=200),
        wake,
    )
    lifecycle.install_signal_quit(request_quit)
    lifecycle.watch_stdin_eof(
        sys.stdin,
        lambda: native.invoke_from_event_loop(request_quit),
    )
    return wakeup


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")

    # Seed the bundled sample as the take when nothing is recorded yet, so a
    # fresh run is transcribable/playable immediately without clobbering an
    # existing recording. A no-op when no sample is wired in.
    if slots.seed_take(SAMPLE_WAV):
        logging.getLogger(__name__).info("seeded default sample as the take")

    components = slint.load_file(str(SLINT_FILE))
    instance = components.MainWindow()
    meter, player = configure(instance)
    # The app is idle now, so the meter owns the selected input and pushes
    # levels. _run closes it (and any playback stream) on every exit path.
    meter.start()
    wakeup = _install_lifecycle()
    # The ready marker the lifecycle regression tests wait for: from here on a
    # SIGINT/SIGTERM/Ctrl-D is guaranteed to be handled, not to traceback.
    logging.getLogger(__name__).info("entering event loop")
    _run(instance, meter, player)
    del wakeup


if __name__ == "__main__":
    main()
