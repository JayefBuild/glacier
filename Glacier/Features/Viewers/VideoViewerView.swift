// VideoViewerView.swift
// AVKit-based video player using AVPlayerView (AppKit) to avoid the
// _AVKit_SwiftUI crash on macOS 26 with SwiftUI's VideoPlayer wrapper.

import SwiftUI
import AVKit

struct VideoViewerView: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                AVPlayerViewRepresentable(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            player?.pause()
            player = nil
            let item = AVPlayerItem(url: url)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.play()
            player = newPlayer
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - AVPlayerView bridge (bypasses broken _AVKit_SwiftUI on macOS 26)

private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    typealias NSViewType = AVPlayerView

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - Audio Viewer

struct AudioViewerView: View {
    let url: URL
    @Environment(\.appTheme) private var theme

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative.reversing, isActive: isPlaying)

            Text(url.lastPathComponent)
                .font(theme.typography.labelFont)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                Button {
                    if isPlaying {
                        player?.pause()
                    } else {
                        player?.play()
                    }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}
