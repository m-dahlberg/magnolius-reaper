# Track Manager

Nine named track groups on a narrow always-on-top panel, driven by the numpad.

On a big session, getting to "just the drums" or "everything except the vocal
comps" means clicking through the TCP or REAPER's own Track Manager every
time. Type `drums*` into slot 1 once and from then on Numpad-1 *is* that group
— selected, hidden, or soloed, depending on which of the three modes the
panel is in.

Each mode has its **own page of nine**: the groups you reach for are rarely
the ones you hide, and neither is the handful you solo.

The slots save with the project, so a session opens with its own groups. The
presets are global, so the names you always use follow you between sessions.

## Install

```bash
ln -sfn "$PWD" ~/.config/REAPER/Scripts/TrackManager
```

Then Actions → Show action list → New action → Load ReaScript → pick
`Magnolius_TrackManager.lua` inside the symlink. Needs
[ReaImGui](https://github.com/cfillion/reaimgui) and nothing else.

## Use

Pick a mode, type patterns into the slots, press the squares — or the numpad.

| Key | Select mode | Hide mode | Solo/Mute mode |
| --- | --- | --- | --- |
| Numpad 1–9 | select that slot's tracks | hide that slot's tracks | solo that slot's tracks |
| Ctrl + Numpad 1–9 | add that slot to the selection | (same as without Ctrl) | mute that slot's tracks |
| Numpad + | select all tracks | show all tracks | solo every slot |
| Numpad − | deselect all tracks | hide all tracks | unsolo every slot |
| Ctrl + Numpad + | (same as without Ctrl) | (same as without Ctrl) | mute every slot |
| Ctrl + Numpad − | (same as without Ctrl) | (same as without Ctrl) | unmute every slot |
| Numpad / | to Hide mode | to Solo/Mute mode | back to Select mode |
| Numpad 0 | close the panel | close the panel | close the panel |

Numpad / cycles: **Select → Hide → Solo/Mute → Select**.

**The nine slots belong to the mode.** Switching pages swaps the patterns, the
lights and the preset combo together, so `drums*, gtr*, keys*` can sit on the
Hide page while the Solo/Mute page holds the four tracks you actually audition.
All three pages save with the project and travel in the global store.

**Shortcuts need the panel focused.** Click it once after working in the
arrange view — see *Known limits*.

### The squares are toggles, and they are lit by the project

**Lit means present**: selected in Select mode, *showing* in Hide mode. A dark
square is a group that is gone. (Solo/Mute mode inverts this deliberately —
see below.) Pressing a lit square takes the group away and
pressing a dark one brings it back — Numpad-1 selects the drums, Numpad-1 again
clears the selection; in Hide mode Numpad-1 hides them and Numpad-1 again shows
them. Half-lit means some of the slot's tracks are there and some are not, and
pressing finishes the job.

Nothing about that state is stored. Hide a track by hand, or click one in the
TCP, and the lights simply say so on the next frame; there is no stale toggle
to get out of step. It also makes the tooltip honest — hover a square and it
names the tracks that press would affect, counted from the project as it is.

### Select mode is exclusive; Ctrl accumulates

A plain press replaces the selection, so one key gets you to one group without
clearing anything first. Ctrl+press adds a group instead, or takes just that
group back out if it is already lit, which is how you build a selection from
several slots. Ctrl works on the numpad and on the mouse alike.

### Hide mode hides

A lit slot's press hides, a dark one's press shows. Slots are independent here
— several groups can be hidden at once, and each square tracks its own. The
**TCP / MCP / Both** choice decides which panel that means; under **Both** a
slot only stays lit while its tracks are in both, so a group hidden in the TCP
alone reads half-lit and one more press finishes it.

That radio belongs to this mode alone. It is greyed out in Select mode because
REAPER's track selection is not per-panel — there is one selection and both
panels show it — and in Solo/Mute because mute and solo are per-track.

### Solo/Mute mode

Each row grows a second square: **red for mute on the left, yellow for solo on
the right**, in the order they sit on a REAPER track panel. Press either and
the slot's tracks mute or solo; press it again and they don't. Half-lit means
half the group is engaged, and pressing finishes the job.

On the numpad the division is the same on every key: **plain is solo, Ctrl is
mute, + engages and − clears.** So 1–9 solo a slot, Ctrl + 1–9 mute it, **+**
solos *every* slot at once and **Ctrl + −** unmutes them all.

"Every slot" means the tracks the nine slots name, merged and deduplicated —
not the project. Soloing every track in a session is audibly the same as
soloing none, so a key that did that would do nothing; soloing everything the
slots name leaves exactly your groups up and everything unnamed quiet, which is
the thing you actually wanted. The two buttons do the same and **relabel
themselves while Ctrl is held**, from *Solo all* / *Unsolo all* to *Mute all* /
*Unmute all*, so the press is spelled out before it is made. They grey out when
no slot names anything, and hovering says how many tracks that is.

**Only the tracks a pattern actually names are touched — never a folder's
children.** REAPER already carries a parent's mute and solo down through the
folder's own routing, so writing the flag onto the children as well would be
redundant going in and wrong coming out: the unmute would clear a child you had
muted by hand. *Include tracks in folders* is greyed out here for that reason;
a slot reading `drums*` engages the DRUMS parent and nothing else, and the
whole folder goes quiet anyway.

Here — and only here — **lit means engaged rather than present**: a red square
is a muted group, not an unmuted one. Red means muted in every DAW there is,
and a red square that lit for an audible track would be a worse lie than the
exception. The *Panels* and *levels* controls grey out too, because mute and
solo are per-track and reach whatever the slot names.

### Folder levels

The **levels** box under the radio says how deep a *show* reaches. It reads
"levels of N", where N is how deep the open session actually goes, and it
cannot be wound past that.

- **1** — top-level tracks and folder parents only. Nothing inside any folder.
- **2** (default) — that, plus one level in: a folder's own tracks and its
  subfolder parents, but not what is inside those subfolders.
- **3** — one level deeper again, and so on.

A folder parent sits on its siblings' level, not its children's, so raising the
number opens folders rather than swallowing their parents.

**It is a lens, not an action.** Moving it does not touch a single track. It
constrains what a show reveals — a slot press that brings a group back, or
Numpad + — and it never constrains a hide: a group is hidden whole and revealed
only as deep as the setting reaches. Anything the action does not name is left
exactly as you left it, so a track you opened up by hand stays open.

What *does* change the moment the box moves is the lights, because they are
read through the same lens. A slot whose group is showing as far as the setting
reaches is fully lit; wind the box one deeper and the same slot drops to
half-lit, because there is now another level for it to reveal. Press it and it
lights again. The tooltip counts what is being held back — `6 tracks, 2 below
level 2`.

### From selection

Select the tracks you want in the TCP and press **From selection**: the first
nine selected track names go into the slots, in project order, from the top.
It is the fast way to get a session's groups into the panel — select the drum
tracks, the guitars and the vocal, press once, then widen the ones you want to
be groups rather than single tracks.

The button says what it will do before you press it: it is dead when nothing is
selected, the grey text beside it names the slots the press overwrites, and
hovering lists the terms that will land in them. It **fills from the top and
stops** — importing three names leaves slots 4–9 alone, so it cannot quietly
take out a set you have built up. Slots have no undo.

Selected tracks with no name are skipped, since there is nothing to match on. A
selected folder parent imports as its name, so with **Include tracks in
folders** on that slot is the whole folder — which is usually what was wanted.

### The pattern language

```
drums              substring, case-blind  -- finds "Drums OH", "Room drums"
drums*             names STARTING with drums
*bus               names ENDING with bus
gtr?1              ? is exactly one character
gtr*, perc*        , or ; separates terms; any of them may match
gtr*, -gtr ref     a leading - excludes, and exclusion always wins
-vox               exclusion alone means everything except
```

A term with no wildcard in it is a substring, because that is nearly always
what someone means by naming a group they can see in the TCP. The moment a `*`
appears the term anchors at both ends — otherwise `drums*` would be
indistinguishable from `drums`. Pattern characters have no special meaning, so
a track called `Gtr (DI)` is typed as it reads.

**Include tracks in folders** adds every child of a matched folder,
recursively, whether or not the children's own names match. It does not work
the other way: matching a child does not pull in its parent. It applies to
Select and Hide only — Solo/Mute never expands a folder, and the box is greyed
there.

### Presets

The combo recalls a named set of nine slots immediately. Type a name and press
**Save** to store the current nine under it — an existing name is overwritten,
a new one appended. **Del** removes the loaded preset and asks once first,
because ExtState is written straight through and there is no undo for it.

A preset is **one page of nine**, not the whole panel: Save stores the page you
are looking at, and the combo recalls onto the page you are looking at — so a
set of drum groups can go into Select today and Solo/Mute tomorrow. Each page
remembers which preset it has loaded, and the combo follows you across a mode
switch.

Presets are global. The slots themselves belong to the project, so recalling a
preset changes what this session's slots are, and the session keeps whatever is
in them when it is saved.

## Notes on the design

**The lights are derived, not stored.** This is the decision everything else
follows from. A stored toggle has to be kept in step with a project the user is
also editing by hand, and it never quite is; a derived one cannot drift because
there is nothing to drift. It costs one pass over the track list per frame,
which for a few hundred tracks is nothing, and it buys the honest tooltip and
the half-lit state for free.

**Lit means present in Select and Hide.** Selected, or visible. Reading the
light as "this slot has been applied" would have hide mode light up for what is
*gone*, and the panel would then be dark on a session where everything is
showing — which is the state you spend most of your time in, and the least
informative thing to look at. Present-means-lit also makes the two modes agree,
so cycling with Numpad / does not invert what your eyes are tracking.

**Solo/Mute is the exception, and the colours are why.** Its squares light for
a group that is muted or soloed — engaged, not present. The rule above is a
good rule, but it loses to a stronger one: red means muted in every DAW ever
made, and a red square lit for an audible track would be read wrongly by
everyone, every time, no matter what the README said. An exception you can see
the reason for beats a consistency you have to remember.

**Mute gets an undo point; solo does not.** The same trade visibility and
selection make, for the same reason. A mute is a mix decision and survives into
the render, so it is worth being able to take back; a solo is monitoring, it
never leaves the room, and it is the most-pressed key in that mode — an undo
point on every press would bury the edits either side of it.

**`I_SOLO` holds 0, 1 or 2, whatever the docs say.** The API lists 5 and 6 for
"safe solo"; measured on 7.75, writing 4, 5 or 6 lands as **0**, and reading
never returns them. Solo-safe is `B_SOLO_DEFEAT`, a flag of its own — which is
why this panel never touches the safe flag, and why a reverb return set
solo-safe keeps that setting through any number of presses. The verify suite
asserts it rather than trusting either the docs or this paragraph.

**And 1 is not the value to write.** `I_SOLO` 1 is solo *ignoring routing*: the
track goes straight to master and everything else is silenced, so a track whose
master send is off and which reaches the mix only through a send to a bus goes
**quiet under its own solo** — the square lights, the button in the TCP lights,
and nothing comes out. 2 is solo-in-place, which keeps the track's routing.
REAPER's own button chooses between the two from the *solo in place* preference
(`soloip`: 0 → 1, 1 → 2, and it is on by default), so this panel reads that
preference on every press and writes the same thing a click would. The verify
suite pins it to REAPER's own solo action rather than to a constant, so it
holds whichever way the preference is set.

**One snapshot per frame.** `Apply.snapshot` reads every track once and the
nine slots resolve against it, rather than nine walks over the project. That is
not only speed: it means the nine lights, the tooltips and any press made this
frame all describe the same instant.

**A page per mode, and one line of indirection to pay for it.** Every read
and write of a slot in the panel goes through `slots()`, which hands back
`cfg.slots[cfg.mode]`. Keying the three pages by the mode string rather than
holding three named tables means the stores, the preset shelf and the panel all
loop over `Config.MODES` and cannot disagree about how many pages there are.

**Solo and mute stop at the names; select and hide do not.** The asymmetry is
REAPER's, not this panel's. A folder parent's mute and solo already reach its
children through the folder's routing, so expanding the match would write the
flag onto tracks that were going to follow anyway — and the *unmute* would then
clear a child the user had muted by hand, which the panel has no business
doing. Selection and visibility have no such propagation, so there the
expansion is the whole point.

**The marker key carries a format number.** It used to say only "this project
has settings"; it now says which layout they are in. A `1` is a session saved
when nine slots were shared by every mode, and it loads by seeding all three
pages with those nine rather than opening blank — which matters because a
project cannot be probed key by key: `SetProjExtState` deletes a key set to
empty, so an absent key and an empty slot are the same thing. The global store
gets the same marker for the same reason, so the first run after an update
finds the slots where it left them.

**Three stores, because there are three questions.** Project ExtState answers
"what are *this* session's slots" and rides in the `.RPP`. Global ExtState
answers "what were they last time", so a new project does not open with nine
blanks. The preset shelf answers "what sets do I keep", and is global by
definition. The first two are written together on every edit, and the project
wins on load.

An empty slot stores an empty string, and `SetProjExtState` deletes a key set
to empty — so a missing key and an empty slot are indistinguishable. One marker
key (`saved`) settles it for all nine, and it is what `load_proj` tests.

**An imported name spends `,`, `;` and a leading `-` as `?`.** The pattern
language has no escape, deliberately — an escape is a bug waiting for the first
person to put the delimiter in a track name — so a name carrying one of the
three characters that mean something cannot be quoted into a term, only
rewritten. `?` is one character of anything, so the imported term still matches
the name it came from. The leading `-` is the reason this is not optional: a
track called `-Room` imported verbatim would give a slot quietly meaning
*everything except* that track.

**Presets are one ExtState key per field**, not nine strings joined into one.
Joining needs an escape, and an escape is a bug waiting for the first person to
put the delimiter in a track name. Keys are cheap.

**Selection gets no undo point; visibility does.** The whole premise is that a
numpad key is cheap, and an undo point per keypress would bury the edits either
side of it. Hiding thirty tracks is worth being able to take back, so that one
is wrapped, with `UNDO_STATE_TRACKCFG` rather than the whole project state —
asking for the latter would snapshot every item in the session on each press.

**`TrackList_AdjustWindows` is the whole trick to hiding.** Writing
`B_SHOWINTCP` / `B_SHOWINMIXER` changes the project and nothing on screen; the
TCP and the mixer re-lay themselves out only when asked to.

## Layout

| File | Role |
| --- | --- |
| `Magnolius_TrackManager.lua` | entry action — the panel |
| `tm/config.lua` | defaults, the mode cycle, global and project ExtState, the preset shelf |
| `tm/match.lua` | **pure**: pattern text → matcher; name → does it match; track name → term |
| `tm/tracks.lua` | **pure**: folder expansion, nesting levels and the slot union, over a plain list |
| `tm/apply.lua` | the only file touching the project — snapshot, select, hide, mute, solo, read the selection |
| `tm/ui.lua` | the panel |
| `test/headless.lua` | the pure stages, plus panel frames against a stub |
| `test/ui_frame.lua` | one panel frame against a stub ImGui |
| `test/panel_in_reaper.lua` | the panel against the real ReaImGui |
| `test/verify_in_reaper.lua` | a built track fixture, selected and hidden for real |
| `tools/run_tests.py` | runs the two headless-drivable suites |
| `tools/run_panel_test.py` | runs the panel suite and waits for its result |

## Tests

There is no system `lua` on this machine; the suites run inside the already
running REAPER. Last run: **297 assertions, 0 failures.**

```bash
python3 tools/run_tests.py          # headless + verify
python3 tools/run_panel_test.py     # the panel, against the real ReaImGui
```

| Suite | Covers | Cannot cover |
| --- | --- | --- |
| `headless.lua` | 195 assertions: the whole pattern language — substring vs anchored, `?`, multi-term, exclusion beating inclusion, exclusion alone, trimming, Lua pattern magic as literals, the unnamed track; the round trip a track name makes back into a term, including a name holding a comma and one starting with a `-`; folder expansion including nesting, a `-2` that closes two folders at once, two sibling folders and a folder left unclosed at the end of the project; the slot union, deduplicated and in project order, of overlapping slots and of no slots at all; the nesting-level walk, including a parent sitting on its siblings' level, a flat project, an unbalanced `-1` that cannot push below level 1, and an empty project; `resolve` and the three lit states against a hand-built snapshot, per scope and per folder level, including that a hidden track does not read as selected and that the lens touches neither Select nor the two Solo/Mute lights; the mute and solo lights, lit, dark and half-lit, read separately from each other and from visibility; the mode cycle, including an unrecognised mode falling back rather than sticking; what the import button collects off a snapshot, in project order, skipping an unnamed track and counting the ones past the limit; the three pages — that they are independent tables, that all three round-trip through the project store and the global one with their preset names, and that a format-1 store, project or global, seeds every page with the nine slots it had; the preset shelf round-tripped through a test-only ExtState section, including overwrite, compaction and orphaned keys; eleven panel states rendered twice each — Solo/Mute among them, quiet and with both its squares pressed — asserting both stacks balance; a frame that presses **From selection** and asserts the selected name landed in slot 1 of the page and slot 2 was left alone; two frames resolving the same folder name in Solo/Mute and in Hide, asserting the first reaches the parent alone and the second the whole folder; a scan asserting every config key the panel names is real and every setting is named | that the ImGui calls have the right *arity* or that the symbols exist; anything touching a real project |
| `panel_in_reaper.lua` | the panel against the **real** ReaImGui, ten states × three frames: the window drew, the frame did not raise, both stacks balanced — and that **all 47 ImGui symbols the panel names exist at 0.9**, scanned out of the source so a symbol added later is covered without anyone remembering. That check earns its keep here more than in the sibling repos: this panel is the only one that leans on `Key_Keypad1`–`9`, `Key_KeypadAdd`, `Key_KeypadDivide`, `Mod_Ctrl` and `WindowFlags_TopMost`, and whether those exist at the pinned version is not something that can be reasoned out | anything needing a control to be *moved* — the real library cannot be given fake input, which is what the stub is for |
| `verify_in_reaper.lua` | 71 assertions against a fixture it builds itself — a `TMDRUMS` folder over `TMKick`/`TMSnare`, plus `TMGtr 1`, `TMGtr ref`, `TMVox`: folder expansion on and off; exclusion; exclusive press, Ctrl accumulate, Ctrl on a lit slot, plain press on a lit slot; select-all and deselect-all; hiding under `tcp` leaving the mixer alone and going dark under `tcp` and `both` while staying lit under `mcp`; hiding under `both`; show-all and hide-all; the levels lens: that a show reaches only as deep as it says, that a hide ignores it, that show-all leaves a hand-shown deep track alone, and that the light goes from lit to half-lit when the box is wound one deeper — with the fixture's levels read off the project rather than assumed, since it is appended to whatever the user has open; import off a real project — the selected names read in project order, each resolving back to exactly the track it came from, and a selected folder parent resolving to its whole folder; mute and solo against the real project — mute reaching a whole folder and lighting its square, half a group reading half-lit, solo engaging without touching mute and writing exactly what REAPER's own solo action writes, so a track that reaches the mix only through a send is as audible under the panel's solo as under the button's, a muted track still reading as showing, solo-in-place still reading as soloed, a solo-safe track keeping `B_SOLO_DEFEAT` through a solo and an unsolo, and the bulk keys working over the union of two slots — soloing and unsoloing every slot, leaving a track no slot names alone, and leaving the other flag alone; the nine slots and the settings round-tripping through project ExtState, each page keeping its own nine, with an empty slot coming back empty and a stored `false` coming back boolean | whether the shortcuts feel right under the fingers — that is a manual pass |

The two panel suites are complements and neither is redundant: the stub can move
every control but answers any call with any arguments, so it cannot see a wrong
argument count or a renamed symbol; the real library catches those and cannot be
handed fake input.

`verify_in_reaper.lua` restores the selection and visibility of every
pre-existing track and deletes its own fixture in an unwind that runs whether or
not the body raised — but it does leave the project **dirty**, because adding
and deleting tracks is an edit. Run it on a scratch project.

## Known limits

- **Shortcuts need the panel focused.** ReaImGui receives keys for its own
  window and nothing else. Making them global would mean a second extension
  (`js_ReaScriptAPI`, polling the OS keyboard) and numpad 1 firing while you
  type into a REAPER field. Deliberately not done; click the panel once.
- **Numpad − in Hide mode hides every track in the project.** Drastic, and
  exactly what it says. Numpad + brings them all back, and it is one undo point.
- **Nothing that writes a slot can be undone.** Import and preset recall both
  overwrite them, and ExtState is written straight through. It is why the
  import fills only as many slots as there are tracks selected, and why the
  button says which ones before it is pressed.
- **Solo is plain solo, not solo-in-place.** The panel writes `I_SOLO` 1; if
  your preference is solo-in-place, a solo from here is still an ordinary one.
  Solo-safe (`B_SOLO_DEFEAT`) is never touched either way.
- **The Solo/Mute bulk keys reach only what the slots name.** A track soloed
  or muted by hand that no pattern matches is left alone by *Solo all* and
  *Unsolo all* — deliberately, since the alternative is a key that solos the
  whole project and therefore does nothing. REAPER's own unsolo-all action is
  still there for the rest.
- **Track names only.** No matching on colour, folder membership, track number
  or parameter.
- **The master track is never touched.** It is not in `GetTrack`'s enumeration
  and nothing here adds it.
- **A slot matching nothing is disabled**, not empty-but-pressable — so a
  pattern with a typo in it reads as a dead square rather than doing nothing
  silently.
