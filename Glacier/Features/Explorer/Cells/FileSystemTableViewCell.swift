// Ported from CodeEdit (https://github.com/CodeEditApp/CodeEdit) — MIT License.
// See LICENSES/CodeEdit-LICENSE.md for full license text.
//
//  FileSystemTableViewCell.swift
//  CodeEdit
//
//  Created by TAY KAI QUAN on 14/8/22.
//

import SwiftUI

class FileSystemTableViewCell: StandardTableViewCell {

    weak var fileItem: CEWorkspaceFile?

    var changeLabelLargeWidth: NSLayoutConstraint!
    var changeLabelSmallWidth: NSLayoutConstraint!

    private var navigatorFilter: String?

    /// Initializes the `OutlineTableViewCell` with an `icon` and `label`
    /// Both the icon and label will be colored, and sized based on the user's preferences.
    /// - Parameters:
    ///   - frameRect: The frame of the cell.
    ///   - item: The file item the cell represents.
    ///   - isEditable: Set to true if the user should be able to edit the file name.
    ///   - navigatorFilter: An optional string use to filter the navigator area.
    ///                      (Used for bolding and changing primary/secondary color).
    init(frame frameRect: NSRect, item: CEWorkspaceFile?, isEditable: Bool = true, navigatorFilter: String? = nil) {
        super.init(frame: frameRect, isEditable: isEditable)
        self.navigatorFilter = navigatorFilter

        if let item = item {
            addIcon(item: item)
        }
        addModel()
    }

    override func configLabel(label: NSTextField, isEditable: Bool) {
        super.configLabel(label: label, isEditable: isEditable)
        label.delegate = self
    }

    func addIcon(item: CEWorkspaceFile) {
        fileItem = item
        imageView?.image = item.nsIcon
        imageView?.contentTintColor = color(for: item)

        let fileName = item.labelFileName()
        let fontSize = textField?.font?.pointSize ?? 12

        guard let filter = navigatorFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty else {
            textField?.stringValue = fileName
            return
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingMiddle

        /// Initialize default attributes
        let attributedString = NSMutableAttributedString(string: fileName, attributes: [
            .paragraphStyle: paragraphStyle,
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ])

        /// Check if the filename contains the filter text
        let range = (fileName as NSString).range(of: filter, options: .caseInsensitive)
        if range.location != NSNotFound {
            /// If the filter text matches, bold the matching text and set primary label color
            attributedString.addAttributes(
                [
                    .font: NSFont.boldSystemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.labelColor
                ],
                range: range
            )
        } else {
            /// If no match, apply primary label color for parent folder,
            /// or secondary label color for a non-matching file
            attributedString.addAttribute(
                .foregroundColor,
                value: item.isFolder ? NSColor.labelColor : NSColor.secondaryLabelColor,
                range: NSRange(location: 0, length: attributedString.length)
            )
        }

        textField?.attributedStringValue = attributedString
    }

    func addModel() {
        guard let fileItem = fileItem, let secondaryLabel = secondaryLabel else {
            return
        }

        // Glacier: strip git status badges. Still show symlink glyph.
        if fileItem.url.ceIsSymbolicLink { secondaryLabel.stringValue = "\u{F241E}" }
    }

    /// *Not Implemented*
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fatalError("""
            init(frame: ) isn't implemented on `OutlineTableViewCell`.
            Please use `.init(frame: NSRect, item: CEWorkspaceFile?)
            """)
    }

    /// *Not Implemented*
    required init?(coder: NSCoder) {
        fatalError("""
            init?(coder: NSCoder) isn't implemented on `OutlineTableViewCell`.
            Please use `.init(frame: NSRect, item: CEWorkspaceFile?)
            """)
    }

    /// Returns the font size for the current row height. Defaults to `13.0`
    private var fontSize: Double {
        switch self.frame.height {
        case 20: return 11
        case 22: return 13
        case 24: return 14
        default: return 13
        }
    }

    /// Get the appropriate color for the items icon.
    /// Glacier default: always color (icons in color).
    /// - Parameter item: The `CEWorkspaceFile` to get the color for
    /// - Returns: A `NSColor` for the given `CEWorkspaceFile`.
    func color(for item: CEWorkspaceFile) -> NSColor {
        if !item.isFolder {
            return NSColor(item.iconColor)
        } else {
            return NSColor.ceFolderBlue
        }
    }

    deinit {
        toolTip = nil
    }
}

let errorRed = NSColor(red: 1, green: 0, blue: 0, alpha: 0.2)
extension FileSystemTableViewCell: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let fileItem else { return }
        textField?.backgroundColor = fileItem.validateFileName(for: textField?.stringValue ?? "") ? .none : errorRed
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let fileItem else { return }
        do {
            textField?.backgroundColor = fileItem.validateFileName(for: textField?.stringValue ?? "") ? .none : errorRed
            if fileItem.validateFileName(for: textField?.stringValue ?? "") {
                let newURL = fileItem.url
                    .deletingLastPathComponent()
                    .appending(path: textField?.stringValue ?? "")
                try host?.fileManager?.move(file: fileItem, to: newURL)
            } else {
                textField?.stringValue = fileItem.labelFileName()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }
}

// Glacier stub: replaces CodeEdit's `NSColor.folderBlue` asset catalog color.
extension NSColor {
    static let ceFolderBlue = NSColor(
        red: 0.32, green: 0.56, blue: 0.93, alpha: 1.0
    )
}
