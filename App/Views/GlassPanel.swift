import SwiftUI

extension View {
    /// Liquid Glass behind this view on iOS 26+ (optionally interactive), or the
    /// given fallback fill — `nil` for none — on earlier versions.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat, interactive: Bool = false,
                    fallback: HierarchicalShapeStyle?) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular,
                             in: .rect(cornerRadius: cornerRadius))
        } else if let fallback {
            self.background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}
