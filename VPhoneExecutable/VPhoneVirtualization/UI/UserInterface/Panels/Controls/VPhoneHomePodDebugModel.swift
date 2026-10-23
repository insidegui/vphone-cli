import Foundation

/// SoundBoard supplies its fixed, ABI-checked debug catalog. Keeping the editor
/// driven by that catalog avoids silently hiding operations when UI and daemon
/// versions differ.
@MainActor
@Observable
final class VPhoneHomePodDebugModel {
    struct Argument: Decodable, Identifiable {
        let name: String
        let type: String
        let initial: VPhoneHomePodDebugJSON
        let help: String
        var id: String { name }
    }

    struct Operation: Decodable, Identifiable {
        let id: String
        let title: String
        let group: String
        let arguments: [Argument]
        let reply: String
        let help: String
        let available: Bool
    }

    struct Group: Identifiable {
        let id: String
        let operations: [Operation]
    }

    let control: VPhoneGuestControl
    private(set) var groups: [Group] = []
    private(set) var operations: [Operation] = []
    private(set) var animations: [String] = []
    private(set) var phases: [String] = []
    var selectedID = "getAllDebugInfo:"
    var values: [String: String] = [:]
    private(set) var isBusy = false
    private(set) var result = ""
    private(set) var error: String?

    var selected: Operation? { operations.first { $0.id == selectedID } }

    init(control: VPhoneGuestControl) { self.control = control }

    func load() async {
        guard !isBusy, control.isConnected else { return }
        guard control.guestCapabilities.contains("homepod_debug") else {
            error = "The guest agent does not expose SoundBoard debugging. Update the guest environment to use these controls."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await control.call("homepod.debug.catalog")
            let data = try JSONSerialization.data(withJSONObject: result["operations"] ?? [])
            operations = try JSONDecoder().decode([Operation].self, from: data)
            animations = result["animations"] as? [String] ?? []
            phases = result["phases"] as? [String] ?? []
            var names: [String] = []
            for operation in operations where !names.contains(operation.group) { names.append(operation.group) }
            groups = names.map { name in Group(id: name, operations: operations.filter { $0.group == name }) }
            if !operations.contains(where: { $0.id == selectedID }) { selectedID = operations.first?.id ?? "" }
            resetArguments()
            error = nil
        } catch { self.error = String(describing: error) }
    }

    func resetArguments() {
        values = Dictionary(uniqueKeysWithValues: (selected?.arguments ?? []).map { ($0.name, $0.initial.editorText) })
    }

    func restartSoundBoard() async {
        guard !isBusy, control.isConnected else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let response = try await control.call("services.kickstart", params: [
                "label": "com.apple.SoundBoard", "kill": true, "force": true,
            ])
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            result = String(decoding: data, as: UTF8.self)
        } catch { self.error = String(describing: error) }
    }

    func execute() async {
        guard !isBusy, control.isConnected, let operation = selected, operation.available else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            var arguments: [String: Any] = [:]
            for argument in operation.arguments {
                let text = values[argument.name] ?? ""
                if argument.type == "string" { arguments[argument.name] = text; continue }
                guard let data = text.data(using: .utf8) else { throw VPhoneHomePodDebugEditorError.invalid(argument.name) }
                do { arguments[argument.name] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
                catch { throw VPhoneHomePodDebugEditorError.invalid(argument.name) }
            }
            let response = try await control.call("homepod.debug.call", params: ["operation": operation.id, "arguments": arguments])
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            result = String(decoding: data, as: UTF8.self)
        } catch { self.error = String(describing: error) }
    }
}

private enum VPhoneHomePodDebugEditorError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case let .invalid(name): "\(name) must contain a valid JSON value." }
    }
}

/// Codable JSON preserves the guest's typed argument defaults without an Any
/// payload in observable state.
indirect enum VPhoneHomePodDebugJSON: Decodable {
    case string(String), number(Double), bool(Bool), array([Self]), object([String: Self]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = try .object(container.decode([String: Self].self)) }
    }

    private var object: Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .array(value): value.map(\.object)
        case let .object(value): value.mapValues(\.object)
        case .null: NSNull()
        }
    }

    var editorText: String {
        if case let .string(value) = self { return value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
