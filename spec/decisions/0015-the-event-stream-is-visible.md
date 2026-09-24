# 0015. The event stream is visible

- Status: **Accepted** — confirmed by the maintainer on 2026-09-22 (same
  session as this record's first draft).
- Date: 2026-09-22

## Context

Both modes show a status: inline draws virtual lines at the selection, vibe a
floating corner panel (`ui/progress.lua`, `ui/panel.lua`). Both say one thing —
the latest action, plus a usage line — and both are deliberately small, because a
status that grows with activity ends up covering the code being worked on.

That is the right design for a run that is behaving, and useless for one that is
not. The status has nothing to compare against: "running `go version; python3
--version`" looks the same in the first second and the tenth minute. When the run
described in [0014](0014-stalled-runs-are-aborted.md) hung, there was no way to
see whether the request had been sent, what the model had asked for, whether the
tool had been dispatched, or how long it had been stuck — which is to say, no way
to tell a hang from hard thinking, and no evidence to report.

The loop already produces exactly the right data for this: a typed event stream
([0002](0002-typed-event-contract.md)) that both modes already tap for their
status. What was missing was somewhere for it to land other than a two-line
summary.

## Decision

**Keep a session-wide log of the typed event stream, and give it a keybinding.**

- `ui/monitor.lua` records every event: timestamps, turn boundaries, the model's
  text and reasoning, each tool call with its command or path, usage lines, and
  how long the current tool call has been running.
- **Recorded whether or not it is on screen.** Opening it after a run went wrong
  shows that run. This is the point of the feature, and it is why the monitor is
  not simply a view onto a live stream.
- Opened with `<leader>am` (toggling) or `:Smith monitor`, in a **split**, not a
  float. A float cannot offer scrollback or search, and this is the one surface
  in the plugin meant to be read line by line after the fact.
- Inside the buffer: `q` closes, `X` cancels the run the same way
  `<leader>ax` does, `<C-c>` clears the log.
- The log is bounded at 2000 entries, with the count of dropped entries shown, so
  a long session cannot grow it without limit and the log never silently looks
  complete when it is not.

## Consequences

### Positive

- A stall becomes legible: a tool call that has been "running" for minutes is
  visible, with the command above it, instead of being a status line that looks
  the same as progress.
- A post-mortem is possible without reproducing the run. The evidence from the
  hang — the request, the tool call, the silence — is already recorded.
- Answering "was the prompt a cache hit, and on which turn" no longer needs a
  notification to be read at exactly the right moment.
- Tool timings come for free, which is where the next performance question will
  be.

### Negative / costs

- **It is not a transcript.** The loop emits no `tool_result` events (only
  `tool_use`), so the monitor cannot say whether a command succeeded; it says
  `returned after 1.7s`, which is what it actually observed. Anything else would
  be inventing a result. Fixing this means giving the loop an event for resolved
  tool outcomes, which is a change to the event contract and was not needed for
  the problem at hand.
- A second surface to keep working, with its own buffer, keymaps and lifecycle —
  the plugin now has three UIs where it had two.
- Buffer-local keymaps on a scratch buffer can surprise the user who lands in it
  by accident, and `X` there cancels a real run.
- The log holds whatever the model wrote, at length, in a buffer the user may not
  have opened: a long session accumulates memory that is only freed on clear or
  exit.
- The name of the buffer (`agent-smith://stream`) means only one can exist per
  session, so two concurrent runs share a log. Two modes running at once is
  already outside what the plugin supports — the modes assume one active run —
  but it is now visible in a second place.

## Alternatives considered

**Reuse the corner float (`ui/panel.lua`) with more lines.** Cheapest, and
rejected: a float is small, non-focusable and unscrollable by design, so the
evidence scrolls out of view — which is the failure being fixed.
**Write the stream to a file.** Survives Neovim, so a crash can be investigated
afterwards, and needs no buffer. Rejected for now: it introduces a second
on-disk artifact with a rotation policy, a location, and the question of what is
recorded there by default — and credentials or file contents pass through the
stream. A buffer has the advantage of ending when the session does.

**Only show the monitor when a run stalls.** Then it is not available for the
case that matters most: the user noticing something *before* it dies, and the run
reporting more than one thing going wrong. It also makes the display conditional
on a watchdog that is configured off.

**Extend the status line instead.** That is where the status is today, and it was
insufficient: the status binds to a buffer or a corner and has room for two
lines, and it is designed to *disappear* when the run ends, which is exactly
backwards for a post-mortem.

## Amendment, 2026-09-22

The decision above says the monitor is "a **split**, not a float", and gives two
reasons: a float cannot offer scrollback or search, and a log is meant to be read
line by line. **That part is superseded: the monitor is a floating window.** The
rest of the record — that the stream is recorded, kept across runs, bounded, and
reachable from a keybinding — stands unchanged.

The reasoning above was wrong about the mechanism, not the goal. A float *can*
carry a real buffer, and `focusable`/`enter` (which `ui/panel.lua` sets to false
precisely because a status must not steal the cursor) give it the normal window's
scrolling, search and yank. The two properties the split was chosen for were
never the split's to give.

What the split cost, in use: opening the monitor rearranged the user's window
layout — for a run they may only want to glance at — and closing it did not
reliably give the layout back. That is a large, permanent, visible change to the
editor for a temporary look at a log, and it is the wrong trade for a window the
user opens *because something is already going wrong*.

The monitor is now the same centred float as the instruction prompt, from one
shared helper (`ui/float.lua`), including the property that matters most for
discoverability: the keys are written on the window's own bottom border. Two
hand-rolled floats drift into two different sets of hints, and a key that only
exists in the help is a key nobody finds.

### Amendment to the amendment, 2026-09-22 — the steer input's frame

The steer input (`s`, [0016](0016-steering-is-delivered-on-the-next-turn.md)) was
first docked with a border table whose only non-empty entry was the top edge, so
that the input appeared to share the monitor's frame rather than sitting inside it
as a second box. It does not work: **an empty string in a border table still
reserves its cell**, so the input's blank left border sat on the monitor's own left
border column and occluded it, and the input's text landed one column in. Measured
on a screen, then replaced.

The input is now an ordinary rounded box — the same shape as the prompt — sized and
placed so that its whole frame lands inside the monitor's content box. The cost is
two rows and four columns of log, and a visible inner box where a seamless division
was intended; the benefit is that no cell is asked for that belongs to the
monitor's frame, which is a property the geometry can be tested for rather than
looked at.

### Consequences of the amendment

- A float does not follow a resized editor the way a split does, so the geometry
  is recomputed on every redraw and a `VimResized` autocmd asks for one when the
  run is over and no spinner is running.
- The float is not part of the window layout, so it is not captured in
  `:mksession` and does not appear when the user cycles windows. For a
  session-lived log that is the correct reading of "temporary".
- The window's size is fixed at open (100×24, clamped to the editor) rather than
  being resizable by dragging a split boundary. Making a float resizable means
  re-implementing window resizing, which is not what this window is for; a wide
  entry is clipped with an ellipsis rather than wrapped, so the timestamp column
  stays readable.
- `ui/panel.lua` is unchanged: a status display still must not take focus, and it
  is still the corner float. The division is now "the user is looking at this"
  (centred, entered) versus "this is reporting at you" (corner, focusless).

## Related

- [0002](0002-typed-event-contract.md) — the events the monitor renders
- [0014](0014-stalled-runs-are-aborted.md) — the decision the monitor exists to
  make visible
- [0013](0013-usage-input-tokens-excludes-cached.md) — the usage line, and why
  its cache rate was wrong until now
- [../events.md](../events.md) — the field-level event reference
- [../architecture.md](../architecture.md) — module map and data flow
