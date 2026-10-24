import SwiftUI

@main
struct MeshMapperApp: App {
    @StateObject private var model = MeshModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { model.launch() }
                // Dashboard pairing QR code: meshmapper://gateway?url=…&token=…
                .onOpenURL { model.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }
}
