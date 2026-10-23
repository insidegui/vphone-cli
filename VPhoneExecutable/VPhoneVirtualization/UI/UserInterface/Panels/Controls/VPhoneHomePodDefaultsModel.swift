import Foundation
import Observation

/// A default's identity, editor and constraints come from SBSDefaultInfo, not
/// a host-maintained list of SoundBoard flags. Archived bytes are not needed.
struct VPhoneHomePodUserDefault: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case bool, int, float, string, unsupported }

    let id: String
    let description: String
    let kind: Kind
    let nativeType: String
    let currentValue: String
    let defaultValue: String
    let rangeMin: Decimal?
    let rangeMax: Decimal?
    let isModified: Bool
    let requiresReinit: Bool

    func validated(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        switch kind {
        case .bool:
            switch trimmed.lowercased() {
            case "1", "true", "yes": value = "1"
            case "0", "false", "no": value = "0"
            default: throw VPhoneHomePodDefaultsError("Enter a Boolean value.")
            }
        case .int:
            if let number = Int64(trimmed) { value = String(number) }
            else if let number = UInt64(trimmed) { value = String(number) }
            else { throw VPhoneHomePodDefaultsError("Enter a whole number within the 64-bit range.") }
        case .float:
            guard let number = Double(trimmed), number.isFinite else {
                throw VPhoneHomePodDefaultsError("Enter a finite number using a period as the decimal separator.")
            }
            value = String(number)
        case .string: return input
        case .unsupported: throw VPhoneHomePodDefaultsError("This firmware's value type is not supported by the editor.")
        }
        if kind == .int || kind == .float {
            guard let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
                throw VPhoneHomePodDefaultsError("The number is outside the supported range.")
            }
            if let rangeMin, number < rangeMin { throw VPhoneHomePodDefaultsError("The value is below the minimum of \(rangeMin).") }
            if let rangeMax, number > rangeMax { throw VPhoneHomePodDefaultsError("The value is above the maximum of \(rangeMax).") }
        }
        return value
    }

    static func parse(_ response: [String: Any]) throws -> [Self] {
        guard let value = response["value"] as? [String: Any], let array = value["array"] as? [[String: Any]] else {
            throw VPhoneHomePodDefaultsError("SoundBoard did not return a user defaults list.")
        }
        var seen: Set<String> = []
        return try array.map { row in
            guard let info = row["info"] as? [String: Any], let metadata = info["decoded"] as? [String: Any],
                  let name = metadata["stringForUserDefault"] as? String, !name.isEmpty,
                  seen.insert(name).inserted else {
                throw VPhoneHomePodDefaultsError("SoundBoard returned missing or duplicate default metadata.")
            }
            let type = metadata["valueType"] as? String ?? "unknown"
            let kind: Kind = (metadata["isBool"] as? Bool) == true ? .bool
                : (metadata["isDouble"] as? Bool) == true ? .float : Kind(rawValue: type) ?? .unsupported
            return Self(id: name, description: metadata["userDescription"] as? String ?? name,
                        kind: kind, nativeType: type,
                        currentValue: text(row["value"], kind: kind),
                        defaultValue: text(metadata["defaultValue"], kind: kind),
                        rangeMin: decimal(metadata["rangeMin"]), rangeMax: decimal(metadata["rangeMax"]),
                        isModified: (row["mod"] as? Bool) == true,
                        requiresReinit: (metadata["requiresReinit"] as? Bool) == true)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func text(_ value: Any?, kind: Kind) -> String {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber { text = number.stringValue }
        else if let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
        } else { return "" }
        if kind == .bool {
            switch text.lowercased() {
            case "true", "yes", "1": return "1"
            case "false", "no", "0": return "0"
            default: break
            }
        }
        return text
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber else { return nil }
        return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct VPhoneHomePodDefaultsError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
@Observable
final class VPhoneHomePodDefaultsModel {
    typealias Call = @MainActor (String, [String: String]) async throws -> [String: Any]
    @ObservationIgnored private let call: Call

    private(set) var entries: [VPhoneHomePodUserDefault] = []
    private(set) var visibleEntries: [VPhoneHomePodUserDefault] = []
    private(set) var drafts: [String: String] = [:]
    var selectedID: String?
    var searchText = "" { didSet { updateVisibleEntries() } }
    var overridesOnly = false { didSet { updateVisibleEntries() } }
    private(set) var isBusy = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var status: String?

    var selected: VPhoneHomePodUserDefault? { entries.first { $0.id == selectedID } }
    var pendingCount: Int { drafts.count }

    init(call: @escaping Call) { self.call = call }

    func text(for entry: VPhoneHomePodUserDefault) -> String { drafts[entry.id] ?? entry.currentValue }

    func edit(_ entry: VPhoneHomePodUserDefault, text: String) {
        guard !isBusy else { return }
        let validated = try? entry.validated(text)
        if text == entry.currentValue || (validated != nil && validated == (try? entry.validated(entry.currentValue))) {
            drafts.removeValue(forKey: entry.id)
        } else { drafts[entry.id] = text }
        status = nil
    }

    func discard(_ entry: VPhoneHomePodUserDefault) { drafts.removeValue(forKey: entry.id) }

    func validationError(for entry: VPhoneHomePodUserDefault) -> String? {
        do { _ = try entry.validated(text(for: entry)); return nil }
        catch { return String(describing: error) }
    }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do { apply(try await read()) }
        catch { self.error = String(describing: error) }
    }

    func save(_ entry: VPhoneHomePodUserDefault) async {
        guard !isBusy, drafts[entry.id] != nil else { return }
        await change(entry, reset: false)
    }

    func reset(_ entry: VPhoneHomePodUserDefault) async {
        guard !isBusy, entry.isModified else { return }
        await change(entry, reset: true)
    }

    private func change(_ entry: VPhoneHomePodUserDefault, reset: Bool) async {
        isBusy = true
        error = nil
        status = nil
        defer { isBusy = false }
        var submitted = false
        do {
            let requested = reset ? nil : try entry.validated(text(for: entry))
            var arguments = ["name": entry.id]
            if let requested { arguments["value"] = requested }
            _ = try await call(reset ? "resetUserDefault:" : "setUserDefaults:withValue:", arguments)
            submitted = true
            // These setters return submission, not completion. Read back the
            // guest value before clearing a draft or claiming that it saved.
            for attempt in 0..<6 {
                if attempt > 0 { try await Task.sleep(for: .milliseconds(200)) }
                let refreshed = try await read()
                apply(refreshed)
                guard let current = refreshed.first(where: { $0.id == entry.id }) else { break }
                let matches = reset ? !current.isModified
                    : current.isModified && (try? current.validated(current.currentValue)) == requested
                if matches {
                    drafts.removeValue(forKey: entry.id)
                    status = reset ? "Reset \(entry.id)." : "Saved \(entry.id)."
                    return
                }
            }
            throw VPhoneHomePodDefaultsError("SoundBoard has not reported the requested change. Refresh to check its current value.")
        } catch {
            self.error = submitted ? "Change submitted, but could not confirm it: \(error)" : String(describing: error)
        }
    }

    private func read() async throws -> [VPhoneHomePodUserDefault] {
        try VPhoneHomePodUserDefault.parse(await call("getUserDefaults:", [:]))
    }

    private func apply(_ entries: [VPhoneHomePodUserDefault]) {
        self.entries = entries
        // Refresh preserves edits, including edits to other selected defaults.
        let names = Set(entries.map(\.id))
        drafts = drafts.filter { names.contains($0.key) }
        hasLoaded = true
        updateVisibleEntries()
    }

    private func updateVisibleEntries() {
        visibleEntries = entries.filter {
            (!overridesOnly || $0.isModified) && (searchText.isEmpty
                || $0.id.localizedCaseInsensitiveContains(searchText)
                || $0.description.localizedCaseInsensitiveContains(searchText))
        }
        if !visibleEntries.contains(where: { $0.id == selectedID }) { selectedID = visibleEntries.first?.id }
    }
}
