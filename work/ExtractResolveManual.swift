// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import PDFKit

let pdfPath = "/Applications/DaVinci Resolve/DaVinci Resolve Manual.pdf"
let url = URL(fileURLWithPath: pdfPath)

guard let document = PDFDocument(url: url) else {
    fputs("Failed to open PDF: \(pdfPath)\n", stderr)
    exit(1)
}

let needles = Array(CommandLine.arguments.dropFirst()).map { $0.lowercased() }
let queries = needles.isEmpty ? [
    "assist using reel",
    "reel extraction",
    "extraction pattern",
    "source clip file pathname",
    "%r",
    "%d"
] : needles

func snippet(_ text: String, around range: Range<String.Index>) -> String {
    let start = text.index(range.lowerBound, offsetBy: -260, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(range.upperBound, offsetBy: 520, limitedBy: text.endIndex) ?? text.endIndex
    return text[start..<end]
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
}

for pageIndex in 0..<document.pageCount {
    guard let page = document.page(at: pageIndex), let text = page.string else { continue }
    let lower = text.lowercased()
    for query in queries {
        if let range = lower.range(of: query) {
            print("---- page \(pageIndex + 1), query: \(query) ----")
            print(snippet(text, around: range))
            print()
        }
    }
}
