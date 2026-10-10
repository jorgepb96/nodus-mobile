import SwiftUI

/// Desktop's complete Dictionary, backed by the paired vault or its downloaded
/// consultation projection. Navigation and provider credentials stay native.
struct DictionaryWorkspaceView: View {
    let session: SpaceSession

    var body: some View {
        SharedDesktopSurface(session: session, surface: .dictionary)
    }
}
