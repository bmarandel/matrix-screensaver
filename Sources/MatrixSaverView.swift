// Matrix screensaver pour macOS.
// Port Swift de l'effet « matrix » de TerminalTextEffects (TTE, licence MIT,
// github.com/ChrisBuilds/terminaltexteffects), l'effet utilisé par le
// screensaver d'Omarchy. Pluie numérique → remplissage → résolution du logo.

import AppKit
import CoreText
import Metal
import QuartzCore
import ScreenSaver

// MARK: - Réglages (valeurs par défaut de TTE)

private enum Cfg {
    static let fps: Double = 30
    static let ticksPerFrame = 4          // 4 × 30 = 120 ticks/s, comme « tte --frame-rate 120 »
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

// MARK: - Aléatoire rapide
// Le générateur système de Swift est cryptographique et lent ; la simulation tire ~160 000
// nombres par image en pleine pluie. wyrand suffit largement pour une animation.

struct FastRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64 = UInt64(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds) | 1) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0xA0761D6478BD642F
        let m = state.multipliedFullWidth(by: state ^ 0xE7037ED1A0B428DB)
        return m.high ^ m.low
    }
    /// Vrai avec la probabilité p.
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) * 0x1.0p-53 < p }
}

var rng = FastRNG()

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
        baseDelay = p == .fill ? Int.random(in: max(r.lowerBound / 3, 1)...max(r.upperBound / 3, 1), using: &rng)
                               : Int.random(in: r, using: &rng)
        activeDelay = 0
        length = p == .rain ? Int.random(in: max(1, chars.count / 10)...chars.count, using: &rng) : chars.count
        holdTime = length == chars.count ? Int.random(in: 20...45, using: &rng) : 0
    }

    private func trim() {
        guard !visible.isEmpty else { return }
        visible.removeFirst().visible = false
        if visible.count > 1 { visible[0].color = engine.rainColors.suffix(3).randomElement(using: &rng)!.scaled(0.65) }
    }

    private func drop() {
        visible = visible.filter { c in
            c.row += 1
            if c.row >= engine.rows { c.visible = false; return false }
            return true
        }
    }

    func resolveChar() -> MChar { visible.remove(at: Int.random(in: 0..<visible.count, using: &rng)) }

    func tick() {
        if activeDelay == 0 {
            if !pending.isEmpty {
                let next = pending.removeFirst()
                next.sym = engine.randomRainSymbol()
                next.color = Cfg.highlight
                visible.last?.color = engine.rainColors.randomElement(using: &rng)!
                next.visible = true
                visible.append(next)
            } else if !visible.isEmpty {
                if visible.last!.color == Cfg.highlight { visible.last!.color = engine.rainColors.randomElement(using: &rng)! }
                if holdTime > 0 { holdTime -= 1 }
                else if phase == .rain {
                    if rng.chance(dropChance) { drop() }
                    trim()
                }
            }
            if visible.count > length { trim() }
            activeDelay = baseDelay
        } else {
            activeDelay -= 1
        }
        for c in visible {
            if rng.chance(Cfg.symbolSwapChance) { c.sym = engine.randomRainSymbol() }
            if rng.chance(Cfg.colorSwapChance) { c.color = engine.rainColors.randomElement(using: &rng)! }
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

    func randomRainSymbol() -> Int { rainSymbolIDs.randomElement(using: &rng)! }

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
        pending.shuffle(using: &rng)
    }

    func step() {
        switch phase {
        case .rain, .fill:
            if columnDelay == 0 {
                if phase == .rain {
                    for _ in 0..<Int.random(in: 1...3, using: &rng) where !pending.isEmpty { active.append(pending.removeFirst()) }
                    columnDelay = Int.random(in: Cfg.rainColumnDelay, using: &rng)
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
                    for _ in 0..<Int.random(in: 1...4, using: &rng) where !col.visible.isEmpty {
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

// MARK: - Vue

@objc(MatrixSaverView)
final class MatrixSaverView: ScreenSaverView {
    private var engine: MatrixEngine?
    private var renderer: MetalRenderer?
    private var fonts: [CTFont] = []
    private var glyphs: [GlyphSpec] = []
    private var symbolIndex: [Character: Int] = [:]
    private var baseFont: CTFont!
    private var cellW: CGFloat = 0, cellH: CGFloat = 0, baseline: CGFloat = 0
    private var builtFor = CGSize.zero, builtScale: CGFloat = 0
    private var builtDisplay: CGDirectDisplayID = 0
    private var observers: [NSObjectProtocol] = []
    private var drewFinal = false       // logo figé déjà dessiné → plus besoin de redessiner
    /// Vrai seulement dans le vrai hôte (pas dans tools/preview).
    private let hostedBySystem = ProcessInfo.processInfo.processName.contains("legacyScreenSaver")

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

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
        // macOS 14+ : legacyScreenSaver ne libère pas les instances et continue d'animer
        // après la sortie de l'économiseur → on quitte le processus dès qu'il n'a plus lieu d'être.
        // willstop n'est pas toujours émis (déverrouillage avec mot de passe…) : screenIsUnlocked
        // couvre ce cas. Ne PAS tuer le processus selon la présence de ScreenSaverEngine :
        // sur macOS 26, WallpaperAgent héberge aussi l'économiseur (écran verrouillé) et le
        // relance aussitôt → boucle de redémarrage.
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.screensaver.willstop", "com.apple.screenIsUnlocked"] {
            observers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                if self?.isPreview == false, self?.hostedBySystem == true { exit(0) }
            })
        }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit { observers.forEach { DistributedNotificationCenter.default().removeObserver($0) } }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    // Rendu par CAMetalLayer : AppKit ne dessine rien lui-même.
    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.pixelFormat = MetalRenderer.pixelFormat
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        l.framebufferOnly = true
        l.isOpaque = true
        l.backgroundColor = CGColor(gray: 0, alpha: 1)
        return l
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        builtFor = .zero                // densité de pixels changée → reconstruire la grille
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 1 }

    private var displayID: CGDirectDisplayID {
        (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// GPU qui pilote l'écran de la vue (pas de copie entre GPU ; l'iGPU sur l'écran interne).
    private func preferredDevice() -> MTLDevice? {
        if displayID != 0, let d = CGDirectDisplayCopyCurrentMetalDevice(displayID) { return d }
        return MTLCreateSystemDefaultDevice()
    }

    private func symbolID(_ ch: Character) -> Int {
        if let i = symbolIndex[ch] { return i }
        var g = GlyphSpec()
        switch ch {
        case "█": g.kind = 1
        case "▀": g.kind = 2
        case "▄": g.kind = 3
        case "▌": g.kind = 4
        case "▐": g.kind = 5
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

    /// (Re)construit la grille pour la taille, la densité et le GPU actuels de l'écran.
    /// Le nombre de cellules découle de la résolution : taille de police plafonnée à
    /// `Cfg.maxFontSize` points (taille physique constante, Retina ou non), réduite si
    /// nécessaire pour que le logo tienne (aperçu des Réglages, petits écrans).
    private func rebuild() {
        let size = bounds.size
        guard size.width > 10, size.height > 10 else { return }
        builtFor = size; builtScale = scale; builtDisplay = displayID; drewFinal = false

        if renderer == nil || renderer?.device.registryID != preferredDevice()?.registryID {
            renderer = preferredDevice().flatMap(MetalRenderer.init)
            metalLayer?.device = renderer?.device
        }

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
        // Origine en haut à gauche (repère Metal, rangée 0 en haut comme le moteur)
        let origin = CGPoint(x: (size.width - CGFloat(cols) * cellW) / 2,
                             y: (size.height - CGFloat(rows) * cellH) / 2)
        let e = MatrixEngine(cols: cols, rows: rows, logo: logo, symbolID: symbolID)
        engine = e

        metalLayer?.contentsScale = scale
        metalLayer?.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        renderer?.configure(glyphs: glyphs, fonts: fonts, cell: CGSize(width: cellW, height: cellH),
                            baseline: baseline, origin: origin, viewport: size, scale: scale,
                            cellCount: cols * rows)
    }

    override func startAnimation() {
        super.startAnimation()
        rebuild()
    }

    override func animateOneFrame() {
        // Pas de test occlusionState : dans l'hôte ViewBridge (legacyScreenSaver) la fenêtre
        // se déclare toujours masquée, même affichée → l'économiseur restait noir.
        if bounds.size != builtFor || scale != builtScale || displayID != builtDisplay { rebuild() }
        guard let e = engine else { return }
        for _ in 0..<Cfg.ticksPerFrame { e.step() }
        if e.phase == .done, let t = e.doneAt, Date().timeIntervalSince(t) > Cfg.holdLogo { rebuild() }
        // Logo figé : une seule image suffit pendant Cfg.holdLogo (le layer garde son contenu).
        if e.phase == .done && e.resolving.isEmpty {
            if drewFinal { return }
            drewFinal = true
        }
        if let l = metalLayer, l.superlayer != nil || hostedBySystem { renderer?.draw(e, glyphs: glyphs, in: l) }
    }

    // MARK: Outil de test (tools/preview) : rendu hors écran

    @objc func renderOffscreen() {
        guard let e = engine else { return }
        renderer?.drawOffscreen(e, glyphs: glyphs, readBack: false)
    }

    @objc func writePNG(_ path: NSString) {
        guard let e = engine, let img = renderer?.drawOffscreen(e, glyphs: glyphs, readBack: true) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path as String))
    }
}
