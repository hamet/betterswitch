import Foundation
import Carbon
import IOKit.hid
import ApplicationServices

// betterswitch — cycles the keyboard layout on a short press of the Fn/🌐 key.
//
// Build:  swiftc -O betterswitch.swift -o betterswitch
// Run:    ./betterswitch             (requires the Input Monitoring permission)
//         ./betterswitch --verbose   (also lists HID devices on startup)
//
// The Globe key's own action must be turned off:
// System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.
//
// The key is read straight off the device via IOKit HID rather than from the
// event stream. With the action set to "Do Nothing" macOS emits no event for 🌐
// at all — neither .cgSessionEventTap nor .cghidEventTap sees it. The device's
// HID element exists regardless of that setting.

// --- Configuration ---

// Longest press still counted as a short tap
let tapThreshold: CFAbsoluteTime = 0.3

// Modifiers that disqualify a 🌐 press from switching.
// Caps Lock (.maskAlphaShift) is deliberately not among them.
let blockingModifiers: CGEventFlags = [.maskCommand, .maskAlternate,
                                       .maskControl, .maskShift]

// The HID element behind Fn/🌐 on Apple keyboards:
// AppleVendorTopCase (0xFF), KeyboardFn (0x03)
let fnUsagePage: UInt32 = 0xFF
let fnUsage: UInt32 = 0x03

// --- Input Monitoring permission ---
if !CGPreflightListenEventAccess() {
    CGRequestListenEventAccess()
    print("Input Monitoring permission is missing.")
    print("System Settings → Privacy & Security → Input Monitoring → add betterswitch (or the terminal it was launched from), then restart it.")
    exit(1)
}

// --- State ---
var pressedAt: CFAbsoluteTime = 0
var chord = false

// --- Input sources (Carbon TIS) ---

// TISGetInputSourceProperty is a Get-family call: the value comes back unretained
func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
}

func sourceID(_ source: TISInputSource) -> String? {
    return property(source, kTISPropertyInputSourceID) as? String
}

func isCyclable(_ source: TISInputSource) -> Bool {
    guard let category = property(source, kTISPropertyInputSourceCategory) as? String,
          category == (kTISCategoryKeyboardInputSource as String),
          (property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool) == true,
          (property(source, kTISPropertyInputSourceIsEnabled) as? Bool) == true
    else { return false }
    return true
}

func cyclableSources() -> [TISInputSource] {
    // false → only the sources enabled in settings, not everything installed
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue()
            as NSArray? as? [TISInputSource] else { return [] }
    return list.filter(isCyclable)
}

func cycleInputSource() {
    let sources = cyclableSources()
    guard sources.count > 1 else { return }

    // TISCopyCurrentKeyboardInputSource is a Copy-family call: retained
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let currentID = sourceID(current) else { return }

    // Match by ID rather than by reference: TIS may hand back a different
    // object for the same layout
    guard let index = sources.firstIndex(where: { sourceID($0) == currentID })
    else { return }

    TISSelectInputSource(sources[(index + 1) % sources.count])
}

// --- Handling 🌐 presses ---

// Modifiers are read from system state: the HID callback knows nothing about
// them, being subscribed to the Fn element alone
func otherModifiersHeld() -> Bool {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    return !flags.intersection(blockingModifiers).isEmpty
}

func handleFn(pressed: Bool) {
    if pressed {
        pressedAt = CFAbsoluteTimeGetCurrent()
        chord = otherModifiersHeld()
    } else {
        if !chord,
           !otherModifiersHeld(),
           CFAbsoluteTimeGetCurrent() - pressedAt < tapThreshold {
            cycleInputSource()
        }
        chord = false
    }
}

func valueCallback(context: UnsafeMutableRawPointer?,
                   result: IOReturn,
                   sender: UnsafeMutableRawPointer?,
                   value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    guard IOHIDElementGetUsagePage(element) == fnUsagePage,
          IOHIDElementGetUsage(element) == fnUsage else { return }
    handleFn(pressed: IOHIDValueGetIntegerValue(value) != 0)
}

// --- IOHIDManager setup ---
let manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                 IOOptionBits(kIOHIDOptionsTypeNone))

// Keyboards: GenericDesktop (0x01) / Keyboard (0x06), plus the Apple vendor
// collection where some models expose Fn
let deviceMatching: [[String: Any]] = [
    [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06],
    [kIOHIDDeviceUsagePageKey: 0xFF, kIOHIDDeviceUsageKey: 0x03],
]
IOHIDManagerSetDeviceMatchingMultiple(manager, deviceMatching as CFArray)

// Subscribe to exactly one element — the Fn state. Nothing else from the
// keyboard is delivered to this process.
let valueMatching: [[String: Any]] = [
    [kIOHIDElementUsagePageKey: Int(fnUsagePage), kIOHIDElementUsageKey: Int(fnUsage)],
]
IOHIDManagerSetInputValueMatchingMultiple(manager, valueMatching as CFArray)

IOHIDManagerRegisterInputValueCallback(manager, valueCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(),
                                CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    print(String(format: "IOHIDManagerOpen failed: 0x%08X", openResult))
    print("This is usually a denied Input Monitoring permission.")
    exit(1)
}

// --- Startup check ---
// Find which device carries the Fn element: if none does, the key will not
// work, and that should be said up front rather than failing silently
let verbose = CommandLine.arguments.contains("--verbose")
var devicesWithFn = 0

if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
    if verbose { print("HID devices found: \(devices.count)") }
    for device in devices {
        let elements = IOHIDDeviceCopyMatchingElements(
            device,
            [kIOHIDElementUsagePageKey: Int(fnUsagePage),
             kIOHIDElementUsageKey: Int(fnUsage)] as CFDictionary,
            IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
        let found = (elements?.count ?? 0) > 0
        if found { devicesWithFn += 1 }
        if verbose {
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "—"
            print("  • \(name) — Fn element: \(found ? "yes" : "no")")
        }
    }
} else if verbose {
    print("IOHIDManagerCopyDevices returned nil")
}

if devicesWithFn == 0 {
    print("Warning: the Fn element (0xFF/0x03) was not found on any device.")
    print("This keyboard may expose 🌐 under a different usage — run with --verbose.")
}

let initialCount = cyclableSources().count
if initialCount < 2 {
    print("Warning: \(initialCount) layout(s) in the cycle — nothing to switch between.")
    print("Add a second one under System Settings → Keyboard → Input Sources.")
}

print("betterswitch running: a short 🌐 press cycles the layout (\(initialCount) in the cycle).")
CFRunLoopRun()
