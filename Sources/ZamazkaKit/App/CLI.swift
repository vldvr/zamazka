import AppKit
import SwiftUI

/// Command-line modes for development and for the README pictures. All of them work on files
/// or synthetic images; none touch the clipboard or the screenshot folders.
///   Zamazka --scan picture.png              findings, one per line
///   Zamazka --redact in.png out.png         hide every strong finding
///   Zamazka --snap card|applied|onboarding|settings out.png [light|dark]
///   Zamazka --hero out.png                  the 16:10 before/after picture
///   Zamazka --sample chat|screen|qr|plain out.png   an invented screenshot to try the app on
///   Zamazka --demo                          start normally and show the example card
enum CLI {
    @MainActor
    static func handle(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            scan(URL(fileURLWithPath: args[i + 1]), redactTo: nil)
            return true
        }
        if let i = args.firstIndex(of: "--redact"), i + 2 < args.count {
            scan(URL(fileURLWithPath: args[i + 1]), redactTo: URL(fileURLWithPath: args[i + 2]))
            return true
        }
        if let i = args.firstIndex(of: "--sample"), i + 2 < args.count {
            // Invented screenshots for trying the app: chat, screen, qr, plain.
            let image: CGImage
            switch args[i + 1] {
            case "screen": image = SyntheticImage.screen()
            case "qr": image = SyntheticImage.qr()
            case "plain": image = SyntheticImage.plain()
            default: image = SyntheticImage.chat()
            }
            try? ImageFile.png(image, dpi: 144)?.write(to: URL(fileURLWithPath: args[i + 2]))
            exit(0)
        }
        if args.contains("--snap") || args.contains("--hero") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            DispatchQueue.main.async { Snapshots.run(args) }
            app.run()
            return true
        }
        return false
    }

    private static func scan(_ url: URL, redactTo out: URL?) {
        guard let data = try? Data(contentsOf: url), let loaded = ImageFile.decode(data) else {
            FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
            exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let a = try await Detector.analyze(loaded.image, options: DetectorOptions(timeout: 90))
                for f in a.findings {
                    let r = f.bounds
                    print("\(f.kind.rawValue)\(f.weak ? " (weak)" : "")\t\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))\t\(f.text ?? "")")
                }
                print(String(format: "%.2fs", a.seconds))
                if let out, let cleaned = Redactor.render(loaded.image, rects: a.findings.filter(\.enabled).flatMap(\.rects), style: RedactStyle()),
                   let png = ImageFile.encode(cleaned, as: loaded.type, dpi: loaded.dpi) {
                    try png.write(to: out)
                    print("wrote \(out.path)")
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}

/// Renders the card, onboarding and settings to PNG without screen recording, and draws the
/// before/after picture for the site.
@MainActor
enum Snapshots {
    static func run(_ args: [String]) {
        if let i = args.firstIndex(of: "--hero"), i + 1 < args.count {
            hero(URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snap"), i + 2 < args.count else { exit(64) }
        let what = args[i + 1], out = URL(fileURLWithPath: args[i + 2])
        let dark = args.dropFirst(i + 3).first == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let view: NSView
        switch what {
        case "card", "applied":
            let session = demoSession()
            if what == "applied" {
                CaptureCenter.shared.apply(session)
            }
            view = NSHostingView(rootView: CardView(session: session, controller: CardController.shared, solid: true))
        case "onboarding":
            view = NSHostingView(rootView: OnboardingView(close: {}))
        case "settings":
            view = NSHostingView(rootView: SettingsView())
        default:
            exit(64)
        }
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            capture(view, to: out, dark: dark, floating: what == "card" || what == "applied")
            exit(0)
        }
    }

    /// The synthetic chat with findings, one switched off to show the dashed state.
    static func demoSession() -> Session {
        let image = SyntheticImage.chat(scale: 2)
        let data = ImageFile.png(image, dpi: 144)!
        let loaded = ImageFile.decode(data)!
        let session = Session(origin: .system, loaded: loaded, isDemo: false)
        session.add(.clipboard)
        let analysis = try? Detector.analyzeSync(image, options: DetectorOptions())
        session.findings = analysis?.findings ?? []
        if let i = session.findings.firstIndex(where: { $0.kind == .plate }) { session.findings[i].enabled = false }
        session.state = .review
        return session
    }

    private static func capture(_ view: NSView, to out: URL, dark: Bool, floating: Bool) {
        let content = view.bounds.size
        let pad: CGFloat = floating ? 36 : 0
        let size = CGSize(width: content.width + pad * 2, height: content.height + pad * 2)
        let scale: CGFloat = 2
        func bitmap(_ s: CGSize) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s.width * scale), pixelsHigh: Int(s.height * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = s
            return rep
        }
        let rendered = bitmap(content)
        view.cacheDisplay(in: view.bounds, to: rendered)
        let canvas = bitmap(size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        if floating {
            NSGradient(colors: dark ? [NSColor(hex: 0x23272D), NSColor(hex: 0x30363D)] : [NSColor(hex: 0xE9ECEF), NSColor(hex: 0xD6DBE0)])!
                .draw(in: NSRect(origin: .zero, size: size), angle: -70)
        }
        let frame = NSRect(x: pad, y: pad, width: content.width, height: content.height)
        if floating {
            let shape = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = CGSize(width: 0, height: -8)
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.22)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            // The card's own rounded edge; the snapshot of the view has square corners.
            shape.addClip()
        }
        rendered.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        try? canvas.representation(using: .png, properties: [:])?.write(to: out)
        print("wrote \(out.path)")
    }

    // MARK: - Before and after

    /// 2400×1500: the same chat twice, found data marked on the left and hidden on the right.
    static func hero(_ out: URL) {
        let W: CGFloat = 2400, H: CGFloat = 1500
        let shot = SyntheticImage.chat(scale: 2, width: 480)
        guard let analysis = try? Detector.analyzeSync(shot, options: DetectorOptions()) else { exit(1) }
        let findings = analysis.findings.filter(\.enabled)
        guard let cleaned = Redactor.render(shot, rects: findings.flatMap(\.rects), style: RedactStyle()) else { exit(1) }

        let ctx = SyntheticImage.bitmap(Int(W), Int(H))
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        NSColor(hex: 0x111317).setFill()
        CGRect(x: 0, y: 0, width: W, height: H).fill()

        let labelSpace: CGFloat = 96, gap: CGFloat = 120
        let k = min((H - 2 * 90 - labelSpace) / CGFloat(shot.height), (W - 2 * 140 - gap) / 2 / CGFloat(shot.width))
        let pw = CGFloat(shot.width) * k, ph = CGFloat(shot.height) * k
        let x0 = (W - 2 * pw - gap) / 2
        let top = (H - ph - labelSpace) / 2 + labelSpace
        let panels = [CGRect(x: x0, y: top, width: pw, height: ph), CGRect(x: x0 + pw + gap, y: top, width: pw, height: ph)]
        let labelY = top - labelSpace + 8

        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor(hex: 0xE6E8EB)]
        let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor(hex: 0x8A939D)]
        NSAttributedString(string: "До", attributes: label).draw(at: CGPoint(x: panels[0].minX, y: labelY))
        NSAttributedString(string: "Замазка нашла и отметила", attributes: sub).draw(at: CGPoint(x: panels[0].minX + 72, y: labelY + 7))
        NSAttributedString(string: "После", attributes: label).draw(at: CGPoint(x: panels[1].minX, y: labelY))
        NSAttributedString(string: "закрыто сплошной заливкой", attributes: sub).draw(at: CGPoint(x: panels[1].minX + 128, y: labelY + 7))

        for (i, panel) in panels.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 40
            shadow.shadowOffset = CGSize(width: 0, height: -14)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: panel, xRadius: 22, yRadius: 22).fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: panel, xRadius: 22, yRadius: 22).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: i == 0 ? shot : cleaned, size: panel.size).draw(in: panel)
            if i == 0 {
                for f in findings {
                    for r in f.rects {
                        let v = CGRect(x: panel.minX + r.minX * k, y: panel.minY + r.minY * k, width: r.width * k, height: r.height * k)
                        let path = NSBezierPath(roundedRect: v, xRadius: 5, yRadius: 5)
                        NSColor(hex: 0xFFC21A, alpha: 0.4).setFill()
                        path.fill()
                        NSColor(hex: 0xC98A00).setStroke()
                        path.lineWidth = 2.5
                        path.stroke()
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage(), let png = ImageFile.png(image) else { exit(1) }
        try? png.write(to: out)
        print("wrote \(out.path)")
    }
}
