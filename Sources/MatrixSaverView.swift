// Matrix screensaver pour macOS.
// Port Swift de l'effet « matrix » de TerminalTextEffects (TTE, licence MIT,
// github.com/ChrisBuilds/terminaltexteffects), l'effet utilisé par le
// screensaver d'Omarchy. Pluie numérique → remplissage → résolution du logo.

import AppKit
import CoreText
import ScreenSaver

// MARK: - Réglages (valeurs par défaut de TTE)

private enum Cfg {
    static let fps: Double = 60
    static let ticksPerFrame = 2          // 2 × 60 = 120 ticks/s, comme « tte --frame-rate 120 »
    static let fontName = "JetBrainsMonoNL Nerd Font Mono"   // repli : Menlo
    static let maxFontSize: CGFloat = 18                     // comme le terminal d'Omarchy
    static let highlight = RGB(0xDBFFDB)
    static let rainStops = (RGB(0x92BE92), RGB(0x185318))
    static let finalStops = (RGB(0x92BE92), RGB(0x336B33))
    static let finalSteps = 12
    static let rainFallDelay = 2...15
    static let rainColumnDelay = 3...9
    static let rainTime: TimeInterval = 15
    static let symbolSwapChance = 0.005
    static let colorSwapChance = 0.001
    static let resolveDelay = 3
    static let resolveFrames = 3        // frames par pas du dégradé de résolution
    static let holdLogo: TimeInterval = 10  // durée d'affichage du logo avant de reboucler
    static let symbols: [Character] = Array("2598Z*):.\"=+-¦|_ｦｱｳｴｵｶｷｹｺｻｼｽｾｿﾀﾂﾃﾅﾆﾇﾈﾊﾋﾎﾏﾐﾑﾒﾓﾔﾕﾗﾘﾜ")
}

// MARK: - Couleurs

struct RGB: Hashable {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ hex: UInt32) { r = UInt8(hex >> 16 & 0xFF); g = UInt8(hex >> 8 & 0xFF); b = UInt8(hex & 0xFF) }
    init(r: Double, g: Double, b: Double) {
        func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        self.r = c(r); self.g = c(g); self.b = c(b)
    }
    func scaled(_ f: Double) -> RGB { RGB(r: Double(r) * f, g: Double(g) * f, b: Double(b) * f) }
    static func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(r: Double(a.r) + (Double(b.r) - Double(a.r)) * t,
            g: Double(a.g) + (Double(b.g) - Double(a.g)) * t,
            b: Double(a.b) + (Double(b.b) - Double(a.b)) * t)
    }
    var cg: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
}

private func gradient(_ a: RGB, _ b: RGB, steps: Int) -> [RGB] {
    (0...steps).map { RGB.lerp(a, b, Double($0) / Double(steps)) }
}

// MARK: - Modèle

final class MChar {
    let col: Int, inRow: Int
    var row: Int
    let input: Int              // index du symbole d'origine (logo ou espace)
    let inputIsSpace: Bool
    var sym = 0
    var color = Cfg.highlight
    var visible = false
    var finalColor = Cfg.finalStops.0
    var scene: [RGB]? = nil     // dégradé de résolution en cours
    var sceneTick = 0
    init(col: Int, row: Int, input: Int, isSpace: Bool) {
        self.col = col; inRow = row; self.row = row; self.input = input; inputIsSpace = isSpace
    }
}

final class RainColumn {
    enum Phase { case rain, fill }
    let chars: [MChar]          // de haut en bas
    unowned let engine: MatrixEngine
    var pending: [MChar] = []
    var visible: [MChar] = []
    var phase = Phase.rain
    var isFull = false
    var baseDelay = 0, activeDelay = 0, length = 0, holdTime = 0
    var dropChance = 0.08

    init(chars: [MChar], engine: MatrixEngine) {
        self.chars = chars; self.engine = engine
        setup(.rain)
    }

    func setup(_ p: Phase) {
        phase = p; isFull = false
        pending = chars
        for c in chars { c.visible = false; c.row = c.inRow }
        visible.removeAll(keepingCapacity: true)
        let r = Cfg.rainFallDelay
        baseDelay = p == .fill ? Int.random(in: max(r.lowerBound / 3, 1)...max(r.upperBound / 3, 1))
                               : Int.random(in: r)
        activeDelay = 0
        length = p == .rain ? Int.random(in: max(1, chars.count / 10)...chars.count) : chars.count
        holdTime = length == chars.count ? Int.random(in: 20...45) : 0
    }

    private func trim() {
        guard !visible.isEmpty else { return }
        visible.removeFirst().visible = false
        if visible.count > 1 { visible[0].color = engine.rainColors.suffix(3).randomElement()!.scaled(0.65) }
    }

    private func drop() {
        visible = visible.filter { c in
            c.row += 1
            if c.row >= engine.rows { c.visible = false; return false }
            return true
        }
    }

    func resolveChar() -> MChar { visible.remove(at: Int.random(in: 0..<visible.count)) }

    func tick() {
        if activeDelay == 0 {
            if !pending.isEmpty {
                let next = pending.removeFirst()
                next.sym = engine.randomRainSymbol()
                next.color = Cfg.highlight
                visible.last?.color = engine.rainColors.randomElement()!
                next.visible = true
                visible.append(next)
            } else if !visible.isEmpty {
                if visible.last!.color == Cfg.highlight { visible.last!.color = engine.rainColors.randomElement()! }
                if holdTime > 0 { holdTime -= 1 }
                else if phase == .rain {
                    if Double.random(in: 0..<1) < dropChance { drop() }
                    trim()
                }
            }
            if visible.count > length { trim() }
            activeDelay = baseDelay
        } else {
            activeDelay -= 1
        }
        for c in visible {
            if Double.random(in: 0..<1) < Cfg.symbolSwapChance { c.sym = engine.randomRainSymbol() }
            if Double.random(in: 0..<1) < Cfg.colorSwapChance { c.color = engine.rainColors.randomElement()! }
        }
    }
}

final class MatrixEngine {
    enum Phase { case rain, fill, resolve, done }
    let cols: Int, rows: Int
    var chars: [MChar] = []
    let rainColors = gradient(Cfg.rainStops.0, Cfg.rainStops.1, steps: 6)
    let rainSymbolIDs: [Int]
    var pending: [RainColumn] = [], active: [RainColumn] = [], full: [RainColumn] = []
    var resolving: [MChar] = []
    var phase = Phase.rain
    var columnDelay = 0, resolveDelay = Cfg.resolveDelay
    var rainStart = Date()
    var doneAt: Date? = nil

    func randomRainSymbol() -> Int { rainSymbolIDs.randomElement()! }

    init(cols: Int, rows: Int, logo: [[Character]], symbolID: (Character) -> Int) {
        self.cols = cols; self.rows = rows
        rainSymbolIDs = Cfg.symbols.map(symbolID)
        let space = symbolID(" ")
        let logoH = logo.count, logoW = logo.map(\.count).max() ?? 0
        let top = (rows - logoH) / 2, left = (cols - logoW) / 2
        // Dégradé final radial, comme TTE (rangées comptées double : cellules ~2:1)
        let finals = gradient(Cfg.finalStops.0, Cfg.finalStops.1, steps: Cfg.finalSteps)
        let cx = Double(logoW - 1) / 2, cy = Double(logoH - 1) / 2
        let maxD = max(1, (cx * cx + (cy * 2) * (cy * 2)).squareRoot())
        for col in 0..<cols {
            var colChars: [MChar] = []
            for row in 0..<rows {
                let lr = row - top, lc = col - left
                var ch: Character = " "
                if lr >= 0, lr < logoH, lc >= 0, lc < logo[lr].count { ch = logo[lr][lc] }
                let m = MChar(col: col, row: row, input: ch == " " ? space : symbolID(ch), isSpace: ch == " ")
                let dx = Double(lc) - cx, dy = (Double(lr) - cy) * 2
                let d = min(1, (dx * dx + dy * dy).squareRoot() / maxD)
                m.finalColor = finals[Int((d * Double(Cfg.finalSteps)).rounded())]
                chars.append(m); colChars.append(m)
            }
            pending.append(RainColumn(chars: colChars, engine: self))
        }
        pending.shuffle()
    }

    func step() {
        switch phase {
        case .rain, .fill:
            if columnDelay == 0 {
                if phase == .rain {
                    for _ in 0..<Int.random(in: 1...3) where !pending.isEmpty { active.append(pending.removeFirst()) }
                    columnDelay = Int.random(in: Cfg.rainColumnDelay)
                } else {
                    active.append(contentsOf: pending); pending.removeAll()
                    columnDelay = 1
                }
            } else { columnDelay -= 1 }

            for col in active {
                col.tick()
                if col.pending.isEmpty {
                    if col.phase == .fill && !col.isFull { full.append(col); col.isFull = true }
                    else if col.visible.isEmpty { col.setup(phase == .fill ? .fill : .rain); pending.append(col) }
                }
            }
            active.removeAll { $0.visible.isEmpty }

            if phase == .fill, pending.isEmpty, active.allSatisfy({ $0.pending.isEmpty && $0.phase == .fill }) {
                phase = .resolve; active.removeAll()
            }
            if phase == .rain, Date().timeIntervalSince(rainStart) > Cfg.rainTime {
                phase = .fill
                for col in active { col.holdTime = 0; col.dropChance = 1 }
                for col in pending { col.setup(.fill) }
            }

        case .resolve:
            for col in full {
                col.tick()
                guard !col.visible.isEmpty else { continue }
                if resolveDelay == 0 {
                    for _ in 0..<Int.random(in: 1...4) where !col.visible.isEmpty {
                        let c = col.resolveChar()
                        if c.inputIsSpace { c.visible = false }
                        else {
                            c.sym = c.input
                            c.scene = gradient(Cfg.highlight, c.finalColor, steps: 8)
                            c.sceneTick = 0
                            resolving.append(c)
                        }
                    }
                    resolveDelay = Cfg.resolveDelay
                } else { resolveDelay -= 1 }
            }
            full.removeAll { $0.visible.isEmpty }
            if full.isEmpty && resolving.isEmpty { phase = .done; doneAt = Date() }

        case .done:
            break
        }

        // Animation des caractères en cours de résolution
        resolving.removeAll { c in
            guard let s = c.scene else { return true }
            let i = c.sceneTick / Cfg.resolveFrames
            if i >= s.count { c.color = c.finalColor; c.scene = nil; return true }
            c.color = s[i]; c.sceneTick += 1
            return false
        }
    }
}

// MARK: - Glyphes

private enum Block { case full, upper, lower, left, right }

private struct Glyph {
    var block: Block? = nil
    var font = 0
    var glyph: CGGlyph = 0
    var dx: CGFloat = 0     // centrage horizontal dans la cellule
}

// MARK: - Vue

@objc(MatrixSaverView)
final class MatrixSaverView: ScreenSaverView {
    private var engine: MatrixEngine?
    private var fonts: [CTFont] = []
    private var glyphs: [Glyph] = []
    private var symbolIndex: [Character: Int] = [:]
    private var baseFont: CTFont!
    private var cellW: CGFloat = 0, cellH: CGFloat = 0, baseline: CGFloat = 0
    private var origin = CGPoint.zero
    private var builtFor = CGSize.zero
    private var stopObserver: NSObjectProtocol?

    private lazy var logo: [[Character]] = {
        let url = Bundle(for: MatrixSaverView.self).url(forResource: "logo", withExtension: "txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var lines = text.components(separatedBy: "\n").map { Array($0) }
        while lines.last?.allSatisfy({ $0 == " " }) == true { lines.removeLast() }
        return lines
    }()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1 / Cfg.fps
        wantsLayer = true
        // macOS 14+ : legacyScreenSaver ne libère pas les instances → on quitte proprement.
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            if self?.isPreview == false { exit(0) }
        }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit { if let o = stopObserver { DistributedNotificationCenter.default().removeObserver(o) } }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    private func symbolID(_ ch: Character) -> Int {
        if let i = symbolIndex[ch] { return i }
        var g = Glyph()
        switch ch {
        case "█": g.block = .full
        case "▀": g.block = .upper
        case "▄": g.block = .lower
        case "▌": g.block = .left
        case "▐": g.block = .right
        default:
            let s = String(ch) as CFString
            let f = CTFontCreateForString(baseFont, s, CFRange(location: 0, length: CFStringGetLength(s)))
            var utf16 = Array(String(ch).utf16)
            var gl = [CGGlyph](repeating: 0, count: utf16.count)
            CTFontGetGlyphsForCharacters(f, &utf16, &gl, utf16.count)
            let name = CTFontCopyPostScriptName(f) as String
            if let fi = fonts.firstIndex(where: { CTFontCopyPostScriptName($0) as String == name }) { g.font = fi }
            else { fonts.append(f); g.font = fonts.count - 1 }
            g.glyph = gl[0]
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(f, .horizontal, &g.glyph, &adv, 1)
            g.dx = (cellW - adv.width) / 2
        }
        glyphs.append(g)
        symbolIndex[ch] = glyphs.count - 1
        return glyphs.count - 1
    }

    private func rebuild() {
        let size = bounds.size
        guard size.width > 10, size.height > 10 else { return }
        builtFor = size
        let logoW = CGFloat(max(1, logo.map(\.count).max() ?? 1))
        let logoH = CGFloat(max(1, logo.count))

        // Métriques à 1 pt puis mise à l'échelle pour que le logo tienne (preview incluse)
        let probe = CTFontCreateWithName(Cfg.fontName as CFString, 1, nil)
        let isJB = (CTFontCopyFamilyName(probe) as String).lowercased().contains("jetbrains")
        let unit = isJB ? probe : CTFontCreateWithName("Menlo-Regular" as CFString, 1, nil)
        var mGlyph: CGGlyph = 0; var m: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(unit, &m, &mGlyph, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(unit, .horizontal, &mGlyph, &adv, 1)
        let lineUnit = CTFontGetAscent(unit) + CTFontGetDescent(unit) + CTFontGetLeading(unit)
        let fontSize = min(Cfg.maxFontSize,
                           size.width / ((logoW + 4) * adv.width),
                           size.height / ((logoH + 4) * lineUnit))

        baseFont = CTFontCreateCopyWithAttributes(unit, fontSize, nil, nil)
        cellW = adv.width * fontSize
        cellH = (lineUnit * fontSize).rounded(.up)
        let asc = CTFontGetAscent(baseFont), desc = CTFontGetDescent(baseFont)
        baseline = desc + (cellH - asc - desc) / 2

        fonts = []; glyphs = []; symbolIndex = [:]
        let cols = Int(size.width / cellW), rows = Int(size.height / cellH)
        origin = CGPoint(x: (size.width - CGFloat(cols) * cellW) / 2,
                         y: (size.height - CGFloat(rows) * cellH) / 2)
        engine = MatrixEngine(cols: cols, rows: rows, logo: logo, symbolID: symbolID)
    }

    override func startAnimation() {
        super.startAnimation()
        rebuild()
    }

    override func animateOneFrame() {
        if bounds.size != builtFor { rebuild() }
        guard let e = engine else { return }
        for _ in 0..<Cfg.ticksPerFrame { e.step() }
        if e.phase == .done, let t = e.doneAt, Date().timeIntervalSince(t) > Cfg.holdLogo { rebuild() }
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(bounds)
        guard let e = engine else { return }

        struct Batch { var rects: [CGRect] = []; var runs: [Int: ([CGGlyph], [CGPoint])] = [:] }
        var batches: [RGB: Batch] = [:]
        let rows = e.rows
        for c in e.chars where c.visible {
            let x = origin.x + CGFloat(c.col) * cellW
            let y = origin.y + CGFloat(rows - 1 - c.row) * cellH
            let g = glyphs[c.sym]
            if let b = g.block {
                let r: CGRect
                switch b {
                case .full:  r = CGRect(x: x, y: y, width: cellW, height: cellH)
                case .upper: r = CGRect(x: x, y: y + cellH / 2, width: cellW, height: cellH / 2)
                case .lower: r = CGRect(x: x, y: y, width: cellW, height: cellH / 2)
                case .left:  r = CGRect(x: x, y: y, width: cellW / 2, height: cellH)
                case .right: r = CGRect(x: x + cellW / 2, y: y, width: cellW / 2, height: cellH)
                }
                batches[c.color, default: Batch()].rects.append(r)
            } else {
                var run = batches[c.color, default: Batch()].runs[g.font] ?? ([], [])
                run.0.append(g.glyph)
                run.1.append(CGPoint(x: x + g.dx, y: y + baseline))
                batches[c.color, default: Batch()].runs[g.font] = run
            }
        }

        ctx.textMatrix = .identity
        for (color, batch) in batches {
            ctx.setFillColor(color.cg)
            if !batch.rects.isEmpty {
                ctx.setShouldAntialias(false)   // pas de jointures visibles entre blocs
                ctx.fill(batch.rects)
                ctx.setShouldAntialias(true)
            }
            for (fi, run) in batch.runs {
                run.0.withUnsafeBufferPointer { gs in
                    run.1.withUnsafeBufferPointer { ps in
                        CTFontDrawGlyphs(fonts[fi], gs.baseAddress!, ps.baseAddress!, gs.count, ctx)
                    }
                }
            }
        }
    }
}
