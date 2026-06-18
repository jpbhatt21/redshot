import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var service: ScreenshotService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Redshot").font(.headline)
                    Text("Shift + Option + S").font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("Region capture with cursor magnifier", systemImage: "viewfinder")
                Label("Saves to Pictures/Redshot", systemImage: "folder")
                Label("Copies PNG to clipboard", systemImage: "doc.on.clipboard")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let message = service.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(service.lastCaptureURL == nil ? .secondary : .green)
                    .lineLimit(2)
            }

            HStack {
                Button {
                    service.startCapture()
                } label: {
                    Label("Capture", systemImage: "camera")
                }
                .keyboardShortcut("s", modifiers: [.shift, .option])

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
    }
}
