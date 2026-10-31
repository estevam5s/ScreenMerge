import AppKit
import CoreGraphics
import CoreMedia
import IOSurface
import ScreenCaptureKit
import SwiftUI

// MARK: - BetterDisplay CLI

enum BD {
    static let cli = "/opt/homebrew/bin/betterdisplaycli"
    private static let bg = DispatchQueue(label: "bd.cli", qos: .userInitiated)

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: cli)
    }

    @discardableResult
    static func exec(_ args: String...) async -> String {
        await withCheckedContinuation { cont in
            bg.async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: cli)
                proc.arguments = args
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
                let result = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: result)
            }
        }
    }

    static func ensureRunning() async {
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier?.contains("betterdisplay") == true ||
                $0.localizedName?.lowercased().contains("betterdisplay") == true
            }
        }
        if !running {
            await MainActor.run {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/BetterDisplay.app"))
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    static func createMergedScreen() async {
        // Clean up any leftover virtual screens first
        for _ in 0..<5 {
            let result = await exec("discard", "-name=ScreenMerge")
            if result.lowercased().contains("fail") || result.isEmpty { break }
        }
        try? await Task.sleep(for: .seconds(0.5))

        await exec("create",
             "-type=VirtualScreen",
             "-virtualScreenName=ScreenMerge",
             "-aspectWidth=32",
             "-aspectHeight=9",
             "-virtualScreenHiDPI=off",
             "-connected=on")
    }

    static func setResolution(tagID: String) async {
        await exec("set", "-tagID=\(tagID)", "-hiDPI=off")
        await exec("set", "-tagID=\(tagID)", "-resolution=3840x1080")
    }

    static func getResolution(tagID: String) async -> String {
        await exec("get", "-tagID=\(tagID)", "-resolution")
    }

    static func discard() async {
        await exec("discard", "-name=ScreenMerge")
    }

    static func discardSync() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["discard", "-name=ScreenMerge"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    static func findVirtual() async -> (tagID: String, displayID: CGDirectDisplayID)? {
        let raw = await exec("get", "-identifiers", "-type=VirtualScreen", "-name=ScreenMerge")
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagID = json["tagID (Display)"] as? String,
              let didStr = json["displayID"] as? String,
              let did = UInt32(didStr) else { return nil }
        return (tagID, CGDirectDisplayID(did))
    }
}

// MARK: - Overlay Window

class OverlayWindow: NSWindow {
    let render = CALayer()

    init(displayID: CGDirectDisplayID, leftHalf: Bool) {
        let cgBounds = CGDisplayBounds(displayID)

        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let nsFrame = NSRect(
            x: cgBounds.origin.x,
            y: primaryHeight - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )

        super.init(
            contentRect: nsFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = true
        backgroundColor = .black
        level = .init(rawValue: Int(CGShieldingWindowLevel()) + 1)
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hasShadow = false
        animationBehavior = .none

        setFrame(nsFrame, display: true)

        let v = NSView(frame: NSRect(origin: .zero, size: nsFrame.size))
        v.wantsLayer = true
        v.layer!.masksToBounds = true
        v.layer!.backgroundColor = NSColor.black.cgColor

        render.contentsGravity = .resize
        render.contentsScale = 1.0
        render.magnificationFilter = .nearest
        render.minificationFilter = .nearest
        render.contentsRect = leftHalf
            ? CGRect(x: 0, y: 0, width: 0.5, height: 1)
            : CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        render.frame = v.bounds
        render.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer!.addSublayer(render)

        contentView = v

        print("[ScreenMerge] Overlay \(leftHalf ? "LEFT" : "RIGHT"): nsFrame=\(nsFrame) cgBounds=\(cgBounds) displayID=\(displayID)")
    }

    func showFrame(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render.contents = surface
        CATransaction.commit()
    }
}

// MARK: - Screen Capture

class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "screenmerge.capture", qos: .userInteractive)
    var onFrame: ((IOSurface) -> Void)?
    private var loggedSize = false

    func start(displayID: CGDirectDisplayID, width: Int, height: Int) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("[ScreenMerge] Screen Recording not granted")
            throw MergeError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw MergeError.displayNotFound
        }

        print("[ScreenMerge] SCDisplay: \(scDisplay.displayID) \(scDisplay.width)x\(scDisplay.height)")

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        print("[ScreenMerge] Capture started \(width)x\(height)")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buf: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pxBuf = CMSampleBufferGetImageBuffer(buf) else { return }
        guard let ref = CVPixelBufferGetIOSurface(pxBuf) else { return }
        let surface = unsafeBitCast(ref, to: IOSurface.self)
        if !loggedSize {
            loggedSize = true
            let w = CVPixelBufferGetWidth(pxBuf)
            let h = CVPixelBufferGetHeight(pxBuf)
            print("[ScreenMerge] Actual frame size: \(w)x\(h)")
        }
        onFrame?(surface)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenMerge] stream error: \(error)")
    }
}

enum MergeError: LocalizedError {
    case noBetterDisplay, notEnoughMonitors, displayNotFound, resolutionFailed, screenRecordingDenied
    var errorDescription: String? {
        switch self {
        case .noBetterDisplay: return "BetterDisplay nao instalado"
        case .notEnoughMonitors: return "Precisa de 2 monitores externos"
        case .displayNotFound: return "Display virtual nao encontrado no ScreenCaptureKit"
        case .resolutionFailed: return "Nao conseguiu definir 3840x1080"
        case .screenRecordingDenied: return "Permissao de Gravacao de Tela negada. Conceda em Ajustes > Privacidade e reinicie o app."
        }
    }
}

// MARK: - Merge Controller

@MainActor
class MergeController: ObservableObject {
    @Published var active = false
    @Published var status = "Pronto"

    private var capture = Capture()
    private var leftWin: OverlayWindow?
    private var rightWin: OverlayWindow?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hotkeyMonitor: Any?
    @Published var cursorLocked = true
    private var virtualDisplayID: CGDirectDisplayID = 0
    private var virtualTagID = ""
    var virtualBounds: CGRect = .zero
    private var physicalLeftID: CGDirectDisplayID = 0
    private var physicalRightID: CGDirectDisplayID = 0

    func toggle() {
        Task { active ? await deactivate() : await activate() }
    }

    func activate() async {
        guard !active else { return }

        guard BD.isInstalled else {
            status = "BetterDisplay CLI nao encontrado"
            return
        }

        status = "Verificando BetterDisplay..."
        await BD.ensureRunning()

        // Snapshot physical monitors BEFORE creating virtual
        let externals = physicalExternals()
        guard externals.count >= 2 else {
            status = "Precisa de 2 monitores externos conectados"
            return
        }
        physicalLeftID = externals[0]
        physicalRightID = externals[1]
        let leftBounds = CGDisplayBounds(physicalLeftID)
        let rightBounds = CGDisplayBounds(physicalRightID)
        print("[ScreenMerge] Left monitor: \(physicalLeftID) at \(leftBounds)")
        print("[ScreenMerge] Right monitor: \(physicalRightID) at \(rightBounds)")

        status = "Criando display virtual..."

        await BD.createMergedScreen()
        try? await Task.sleep(for: .seconds(2))

        guard let info = await BD.findVirtual() else {
            status = "Falha ao criar display virtual"
            return
        }
        virtualTagID = info.tagID

        status = "Configurando resolucao..."

        await BD.setResolution(tagID: virtualTagID)
        try? await Task.sleep(for: .seconds(1))

        let res = await BD.getResolution(tagID: virtualTagID)
        print("[ScreenMerge] Virtual display resolution: \(res)")

        if !res.contains("3840") {
            await BD.setResolution(tagID: virtualTagID)
            try? await Task.sleep(for: .seconds(1))
            let res2 = await BD.getResolution(tagID: virtualTagID)
            print("[ScreenMerge] Retry resolution: \(res2)")
        }

        guard let info2 = await BD.findVirtual() else {
            status = "Display virtual perdido"
            await BD.discard()
            return
        }
        virtualDisplayID = info2.displayID
        virtualBounds = CGDisplayBounds(virtualDisplayID)
        let vw = Int(virtualBounds.width)
        let vh = Int(virtualBounds.height)

        print("[ScreenMerge] Virtual display \(virtualDisplayID): \(vw)x\(vh) at \(virtualBounds.origin)")

        guard vw >= 3840 && vh >= 1080 else {
            status = "Resolucao virtual incorreta: \(vw)x\(vh)"
            await BD.discard()
            return
        }

        status = "Movendo janelas..."

        // Move all windows from physical monitors to the virtual display
        moveWindowsToVirtual()
        try? await Task.sleep(for: .seconds(0.5))

        status = "Capturando..."

        // Create overlay windows on physical monitors
        leftWin = OverlayWindow(displayID: physicalLeftID, leftHalf: true)
        rightWin = OverlayWindow(displayID: physicalRightID, leftHalf: false)
        leftWin!.orderFront(nil)
        rightWin!.orderFront(nil)

        // Start capture at EXACT virtual display resolution
        capture.onFrame = { [weak self] surface in
            DispatchQueue.main.async {
                self?.leftWin?.showFrame(surface)
                self?.rightWin?.showFrame(surface)
            }
        }

        do {
            try await capture.start(displayID: virtualDisplayID, width: vw, height: vh)
        } catch {
            status = "Erro captura: \(error.localizedDescription)"
            cleanupOverlays()
            await BD.discard()
            return
        }

        // Setup cursor jail (only if Accessibility already granted)
        if AXIsProcessTrusted() {
            setupEventTap()
            setupHotkey()
        } else {
            print("[ScreenMerge] Accessibility not granted — cursor jail disabled")
            cursorLocked = false
        }

        // Warp cursor to center of virtual display
        let center = CGPoint(x: virtualBounds.midX, y: virtualBounds.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)

        // Give focus back to the frontmost app (not ScreenMerge)
        activateFrontApp()

        active = true
        status = "Merge ativo — \(vw)x\(vh)"
    }

    func deactivate() async {
        guard active else { return }
        active = false

        removeEventTap()
        await capture.stop()
        cleanupOverlays()

        // Move windows back from virtual display to physical monitors BEFORE discarding
        moveWindowsBack()
        try? await Task.sleep(for: .seconds(0.5))

        // Move cursor back to a physical monitor
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: mainBounds.midX, y: mainBounds.midY))

        try? await Task.sleep(for: .seconds(0.3))
        await BD.discard()

        virtualDisplayID = 0
        virtualBounds = .zero
        status = "Desativado"
    }

    // MARK: Helpers

    private func physicalExternals() -> [CGDirectDisplayID] {
        var buf = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &buf, &n)
        return (0..<Int(n))
            .map { buf[$0] }
            .filter { CGDisplayIsBuiltin($0) == 0 }
            .sorted { CGDisplayBounds($0).origin.x < CGDisplayBounds($1).origin.x }
    }

    private func cleanupOverlays() {
        leftWin?.close(); leftWin = nil
        rightWin?.close(); rightWin = nil
    }

    private func moveWindowsToVirtual() {
        let leftBounds = CGDisplayBounds(physicalLeftID)
        let rightBounds = CGDisplayBounds(physicalRightID)
        let physMinX = Int(min(leftBounds.minX, rightBounds.minX))
        let physMaxX = Int(max(leftBounds.maxX, rightBounds.maxX))
        let physMinY = Int(min(leftBounds.minY, rightBounds.minY))
        let physMaxY = Int(max(leftBounds.maxY, rightBounds.maxY))
        let offsetX = Int(virtualBounds.minX) - physMinX
        let offsetY = Int(virtualBounds.minY) - physMinY

        print("[ScreenMerge] Moving windows: physX=\(physMinX)..\(physMaxX) offset=(\(offsetX),\(offsetY))")

        let script = NSAppleScript(source: """
            tell application "System Events"
                repeat with proc in (every process whose visible is true)
                    try
                        repeat with win in (every window of proc)
                            set {x, y} to position of win
                            if x >= \(physMinX) and x < \(physMaxX) and y >= \(physMinY) and y < \(physMaxY) then
                                set position of win to {x + \(offsetX), y + \(offsetY)}
                            end if
                        end repeat
                    end try
                end repeat
            end tell
        """)
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        if let err { print("[ScreenMerge] AppleScript move error: \(err)") }

        // Maximize the frontmost window to fill the virtual display
        let vx = Int(virtualBounds.origin.x)
        let vy = Int(virtualBounds.origin.y)
        let vw = Int(virtualBounds.width)
        let vh = Int(virtualBounds.height)
        let maxScript = NSAppleScript(source: """
            tell application "System Events"
                set frontApp to first process whose frontmost is true
                try
                    set position of window 1 of frontApp to {\(vx), \(vy)}
                    set size of window 1 of frontApp to {\(vw), \(vh)}
                end try
            end tell
        """)
        var maxErr: NSDictionary?
        maxScript?.executeAndReturnError(&maxErr)
    }

    private func activateFrontApp() {
        let script = NSAppleScript(source: """
            tell application "System Events"
                set frontApp to first process whose frontmost is true
                if name of frontApp is not "ScreenMerge" then
                    set frontmost of frontApp to true
                else
                    -- Find another visible app to activate
                    repeat with proc in (every process whose visible is true)
                        if name of proc is not "ScreenMerge" then
                            set frontmost of proc to true
                            exit repeat
                        end if
                    end repeat
                end if
            end tell
        """)
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
    }

    private func moveWindowsBack() {
        guard !virtualBounds.isEmpty else { return }

        let leftBounds = CGDisplayBounds(physicalLeftID)
        let rightBounds = CGDisplayBounds(physicalRightID)
        let physMinX = Int(min(leftBounds.minX, rightBounds.minX))
        let physMinY = Int(min(leftBounds.minY, rightBounds.minY))
        let vMinX = Int(virtualBounds.minX)
        let vMaxX = Int(virtualBounds.maxX)
        let vMinY = Int(virtualBounds.minY)
        let vMaxY = Int(virtualBounds.maxY)
        let offsetX = physMinX - vMinX
        let offsetY = physMinY - vMinY

        print("[ScreenMerge] Moving windows back: virtualX=\(vMinX)..\(vMaxX) offset=(\(offsetX),\(offsetY))")

        let script = NSAppleScript(source: """
            tell application "System Events"
                repeat with proc in (every process whose visible is true)
                    try
                        repeat with win in (every window of proc)
                            set {x, y} to position of win
                            if x >= \(vMinX) and x < \(vMaxX) and y >= \(vMinY) and y < \(vMaxY) then
                                set position of win to {x + \(offsetX), y + \(offsetY)}
                            end if
                        end repeat
                    end try
                end repeat
            end tell
        """)
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        if let err { print("[ScreenMerge] AppleScript move-back error: \(err)") }
    }

    // MARK: Event Tap

    private func setupEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let ctrl = Unmanaged<MergeController>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = ctrl.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passRetained(event)
                }

                // If cursor not locked, let it move freely
                guard ctrl.cursorLocked else { return Unmanaged.passRetained(event) }

                let loc = event.location
                let vb = ctrl.virtualBounds
                guard !vb.isEmpty else { return Unmanaged.passRetained(event) }

                if vb.contains(loc) {
                    return Unmanaged.passRetained(event)
                }

                let clamped = CGPoint(
                    x: min(max(loc.x, vb.minX), vb.maxX - 1),
                    y: min(max(loc.y, vb.minY), vb.maxY - 1)
                )
                CGWarpMouseCursorPosition(clamped)
                CGAssociateMouseAndMouseCursorPosition(1)
                event.location = clamped
                return Unmanaged.passRetained(event)
            },
            userInfo: refcon
        )

        guard let tap = eventTap else {
            print("[ScreenMerge] Event tap creation failed — need Accessibility permission")
            return
        }
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[ScreenMerge] Event tap active")
    }

    private func setupHotkey() {
        // Ctrl+Shift+Esc toggles cursor lock
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            // keyCode 53 = Escape
            if event.keyCode == 53 &&
               event.modifierFlags.contains(.control) &&
               event.modifierFlags.contains(.shift) {
                Task { @MainActor in
                    self.cursorLocked.toggle()
                    if self.cursorLocked {
                        let center = CGPoint(x: self.virtualBounds.midX, y: self.virtualBounds.midY)
                        CGWarpMouseCursorPosition(center)
                        CGAssociateMouseAndMouseCursorPosition(1)
                    }
                    print("[ScreenMerge] Cursor \(self.cursorLocked ? "LOCKED" : "FREE")")
                }
            }
        }
    }

    private func removeHotkey() {
        if let m = hotkeyMonitor { NSEvent.removeMonitor(m) }
        hotkeyMonitor = nil
    }

    private func removeEventTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        tapSource = nil
        removeHotkey()
    }
}

// MARK: - UI

struct MergeView: View {
    @ObservedObject var ctrl: MergeController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.split.2x1")
                Text("ScreenMerge").font(.headline)
            }

            Text(ctrl.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if ctrl.active {
                HStack {
                    Image(systemName: ctrl.cursorLocked ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(ctrl.cursorLocked ? .orange : .green)
                    Text(ctrl.cursorLocked ? "Cursor preso (Ctrl+Shift+Esc libera)" : "Cursor livre (Ctrl+Shift+Esc prende)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button { ctrl.cursorLocked.toggle() } label: {
                    Label(ctrl.cursorLocked ? "Liberar Cursor" : "Prender Cursor",
                          systemImage: ctrl.cursorLocked ? "lock.open" : "lock")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)

                Button(role: .destructive) { ctrl.toggle() } label: {
                    Label("Desativar Merge", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Junta dois monitores 1920x1080 em um display virtual de 3840x1080.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Requer: BetterDisplay (gratis), Gravacao de Tela e Acessibilidade.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button { ctrl.toggle() } label: {
                    Label("Ativar Merge", systemImage: "rectangle.split.2x1")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Button("Sair") {
                Task {
                    await ctrl.deactivate()
                    try? await Task.sleep(for: .seconds(0.5))
                    NSApp.terminate(nil)
                }
            }
            .controlSize(.small)
            .foregroundStyle(.red)
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var controller: MergeController!

    @MainActor
    func applicationDidFinishLaunching(_ note: Notification) {
        controller = MergeController()

        // Auto-activate if launched with --activate
        let autoActivate = CommandLine.arguments.contains("--activate")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "rectangle.split.2x1",
                                accessibilityDescription: "ScreenMerge")
            btn.action = #selector(togglePopover)
            btn.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 280)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MergeView(ctrl: controller))

        if autoActivate {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                controller.toggle()
            }
        }
    }

    @objc func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        BD.discardSync()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
