import SwiftUI

struct GlassButtonStyle: ButtonStyle {
    @AppStorage("theme_style") private var themeStyle: String = "standard"
    @AppStorage("glass_variant") private var glassVariantRaw: Int = 11
    var useCustomVariant: Bool = false
    var variant: GlassVariant = .v6
    var cornerRadius: CGFloat = 8
    
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if themeStyle == "glass" {
                let selectedVariant = useCustomVariant ? variant : (GlassVariant(rawValue: glassVariantRaw) ?? .v11)
                LiquidGlassBackground(variant: selectedVariant, cornerRadius: cornerRadius) {
                    configuration.label
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundColor(.white)
                        .fontWeight(.bold)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .opacity(configuration.isPressed ? 0.8 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            } else {
                configuration.label
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fontWeight(.bold)
                    .background(.ultraThinMaterial)
                    .cornerRadius(cornerRadius)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
                    .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
                }
        }
    }
}

struct GlassToggleStyle: ToggleStyle {
    @AppStorage("theme_style") private var themeStyle: String = "standard"
    var variant: GlassVariant = .v6
    var cornerRadius: CGFloat = 8
    
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack {
                configuration.label
                Spacer()
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(configuration.isOn ? .accentColor : .secondary)
            }
        }
        .buttonStyle(GlassButtonStyle(variant: variant, cornerRadius: cornerRadius))
    }
}

struct GlassButton<Label: View>: View {
    @AppStorage("theme_style") private var themeStyle: String = "standard"
    @AppStorage("glass_variant") private var glassVariantRaw: Int = 11
    var variant: GlassVariant = .v8
    var cornerRadius: CGFloat = 8
    let action: () -> Void
    let label: () -> Label
    
    @State private var isPressed = false
    
    var body: some View {
        label()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(.white)
            .fontWeight(.bold)
            .background(
                Group {
                    if themeStyle == "glass" {
                        LiquidGlassBackground(variant: variant, cornerRadius: cornerRadius) {
                            Color.clear
                        }
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.ultraThinMaterial)
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(isPressed ? 0.8 : 1.0)
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .onTapGesture {
                action()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
    }
}

extension View {
    func glassButtonStyle(variant: GlassVariant = .v6, cornerRadius: CGFloat = 8) -> some View {
        self.buttonStyle(GlassButtonStyle(useCustomVariant: true, variant: variant, cornerRadius: cornerRadius))
    }
    
    func glassToggleStyle(variant: GlassVariant = .v6, cornerRadius: CGFloat = 8) -> some View {
        self.toggleStyle(GlassToggleStyle(variant: variant, cornerRadius: cornerRadius))
    }
}