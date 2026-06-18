import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var service: ScreenshotService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            actions
            Divider()
            settings

            if let message = service.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(service.lastCaptureURL == nil ? .secondary : .green)
                    .lineLimit(2)
            }

            Divider()
            HStack {
                Button("Choose Folder") { service.chooseOutputFolder() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Redshot").font(.headline)
                Text("Shift + Option + S/A/D/F").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var actions: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Button { service.startCapture() } label: { Label("Region", systemImage: "viewfinder") }
                Button { service.captureFocusedWindow() } label: { Label("Window", systemImage: "macwindow") }
            }
            GridRow {
                Button { service.captureLastRegion() } label: { Label("Last", systemImage: "rectangle.dashed") }
                Button { service.captureFullScreen() } label: { Label("Screen", systemImage: "display") }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Save to location", isOn: $service.saveToLocationEnabled)
            Toggle("Copy to clipboard", isOn: $service.copyToClipboardEnabled)
            Toggle("Include mouse pointer", isOn: $service.includeMousePointer)

            Picker("Format", selection: $service.imageFormat) {
                ForEach(RedshotImageFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Quality").font(.caption)
                    Spacer()
                    Text("\(Int(service.imageQuality * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $service.imageQuality, in: 0.1...1)
                    .disabled(service.imageFormat != .jpeg)
            }

            Text(service.outputFolderPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .font(.caption)
        .toggleStyle(.checkbox)
    }
}
