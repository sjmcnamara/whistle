import SwiftUI

/// First-run onboarding carousel shown once after the splash screen clears.
///
/// Walks new users through three feature cards explaining what Whistle is,
/// then shows a permission-framing screen before triggering the location
/// authorisation prompt. Dismissed permanently by setting
/// `AppSettings.hasCompletedOnboarding = true`.
struct OnboardingView: View {

    let locationService: LocationService
    let onComplete: () -> Void

    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(
            icon: "lock.shield.fill",
            title: "Private by design",
            body: "Your location is end-to-end encrypted using MLS. No server ever sees where you are — only your family group can."
        ),
        Page(
            icon: "person.crop.circle.badge.checkmark",
            title: "No accounts, no servers",
            body: "Whistle is built on Nostr — an open protocol. Your identity is a cryptographic key you own. No sign-up, no cloud."
        ),
        Page(
            icon: "antenna.radiowaves.left.and.right",
            title: "Always in touch",
            body: "Location updates run in the background so your family always knows where you are, even when the app is closed."
        )
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Image("WhistleLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * 0.42)
                    .foregroundStyle(.primary)
                    .padding(.top, 56)

                Spacer()

                Group {
                    if page < pages.count {
                        featurePage(pages[page])
                    } else {
                        permissionPage
                    }
                }
                .id(page)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.3), value: page)

                Spacer()

                if page < pages.count {
                    pageIndicator
                        .padding(.bottom, 20)
                }

                Button(action: advance) {
                    Text(page < pages.count ? "Next" : "Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.primary)
                        .foregroundStyle(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 48)
            }
        }
    }

    // MARK: - Subviews

    private func featurePage(_ item: Page) -> some View {
        VStack(spacing: 20) {
            Image(systemName: item.icon)
                .font(.system(size: 58))
                .foregroundStyle(.primary)

            Text(item.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(item.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private var permissionPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.fill")
                .font(.system(size: 58))
                .foregroundStyle(.primary)

            Text("One last thing")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Whistle needs location access to share your position with your family.\n\nYour location is always encrypted — only your group members can see it.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: index == page ? 20 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
    }

    // MARK: - Actions

    private func advance() {
        if page < pages.count {
            withAnimation { page += 1 }
        } else {
            locationService.requestAlwaysAuthorization()
            onComplete()
        }
    }
}
