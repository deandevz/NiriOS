# Contributing to NiriOS

Thanks for helping. NiriOS is an opinionated project: it trades features for smoothness, stability and a small footprint. Please read the first two sections before starting anything big, and open an issue to talk it through first.

## What NiriOS stands for

- **The experience comes first.** A visual glitch, a window in the wrong place, an extra Accessibility read, or memory and CPU that creep up are bugs, even when the feature works. When a feature and stability pull in different directions, stability wins.
- **Light is a feature.** Idle, NiriOS uses about 10 MB and 0% CPU. Nothing runs while nothing moves: no polling, no timers, no display link. State for a window goes away with the window, so memory never grows with time. A change that makes these numbers worse needs a measured reason.
- **Off means gone.** Every feature can be turned off, and a disabled feature has no window, no event monitor and no memory. Heavy work (UI, image decoding, networking) runs in a separate process that exits when it's done.
- **SIP stays on.** This one isn't negotiable: no disabling System Integrity Protection, not even partially, no scripting additions injected into the Dock, no kernel extensions. Private SkyLight APIs are fine when they work with SIP on. Check what a call actually does on screen, not its return code: several return success and do nothing.
- **Simple code.** A solution you can read in one go beats a flexible abstraction. No new layer, protocol or type without a real need. Comments explain why (the macOS rule, the measured number), not what.
- **Measure, don't guess.** "It feels smoother" isn't a result, numbers are. And "you can't do that on a Mac" is a hypothesis to test with a prototype, not a fact.

## Architecture rules

These are the decisions behind the smooth animation. A pull request that breaks one needs numbers that justify it.

1. **Minimal work per frame on the main thread.** A tick is the closed-form spring, a list of rectangles, and handing them to each app. No snapshots, plans, diffs or state bookkeeping per tick.
2. **One queue per app, and only the latest frame counts.** Never call Accessibility on the main thread. A slow app delays only its own windows.
3. **No reads during an animation.** Every Accessibility read is a round trip that blocks the app's queue. Positions are checked only after the strip settles (150 ms), because Electron applies sizes asynchronously and a read right after a write lies.
4. **One source of truth: the `Layout`.** The per-app worker only keeps the frame it was asked for and the frame it got. Parallel state that can disagree with the layout isn't allowed: that's where "windows move on their own" comes from.
5. **The layout changes only on a user action or a real window event** (open, close, minimize, hide). An Accessibility timeout doesn't mean the window is gone, and it never removes anything from the strip.
6. **Springs with a closed-form solution.** Changing the target mid-animation keeps the velocity, and a late frame doesn't change the trajectory.
7. **Windows outside the viewport park with 1 pt at the right edge of the screen.** macOS pulls any window that is fully off screen back to 40 pt visible. Parked windows aren't resized, because Electron refuses to resize off screen.
8. **Focus goes through a single queue, the latest request wins, and it's applied when the animation ends.** Activating an app mid-animation stalls that app, the app losing focus and the WindowServer.
9. **Hotkeys come from a `CGEventTap` at the HID level, on its own thread.** It sees the key before other apps' global shortcuts and knows when a key repeats.
10. **A window missing from an app's list isn't closed until the WindowServer confirms it.** Accessibility only lists the current Space, and a window that leaves without closing comes back to the same column.

Before adding anything new, ask three questions. Does it run every frame? Does it read from the app? Does it create a second place that holds state? If any answer is yes, bring numbers.

### Patterns we avoid

yabai, AeroSpace, OmniWM, Paneru and niri are where NiriOS started, not its ceiling. Reading how window managers work taught us to stay away from:

- Reading a window back after every write, or before writing when there's no reason to.
- A heavy pipeline on every tick (snapshot, plan, diff, bookkeeping). More work per frame means more dropped frames.
- Many intermediate states that can disagree with each other. That's where windows get lost or move on their own.
- A focus border that follows the computed frame on the main thread. The real window arrives later, through the app's queue, so the two drift apart.
- Toggling `AXEnhancedUserInterface` on every batch. NiriOS turns it off once and restores it on exit.

## Project layout

| Path | What's there |
|---|---|
| `Sources/NiriCore` | The model: `Layout` (strip, viewport, stacked columns), `Workspaces`, `Spring`, `Shortcut`, `ClipboardList`, `Feature`, `Version`, `WallpaperEffect`. Pure Swift, no AppKit, covered by tests. |
| `Sources/NiriOS` | The app: `AppWorker` (the per-app Accessibility queue), `WindowManager` (state, display link, actions), `Border`, `Compositor` (the ghost resize), `Hotkeys`, `Settings` and `SettingsPanel`, `Wallpaper`, `Clipboard` and `ClipboardPanel`, `Updater`, `Welcome`, `AppBundle`, `PrivateAPI` (SkyLight through `dlsym`), `Config`. |
| `Tests/NiriCoreTests` | Layout and spring tests. One of them checks the gap between windows on every frame of an animation. |
| `docs/NOTES.md` | Engineering notes: how each part works, what was measured, and every experiment, whether it worked or not (in Portuguese). |

## Development

You need an Apple Silicon Mac with macOS 15 or later and Swift 6 (Xcode or the Command Line Tools). The measurements in the notes come from macOS 26.

```sh
./scripts/test.sh      # NiriCore tests
./scripts/run.sh -v    # release build and run, with measurements
```

The terminal needs Accessibility permission. `Ctrl+C` brings every window back on screen and quits. `pkill -USR1 -f niri-os` saves the state and quits without moving anything, which is handy before starting a new build.

With `-v`, every animation prints the frames applied, the cost per frame, the longest gap between frames, the frames where windows overlapped, and a final check of every window against where it should be. When you report a change, these are the targets:

- Longest gap between frames: about 17 ms or less.
- Frames with overlap: 0.
- Final check: everything in place.
- Idle memory (physical footprint) and CPU: unchanged.

### Testing without touching your windows

```sh
swift build -c release
cp .build/release/niri-os /tmp/niri-os-test   # if your everyday NiriOS is running
/tmp/niri-os-test -v --pid <pid> --script right,right,grow,full,full,shrink,left,move:2,ws:2,ws:1
```

`--pid` manages only that app's windows, in a strip at the bottom of the screen, without hotkeys and without stealing focus. Throwaway floating panels make good test windows. Run the test build from a copy of the binary when NiriOS is already open: two processes from the same file break window capture for the second one. `NIRI_CONFIG=<file>` uses another config file, and `niri-os --list` shows every window and whether it would join the strip. The full list of script steps and test variables is in the notes, under "Testar sem mexer nas suas janelas".

## Opening an issue

For a bug, include:

- Your NiriOS version, macOS version, Mac model and displays.
- What you did, what you expected and what happened. One problem per issue.
- The apps involved and their versions. Many window bugs only show up with one app.
- Your `~/.config/niri-os/config.json`, with anything private removed.
- The log: `~/Library/Logs/niri-os.log` for the app, or the terminal output of `./scripts/run.sh -v`.
- A screen recording for anything visual. A one-frame glitch is real, and a recording is the fastest way to find it.

For a feature request, start with the problem rather than the solution, and say how it would fit: what it costs while idle, whether it runs every frame, and whether it works with SIP on.

Please don't open a public issue for a security problem. Use "Report a vulnerability" in the repository's Security tab instead.

## Pull requests

- Open an issue first for anything bigger than a fix, especially new features and architecture changes.
- Keep each pull request to one topic and keep the diff small.
- Explain what changes and why. If it touches animation, Accessibility, focus or memory, include before and after numbers from `-v` and the memory footprint, and the apps you tested with.
- Layout changes come with tests in `NiriCore`, and `./scripts/test.sh` has to pass.
- Match the code around you: naming, idioms and comment density.
- Don't add dependencies without talking about it first. Right now there are none.
- When shortcuts, config keys or features change, update both READMEs. Record experiments in `docs/NOTES.md`, with numbers, including the ones that didn't work.
- Most comments and notes are in Portuguese. English is welcome in issues, pull requests and new code.

Releases are published by the maintainer.

## License

NiriOS is licensed under the [GNU General Public License v3.0 or later](LICENSE). By contributing, you agree that your contribution is released under the same license.
