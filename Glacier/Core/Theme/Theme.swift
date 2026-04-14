// Theme.swift
// Central design token system — change values here to retheme the entire app.
// All colors, spacing, typography, and radius values flow from this file.

import SwiftUI

// MARK: - Theme Protocol

protocol AppTheme: Sendable {
    var name: String { get }
    var colors: ThemeColors { get }
    var typography: ThemeTypography { get }
    var spacing: ThemeSpacing { get }
    var radius: ThemeRadius { get }
    var animation: ThemeAnimation { get }
}

// MARK: - Color Tokens

struct ThemeColors {
    // Backgrounds
    let windowBackground: Color
    let sidebarBackground: Color
    let editorBackground: Color
    let terminalBackground: Color

    // Text
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let codeText: Color

    // Interactive
    let accent: Color
    let accentSecondary: Color
    let selectionBackground: Color
    let hoverBackground: Color

    // Syntax highlighting
    let syntaxKeyword: Color
    let syntaxString: Color
    let syntaxComment: Color
    let syntaxNumber: Color
    let syntaxFunction: Color
    let syntaxType: Color

    // Borders & separators
    let separator: Color
    let borderSubtle: Color

    // Status
    let success: Color
    let warning: Color
    let error: Color
}

// MARK: - Typography Tokens

struct ThemeTypography {
    let editorFont: Font
    let editorFontSize: CGFloat
    let editorFontName: String  // for NSFont/AttributedString use
    let terminalFont: Font
    let terminalFontName: String
    let terminalFontSize: CGFloat
    let sidebarItemFont: Font
    let tabFont: Font
    let labelFont: Font
    let captionFont: Font
}

// MARK: - Spacing Tokens

struct ThemeSpacing {
    let sidebarWidth: CGFloat
    let sidebarMinWidth: CGFloat
    let sidebarMaxWidth: CGFloat
    let tabBarHeight: CGFloat
    let toolbarHeight: CGFloat
    let itemPadding: EdgeInsets
    let sectionPadding: EdgeInsets
    let iconSize: CGFloat
    let indentWidth: CGFloat
}

// MARK: - Radius Tokens

struct ThemeRadius {
    let small: CGFloat
    let medium: CGFloat
    let large: CGFloat
    let panel: CGFloat
}

// MARK: - Animation Tokens

struct ThemeAnimation {
    let standard: Animation
    let fast: Animation
    let slow: Animation
    let spring: Animation
}

// MARK: - Default Glacier Theme (Apple × Anthropic)

struct GlacierTheme: AppTheme {
    let name = "Glacier"

    var colors: ThemeColors {
        ThemeColors(
            windowBackground: Color(nsColor: .windowBackgroundColor),
            sidebarBackground: Color(nsColor: .controlBackgroundColor).opacity(0.6),
            editorBackground: Color(nsColor: .textBackgroundColor),
            terminalBackground: Color(red: 0.05, green: 0.05, blue: 0.07),

            primaryText: Color(nsColor: .labelColor),
            secondaryText: Color(nsColor: .secondaryLabelColor),
            tertiaryText: Color(nsColor: .tertiaryLabelColor),
            codeText: Color(nsColor: .labelColor),

            accent: Color.accentColor,
            accentSecondary: Color(red: 0.38, green: 0.62, blue: 0.95),
            selectionBackground: Color.accentColor.opacity(0.15),
            hoverBackground: Color(nsColor: .labelColor).opacity(0.05),

            syntaxKeyword: Color(red: 0.84, green: 0.31, blue: 0.51),
            syntaxString: Color(red: 0.93, green: 0.55, blue: 0.25),
            syntaxComment: Color(nsColor: .secondaryLabelColor),
            syntaxNumber: Color(red: 0.40, green: 0.68, blue: 0.94),
            syntaxFunction: Color(red: 0.53, green: 0.78, blue: 0.92),
            syntaxType: Color(red: 0.68, green: 0.87, blue: 0.73),

            separator: Color(nsColor: .separatorColor),
            borderSubtle: Color(nsColor: .separatorColor).opacity(0.5),

            success: .green,
            warning: .orange,
            error: .red
        )
    }

    var typography: ThemeTypography {
        ThemeTypography(
            editorFont: .system(size: 15, weight: .regular, design: .monospaced),
            editorFontSize: 15,
            editorFontName: "SFMono-Regular",
            terminalFont: .system(size: 15, weight: .regular, design: .monospaced),
            terminalFontName: "SFMono-Regular",
            terminalFontSize: 15,
            sidebarItemFont: .system(size: 14, weight: .regular),
            tabFont: .system(size: 14, weight: .medium),
            labelFont: .system(size: 15, weight: .regular),
            captionFont: .system(size: 13, weight: .regular)
        )
    }

    var spacing: ThemeSpacing {
        ThemeSpacing(
            sidebarWidth: 220,
            sidebarMinWidth: 160,
            sidebarMaxWidth: 360,
            tabBarHeight: 36,
            toolbarHeight: 52,
            itemPadding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8),
            sectionPadding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12),
            iconSize: 16,
            indentWidth: 16
        )
    }

    var radius: ThemeRadius {
        ThemeRadius(
            small: 4,
            medium: 8,
            large: 12,
            panel: 16
        )
    }

    var animation: ThemeAnimation {
        ThemeAnimation(
            standard: .easeInOut(duration: 0.2),
            fast: .easeInOut(duration: 0.12),
            slow: .easeInOut(duration: 0.35),
            spring: .spring(response: 0.35, dampingFraction: 0.75)
        )
    }
}

// MARK: - Theme Environment Key

private struct ThemeKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: any AppTheme = GlacierTheme()
}

extension EnvironmentValues {
    var appTheme: any AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
