// Teste Matrix.saver hors écran : charge le bundle, l'anime en temps réel (rendu compris),
// enregistre des captures PNG à des instants donnés et mesure le temps CPU consommé.
// Usage : swiftc -O tools/preview.swift -o build/preview
//         build/preview build/Matrix.saver <dossier-sortie> [LxH] [secondes…]
//         (défaut : 1440x900, captures à 3 17 23 26 44 s)
import AppKit
import ScreenSaver

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let bundle = Bundle(path: args[0]), bundle.load(),
      let cls = bundle.principalClass as? ScreenSaverView.Type else {
    print("usage: preview <Matrix.saver> <dossier-sortie> [LxH] [secondes…]"); exit(2)
}
let out = args[1]
args.removeFirst(2)
var size = NSSize(width: 1440, height: 900)
if let first = args.first, first.contains("x") {
    let p = first.split(separator: "x").compactMap { Double($0) }
    if p.count == 2 { size = NSSize(width: p[0], height: p[1]) }
    args.removeFirst()
}
var shots = args.isEmpty ? [3, 17, 23, 26, 44] : args.compactMap(Double.init)
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let v = cls.init(frame: NSRect(origin: .zero, size: size), isPreview: false)!
v.startAnimation()

// Rendu Metal hors écran si la vue le propose, sinon rendu CoreGraphics classique.
let metalRender = NSSelectorFromString("renderOffscreen")
let metalSnap = NSSelectorFromString("writePNG:")
let isMetal = v.responds(to: metalRender)

func render() {
    if isMetal { v.perform(metalRender) }
    else { let r = v.bitmapImageRepForCachingDisplay(in: v.bounds)!; v.cacheDisplay(in: v.bounds, to: r) }
}

func snap(_ name: String) {
    let path = "\(out)/\(name).png"
    if isMetal { v.perform(metalSnap, with: path as NSString) }
    else {
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    print("→ \(path)")
}

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

let start = Date(), cpu0 = cpuSeconds(); var frames = 0
var simT = 0.0, renT = 0.0
while !shots.isEmpty {
    let t0 = Date()
    v.animateOneFrame(); let t1 = Date(); render(); frames += 1
    simT += t1.timeIntervalSince(t0); renT += Date().timeIntervalSince(t1)
    if Date().timeIntervalSince(start) >= shots[0] { snap("t\(Int(shots[0]))"); shots.removeFirst() }
    let dt = v.animationTimeInterval - Date().timeIntervalSince(t0)
    if dt > 0 { Thread.sleep(forTimeInterval: dt) }
}
let el = Date().timeIntervalSince(start), cpu = cpuSeconds() - cpu0
print(String(format: "%@ %d×%d : %d frames en %.1f s = %.1f fps — CPU %.0f %% d'un cœur (%.1f ms CPU/frame)",
             isMetal ? "Metal" : "CoreGraphics", Int(size.width), Int(size.height),
             frames, el, Double(frames) / el, cpu / el * 100, cpu / Double(frames) * 1000))
print(String(format: "  dont simulation %.1f ms/frame, rendu %.1f ms/frame (temps écoulé)",
             simT / Double(frames) * 1000, renT / Double(frames) * 1000))
