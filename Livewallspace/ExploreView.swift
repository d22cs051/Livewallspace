import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ExploreView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = ExploreViewModel()
    @State private var isShowingLocalPicker = false

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Explore")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.categories, id: \.self) { tag in
                            Button {
                                viewModel.selectedCategory = tag
                            } label: {
                                Text(tag)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                    .background(
                                        viewModel.selectedCategory == tag
                                        ? Color.white.opacity(0.22)
                                        : Color.white.opacity(0.08),
                                        in: Capsule(style: .continuous)
                                    )
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("MoeWalls")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Spacer()

                        Button("Refresh") {
                            Task {
                                await viewModel.loadMoewallsPosts(forceRefresh: true)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))

                        Button("Use Local MP4/MOV") {
                            isShowingLocalPicker = true
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                    }

                    Text("Browse latest wallpapers from moewalls.com and import directly, or choose your own local MP4/MOV file.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }

                LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
                    if viewModel.isLoadingPosts {
                        ProgressView("Loading MoeWalls wallpapers")
                            .padding(.top, 12)
                    }

                    ForEach(viewModel.pagedVisiblePosts, id: \.id) { post in
                        MoewallsPostCard(
                            post: post,
                            isImporting: viewModel.isImportingPostIDs.contains(post.id),
                            onImport: {
                                Task {
                                    await viewModel.importMoewallsPost(post, modelContext: modelContext)
                                }
                            }
                        )
                    }
                }

                if viewModel.hasMorePosts || viewModel.isLoadingMorePosts {
                    HStack {
                        Spacer()
                        Button {
                            Task {
                                await viewModel.loadMorePosts()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if viewModel.isLoadingMorePosts {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(viewModel.isLoadingMorePosts ? "Loading..." : "Load More")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                        .disabled(viewModel.isLoadingMorePosts || viewModel.isLoadingPosts)
                        Spacer()
                    }
                }

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
        .fileImporter(
            isPresented: $isShowingLocalPicker,
            allowedContentTypes: [.mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.setLocalVideo(url, modelContext: modelContext)
            case .failure(let error):
                viewModel.statusMessage = "Local import failed: \(error.localizedDescription)"
            }
        }
    }

}

private struct MoewallsPostCard: View {
    let post: MoewallsPost
    let isImporting: Bool
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: post.pageURL) {
                ZStack(alignment: .topLeading) {
                    CachedRemoteImage(url: post.thumbnailURL) {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.08, green: 0.17, blue: 0.34),
                                        Color(red: 0.26, green: 0.14, blue: 0.36)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }

                    Text(post.category)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.42), in: Capsule(style: .continuous))
                        .padding(10)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Text(post.title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .lineLimit(2)

            HStack(spacing: 8) {
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isImporting)

                Link(destination: post.pageURL) {
                    Text("Open")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 320, alignment: .top)
    }
}
