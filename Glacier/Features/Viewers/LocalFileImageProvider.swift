// LocalFileImageProvider.swift
// MarkdownUI image provider that loads images from the local filesystem using
// file:// URLs. Used for markdown previews where images live alongside the document.

import SwiftUI
import AppKit
import MarkdownUI

struct LocalFileImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                // Use the image's intrinsic size but cap at container width.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(image.size, contentMode: .fit)
                    .frame(maxWidth: image.size.width)
            } else {
                EmptyView()
            }
        }
    }
}
