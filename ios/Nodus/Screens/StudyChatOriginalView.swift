import NodusKit
import NodusUI
import SwiftUI

/// Questions and study assessments use their actual Desktop records. An exam
/// citation is not a teaching-exam ID and never guesses that other collection.
struct StudyChatOriginalView: View {
    let kind: String
    let id: String
    let session: SpaceSession
    @State private var source: JSONValue?
    @State private var downloaded = false
    @State private var issue: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if let data = source?.objectValue?["data"]?.objectValue {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:20) {
                        if downloaded { Label("Fuente descargada",systemImage:"arrow.down.circle").font(.caption).foregroundStyle(.secondary) }
                        if kind == "question" { StudyChatQuestionContent(question:.object(data),session:session) }
                        else {
                            Text(data["title"]?.stringValue ?? "Examen").font(.title2.bold()).fixedSize(horizontal:false,vertical:true)
                            if let description = data["description"]?.stringValue,!description.isEmpty { CorpusProse(description,accent:session.accent,session:session) }
                            if let duration = data["durationMinutes"]?.intValue { Label("\(duration) minutos",systemImage:"clock").font(.caption) }
                            if let maximum = data["maxAttempts"]?.intValue { Text("Intentos permitidos: \(maximum)").font(.caption) }
                            if let items = data["items"]?.arrayValue {
                                ForEach(Array(items.enumerated()),id:\.offset) { index,item in
                                    if let raw = item.objectValue,let question = raw["question"] {
                                        VStack(alignment:.leading,spacing:12) {
                                            HStack { Text("Pregunta \(index + 1)").font(.headline);Spacer(minLength:0);if let points = raw["points"]?.doubleValue { Text("\(points.formatted()) puntos").font(.caption) } }
                                            StudyChatQuestionContent(question:question,session:session)
                                        }.padding(16).background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:16))
                                    }
                                }
                            }
                        }
                        if kind != "question" {
                            StudyOriginalMetadata(session: session, value: .object(data), excluding: ["title", "description", "durationMinutes", "maxAttempts", "items"])
                        }
                        if let related = source?.objectValue?["related"]?.objectValue {
                            if let rubric = related["rubric"], rubric != .null { StudyOriginalSection(session: session, title: "Rúbrica", value: rubric, field: "rubric") }
                            if let versions = related["versions"] { StudyOriginalSection(session: session, title: "Versiones", value: versions, field: "versions") }
                            if let attempts = related["attempts"] { StudyOriginalSection(session: session, title: "Intentos y respuestas", value: attempts, field: "attempts") }
                        } else if downloaded {
                            Text("Esta descarga conserva la pregunta o examen original. Para incluir sus versiones e intentos, actualiza la descarga cuando Nodus esté conectado.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(20).frame(maxWidth:800,alignment:.leading).frame(maxWidth:.infinity,alignment:.center)
                }
            } else if let issue { CorpusOpenFailure(message:issue) { attempt += 1 } }
            else { ProgressView().tint(session.accent) }
        }.navigationTitle(kind == "question" ? "Pregunta":"Examen de estudio").navigationBarTitleDisplayMode(.inline)
            .nodusPageBackdrop(accent:session.accent)
            .nodusReadingStyle(ReadingStyle(document: true))
            .nodusPageFunctions(accent: session.accent)
            .task(id:attempt) {
                issue = nil
                do { let (value,offline) = try await CompanionStudyChatSources.original(kind:kind,id:id,session:session);try Task.checkCancellation();source = value;downloaded = offline }
                catch where error.isCancellation {}
                catch { issue = error.localizedDescription }
            }
    }
}

struct StudyChatQuestionContent: View {
    let question: JSONValue
    let session: SpaceSession
    var body: some View {
        if let raw = question.objectValue {
            VStack(alignment:.leading,spacing:12) {
                if let prompt = raw["prompt"]?.stringValue { CorpusProse(prompt,accent:session.accent,session:session) }
                if let options = raw["options"]?.arrayValue,!options.isEmpty {
                    ForEach(Array(options.enumerated()),id:\.offset) { index,option in
                        if let value = option.objectValue,let text = value["text"]?.stringValue {
                            VStack(alignment:.leading,spacing:6) {
                                HStack(alignment:.top) {
                                    Text("\(index + 1).").foregroundStyle(.secondary)
                                    CorpusProse(text,accent:session.accent,session:session)
                                    if value["correct"] == .bool(true) { Image(systemName:"checkmark.circle.fill").foregroundStyle(session.accent).accessibilityLabel("Respuesta correcta") }
                                }
                                if let feedback = value["feedback"]?.stringValue,!feedback.isEmpty { CorpusProse(feedback,accent:session.accent,session:session) }
                            }.padding(12).background(Color(uiColor:.tertiarySystemBackground),in:RoundedRectangle(cornerRadius:12))
                        }
                    }
                }
                if let answer = raw["answer"]?.objectValue {
                    let text = Self.answerText(answer)
                    if !text.isEmpty { Text("Respuesta").font(.headline);CorpusProse(text,accent:session.accent,session:session) }
                }
                if let explanation = raw["explanation"]?.stringValue,!explanation.isEmpty { Text("Explicación").font(.headline);CorpusProse(explanation,accent:session.accent,session:session) }
                if let competence = raw["competence"]?.stringValue,!competence.isEmpty { Text("Competencia").font(.headline);Text(verbatim:competence).textSelection(.enabled) }
                if let source = raw["source"]?.objectValue { StudyOriginalProvenance(session: session, question: raw, source: source) }
                if let rubric = raw["rubric"], rubric.objectValue?.isEmpty == false { StudyOriginalSection(session: session, title: "Criterios de evaluación", value: rubric, field: "rubric") }
                StudyOriginalMetadata(session: session, value: question, excluding: ["prompt", "options", "answer", "explanation", "competence", "source", "rubric"])
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    static func answerText(_ answer: [String:JSONValue]) -> String {
        var pieces: [String] = []
        if let text = answer["text"]?.stringValue,!text.isEmpty { pieces.append(text) }
        if let value = answer["value"] {
            if case .bool(let bool) = value { pieces.append(bool ? "Verdadero":"Falso") }
            else if let text = value.stringValue { pieces.append(text) }
            else if let values = value.arrayValue { pieces.append(values.compactMap(\.stringValue).joined(separator:"\n")) }
        }
        if let items = answer["items"]?.arrayValue { pieces.append(items.compactMap(\.stringValue).joined(separator:"\n")) }
        if let pairs = answer["pairs"]?.arrayValue { pieces.append(pairs.compactMap { pair in guard let values = pair.arrayValue,values.count == 2,let left = values[0].stringValue,let right = values[1].stringValue else { return nil };return "\(left) → \(right)" }.joined(separator:"\n")) }
        return pieces.filter { !$0.isEmpty }.joined(separator:"\n\n")
    }
}
