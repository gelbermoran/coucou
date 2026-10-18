import Foundation
import AppKit
import PDFKit
import Vision

// MARK: - FileTextExtractor
// Turns a dropped file into plain text the chat model can read, for every provider that takes
// text (MiniMax, Google, OpenAI, local models, the CLIs). Everything runs on the Mac: text and code,
// PDF (with OCR for scanned pages), images (OCR), Word / RTF / OpenDocument, and Excel sheets.

enum FileTextExtractor {
    /// Max size we try to read at all.
    private static let maxFileBytes = 25_000_000

    /// Text of the file, or an explicit note when it cannot be read (so the model never pretends to see it).
    static func text(for url: URL, limit: Int) async -> String {
        await Task.detached(priority: .userInitiated) {
            let raw = extract(url: url)
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "[Coucou could not read the contents of this file (\(url.pathExtension.isEmpty ? "unknown type" : "." + url.pathExtension.lowercased())). Tell the user you cannot see its contents.]"
            }
            return raw.count > limit ? String(raw.prefix(limit)) + "\n[truncated: the file is longer than what fits in the chat]" : raw
        }.value
    }

    nonisolated static func extract(url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { return nil }
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return pdfText(url)
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "tif", "tiff", "bmp":
            guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let text = ocr(cg)
            return text.isEmpty ? nil : "[Text recognized in the image]\n" + text
        case "docx", "doc", "rtf", "rtfd", "odt", "wordml":
            let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return attr?.string
        case "xlsx":
            return xlsxText(url)
        default:
            return plainText(url)
        }
    }

    // MARK: Plain text and code

    private nonisolated static func plainText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(4096).contains(0) { return nil }   // binary
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: PDF (text layer first, OCR for scanned pages)

    private nonisolated static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let layer = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if layer.count > 40 { return layer }
        // Scanned PDF: render each page and recognize its text.
        var parts: [String] = []
        for i in 0..<min(doc.pageCount, 15) {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let size = CGSize(width: box.width * scale, height: box.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let t = ocr(cg)
                if !t.isEmpty { parts.append("— Page \(i + 1) —\n" + t) }
            }
        }
        return parts.isEmpty ? (layer.isEmpty ? nil : layer) : parts.joined(separator: "\n\n")
    }

    // MARK: OCR

    private nonisolated static func ocr(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["es-ES", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: Excel (.xlsx = zip of XML; read the shared strings and sheet cells)

    private nonisolated static func xlsxText(_ url: URL) -> String? {
        #if APPSTORE
        return nil
        #else
        func unzip(_ entry: String) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path, entry]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
        }
        func strip(_ xml: String) -> String {
            xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
               .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
               .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        }
        guard let shared = unzip("xl/sharedStrings.xml") else { return nil }
        // One <si> element per shared string.
        let items = shared.components(separatedBy: "</si>").map { strip($0).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : "[Text cells of the spreadsheet, in order]\n" + items.joined(separator: "\n")
        #endif
    }
}
