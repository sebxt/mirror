import AppKit
import AVFoundation
import Carbon.HIToolbox
import UniformTypeIdentifiers

// Command Shift S shows or hides the camera.
let shortcutKey = UInt32(kVK_ANSI_S)
let shortcutModifiers = UInt32(cmdKey | shiftKey)

// The camera grows out of the notch, where the real camera is, and folds back into it.
// The camera needs about 430 ms to deliver its first picture, so the motion starts at once
// and shows a blurred frame from last time until the live picture arrives.
let openDuration = 0.45
let closeDuration = 0.35
let openCornerRadius: CGFloat = 44
let notchCornerRadius: CGFloat = 8
let closedScale: CGFloat = 1.08

// One spring for every motion: no bounce, drawn at the display's full refresh rate.
func spring(_ keyPath: String, from: Any?, to: Any, duration: Double) -> CASpringAnimation {
    let animation = CASpringAnimation(perceptualDuration: duration, bounce: 0)
    animation.keyPath = keyPath
    animation.fromValue = from
    animation.toValue = to
    animation.duration = animation.settlingDuration
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    return animation
}

extension NSScreen {
    // The laptop's own screen, never an external monitor. The main screen when the lid is closed.
    static var builtIn: NSScreen {
        screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? main ?? screens[0]
    }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // The notch in this screen's own coordinates, origin bottom left. A screen without one
    // gets a strip of zero height at the top center, so the camera drops from the top edge.
    var notch: CGRect {
        if let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea, right.minX > left.maxX {
            return CGRect(x: left.maxX - frame.minX, y: left.minY - frame.minY, width: right.minX - left.maxX, height: left.height)
        }
        return CGRect(x: frame.width / 2 - 90, y: frame.height, width: 180, height: 0)
    }
}

// The Mac's camera. It runs only while Mirror is open, so the camera light means Mirror is showing.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "mirror.session")
    private let frameQueue = DispatchQueue(label: "mirror.frames")
    private let context = CIContext()
    private var isConfigured = false
    private var onPicture: (() -> Void)?
    private var onLastFrame: ((CGImage) -> Void)?

    // The built in camera; an iPhone through Continuity Camera only when there is no other.
    static var device: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            .devices.first ?? AVCaptureDevice.default(for: .video)
    }

    func configure() -> Bool {
        if isConfigured { return true }
        guard let device = Self.device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        let frames = AVCaptureVideoDataOutput()
        frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        frames.alwaysDiscardsLateVideoFrames = true
        frames.setSampleBufferDelegate(self, queue: frameQueue)
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        if session.canAddOutput(frames) { session.addOutput(frames) }
        session.commitConfiguration()
        isConfigured = true
        return true
    }

    func start() {
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
    }

    // Calls back once the first real picture arrives. The first frames after a start are black.
    func whenPicture(_ handler: @escaping () -> Void) {
        frameQueue.async { self.onPicture = handler }
    }

    // Calls back with a small blurred copy of the next picture, mirrored like the preview.
    func captureLastFrame(_ handler: @escaping (CGImage) -> Void) {
        frameQueue.async { self.onLastFrame = handler }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard onPicture != nil || onLastFrame != nil,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              Self.brightness(pixels) > 24 else { return }
        if let handler = onPicture {
            onPicture = nil
            DispatchQueue.main.async(execute: handler)
        }
        if let handler = onLastFrame, let image = blurred(pixels) {
            onLastFrame = nil
            DispatchQueue.main.async { handler(image) }
        }
    }

    // Mean of a 16 by 16 grid on the luma plane, where black is 16.
    private static func brightness(_ pixels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return 0 }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var sum = 0
        for y in 0..<16 {
            for x in 0..<16 { sum += Int(luma[y * height / 16 * row + x * width / 16]) }
        }
        return sum / 256
    }

    private func blurred(_ pixels: CVPixelBuffer) -> CGImage? {
        let frame = CIImage(cvPixelBuffer: pixels)
        let scale = 480 / frame.extent.width
        let mirrored = frame.transformed(by: CGAffineTransform(scaleX: -scale, y: scale))
        let small = mirrored.transformed(by: CGAffineTransform(translationX: -mirrored.extent.minX, y: -mirrored.extent.minY))
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: small.extent)
        return context.createCGImage(soft, from: small.extent)
    }
}

// The blurred last frame, kept on disk so the first opening after a restart has one too.
enum LastFrame {
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.sebastianturner.mirror/last.png")

    static func load() -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func save(_ image: CGImage) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(file, image, nil)
            CGImageDestinationFinalize(file)
        }
    }
}

final class CameraWindow: NSWindow {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }

    // Borderless windows are kept below the menu bar by default; this one covers the whole screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // Command W closes. So does Command Q, so the shortcut keeps working.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if command, ["w", "q"].contains(event.charactersIgnoringModifiers?.lowercased()) {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onClose?() } else { super.keyDown(with: event) }
    }
}

final class StageView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let aperture = CALayer()  // the visible area, which grows out of the notch
    private let clip = CALayer()
    private let content = CALayer()
    private let lastFrameLayer = CALayer()
    private let closedBounds: CGRect
    private let openBounds: CGRect

    init(frame: NSRect, session: AVCaptureSession, notch: CGRect) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        // Closed, the aperture hides under the notch. Open, it reaches past the screen's
        // edges, so its rounded bottom corners are off screen.
        closedBounds = CGRect(x: 0, y: 0, width: max(notch.width - 4, 0), height: max(notch.height - 2, 0))
        let halfWidth = max(notch.midX, frame.width - notch.midX)
        openBounds = CGRect(x: 0, y: 0, width: (halfWidth + openCornerRadius) * 2, height: frame.height + openCornerRadius)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let top = CGPoint(x: notch.midX, y: frame.height)

        aperture.backgroundColor = NSColor.black.cgColor
        aperture.cornerCurve = .continuous
        aperture.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        aperture.anchorPoint = CGPoint(x: 0.5, y: 1)
        aperture.position = top

        clip.frame = bounds
        clip.mask = aperture

        content.bounds = bounds
        content.anchorPoint = CGPoint(x: 0.5, y: 1)
        content.position = top
        content.backgroundColor = NSColor.black.cgColor

        lastFrameLayer.frame = bounds
        lastFrameLayer.contentsGravity = .resizeAspectFill
        lastFrameLayer.masksToBounds = true

        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        // Mirrored, like FaceTime and Photo Booth.
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        layer?.addSublayer(clip)
        clip.addSublayer(content)
        content.addSublayer(lastFrameLayer)
        content.addSublayer(previewLayer)
        reset(lastFrame: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Closed under the notch, the last frame in place and the live picture hidden.
    func reset(lastFrame: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [aperture, content, previewLayer] { layer.removeAllAnimations() }
        aperture.bounds = closedBounds
        aperture.cornerRadius = notchCornerRadius
        content.transform = CATransform3DMakeScale(closedScale, closedScale, 1)
        lastFrameLayer.contents = lastFrame
        previewLayer.opacity = 0
        CATransaction.commit()
    }

    // Starts from wherever the motion is now, so a second press mid motion turns it around smoothly.
    func animate(open: Bool, completion: (() -> Void)? = nil) {
        let duration = open ? openDuration : closeDuration
        let bounds = open ? openBounds : closedBounds
        let radius = open ? openCornerRadius : notchCornerRadius
        let scale = open ? 1 : closedScale
        let transform = CATransform3DMakeScale(scale, scale, 1)
        let now = (aperture: aperture.presentation() ?? aperture, content: content.presentation() ?? content)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        aperture.bounds = bounds
        aperture.cornerRadius = radius
        content.transform = transform
        aperture.add(spring("bounds", from: NSValue(rect: now.aperture.bounds), to: NSValue(rect: bounds), duration: duration), forKey: "bounds")
        aperture.add(spring("cornerRadius", from: now.aperture.cornerRadius, to: radius, duration: duration), forKey: "cornerRadius")
        content.add(spring("transform", from: NSValue(caTransform3D: now.content.transform), to: NSValue(caTransform3D: transform), duration: duration), forKey: "transform")
        CATransaction.commit()
    }

    // The live picture sharpens in over the blurred last frame.
    func showLive() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = previewLayer.presentation()?.opacity ?? 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.opacity = 1
        previewLayer.add(fade, forKey: "opacity")
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let camera = Camera()
    private var window: CameraWindow?
    private var stage: StageView?
    private var shortcut: EventHotKeyRef?
    private var isOpen = false
    // Bumped on every open and close, so a callback from an earlier press does nothing.
    private var generation = 0
    private var lastFrame = LastFrame.load()
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let registered = registerShortcut()
        if CommandLine.arguments.contains("--check") {
            check(shortcutRegistered: registered)
            return
        }
        // Built ahead of time, so the first press does no setup work.
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized, camera.configure() {
            prepareWindow(for: .builtIn)
        }
        // Started at login with --background. Opened by a click, it shows the camera right away.
        if !CommandLine.arguments.contains("--background") { open() }
    }

    // A click on the app while it is running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle()
        return false
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            present()
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { self.present() } }
            }
        default:
            explain("Mirror cannot use the camera", "Turn on Mirror in System Settings, Privacy & Security, Camera.",
                    settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        }
    }

    func close() {
        guard isOpen, let window, let stage else { return }
        isOpen = false
        generation += 1
        let generation = self.generation
        camera.captureLastFrame { [weak self] image in
            self?.lastFrame = image
            LastFrame.save(image)
        }
        // The keyboard goes back at once; the window keeps animating above everything.
        let handedBack = previousApp.map { !$0.isTerminated && $0.activate(options: []) } ?? false
        stage.animate(open: false) { [weak self] in
            guard let self, generation == self.generation else { return }
            window.orderOut(nil)
            self.camera.stop()
            if !handedBack { NSApp.hide(nil) }
        }
    }

    private func present() {
        guard camera.configure() else {
            explain("No camera found", "Mirror could not open a camera on this Mac.")
            return
        }
        isOpen = true
        generation += 1
        let generation = self.generation
        let screen = NSScreen.builtIn
        if window?.frame != screen.frame { prepareWindow(for: screen) }
        guard let window, let stage else { return }
        // Also on a reopen mid close, when a close before the first picture left the live picture hidden.
        camera.whenPicture { [weak self] in
            guard let self, generation == self.generation else { return }
            self.stage?.showLive()
        }
        if !window.isVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
            stage.reset(lastFrame: lastFrame)
            camera.start()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        stage.animate(open: true)
    }

    private func prepareWindow(for screen: NSScreen) {
        window?.orderOut(nil)
        stage?.previewLayer.session = nil
        let window = CameraWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.onClose = { [weak self] in self?.close() }
        let stage = StageView(frame: NSRect(origin: .zero, size: screen.frame.size), session: camera.session, notch: screen.notch)
        window.contentView = stage
        self.window = window
        self.stage = stage
    }

    private func registerShortcut() -> Bool {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.toggle() }
            return noErr
        }, 1, &pressed, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D52_524F), id: 1)  // "MRRO"
        return RegisterEventHotKey(shortcutKey, shortcutModifiers, id, GetApplicationEventTarget(), 0, &shortcut) == noErr
    }

    private func explain(_ title: String, _ text: String, settings: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if settings != nil {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
        }
        if alert.runModal() == .alertFirstButtonReturn, let settings, let url = URL(string: settings) {
            NSWorkspace.shared.open(url)
        }
    }

    // `Mirror --check` prints what Mirror finds, then times the camera's first picture.
    private func check(shortcutRegistered: Bool) {
        let screen = NSScreen.builtIn
        let allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        print("shortcut: \(shortcutRegistered ? "registered" : "not registered")")
        print("screen: \(screen.localizedName), notch \(screen.notch)")
        print("camera: \(Camera.device?.localizedName ?? "none"), access \(allowed ? "allowed" : "not allowed")")
        guard allowed, camera.configure() else {
            NSApp.terminate(nil)
            return
        }
        let start = Date()
        camera.whenPicture {
            print("first picture: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            NSApp.terminate(nil)
        }
        camera.start()
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
