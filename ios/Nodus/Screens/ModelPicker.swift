import NodusAI
import NodusKit
import NodusUI
import SwiftUI

/// One entry in the model list, from whichever provider.
struct ModelOption: Identifiable, Hashable {
    let provider: AIProvider
    let model: String
    var id: String { "\(provider.rawValue)/\(model)" }
    var ref: ModelRef { ModelRef(provider: provider, model: model) }
}

/// Picking a model out of a list that is genuinely long.
///
/// OpenRouter alone publishes several hundred, so the three things that make this usable are a
/// search field, a pinned section, and a stable order. The order is alphabetical by provider
/// and then by model — not "as the API returned them", which is arbitrary and changes between
/// calls, so the same model is in a different place every time you look.
struct ModelPickerView: View {
    @Environment(AISettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let task: AISettings.Task
    let accent: Color

    @State private var options: [ModelOption] = []
    @State private var loading: Set<AIProvider> = []
    @State private var errors: [AIProvider: String] = [:]
    @State private var query = ""

    private var matches: [ModelOption] {
        // The provider's name is searchable alongside the id, so "gemini" finds every Google
        // model even where the id does not repeat the word — and `ModelSearch` is what makes
        // "gemini flash" find `gemini-2.5-flash`, which a plain `contains` never could.
        options.filter { ModelSearch.matches(query: query, candidate: "\($0.model) \($0.provider.label)") }
    }

    private var pinned: [ModelOption] {
        matches.filter { settings.isPinned($0.ref) }
    }

    private var rest: [ModelOption] {
        matches.filter { !settings.isPinned($0.ref) }
    }

    var body: some View {
        List {
            if settings.availableProviders(for: task).isEmpty {
                Section {
                    // A key that cannot serve *this* task is not a missing key, and telling
                    // somebody with a Groq key to add a key would send them to a screen where
                    // everything already looks configured.
                    if task == .image, !settings.configuredProviders.isEmpty {
                        NodusNotice(
                            tone: .caution,
                            title: "No key here can draw",
                            message: "Images need an OpenAI, Google Gemini or OpenRouter key. The ones on this device only answer in words.",
                            systemImage: "photo"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        NodusNotice(
                            tone: .caution,
                            title: "No keys configured",
                            message: "Add a provider's key and its models will appear here.",
                            systemImage: "key"
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }

            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { option in row(option) }
                }
            }

            if !rest.isEmpty {
                Section(pinned.isEmpty ? "Models" : "All") {
                    ForEach(rest) { option in row(option) }
                }
            }

            if !loading.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().tint(accent)
                        Text("Querying \(loading.map(\.label).sorted().joined(separator: ", "))…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !errors.isEmpty {
                Section("Could not be listed") {
                    ForEach(errors.sorted(by: { $0.key.label < $1.key.label }), id: \.key) { provider, message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.label).font(.caption.weight(.medium))
                            Text(message).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if matches.isEmpty, loading.isEmpty, !options.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("No model contains “\(query)”.")
                )
                .listRowBackground(Color.clear)
            }

            // A provider answered, and had nothing to offer for this task. Without this the
            // screen is simply blank, which reads as "still loading" forever.
            if options.isEmpty, loading.isEmpty, errors.isEmpty, !settings.availableProviders(for: task).isEmpty {
                ContentUnavailableView(
                    "Nothing to choose from",
                    systemImage: "square.dashed",
                    description: Text(LocalizedStringKey(
                        task == .image
                            ? "None of the configured providers published an image model."
                            : "None of the configured providers published a model for this task."
                    ))
                )
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(Text(LocalizedStringKey(task.label)))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search model or provider")
        .nodusDismissesKeyboard()
        .task { await loadAll() }
        .refreshable { await loadAll(force: true) }
    }

    private func row(_ option: ModelOption) -> some View {
        let isSelected = settings.model(for: task) == option.ref
        return Button {
            settings.setModel(option.ref, for: task)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.model)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(option.provider.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(accent)
                }
            }
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                settings.togglePinned(option.ref)
            } label: {
                Label(
                    settings.isPinned(option.ref) ? "Remove" : "Pin",
                    systemImage: settings.isPinned(option.ref) ? "star.slash" : "star"
                )
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button {
                settings.togglePinned(option.ref)
            } label: {
                Label(
                    settings.isPinned(option.ref) ? "Unpin" : "Pin",
                    systemImage: settings.isPinned(option.ref) ? "star.slash" : "star"
                )
            }
        }
    }

    private func loadAll(force: Bool = false) async {
        let catalogue = ModelCatalogue(keyProvider: settings.keyProvider)
        if force { await catalogue.invalidate() }

        let providers = settings.availableProviders(for: task)
        errors = [:]
        var collected: [ModelOption] = []

        // Each provider answers on its own, so a slow or broken one does not hold up the rest.
        await withTaskGroup(of: (AIProvider, Result<[String], any Error>).self) { group in
            for provider in providers {
                loading.insert(provider)
                group.addTask {
                    do {
                        // Two different questions, not one question and a filter: what a
                        // provider will draw with is published somewhere other than what it
                        // will talk with, at both OpenRouter and Google.
                        let ids = task == .image
                            ? try await catalogue.imageModels(for: provider)
                            : try await catalogue.models(for: provider)
                        return (provider, .success(ids))
                    } catch {
                        return (provider, .failure(error))
                    }
                }
            }
            for await (provider, result) in group {
                loading.remove(provider)
                switch result {
                case .success(let ids):
                    // The image list arrives already narrowed to what can draw. A chat list
                    // still has to drop the embedding, audio and image models a provider
                    // publishes in the same response as its chat ones.
                    let filtered = task == .image ? ids : ids.filter(RequestShaping.isChatModel)
                    collected.append(contentsOf: filtered.map { ModelOption(provider: provider, model: $0) })
                case .failure(let error):
                    errors[provider] = error.localizedDescription
                }
            }
        }

        // Alphabetical by provider, then by model. Stable between launches, which "as the API
        // returned them" is not.
        options = collected.sorted {
            $0.provider.label == $1.provider.label
                ? $0.model.localizedStandardCompare($1.model) == .orderedAscending
                : $0.provider.label < $1.provider.label
        }
    }
}
