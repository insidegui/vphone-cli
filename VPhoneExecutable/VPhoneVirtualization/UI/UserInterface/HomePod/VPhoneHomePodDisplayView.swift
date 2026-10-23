import AppKit
import VPhoneCoreKit

// MARK: - HomePod Top Cap

/// The HomePod's light diffuser and capacitive controls. Every light comes
/// from the latest guest frame; this view has no autonomous animation clock.
@MainActor
final class VPhoneHomePodDisplayView: NSView {
    static let defaultContentSize = NSSize(width: 480, height: 480)

    enum Control: Hashable {
        case volumeDown
        case volumeUp
        case surface

        /// SoundBoard's SBHPIOHID maps consumer Play/Pause to Center.
        var usage: UInt32 {
            switch self {
            case .volumeDown: 0xEA
            case .volumeUp: 0xE9
            case .surface: 0xCD
            }
        }
    }

    struct ControlEvent {
        let control: Control
        let down: Bool
        var minimumHold: Duration = .zero
        var longPress = false
    }

    /// Paired transitions preserve a physical hold until pointer/key release.
    var onControlChange: ((ControlEvent) -> Void)?
    private(set) var geometry: VPhoneHomePodDisplayGeometry?
    private(set) var displayFrame: VPhoneHomePodDisplayFrame?

    private let canvas = VPhoneHomePodMetalView(frame: .zero)
    private let surface = VPhoneHomePodCapControl(control: .surface, label: "HomePod touch surface")
    private let minus = VPhoneHomePodCapControl(control: .volumeDown, label: "Decrease volume")
    private let plus = VPhoneHomePodCapControl(control: .volumeUp, label: "Increase volume")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        addSubview(canvas)
        for button in [surface, minus, plus] {
            button.onChange = { [weak self] event in
                self?.onControlChange?(event)
            }
            addSubview(button)
        }
        surface.nextKeyView = minus
        minus.nextKeyView = plus
        plus.nextKeyView = surface
        if let error = canvas.renderingError {
            let label = NSTextField(wrappingLabelWithString: "HomePod display unavailable: \(error)")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .secondaryLabelColor
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.defaultContentSize }

    /// A geometry change invalidates the previous frame. Never retain old LED
    /// indices against a new device layout, or display a partial snapshot.
    func update(geometry: VPhoneHomePodDisplayGeometry, frame: VPhoneHomePodDisplayFrame) {
        guard frame.matches(geometry) else { return }
        guard self.geometry != geometry || displayFrame != frame else { return }
        self.geometry = geometry
        displayFrame = frame
        canvas.update(geometry: geometry, snapshot: frame)
    }

    func clearDisplay() {
        releaseControls()
        guard displayFrame != nil else { return }
        displayFrame = nil
        canvas.update(geometry: geometry, snapshot: nil)
    }

    func releaseControls() {
        for button in [surface, minus, plus] { button.releaseControl() }
    }

    func focusControls() {
        window?.makeFirstResponder(minus)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        releaseControls()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowResignedKey(_ notification: Notification) { releaseControls() }

    private var capRect: CGRect {
        let diameter = max(0, min(bounds.width, bounds.height) - 32)
        return CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        let cap = capRect
        surface.frame = cap
        let side = cap.width * 0.19
        minus.frame = CGRect(x: cap.midX - cap.width * 0.30 - side / 2, y: cap.midY - side / 2, width: side, height: side)
        plus.frame = CGRect(x: cap.midX + cap.width * 0.30 - side / 2, y: cap.midY - side / 2, width: side, height: side)
    }

}

// MARK: - Capacitive Hit Areas

/// The pointer's up event returns to its original view even after dragging
/// outside it. Keeping down/up separate also lets the guest recognize holds.
@MainActor
private final class VPhoneHomePodCapControl: NSButton {
    let control: VPhoneHomePodDisplayView.Control
    var onChange: ((VPhoneHomePodDisplayView.ControlEvent) -> Void)?
    private var isPressed = false
    private var longPress = false
    private var holdTask: Task<Void, Never>?

    init(control: VPhoneHomePodDisplayView.Control, label: String) {
        self.control = control
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(activateControl)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp(control == .surface ? "Click or hold to touch the HomePod top surface." : "Click or hold to change the HomePod volume.")
        toolTip = label
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }
    override var focusRingType: NSFocusRingType { get { .none } set {} }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let radius = min(bounds.width, bounds.height) / 2
        guard hypot(local.x - bounds.midX, local.y - bounds.midY) <= radius else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressControl()
    }

    override func mouseUp(with event: NSEvent) { finishPress() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else if event.keyCode == 49 || event.keyCode == 36 { pressControl() }
        else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { finishPress() }
        else { super.keyUp(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        releaseControl()
        return super.resignFirstResponder()
    }

    override func accessibilityPerformPress() -> Bool {
        guard !isPressed else { return false }
        activateControl()
        return true
    }

    @objc private func activateControl() {
        pressControl()
        finishPress()
    }

    private func finishPress() {
        // Volume still needs a usable consumer-key hold. Center releases must
        // stay immediate so SoundBoard can coalesce double and triple taps.
        releaseControl(minimumHold: control == .surface ? .zero : .milliseconds(700))
    }

    private func pressControl() {
        guard !isPressed else { return }
        isPressed = true
        longPress = false
        onChange?(.init(control: control, down: true))
        if control == .surface {
            holdTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self, isPressed else { return }
                longPress = true
                // SoundBoard requires KeyboardLongPress, not repeated taps.
                onChange?(.init(control: control, down: true, longPress: true))
            }
        }
    }

    func releaseControl(minimumHold: Duration = .zero) {
        guard isPressed else { return }
        isPressed = false
        holdTask?.cancel()
        holdTask = nil
        onChange?(.init(control: control, down: false, minimumHold: minimumHold, longPress: longPress))
        longPress = false
    }

    // Visual markings belong to the optical shader; these views supply native
    // button, keyboard, and accessibility semantics above the Metal surface.
    override func draw(_ dirtyRect: NSRect) {}
}
