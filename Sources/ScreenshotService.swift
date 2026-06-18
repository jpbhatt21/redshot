import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotService: ObservableObject {
    @Published var lastCaptureURL: URL?
    @Published var lastMessage: String? = "Ready"
    @Published var outputFolderPath: String {
        didSet { defaults.set(outputFolderPath, forKey: Keys.outputFolderPath) }
    }
    @Published var includeMousePointer: Bool {
        didSet { defaults.set(includeMousePointer, forKey: Keys.includeMousePointer) }
    }
    @Published var copyToClipboardEnabled: Bool {
        didSet { defaults.set(copyToClipboardEnabled, forKey: Keys.copyToClipboardEnabled) }
    }
    @Published var saveToLocationEnabled: Bool {
        didSet { defaults.set(saveToLocationEnabled, forKey: Keys.saveToLocationEnabled) }
    }
    @Published var imageFormat: RedshotImageFormat {
        didSet { defaults.set(imageFormat.rawValue, forKey: Keys.imageFormat) }
    }
    @Published var imageQuality: Double {
        didSet { defaults.set(imageQuality, forKey: Keys.imageQuality) }
    }

    private let defaults = UserDefaults.standard
    private var controller: CaptureOverlayController?
    private var actionWindow: NSWindow?

    init() {
        outputFolderPath = defaults.string(forKey: Keys.outputFolderPath)
            ?? ScreenshotService.defaultOutputFolder().path
        includeMousePointer = defaults.object(forKey: Keys.includeMousePointer) as? Bool ?? false
        copyToClipboardEnabled = defaults.object(forKey: Keys.copyToClipboardEnabled) as? Bool ?? true
        saveToLocationEnabled = defaults.object(forKey: Keys.saveToLocationEnabled) as? Bool ?? true
        imageFormat = RedshotImageFormat(rawValue: defaults.string(forKey: Keys.imageFormat) ?? "") ?? .png
        imageQuality = defaults.object(forKey: Keys.imageQuality) as? Double ?? 0.9
    }

    func startCapture() {
        guard controller == nil else { return }
        lastMessage = "Select a region..."
        controller = CaptureOverlayController { [weak self] result in
            Task { @MainActor in
                self?.controller = nil
                switch result {
                case .success(let rect):
                    self?.storeLastRegion(rect)
                    self?.capture(rect: rect)
                case .cancelled:
                    self?.lastMessage = "Capture cancelled"
                }
            }
        }
        controller?.show()
    }

    func captureLastRegion() {
        guard let rect = lastRegion else {
            lastMessage = "No previous region"
            return
        }
        capture(rect: rect)
    }

    func captureFullScreen() {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        capture(rect: union)
    }

    func captureFocusedWindow() {
        guard let info = focusedWindowInfo(),
              let windowID = info[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            lastMessage = "Could not find focused window"
            return
        }

        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else {
            lastMessage = "Screen Recording permission is required"
            return
        }

        handle(image: image, suggestedSize: bounds.size)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputFolderPath)

        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }

    private func capture(rect: CGRect) {
        guard rect.width >= 2, rect.height >= 2 else {
            lastMessage = "Selection was too small"
            return
        }

        guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming]) else {
            lastMessage = "Screen Recording permission is required"
            return
        }

        handle(image: image, suggestedSize: rect.size)
    }

    private func handle(image: CGImage, suggestedSize: CGSize) {
        let image = includeMousePointer ? imageWithCursor(base: image, size: suggestedSize) ?? image : image
        guard let data = encodedData(for: image) else {
            lastMessage = "Could not encode screenshot"
            return
        }

        if !saveToLocationEnabled && !copyToClipboardEnabled {
            showActionWindow(data: data, image: image)
            return
        }

        do {
            var actions: [String] = []
            if saveToLocationEnabled {
                let url = try save(data: data, to: outputFolderURL())
                lastCaptureURL = url
                actions.append("saved")
            }
            if copyToClipboardEnabled {
                copyToClipboard(data: data, image: NSImage(cgImage: image, size: suggestedSize))
                actions.append("copied")
            }
            lastMessage = actions.isEmpty ? "Capture ready" : "Capture \(actions.joined(separator: " and "))"
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    private func outputFolderURL() throws -> URL {
        let folder = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func defaultOutputFolder() -> URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return base.appendingPathComponent("Redshot", isDirectory: true)
    }

    private func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Redshot \(formatter.string(from: Date())).\(imageFormat.fileExtension)"
    }

    private func save(data: Data, to folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(fileName())
        try data.write(to: url, options: .atomic)
        return url
    }

    private func copyToClipboard(data: Data, image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setData(data, forType: imageFormat.pasteboardType)
    }

    private func encodedData(for image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: imageFormat.bitmapFileType, properties: imageFormat.properties(quality: imageQuality))
    }

    private func storeLastRegion(_ rect: CGRect) {
        defaults.set(NSStringFromRect(rect), forKey: Keys.lastRegion)
    }

    private var lastRegion: CGRect? {
        guard let raw = defaults.string(forKey: Keys.lastRegion) else { return nil }
        let rect = NSRectFromString(raw)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private func focusedWindowInfo() -> [String: Any]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let frontAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return windows.first { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return false
            }

            return layer == 0
                && alpha > 0
                && ownerPID == frontAppPID
                && bounds.width > 20
                && bounds.height > 20
        }
    }

    private func imageWithCursor(base: CGImage, size: CGSize) -> CGImage? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
              let cursorImage = NSCursor.current.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let scaleX = CGFloat(base.width) / size.width
        let scaleY = CGFloat(base.height) / size.height
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        let hotSpot = NSCursor.current.hotSpot
        let cursorSize = NSCursor.current.image.size

        let rep = NSBitmapImageRep(cgImage: base)
        let output = NSImage(size: NSSize(width: base.width, height: base.height))
        output.addRepresentation(rep)

        output.lockFocus()
        NSCursor.current.image.draw(in: CGRect(
            x: (local.x - hotSpot.x) * scaleX,
            y: (local.y - (cursorSize.height - hotSpot.y)) * scaleY,
            width: cursorSize.width * scaleX,
            height: cursorSize.height * scaleY
        ))
        output.unlockFocus()

        var rect = CGRect(origin: .zero, size: output.size)
        return output.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func showActionWindow(data: Data, image: CGImage) {
        let view = CaptureActionView(
            save: { [weak self] in self?.performManualSave(data: data) },
            copy: { [weak self] in self?.performManualCopy(data: data, image: image) },
            saveAndCopy: { [weak self] in
                self?.performManualSave(data: data)
                self?.performManualCopy(data: data, image: image)
            },
            saveCustom: { [weak self] in self?.performManualSaveCustom(data: data) },
            trash: { [weak self] in self?.closeActionWindow(message: "Capture discarded") }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Redshot"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        actionWindow = window
    }

    private func performManualSave(data: Data) {
        do {
            let url = try save(data: data, to: outputFolderURL())
            lastCaptureURL = url
            closeActionWindow(message: "Saved: \(url.lastPathComponent)")
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    private func performManualCopy(data: Data, image: CGImage) {
        copyToClipboard(data: data, image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        closeActionWindow(message: "Copied")
    }

    private func performManualSaveCustom(data: Data) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let folder = panel.url {
            do {
                let url = try save(data: data, to: folder)
                lastCaptureURL = url
                closeActionWindow(message: "Saved: \(url.lastPathComponent)")
            } catch {
                lastMessage = error.localizedDescription
            }
        }
    }

    private func closeActionWindow(message: String) {
        actionWindow?.close()
        actionWindow = nil
        lastMessage = message
    }

    private enum Keys {
        static let outputFolderPath = "redshot.outputFolderPath"
        static let includeMousePointer = "redshot.includeMousePointer"
        static let copyToClipboardEnabled = "redshot.copyToClipboardEnabled"
        static let saveToLocationEnabled = "redshot.saveToLocationEnabled"
        static let imageFormat = "redshot.imageFormat"
        static let imageQuality = "redshot.imageQuality"
        static let lastRegion = "redshot.lastRegion"
    }
}

enum RedshotImageFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case tiff

    var id: String { rawValue }

    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        }
    }

    var bitmapFileType: NSBitmapImageRep.FileType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }

    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .png: return .png
        case .jpeg: return .tiff
        case .tiff: return .tiff
        }
    }

    func properties(quality: Double) -> [NSBitmapImageRep.PropertyKey: Any] {
        switch self {
        case .jpeg:
            return [.compressionFactor: max(0, min(1, quality))]
        case .png, .tiff:
            return [:]
        }
    }
}

struct CaptureActionView: View {
    let save: () -> Void
    let copy: () -> Void
    let saveAndCopy: () -> Void
    let saveCustom: () -> Void
    let trash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture ready").font(.headline)
            Button("Save to location", action: save)
            Button("Copy to clipboard", action: copy)
            Button("Save and copy", action: saveAndCopy)
            Button("Save to custom folder", action: saveCustom)
            Button("Move to trash", role: .destructive, action: trash)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

enum CaptureResult {
    case success(CGRect)
    case cancelled
}

final class CaptureOverlayController {
    private let completion: (CaptureResult) -> Void
    private var windows: [CaptureWindow] = []
    private var completed = false

    init(completion: @escaping (CaptureResult) -> Void) {
        self.completion = completion
    }

    func show() {
        windows = NSScreen.screens.map { screen in
            let screenImage = CGWindowListCreateImage(screen.frame, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming])
            let window = CaptureWindow(screen: screen)
            let view = CaptureOverlayView(screen: screen, screenImage: screenImage) { [weak self] result in
                self?.finish(result)
            }
            window.contentView = view
            window.orderFrontRegardless()
            window.makeKey()
            window.makeFirstResponder(view)
            return window
        }
        NSCursor.crosshair.set()
    }

    private func finish(_ result: CaptureResult) {
        guard !completed else { return }
        completed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            windows.forEach { window in
                window.animator().alphaValue = 0
                window.orderOut(nil)
            }
        }
        windows.removeAll()
        NSCursor.arrow.set()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [completion] in
            completion(result)
        }
    }
}

final class CaptureWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 1
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

}

final class CaptureOverlayView: NSView {
    private let screen: NSScreen
    private let screenImage: CGImage?
    private let completion: (CaptureResult) -> Void
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var cursorPoint: CGPoint?
    private let magnifierDiameter: CGFloat = 154
    private let magnifierGap: CGFloat = 18

    init(screen: NSScreen, screenImage: CGImage?, completion: @escaping (CaptureResult) -> Void) {
        self.screen = screen
        self.screenImage = screenImage
        self.completion = completion
        super.init(frame: screen.frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        cursorPoint = currentPoint
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect, rect.width >= 2, rect.height >= 2 else {
            completion(.cancelled)
            return
        }

        completion(.success(toGlobal(rect)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            completion(.cancelled)
            return
        }

        guard let delta = arrowDelta(for: event) else {
            super.keyDown(with: event)
            return
        }

        if currentPoint != nil {
            currentPoint = clamped((currentPoint ?? .zero) + delta)
            cursorPoint = currentPoint
        } else if cursorPoint != nil {
            cursorPoint = clamped((cursorPoint ?? .zero) + delta)
        } else {
            cursorPoint = clamped(CGPoint(x: bounds.midX, y: bounds.midY) + delta)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let screenImage {
            NSImage(cgImage: screenImage, size: bounds.size).draw(in: bounds)
        } else {
            NSColor.black.setFill()
            bounds.fill()
        }

        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        if let rect = selectionRect {
            if let cropped = cropSelectionImage(for: rect) {
                NSGraphicsContext.current?.imageInterpolation = .none
                NSImage(cgImage: cropped, size: rect.size).draw(in: rect)
            }

            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()

            drawDimensions(for: rect)
        }

        if let point = cursorPoint {
            drawMagnifier(at: point)
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }

    private func toGlobal(_ rect: CGRect) -> CGRect {
        CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func drawDimensions(for rect: CGRect) {
        let text = "\(Int(rect.width)) x \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let box = CGRect(x: rect.minX, y: max(rect.minY - 26, 8), width: size.width + 14, height: 22)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 4), withAttributes: attributes)
    }

    private func drawMagnifier(at point: CGPoint) {
        let sampleSize: CGFloat = 10
        let image = magnifierSample(at: point, size: sampleSize)

        let box = magnifierBox(at: point)

        NSColor.black.withAlphaComponent(0.86).setFill()
        let circle = NSBezierPath(ovalIn: box)
        circle.fill()

        let imageRect = box.insetBy(dx: 8, dy: 8)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: imageRect).addClip()
        if let image {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: image, size: imageRect.size).draw(in: imageRect)
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: imageRect.midX, y: imageRect.minY))
        cross.line(to: CGPoint(x: imageRect.midX, y: imageRect.maxY))
        cross.move(to: CGPoint(x: imageRect.minX, y: imageRect.midY))
        cross.line(to: CGPoint(x: imageRect.maxX, y: imageRect.midY))
        cross.lineWidth = 1
        cross.stroke()

        NSColor.white.withAlphaComponent(0.88).setStroke()
        circle.lineWidth = 2
        circle.stroke()

        let label = "\(Int(screen.frame.minX + point.x)), \(Int(screen.frame.minY + bounds.height - point.y))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let labelSize = label.size(withAttributes: attributes)
        let labelPoint = CGPoint(x: box.midX - labelSize.width / 2, y: box.minY + 10)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: CGRect(
            x: labelPoint.x - 6,
            y: labelPoint.y - 3,
            width: labelSize.width + 12,
            height: labelSize.height + 5
        ), xRadius: 4, yRadius: 4).fill()
        label.draw(at: labelPoint, withAttributes: attributes)
    }

    private func magnifierSample(at point: CGPoint, size: CGFloat) -> CGImage? {
        guard let screenImage else { return nil }

        let scaleX = CGFloat(screenImage.width) / bounds.width
        let scaleY = CGFloat(screenImage.height) / bounds.height
        let sampleRect = CGRect(
            x: (point.x - size / 2) * scaleX,
            y: (bounds.height - point.y - size / 2) * scaleY,
            width: size * scaleX,
            height: size * scaleY
        ).integral

        return screenImage.cropping(to: sampleRect)
    }

    private func cropSelectionImage(for rect: CGRect) -> CGImage? {
        guard let screenImage else { return nil }

        let scaleX = CGFloat(screenImage.width) / bounds.width
        let scaleY = CGFloat(screenImage.height) / bounds.height
        let cropRect = CGRect(
            x: rect.minX * scaleX,
            y: (bounds.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral

        return screenImage.cropping(to: cropRect)
    }

    private func magnifierBox(at point: CGPoint) -> CGRect {
        var box = CGRect(
            x: point.x + magnifierGap,
            y: point.y - magnifierDiameter - magnifierGap,
            width: magnifierDiameter,
            height: magnifierDiameter
        )
        if box.maxX > bounds.maxX - 8 { box.origin.x = point.x - magnifierDiameter - magnifierGap }
        if box.minY < bounds.minY + 8 { box.origin.y = point.y + magnifierGap }
        return box
    }

    private func arrowDelta(for event: NSEvent) -> CGPoint? {
        switch event.specialKey {
        case .leftArrow: return CGPoint(x: -1, y: 0)
        case .rightArrow: return CGPoint(x: 1, y: 0)
        case .upArrow: return CGPoint(x: 0, y: 1)
        case .downArrow: return CGPoint(x: 0, y: -1)
        default: return nil
        }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}
