import SwiftUI

struct VPhoneHomePodDefaultsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: VPhoneHomePodDefaultsModel
    @State private var confirmsDiscard = false

    init(call: @escaping VPhoneHomePodDefaultsModel.Call) {
        _model = State(initialValue: VPhoneHomePodDefaultsModel(call: call))
    }

    var body: some View {
        VStack(spacing: 0) {
            VPhoneHomePodDefaultsToolbar(model: model)
            Divider()
            HSplitView {
                VPhoneHomePodDefaultsList(model: model)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 400)
                if let entry = model.selected {
                    VPhoneHomePodDefaultEditor(model: model, entry: entry)
                        .id(entry.id)
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(model.hasLoaded ? "No Matching Defaults" : "User Defaults",
                                           systemImage: "slider.horizontal.3",
                                           description: Text(model.hasLoaded ? "Change the search or filter to browse other defaults." : "Reading defaults from SoundBoard…"))
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            VPhoneHomePodDefaultsFooter(model: model) {
                if model.pendingCount > 0 { confirmsDiscard = true }
                else { dismiss() }
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 500, idealHeight: 600)
        .interactiveDismissDisabled(model.isBusy || model.pendingCount > 0)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .task { await model.load() }
    }
}

private struct VPhoneHomePodDefaultsToolbar: View {
    @Bindable var model: VPhoneHomePodDefaultsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HomePod User Defaults").font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isBusy)
                    .help("Read current values and metadata. Unsaved edits are preserved.")
            }
            HStack(spacing: 16) {
                TextField("Search names and descriptions", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Overrides Only", isOn: $model.overridesOnly)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(16)
    }
}

private struct VPhoneHomePodDefaultsList: View {
    @Bindable var model: VPhoneHomePodDefaultsModel

    var body: some View {
        List(selection: $model.selectedID) {
            ForEach(model.visibleEntries) { entry in
                VPhoneHomePodDefaultRow(name: entry.id, value: entry.currentValue,
                                       isModified: entry.isModified, hasDraft: model.drafts[entry.id] != nil)
                    .tag(entry.id)
            }
        }
        .overlay {
            if !model.hasLoaded && model.isBusy { ProgressView() }
        }
        .accessibilityLabel("HomePod user defaults")
    }
}

private struct VPhoneHomePodDefaultRow: View {
    let name: String
    let value: String
    let isModified: Bool
    let hasDraft: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(value.isEmpty ? "\"\"" : value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if hasDraft { Text("Edited") }
                else if isModified { Text("Override") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct VPhoneHomePodDefaultEditor: View {
    @Bindable var model: VPhoneHomePodDefaultsModel
    let entry: VPhoneHomePodUserDefault

    var body: some View {
        Form {
            Section {
                Text(verbatim: entry.id)
                    .font(.system(.headline, design: .monospaced))
                    .textSelection(.enabled)
                Text(verbatim: entry.description)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if entry.requiresReinit {
                    Label("Requires reinitialization; restart SoundBoard after applying this change.", systemImage: "arrow.clockwise")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Value") {
                VPhoneHomePodDefaultValueEditor(entry: entry, value: Binding {
                    model.text(for: entry)
                } set: { model.edit(entry, text: $0) })
                if let error = model.validationError(for: entry) {
                    Text(verbatim: error).font(.callout).foregroundStyle(.red)
                }
                HStack {
                    Button("Save") { Task { await model.save(entry) } }
                        .disabled(model.drafts[entry.id] == nil || model.validationError(for: entry) != nil)
                    Button("Discard Edit") { model.discard(entry) }
                        .disabled(model.drafts[entry.id] == nil)
                    Spacer()
                    Button("Reset to Default") { Task { await model.reset(entry) } }
                        .disabled(!entry.isModified)
                        .help("Remove this setting's override in SoundBoard.")
                }
            }
            Section("Metadata") {
                LabeledContent("Type") { Text(verbatim: entry.nativeType) }
                LabeledContent("Current Value") { Text(verbatim: display(entry.currentValue)) }
                LabeledContent("Default Value") { Text(verbatim: display(entry.defaultValue)) }
                if let minimum = entry.rangeMin {
                    LabeledContent("Minimum") { Text(verbatim: String(describing: minimum)) }
                }
                if let maximum = entry.rangeMax {
                    LabeledContent("Maximum") { Text(verbatim: String(describing: maximum)) }
                }
                LabeledContent("Stored Override") {
                    if entry.isModified { Text("Yes") } else { Text("No") }
                }
            }
            .textSelection(.enabled)
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
    }

    private func display(_ value: String) -> String { value.isEmpty ? "\"\"" : value }
}

private struct VPhoneHomePodDefaultValueEditor: View {
    let entry: VPhoneHomePodUserDefault
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading) {
            switch entry.kind {
            case .bool:
                Toggle("Enabled", isOn: Binding { value == "1" } set: { value = $0 ? "1" : "0" })
            case .int, .float:
                TextField("Value", text: $value)
                    .font(.system(.body, design: .monospaced))
            case .string:
                TextField("Value", text: $value, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(.body, design: .monospaced))
            case .unsupported:
                Text(verbatim: value).textSelection(.enabled)
                Text("This value type is available for browsing only.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct VPhoneHomePodDefaultsFooter: View {
    let model: VPhoneHomePodDefaultsModel
    let done: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.visibleEntries.count) of \(model.entries.count) defaults · \(model.pendingCount) unsaved changes")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.error {
                    Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
                } else if let status = model.status {
                    Text(verbatim: status).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            Button("Done", action: done)
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
        }
        .padding(16)
    }
}
