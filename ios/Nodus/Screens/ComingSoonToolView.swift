import NodusUI
import SwiftUI

struct ComingSoonToolView: View {
    let route: NodusRoute
    let accent: Color

    var body: some View {
        let item = NodusNavigationContract.items.first { $0.route == route }
        ContentUnavailableView {
            Label(item?.label ?? "Nodus Tools", systemImage: item?.systemImage ?? "wrench.and.screwdriver")
        } description: {
            Text("Coming soon. This tool is currently available in Nodus Desktop.")
        }
        .tint(accent)
        .accessibilityIdentifier("nodus-coming-soon-\(route.rawValue)")
    }
}
