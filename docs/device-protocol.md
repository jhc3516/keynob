# Layer 1·2·3 input report protocol

This document records only the protocol used by `KeyboardDeviceBridge.exe` for the
connected VID `514C`, PID `8850`, interface `0`, Usage Page `FF00` device family.
The reported serial is diagnostic only because two physical units returned the same value.

## Slot map

| Input | Slot | Input | Slot |
| --- | ---: | --- | ---: |
| `key01` to `key12` | 1 to 12 | `knob1_ccw`, `knob1_press`, `knob1_cw` | 16, 17, 18 |
| `knob2_ccw`, `knob2_press`, `knob2_cw` | 19, 20, 21 | Reserved | 13 to 15, 22 to 25 |

## 64-byte report

| Offset | Meaning | V2 rule |
| ---: | --- | --- |
| 0..1 | Command | `03 fa` |
| 2 | Slot | Exact input slot in the selected layer |
| 3..4 | Layer/type | `<01|02|03> 01` |
| 5 | Active-input mode | App-generated reports use `00`; the second unit's factory defaults use `01`, which is accepted only when reading and preserved by rollback |
| 6 | Chord item count | 1 to 5 |
| 9, 12, 15, 18, 21 | Chord items | Modifier code or USB HID keyboard usage |
| 11, 14, ... 59 | Vendor padding | `32` for device-direct chords; zero is accepted by app aliases |

Confirmed modifier codes are `f1` Control, `f2` Shift, `f3` Alt, and `f4`
Windows. Regular keys use USB HID keyboard usage values. The firmware does not
preserve left/right modifier identity, so V2 rejects right-side modifiers for
device-direct shortcuts rather than silently changing their meaning.

V2 supports the USB HID keyboard-page usages exposed by the editor: letters,
top-row digits, common punctuation, F1-F24, editing and navigation keys,
Caps Lock, Print Screen, Scroll Lock, Pause, Application/Menu, Num Lock, and
numeric keypad digits and operators. Numeric keypad Enter is recorded as the
ordinary Enter key because the WPF recorder does not distinguish the two input
locations. The native bridge independently accepts only the same explicit
keyboard-page allowlist. Consumer-page media keys such as volume and play are
not offered because this device's consumer report mode has not been captured
and verified. The editor rejects unsupported keys instead of guessing a report.

Control+Shift+Alt plus any of the 54 layer-specific internal alias keys is reserved for app
routing. A user cannot save one of those combinations as a device-direct global
or Typeless shortcut because the Windows hook could otherwise identify the
wrong physical input.

An app-routed input is encoded as Control+Shift+Alt plus the layer/input pair's
globally unique alias. Layer 1 preserves the original 18 aliases. Layer 2 uses
F13-F24 plus six navigation/editing keys, and Layer 3 uses 18 letter keys while
excluding C (Codex Ctrl+C cancellation) and M (an existing Layer 1 alias).
A global or Typeless shortcut is encoded directly. A disabled input is currently
encoded as one null usage (`count=1`, item `00`). This null-key representation is
an inference and must be confirmed by a physical no-output observation before final release.

| Layer | KEY 1..12 aliases | Knob aliases in slot order 16..21 |
| ---: | --- | --- |
| 1 | F1..F12 | Left, Enter, Right, Up, M, Down |
| 2 | F13..F24 | Home, End, PageUp, PageDown, Insert, Delete |
| 3 | A, B, D..L, N | O, P, Q, R, S, T |

The known V1 Typeless translation built-in is the compatibility exception: its
existing app alias is preserved, and the Windows runtime verifies that Typeless
is running before injecting F13. Typeless user-defined shortcuts and the explicit
dictation built-in remain device-direct.

## Transaction rules

1. Read all 25 slots from the explicitly selected layer (1, 2, or 3).
2. Compare the selected slot with the previously read 128-character hex value.
3. Skip the write when the replacement is identical.
4. Write the 64-byte slot report, commit, read all slots again, and compare.
5. On any failure, restore the original slot and verify it in the same layer.
6. For a multi-slot apply, restore every earlier changed `(layer, slot)` in reverse order if a later slot fails.

The settings JSON is the user's intent. Device reports are an execution copy. A
mismatch is never resolved automatically; the UI offers apply, import, or cancel.

The confirmed read request is `03 fa 19 00 <layer>` in a 65-byte report. The
bridge accepts `read-layer <1|2|3>` and validates that all 25 responses repeat
the requested layer byte. `program-report <layer> ...` validates both expected
and replacement layer/slot headers before device access. The old `read-layer1`
and layer-1 `program-report` arity remain as compatibility aliases for existing
diagnostic scripts.

Read-only checks have confirmed 25 structurally valid reports from all three
layers on the registered device. Layer 2·3 physical key/knob writes and
persistence still require a separately approved test that snapshots all 75
reports, changes one input at a time, observes the physical event, restores the
original bytes, and confirms the final 75-report snapshot exactly matches.
