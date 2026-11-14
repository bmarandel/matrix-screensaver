// Teste Matrix.saver hors écran : charge le bundle, l'anime en temps réel et
// enregistre des captures PNG à des instants donnés, puis mesure le coût du rendu.
// Usage : swiftc -O tools/preview.swift -o build/preview
//         build/preview build/Matrix.saver <dossier-sortie> [secondes…]   (défaut : 3 17 23 26 44)
import AppKit
import ScreenSaver

let args = CommandLine.arguments
guard args.count >= 3, let bundle = Bundle(path: args[1]), bundle.load(),
      let cls = bundle.principalClass as? ScreenSaverView.Type else {
    print("usage: preview <Matrix.saver> <dossier-sortie> [secondes…]"); exit(2)
}
let out = args[2]
var shots = args.count > 3 ? args[3...].compactMap(Double.init) : [3, 17, 23, 26, 44]
let v = cls.init(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), isPreview: false)!
v.startAnimation()

func snap(_ name: String) {
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    print("→ \(out)/\(name).png")
}

let start = Date(); var frames = 0
while !shots.isEmpty {
    let t0 = Date(); v.animateOneFrame(); frames += 1
    if Date().timeIntervalSince(start) >= shots[0] { snap("t\(Int(shots[0]))"); shots.removeFirst() }
    let dt = v.animationTimeInterval - Date().timeIntervalSince(t0)
    if dt > 0 { Thread.sleep(forTimeInterval: dt) }
}
let el = Date().timeIntervalSince(start)
print(String(format: "%d frames en %.1f s = %.1f fps (simulation)", frames, el, Double(frames) / el))
let t = Date()
for _ in 0..<60 { let r = v.bitmapImageRepForCachingDisplay(in: v.bounds)!; v.cacheDisplay(in: v.bounds, to: r) }
print(String(format: "rendu : %.1f ms/frame (1440×900)", Date().timeIntervalSince(t) / 60 * 1000))
