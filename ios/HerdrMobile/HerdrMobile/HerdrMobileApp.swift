import SwiftUI

@main
struct HerdrMobileApp: App {
    @StateObject private var model = AppModel(
        sessions: NativeSessionHTTPClient(),
        credentials: KeychainCredentialStore(),
        configuration: OriginDefaultsStore()
    )

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    await model.start()
                }
        }
    }
}
