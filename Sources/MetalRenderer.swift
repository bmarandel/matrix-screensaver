// Rendu GPU (Metal) de la grille Matrix.
// Le CPU ne fait que la simulation et remplit un petit tableau d'instances
// (une par cellule visible : position, symbole, couleur) ; le GPU dessine toute la
// grille en un seul appel instancié, à partir d'un atlas de glyphes préparé une fois.

import AppKit
import CoreText
import Metal

/// Une cellule visible, telle que lue par le shader (12 octets, même disposition que `Cell` en MSL).
struct CellInstance {
    var col: UInt16, row: UInt16, sym: UInt16
    var kind: UInt8                     // 0 glyphe (atlas), 1 █, 2 ▀, 3 ▄, 4 ▌, 5 ▐
    var pad: UInt8 = 0
    var r: UInt8, g: UInt8, b: UInt8
    var a: UInt8 = 255
}

/// Paramètres de la grille en pixels physiques (même disposition que `U` en MSL).
struct GridUniforms {
    var viewport: SIMD2<Float>          // taille de la cible
    var origin: SIMD2<Float>            // coin haut-gauche de la grille
    var cell: SIMD2<Float>              // taille d'une cellule (fractionnaire)
    var slot: SIMD2<Float>              // taille d'une case de l'atlas (marges comprises)
    var atlas: SIMD2<Float>             // taille de l'atlas
    var pad: SIMD2<Float>               // marge autour du glyphe dans sa case
    var atlasCols: UInt32
    var unused: UInt32 = 0
}

/// Ce qu'il faut savoir pour dessiner un symbole.
struct GlyphSpec {
    var kind: UInt8 = 0
    var font = 0
    var glyph: CGGlyph = 0
    var dx: CGFloat = 0                 // centrage horizontal dans la cellule (points)
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Cell { ushort col; ushort row; ushort sym; uchar kind; uchar pad; uchar4 color; };
struct U { float2 viewport; float2 origin; float2 cell; float2 slot; float2 atlas; float2 pad;
           uint atlasCols; uint unused; };
struct VOut { float4 pos [[position]]; float2 uv; half4 color; uint textured [[flat]]; };

vertex VOut grid_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Cell *cells [[buffer(0)]], constant U &u [[buffer(1)]]) {
    Cell c = cells[iid];
    // Bords de cellule arrondis au pixel : les blocs du logo se touchent sans jointure.
    float x0 = round(u.origin.x + float(c.col) * u.cell.x);
    float x1 = round(u.origin.x + float(c.col + 1) * u.cell.x);
    float y0 = round(u.origin.y + float(c.row) * u.cell.y);
    float y1 = round(u.origin.y + float(c.row + 1) * u.cell.y);
    float xm = round((x0 + x1) * 0.5), ym = round((y0 + y1) * 0.5);
    float2 p0 = float2(x0, y0), p1 = float2(x1, y1), uv0 = 0, uv1 = 0;
    switch (c.kind) {
        case 0: {
            p0 = float2(x0, y0) - u.pad; p1 = p0 + u.slot;
            float2 s = float2(c.sym % u.atlasCols, c.sym / u.atlasCols) * u.slot;
            uv0 = s / u.atlas; uv1 = (s + u.slot) / u.atlas;
            break;
        }
        case 2: p1.y = ym; break;           // ▀ moitié haute
        case 3: p0.y = ym; break;           // ▄ moitié basse
        case 4: p1.x = xm; break;           // ▌ moitié gauche
        case 5: p0.x = xm; break;           // ▐ moitié droite
        default: break;                     // █ cellule pleine
    }
    float2 k = float2(vid & 1, vid >> 1);
    float2 p = mix(p0, p1, k);
    VOut o;
    o.pos = float4(p.x / u.viewport.x * 2 - 1, 1 - p.y / u.viewport.y * 2, 0, 1);
    o.uv = mix(uv0, uv1, k);
    o.color = half4(c.color) / 255.0h;
    o.textured = c.kind == 0;
    return o;
}

fragment half4 grid_fragment(VOut in [[stage_in]], texture2d<half> atlas [[texture(0)]]) {
    if (!in.textured) return in.color;
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    half a = atlas.sample(s, in.uv).r;
    return half4(in.color.rgb * a, a);      // alpha prémultiplié
}
"""

final class MetalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var atlas: MTLTexture?
    private var uniforms: GridUniforms?
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var offscreen: MTLTexture?

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: shaderSource, options: nil),
              let vf = lib.makeFunction(name: "grid_vertex"),
              let ff = lib.makeFunction(name: "grid_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf; d.fragmentFunction = ff
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = Self.pixelFormat
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.device = device; queue = q; pipeline = p
    }

    /// Prépare l'atlas de glyphes et les tampons pour une grille donnée.
    /// `cell`, `origin` et `baseline` sont en points ; `scale` = pixels par point.
    func configure(glyphs: [GlyphSpec], fonts: [CTFont], cell: CGSize, baseline: CGFloat,
                   origin: CGPoint, viewport: CGSize, scale: CGFloat, cellCount: Int) {
        let pad = max(2, (cell.width * scale * 0.25).rounded(.up))
        let slotW = Int((cell.width * scale).rounded(.up) + 2 * pad)
        let slotH = Int((cell.height * scale).rounded(.up) + 2 * pad)
        let cols = 16, rows = max(1, (glyphs.count + cols - 1) / cols)
        let W = cols * slotW, H = rows * slotH

        // Glyphes en blanc sur noir dans un bitmap 8 bits (niveaux de gris = couverture).
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setAllowsFontSmoothing(false); ctx.setShouldAntialias(true)
        ctx.textMatrix = .identity
        let scaled = fonts.map { CTFontCreateCopyWithAttributes($0, CTFontGetSize($0) * scale, nil, nil) }
        for (i, g) in glyphs.enumerated() where g.kind == 0 {
            let sx = CGFloat((i % cols) * slotW), top = CGFloat(H - (i / cols) * slotH)
            var gl = g.glyph
            var pos = CGPoint(x: sx + pad + g.dx * scale, y: top - pad - (cell.height - baseline) * scale)
            CTFontDrawGlyphs(scaled[g.font], &gl, &pos, 1, ctx)
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: W, height: H, mipmapped: false)
        td.usage = .shaderRead
        let tex = device.makeTexture(descriptor: td)!
        tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: W)
        atlas = tex

        uniforms = GridUniforms(
            viewport: SIMD2(Float(viewport.width * scale), Float(viewport.height * scale)),
            origin: SIMD2(Float(origin.x * scale), Float(origin.y * scale)),
            cell: SIMD2(Float(cell.width * scale), Float(cell.height * scale)),
            slot: SIMD2(Float(slotW), Float(slotH)),
            atlas: SIMD2(Float(W), Float(H)),
            pad: SIMD2(Float(pad), Float(pad)),
            atlasCols: UInt32(cols))

        let len = max(1, cellCount) * MemoryLayout<CellInstance>.stride
        if buffers.first.map({ $0.length < len }) ?? true {
            buffers = (0..<3).map { _ in device.makeBuffer(length: len, options: .storageModeShared)! }
        }
        offscreen = nil
    }

    /// Encode une image de la grille dans `target` (sans la soumettre).
    private func encode(_ engine: MatrixEngine, glyphs: [GlyphSpec], into target: MTLTexture,
                        _ cb: MTLCommandBuffer) {
        inFlight.wait()
        cb.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        let buf = buffers[bufferIndex]; bufferIndex = (bufferIndex + 1) % buffers.count
        let cap = buf.length / MemoryLayout<CellInstance>.stride
        let p = buf.contents().bindMemory(to: CellInstance.self, capacity: cap)
        var n = 0
        for c in engine.chars where c.visible && n < cap {
            p[n] = CellInstance(col: UInt16(c.col), row: UInt16(c.row), sym: UInt16(c.sym),
                                kind: glyphs[c.sym].kind, r: c.color.r, g: c.color.g, b: c.color.b)
            n += 1
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        if n > 0, var u = uniforms, let atlas {
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        }
        enc.endEncoding()
    }

    /// Dessine et affiche une image dans le CAMetalLayer de la vue.
    func draw(_ engine: MatrixEngine, glyphs: [GlyphSpec], in layer: CAMetalLayer) {
        guard uniforms != nil, let drawable = layer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }
        encode(engine, glyphs: glyphs, into: drawable.texture, cb)
        cb.present(drawable)
        cb.commit()
    }

    /// Rendu dans une texture hors écran (outil de test) ; renvoie l'image si `readBack`.
    @discardableResult
    func drawOffscreen(_ engine: MatrixEngine, glyphs: [GlyphSpec], readBack: Bool) -> CGImage? {
        guard let u = uniforms, let cb = queue.makeCommandBuffer() else { return nil }
        let W = Int(u.viewport.x), H = Int(u.viewport.y)
        if offscreen == nil {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: W, height: H,
                                                              mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .managed
            offscreen = device.makeTexture(descriptor: td)
        }
        guard let tex = offscreen else { return nil }
        encode(engine, glyphs: glyphs, into: tex, cb)
        if readBack, let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: tex); blit.endEncoding() }
        cb.commit()
        guard readBack else { return nil }
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        tex.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return bytes.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)?.makeImage()
        }
    }
}
