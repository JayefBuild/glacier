// DirectoryEventStream.swift
// Single root-level FSEvents stream. Fires one callback per batch of change events
// under the watched root — including all descendants, recursively.
//
// Based on the MIT-licensed CodeEdit implementation
// (github.com/CodeEditApp/CodeEdit — DirectoryEventStream.swift).
//
// Why a single root stream instead of per-folder DispatchSource watchers:
//   - No risk of "forgot to attach a watcher to a newly-created subdirectory"
//   - No ulimit pressure on deep trees
//   - Rename events carry inode/fileId via UseExtendedData, letting us correlate
//     the two-part rename event pair
//   - Debouncing is built in via the `latency` parameter
//
// The callback is treated as advisory: on any event, the receiver should re-diff
// the affected parent directory against the filesystem. Do not trust event payload
// ordering or completeness.

import Foundation
import CoreServices

/// Kind of filesystem change, derived from FSEvent flags.
enum DirectoryEventKind {
    case changeInDirectory   // A file or directory inside the path changed (created/deleted/renamed/modified).
    case rootRenamed         // The watched root itself was renamed or moved.
    case rootDeleted         // The watched root itself was deleted.
}

/// A single directory-change event.
struct DirectoryEvent {
    let url: URL
    let kind: DirectoryEventKind
}

final class DirectoryEventStream {

    // MARK: - State

    private let rootURL: URL
    private let onEvents: ([DirectoryEvent]) -> Void
    private var stream: FSEventStreamRef?

    // MARK: - Init

    /// - Parameters:
    ///   - rootURL: The root directory to watch recursively.
    ///   - latency: FSEvents coalescing window in seconds. 0.1 is a good default.
    ///   - onEvents: Callback invoked on the background queue. Events are batched.
    init(
        rootURL: URL,
        latency: CFTimeInterval = 0.1,
        onEvents: @escaping ([DirectoryEvent]) -> Void
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.onEvents = onEvents
        start(latency: latency)
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    private func start(latency: CFTimeInterval) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [rootURL.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagUseExtendedData
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryEventStream.eventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Callback

    private static let eventCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let stream = Unmanaged<DirectoryEventStream>.fromOpaque(info).takeUnretainedValue()

        // With UseExtendedData + UseCFTypes, eventPaths is a CFArray of CFDictionary.
        // Each dictionary has kFSEventStreamEventExtendedDataPathKey. We only need the path here;
        // parent re-diff is authoritative so we don't need the inode.
        let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
        let count = CFArrayGetCount(cfArray)
        guard count > 0 else { return }

        var events: [DirectoryEvent] = []
        events.reserveCapacity(count)

        for index in 0..<count {
            let raw = CFArrayGetValueAtIndex(cfArray, index)
            guard let raw else { continue }

            let path: String
            let dict = unsafeBitCast(raw, to: CFDictionary.self)
            let nsDict = dict as NSDictionary
            if let value = nsDict[kFSEventStreamEventExtendedDataPathKey] as? String {
                path = value
            } else {
                continue
            }

            let flags = eventFlags[index]
            let url = URL(fileURLWithPath: path).standardizedFileURL

            let isRoot = (path == stream.rootURL.path)
            let isRootChanged = (flags & UInt32(kFSEventStreamEventFlagRootChanged)) != 0

            if isRoot || isRootChanged {
                if FileManager.default.fileExists(atPath: stream.rootURL.path) {
                    events.append(DirectoryEvent(url: stream.rootURL, kind: .rootRenamed))
                } else {
                    events.append(DirectoryEvent(url: stream.rootURL, kind: .rootDeleted))
                }
                continue
            }

            events.append(DirectoryEvent(url: url, kind: .changeInDirectory))
        }

        guard !events.isEmpty else { return }
        stream.onEvents(events)
    }
}
