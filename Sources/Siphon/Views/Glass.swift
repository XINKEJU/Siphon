import SwiftUI

// MARK: - Adaptive Liquid Glass
//
// Apple's macOS 26 "Liquid Glass" design rules applied throughout the app:
//
//  0. Window chrome is SYSTEM-OWNED. AppKit draws the window controls and the
//     unified title bar, SwiftUI draws toolbar items on their glass surfaces,
//     and NavigationSplitView draws the sidebar glass. Never add .glassEffect,
//     a tint or a custom background to those — it double-composites and breaks
//     the automatic scroll edge effect. That chrome only appears on macOS 26+
//     when the binary's LC_BUILD_VERSION.sdk is >= 26 (see Package.swift).
//  1. Custom glass belongs to the *floating* layer — small controls that sit
//     above content. Content (list rows, body text, progress bars, inspector
//     forms) stays opaque and crisp.
//  2. Neighbouring glass elements share one `GlassEffectContainer` so their
//     lenses merge and morph, instead of stacking independent blurred layers.
//  3. Interactive elements opt into `.interactive()` for press/hover refraction.
//  4. `tint()` is reserved for the primary action; neutral surfaces stay `.regular`.
//  5. Scroll content softens under translucent bars via `.scrollEdgeEffectStyle`.
//
// Every macOS 26 API below is gated behind `if #available(macOS 26.0, *)`.
// The package keeps its macOS 14 deployment target: 14/15 render equivalent
// material surfaces and bordered buttons, so a single binary works everywhere.

extension View {
    /// Neutral floating surface with a rounded-rectangle lens.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 16,
                   tint: Color? = nil,
                   interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive),
                             in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                }
        }
    }

    /// Capsule lens — status pills and compact actions.
    @ViewBuilder
    func glassPill(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive), in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay { Capsule().stroke(.separator.opacity(0.45), lineWidth: 0.5) }
        }
    }

    /// Circular lens — icon-only row controls. `.clear` keeps rows readable.
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear.tint(tint).interactive(), in: Circle())
        } else {
            self.background(.quaternary, in: Circle())
        }
    }

    /// Glass button on 26+, bordered button on earlier systems.
    /// A prominent action gets a restrained accent tint (26.1+ API).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if #available(macOS 26.1, *), prominent {
                self.buttonStyle(.glass(.regular
                    .tint(Color.accentColor.opacity(0.25))
                    .interactive()))
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Tag a glass element so it can morph between container layouts.
    @ViewBuilder
    func glassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Conditional glass elements morph in/out instead of popping.
    @ViewBuilder
    func glassMorphTransition() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectTransition(.matchedGeometry)
        } else {
            self
        }
    }

    /// Soften scrolling content under the translucent toolbar / floating bar.
    @ViewBuilder
    func softScrollTopEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// Groups adjacent glass elements into one lens system on macOS 26+.
/// On 14/15 the content is laid out in a plain HStack with equivalent spacing.
struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing ?? 12) { content }
            }
        } else {
            HStack(spacing: spacing ?? 12) { content }
        }
    }
}
