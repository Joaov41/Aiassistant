import SwiftUI

public enum GlassVariant: Int, CaseIterable, Identifiable, Sendable {
    case regular = 0
    case clear = 1
    case tinted = 2

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .regular: "Regular"
        case .clear: "Clear"
        case .tinted: "Tinted"
        }
    }

    var glass: Glass {
        switch self {
        case .regular: .regular
        case .clear: .clear
        case .tinted: .regular.tint(.white.opacity(0.15))
        }
    }
}

/// A SwiftUI view that renders its content inside a Liquid Glass material.
public struct LiquidGlassBackground<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat
    private let variant: GlassVariant

    /// Creates a new liquid‑glass container.
    /// - Parameters:
    ///   - variant: A ``GlassVariant``. Defaults to `.regular`.
    ///   - cornerRadius: Corner radius in points. Defaults to `10`.
    ///   - content: Your SwiftUI hierarchy.
    public init(
        variant: GlassVariant = .regular,
        cornerRadius: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.variant = variant
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .glassEffect(variant.glass, in: .rect(cornerRadius: cornerRadius))
    }
}
