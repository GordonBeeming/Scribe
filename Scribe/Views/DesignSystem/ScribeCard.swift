import SwiftUI

extension View {
    /// Standard glass card. Apply after content + internal padding is composed.
    /// `interactive` adds the touch-reactive glass for tappable cards.
    func scribeCard(
        padding: CGFloat = ScribeDesign.Spacing.l,
        interactive: Bool = false
    ) -> some View {
        self
            .padding(padding)
            .glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: ScribeDesign.Radius.card)
            )
    }

    /// Surface fill for a `Form`/`List` section shown over the Scribe gradient,
    /// so grouped rows read as soft cards instead of vanishing when the default
    /// grouped background is hidden. Apply to a `Section`.
    func scribeSection() -> some View {
        listRowBackground(ScribeTheme.surface.opacity(0.55))
    }

    /// Hero card for the primary summary surface — larger radius and a faint
    /// brand tint so it reads as the focal point of the screen.
    func scribeHeroCard(padding: CGFloat = ScribeDesign.Spacing.xl) -> some View {
        self
            .padding(padding)
            .glassEffect(
                .regular.tint(ScribeTheme.accent.opacity(0.18)),
                in: .rect(cornerRadius: ScribeDesign.Radius.hero)
            )
    }
}

/// A consistent section header used above grouped glass cards.
struct ScribeSectionHeader: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: ScribeDesign.Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(ScribeTheme.accent)
            }
            Text(title)
                .font(ScribeDesign.Font.sectionHeader)
                .foregroundStyle(ScribeTheme.primaryText)
            Spacer(minLength: 0)
        }
    }
}
