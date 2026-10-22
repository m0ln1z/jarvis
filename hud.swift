// Jarvis HUD: an arc-reactor style circle on top of the screen showing what Jarvis is doing.
// Reads commands from a FIFO, one per line: "<state>\t<text>", state = listening | thinking | speaking | hide.
// Build: swiftc -O hud.swift -o JarvisHUD
import AppKit
import QuartzCore

let W: CGFloat = 560, H: CGFloat = 190, D: CGFloat = 110  // window size, circle diameter

final class HUD {
    let panel: NSPanel
    let reactor = CALayer()
    let glow = CAShapeLayer(), ring = CAShapeLayer(), arc = CAShapeLayer(), arc2 = CAShapeLayer()
    let core = CAShapeLayer(), inner = CAShapeLayer()
    let label = NSTextField(labelWithString: "")
    var shown = false

    init() {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = NSPanel(contentRect: NSRect(x: vf.midX - W / 2, y: vf.maxY - H - 8, width: W, height: H),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0

        let view = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        view.wantsLayer = true
        panel.contentView = view

        reactor.frame = CGRect(x: (W - D) / 2, y: H - D - 6, width: D, height: D)
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

        label.frame = NSRect(x: 10, y: 4, width: W - 20, height: H - D - 18)
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
        view.addSubview(label)
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
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; panel.animator().alphaValue = 0 },
                                                 completionHandler: { if !self.shown { self.panel.orderOut(nil) } })
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
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 1 }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, never takes focus
let hud = HUD()

let fifo = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSHomeDirectory() + "/jarvis/.hud"
Thread {
    let fd = open(fifo, O_RDWR)  // read+write: a FIFO opened like this never hits EOF between writers
    guard fd >= 0, let f = fdopen(fd, "r") else { exit(1) }
    var line: UnsafeMutablePointer<CChar>? = nil
    var cap = 0
    while getline(&line, &cap, f) > 0 {
        let parts = String(cString: line!).trimmingCharacters(in: .newlines)
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let state = parts.first ?? "hide", text = parts.count > 1 ? parts[1] : ""
        DispatchQueue.main.async { hud.apply(state, text) }
    }
}.start()

// quit when Jarvis (the parent process) is gone
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in if getppid() == 1 { exit(0) } }
app.run()
