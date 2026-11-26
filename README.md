# OleOle Move Controller

**English** | [日本語](README.ja.md)

An iPad-only MIDI CC controller for live performance with Ableton Move (in a Move
Everything / move-anything setup).

- 6 sliders (KICK / HAT / S1–S4)
- 4 XY pads (in sets of two, switching between named MIDI configurations; multi-touch
  lets you move them at the same time)
- A fader attached to the bottom-right set (its CH/CC and value belong to each MIDI
  configuration)
- A stopwatch (touching a control while it is stopped shows a warning)
- Battery level display
- Move Mirror Display (a mirror of the 128×64 OLED)

All of these sit on one screen. There are no screen transitions, no tabs and no
vertical scrolling.

- Target: iPadOS 17 or later, landscape only (`TARGETED_DEVICE_FAMILY = 2`)
- Frameworks: SwiftUI, Observation, Core MIDI, WebKit, Network
- External libraries: none
  - The reference app used AudioKit `Controls`' XYPad; this app implements the same
    look and handling with a SwiftUI `Canvas` and `DragGesture(minimumDistance: 0)`.

---

## 1. Connections

```
iPad (USB host) ── USB-C ── Ableton Move (Standalone)
      │                               │
      └──── Wi-Fi (same network) ─────┘   ← for Mirror Display (when there is no USB network)
```

### MIDI (USB-C)

1. Connect the iPad and the Move directly with a USB-C cable.
   - Use a cable that carries data. A charge-only cable carries no MIDI.
2. When the app starts, it lists the Core MIDI destinations.
   - It automatically picks a port whose name, manufacturer or model contains "move",
     or whose manufacturer contains "ableton".
   - If no such port exists, it picks a USB port.
   - Port names are not hard-coded.
3. When **M** in the top row lights up, it is connected. The connected port's name is
   shown in **SETTINGS → MIDI OUTPUT** (marked `ACTIVE`).
4. To choose the destination by hand, long-press the app name or **M** in the top row to
   open **SETTINGS → MIDI OUTPUT**.
   - The chosen destination is saved. It stores the uniqueID and the name, and on
     reconnection matches the uniqueID first, then the name.
   - When a manually chosen device cannot be found it shows `WAITING`, and sends to no
     other device.
5. USB plugging and unplugging is handled automatically.
   - Sending stops the moment it is unplugged (logged as `DROP`).
   - Plugging back in reconnects automatically and resumes sending.
   - After reconnecting, **SEND ALL** resends the current values of every control.

### Receiving the CCs on the Move (important)

**Connect the iPad to the Move's USB-C port. MIDI does not pass through the USB-A port.**

- The Move's USB-A is a host-side port, for plugging in USB MIDI **devices**. The iPad
  cannot act as a generic USB MIDI device, so plugging it into USB-A creates no MIDI path.
- When a host (the iPad) is connected to the Move's USB-C, the Move presents itself as
  "Ableton Move" with several MIDI ports (Live / User / External / Standalone).
- [Schwung](https://github.com/charlesvestal/schwung) (formerly Move Everything) receives
  as external MIDI (cable 2) only the MIDI sent to the **Standalone Port** (as measured in
  Schwung's `docs/SYSEX.md`).
  - The app's automatic selection gives the Standalone Port top priority.
- Assign the incoming CCs with Schwung's CC map / CC learn. Use the SEND / TEST / SEND
  X/Y/BOTH buttons in each slider's and XY pad's settings (long-press the name) for that
  learning.
  - The bottom-right fader's CH/CC can be changed in the FADER section of the XY MIDI
    configuration sheet.
- Ableton Move's stock firmware alone offers only limited ways to assign arbitrary CCs.

## 2. Enabling Mirror Display

These are the steps from "Display Mirror" in
[move-anything's MANUAL.md](https://github.com/peterjungx/move-anything/blob/main/MANUAL.md).

1. On the Move, press **Shift + Vol + Step 2** to open Global Settings.
2. Set **Display → Mirror Display** to **On**. The setting is kept across restarts.
3. Open `http://move.local:7681` in a browser and the Move's screen appears.

### How it is streamed (from reading `src/host/display_server.c`)

| Item | Details |
|---|---|
| Server | An HTTP server on port 7681 (starts automatically at boot, idle while Mirror is OFF) |
| `GET /` | HTML: `<canvas width=128 height=64>` and the JS that draws it |
| `GET /stream` | **Server-Sent Events**. One frame is 1024 bytes (SSD1306 format, 8 pages × 128 columns, 1 bit/px) in base64. About 30 Hz, sent only when the screen changes |
| Simultaneous connections | Up to 8 clients |

The app **shows this page as it is in a WKWebView**. No streaming code of its own is
implemented. Only the following CSS and JS are injected into the page:

- A black background, with the canvas scaled to fill the view (`image-rendering: pixelated`)
- Removing the border and the status display
- Neon-blue tinting (switch it OFF in the settings for black and white)
- Passing the page's `#status` string (`connected - 30 fps` and the like) to the native
  side, shown as the connection state

The WebView is display-only. Scrolling, pinch zoom and touch are all disabled.

### Display paths (USB first)

- The default URL is **`http://172.16.254.1:7681`**.
  - 172.16.254.1 is the Move's address when connected over USB-C (stated in
    [Ableton's help article](https://help.ableton.com/hc/en-us/articles/14645140037788-Troubleshooting-Move-network-connections)).
  - display_server listens on every interface, so the mirror works with just the USB-C cable.
  - If the old default `http://move.local:7681` was saved, it is migrated to the USB
    address automatically at start-up.
- **When USB cannot be reached, it is shown over Wi-Fi** (switchable in the settings;
  default ON).
  - If it cannot load over USB, it immediately tries `move.local` (Wi-Fi).
  - While shown over Wi-Fi, it checks the USB side every 15 s and returns to USB once it
    is back.
  - If the stream does not come back within 5 s (for example after unplugging the
    cable), it switches path and reloads.
- At the bottom left of the Mirror view on the main screen, the current path (`USB` /
  `Wi-Fi` / `LAN`) is shown small.
- The **USB 172.16.254.1** / **Wi-Fi move.local** buttons in the settings switch
  explicitly.
- **NETWORK PATH CHECK** checks whether the page can be reached over wired (USB
  Ethernet), over Wi-Fi, and with no path restriction.

If the connection fails, it shows an error and retries automatically. Tapping the
Mirror view while disconnected reconnects at once. Mirror Display not connecting has no
effect on MIDI operation.

---

## 3. Screen and controls

The design follows the reference app (OleOleMIDICon).

- The screen holds only what you touch during a live set. There are no framed buttons,
  panels or logs.
- Settings open with a **long press**. They appear as a sheet in the middle of the
  screen and scroll, so nothing runs off the screen.

| Position | Contents | Controls |
|---|---|---|
| Top row | App name, M (lit while MIDI is connected), battery level, stopwatch | **Long-press** the app name or M → overall settings. **Tap** the time → START/STOP, **long-press** → RESET |
| Top left | Move Mirror Display (the largest 2:1 that fits the free space). Display path (USB / Wi-Fi) at its bottom left | **Tap** while disconnected → reconnect |
| Top right | Sliders KICK / HAT / S1–S4 | Drag a slider. **Long-press** its name → that slider's settings |
| Bottom left | SET 1 (XY 1 / XY 2) | See below |
| Bottom right | Fader, SET 2 (XY 3 / XY 4) | See below |

### Battery level

- The status bar is hidden, so the level (icon and %) is shown between M and the
  stopwatch in the top row.
- The display updates as soon as the level or charging state changes.
- While charging, the icon has a lightning bolt.
- When not charging and at 20 % or less, it is shown in red.
- Where the level cannot be read (the simulator and so on) it shows `--%`.

### Sliders

- The same look and size as the reference app's ModWheel (65×210 pt, a dark navy
  rounded rectangle with a blue horizontal bar).
- The 6 sliders KICK / HAT / S1–S4 are spread evenly across the full width of the right
  column.
- **Relative dragging.** Moving up increases the value. The slider's height covers the
  whole 0–127 range, and the value does not jump to where you touch.
- The settings opened by long-pressing the name change the name, MIDI CH and CC, and
  send SEND / TEST / 0 / 64 / 127.
  - **TEST** is a sweep sending 0 → 127 → the current value over about 1 second.

### XY pads

- XY pads come **in sets of two**: SET 1 at the bottom left (XY 1, XY 2) and SET 2 at the
  bottom right (XY 3, XY 4).
- Each set holds **up to 16 named MIDI configurations**. One MIDI configuration holds
  both pads (CH, CC and reverse for each pad's X/Y).
  - Tap **◁ name ▷** under the set to switch both pads together.
  - Switching alone sends no MIDI (so parameters on the receiving side do not jump).
  - The marker position is remembered per MIDI configuration, and switching returns to
    that configuration's last position.
- **Long-press** the MIDI configuration's name to open its settings sheet.
  - It can add MIDI configurations (duplicating the selected one with each CC +2), delete,
    reorder and rename them.
  - Each pad's X/Y MIDI CH and CC, Reverse X/Y, ON/OFF, SEND X / Y / BOTH and CENTER are
    also operated here.

- The left edge is X=0, the right edge X=127, the bottom edge Y=0 and the top edge Y=127.
- How it behaves
  - The value is updated and sent the moment you touch.
  - It sends in real time while dragging.
  - When you lift your finger, the final value is always sent.
  - The last position is kept after you lift your finger.
- ON/OFF
  - When OFF, operating the pad sends no MIDI (the marker still moves).
  - SEND X / Y / BOTH are explicit actions for CC learning, so they send even when OFF.
  - **CENTER** moves to X=64, Y=64, and sends only when ON.
- Reverse X / Reverse Y invert the sent value per axis (`127 - v`). Default OFF.

### Fader (bottom right)

- To the left of SET 2's pads is a fader that looks like the sliders. It is operated with
  the same relative dragging as the sliders.
- Its CH/CC and value belong to each MIDI configuration. Switching MIDI configurations
  with ◁ ▷ also switches the fader's assignment and value (switching alone sends nothing).
- Its CH/CC can be changed in the **FADER** section of the sheet opened by long-pressing
  the MIDI configuration's name.
- Each pad has its own independent `DragGesture`. Together with the sliders, they can be
  operated at the same time with separate fingers.

### Stopwatch

- Timing is computed from "start time" and "accumulated time". It does not depend on how
  often the screen updates.
- It shows the correct elapsed time after returning from the background and after
  restarting the app. The state is saved.
- While running, the background gradient turns dark blue, as in the reference app.
- SETTINGS can switch to a millisecond display (`HH:MM:SS.mmm`).
- **Warning while stopped**: touching a slider, XY pad or the fader while the stopwatch
  is stopped shows a "**CLOCK STOPPED**" warning in the middle of the screen.
  - The warning does not block touches, so you can keep operating.
  - It disappears 1.5 s after you lift your finger, and immediately when the stopwatch starts.
  - It is not shown when touching the top row (app name, M, stopwatch) or the Mirror view.

---

## 4. MIDI implementation

- Sending API flow
  - Setup: `MIDIClientCreateWithBlock` → `MIDIOutputPortCreate`
  - Getting destinations: `MIDIGetNumberOfDestinations` / `MIDIGetDestination`
  - Sending: `MIDISendEventList` (MIDI 1.0 protocol, UMP Message Type 2)
- Message format: `Status = 0xB0 | (channel - 1)`, `Data1 = CC number`, `Data2 = value`
  - The UMP word is `0x2g_Bn_cc_vv` (g is the group).
- Detecting plugging and unplugging: it re-lists on the `msgSetupChanged`,
  `msgObjectAdded`, `msgObjectRemoved` and `msgPropertyChanged` notifications.
- Sending flow
  - Sending is handled by `MIDISendEngine`, separate from the SwiftUI views. It runs on a
    dedicated serial queue (QoS `.userInteractive`).
  - Thinning (`CCThrottle`) is independent per control (per slider, or per XY axis).
    - The same value is never sent twice in a row.
    - Sending is at most 60 Hz. Values arriving within the interval are held, and only the
      latest is sent later.
    - The final value at the end of a touch is sent immediately, regardless of the interval.
    - Explicit sends such as the SEND buttons always send, even the same value.
  - If there is no destination or a send error occurs, the message is recorded as `DROP` /
    `ERR`. The thinning memory is reset too, so after reconnecting even the same value is sent.
- Debug log
  - The sending thread appends to a locked ring buffer (300 entries).
  - The UI only reads it every 0.2 s with a `TimelineView`. It is not observed by SwiftUI,
    so sends never redraw the screen.
  - The log can be switched OFF; the send count is kept even when OFF.
- **Loopback test port** (SETTINGS)
  - Creates a virtual MIDI destination inside the app. Choosing it as the destination shows
    in the log, as `RX`, the bytes that actually went through Core MIDI.
  - A feature for checking what is sent without hardware.
  - Creating a virtual endpoint on iOS needs `UIBackgroundModes: audio`, so it is set in
    Info.plist.

---

## 5. Saved settings

`AppConfiguration` (Codable) is saved as JSON in UserDefaults.

- While operating, saves are debounced by 0.6 s. Moving to the background saves immediately.
- What is saved
  - Name, CH/CC and last value of the 6 sliders (KICK / HAT / S1–S4)
  - The XY pads' named MIDI configurations (each axis's CH/CC, reverse, position, the
    fader's CH/CC and value), the selected configuration, ON/OFF
  - The MIDI destination's identity
  - Mirror Display's URL and tint setting
  - The stopwatch state
  - Log settings
- Keys missing from the saved data are filled with defaults, so existing settings do not
  break when items are added in future.

Defaults:

| | CH | CC |
|---|---|---|
| KICK / HAT | 1 / 1 | 103 / 104 |
| S1–S4 | 1 | 20, 21, 22, 23 |
| XY 1 X / Y | 1 / 1 | 24 / 25 |
| XY 2 X / Y | 1 / 1 | 26 / 27 |
| XY 3 X / Y | 1 / 1 | 28 / 29 |
| XY 4 X / Y | 1 / 1 | 30 / 31 |
| Fader (bottom right) | 1 | 102 |

**SETTINGS → RESET CH/CC TO DEFAULTS** returns the controls' settings to the defaults.

---

## 6. Settings for live use

- It does not auto-sleep while running (`isIdleTimerDisabled`).
- The app's controls take priority over system gestures at the screen edges
  (`defersSystemGestures`). The status bar and home indicator are hidden.
- There are no scrolling views. The Mirror WebView accepts no touches either.
- Keeping drawing cheap
  - `@Observable` observes per property, so moving one control does not redraw the others.
  - Sliders and XY pads are drawn with `Canvas`. The glow effect sits on a background
    layer that does not depend on position.
- Every piece of text that takes a tap or long press has a hit area at least 44 pt tall.
  For sliders and XY pads the whole body is the hit area.

---

## 7. Building

```bash
open OleOleMoveController.xcodeproj
```

- Scheme: `OleOleMoveController`
- To run on a device, set the Team in Signing & Capabilities (the initial value is the same
  Team as the reference project).
- Running the tests:

```bash
xcodebuild test -project OleOleMoveController.xcodeproj -scheme OleOleMoveController -destination 'platform=iOS Simulator,name=iPad Pro (11-inch) (4th generation)'
```

### Files

| File | Role |
|---|---|
| `OleOleMoveControllerApp.swift` | Entry point, sleep prevention, saving and reconnecting according to ScenePhase |
| `ContentView.swift` | The one-screen layout (`ControllerLayout` computes each area's size), the top row (including the battery level), the warning while the stopwatch is stopped |
| `MIDIMessage.swift` | `ControlChange` (bytes and UMP), `CCValueMapper`, `CCThrottle`. Pure logic with no Core MIDI dependency |
| `MIDIManager.swift` | The Core MIDI client and port, listing / auto-selecting / plug handling of destinations, `MIDISendEngine`, `MIDILog` |
| `MIDIControlConfiguration.swift` | Types of the saved settings |
| `ConfigurationStore.swift` | Saving to and loading from UserDefaults (debounced) |
| `ControllerModels.swift` | `KnobModel`, `XYPadModel`, `XYPadSetModel` (set and fader), `AppModel` |
| `SliderView.swift` | Slider |
| `XYPadView.swift` | XY pad (including the ◁ ▷ MIDI configuration switch) |
| `StopwatchView.swift` | Stopwatch (logic and display) |
| `MoveMirrorView.swift` | Mirror display with WKWebView, `MirrorController` |
| `MirrorDiagnostics.swift` | Reachability checks per USB/Wi-Fi path, interface monitoring |
| `SettingsView.swift` | Settings sheets for sliders, XY pads (managing MIDI configurations) and the whole app |
| `Theme.swift` | Colours, the Futura font, `Neon` / `BlueShadow` (from the reference app) |

---

## 8. Verification status

| # | Item | Status |
|---|---|---|
| 1 | The layout fits an iPad in landscape | ✅ `LayoutTests` checks the sizes of 6 main models by calculation. Installed and launched on a device (iPad Pro 11" M4). **Not yet checked by eye** |
| 2 | 6 sliders operated independently | ✅ Relative dragging checked by unit tests. Not yet tried on a device |
| 3 | Two XY pads operated at the same time | ⚠️ Each pad has its own independent `DragGesture`. **Simultaneous operation not yet checked on a device** |
| 4 | Independent CH/CC settings per axis | ✅ Unit tests |
| 5 | Correct MIDI CC messages sent | ✅ Unit tests of the status byte, data bytes and UMP, plus an integration test through a Core MIDI virtual port (loopback) that receives `B2 16 63` / `BF 1B 00` |
| 6 | SEND sends the current value | ✅ Unit tests (forced send) |
| 7 | USB plugging and unplugging | ⚠️ The logic of stopping while disconnected and resending after reconnecting is checked by unit tests. **Not yet tested by unplugging USB on a device** |
| 8 | Settings kept after a restart | ✅ Saving and loading, and filling in missing keys, checked by unit tests. Restart on a device not yet checked |
| 9 | Stopwatch | ✅ Unit tests (computing from time, RESET, the clock going backwards) |
| 10 | Mirror Display connection | ⚠️ The mock server (`Tools/mock_display_server.py`) is confirmed to answer over HTTP and SSE. **Display inside the app and with a real Move not yet tested** |
| 11 | UI still works when the Mirror connection fails | ⚠️ By design independent of MIDI (on failure it shows an error and retries automatically). **Behaviour not yet checked** |
| 12 | Battery level display | ⚠️ Only the build is confirmed. **Not yet checked on a device** |
| 13 | Warning while the stopwatch is stopped | ⚠️ Only the build is confirmed. **Whether the warning appears, and whether sliders and pads stay usable while it is shown, not yet checked** |

**Not yet tested because hardware is needed**

- With an Ableton Move actually connected over USB-C: the MIDI port names, automatic
  detection and CC reception
- Whether HTTP (Mirror) can be reached over the USB-C cable alone
  - Whether the Move appears to the iPad as USB Ethernet can be checked with NETWORK PATH
    CHECK inside the app.
- Simultaneous multi-touch and latency on a device

### Trying Mirror with the mock server

Run this on a Mac and set the URL to `http://localhost:7681` on the simulator side.

```bash
python3 Tools/mock_display_server.py
```
