import SwiftUI

struct ContentView: View {
    @State private var isPresented = false

    var body: some View {
        VStack {
            Button("OK") {
                isPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("OK", isPresented: $isPresented) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("ボタンが押されました")
        }
    }
}
