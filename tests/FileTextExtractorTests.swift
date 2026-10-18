import Foundation
import AppKit
import PDFKit

var failed = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ✓ \(name)" : "  ✗ \(name)")
    if !ok { failed += 1 }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-extract-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let phrase = "Factura numero 4821 total 1500 pesos"

// Draws `phrase` into a bitmap (used for the image and for the scanned PDF)
func bitmap() -> NSImage {
    let img = NSImage(size: NSSize(width: 1000, height: 300))
    img.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 300).fill()
    (phrase as NSString).draw(at: NSPoint(x: 30, y: 120),
        withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
    img.unlockFocus()
    return img
}

// 1. plain text
let txt = dir.appendingPathComponent("nota.txt")
try! phrase.write(to: txt, atomically: true, encoding: .utf8)
check("text file", FileTextExtractor.extract(url: txt)?.contains("4821") == true)

// 2. PDF with a text layer
let pdf = dir.appendingPathComponent("texto.pdf")
do {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
    (phrase + " — documento con capa de texto suficiente para pasar el umbral" as NSString).draw(at: NSPoint(x: 40, y: 700),
        withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage(); ctx.closePDF()
}
check("PDF with text layer", FileTextExtractor.extract(url: pdf)?.contains("4821") == true)

// 3. image with text (OCR)
let png = dir.appendingPathComponent("foto.png")
let tiff = bitmap().tiffRepresentation!
try! NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!.write(to: png)
check("image OCR", FileTextExtractor.extract(url: png)?.contains("4821") == true)

// 4. scanned PDF (page is only an image)
let scan = dir.appendingPathComponent("escaneado.pdf")
let doc = PDFDocument(); doc.insert(PDFPage(image: bitmap())!, at: 0); doc.write(to: scan)
check("scanned PDF OCR", FileTextExtractor.extract(url: scan)?.contains("4821") == true)

// 5. Word document (made with textutil)
let rtf = dir.appendingPathComponent("a.rtf")
try! phrase.write(to: rtf.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
p.arguments = ["-convert", "docx", rtf.deletingPathExtension().appendingPathExtension("txt").path, "-output", dir.appendingPathComponent("w.docx").path]
try! p.run(); p.waitUntilExit()
check("docx", FileTextExtractor.extract(url: dir.appendingPathComponent("w.docx"))?.contains("4821") == true)

// 6. binary file is rejected, not shown as garbage
let bin = dir.appendingPathComponent("x.bin")
try! Data([0, 1, 2, 0, 255, 254, 0, 0]).write(to: bin)
check("binary file → nil", FileTextExtractor.extract(url: bin) == nil)

try? FileManager.default.removeItem(at: dir)
if failed > 0 { print("\(failed) FAILED"); exit(1) }
print("All tests passed.")
