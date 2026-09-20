# betterswitch

Switch the keyboard layout with the Fn/🌐 key on macOS — instantly, with no popup.

The built-in Globe key behavior shows a picker overlay and has a noticeable lag between input sources. This small Swift utility replaces it: a short tap on 🌐 cycles through your enabled input sources immediately.

## How it works

The Globe key is read **straight off the device** via IOKit HID, not from the event stream. `IOHIDManager` is opened on the keyboards and subscribed — through `IOHIDManagerSetInputValueMatchingMultiple` — to a single element: `AppleVendorTopCase` (usage page `0xFF`), `KeyboardFn` (usage `0x03`). When that element goes to 1 the timestamp is recorded; when it returns to 0 the next input source is selected, provided the press was shorter than 0.3 s and no other modifier was held. Modifier state is read on demand with `CGEventSource.flagsState`, so `Fn`+anything, a long hold, or any chord is ignored.

Switching itself is the Carbon Text Input Source API: `TISCreateInputSourceList` for the enabled keyboard sources, `TISCopyCurrentKeyboardInputSource` for the current one, `TISSelectInputSource` for the next in the list. Sources are matched by `kTISPropertyInputSourceID` rather than by object identity, since TIS may hand back a different object for the same layout.

Reading the device directly is not an implementation preference — it is the only thing that works. See the note below.

### Why not a CGEventTap

The obvious design is a `CGEventTap` on `flagsChanged` filtered to keycode 63. It cannot work here, and the reason is worth recording:

- With **"Press 🌐 key to" set to "Do Nothing"** — the configuration this utility requires — macOS does not emit any event for the Globe key. Not at `.cgSessionEventTap`, and not at `.cghidEventTap` either. The key is switched off below both.
- Set the key to a real action and the events appear at both levels — but then the system performs that action too, so with "Change Input Source" the layout switches twice and lands back where it started.

There is no tap level and no threshold that resolves this. Subscribing to the HID element sidesteps it entirely, because the element exists regardless of what the setting is bound to.

## Installation

```bash
swiftc -O betterswitch.swift -o betterswitch   # requires Xcode CLT: xcode-select --install
sudo mv betterswitch /usr/local/bin/
/usr/local/bin/betterswitch                    # first run triggers the permission prompt
```

On first launch, macOS will ask for permission under **System Settings → Privacy & Security → Input Monitoring** — add the `betterswitch` binary itself (or the terminal it was launched from), then restart the utility.

Then set the Globe key to do nothing of its own:

**System Settings → Keyboard → "Press 🌐 key to"** → **Do Nothing**.

On startup the utility prints how many input sources are in the cycle, and warns if the Fn element was not found on any device. Run with `--verbose` to list the HID devices and which one carries the element.

## Run at login

Copy the LaunchAgent plist and load it:

```bash
cp com.user.betterswitch.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.betterswitch.plist
```

## Notes

- No network access, no update check, no bundled app, no login-item API — the LaunchAgent above is the only autostart mechanism, and removing the plist is the only uninstall step besides deleting the binary.
- The value-matching subscription means the process receives the state of one key and nothing else. It is not that key events are received and ignored — they are never delivered.
- Layouts are cycled in the order macOS lists them in Keyboard settings. With exactly two sources this is a plain toggle; the utility does no most-recently-used tracking.
- The `0xFF`/`0x03` element is where Apple puts Fn on built-in keyboards. A third-party keyboard, or an external one that reports Globe on the consumer page, will not be picked up — `--verbose` shows this immediately.
- To cycle backwards while `Shift` is held: drop `.maskShift` from `blockingModifiers`, then in `cycleInputSource` pick `(index - 1 + sources.count) % sources.count` when `CGEventSource.flagsState(.combinedSessionState)` contains `.maskShift`.
- The Input Monitoring grant is tied to the binary. After rebuilding, re-add it in System Settings.
