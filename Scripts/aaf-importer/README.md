# AAF Importer (ReaScript)

Lists the tracks in a **Pro Tools AAF export** and imports one track's
**name, volume, pan and automation** onto the selected REAPER track, or as a
new track.

It imports track settings only. Audio, clips, plugins and sends are left out.
The AAF is read by the script itself, as a compound file parsed in pure Lua,
so it needs no converter or extension other than ReaImGui.

## Install

Requires **ReaImGui** (ReaPack). The file dialog uses js_ReaScriptAPI when it
is installed, and REAPER's own dialog otherwise.

```bash
ln -sfn "$PWD" ~/.config/REAPER/Scripts/AAFImporter
```

Then add `Magnolius_AAFImporter.lua` in Actions → Show action list → New
action → Load ReaScript.

## Use

1. **Open AAF…** and pick the export. The panel lists every audio track with
   its volume and pan:
   - *static −10.6 dB*: the lane never moves.
   - *auto, 233 pts, −1.3 .. +7.3 dB*: the lane is automation.
   - *--*: the track carries no lane of that kind.

   The panel remembers the last file and reopens it next time.
2. Click a track. The **Preview** draws its volume, and its pan if it has any,
   as REAPER will draw it.
3. Tick what to import: **Name**, **Volume**, **Pan** and **Automation**.
4. Choose a **Placement**: where the AAF's first sample lands in the project.
   - *Project start* (the default) puts it at 0:00.
   - *Edit cursor* puts it at the edit cursor.
   - *Match timecode* uses the AAF's start timecode (for example 00:59:50:00)
     less REAPER's project start time.
5. **Apply to selected track**, or **Insert as new track**. A new track goes
   below the last selected track, or at the end if none is selected. Each
   import is one undo step. The status line says where the points went. If
   none of them is on screen it warns you, and **Show in arrange** scrolls
   the view to them. *Match timecode* on a project that starts at 0:00 puts
   them about an hour in.

### What the checkboxes do

| Lane in the AAF | Volume / Pan ticked | Automation ticked | Result |
| --- | --- | --- | --- |
| static | yes | either | the fader / pan knob is set, no envelope |
| moves | yes | yes | the envelope is written, and the fader goes to 0 dB / centre so it does not add to it |
| moves | no | yes | the envelope is written, and the fader is left alone |
| moves | yes | no | the fader takes the lane's opening value |

Automation goes to the track's **Volume** and **Pan** envelopes (post-FX).
An envelope that already exists keeps its points outside the imported span;
only the span the AAF covers is replaced.

## How Pro Tools writes it

Decoded from a real Pro Tools 25.6 export (`test/fixtures/automation_import.aaf`):

```
CompositionMob
  TimelineMobSlot  "Track name", edit rate 48000/1
    Sequence
      OperationGroup  MonoAudioGain, length L
        Parameter Amplitude = VaryingValue (Linear)
          ControlPoint  Time = a fraction of L, Value = linear gain
        InputSegments[1] = SourceClip
      Filler
```

Two things follow from that:

- **Automation exists only under clips.** Pro Tools wraps each clip in its
  own gain effect, so a gap between clips (a Filler) carries none. To carry a
  whole track's automation, put a clip under its full length before
  exporting.
- **A point's time is a fraction of its clip.** It is not a timeline
  position. Each point lands at `clip start + time × clip length`.

Pro Tools also writes a step at a clip's end: one point a sample before the
end, then the value past the clip, clamped to the end and repeated. The
repeat is dropped and the step is kept.

The points are written as Pro Tools' breakpoints, without resampling. REAPER
interpolates its Volume lane in the fader's scaled domain, which is closer
to how Pro Tools ramps than the AAF's nominal linear-gain interpolation.

## Limits

- **Pan has not been checked against a real file.** The Pro Tools 25.6
  export this was built on contains no pan: its dictionary defines only the
  gain effect. Pan import (MonoAudioPan, 0..1 mapped to REAPER's L..R) is
  implemented from the AAF specification. Synthetic tests cover it, and so
  does the in-REAPER test of the pan lane's direction, but no real export
  does. The same applies to constant values and to constant (stepped)
  interpolation.
- One AAF track is applied at a time.
- *Match timecode* reads the timecode at its nominal rate: 00:59:50:00 is
  3590 s. That matches a REAPER project whose start time is set to the same
  timecode.
- Big-endian AAF files (very old Avid writers) are refused with a message.

## Layout

| File | Role |
| --- | --- |
| `Magnolius_AAFImporter.lua` | Entry: checks for ReaImGui, sets `package.path`, starts the panel. |
| `ai/cfb.lua` | Compound File Binary reader: header, DIFAT, FAT, mini stream, directory tree. Pure Lua. |
| `ai/aaf.lua` | AAF objects over it: `properties` streams, strong references (single, vector and set), weak references as AUIDs, and indirect values. Pure Lua. |
| `ai/model.lua` | Walks compositions into tracks with volume and pan lanes in seconds. Pure Lua. |
| `ai/config.lua` | Defaults and ExtState persistence. |
| `ai/apply.lua` | **The only file that touches the project.** `plan` (pure) decides what to write; `apply` and `insert_new` write it inside one undo block. |
| `ai/ui.lua` | The ReaImGui panel, with `_init` / `_frame` test hooks. |

## Tests

REAPER must be open. The runner refuses to start it.

```bash
python3 tools/run_tests.py          # headless, frames, verify
python3 tools/run_panel_test.py     # the panel against the real ReaImGui
```

| Suite | Covers | Cannot cover |
| --- | --- | --- |
| `test/headless.lua` | The CFB reader: stream sizes and checksums checked against olefile on the fixture. The model: track names, the timecode, and point counts, times and values in dB checked against a separate Python decode of the real export. Walker paths no real export has: pan, ConstantValue, constant interpolation, gain over pan, Transitions, clips across a Filler. Static detection, the import plan, and the checkbox key scan. | Whether REAPER plays the values as written, and any Pro Tools layout other than the one in the fixture. |
| `test/panel_frame.lua` | Every panel state, quiet and with every control moved, against a stub ImGui: stacks balanced, and buttons reaching `Apply` with the right track and offset. `Apply` is stubbed, so the project is untouched. | How the panel looks. |
| `test/verify_in_reaper.lua` | Fixture tracks at the end of the open project. It reads the written lane back through `Envelope_Evaluate` and `Envelope_FormatValue`, and checks that a user point outside the span survives while one inside it goes. Also: placement, a static lane going to the fader, the pan lane's direction, insert-as-new position and selection, the undo point name, and the project left as it was found. | A comparison with Pro Tools' own playback, which is a manual check. |
| `test/panel_in_reaper.lua` | Ten real ReaImGui frames over the fixture. | Clicks. It clicks nothing, so it never edits the project. |

`test/fixtures/automation_import.aaf` is a real export with volume automation.
`test/fixtures/names_only.aaf` is an earlier export of the same session with
empty tracks: names, no lanes.
