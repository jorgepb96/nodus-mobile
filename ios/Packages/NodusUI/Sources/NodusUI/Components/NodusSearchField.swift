import SwiftUI

/// The one search field in the app.
///
/// There were three. The Search tab drew this glass capsule by hand; every list used
/// `.searchable`, which on iOS puts a system field in a drawer under the navigation bar and
/// looks nothing like it; and the argument map's seed picker had a third, inline in a list
/// row. Same gesture, three appearances, and two of them out of place on a screen whose whole
/// chrome is glass over an accent backdrop.
///
/// The field deliberately owns no page margin. Some screens place it in a page column while
/// others put it beside compact controls; making the shared field add another page inset made
/// those layouts cramped and, in a few cases, wider than the phone.
public struct NodusSearchField: View {
    @Binding private var text: String
    private let prompt: LocalizedStringKey
    private let accent: Color
    /// Raises the leading glyph into a working state — a search that is out, not just typed.
    private let isBusy: Bool

    @FocusState private var focused: Bool

    public init(
        text: Binding<String>,
        prompt: LocalizedStringKey,
        accent: Color,
        isBusy: Bool = false
    ) {
        _text = text
        self.prompt = prompt
        self.accent = accent
        self.isBusy = isBusy
    }

    /// The placeholder, said loudly enough to be read.
    ///
    /// A `TextField`'s own prompt is drawn in `placeholderText`, which is the label colour at
    /// about a quarter — tuned for a white field, and over tinted glass on an accent bloom it
    /// was the faintest thing on the screen. Handing `prompt:` a styled `Text` is the only way
    /// to say otherwise: the string parameter has no colour to give.
    private var placeholder: Text {
        Text(prompt).foregroundColor(.nodusTertiaryText)
    }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isBusy ? "ellipsis" : "magnifyingglass")
                .font(.callout.weight(.medium))
                // The accent, walked until it reads. A `#6366f1` glyph on a pale violet capsule
                // is the same violet twice.
                .foregroundStyle(accent.nodusReadable)
                .symbolEffect(.variableColor, isActive: isBusy)

            // `textInputAutocapitalization` and `submitLabel` are UIKit-only, and this package
            // builds for macOS as well so its rules can be unit-tested without a simulator.
            #if os(iOS)
            TextField("", text: $text, prompt: placeholder)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($focused)
                .accessibilityIdentifier("nodus-search-field")
            #else
            TextField("", text: $text, prompt: placeholder)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($focused)
                .accessibilityIdentifier("nodus-search-field")
            #endif

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.nodusTertiaryText)
                        // A 17-point glyph is not a target. The same lesson the header
                        // buttons taught, applied before anybody has to report it.
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, text.isEmpty ? 13 : 5)
        .padding(.vertical, 10)
        // Not `interactive`, deliberately. The field is a place to type, not a control that
        // lights up: with the lit edge on it, its bright accent outline was the strongest line
        // on a screen whose subject is the list underneath.
        .nodusGlass(NodusGlass(.regular, tint: accent), in: Capsule())
    }
}
