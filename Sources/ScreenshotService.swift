import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotService: ObservableObject {
    @Published var lastCaptureURL: URL?
    @Published var lastMessage: String? = "Ready"

    private var controller: CaptureOverlayController?

    func startCapture() {
        guard controller == nil else { return }
        lastMessage = "Select a region..."
        controller = CaptureOverlayController { [weak self] result in
            Task { @MainActor in
                self?.controller = nil
                switch result {
                case .success(let rect):
                    self?.capture(rect: rect)
                case .cancelled:
                    self?.lastMessage = "Capture cancelled"
                }
            }
        }
        controller?.show()
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

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            lastMessage = "Could not encode screenshot"
            return
        }

        do {
            let folder = try outputFolder()
            let url = folder.appendingPathComponent(fileName(), conformingTo: .png)
            try png.write(to: url, options: .atomic)
            copyToClipboard(png: png, image: NSImage(cgImage: image, size: rect.size))
            lastCaptureURL = url
            lastMessage = "Saved and copied: \(url.lastPathComponent)"
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    private func outputFolder() throws -> URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let folder = base.appendingPathComponent("Redshot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Redshot \(formatter.string(from: Date())).png"
    }

    private func copyToClipboard(png: Data, image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setData(png, forType: .png)
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
            window.makeKeyAndOrderFront(nil)
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
