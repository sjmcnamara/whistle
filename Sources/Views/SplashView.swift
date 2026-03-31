import SwiftUI

/// Full-screen launch screen shown while the app connects to relays
/// and initialises the MLS encryption layer.
///
/// Dismissed automatically when `AppViewModel.startupPhase == .ready`.
struct SplashView: View {

    let phase: AppViewModel.StartupPhase

    @State private var logoScale: CGFloat = 0.75
    @State private var ringsAnimating = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer()
                logoSection
                Spacer()
                statusSection
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                logoScale = 1.0
            }
            withAnimation(.easeIn(duration: 0.3).delay(0.15)) {
                ringsAnimating = true
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - Logo

    private var logoSection: some View {
        VStack(spacing: 24) {
            ZStack {
                // Expanding rings — always rendered; opacity driven by ringsAnimating
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(.white.opacity(ringsAnimating ? 0.18 : 0), lineWidth: 1.5)
                        .frame(width: ringSize(i), height: ringSize(i))
                        .scaleEffect(ringsAnimating ? 1.0 : 0.6)
                        .animation(
                            .easeOut(duration: 2.2)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.65),
                            value: ringsAnimating
                        )
                }

                Image(systemName: "figure.2.and.child.holdinghands")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: phase != .ready)
            }
            .frame(width: 220, height: 220)
            .scaleEffect(logoScale)

            Text("whistle")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .scaleEffect(logoScale)
        }
    }

    private func ringSize(_ index: Int) -> CGFloat { 90 + CGFloat(index) * 44 }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.white.opacity(0.7))
                .scaleEffect(1.1)

            Text(phase.message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: phase.message)
        }
        .padding(.bottom, 56)
    }
}
