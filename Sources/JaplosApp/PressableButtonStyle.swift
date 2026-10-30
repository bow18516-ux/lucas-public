import SwiftUI

/// Shared click feedback for chrome / icon / borderless buttons.
///
/// Japlos-v2 evidence (`V2WeChatPrimaryButton.makeBody`):
/// - conforms to `SwiftUI.ButtonStyle`
/// - reads `ButtonStyleConfiguration.isPressed`
/// - applies `_OpacityEffect` with **0.75** when pressed, **1.0** otherwise
///   (disasm: `bl isPressed` → `fmov d0, #0.75` → `fcsel` vs 1.0)
/// - no NSSound / NSHaptic for general UI clicks (NSSound only on alarm audio)
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
