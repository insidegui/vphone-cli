import SwiftUI

struct VPhoneHomePodDebugSection: View {
    @State private var model: VPhoneHomePodDebugModel
    @State private var showsUserDefaults = false

    init(control: VPhoneGuestControl) {
        _model = State(initialValue: VPhoneHomePodDebugModel(control: control))
    }

    var body: some View {
        Section("HomePod") {
            HStack {
                Button("User Defaults…") { showsUserDefaults = true }
                Spacer()
                Button("Restart SoundBoard") { Task { await model.restartSoundBoard() } }
                    .disabled(!model.control.guestCapabilities.contains("service_kickstart"))
            }
            .disabled(model.isBusy || !model.control.isConnected || !model.control.guestCapabilities.contains("homepod_debug"))
            .sheet(isPresented: $showsUserDefaults) {
                VPhoneHomePodDefaultsView { operation, arguments in
                    try await model.control.call("homepod.debug.call", params: ["operation": operation, "arguments": arguments])
                }
            }
            Picker("SoundBoard Debug Control", selection: $model.selectedID) {
                ForEach(model.groups) { group in
                    Section(group.id) {
                        ForEach(group.operations) { operation in
                            Text(verbatim: operation.title).tag(operation.id)
                        }
                    }
                }
            }
            .disabled(model.isBusy || model.operations.isEmpty)
            .onChange(of: model.selectedID) { _, _ in model.resetArguments() }

            if let operation = model.selected {
                VPhoneHomePodDebugOperationEditor(model: model, operation: operation)
                    .disabled(!model.control.guestCapabilities.contains("homepod_debug"))
            }
            if let error = model.error {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !model.result.isEmpty {
                DisclosureGroup("SoundBoard Reply") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: model.result)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 80, maxHeight: 280)
                    HStack {
                        Spacer()
                        Button("Copy Reply") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.result, forType: .string)
                        }
                    }
                }
            }
            HStack {
                Text("Commands without a reply report submission. SoundBoard applies them asynchronously.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Reload Controls") { Task { await model.load() } }
                    .disabled(model.isBusy)
            }
        }
        .task(id: model.control.isConnected && model.control.guestCapabilities.contains("homepod_debug")) {
            await model.load()
        }
    }
}

private struct VPhoneHomePodDebugOperationEditor: View {
    @Bindable var model: VPhoneHomePodDebugModel
    let operation: VPhoneHomePodDebugModel.Operation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: operation.help)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: operation.id)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(operation.arguments) { argument in
                VStack(alignment: .leading, spacing: 4) {
                    if operation.id == "render:" {
                        VPhoneHomePodAnimationEditor(
                            animations: model.animations,
                            phases: model.phases,
                            value: Binding {
                                model.values[argument.name] ?? "{}"
                            } set: { model.values[argument.name] = $0 }
                        )
                    } else {
                        VPhoneHomePodDebugArgumentEditor(
                            argument: argument,
                            value: Binding {
                                model.values[argument.name] ?? ""
                            } set: { model.values[argument.name] = $0 }
                        )
                    }
                }
            }
            if !operation.available {
                Text("This operation's native signature is unavailable on the guest firmware.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(operation.reply == "none" ? "Send Command" : "Read") {
                    Task { await model.execute() }
                }
                .disabled(model.isBusy || !operation.available)
            }
        }
        .disabled(model.isBusy)
    }
}

private struct VPhoneHomePodAnimationEditor: View {
    let animations: [String]
    let phases: [String]
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Animation", selection: selection("animation", fallback: "setup")) {
                ForEach(animations, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Picker("Phase", selection: selection("phase", fallback: "On")) {
                ForEach(phases, id: \.self) { Text(verbatim: $0).tag($0) }
            }
        }
    }

    private func selection(_ key: String, fallback: String) -> Binding<String> {
        Binding {
            (try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String])?[key] ?? fallback
        } set: { newValue in
            var options = (try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String]) ?? [:]
            options[key] = newValue
            if let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]) {
                value = String(decoding: data, as: UTF8.self)
            }
        }
    }
}

private struct VPhoneHomePodDebugArgumentEditor: View {
    let argument: VPhoneHomePodDebugModel.Argument
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if argument.type == "bool" {
                Toggle(argument.name, isOn: Binding {
                    value == "true"
                } set: { value = $0 ? "true" : "false" })
            } else if ["array", "dictionary", "button", "replay"].contains(argument.type) {
                Text(verbatim: argument.name)
                TextEditor(text: $value)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 180)
                    .border(Color(nsColor: .separatorColor))
                    .accessibilityLabel(argument.name)
            } else {
                TextField(argument.name, text: $value)
                    .font(.system(size: 11, design: .monospaced))
            }
            Text(verbatim: argument.help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
