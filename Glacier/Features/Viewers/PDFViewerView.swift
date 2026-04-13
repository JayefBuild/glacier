// PDFViewerView.swift
// Native PDFKit-based PDF viewer.

import SwiftUI
import PDFKit

struct PDFViewerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor(white: 0.15, alpha: 1)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }
    }
}

// MARK: - Binary Info View

struct BinaryInfoView: View {
    let url: URL
    @Environment(\.appTheme) private var theme

    @State private var fileSize: String = ""
    @State private var modDate: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.tertiary)

            Text(url.lastPathComponent)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                infoRow(label: "Size", value: fileSize)
                infoRow(label: "Type", value: url.pathExtension.uppercased())
                infoRow(label: "Modified", value: modDate)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(.ultraThinMaterial)
            )

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { loadMetadata() }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(theme.typography.captionFont)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(theme.typography.captionFont)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func loadMetadata() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int64 {
            fileSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        if let date = attrs?[.modificationDate] as? Date {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            modDate = fmt.string(from: date)
        }
    }
}
