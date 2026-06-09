import SwiftUI

/// The layered, brand-tinted backdrop that sits behind every screen.
///
/// Liquid Glass refracts and blurs whatever is *behind* a surface. The previous
/// design failed because cards floated on flat white — there was nothing to
/// refract, so the glass rendered invisible. This view gives glass a vertical
/// brand gradient plus two soft colour blobs to pick up, which is what makes the
/// frosted surfaces actually read.
struct ScribeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ScribeTheme.gradientTop, ScribeTheme.gradientBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            // Soft colour blobs — low opacity, heavily blurred. Subtle to the eye,
            // but they give the glass real hue/contrast to refract at the edges.
            GeometryReader { geo in
                let blob = min(geo.size.width, geo.size.height) * 0.9
                ZStack {
                    Circle()
                        .fill(ScribeTheme.accent)
                        .frame(width: blob, height: blob)
                        .opacity(0.22)
                        .blur(radius: 90)
                        .offset(x: geo.size.width * 0.32, y: -geo.size.height * 0.18)
                    Circle()
                        .fill(ScribeTheme.secondary)
                        .frame(width: blob * 0.85, height: blob * 0.85)
                        .opacity(0.16)
                        .blur(radius: 100)
                        .offset(x: -geo.size.width * 0.34, y: geo.size.height * 0.42)
                }
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Apply the Scribe backdrop behind a screen's scrolling content and let the
    /// content scroll over it. Use on the root of each tab's screen.
    func scribeScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(ScribeBackground())
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            ForEach(0..<3) { _ in
                Text("Glass card")
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .glassEffect(.regular, in: .rect(cornerRadius: ScribeDesign.Radius.card))
            }
        }
        .padding()
    }
    .scribeScreen()
}
