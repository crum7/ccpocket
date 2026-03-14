#!/usr/bin/env swift
//
// sim-tap.swift — Tap native iOS Simulator UI elements by accessibility label.
//
// Usage:
//   swift scripts/sim-tap.swift tap "許可"        # Find & tap button by label
//   swift scripts/sim-tap.swift describe          # Dump accessible elements
//   swift scripts/sim-tap.swift wait "許可" 10    # Wait up to 10s for element, then tap
//
// Requires: Accessibility permission for Terminal/iTerm in System Settings.
//

import AppKit
import Foundation

// MARK: - AX Helpers

func axValue<T>(_ element: AXUIElement, _ attr: String) -> T? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axValue(element, kAXChildrenAttribute) ?? []
}

func axRole(_ element: AXUIElement) -> String? {
    axValue(element, kAXRoleAttribute)
}

func axTitle(_ element: AXUIElement) -> String? {
    axValue(element, kAXTitleAttribute)
}

func axDescription(_ element: AXUIElement) -> String? {
    axValue(element, kAXDescriptionAttribute)
}

func axValue_(_ element: AXUIElement) -> String? {
    axValue(element, kAXValueAttribute)
}

func axLabel(_ element: AXUIElement) -> String {
    axTitle(element) ?? axDescription(element) ?? axValue_(element) ?? ""
}

func axPosition(_ element: AXUIElement) -> CGPoint? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
          let v = value else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(v as! AXValue, .cgPoint, &point)
    return point
}

func axSize(_ element: AXUIElement) -> CGSize? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
          let v = value else { return nil }
    var size = CGSize.zero
    AXValueGetValue(v as! AXValue, .cgSize, &size)
    return size
}

// MARK: - Tree traversal

struct ElementInfo {
    let element: AXUIElement
    let role: String
    let label: String
    let position: CGPoint?
    let size: CGSize?
    let depth: Int
}

func walkTree(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 15, results: inout [ElementInfo]) {
    guard depth <= maxDepth else { return }
    let role = axRole(element) ?? "unknown"
    let label = axLabel(element)
    let pos = axPosition(element)
    let sz = axSize(element)
    results.append(ElementInfo(element: element, role: role, label: label, position: pos, size: sz, depth: depth))
    for child in axChildren(element) {
        walkTree(child, depth: depth + 1, maxDepth: maxDepth, results: &results)
    }
}

// MARK: - Find Simulator window

func findSimulatorApp() -> AXUIElement? {
    let apps = NSWorkspace.shared.runningApplications
    guard let sim = apps.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) else {
        fputs("Error: Simulator.app is not running.\n", stderr)
        return nil
    }
    return AXUIElementCreateApplication(sim.processIdentifier)
}

// MARK: - Commands

func describe() {
    guard let app = findSimulatorApp() else { exit(1) }
    var elements: [ElementInfo] = []
    walkTree(app, results: &elements)
    for e in elements {
        let indent = String(repeating: "  ", count: e.depth)
        let posStr: String
        if let p = e.position, let s = e.size {
            posStr = " (\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))"
        } else {
            posStr = ""
        }
        let labelStr = e.label.isEmpty ? "" : " \"\(e.label)\""
        print("\(indent)[\(e.role)]\(labelStr)\(posStr)")
    }
}

func findElement(named name: String) -> ElementInfo? {
    guard let app = findSimulatorApp() else { return nil }
    var elements: [ElementInfo] = []
    walkTree(app, results: &elements)
    // Prefer exact match on buttons first
    if let match = elements.first(where: { $0.label == name && $0.role.contains("Button") }) {
        return match
    }
    // Then exact match on any element
    if let match = elements.first(where: { $0.label == name }) {
        return match
    }
    // Then substring match
    if let match = elements.first(where: { $0.label.contains(name) && $0.role.contains("Button") }) {
        return match
    }
    return elements.first(where: { $0.label.contains(name) })
}

func tap(name: String) -> Bool {
    guard let info = findElement(named: name) else {
        fputs("Error: Element \"\(name)\" not found.\n", stderr)
        return false
    }
    guard let pos = info.position, let size = info.size else {
        fputs("Error: Element \"\(name)\" has no position.\n", stderr)
        return false
    }
    let centerX = pos.x + size.width / 2
    let centerY = pos.y + size.height / 2
    print("Tapping \"\(info.label)\" [\(info.role)] at (\(Int(centerX)), \(Int(centerY)))")

    // Perform AX press action
    let result = AXUIElementPerformAction(info.element, kAXPressAction as CFString)
    if result == .success {
        print("OK (AXPress)")
        return true
    }

    // Fallback: click via CGEvent
    let point = CGPoint(x: centerX, y: centerY)
    let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    mouseDown?.post(tap: .cghidEventTap)
    usleep(100_000)
    mouseUp?.post(tap: .cghidEventTap)
    print("OK (CGEvent click)")
    return true
}

func wait(name: String, timeout: Int) -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeout))
    while Date() < deadline {
        if tap(name: name) { return true }
        Thread.sleep(forTimeInterval: 1.0)
    }
    fputs("Error: Timed out waiting for \"\(name)\" after \(timeout)s.\n", stderr)
    return false
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("""
    Usage:
      swift \(args[0]) tap <label>          Tap element by label
      swift \(args[0]) describe             List all accessible elements
      swift \(args[0]) wait <label> [sec]   Wait for element then tap (default 10s)

    """, stderr)
    exit(2)
}

switch args[1] {
case "describe":
    describe()
case "tap":
    guard args.count >= 3 else {
        fputs("Usage: tap <label>\n", stderr)
        exit(2)
    }
    exit(tap(name: args[2]) ? 0 : 1)
case "wait":
    guard args.count >= 3 else {
        fputs("Usage: wait <label> [timeout_sec]\n", stderr)
        exit(2)
    }
    let timeout = args.count >= 4 ? (Int(args[3]) ?? 10) : 10
    exit(wait(name: args[2], timeout: timeout) ? 0 : 1)
default:
    fputs("Unknown command: \(args[1])\n", stderr)
    exit(2)
}
