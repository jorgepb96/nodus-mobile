import NodusKit
import NodusUI
import SwiftUI

/// An exam as the paper it is.
///
/// The desktop's builder composes numbered questions of thirteen types and prints them
/// (`shared/teachingExams.ts`); this reads the same rows back. It is not the printed sheet —
/// there are no ruled answer lines and no logos, because nobody sits an exam on a phone — but
/// it is the exam: every question in its place, with its options, its pairs, its items and its
/// image, and the mark it is worth.
///
/// The one thing it hides by default is the solution. A teacher checking an exam in a corridor
/// wants the paper; the answer key is a tap away and never the first thing on screen.
struct ExamView: View {
    let session: SpaceSession
    let detail: ExamDetail

    @State private var showingSolutions = false

    /// Top-level questions, in the order they are printed.
    ///
    /// A `section` is not a question: it is a shared statement — a source text, a case, a
    /// picture — that several sub-questions hang from, and those carry `parent_id`. Rendering
    /// the flat list would print the passage and its questions as siblings, which is exactly
    /// what the section type exists to avoid.
    private var blocks: [Block] {
        let children = Dictionary(grouping: detail.questions.filter { !parentId($0).isEmpty }) { parentId($0) }
        return detail.questions
            .filter { parentId($0).isEmpty }
            .sorted { position($0) < position($1) }
            .enumerated()
            .map { index, question in
                Block(
                    number: "\(index + 1)",
                    question: question,
                    children: (children[question.string("id") ?? ""] ?? []).sorted { position($0) < position($1) }
                )
            }
    }

    struct Block: Identifiable {
        let number: String
        let question: Row
        let children: [Row]
        var id: String { question.string("id") ?? number }
    }

    private func parentId(_ row: Row) -> String { row.string("parent_id") ?? "" }
    private func position(_ row: Row) -> Int { row.int("position") ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading

                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 12) {
                        question(block.question, number: block.number)
                        ForEach(Array(block.children.enumerated()), id: \.offset) { index, child in
                            question(child, number: "\(block.number).\(index + 1)")
                                .padding(.leading, 14)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(session.accent.opacity(0.35)).frame(width: 2)
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(15)
                    .nodusGlass(NodusGlass(.thin, tint: session.accent))
                }

                if detail.questions.isEmpty {
                    ContentUnavailableView(
                        "No questions",
                        systemImage: "questionmark.square.dashed",
                        description: Text("This exam was published without any question in it.")
                    )
                }
            }
            .padding(16)
            .nodusTopAnchor()
        }
        .nodusScrollToTop(accent: session.accent)
        .nodusHidesBottomBar()
        .navigationTitle(Text(verbatim: detail.exam.text("title") ?? String(localized: "Exam")))
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(NodusMotion.standard) { showingSolutions.toggle() }
                } label: {
                    Image(systemName: showingSolutions ? "key.fill" : "key")
                }
                .tint(session.accent)
                .accessibilityLabel(showingSolutions ? "Hide the answer key" : "Show the answer key")
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: detail.exam.text("title") ?? String(localized: "Exam"))
                .font(.title3.weight(.semibold))
            if let line = subtitleLine {
                Text(verbatim: line).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                chip("\(countedQuestions) questions")
                chip("\(formattedPoints) points")
                if let language = detail.exam.text("language") {
                    chip(LocalizedStringKey(language.uppercased()))
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nodusGlass(NodusGlass(.regular, tint: session.accent))
    }

    /// Sections do not count: they are a statement, and the exam is worth what its questions
    /// are worth — the same rule the total points follow.
    private var countedQuestions: Int {
        detail.questions.filter { ($0.text("type") ?? "") != "section" }.count
    }

    private var formattedPoints: String {
        detail.points == detail.points.rounded()
            ? String(Int(detail.points))
            : String(format: "%.2f", detail.points)
    }

    private var subtitleLine: String? {
        let names = [detail.subject?.text("name"), detail.course?.text("name")].compactMap { $0 }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private func chip(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(session.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(session.accent.opacity(0.14), in: Capsule())
    }

    // MARK: One question

    @ViewBuilder
    private func question(_ row: Row, number: String) -> some View {
        let type = row.text("type") ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: number)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(session.accent)
                Text(verbatim: row.text("prompt") ?? "—")
                    .font(type == "section" ? .subheadline.weight(.semibold) : .subheadline)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if type != "section", let points = row.double("points") {
                    Text(verbatim: points == points.rounded() ? "\(Int(points))" : String(format: "%.2f", points))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let hash = row.text("image_data_url"), hash.hasPrefix("data:image") {
                DataURLImage(dataURL: hash)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let caption = row.text("image_caption") {
                    Text(verbatim: caption).font(.caption2).foregroundStyle(.secondary)
                }
            }

            body(of: row, type: type)

            // A section is a shared statement, not a question — it carries no points and the
            // desktop does not mark it (`examTotalPoints`, shared/teachingExams.ts:290). Giving
            // it an answer key put "See the marking rubric" under a heading that asks nothing.
            if showingSolutions, type != "section", let solution = row.text("solution") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Answer key").font(.caption2.weight(.semibold)).foregroundStyle(session.accent)
                    Text(verbatim: solution).font(.caption).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(session.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the question shows below its prompt, by type. The four that carry structure are
    /// rendered as that structure; everything else is a prompt and a blank sheet, and a blank
    /// sheet has nothing to show on a phone.
    @ViewBuilder
    private func body(of row: Row, type: String) -> some View {
        switch type {
        case "multiple_choice":
            let options = objects(row, "options_json")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let correct = option["correct"]?.boolValue == true
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(verbatim: "\(Self.letter(index)))")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(verbatim: option["text"]?.stringValue ?? "")
                            .font(.callout)
                        if showingSolutions, correct {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(session.accent)
                        }
                    }
                }
            }

        case "true_false":
            HStack(spacing: 14) {
                Text("True").font(.callout)
                Text("False").font(.callout)
            }
            .foregroundStyle(.secondary)

        case "matching":
            let pairs = objects(row, "pairs_json")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(verbatim: "\(index + 1).")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(verbatim: pair["left"]?.stringValue ?? "").font(.callout)
                        Text(verbatim: "—").foregroundStyle(.tertiary)
                        Text(verbatim: "\(Self.letter(index))) \(pair["right"]?.stringValue ?? "")")
                            .font(.callout)
                    }
                }
            }

        case "ordering":
            let items = (row.embeddedJSON("items_json")?.arrayValue ?? []).compactMap(\.stringValue)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "square").font(.caption2).foregroundStyle(.tertiary)
                        Text(verbatim: item).font(.callout)
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    private func objects(_ row: Row, _ column: String) -> [[String: JSONValue]] {
        (row.embeddedJSON(column)?.arrayValue ?? []).compactMap(\.objectValue)
    }

    /// `a)`, `b)`, … past `z` it keeps counting rather than wrapping, which is what
    /// `examOptionLetter` does.
    static func letter(_ index: Int) -> String {
        guard index < 26 else { return String(index + 1) }
        return String(UnicodeScalar(UInt8(97 + index)))
    }
}

/// An image the row carries inline as a `data:` URL.
///
/// Exam questions are the one place a picture travels inside the JSON rather than on the asset
/// channel: the teacher pasted it into the paper, and it is part of the question rather than
/// an attachment to it.
struct DataURLImage: View {
    let dataURL: String

    private var image: UIImage? {
        guard
            let comma = dataURL.firstIndex(of: ","),
            let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]), options: .ignoreUnknownCharacters)
        else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
        }
    }
}
