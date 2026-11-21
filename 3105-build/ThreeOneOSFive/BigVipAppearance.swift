
import SwiftUI
import UIKit

struct BigVipPrimaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var prefs: BigVipPreferences
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: prefs.largeButtons ? 54 : 44)
            .padding(.horizontal, 16)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.025, green: 0.07, blue: 0.13))
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [prefs.accent.opacity(0.48), .clear],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(prefs.accent.opacity(prefs.highContrast ? 1 : 0.6), lineWidth: prefs.highContrast ? 2 : 1))
            .shadow(color: prefs.accent.opacity(enabled ? 0.22 : 0), radius: configuration.isPressed ? 2 : 9, y: configuration.isPressed ? 1 : 5)
            .offset(y: configuration.isPressed && !prefs.reduceMotion && !systemReduceMotion ? 2 : 0)
            .opacity(enabled ? 1 : 0.45)
            .animation(prefs.reduceMotion || systemReduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct BigVipCardModifier: ViewModifier {
    @EnvironmentObject private var prefs: BigVipPreferences
    func body(content: Content) -> some View {
        content.padding(22)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(prefs.accent.opacity(prefs.highContrast ? 0.8 : 0.17), lineWidth: prefs.highContrast ? 2 : 1))
            .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
    }
}
extension View {
    func bigVipCard() -> some View { modifier(BigVipCardModifier()) }
}
