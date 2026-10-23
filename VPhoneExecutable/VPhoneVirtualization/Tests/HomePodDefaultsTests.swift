import AppKit
import SwiftUI

@main
struct HomePodDefaultsTests {
    @MainActor static func main() async throws {
        let preview = Bundle.main.bundleURL.pathExtension == "app"
        if preview {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            let url = Bundle.main.resourceURL!.appendingPathComponent("defaults.json")
            let reply = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let store = DefaultsStore(reply: reply)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 960, height: 680),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "HomePod Defaults Preview"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DefaultsPreview(store: store))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            return
        }

        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let reply = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let entries = try VPhoneHomePodUserDefault.parse(reply)
            precondition(entries.count == 150 && Set(entries.map(\.id)).count == 150)
            for entry in entries { _ = try entry.validated(entry.currentValue) }
            print("All 150 exported defaults decoded and their current typed values validated")
        }

        let store = DefaultsStore(reply: fixture())
        let model = VPhoneHomePodDefaultsModel(call: store.call)
        await model.load()
        precondition(model.error == nil && model.entries.count == 6)
        let boolean = model.entries.first { $0.id == "Boolean" }!
        let integer = model.entries.first { $0.id == "Integer" }!
        let real = model.entries.first { $0.id == "Float" }!
        let string = model.entries.first { $0.id == "String" }!
        let wide = model.entries.first { $0.id == "Wide" }!
        let unsupported = model.entries.first { $0.id == "Future" }!
        precondition(boolean.kind == .bool && boolean.currentValue == "1" && boolean.requiresReinit)
        precondition((try? boolean.validated("false")) == "0")
        precondition((try? wide.validated(wide.currentValue)) == "18446744073709551615")
        precondition((try? string.validated("  spaced text  ")) == "  spaced text  ")
        precondition(unsupported.kind == .unsupported && unsupported.currentValue == "{\"a\":1}")
        for value in ["1.5", "101", "-1", "18446744073709551616"] { rejects { try integer.validated(value) } }
        for value in ["nan", "inf", "-inf", "2.1", "text"] { rejects { try real.validated(value) } }
        precondition((try? real.validated("1e0")) == "1.0")
        rejects { try unsupported.validated("1") }
        model.searchText = "adjustable number"
        precondition(model.visibleEntries.map(\.id) == ["Integer"])
        model.searchText = ""
        model.overridesOnly = true
        precondition(model.visibleEntries.map(\.id) == ["Boolean"])
        model.overridesOnly = false

        model.edit(string, text: "draft")
        model.edit(integer, text: "20")
        await model.load()
        precondition(model.text(for: string) == "draft" && model.pendingCount == 2)
        store.delayedReads = 1
        await model.save(integer)
        precondition(model.error == nil && model.status == "Saved Integer.")
        precondition(model.pendingCount == 1 && model.text(for: string) == "draft")
        precondition(store.writes.last?.0 == "setUserDefaults:withValue:" && store.writes.last?.1 == ["name": "Integer", "value": "20"])
        precondition(model.entries.first { $0.id == "Integer" }!.isModified)

        let currentInteger = model.entries.first { $0.id == "Integer" }!
        model.edit(currentInteger, text: "101")
        let count = store.writes.count
        await model.save(currentInteger)
        precondition(model.error != nil && store.writes.count == count && model.drafts[integer.id] == "101")
        model.discard(currentInteger)

        // Reset removes an override even when its value equals the factory value.
        await model.reset(boolean)
        precondition(model.error == nil && model.status == "Reset Boolean.")
        precondition(store.writes.last?.0 == "resetUserDefault:" && store.writes.last?.1 == ["name": "Boolean"])
        precondition(!model.entries.first { $0.id == "Boolean" }!.isModified)
        precondition(model.text(for: string) == "draft")

        store.ignoresWrites = true
        model.edit(real, text: "1.5")
        await model.save(real)
        precondition(model.status == nil && model.error?.contains("has not reported") == true)
        precondition(model.drafts[real.id] == "1.5")
        store.ignoresWrites = false
        store.failsReadback = true
        await model.save(real)
        precondition(model.status == nil && model.error?.contains("Change submitted") == true)
        precondition(model.drafts[real.id] == "1.5")

        var duplicate = fixture()
        var value = duplicate["value"] as! [String: Any]
        var rows = value["array"] as! [[String: Any]]
        rows.append(rows[0])
        value["array"] = rows
        duplicate["value"] = value
        rejects { try VPhoneHomePodUserDefault.parse(duplicate) }
        rejects { try VPhoneHomePodUserDefault.parse(["value": [:]]) }
        let control = VPhoneGuestControl()
        let debug = VPhoneHomePodDebugModel(control: control)
        await debug.restartSoundBoard()
        precondition(debug.error == nil && !debug.isBusy && control.requests.count == 1)
        precondition(control.requests[0].0 == "services.kickstart")
        precondition(control.requests[0].1["label"] as? String == "com.apple.SoundBoard")
        precondition(control.requests[0].1["kill"] as? Bool == true && control.requests[0].1["force"] as? Bool == true)
        control.isConnected = false
        await debug.restartSoundBoard()
        precondition(control.requests.count == 1)
        control.isConnected = true
        control.fails = true
        await debug.restartSoundBoard()
        precondition(debug.error != nil && !debug.isBusy)
        print("Typed editors, bounds, 64-bit precision, search, overrides, draft preservation, save/reset readback and failure handling passed")
        print("SoundBoard restart targets only its launchd service; disconnected and failed requests are handled")
    }

    static func rejects<T>(_ operation: () throws -> T) {
        do { _ = try operation(); preconditionFailure("Expected invalid input to be rejected") }
        catch {}
    }

    static func fixture() -> [String: Any] {
        func row(_ name: String, _ type: String, _ value: Any, _ factory: Any,
                 modified: Bool = false, min: Int? = nil, max: Int? = nil) -> [String: Any] {
            ["info": ["decoded": ["stringForUserDefault": name,
                                  "userDescription": name == "Integer" ? "An adjustable number" : name,
                                  "valueType": type, "defaultValue": factory,
                                  "isBool": type == "bool", "isDouble": type == "float",
                                  "rangeMin": min.map { $0 as Any } ?? NSNull(),
                                  "rangeMax": max.map { $0 as Any } ?? NSNull(),
                                  "requiresReinit": type == "bool"]], "value": value, "mod": modified]
        }
        return ["operation": "getUserDefaults:", "value": ["array": [
            row("Boolean", "bool", "1", 1, modified: true),
            row("Integer", "int", 10, 10, min: 0, max: 100),
            row("Float", "float", 1.9, 1.9, min: 0, max: 2),
            row("String", "string", "", ""),
            row("Wide", "int", NSNumber(value: UInt64.max), 0),
            row("Future", "dictionary", ["a": 1], ["a": 1]),
        ]]]
    }
}

/// Only this harness links the debug model to a captured guest connection.
@MainActor
final class VPhoneGuestControl {
    var isConnected = true
    var guestCapabilities = ["homepod_debug", "service_kickstart"]
    var requests: [(String, [String: Any])] = []
    var fails = false

    func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        requests.append((method, params))
        if fails { throw VPhoneHomePodDefaultsError("Restart refused") }
        return ["label": "com.apple.SoundBoard", "pid": 123]
    }
}

@MainActor
private final class DefaultsStore {
    var rows: [[String: Any]]
    var writes: [(String, [String: String])] = []
    var delayedReads = 0
    var ignoresWrites = false
    var failsReadback = false
    private var pending: (String, [String: String])?

    init(reply: [String: Any]) { rows = (reply["value"] as! [String: Any])["array"] as! [[String: Any]] }

    func call(_ operation: String, arguments: [String: String]) async throws -> [String: Any] {
        if operation == "getUserDefaults:" {
            if !writes.isEmpty && failsReadback { throw VPhoneHomePodDefaultsError("Disconnected") }
            if delayedReads > 0 { delayedReads -= 1 }
            else if let (operation, arguments) = pending {
                let index = rows.firstIndex { (($0["info"] as? [String: Any])?["decoded"] as? [String: Any])?["stringForUserDefault"] as? String == arguments["name"] }!
                let metadata = (rows[index]["info"] as! [String: Any])["decoded"] as! [String: Any]
                rows[index]["value"] = operation == "resetUserDefault:" ? metadata["defaultValue"] : arguments["value"]
                rows[index]["mod"] = operation != "resetUserDefault:"
                self.pending = nil
            }
            return ["operation": operation, "value": ["array": rows]]
        }
        precondition(operation == "setUserDefaults:withValue:" || operation == "resetUserDefault:")
        writes.append((operation, arguments))
        if !ignoresWrites { pending = (operation, arguments) }
        return ["operation": operation, "submitted": true]
    }
}

private struct DefaultsPreview: View {
    let store: DefaultsStore
    @State private var isPresented = true
    var body: some View {
        Button("Browse HomePod User Defaults") { isPresented = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $isPresented) { VPhoneHomePodDefaultsView(call: store.call) }
    }
}
