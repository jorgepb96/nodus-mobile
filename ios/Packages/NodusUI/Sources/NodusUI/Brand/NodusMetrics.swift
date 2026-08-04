import SwiftUI

/// The corner radii the app is drawn to, and the whole of them.
///
/// There were eight: 26 on the header, 22 on a glass panel by default, 18 on a Home tile, 15 on
/// both button styles, 14 on a text field, 11 on an argument block, 10 on a report thumbnail,
/// and a capsule on the search field. Most of those differences were nobody's decision — they
/// were whatever the call site happened to type — and four points of radius is exactly the kind
/// of difference a reader feels as sloppiness without being able to name.
///
/// Three sizes cover everything, and which one applies is decided by what a surface *is* rather
/// than by how big it happens to be: a panel holds content, a control is pressed, and an inner
/// shape sits inside one of the two.
public enum NodusRadius {
    /// Cards, sheets, notices, section bodies — anything that holds other things.
    public static let panel: CGFloat = 20
    /// Buttons, fields, thumbnails, chips that are not capsules.
    public static let control: CGFloat = 14
    /// The one radius that is neither: the chrome's own bottom edge, which follows the screen.
    public static let screenEdge: CGFloat = 26

    public static var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panel, style: .continuous)
    }

    public static var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: control, style: .continuous)
    }
}

/// The grid every screen is laid out on.
///
/// The side margin was 16 on most screens and 20 on the space picker, and the gap between one
/// block of content and the next was whatever the enclosing `VStack` had been given — 10, 12,
/// 14, 16 and 18 all appear. A fixed grid is what lets a reader stop noticing the layout.
public enum NodusSpace {
    /// The page's own side margin. Every screen, one number.
    public static let page: CGFloat = 16
    /// Between two cards that belong to the same list.
    public static let card: CGFloat = 12
    /// Between one conceptual block and the next — a heading and its grid, the passages and the
    /// metadata under them. Deliberately more than twice `card`, because that difference is the
    /// only thing telling a reader where one subject ends.
    public static let block: CGFloat = 26
    /// What a card puts between its edge and its content.
    public static let cardPadding: CGFloat = 15
}

/// One duration and one curve, so an expansion, a tab change and a card appearing all feel like
/// the same app doing them.
///
/// Everything in the app already animated; nothing agreed. 0.2, 0.22, 0.24 and 0.32 second
/// `easeOut`s and a `spring(duration: 0.22)` were all in use, often two of them on one screen.
public enum NodusMotion {
    /// A control acknowledging a touch.
    public static let quick: Animation = .easeOut(duration: 0.18)
    /// The default: a disclosure, a selection, a card arriving.
    public static let standard: Animation = .easeOut(duration: 0.26)
    /// Something with weight — a sheet's content, a scroll returning to the top.
    public static let deliberate: Animation = .easeOut(duration: 0.34)
    /// The one springy thing: a press, where the overshoot reads as give rather than as motion.
    public static let press: Animation = .spring(response: 0.3, dampingFraction: 0.72)
}
