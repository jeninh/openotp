import SwiftUI

struct GHContributor: Identifiable, Decodable {
    let login: String
    let avatar_url: String
    let html_url: String
    var id: String { login }
}

private struct GHUser: Decodable { let avatar_url: String }
private struct GHRepo: Decodable { let stargazers_count: Int }

@MainActor
final class GitHubModel: ObservableObject {
    static let repo = "jeninh/OpenOTP"
    var ownerLogin: String { String(Self.repo.split(separator: "/").first ?? "") }

    @Published var stars: Int?
    @Published var ownerAvatar: URL?
    @Published var contributors: [GHContributor] = []
    @Published var loading = true

    var repoURL: URL { URL(string: "https://github.com/\(Self.repo)")! }
    var ownerURL: URL { URL(string: "https://github.com/\(ownerLogin)")! }

    func load() async {
        loading = true
        defer { loading = false }
        // Owner avatar comes from the user endpoint, so it loads even before the
        // repo exists.
        if let user = await get(GHUser.self, "https://api.github.com/users/\(ownerLogin)") {
            ownerAvatar = URL(string: user.avatar_url)
        }
        if let repo = await get(GHRepo.self, "https://api.github.com/repos/\(Self.repo)") {
            stars = repo.stargazers_count
        }
        if let contribs = await get([GHContributor].self, "https://api.github.com/repos/\(Self.repo)/contributors?per_page=24") {
            contributors = contribs
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ urlString: String) async -> T? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

struct GitHubCard: View {
    @StateObject private var gh = GitHubModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(url: gh.ownerAvatar, size: 26)
                    .onTapGesture { openURL(gh.ownerURL) }
                Button { openURL(gh.repoURL) } label: {
                    Text(GitHubModel.repo)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                }
                .buttonStyle(.plain).foregroundStyle(.blue).focusable(false)
                Spacer()
                starPill
                Button { openURL(gh.repoURL) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.caption2)
                        Text("Star").font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.fillStrong))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ink).focusable(false)
            }

            if !gh.contributors.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    HStack(spacing: -8) {
                        ForEach(gh.contributors.prefix(10)) { c in
                            Button { openURL(URL(string: c.html_url)!) } label: {
                                Avatar(url: URL(string: c.avatar_url), size: 24)
                                    .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help(c.login)
                        }
                    }
                    Text("\(gh.contributors.count) contributor\(gh.contributors.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .task { await gh.load() }
    }

    private var starPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill").foregroundStyle(Theme.secondary).font(.caption2)
            if gh.loading && gh.stars == nil {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else if let s = gh.stars {
                Text(s.formatted()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text("0").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.fill))
    }
}

private struct Avatar: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Color.gray.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
