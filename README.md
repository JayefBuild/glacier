# Glacier

Glacier is a native macOS workspace app for browsing a folder, editing files, opening terminals, and previewing project artifacts without leaving one window.

Built for macOS 26 (Tahoe) with SwiftUI and AppKit-backed views where native controls matter.

## What It Does

- File explorer with folder creation, file creation, rename, and delete flows
- Tabbed editor with native macOS split panes
- Integrated terminal tabs powered by SwiftTerm
- Git graph tab for quick branch/history inspection
- Rich Markdown editing with a source-mode fallback
- Markwhen timeline preview
- Excalidraw editing with autosave back to disk
- Native PDF viewing

## Viewer Support

Glacier currently includes first-class handling for:

- Plain text and code files
- Markdown (`.md`, `.markdown`)
- Markwhen (`.mw`, `.markwhen`)
- Excalidraw (`.excalidraw`)
- PDF

Excalidraw loads from `excalidraw.com` inside an embedded `WKWebView`, so it requires internet access. Drawings are auto-saved back to the `.excalidraw` file on disk shortly after edits.

## Split View And Terminal Workflow

Glacier supports pane-aware tabs and shortcuts:

- `Cmd+T` opens a new terminal tab
- `Option+Cmd+Right Arrow` splits the focused pane to the right
- `Option+Cmd+Down Arrow` splits the focused pane downward
- `Option+Cmd+\` closes the active split

Terminal tabs retain focus correctly when moved between panes or when switching tabs, and split panes keep independent tab bars.

## Git Graph

The sidebar toolbar includes a Git button that opens a `Git Graph` tab in the main editor area. The graph is optimized for quick scanning instead of full Git client functionality:

- Colored swim lanes
- Inline branch and remote refs
- Shared horizontal/vertical scrolling across the full commit list
- Clear empty state when the current folder is not a Git repository

## Development

### Requirements

- Xcode 17+
- macOS 26+

### Build

```bash
xcodebuild -scheme Glacier -project Glacier.xcodeproj -configuration Debug build
```

### Run The Latest Debug Build

```bash
open ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/Glacier.app
```

If you keep a Spotlight-visible dev copy such as `~/Applications/Dev/Glacier.app`, sync the latest Debug build into that location before launching from Spotlight.

## Project Notes

- The app uses SwiftTerm for terminal rendering.
- The git graph is a native SwiftUI/AppKit implementation inspired by VS Code Git Graph, not an embedded web view.
