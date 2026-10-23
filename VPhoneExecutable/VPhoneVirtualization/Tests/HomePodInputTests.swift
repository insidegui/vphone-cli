import AppKit

/// Exercise the actual AppKit hit areas and their emitted transitions.
@main
struct HomePodInputTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let cap = VPhoneHomePodDisplayView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        cap.layoutSubtreeIfNeeded()
        let buttons = cap.subviews.compactMap { $0 as? NSButton }
        let center = try require(buttons.first { $0.accessibilityLabel() == "HomePod touch surface" })
        let plus = try require(buttons.first { $0.accessibilityLabel() == "Increase volume" })
        let minus = try require(buttons.first { $0.accessibilityLabel() == "Decrease volume" })
        precondition(!center.isHidden && center.isAccessibilityElement())
        precondition(plus.nextKeyView === center && center.nextKeyView === minus)
        var events: [VPhoneHomePodDisplayView.ControlEvent] = []
        cap.onControlChange = { events.append($0) }

        // AX and rapid repeated taps retain distinct, immediate down/up pairs.
        for _ in 0..<3 { precondition(center.accessibilityPerformPress()) }
        precondition(events.count == 6)
        for (index, event) in events.enumerated() {
            precondition(event.control.usage == 0xCD && event.down == (index % 2 == 0))
            precondition(event.minimumHold == .zero && !event.longPress)
        }
        events.removeAll()
        precondition(plus.accessibilityPerformPress() && minus.accessibilityPerformPress())
        precondition(events.map { $0.control.usage } == [0xE9, 0xE9, 0xEA, 0xEA])
        precondition(events[1].minimumHold == .milliseconds(700) && events[3].minimumHold == .milliseconds(700))

        let down = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: 0, context: nil,
                                                eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              eventNumber: 2, clickCount: 1, pressure: 0))
        events.removeAll()
        center.mouseDown(with: down)
        center.mouseDown(with: down) // Repeats do not create extra presses/timers.
        try await Task.sleep(for: .milliseconds(650))
        center.mouseUp(with: up)
        precondition(events.count == 3)
        precondition(events.map(\.down) == [true, true, false])
        precondition(events.map(\.longPress) == [false, true, true])

        // Closing, focus loss and disconnect use the same release path. A
        // cancelled timer must not fire into a subsequent short press.
        events.removeAll()
        center.mouseDown(with: down)
        cap.releaseControls()
        center.mouseDown(with: down)
        center.mouseUp(with: up)
        try await Task.sleep(for: .milliseconds(650))
        precondition(events.count == 4 && events.allSatisfy { !$0.longPress })
        cap.releaseControls()
        precondition(events.count == 4)
        print("HomePod top-cap tap, multi-tap, hold, release and volume tests passed")
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "HomePodInputTests", code: 1) }
        return value
    }
}
