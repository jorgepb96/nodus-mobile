import NodusUI
import SwiftUI

/// The button that floats over a long screen, and the wheel it opens.
///
/// It used to be one button that did one thing: back to top. That is still the first thing it
/// does, but a screen you have to scroll for a minute is also a screen you want to *search*, and
/// there was nowhere to put a second control — a page already carries a header, a tab bar and,
/// on a report, five buttons of its own. So the one floating button became a hub: press it and
/// its functions fan out around it on an arc, press one and it does that and folds away.
///
/// Two pieces, because `ScrollViewProxy` can only reach a view that is inside the scroll view:
/// the screen marks its first element with `nodusTopAnchor()`, and the scrollable itself takes
/// `nodusPageFunctions(accent:)`, which wraps it in a reader and floats the hub over it.
///
/// What the hub offers depends on what the page can honestly do. "Back to top" appears once the
/// screen has actually been scrolled — a corpus of nine thousand ideas needs it, an empty state
/// does not — and "find" appears only where prose has registered itself with `PageSearch`, which
/// is reports and immersions rather than lists of rows. With one function it is simply that
/// button, exactly as before; with two it is a wheel. The scroll measurement is iOS 18's
/// `onScrollGeometryChange`; before 18 the button is simply always there, which is the honest
/// degradation: still useful, just not as quiet.
enum NodusScrollAnchor: Hashable {
    case top
}

extension View {
    /// Marks the first element of a scrollable as the place "back to top" goes.
    func nodusTopAnchor() -> some View {
        id(NodusScrollAnchor.top)
    }

    /// Floats the page's function hub over a scrollable that carries a `nodusTopAnchor()`.
    ///
    /// `chat` is what the third seat opens onto. A page that has a document worth asking about
    /// passes one; everywhere else the petal is drawn dimmed and does nothing, which is the
    /// truth about it.
    func nodusPageFunctions(accent: Color, chat: PageChatSubject? = nil) -> some View {
        modifier(PageFunctionsModifier(accent: accent, chat: chat))
    }

    /// The mark a passage wears for a moment while an answer points at it.
    ///
    /// Not a selection — nothing is being acted on, and a mark that stayed would be one more
    /// thing to dismiss. The same yellow the find bar uses, because "the app is showing you
    /// where" should look the same wherever it happens.
    func nodusRevealed(_ isRevealed: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.nodusFindMatch.opacity(isRevealed ? 0.6 : 0))
                .padding(.horizontal, -7)
                .padding(.vertical, -5)
        }
        .animation(NodusMotion.standard, value: isRevealed)
    }
}

/// The same anchor, shaped as a list row.
///
/// A `List` gives every row a minimum height and its own insets, so the plain modifier would
/// leave a visible gap above the first entry. This one takes no space at all.
struct NodusTopAnchorRow: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .nodusTopAnchor()
    }
}

/// One thing the hub can do.
enum PageFunction: Hashable, Identifiable {
    case top
    case find
    /// Asking about the page you are reading. The petal is here and the function is not: it is
    /// drawn dimmed and does nothing, because a hub that hides its third seat until the day it
    /// is filled teaches the wheel twice.
    case chat

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .top: return "chevron.up"
        case .find: return "magnifyingglass"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .top: return "Back to top"
        case .find: return "Find on this page"
        case .chat: return "Ask about this page"
        }
    }
}

private struct PageFunctionsModifier: ViewModifier {
    let accent: Color
    /// The document this page is, when it is one worth asking about.
    let chat: PageChatSubject?

    @Environment(AppPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nodusHasTabBar) private var hasTabBar
    /// Optional on purpose. Every long scrollable in the app is inside a `SpaceShell`, which
    /// provides one — but a non-optional `@Environment` for an `@Observable` is a crash when it
    /// is missing, and a "back to top" button is not worth taking a screen down for.
    @Environment(NodusChrome.self) private var chrome: NodusChrome?
    /// One per page, and it belongs here rather than to the screen: a report and the dossier
    /// pushed on top of it are two pages, and each searches itself.
    @State private var search = PageSearch()
    @State private var isScrolled = false
    @State private var isWheelOpen = false
    @State private var isChatOpen = false
    /// How much room the find bar is taking at the bottom, measured rather than guessed.
    @State private var findBarHeight: CGFloat = 0

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            measured(content)
                .environment(search)
                // An inset rather than an overlay: the bar has to move with the keyboard, and
                // the last paragraph of a report has to stay readable while it is on screen.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if search.isOpen {
                        PageFindBar(search: search, accent: accent)
                            // The hub floats over the whole page, safe area and all, so it has
                            // to be told how tall the bar is or it sits on top of it — which is
                            // precisely where the bar's own close button is.
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.onAppear { findBarHeight = geometry.size.height }
                                }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .overlay {
                    if isWheelOpen {
                        // Anywhere else on the page folds the wheel away, which is what every
                        // other thing that fans out of a button does.
                        Color.black.opacity(0.06)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { isWheelOpen = false }
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) { hub(proxy) }
                // A hub that goes away — the page scrolled back to the top of a list — would
                // otherwise leave its scrim over the page with nothing to close it.
                .onChange(of: showsHub) { _, shown in
                    if !shown { isWheelOpen = false }
                }
                .animation(NodusMotion.quick, value: isScrolled)
                .animation(NodusMotion.standard, value: search.isOpen)
                .animation(NodusMotion.morph, value: isWheelOpen)
                // Walking the matches is the only thing that scrolls the page for the reader,
                // and it happens here because this is where the proxy is.
                //
                // Except where the block can do better. An anchor is one point per block, which
                // is the right unit for a heading or a line of a list and the wrong one for a
                // paragraph of a report: two matches in the same paragraph are the same anchor,
                // so walking onto the second moved nothing, and a paragraph taller than the
                // screen centres with the word anywhere at all — including off it. A paragraph
                // of prose therefore says so at registration and puts the word on the screen
                // itself; the page stays out of its way rather than scrolling twice.
                .onChange(of: search.scrollTarget) { _, target in
                    guard let target, !search.placesItsOwnMatches(target.path) else { return }
                    scroll(proxy, to: PageSearchAnchor(path: target.path), anchor: .center)
                }
                .nodusSheet(isPresented: $isChatOpen) {
                    if let chat {
                        PageChatSheet(
                            subject: chat,
                            passages: chatPassages,
                            accent: accent,
                            // The sheet has closed by the time this runs: the whole point of
                            // tapping a reference is to see the paragraph it names.
                            onReveal: { passage in search.reveal(passage.path) }
                        )
                    }
                }
                // Every scrollable in the shell reports its position, including the ones on
                // pushed screens — where the header is not even on screen. Scrolling a dossier
                // therefore collapsed the header of the tab root behind it, and popping back
                // landed on a page at the top wearing a collapsed header, which reads as a bug
                // because it is one. A screen that goes away stops speaking for the chrome.
                .onDisappear { chrome?.setScrolled(false) }
        }
    }

    /// The hub. Always the same neutral button: what it opens onto changes, what you press to
    /// open it does not.
    @ViewBuilder
    private func hub(_ proxy: ScrollViewProxy) -> some View {
        if showsHub {
            PageFunctionWheel(
                functions: available,
                disabled: unbuilt,
                accent: accent,
                isOpen: $isWheelOpen
            ) { function in
                perform(function, proxy)
            }
            .padding(.trailing, NodusSpace.page)
            // Clear of the bottom bar where there is one, and low where there is not. It used
            // to need 76 to clear the system's floating tab bar, which overlaps content and
            // takes the touches landing on it. The bar the app draws now goes in a
            // `safeAreaInset`, so it is not floating over anything and the button only has to
            // sit above the bar's own height.
            .padding(.bottom, (hasTabBar ? 62 : 22) + (search.isOpen ? findBarHeight : 0))
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    /// What fans out of the hub, from straight up round to the left.
    ///
    /// The preference covers "back to top" alone, because that is the button it was written for.
    /// Switching it off on a screen with prose on it leaves the search, which is a different
    /// promise and one nobody asked to be rid of.
    private var available: [PageFunction] {
        var functions: [PageFunction] = []
        if preferences.showsScrollToTop { functions.append(.top) }
        if search.hasContent, !search.isOpen { functions.append(.find) }
        functions.append(.chat)
        return functions
    }

    /// The seats that are reserved rather than built on this page.
    private var unbuilt: Set<PageFunction> {
        chat == nil ? [.chat] : []
    }

    /// Everything the page is showing, numbered for an answer to point at.
    private var chatPassages: [PageChatPassage] {
        search.passages().enumerated().map { index, entry in
            PageChatPassage(number: index + 1, path: entry.path, text: entry.text)
        }
    }

    /// Whether the hub is on the screen at all.
    ///
    /// Once the page has been scrolled — the rule the single button always followed — or as soon
    /// as there is prose to search, which is worth offering from the first line rather than from
    /// the second screenful. A page with neither has nothing to open the wheel for.
    private var showsHub: Bool {
        guard available.contains(where: { !unbuilt.contains($0) }) else { return false }
        return isScrolled || search.hasContent
    }

    private func perform(_ function: PageFunction, _ proxy: ScrollViewProxy) {
        isWheelOpen = false
        switch function {
        case .top:
            goToTop(proxy)
        case .find:
            search.open()
        case .chat:
            guard chat != nil else { return }
            search.close()
            isChatOpen = true
        }
    }

    /// Back to the top, and a second attempt a beat later.
    ///
    /// A scroll view that is still decelerating overrides a programmatic scroll with its own
    /// momentum: the tap registers, the animation starts, the flick wins, and the button looks
    /// broken precisely when it is most wanted — while the list is still moving. The touch
    /// never reaches the scroll view to stop it, because the button is an overlay *beside* the
    /// scroll view rather than inside it. So the request is made again once the momentum has
    /// had time to be overridden; if the first one landed, the second is a no-op.
    private func goToTop(_ proxy: ScrollViewProxy) {
        scroll(proxy, to: NodusScrollAnchor.top, anchor: .top)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            proxy.scrollTo(NodusScrollAnchor.top, anchor: .top)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: some Hashable, anchor: UnitPoint) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: anchor)
        } else {
            withAnimation(NodusMotion.deliberate) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    /// One measurement, two answers.
    ///
    /// The header wants to know whether the page has moved at all — that is a line or two, and
    /// it wants to know immediately. The button wants to know whether scrolling back would be a
    /// chore, which is about a screen's worth. Both come out of the same geometry callback,
    /// because adding a second one to every scroll view in the app would be paying twice for a
    /// number the system already handed over.
    ///
    /// The header's answer is given as *two* thresholds rather than one, and that is the whole
    /// of why the page no longer shakes. Collapsing the header takes seven points off the top
    /// inset, and a scroll view keeps its offset when its inset changes — so the same gesture
    /// that crossed a single threshold going down immediately crossed it again coming back:
    /// collapse, seven points of slack, expand, seven points back, collapse. At rest that is a
    /// flicker; at the bottom of a page, where the rubber band is already returning the content,
    /// it is a page that bounces and a title that slides left and right as the record count
    /// appears and disappears under it. The band between the two thresholds is twenty points —
    /// comfortably more than the seven the collapse itself moves — so nothing the header does
    /// can undo the reading that produced it.
    @ViewBuilder
    private func measured(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Thresholds.self) { geometry in
                // Measured from where the content rests, not from the raw offset: a scroll view
                // under a hundred-point header sits at −100 when it has not been touched, so
                // `contentOffset.y > 16` meant "scrolled past a hundred and sixteen points" on
                // one screen and something else on the next.
                let travelled = geometry.contentOffset.y + geometry.contentInsets.top
                return Thresholds(
                    // Past the top by more than a rubber-band wobble.
                    beyondCollapse: travelled > 24,
                    beyondReturn: travelled > 4,
                    far: travelled > geometry.containerSize.height * 0.75
                )
            } action: { _, crossed in
                isScrolled = crossed.far
                if crossed.beyondCollapse {
                    chrome?.setScrolled(true)
                } else if !crossed.beyondReturn {
                    chrome?.setScrolled(false)
                }
            }
        } else {
            content.onAppear { isScrolled = true }
        }
    }

    private struct Thresholds: Equatable {
        /// Far enough down that the header should give up its second line.
        let beyondCollapse: Bool
        /// Still far enough down that it should stay given up.
        let beyondReturn: Bool
        let far: Bool
    }
}

// MARK: - The wheel

/// The hub and the functions that fan out of it.
///
/// The hub itself says nothing about what it will offer — an ellipsis, the same on every screen —
/// and that is deliberate: a button that is a magnifying glass on one page and a chevron on the
/// next has to be read before it can be pressed, and this one is always in the same place doing
/// the same thing. What it opens onto is what changes.
///
/// It keeps the geometry of the button it replaced: a 36-point circle inside a 44-point target.
/// The circle used to *be* 44 and drawn in the prominent material with a glow under it, which on
/// a page of quiet cards made the one thing that only scrolls the loudest object on the screen.
/// The thumb still gets its 44; the eye gets a good deal less.
///
/// Pressing it throws the functions out along a quarter turn — straight up, and round to the
/// left — which is where a thumb resting on that corner already sweeps. Pressing one runs it and
/// folds the rest away.
private struct PageFunctionWheel: View {
    let functions: [PageFunction]
    /// Seats that are drawn but do nothing on this page.
    let disabled: Set<PageFunction>
    let accent: Color
    @Binding var isOpen: Bool
    let choose: (PageFunction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Far enough out that a petal clears the hub and a thumb can tell them apart.
    private static let radius: CGFloat = 68

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ForEach(Array(functions.enumerated()), id: \.element) { index, function in
                circle(function.systemImage, label: Text(function.label)) { choose(function) }
                    .disabled(disabled.contains(function))
                    // A seat that is reserved rather than built says so by being dim, which is
                    // the only honest thing a control that does nothing can do.
                    .opacity(disabled.contains(function) ? 0.45 : 1)
                    .offset(isOpen ? offset(index) : .zero)
                    .opacity(isOpen ? 1 : 0)
                    .scaleEffect(isOpen ? 1 : 0.5)
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)
                    .animation(petalMotion(index), value: isOpen)
            }
            circle(
                isOpen ? "xmark" : "ellipsis",
                label: isOpen ? Text("Close the page tools") : Text("Page tools")
            ) {
                isOpen.toggle()
            }
        }
        // The petals are drawn outside a 44-point hub, so the container is given the room they
        // actually occupy rather than being trusted to hit-test past its own edge.
        .frame(width: Self.radius + 44, height: Self.radius + 44, alignment: .bottomTrailing)
    }

    private func circle(_ systemImage: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .nodusGlass(NodusGlass(.regular, tint: accent, interactive: true), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .tint(accent)
        .accessibilityLabel(label)
    }

    /// A quarter turn, from straight up round to straight left.
    private func offset(_ index: Int) -> CGSize {
        let count = functions.count
        let fraction = count > 1 ? Double(index) / Double(count - 1) : 0.5
        let radians = (90 + fraction * 90) * .pi / 180
        return CGSize(width: cos(radians) * Self.radius, height: -sin(radians) * Self.radius)
    }

    /// Staggered, so the wheel unfolds rather than appearing. Not staggered under Reduce Motion,
    /// where a thing arriving in pieces is exactly what was asked to stop.
    private func petalMotion(_ index: Int) -> Animation {
        guard !reduceMotion else { return NodusMotion.quick }
        return NodusMotion.morph.delay(Double(index) * 0.045)
    }
}

// MARK: - The find bar

/// Find-in-page, drawn where a browser draws it: at the bottom, above the keyboard.
///
/// The count is the whole of the feedback — "3/12" says both that the word is on the page and how
/// much of it is still ahead — so it is set in monospaced figures that do not shuffle as the
/// numbers change, and it reads "0/0" rather than disappearing when there is nothing, because a
/// search that finds nothing has to say so.
private struct PageFindBar: View {
    @Bindable var search: PageSearch
    let accent: Color

    @FocusState private var focused: Bool

    private var count: Int { search.matches.count }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(accent.nodusReadable)

            TextField(
                "",
                text: $search.query,
                prompt: Text("Find on this page").foregroundColor(.nodusTertiaryText)
            )
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .focused($focused)
            .onSubmit { search.next() }

            Text(verbatim: "\(count == 0 ? 0 : search.activeIndex + 1)/\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(count == 0 ? Color.nodusTertiaryText : Color.nodusSecondaryText)
                .accessibilityLabel(count == 0 ? Text("No matches") : Text("Match \(search.activeIndex + 1) of \(count)"))

            step("chevron.up", label: "Previous match") { search.previous() }
            step("chevron.down", label: "Next match") { search.next() }
            step("xmark", label: "Close the search", enabled: true) {
                focused = false
                search.close()
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .nodusGlass(NodusGlass(.prominent, tint: accent), in: Capsule())
        .padding(.horizontal, NodusSpace.page)
        .padding(.bottom, 8)
        .onAppear { focused = true }
    }

    private func step(
        _ systemImage: String,
        label: LocalizedStringKey,
        enabled: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let live = enabled ?? (count > 0)
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(live ? accent.nodusReadable : Color.nodusTertiaryText)
        .disabled(!live)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Text that can be found

/// A line of text that takes part in the page's find bar.
///
/// It behaves like `Text` for everything the caller cares about — `.font`, `.foregroundStyle`
/// and the rest apply exactly as they did — and adds the two things `Text` cannot do on its own:
/// it tells the page what words are on it, and it paints the matches when they are looked for.
///
/// On a screen with no `PageSearch` in the environment it is a `Text` and nothing else, so it
/// costs a sheet or a widget nothing to use one.
struct PageText: View {
    let text: String
    let order: Int

    @Environment(PageSearch.self) private var search: PageSearch?
    @Environment(\.nodusSearchPath) private var basePath

    init(_ text: String, order: Int) {
        self.text = text
        self.order = order
    }

    private var path: PageSearch.Path { basePath + [order] }

    var body: some View {
        Text(highlighted)
            .nodusRevealed(search?.revealed == path)
            .id(PageSearchAnchor(path: path))
            .onAppear { search?.register(path, text: text) }
            .onChange(of: text) { _, latest in search?.register(path, text: latest) }
            .onDisappear { search?.unregister(path) }
    }

    private var highlighted: AttributedString {
        var attributed = AttributedString(text)
        guard let highlights = search?.highlights(for: path) else { return attributed }
        attributed.nodusHighlight(highlights, in: text)
        return attributed
    }
}

extension AttributedString {
    /// Paints a block's matches, the active one louder than the rest.
    ///
    /// The ranges arrive as `NSRange`s over the plain string the block registered, which counts
    /// UTF-16; an `AttributedString` counts characters. Going through the `String` is what keeps
    /// a match found after an emoji on the word it was actually found in.
    mutating func nodusHighlight(_ highlights: PageSearch.Highlights, in plain: String) {
        for range in highlights.ranges {
            guard let bounds = Range(range, in: plain) else { continue }
            let start = index(startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: bounds.lowerBound))
            let end = index(startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: bounds.upperBound))
            self[start..<end].backgroundColor = range == highlights.active
                ? Color.nodusFindActive
                : Color.nodusFindMatch
        }
    }
}

extension Color {
    /// Every match on the page, and the one being looked at.
    ///
    /// Not the accent: a report is already accent-tinted from its glass to its citations, and a
    /// highlight drawn in the accent disappears into the page it is meant to stand out from.
    /// These are the two colours every find bar since the first browser has used, dimmed for a
    /// dark page so black text on them stays black text.
    static let nodusFindMatch = nodusDynamic(light: "#fde68a", dark: "#8a6d1f")
    static let nodusFindActive = nodusDynamic(light: "#fb923c", dark: "#c2620d")

    /// Where the reader stopped.
    ///
    /// Deliberately not in the yellows above. A find highlight is a thing happening now and
    /// disappears when the bar closes; a bookmark is still there tomorrow, and two marks in the
    /// same family would have a reader closing the find bar to work out which was which. Green
    /// instead — and quieter than either yellow, because it sits under prose that is being read
    /// rather than scanned. The rule under it is what makes it legible to somebody who cannot
    /// tell the two hues apart at all.
    static let nodusBookmark = nodusDynamic(light: "#bbf7d0", dark: "#2f6b46")
    static let nodusBookmarkRule = nodusDynamic(light: "#15803d", dark: "#6ee7b7")
}
