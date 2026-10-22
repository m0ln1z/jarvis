// Jarvis HUD: an arc-reactor style circle on top of the screen showing what Jarvis is doing,
// plus a menu bar icon with controls.
// Reads commands from a FIFO, one per line: "<state>\t<text>", state = listening | thinking | speaking | hide.
// Talks back to Jarvis through files next to the FIFO: .trigger (listen now), .paused (ignore claps),
// .cancel (stop whatever Jarvis is doing — a click on the circle).
// Build: swiftc -O hud.swift -o JarvisHUD
import AppKit
import Carbon
import QuartzCore

let W: CGFloat = 560, H: CGFloat = 190, D: CGFloat = 110  // window size, circle diameter

/// The circle itself: clickable, shows ✕ on hover.
final class ReactorView: NSView {
    var onClick: () -> Void = {}
    let cross = CATextLayer()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { cross.opacity = 1 }
    override func mouseExited(with event: NSEvent) { cross.opacity = 0 }
}

final class HUD {
    let panel: NSPanel      // the circle: takes clicks
    let textPanel: NSPanel  // caption under it: clicks pass through
    let reactor = CALayer()
    let glow = CAShapeLayer(), ring = CAShapeLayer(), arc = CAShapeLayer(), arc2 = CAShapeLayer()
    let core = CAShapeLayer(), inner = CAShapeLayer()
    let label = NSTextField(labelWithString: "")
    var shown = false
    var onCancel: () -> Void = {}

    static func makePanel(_ rect: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.alphaValue = 0
        return p
    }

    init() {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let side = D + 16
        panel = HUD.makePanel(NSRect(x: vf.midX - side / 2, y: vf.maxY - side - 2, width: side, height: side))
        textPanel = HUD.makePanel(NSRect(x: vf.midX - W / 2, y: vf.maxY - H - 8, width: W, height: H - side))
        textPanel.ignoresMouseEvents = true

        let view = ReactorView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.wantsLayer = true
        view.toolTip = "Нажмите, чтобы остановить Джарвиса"
        view.onClick = { [unowned self] in self.onCancel() }
        panel.contentView = view

        reactor.frame = CGRect(x: 8, y: 8, width: D, height: D)
        view.layer!.addSublayer(reactor)
        func circle(_ layer: CAShapeLayer, inset: CGFloat) {
            layer.frame = reactor.bounds
            layer.path = CGPath(ellipseIn: reactor.bounds.insetBy(dx: inset, dy: inset), transform: nil)
            layer.fillColor = nil
            reactor.addSublayer(layer)
        }
        let backdrop = CAShapeLayer()  // dark disc so the reactor reads on light backgrounds too
        circle(backdrop, inset: 2)
        backdrop.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        circle(glow, inset: 22)
        glow.shadowRadius = 22
        glow.shadowOpacity = 1
        glow.shadowOffset = .zero
        circle(ring, inset: 6)
        ring.lineWidth = 3
        ring.lineDashPattern = [10, 7]
        circle(arc, inset: 14)
        arc.lineWidth = 4
        arc.strokeEnd = 0.28
        arc.lineCap = .round
        circle(arc2, inset: 14)
        arc2.lineWidth = 4
        arc2.strokeStart = 0.5
        arc2.strokeEnd = 0.72
        arc2.lineCap = .round
        circle(inner, inset: 26)
        inner.lineWidth = 2
        circle(core, inset: 38)

        // ✕ over the core on hover
        let cross = view.cross
        cross.string = "✕"
        cross.fontSize = 30
        cross.alignmentMode = .center
        cross.foregroundColor = NSColor.white.cgColor
        cross.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        cross.frame = CGRect(x: 8, y: 8 + D / 2 - 19, width: D, height: 38)
        cross.opacity = 0
        view.layer!.addSublayer(cross)

        let textView = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H - side))
        textPanel.contentView = textView
        label.frame = NSRect(x: 10, y: 4, width: W - 20, height: H - side - 10)
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = true
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 6
        label.shadow = shadow
        textView.addSubview(label)
    }

    func spin(_ layer: CALayer, _ seconds: Double, reverse: Bool = false) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = (reverse ? 1 : -1) * Double.pi * 2
        a.duration = seconds
        a.repeatCount = .infinity
        layer.add(a, forKey: "spin")
    }

    func pulse(_ layer: CALayer, _ seconds: Double, scale: CGFloat) {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1
        a.toValue = scale
        a.duration = seconds
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "pulse")
    }

    func apply(_ state: String, _ text: String) {
        if state == "hide" {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                panel.animator().alphaValue = 0
                textPanel.animator().alphaValue = 0
            }, completionHandler: {
                if !self.shown { self.panel.orderOut(nil); self.textPanel.orderOut(nil) }
            })
            shown = false
            return
        }
        let color: NSColor
        switch state {
        case "thinking": color = NSColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 1)
        case "speaking": color = NSColor(red: 0.62, green: 0.95, blue: 1.0, alpha: 1)
        default: color = NSColor(red: 0.30, green: 0.82, blue: 1.0, alpha: 1)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        for l in [ring, arc, arc2, inner] { l.strokeColor = color.cgColor }
        core.fillColor = color.withAlphaComponent(0.9).cgColor
        glow.fillColor = color.withAlphaComponent(0.35).cgColor
        glow.shadowColor = color.cgColor
        arc.opacity = state == "thinking" ? 1 : 0
        arc2.opacity = state == "thinking" ? 1 : 0
        CATransaction.commit()

        switch state {
        case "thinking":
            spin(ring, 3.0); spin(arc, 0.9); spin(arc2, 1.4, reverse: true)
            pulse(core, 0.5, scale: 1.15); pulse(glow, 0.5, scale: 1.1)
        case "speaking":
            spin(ring, 5.0)
            pulse(core, 0.22, scale: 1.35); pulse(glow, 0.22, scale: 1.25)
        default:  // listening
            spin(ring, 7.0)
            pulse(core, 1.1, scale: 1.2); pulse(glow, 1.1, scale: 1.15)
        }
        if !text.isEmpty || state == "listening" { label.stringValue = text }
        if !shown {
            shown = true
            panel.orderFrontRegardless()
            textPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 1
                textPanel.animator().alphaValue = 1
            }
        }
    }
}

// ---------- menu bar icon ----------

final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let status = NSMenuItem(title: "Спит", action: nil, keyEquivalent: "")
    let pause = NSMenuItem(title: "Пауза — выключить микрофон", action: #selector(togglePause), keyEquivalent: "")
    let dir: String
    let label = "gui/\(getuid())/com.jarvis.voice"

    init(dir: String) {
        self.dir = dir
        super.init()
        status.isEnabled = false
        menu.addItem(withTitle: "Джарвис", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add("Слушать  (\(hotkeyName) — из любого приложения)", #selector(listen), "")
        add("Отменить — замолчать и уснуть  (\(hotkeyName) ещё раз)", #selector(cancel), "")
        add("Остановить Claude в текущем проекте", #selector(stopClaude), "")
        menu.addItem(pause)
        pause.target = self
        menu.addItem(.separator())
        add("Настройки…", #selector(settings), ",")
        add("Лог", #selector(showLog), "")
        add("Перезапустить", #selector(restart), "")
        add("Выключить до следующего входа", #selector(quit), "")
        item.menu = menu
        menu.delegate = self
        pause.state = FileManager.default.fileExists(atPath: dir + "/.paused") ? .on : .off
        set("hide")
    }

    func add(_ title: String, _ action: Selector, _ key: String) {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    /// Small reactor: outline when asleep, colored when busy.
    func icon(_ color: NSColor?) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let c = color ?? .black
            c.setStroke()
            let outer = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            outer.lineWidth = 1.6
            outer.setLineDash([2.6, 1.6], count: 2, phase: 0)
            outer.stroke()
            let inner = NSBezierPath(ovalIn: r.insetBy(dx: 5, dy: 5))
            inner.lineWidth = 1.4
            inner.stroke()
            c.withAlphaComponent(color == nil ? 0.9 : 1).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 7.3, dy: 7.3)).fill()
            return true
        }
        img.isTemplate = color == nil  // asleep: follows the menu bar's light/dark look
        return img
    }

    func set(_ state: String) {
        let paused = pause.state == .on
        switch state {
        case "listening": item.button?.image = icon(NSColor(red: 0.30, green: 0.82, blue: 1.0, alpha: 1)); status.title = "Слушает…"
        case "thinking": item.button?.image = icon(NSColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 1)); status.title = "Думает…"
        case "speaking": item.button?.image = icon(NSColor(red: 0.62, green: 0.95, blue: 1.0, alpha: 1)); status.title = "Говорит…"
        default: item.button?.image = icon(nil); status.title = paused ? "На паузе" : "Спит — двойной хлопок и пароль"
        }
        item.button?.alphaValue = paused && state == "hide" ? 0.45 : 1
    }

    func menuWillOpen(_ menu: NSMenu) {  // the pause file may have been changed elsewhere
        pause.state = FileManager.default.fileExists(atPath: dir + "/.paused") ? .on : .off
    }

    @objc func listen() { FileManager.default.createFile(atPath: dir + "/.trigger", contents: nil) }
    @objc func cancel() { FileManager.default.createFile(atPath: dir + "/.cancel", contents: nil); hud.apply("hide", "") }
    @objc func stopClaude() { run(dir + "/jarvisctl", ["stop", "current"]) }

    @objc func togglePause() {
        let path = dir + "/.paused"
        if pause.state == .on {
            try? FileManager.default.removeItem(atPath: path)
            pause.state = .off
        } else {
            FileManager.default.createFile(atPath: path, contents: nil)
            pause.state = .on
        }
        set("hide")
    }

    @objc func settings() { run("/usr/bin/open", ["-t", dir + "/config.json"]) }
    @objc func showLog() { run("/usr/bin/open", ["-a", "Console", dir + "/jarvis.log"]) }
    @objc func restart() { run("/bin/launchctl", ["kickstart", "-k", label]) }
    @objc func quit() { run("/bin/launchctl", ["bootout", label]) }

    func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
}

// ---------- global hotkey (default ⌥J): listen, or stop if Jarvis is busy ----------

func readHotkey(_ dir: String) -> String {
    guard let data = FileManager.default.contents(atPath: dir + "/config.json"),
          let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hk = cfg["hotkey"] as? String else { return "alt+j" }
    return hk.lowercased()
}

let keyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
    "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
    "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "space": kVK_Space, "return": kVK_Return, "escape": kVK_Escape,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
]

/// "alt+j" -> (key code, Carbon modifiers, "⌥J")
func parseHotkey(_ s: String) -> (UInt32, UInt32, String)? {
    var mods: UInt32 = 0, name = "", code: Int? = nil
    for part in s.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        switch part {
        case "cmd", "command": mods |= UInt32(cmdKey); name += "⌘"
        case "alt", "option", "opt": mods |= UInt32(optionKey); name += "⌥"
        case "ctrl", "control": mods |= UInt32(controlKey); name += "⌃"
        case "shift": mods |= UInt32(shiftKey); name += "⇧"
        default: code = keyCodes[part]; name += part == "space" ? "Space" : part.uppercased()
        }
    }
    guard let c = code else { return nil }
    return (UInt32(c), mods, name)
}

var hotkeyName = "⌥J"
var hotkeyRef: EventHotKeyRef?
var onHotkey: () -> Void = {}

func registerHotkey(_ spec: String) {
    guard let (code, mods, name) = parseHotkey(spec) else { return }
    hotkeyName = name
    var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in onHotkey(); return noErr }, 1, &type, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x4A52_5653), id: 1)  // 'JRVS'
    let status = RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &hotkeyRef)
    let msg = status == noErr ? "горячая клавиша \(name) готова" : "горячая клавиша \(name) занята другим приложением (\(status))"
    FileHandle.standardError.write("HUD: \(msg)\n".data(using: .utf8)!)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, never takes focus
let hud = HUD()

let fifo = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSHomeDirectory() + "/jarvis/.hud"
let jarvisDir = (fifo as NSString).deletingLastPathComponent
registerHotkey(readHotkey(jarvisDir))
let bar = MenuBar(dir: jarvisDir)
hud.onCancel = { bar.cancel() }
onHotkey = { if hud.shown { bar.cancel() } else { bar.listen() } }
Thread {
    let fd = open(fifo, O_RDWR)  // read+write: a FIFO opened like this never hits EOF between writers
    guard fd >= 0, let f = fdopen(fd, "r") else { exit(1) }
    var line: UnsafeMutablePointer<CChar>? = nil
    var cap = 0
    while getline(&line, &cap, f) > 0 {
        let parts = String(cString: line!).trimmingCharacters(in: .newlines)
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let state = parts.first ?? "hide", text = parts.count > 1 ? parts[1] : ""
        DispatchQueue.main.async { hud.apply(state, text); bar.set(state) }
    }
}.start()

// quit when Jarvis (the parent process) is gone
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in if getppid() == 1 { exit(0) } }
app.run()
