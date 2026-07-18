import SwiftUI

@main
struct HerdrMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel(
        sessions: NativeSessionHTTPClient(),
        credentials: KeychainCredentialStore(),
        configuration: OriginDefaultsStore(),
        liveConnection: NetworkWebSocketConnection()
    )

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    await model.start()
                    model.setSceneActive(scenePhase == .active)
                }
                .onChange(of: scenePhase) { _, phase in
                    model.setSceneActive(phase == .active)
                }
        }
    }
}
