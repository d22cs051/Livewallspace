import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case explore = "Explore"
    case library = "Library"

    var id: String { rawValue }
}

struct MainShellView: View {
    @State private var selectedSection: AppSection = .home
    @State private var isShowingSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            appBackground

            Group {
                switch selectedSection {
                case .home:
                    HomeView()
                case .explore:
                    ExploreView()
                case .library:
                    LibraryView()
                }
            }
            .padding(.top, 94)

            TopNavigationPill(selectedSection: $selectedSection)
                .padding(.top, 20)

            HStack {
                Spacer()
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 24)
                .padding(.top, 20)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }

    private var appBackground: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [
                    Color(red: 0.13, green: 0.15, blue: 0.20),
                    Color(red: 0.04, green: 0.04, blue: 0.06),
                    Color.black
                ],
                center: .topLeading,
                startRadius: 80,
                endRadius: 900
            )
            .blendMode(.screen)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.06),
                    Color.black.opacity(0.46)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct TopNavigationPill: View {
    @Binding var selectedSection: AppSection

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppSection.allCases) { section in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedSection = section
                    }
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(selectedSection == section ? .black : .white.opacity(0.86))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if selectedSection == section {
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.94))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 12)
    }
}
