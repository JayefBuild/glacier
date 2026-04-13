// ImageViewerView.swift
// Displays images with zoom and pan support.

import SwiftUI

struct ImageViewerView: View {
    let url: URL
    @Environment(\.appTheme) private var theme

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
                .ignoresSafeArea()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnifyGesture)
                    .gesture(dragGesture)
                    .onTapGesture(count: 2) {
                        withAnimation(theme.animation.spring) {
                            scale = 1.0
                            offset = .zero
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            imageControls
        }
        .task {
            image = NSImage(contentsOf: url)
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(0.1, min(10, value.magnification))
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = value.translation
            }
    }

    private var imageControls: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(theme.animation.spring) { scale = max(0.1, scale - 0.25) }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.glass)

            Text("\(Int(scale * 100))%")
                .font(theme.typography.captionFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44)

            Button {
                withAnimation(theme.animation.spring) { scale = min(10, scale + 0.25) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.glass)

            Button {
                withAnimation(theme.animation.spring) { scale = 1.0; offset = .zero }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.glass)
        }
        .padding(12)
    }
}
