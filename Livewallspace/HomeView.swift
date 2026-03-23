import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var wallpaperManager = WallpaperManager.shared
    @StateObject private var viewModel = ExploreViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeroWallpaperView(
                    selectedVideoName: wallpaperManager.selectedVideoURL?.lastPathComponent,
                    featured: viewModel.moewallsPosts.first,
                    isImporting: viewModel.moewallsPosts.first.map { viewModel.isImportingPostIDs.contains($0.id) } ?? false,
                    onImport: {
                        guard let featured = viewModel.moewallsPosts.first else { return }
                        Task {
                            await viewModel.importMoewallsPost(featured, modelContext: modelContext)
                        }
                    }
                )

                MoeCarouselSection(
                    title: "Latest on MoeWalls",
                    items: Array(viewModel.moewallsPosts.prefix(10)),
                    importingIDs: viewModel.isImportingPostIDs,
                    onImport: { post in
                        Task {
                            await viewModel.importMoewallsPost(post, modelContext: modelContext)
                        }
                    }
                )

                MoeCarouselSection(
                    title: "More to Explore",
                    items: Array(viewModel.moewallsPosts.dropFirst(10).prefix(10)),
                    importingIDs: viewModel.isImportingPostIDs,
                    onImport: { post in
                        Task {
                            await viewModel.importMoewallsPost(post, modelContext: modelContext)
                        }
                    }
                )

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.76))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .task {
            await viewModel.loadMoewallsPosts()
        }
    }
}

private struct HeroWallpaperView: View {
    let selectedVideoName: String?
    let featured: MoewallsPost?
    let isImporting: Bool
    let onImport: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                CachedRemoteImage(url: featured?.thumbnailURL) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.08, blue: 0.13),
                            Color(red: 0.17, green: 0.20, blue: 0.28),
                            Color(red: 0.06, green: 0.06, blue: 0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.72), Color.black.opacity(0.26), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Immersive Mode")
                        .font(.system(size: geometry.size.width < 900 ? 24 : 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(featured?.title ?? selectedVideoName ?? "Loading latest MoeWalls wallpapers...")
                        .font(.system(size: geometry.size.width < 900 ? 13 : 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)

                    ViewThatFits(in: .horizontal) {
                        heroButtonsHorizontal
                        heroButtonsVertical
                    }
                }
                .frame(maxWidth: min(max(geometry.size.width * 0.72, 280), 720), alignment: .leading)
                .padding(18)
                .padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .frame(height: 330)
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.45))
                    .overlay {
                        Text("Live")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(width: 60, height: 24)

                if let selectedVideoName {
                    Text(selectedVideoName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(16)
        }
        .overlay(alignment: .bottomLeading) {
            Text("All wallpapers are sourced from MoeWalls.com; no copyright intended. Visit the website for perviews, better search and other features.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var heroButtonsHorizontal: some View {
        HStack(spacing: 8) {
            importButton
            if let pageURL = featured?.pageURL {
                openButton(for: pageURL)
            }
        }
    }

    private var heroButtonsVertical: some View {
        VStack(alignment: .leading, spacing: 8) {
            importButton
            if let pageURL = featured?.pageURL {
                openButton(for: pageURL)
            }
        }
    }

    private var importButton: some View {
        Button {
            onImport()
        } label: {
            HStack(spacing: 8) {
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isImporting ? "Importing..." : "Import & Apply")
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.88), in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(featured == nil || isImporting)
    }

    private func openButton(for pageURL: URL) -> some View {
        Link(destination: pageURL) {
            Text("Open on MoeWalls")
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.42), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MoeCarouselSection: View {
    let title: String
    let items: [MoewallsPost]
    let importingIDs: Set<String>
    let onImport: (MoewallsPost) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Link(destination: item.pageURL) {
                                ZStack(alignment: .topLeading) {
                                    CachedRemoteImage(url: item.thumbnailURL) {
                                        ProgressView()
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(
                                                LinearGradient(
                                                    colors: [
                                                        Color(red: 0.10, green: 0.22, blue: 0.52),
                                                        Color(red: 0.43, green: 0.18, blue: 0.58)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                    }

                                    Text(item.category)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.black.opacity(0.35), in: Capsule(style: .continuous))
                                        .padding(10)
                                }
                                .frame(width: 250, height: 146)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Text(item.title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .lineLimit(2)
                            Text(item.category)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))

                            Button {
                                onImport(item)
                            } label: {
                                HStack(spacing: 8) {
                                    if importingIDs.contains(item.id) {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(importingIDs.contains(item.id) ? "Importing..." : "Import & Apply")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(importingIDs.contains(item.id))
                        }
                        .frame(width: 250)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
