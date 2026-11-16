// Écran Cassé — quand Claude a répondu et que personne ne touche l'ordinateur depuis X secondes,
// un bonhomme vient casser l'écran. Il se répare dès que la souris ou le clavier bouge.
import Cocoa
import WebKit
import ScreenCaptureKit
import IOKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var panel: OverlayPanel!
    private var web: WKWebView!
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var captureItem: NSMenuItem!
    private var delayItems: [NSMenuItem] = []
    private var pageReady = false

    private var showActive = false
    private var showStartedAt = Date()
    private var isDemo = false
    private var jsPhase = "idle"
    private var handledStamp: Double = 0
    private var sounds: [String: NSSound] = [:]
    private var playing: [NSSound] = []

    private let defaults = UserDefaults.standard
    private let home = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/ecran-casse")
    private var waitingDir: String { (home as NSString).appendingPathComponent("waiting") }
    private var demoFlag: String { (home as NSString).appendingPathComponent("demo") }
    private var logPath: String { (home as NSString).appendingPathComponent("ecran.log") }

    private var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }
    private var soundOn: Bool {
        get { defaults.object(forKey: "sound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sound") }
    }
    private var delay: Int {
        get { let v = defaults.integer(forKey: "delay"); return v > 0 ? v : 30 }
        set { defaults.set(newValue, forKey: "delay") }
    }

    // MARK: - Démarrage

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: waitingDir, withIntermediateDirectories: true)
        let frame = currentScreen().frame

        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar            // au-dessus des fenêtres, du Dock et de la barre des menus
        panel.ignoresMouseEvents = true      // les clics traversent toujours
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "ecran")
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        panel.contentView = web
        if let url = Bundle.main.url(forResource: "overlay", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        for name in ["knock", "whoosh", "punch", "crack", "shatter"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
                sounds[name] = NSSound(contentsOf: url, byReference: false)
            }
        }

        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        log("démarrage, délai \(delay) s, capture \(CGPreflightScreenCaptureAccess() ? "autorisée" : "non autorisée")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
    }

    // MARK: - Messages venant de l'animation

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let value = body["value"] as? String ?? ""
        switch type {
        case "sfx":
            if soundOn { play(value) }
        case "phase":
            jsPhase = value
            if value == "done" {
                showActive = false
                isDemo = false
                log("fin du spectacle")
            }
        default:
            break
        }
    }

    private func play(_ name: String) {
        playing.removeAll { !$0.isPlaying }
        guard let s = sounds[name]?.copy() as? NSSound else { return }
        s.volume = 1.0
        s.play()
        playing.append(s)
    }

    // MARK: - Boucle

    private func tick() {
        guard pageReady else { return }
        let fm = FileManager.default
        let idle = systemIdleSeconds()

        if fm.fileExists(atPath: demoFlag) {
            try? fm.removeItem(atPath: demoFlag)
            if !showActive { startShow(demo: true, waited: 34) }
            return
        }

        if showActive {
            if Date().timeIntervalSince(showStartedAt) > 900 {   // garde-fou
                js("ecran.reset()")
                showActive = false
                return
            }
            let cancellable = isDemo ? jsPhase == "broken"
                                     : ["attack", "shattering", "broken"].contains(jsPhase)
            let replied = !isDemo && newestWaiting() == nil
            if cancellable && (idle < 1.0 || replied) { js("ecran.userBack()") }
            return
        }

        followScreen()
        guard !paused, !screenLocked(), let newest = newestWaiting() else { return }
        let now = Date().timeIntervalSince1970
        let d = Double(delay)
        if newest > handledStamp && now - newest >= d && idle >= d {
            handledStamp = newest
            startShow(demo: false, waited: now - newest)
        }
    }

    private func startShow(demo: Bool, waited: Double) {
        isDemo = demo
        showActive = true
        showStartedAt = Date()
        jsPhase = "attack"
        followScreen()
        log(demo ? "démo" : "attaque : Claude attend depuis \(Int(waited)) s")
        Task { @MainActor in
            let shot = await self.captureScreen()
            self.js(shot.map { "ecran.setShot('\($0)')" } ?? "ecran.setShot(null)")
            self.js("ecran.trigger(\(Int(waited)))")
        }
    }

    /// Moment de la réponse de Claude la plus récente encore sans réponse, ou nil.
    private func newestWaiting() -> Double? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: waitingDir) else { return nil }
        let now = Date().timeIntervalSince1970
        var newest: Double?
        for name in names where !name.hasPrefix(".") {
            let path = (waitingDir as NSString).appendingPathComponent(name)
            let text = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let t = Double(text) else { try? fm.removeItem(atPath: path); continue }
            if now - t > 12 * 3600 { try? fm.removeItem(atPath: path); continue }
            newest = max(newest ?? t, t)
        }
        return newest
    }

    /// Secondes depuis le dernier mouvement de souris ou appui sur une touche.
    private func systemIdleSeconds() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let ns = dict["HIDIdleTime"] as? NSNumber else { return 0 }
        return ns.doubleValue / 1_000_000_000
    }

    private func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func followScreen() {
        let frame = currentScreen().frame
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Photo de l'écran (sans cette fenêtre) pour en faire tomber de vrais morceaux.
    private func captureScreen() async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let screen = panel.screen ?? currentScreen()
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == num.uint32Value }) else { return nil }
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
            return "data:image/jpeg;base64," + data.base64EncodedString()
        } catch {
            log("capture impossible : \(error.localizedDescription)")
            return nil
        }
    }

    private func js(_ code: String) {
        web.evaluateJavaScript(code, completionHandler: nil)
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile()
        } else {
            try? text.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Menu (icône 🔨 dans la barre des menus)

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔨"
        let menu = NSMenu()
        let title = NSMenuItem(title: "Écran Cassé", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("Lancer la démo (dans 3 s)", #selector(runDemo)))
        pauseItem = item("En pause", #selector(togglePause))
        menu.addItem(pauseItem)
        soundItem = item("Son", #selector(toggleSound))
        menu.addItem(soundItem)

        let delayMenu = NSMenu()
        for s in [15, 30, 60, 120] {
            let it = item(s < 60 ? "\(s) secondes" : "\(s / 60) minute\(s >= 120 ? "s" : "")", #selector(chooseDelay(_:)))
            it.tag = s
            delayMenu.addItem(it)
            delayItems.append(it)
        }
        let delayParent = NSMenuItem(title: "Casser l'écran après…", action: nil, keyEquivalent: "")
        delayParent.submenu = delayMenu
        menu.addItem(delayParent)

        captureItem = item("Vrais morceaux d'écran : autoriser…", #selector(askCapture))
        menu.addItem(captureItem)
        menu.addItem(item("Réparer l'écran maintenant", #selector(repairNow)))
        menu.addItem(.separator())
        menu.addItem(item("Quitter", #selector(quit), key: "q"))
        statusItem.menu = menu
        refreshMenu()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func refreshMenu() {
        pauseItem.state = paused ? .on : .off
        soundItem.state = soundOn ? .on : .off
        delayItems.forEach { $0.state = $0.tag == delay ? .on : .off }
        captureItem.isHidden = CGPreflightScreenCaptureAccess()
    }

    @objc private func runDemo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.showActive else { return }
            self.startShow(demo: true, waited: 34)
        }
    }

    @objc private func togglePause() { paused.toggle(); refreshMenu() }
    @objc private func toggleSound() { soundOn.toggle(); refreshMenu() }
    @objc private func chooseDelay(_ sender: NSMenuItem) { delay = sender.tag; refreshMenu() }

    @objc private func askCapture() {
        // Affiche la demande de macOS ; c'est la personne qui décide dans Réglages Système.
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refreshMenu()
    }

    @objc private func repairNow() {
        js("ecran.reset()")
        showActive = false
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
