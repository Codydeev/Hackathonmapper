import SwiftUI

@main
struct MeshMapperApp: App {
    @StateObject private var model = MeshModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, bluetooth: model.bluetooth, gateway: model.gateway)
        }
    }
}
