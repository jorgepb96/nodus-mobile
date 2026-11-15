import NodusAI
import NodusUI
import SwiftUI
import UIKit

/// The same selection-first writing tools the desktop Workspace adds to Milkdown.
///
/// The values are semantic rather than visual: the edit menu owns the SF Symbol used on iOS,
/// while the provider prompt owns the transformation. This keeps emoji out of both layers.
enum WorkspaceAIAction: String, CaseIterable, Identifiable {
    case academic
    case formal
    case clear
    case concise
    case synonyms

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .academic: "Academic"
        case .formal: "Formal"
        case .clear: "Clarify"
        case .concise: "Concise"
        case .synonyms: "AI synonyms"
        }
    }

    var spokenLabel: String {
        switch self {
        case .academic: String(localized: "Academic")
        case .formal: String(localized: "Formal")
        case .clear: String(localized: "Clarify")
        case .concise: String(localized: "Concise")
        case .synonyms: String(localized: "AI synonyms")
        }
    }

    var systemImage: String {
        switch self {
        case .academic: "graduationcap"
        case .formal: "pencil.line"
        case .clear: "lightbulb"
        case .concise: "scissors"
        case .synonyms: "character.book.closed"
        }
    }

    var instruction: String {
        switch self {
        case .academic:
            "Rewrite the selection in a precise academic register with explicit, orderly reasoning."
        case .formal:
            "Raise the formality and correctness of the selection without making it artificial."
        case .clear:
            "Make the selection clearer and easier to follow without simplifying or adding ideas."
        case .concise:
            "Remove redundancy and make the selection concise without losing any claim or fact."
        case .synonyms:
            "Return five context-appropriate alternatives for the selected wording."
        }
    }
}

typealias WorkspaceReplacement = @MainActor (String) -> Void

private struct WorkspaceAIRequest: Identifiable {
    let id = UUID()
    let action: WorkspaceAIAction
    let source: String
    let apply: WorkspaceReplacement
}

private struct WorkspaceSynonymChoices: Identifiable {
    let id = UUID()
    let alternatives: [String]
    let request: WorkspaceAIRequest
}

enum WorkspaceEditorPrompt {
    private struct SynonymPayload: Decodable { let alternatives: [String] }

    static func messages(action: WorkspaceAIAction, selection: String) -> [ChatMessage] {
        let language = Locale.current.identifier
        let system = """
        You edit a selected passage in a professional writing application. Preserve names,
        citations, numbers, Markdown and the language of the source. Never add facts. The
        interface locale is \(language).
        """
        if action == .synonyms {
            return [
                ChatMessage(role: .system, content: system + " Return JSON only: {\"alternatives\":[\"…\"]}. Exactly five distinct strings, with no commentary."),
                ChatMessage(role: .user, content: "Selection in context:\n<<<\(selection)>>>")
            ]
        }
        return [
            ChatMessage(role: .system, content: system + " Return only the replacement text, without quotation marks or a code fence."),
            ChatMessage(role: .user, content: "\(action.instruction)\n\nSelected text:\n<<<\(selection)>>>")
        ]
    }

    static func cleanedReplacement(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            var lines = value.components(separatedBy: .newlines)
            if !lines.isEmpty { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" { lines.removeLast() }
            value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           let first = value.first, let last = value.last,
           (first == "\"" && last == "\"" || first == "“" && last == "”") {
            value.removeFirst(); value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func synonyms(from raw: String) -> [String] {
        let cleaned = cleanedReplacement(raw)
        guard let data = cleaned.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SynonymPayload.self, from: data)
        else { return [] }
        var seen = Set<String>()
        return payload.alternatives.compactMap { candidate in
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.localizedLowercase).inserted else { return nil }
            return value
        }.prefix(5).map { $0 }
    }
}

enum WorkspaceEditorFailure: LocalizedError {
    case missingModel
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .missingModel: String(localized: "Choose a chat model under Providers to use AI writing tools.")
        case .emptyAnswer: String(localized: "The model did not return a usable replacement.")
        }
    }
}

/// A clean editor surface shared by new-note sheets and the published Workspace detail.
/// Selection opens one compact native ribbon; its first group mirrors desktop formatting,
/// followed by the four quick improvements, AI synonyms, colour and heading controls.
struct WorkspaceEditorSurface: View {
    @Environment(AISettings.self) private var ai

    @Binding var text: String
    let accent: Color
    var minHeight: CGFloat = 280

    @State private var isWorking = false
    @State private var failure: String?
    @State private var synonymChoices: WorkspaceSynonymChoices?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WorkspaceSelectionTextView(
                text: $text,
                accent: UIColor(accent),
                minHeight: minHeight,
                onAIRequest: request
            )
            .padding(.horizontal, 4)

            if isWorking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).tint(accent)
                    Text("Improving selection…").font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accent.opacity(0.22), lineWidth: 1))
        .alert("Could not improve the selection", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .sheet(item: $synonymChoices) { choices in
            WorkspaceSynonymSheet(
                alternatives: choices.alternatives,
                accent: accent,
                onChoose: { replacement in
                    choices.request.apply(replacement)
                    synonymChoices = nil
                },
                onRegenerate: {
                    synonymChoices = nil
                    perform(choices.request)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func request(
        _ action: WorkspaceAIAction,
        _ source: String,
        _ apply: @escaping WorkspaceReplacement
    ) {
        guard !isWorking else { return }
        perform(WorkspaceAIRequest(action: action, source: source, apply: apply))
    }

    private func perform(_ request: WorkspaceAIRequest) {
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                try BetaAIFeatures.requireAutonomousGeneration()
                guard let model = ai.model(for: .chat) else { throw WorkspaceEditorFailure.missingModel }
                let provider = ProviderClient(keyProvider: ai.keyProvider)
                let output = try await provider.complete(ChatRequest(
                    model: model,
                    messages: WorkspaceEditorPrompt.messages(action: request.action, selection: request.source),
                    temperature: request.action == .synonyms ? 0.35 : 0.2,
                    maxTokens: request.action == .synonyms ? 500 : 2400,
                    jsonMode: request.action == .synonyms
                ))
                if request.action == .synonyms {
                    let alternatives = WorkspaceEditorPrompt.synonyms(from: output)
                    guard !alternatives.isEmpty else { throw WorkspaceEditorFailure.emptyAnswer }
                    synonymChoices = WorkspaceSynonymChoices(alternatives: alternatives, request: request)
                } else {
                    let replacement = WorkspaceEditorPrompt.cleanedReplacement(output)
                    guard !replacement.isEmpty else { throw WorkspaceEditorFailure.emptyAnswer }
                    request.apply(replacement)
                }
            } catch {
                if case ProviderError.missingKey(let provider) = error { ai.markRejected(provider) }
                if case ProviderError.http(let status, let provider, _) = error, status == 401 || status == 403 {
                    ai.markRejected(provider)
                }
                failure = error.localizedDescription
            }
        }
    }
}

private struct WorkspaceSynonymSheet: View {
    @Environment(\.dismiss) private var dismiss
    let alternatives: [String]
    let accent: Color
    let onChoose: (String) -> Void
    let onRegenerate: () -> Void

    var body: some View {
        NavigationStack {
            List(alternatives, id: \.self) { alternative in
                Button {
                    onChoose(alternative)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                            .frame(width: 28, height: 28).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        Text(alternative).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.turn.down.left").font(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Synonyms and rephrasings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Regenerate alternatives")
                }
            }
            .tint(accent)
        }
    }
}

private struct WorkspaceSelectionTextView: UIViewRepresentable {
    @Binding var text: String
    let accent: UIColor
    let minHeight: CGFloat
    let onAIRequest: (WorkspaceAIAction, String, @escaping WorkspaceReplacement) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.isEditable = true
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.textContainer.lineFragmentPadding = 0
        view.keyboardDismissMode = .interactive
        view.tintColor = accent
        view.text = text
        view.accessibilityLabel = String(localized: "Content")
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.tintColor = accent
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(minHeight, measured.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: WorkspaceSelectionTextView

        init(parent: WorkspaceSelectionTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0,
                  NSMaxRange(range) <= (textView.text as NSString).length
            else { return UIMenu(children: suggestedActions) }

            let selection = (textView.text as NSString).substring(with: range)
            let formatting = UIMenu(
                title: "",
                options: .displayInline,
                preferredElementSize: .small,
                children: [
                    wrapAction(String(localized: "Bold"), "bold", prefix: "**", suffix: "**", range: range, in: textView),
                    wrapAction(String(localized: "Italic"), "italic", prefix: "*", suffix: "*", range: range, in: textView),
                    wrapAction(String(localized: "Strikethrough"), "strikethrough", prefix: "~~", suffix: "~~", range: range, in: textView),
                    wrapAction(String(localized: "Inline code"), "chevron.left.forwardslash.chevron.right", prefix: "`", suffix: "`", range: range, in: textView),
                    wrapAction(String(localized: "Formula"), "sum", prefix: "$", suffix: "$", range: range, in: textView),
                    linkAction(range: range, in: textView),
                ]
            )

            let improvements = UIMenu(
                title: "",
                options: .displayInline,
                preferredElementSize: .small,
                children: WorkspaceAIAction.allCases.map { action in
                    let image = UIImage(systemName: action.systemImage)
                    image?.accessibilityLabel = action.spokenLabel
                    let item = UIAction(title: "", image: image) { [weak self, weak textView] _ in
                        guard let self, let textView else { return }
                        self.parent.onAIRequest(action, selection) { [weak self, weak textView] replacement in
                            guard let self, let textView,
                                  NSMaxRange(range) <= (textView.text as NSString).length,
                                  (textView.text as NSString).substring(with: range) == selection
                            else { return }
                            self.replace(range, with: replacement, selecting: nil, in: textView)
                        }
                    }
                    item.accessibilityLabel = action.spokenLabel
                    return item
                }
            )

            let colours = UIMenu(
                title: String(localized: "Text color"),
                image: UIImage(systemName: "paintpalette"),
                children: colourActions(range: range, in: textView)
            )
            colours.accessibilityLabel = String(localized: "Text color")

            let headings = UIMenu(
                title: String(localized: "Heading level"),
                image: UIImage(systemName: "textformat.size"),
                children: (0...6).map { level in
                    UIAction(title: level == 0 ? String(localized: "Paragraph") : "H\(level)") { [weak self, weak textView] _ in
                        guard let self, let textView else { return }
                        self.applyHeading(level, range: range, in: textView)
                    }
                }
            )
            headings.accessibilityLabel = String(localized: "Heading level")

            // These selection tools use the retained phone provider, unlike
            // Scriptor's connected Mac assistance. Keep manual formatting here.
            let groups = BetaAIFeatures.autonomousGeneration
                ? [formatting, improvements, colours, headings]
                : [formatting, colours, headings]
            let nodus = UIMenu(title: "", options: .displayInline, children: groups)
            return UIMenu(children: [nodus] + suggestedActions)
        }

        private func wrapAction(
            _ title: String,
            _ image: String,
            prefix: String,
            suffix: String,
            range: NSRange,
            in textView: UITextView
        ) -> UIAction {
            let action = UIAction(title: "", image: UIImage(systemName: image)) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                let source = (textView.text as NSString).substring(with: range)
                self.replace(
                    range,
                    with: prefix + source + suffix,
                    selecting: NSRange(location: range.location + prefix.utf16.count, length: range.length),
                    in: textView
                )
            }
            action.accessibilityLabel = title
            return action
        }

        private func linkAction(range: NSRange, in textView: UITextView) -> UIAction {
            let action = UIAction(title: "", image: UIImage(systemName: "link")) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                let source = (textView.text as NSString).substring(with: range)
                let placeholder = "https://"
                self.replace(
                    range,
                    with: "[\(source)](\(placeholder))",
                    selecting: NSRange(location: range.location + source.utf16.count + 2, length: placeholder.utf16.count),
                    in: textView
                )
            }
            action.accessibilityLabel = String(localized: "Link")
            return action
        }

        private func colourActions(range: NSRange, in textView: UITextView) -> [UIAction] {
            let colours: [(String, String, UIColor)] = [
                (String(localized: "Default"), "inherit", .label),
                (String(localized: "Teal"), "#0f766e", .systemTeal),
                (String(localized: "Blue"), "#2563eb", .systemBlue),
                (String(localized: "Purple"), "#7c3aed", .systemPurple),
                (String(localized: "Red"), "#dc2626", .systemRed),
                (String(localized: "Orange"), "#ea580c", .systemOrange),
            ]
            return colours.map { label, value, colour in
                let image = UIImage(systemName: "circle.fill")?.withTintColor(colour, renderingMode: .alwaysOriginal)
                return UIAction(title: label, image: image) { [weak self, weak textView] _ in
                    guard let self, let textView else { return }
                    let source = (textView.text as NSString).substring(with: range)
                    let replacement = value == "inherit" ? source : "<span style=\"color: \(value)\">\(source)</span>"
                    self.replace(range, with: replacement, selecting: nil, in: textView)
                }
            }
        }

        private func applyHeading(_ level: Int, range: NSRange, in textView: UITextView) {
            let lineRange = (textView.text as NSString).lineRange(for: range)
            let source = (textView.text as NSString).substring(with: lineRange)
            let prefix = level == 0 ? "" : String(repeating: "#", count: level) + " "
            let replacement = source.components(separatedBy: .newlines).map { line in
                let plain = line.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
                return plain.isEmpty ? plain : prefix + plain
            }.joined(separator: "\n")
            replace(lineRange, with: replacement, selecting: nil, in: textView)
        }

        private func replace(
            _ range: NSRange,
            with replacement: String,
            selecting selection: NSRange?,
            in textView: UITextView
        ) {
            guard NSMaxRange(range) <= (textView.text as NSString).length else { return }
            textView.textStorage.replaceCharacters(in: range, with: replacement)
            textView.selectedRange = selection ?? NSRange(location: range.location + replacement.utf16.count, length: 0)
            textViewDidChange(textView)
            textView.becomeFirstResponder()
        }
    }
}
