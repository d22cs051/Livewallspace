import Foundation
import AVFoundation

struct MoewallsPost: Identifiable, Hashable {
    let id: String
    let title: String
    let pageURL: URL
    let category: String
    var thumbnailURL: URL?
    var downloadToken: String?
}

enum MoewallsError: LocalizedError {
    case invalidFeedURL
    case noPostsFound
    case noDownloadToken(details: String)
    case badResponse
    case invalidDownloadedContent

    var errorDescription: String? {
        switch self {
        case .invalidFeedURL:
            return "MoeWalls feed URL is invalid."
        case .noPostsFound:
            return "Could not find wallpaper posts from MoeWalls."
        case .noDownloadToken(let details):
            if details.isEmpty {
                return "Could not resolve download token for this wallpaper."
            }
            return "Could not resolve download token for this wallpaper. \(details)"
        case .badResponse:
            return "Unexpected response while communicating with MoeWalls."
        case .invalidDownloadedContent:
            return "Downloaded file is not a valid video stream."
        }
    }
}

struct MoewallsService {
    typealias ImportProgressHandler = @Sendable (_ percent: Int, _ link: URL?) -> Void

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    private let requestTimeout: TimeInterval = 45
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatestPosts(page: Int = 1, limit: Int = 24) async throws -> [MoewallsPost] {
        let posts = try await fetchPostsFromWordPressAPI(page: page, limit: limit)

        guard !posts.isEmpty else {
            throw MoewallsError.noPostsFound
        }

        // Keep feed loading fast; detailed metadata/token discovery happens during import.
        return posts
    }

    func fetchPostMetadata(for pageURL: URL) async throws -> (thumbnailURL: URL?, downloadToken: String?) {
        var thumbnail: URL?
        var token: String?

        if let pageHTML = try? await fetchHTML(from: pageURL) {
            if thumbnail == nil {
                thumbnail = extractOGImage(from: pageHTML)
            }
            if token == nil {
                let htmlCandidates = [
                    pageHTML,
                    decodeHTMLEntities(pageHTML),
                    decodeJavaScriptEscapes(pageHTML)
                ]
                token = extractGoToken(fromTexts: htmlCandidates)
            }
        }

        if thumbnail == nil || token == nil,
           let slug = extractSlug(from: pageURL),
           !slug.isEmpty,
           let post = try? await fetchPostDetailsBySlug(slug)
        {
            if thumbnail == nil {
                thumbnail = post.embedded?.featuredMedia?.first?.sourceURL.flatMap(URL.init(string:))
            }

            if token == nil {
                let rawTextCandidates = [
                    post.title.rendered,
                    post.excerpt?.rendered,
                    post.content?.rendered
                ].compactMap { $0 }

                let decodedCandidates = rawTextCandidates.map { decodeHTMLEntities($0) }
                let tokenCandidates = rawTextCandidates + decodedCandidates
                token = extractGoToken(fromTexts: tokenCandidates)
            }
        }

        return (thumbnail, token)
    }

    func downloadWallpaperVideo(from post: MoewallsPost, progress: ImportProgressHandler? = nil) async throws -> URL {
        reportProgress(progress, percent: 5, link: post.pageURL)

        print("[MoeWalls] ========================================")
        print("[MoeWalls] Importing: \(post.title)")
        print("[MoeWalls] Post URL: \(post.pageURL.absoluteString)")
        print("[MoeWalls] ========================================")

        guard let pageHTML = try? await fetchHTML(from: post.pageURL) else {
            throw MoewallsError.noDownloadToken(details: "could not fetch page HTML")
        }

        // Try to find ALL download buttons on the page, not just lcc-wall
        let allDownloadTokens = extractAllDownloadTokens(from: pageHTML)
        print("[MoeWalls] Found \(allDownloadTokens.count) potential download token(s)")
        
        for (idx, token) in allDownloadTokens.enumerated() {
            print("[MoeWalls] ")
            print("[MoeWalls] Attempting token \(idx + 1) of \(allDownloadTokens.count)")
            print("[MoeWalls] Token (first 40 chars): \(token.prefix(40))...")
            print("[MoeWalls] Token length: \(token.count)")
            
            do {
                return try await downloadVideoUsingToken(token, post: post, progress: progress, tokenIndex: idx)
            } catch {
                print("[MoeWalls] ❌ Token \(idx + 1) FAILED: \(error.localizedDescription)")
                print("[MoeWalls] Trying next token...")
                continue
            }
        }

        throw MoewallsError.noDownloadToken(details: "no valid video download token found on page")
    }

    private func fetchAjaxDownloadCandidates(from pageHTML: String, pageURL: URL, fallbackPostID: String?) async throws -> [URL] {
        guard let nonce = extractAjaxNonce(from: pageHTML) else {
            throw MoewallsError.noDownloadToken(details: "ajax nonce not found in page html")
        }
        guard let postID = extractAjaxPostID(from: pageHTML, pageURL: pageURL, fallbackPostID: fallbackPostID) else {
            throw MoewallsError.noDownloadToken(details: "ajax post_id not found in page html/api")
        }

        guard let ajaxURL = URL(string: "https://moewalls.com/wp-admin/admin-ajax.php") else {
            throw MoewallsError.badResponse
        }

        var request = makeRequest(
            url: ajaxURL,
            referer: pageURL.absoluteString,
            accept: "*/*"
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        var payloadComponents = URLComponents()
        payloadComponents.queryItems = [
            URLQueryItem(name: "action", value: "link_click_counter"),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "post_id", value: postID)
        ]
        request.httpBody = payloadComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            throw MoewallsError.badResponse
        }

        let responseText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        guard !responseText.isEmpty else {
            return []
        }

        let textCandidates = [responseText, decodeHTMLEntities(responseText), decodeJavaScriptEscapes(responseText)]
        var urls = resolveGoDownloadURLs(fromTexts: textCandidates, baseURL: pageURL)
        for token in extractRawTokenCandidates(fromTexts: textCandidates) {
            if let goURL = buildGoDownloadURL(token: token) {
                urls.append(goURL)
            }
        }

        return orderedUniqueURLs(urls)
    }

    private func extractLccWallPrimaryToken(from html: String) -> String? {
        let anchors = reMatches(
            pattern: "(?is)<a[^>]*class\\s*=\\s*(?:\"[^\"]*lcc-wall[^\"]*\"|'[^']*lcc-wall[^']*')[^>]*>",
            in: html,
            captureGroup: 0
        )

        print("[MoeWalls] Found \(anchors.count) lcc-wall anchor(s)")

        for (index, anchor) in anchors.enumerated() {
            print("[MoeWalls] Anchor \(index): \(anchor.prefix(100))...")

            let urlToken = reMatches(
                pattern: "(?i)data-url\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)')",
                in: anchor,
                captureGroup: 1,
                alternateCaptureGroup: 2
            ).first

            if let urlToken,
               let sanitized = sanitizeExtractedToken(urlToken)
            {
                print("[MoeWalls] Using data-url token from anchor \(index)")
                return sanitized
            }

            let fallbackToken = reMatches(
                pattern: "(?i)data-download\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)')",
                in: anchor,
                captureGroup: 1,
                alternateCaptureGroup: 2
            ).first

            if let fallbackToken,
               let sanitized = sanitizeExtractedToken(fallbackToken)
            {
                print("[MoeWalls] Using data-download token from anchor \(index)")
                return sanitized
            }

            print("[MoeWalls] Anchor \(index) has no valid data-url or data-download attribute")
        }

        print("[MoeWalls] No valid lcc-wall token found in any anchor")
        return nil
    }

    private func extractAllDownloadTokens(from html: String) -> [String] {
        var tokens: [String] = []

        // Priority 1: lcc-wall button (but this might be thumbnail, we'll test and reject if needed)
        if let lccToken = extractLccWallPrimaryToken(from: html) {
            tokens.append(lccToken)
        }

        // Priority 2: Look for other download button selectors that might exist
        // Check for buttons with class containing "download" or similar
        let patterns = [
            "(?is)<a[^>]*class=\"[^\"]*download[^\"]*\"[^>]*data-url=\"([^\"]+)\"",
            "(?is)<a[^>]*data-url=\"([^\"]+)\"[^>]*class=\"[^\"]*download[^\"]*\"",
            "(?is)<button[^>]*data-token=\"([^\"]+)\"",
            "(?is)<a[^>]*href=\".*?go\\.moewalls\\.com.*?video=([A-Za-z0-9_\\-+%/=]{8,})\"",
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            for match in matches {
                guard let tokenRange = Range(match.range(at: 1), in: html) else { continue }
                let token = String(html[tokenRange])
                if let sanitized = sanitizeExtractedToken(token), !tokens.contains(sanitized) {
                    tokens.append(sanitized)
                }
            }
        }

        // Priority 3: Extract from og:video meta tag (might be direct video URL or token)
        if let ogVideo = extractOGImage(from: html)?.absoluteString {
            if let token = tokenFromDownloadURLString(ogVideo) {
                if let sanitized = sanitizeExtractedToken(token), !tokens.contains(sanitized) {
                    tokens.append(sanitized)
                }
            }
        }

        return orderedUniqueStrings(tokens)
    }

    private func reMatches(pattern: String, in text: String, captureGroup: Int, alternateCaptureGroup: Int? = nil) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var output: [String] = []
        for match in matches {
            var targetRange = match.range(at: captureGroup)
            if targetRange.location == NSNotFound,
               let alternateCaptureGroup
            {
                targetRange = match.range(at: alternateCaptureGroup)
            }

            guard targetRange.location != NSNotFound,
                  let stringRange = Range(targetRange, in: text)
            else {
                continue
            }

            output.append(String(text[stringRange]))
        }
        return output
    }

    private func extractAjaxNonce(from html: String) -> String? {
        let patterns = [
            "(?i)nonce\\s*[:=]\\s*[\"']([a-zA-Z0-9_\\-]{6,})[\"']",
            "(?i)_ajax_nonce\\s*[:=]\\s*[\"']([a-zA-Z0-9_\\-]{6,})[\"']",
            "(?i)\"nonce\"\\s*:\\s*\"([a-zA-Z0-9_\\-]{6,})\"",
            "(?i)nonce\\\\\"\\s*:\\s*\\\\\"([a-zA-Z0-9_\\-]{6,})\\\\\"",
            "(?i)data-nonce\\s*=\\s*[\"']([a-zA-Z0-9_\\-]{6,})[\"']"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               let nonceRange = Range(match.range(at: 1), in: html)
            {
                let value = String(html[nonceRange])
                if !value.isEmpty {
                    return value
                }
            }
        }

        return nil
    }

    private func extractAjaxPostID(from html: String, pageURL: URL, fallbackPostID: String?) -> String? {
        let patterns = [
            "(?i)post[_-]?id\\s*[:=]\\s*[\"']?([0-9]{3,})",
            "(?i)postid-([0-9]{3,})",
            "(?i)\\bpost-([0-9]{3,})\\b",
            "(?i)\"post_id\"\\s*:\\s*\"?([0-9]{3,})\"?"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               let idRange = Range(match.range(at: 1), in: html)
            {
                let value = String(html[idRange])
                if !value.isEmpty {
                    return value
                }
            }
        }

        if let fallbackPostID, !fallbackPostID.isEmpty {
            return fallbackPostID
        }

        let fallbackDigits = pageURL.lastPathComponent.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        if !fallbackDigits.isEmpty {
            return String(String.UnicodeScalarView(fallbackDigits))
        }

        return nil
    }

    private func downloadVideoUsingToken(_ token: String, post: MoewallsPost, progress: ImportProgressHandler? = nil, tokenIndex: Int = 0) async throws -> URL {
        let canonicalToken = canonicalizeTokenForQuery(token)
        guard let remoteURL = buildGoDownloadURL(token: canonicalToken) else {
            throw MoewallsError.badResponse
        }

        print("[MoeWalls] Download attempt using token \(tokenIndex + 1)")
        print("[MoeWalls] Token: \(canonicalToken)")
        print("[MoeWalls] Download URL: \(remoteURL.absoluteString)")

        reportProgress(progress, percent: 30, link: remoteURL)
        return try await downloadRemoteVideo(from: remoteURL, post: post, progress: progress, tokenIndex: tokenIndex)
    }

    private func resolveTokenStageCandidateURLs(from tokenURL: URL, post: MoewallsPost) async throws -> [URL] {
        let request = makeRequest(
            url: tokenURL,
            referer: post.pageURL.absoluteString,
            accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        )

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            return []
        }

        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        guard !html.isEmpty else {
            return []
        }

        let textCandidates = [html, decodeHTMLEntities(html), decodeJavaScriptEscapes(html)]
        var urls = resolveGoDownloadURLs(fromTexts: textCandidates, baseURL: tokenURL)

        let rawTokens = extractRawTokenCandidates(fromTexts: textCandidates)
        for token in rawTokens {
            if let goURL = buildGoDownloadURL(token: token) {
                urls.append(goURL)
            }
        }

        return orderedUniqueURLs(urls)
    }

    private func downloadRemoteVideo(from remoteURL: URL, post: MoewallsPost, progress: ImportProgressHandler? = nil, tokenIndex: Int = 0, recoveryDepth: Int = 0) async throws -> URL {
        reportProgress(progress, percent: 75, link: remoteURL)

        var request = makeRequest(
            url: remoteURL,
            referer: post.pageURL.absoluteString,
            accept: "*/*"
        )
        
        // Important: Allow redirects to be followed
        request.httpShouldHandleCookies = true

        let (temporaryURL, response) = try await session.download(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        let allHeaders = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        
        print("[MoeWalls] Response status: \(statusCode)")
        print("[MoeWalls] Content-Type: \(contentType)")
        
        guard (200...299).contains(statusCode) else {
            print("[MoeWalls] ❌ HTTP Error \(statusCode)")
            if let location = allHeaders["Location"] as? String {
                print("[MoeWalls] Redirect to: \(location)")
            }
            throw MoewallsError.badResponse
        }

        // Extract actual filename from response headers BEFORE accepting download
        let contentDisposition = (allHeaders["Content-Disposition"] as? String) ?? ""
        let serverFileName = parseFileName(fromContentDisposition: contentDisposition)
        
        print("[MoeWalls] Content-Disposition header: \(contentDisposition)")
        print("[MoeWalls] Server filename: \(serverFileName ?? "none")")
        
        // Verify this is actually a video file by checking headers and signature
        let isVideo = try await isLikelyVideoDownload(at: temporaryURL, response: response)
        guard isVideo else {
            // If we got HTML, try to parse it for error details or redirect
            if contentType.contains("text/html") || contentType.contains("application/json") {
                if let textPayload = try readTextPayload(from: temporaryURL) {
                    print("[MoeWalls] ⚠️  Got HTML response instead of video")
                    print("[MoeWalls] HTML snippet: \(textPayload.prefix(300))...")

                    if recoveryDepth < 3 {
                        let recoveryURLs = extractRecoveryDownloadURLs(from: textPayload, baseURL: remoteURL)
                            .filter { $0.absoluteString != remoteURL.absoluteString }

                        if !recoveryURLs.isEmpty {
                            print("[MoeWalls] 🔄 Found \(recoveryURLs.count) recovery URL candidate(s) in HTML payload")
                            try FileManager.default.removeItem(at: temporaryURL)

                            for candidate in recoveryURLs {
                                do {
                                    print("[MoeWalls] Trying recovery URL: \(candidate.absoluteString.prefix(120))...")
                                    return try await downloadRemoteVideo(
                                        from: candidate,
                                        post: post,
                                        progress: progress,
                                        tokenIndex: tokenIndex,
                                        recoveryDepth: recoveryDepth + 1
                                    )
                                } catch {
                                    print("[MoeWalls] Recovery URL failed: \(error.localizedDescription)")
                                    continue
                                }
                            }
                        }
                    }

                    if isLikelyTokenErrorPage(textPayload) {
                        print("[MoeWalls] ❌ Server returned token error page")
                        throw MoewallsError.noDownloadToken(details: "go.moewalls.com returned token error - token may be invalid or expired")
                    }
                }
            }
            
            let fileSize = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber
            print("[MoeWalls] Downloaded file is NOT video. Size: \(fileSize?.int64Value ?? 0) bytes")
            try FileManager.default.removeItem(at: temporaryURL)
            throw MoewallsError.invalidDownloadedContent
        }

        let fileSize = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber
        print("[MoeWalls] ✓ Downloaded video file. Size: \(fileSize?.int64Value ?? 0) bytes")

        let destination = try destinationURL(for: post.title, response: response)
        let destinationFileName = destination.lastPathComponent
        
        // Extract core wallpaper name (remove "Live Wallpaper" suffix)
        let coreTitle = post.title
            .replacingOccurrences(of: " Live Wallpaper", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        let sanitizedCoreTitle = sanitizeFileName(coreTitle)
        
        print("[MoeWalls] Expected core name: \(sanitizedCoreTitle).*")
        print("[MoeWalls] Actual saved filename: \(destinationFileName)")
        
        // Verify filename contains the core wallpaper name (more lenient for server variations)
        let filenameLowercase = destinationFileName.lowercased()
        let coreMatches = filenameLowercase.contains(sanitizedCoreTitle.lowercased())
        
        if !coreMatches {
            print("[MoeWalls] ⚠️  WARNING: Filename does NOT contain core wallpaper name!")
            print("[MoeWalls] Downloaded for: Unknown (possible wrong video)")
            print("[MoeWalls] Expected core in: \(post.title)")
            throw MoewallsError.invalidDownloadedContent
        }
        
        print("[MoeWalls] ✓ Filename validation passed (core name matched)")
        
        print("[MoeWalls] ✅ SUCCESS: Token \(tokenIndex + 1) downloaded correct video!")
        print("[MoeWalls] File: \(destinationFileName)")
        
        let manager = FileManager.default

        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temporaryURL, to: destination)

        print("[MoeWalls] Saved to: \(destination.path)")
        reportProgress(progress, percent: 95, link: remoteURL)
        return destination
    }

    private func readTextPayload(from fileURL: URL) throws -> String? {
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return nil
        }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1), !latin1.isEmpty {
            return latin1
        }
        return nil
    }

    private func extractRedirectURL(from html: String) -> URL? {
        // Look for common redirect patterns
        let patterns = [
            // HTML meta refresh
            "(?i)<meta\\s+http-equiv\\s*=\\s*[\"']refresh[\"']\\s+content\\s*=\\s*[\"']\\d+;\\s*url\\s*=\\s*([^\"']+)[\"']",
            // JavaScript window.location
            "(?i)window\\.location\\s*=\\s*[\"']([^\"']+)[\"']",
            "(?i)window\\.location\\.href\\s*=\\s*[\"']([^\"']+)[\"']",
            // HTML href link
            "(?i)<a\\s+href\\s*=\\s*[\"']([^\"']+download[^\"']*)[\"']",
        ]
        
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               let urlRange = Range(match.range(at: 1), in: html) {
                let urlString = String(html[urlRange])
                if let url = URL(string: urlString) ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
                    return url
                }
            }
        }
        
        return nil
    }

    private func isLikelyTokenErrorPage(_ html: String) -> Bool {
        let lowered = html.lowercased()

        if lowered.contains("err=1001") || lowered.contains("err=1002") {
            return true
        }

        let patterns = [
            "(?i)invalid\\s+token",
            "(?i)token\\s+expired",
            "(?i)download\\s+failed",
            "(?i)access\\s+denied"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)) != nil {
                return true
            }
        }

        return false
    }

    private func extractRecoveryDownloadURLs(from html: String, baseURL: URL) -> [URL] {
        let candidates = [
            html,
            decodeHTMLEntities(html),
            decodeJavaScriptEscapes(html)
        ]

        var urls: [URL] = []

        if let redirectURL = extractRedirectURL(from: html) {
            urls.append(redirectURL)
        }

        urls.append(contentsOf: resolveGoDownloadURLs(fromTexts: candidates, baseURL: baseURL))

        let rawTokens = extractRawTokenCandidates(fromTexts: candidates)
        for token in rawTokens {
            if let goURL = buildGoDownloadURL(token: token) {
                urls.append(goURL)
            }
        }

        let anyURLs = resolveAnyURLs(fromTexts: candidates, baseURL: baseURL)
        for url in anyURLs {
            if isGoDownloadURL(url) {
                urls.append(url)
                continue
            }

            let path = url.path.lowercased()
            if path.hasSuffix(".mp4") || path.hasSuffix(".webm") || path.contains("/download") {
                urls.append(url)
            }
        }

        return orderedUniqueURLs(urls)
    }

    private func isLikelyVideoDownload(at fileURL: URL, response: URLResponse) async throws -> Bool {
        if let mimeType = response.mimeType?.lowercased(), !mimeType.isEmpty {
            // Accept video mimes
            if mimeType.hasPrefix("video/") {
                print("[MoeWalls] ✓ MIME type is video/")
                return true
            }
            // REJECT image mimes (thumbnails!)
            if mimeType.hasPrefix("image/") {
                print("[MoeWalls] ❌ MIME type is image/ — This is a thumbnail, not a video!")
                return false
            }
            // Reject HTML/JSON
            if mimeType.contains("html") || mimeType.contains("json") || mimeType.contains("xml") || mimeType.contains("text/") {
                print("[MoeWalls] ❌ MIME type is \(mimeType) — This is not a video file!")
                return false
            }
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64)
        guard !data.isEmpty else {
            print("[MoeWalls] ❌ Downloaded file is empty!")
            return false
        }

        // Check for video signatures
        if data.count >= 8 {
            let ftyp = Data([0x66, 0x74, 0x79, 0x70])
            if data.subdata(in: 4..<8) == ftyp {
                print("[MoeWalls] ✓ File signature is MP4 (ftyp)")
                return true
            }
        }

        if data.count >= 4 {
            let webm = Data([0x1A, 0x45, 0xDF, 0xA3])
            if data.subdata(in: 0..<4) == webm {
                print("[MoeWalls] ✓ File signature is WebM")
                return true
            }
        }

        // Reject image signatures (JPEG, PNG, WEBP)
        if data.count >= 2 && data[0..<2] == Data([0xFF, 0xD8]) {
            print("[MoeWalls] ❌ File signature is JPEG — This is a thumbnail image!")
            return false
        }

        if data.count >= 8 && data.subdata(in: 0..<8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            print("[MoeWalls] ❌ File signature is PNG — This is a thumbnail image!")
            return false
        }

        if data.count >= 4 && data.subdata(in: 0..<4) == Data([0x52, 0x49, 0x46, 0x46]) {
            // Could be WEBP or WAV
            if data.count >= 12 {
                let webpSignature = data.subdata(in: 8..<12)
                if webpSignature == Data([0x57, 0x45, 0x42, 0x50]) {
                    print("[MoeWalls] ❌ File signature is WebP — This is a thumbnail image!")
                    return false
                }
            }
        }

        // Last resort: try to load as video asset
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        if !tracks.isEmpty {
            print("[MoeWalls] ✓ AVURLAsset confirmed video tracks")
            return true
        }

        print("[MoeWalls] ❌ File has no video signature and no video tracks")
        return false
    }

    private func fetchData(from url: URL) async throws -> Data {
        let request = makeRequest(url: url)
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            throw MoewallsError.badResponse
        }
        return data
    }

    private func fetchHTML(from url: URL) async throws -> String {
        let data = try await fetchData(from: url)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw MoewallsError.badResponse
        }
        return html
    }

    private func makeRequest(url: URL, referer: String? = nil, accept: String = "*/*") -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("https://moewalls.com", forHTTPHeaderField: "Origin")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private func reportProgress(_ progress: ImportProgressHandler?, percent: Int, link: URL?) {
        let clamped = min(100, max(0, percent))
        progress?(clamped, link)
    }

    private func resolveGoDownloadURLs(fromTexts texts: [String], baseURL: URL) -> [URL] {
        var urls: [URL] = []

        let patterns = [
            "(?i)(https?:\\/\\/go\\.moewalls\\.com\\/download\\.php\\?video=[^\"'\\s>]+)",
            "(?i)(?:href|src|data-url|data-download)\\s*=\\s*\"([^\"]*go\\.moewalls\\.com\\/download\\.php\\?video=[^\"]+)\"",
            "(?i)(?:href|src|data-url|data-download)\\s*=\\s*'([^']*go\\.moewalls\\.com\\/download\\.php\\?video=[^']+)'",
            "(?i)download\\.php\\?video=([A-Za-z0-9_\\-+%/=.]+)"
        ]

        print("[MoeWalls] [URLExtraction] Searching for go.moewalls.com URLs with \(patterns.count) patterns")

        for (_, text) in texts.enumerated() {
            for (patternIndex, pattern) in patterns.enumerated() {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                    print("[MoeWalls] [URLExtraction] Pattern \(patternIndex + 1): Failed to compile regex")
                    continue
                }

                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let matches = regex.matches(in: text, options: [], range: range)
                
                if matches.count > 0 {
                    print("[MoeWalls] [URLExtraction] Pattern \(patternIndex + 1): Found \(matches.count) match(es)")
                }

                for match in matches {
                    guard let candidateRange = Range(match.range(at: 1), in: text) else {
                        continue
                    }

                    let rawCandidate = String(text[candidateRange])

                    if rawCandidate.contains("download.php?video=") && !rawCandidate.contains("go.moewalls.com") {
                        if let token = tokenFromDownloadURLString(rawCandidate),
                           let url = buildGoDownloadURL(token: token) {
                            urls.append(url)
                        }
                        continue
                    }

                    if let url = normalizeURLCandidate(rawCandidate, baseURL: baseURL),
                       isGoDownloadURL(url)
                    {
                        urls.append(url)
                    }
                }
            }
        }

        return urls
    }

    private func resolveAnyURLs(fromTexts texts: [String], baseURL: URL) -> [URL] {
        var urls: [URL] = []

        let patterns = [
            "(?i)(https?:\\/\\/[^\"'\\s>]+)",
            "(?i)(?:href|src|data-url|data-download)\\s*=\\s*\"([^\"]+)\"",
            "(?i)(?:href|src|data-url|data-download)\\s*=\\s*'([^']+)'"
        ]

        for text in texts {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    continue
                }
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let matches = regex.matches(in: text, options: [], range: range)

                for match in matches {
                    guard let candidateRange = Range(match.range(at: 1), in: text) else {
                        continue
                    }

                    let rawValue = String(text[candidateRange])
                    guard let url = normalizeURLCandidate(rawValue, baseURL: baseURL) else {
                        continue
                    }

                    let scheme = url.scheme?.lowercased() ?? ""
                    guard scheme == "http" || scheme == "https" else {
                        continue
                    }

                    let absolute = url.absoluteString.lowercased()
                    if absolute.hasPrefix("javascript:") || absolute.hasPrefix("mailto:") {
                        continue
                    }

                    urls.append(url)
                }
            }
        }

        return orderedUniqueURLs(urls)
    }

    private func extractRawTokenCandidates(fromTexts texts: [String]) -> [String] {
        var tokens: [String] = []

        let patterns = [
            "(?i)(?:video|download_token|moe_download)\\s*[:=]\\s*[\"']?([A-Za-z0-9_\\-+%/=]{6,})",
            "(?i)download\\.php\\?video=([A-Za-z0-9_\\-+%/=]{6,})",
            "(?i)video%3[Dd]([A-Za-z0-9_\\-+%/=]{6,})",
            "(?i)video\\x3[dD]([A-Za-z0-9_\\-+%/=]{6,})",
            "(?i)(?:data-url|data-download)\\s*=\\s*[\"']([A-Za-z0-9_\\-+%/=]{8,})[\"']",
            "(?i)atob\\([\"']([A-Za-z0-9+/=]{8,})[\"']\\)"
        ]

        for text in texts {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                    continue
                }

                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let matches = regex.matches(in: text, options: [], range: range)
                for match in matches {
                    guard let tokenRange = Range(match.range(at: 1), in: text) else {
                        continue
                    }

                    let rawValue = String(text[tokenRange])

                    if pattern.lowercased().contains("atob") {
                        if let decodedData = Data(base64Encoded: rawValue),
                           let decodedString = String(data: decodedData, encoding: .utf8)
                        {
                            let nestedTokens = extractRawTokenCandidates(fromTexts: [decodedString])
                            tokens.append(contentsOf: nestedTokens)
                        }
                        continue
                    }

                    if let sanitized = sanitizeExtractedToken(rawValue) {
                        tokens.append(sanitized)
                    }
                }
            }
        }

        return orderedUniqueStrings(tokens)
    }

    private func buildGoDownloadURL(token: String) -> URL? {
        let canonicalToken = canonicalizeTokenForQuery(token)
        guard let encodedToken = encodeTokenForQuery(canonicalToken) else {
            return nil
        }
        return URL(string: "https://go.moewalls.com/download.php?video=\(encodedToken)")
    }

    private func canonicalizeTokenForQuery(_ value: String) -> String {
        let normalized = normalizeToken(value)
        if let decoded = normalized.removingPercentEncoding, !decoded.isEmpty {
            return decoded
        }
        return normalized
    }

    private func encodeTokenForQuery(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private func normalizeURLCandidate(_ candidate: String, baseURL: URL) -> URL? {
        let cleaned = decodeJavaScriptEscapes(decodeHTMLEntities(candidate))
            .replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\"'"))

        guard !cleaned.isEmpty else {
            return nil
        }

        if cleaned.hasPrefix("//") {
            return URL(string: "https:" + cleaned)
        }

        if let absolute = URL(string: cleaned), absolute.host != nil {
            return absolute
        }

        return URL(string: cleaned, relativeTo: baseURL)?.absoluteURL
    }

    private func extractGoToken(fromTexts texts: [String]) -> String? {
        for text in texts {
            // 0. PRIORITY: Try moe-download button (modern MoeWalls pages use JavaScript)
            if let moeToken = extractMoeDownloadToken(text) {
                print("[MoeWalls] [TokenExtraction] ✓ Found token in moe-download button: \(String(moeToken.prefix(12)))...")
                return moeToken
            }

            // 1. Try direct URLs first
            let urls = resolveGoDownloadURLs(fromTexts: [text], baseURL: URL(string: "https://moewalls.com")!)
            for url in urls {
                if let token = tokenFromDownloadURLString(url.absoluteString) {
                    return token
                }
            }

            // 2. Try JSON extraction (video tokens often in JSON data)
            if let jsonToken = extractTokenFromJSON(text) {
                print("[MoeWalls] [TokenExtraction] ✓ Found token in JSON data: \(String(jsonToken.prefix(8)))...")
                return jsonToken
            }

            // 3. Try data attribute extraction
            if let dataToken = extractTokenFromDataAttributes(text) {
                print("[MoeWalls] [TokenExtraction] ✓ Found token in data attributes: \(String(dataToken.prefix(8)))...")
                return dataToken
            }

            // 4. Try variable assignment pattern
            let fallbackPattern = "(?i)(?:video|download_token|moe_download|token|videoId|video_id)\\s*[:=]\\s*['\\\"]?([A-Za-z0-9_\\-+%/=.]{6,})['\\\"]?"
            if let regex = try? NSRegularExpression(pattern: fallbackPattern, options: []) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let matches = regex.matches(in: text, options: [], range: range)
                print("[MoeWalls] [TokenExtraction] [Var] Variable assignment pattern found \(matches.count) match(es)")
                if let match = matches.first,
                   let tokenRange = Range(match.range(at: 1), in: text)
                {
                    let token = String(text[tokenRange])
                    print("[MoeWalls] [TokenExtraction] [Var] Extracted candidate: '\(token.prefix(12))...'")
                    if let sanitized = sanitizeExtractedToken(token) {
                        print("[MoeWalls] [TokenExtraction] ✓ Found token in variable assignment: \(String(sanitized.prefix(8)))...")
                        return sanitized
                    } else {
                        print("[MoeWalls] [TokenExtraction] [Var] ✗ Sanitization failed for: \(token.prefix(20))")
                    }
                }
            }
        }

        return nil
    }

    private func extractMoeDownloadToken(_ html: String) -> String? {
        print("[MoeWalls] [TokenExtraction] [MoeBtn] Searching for moe-download button...")
        
        // Look for: <a id="moe-download" ... data-url="TOKEN"
        // The token can be long and contain encoded characters like %2B
        let pattern = "(?i)<a[^>]*id\\s*=\\s*['\"]?moe-download['\"]?[^>]*data-url\\s*=\\s*[\"']([^\"']+)[\"']"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            print("[MoeWalls] [TokenExtraction] [MoeBtn] Failed to compile regex")
            return nil
        }
        
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range),
           let tokenRange = Range(match.range(at: 1), in: html) {
            let token = String(html[tokenRange])
            print("[MoeWalls] [TokenExtraction] [MoeBtn] Found candidate: \(token.prefix(30))...")
            
            // For moe-download tokens, use stricter validation
            // These tokens are typically long, alphanumeric with +, /, %, =
            if token.count >= 20 && isValidMoeDownloadToken(token) {
                print("[MoeWalls] [TokenExtraction] [MoeBtn] ✓ Valid moe-download token")
                return token
            } else {
                print("[MoeWalls] [TokenExtraction] [MoeBtn] ✗ Token validation failed: length=\(token.count)")
            }
        } else {
            print("[MoeWalls] [TokenExtraction] [MoeBtn] No moe-download button found")
        }
        
        return nil
    }

    private func isValidMoeDownloadToken(_ token: String) -> Bool {
        // Moe-download tokens are typically long base64-like strings
        // They contain: a-z, A-Z, 0-9, +, /, %, =, -
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/%=-")
        
        // Reject obviously wrong values
        let lowered = token.lowercased()
        let blockedFragments = ["document.", "window.", "location.", "javascript", "http://", "https://"]
        if blockedFragments.contains(where: { lowered.contains($0) }) {
            return false
        }
        
        // Token must be mostly valid characters
        let validCount = token.filter { valid.contains($0.unicodeScalars.first ?? UnicodeScalar(0)) }.count
        return Double(validCount) / Double(token.count) > 0.9
    }

    private func extractTokenFromJSON(_ html: String) -> String? {
        // Extract tokens from JSON embedded in script tags or directly in HTML
        let jsonPatterns = [
            // {"video":"TOKEN"} or {"video_id":"TOKEN"}
            "(?i)[\"'](?:video|videoId|video_id|token)[\"']\\s*:\\s*[\"']([A-Za-z0-9_\\-+%/=.]{6,})[\"']",
            // "video":{"url":"...?video=TOKEN"...}
            "(?i)[\"'](?:video|download)[\"']\\s*:\\s*\\{[^}]*[\"']url[\"']\\s*:\\s*[\"']([^\"']*video=([A-Za-z0-9_\\-+%/=.]{6,}))?"
        ]

        print("[MoeWalls] [TokenExtraction] [JSON] Trying \(jsonPatterns.count) JSON patterns...")
        
        for (patternIdx, pattern) in jsonPatterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                print("[MoeWalls] [TokenExtraction] [JSON] Pattern \(patternIdx + 1): Failed to compile regex")
                continue
            }

            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            print("[MoeWalls] [TokenExtraction] [JSON] Pattern \(patternIdx + 1): Found \(matches.count) match(es)")
            
            if let match = matches.first {
                // Try group 1 first (direct token), then group 2 (token from URL)
                for groupIdx in [1, 2] {
                    let groupRange = match.range(at: groupIdx)
                    if groupRange.location != NSNotFound,
                       let tokenRange = Range(groupRange, in: html) {
                        let token = String(html[tokenRange])
                        print("[MoeWalls] [TokenExtraction] [JSON] Extracted candidate from group \(groupIdx): '\(token.prefix(12))...'")
                        if let sanitized = sanitizeExtractedToken(token) {
                            print("[MoeWalls] [TokenExtraction] [JSON] ✓ Sanitized successfully")
                            return sanitized
                        } else {
                            print("[MoeWalls] [TokenExtraction] [JSON] ✗ Sanitization failed")
                        }
                    }
                }
            }
        }

        print("[MoeWalls] [TokenExtraction] [JSON] No valid tokens found in JSON")
        return nil
    }

    private func extractTokenFromDataAttributes(_ html: String) -> String? {
        // Extract tokens from data-* attributes
        let dataAttributePatterns = [
            // data-video="TOKEN"
            "(?i)data-(?:video|video-id|video-token|token|wallpaper-id)\\s*=\\s*[\"']([A-Za-z0-9_\\-+%/=.]{6,})[\"']",
            // data-download-url="...?video=TOKEN"
            "(?i)data-(?:download|download-url)\\s*=\\s*[\"']([^\"']*video=([A-Za-z0-9_\\-+%/=.]{6,}))"
        ]

        print("[MoeWalls] [TokenExtraction] [DataAttrs] Trying \(dataAttributePatterns.count) data attribute patterns...")
        
        for (patternIdx, pattern) in dataAttributePatterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                print("[MoeWalls] [TokenExtraction] [DataAttrs] Pattern \(patternIdx + 1): Failed to compile regex")
                continue
            }

            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            print("[MoeWalls] [TokenExtraction] [DataAttrs] Pattern \(patternIdx + 1): Found \(matches.count) match(es)")
            
            if let match = matches.first {
                // Try group 1 first (direct token), then group 2 (token from URL)
                for groupIdx in [1, 2] {
                    let groupRange = match.range(at: groupIdx)
                    if groupRange.location != NSNotFound,
                       let tokenRange = Range(groupRange, in: html) {
                        let token = String(html[tokenRange])
                        print("[MoeWalls] [TokenExtraction] [DataAttrs] Extracted candidate from group \(groupIdx): '\(token.prefix(12))...'")
                        if let sanitized = sanitizeExtractedToken(token) {
                            print("[MoeWalls] [TokenExtraction] [DataAttrs] ✓ Sanitized successfully")
                            return sanitized
                        } else {
                            print("[MoeWalls] [TokenExtraction] [DataAttrs] ✗ Sanitization failed")
                        }
                    }
                }
            }
        }

        print("[MoeWalls] [TokenExtraction] [DataAttrs] No valid tokens found in data attributes")
        return nil
    }

    private func tokenFromDownloadURLString(_ value: String) -> String? {
        let normalized = value.replacingOccurrences(of: "\\/", with: "/")

        if let url = URL(string: normalized),
           isGoDownloadURL(url),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let token = components.queryItems?.first(where: { $0.name.lowercased() == "video" })?.value,
           !token.isEmpty {
            return sanitizeExtractedToken(token)
        }

        guard let range = normalized.range(of: "video=", options: [.caseInsensitive]) else {
            return nil
        }

        let candidate = String(normalized[range.upperBound...])
        let token = candidate.split(separator: "&", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        guard let token, !token.isEmpty else {
            return nil
        }
        return sanitizeExtractedToken(token)
    }

    private func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }

    private func orderedUniqueURLs(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        for value in values {
            let key = value.absoluteString
            if seen.insert(key).inserted {
                output.append(value)
            }
        }
        return output
    }

    private func normalizeToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\"'"))
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func sanitizeExtractedToken(_ value: String) -> String? {
        let token = normalizeToken(value)
        guard isLikelyVideoToken(token) else {
            return nil
        }
        return token
    }

    private func isLikelyVideoToken(_ value: String) -> Bool {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 8 else {
            return false
        }

        let lowered = token.lowercased()
        let blockedExact = Set([
            "document", "window", "location", "href", "src", "null", "undefined",
            "true", "false", "this", "self", "top", "parent"
        ])
        if blockedExact.contains(lowered) {
            return false
        }

        let blockedFragments = [
            "document.",
            "window.",
            "location.",
            "getelementby",
            "queryselector",
            "addeventlistener",
            "createelement",
            "appendchild"
        ]
        if blockedFragments.contains(where: { lowered.contains($0) }) {
            return false
        }

        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return false
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-+%/=.")
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func isGoDownloadURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "go.moewalls.com" && url.path.lowercased() == "/download.php"
    }

    private func fetchPostsFromWordPressAPI(page: Int, limit: Int) async throws -> [MoewallsPost] {
        var components = URLComponents(string: "https://moewalls.com/wp-json/wp/v2/posts")
        components?.queryItems = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "per_page", value: String(min(max(1, limit), 50))),
            URLQueryItem(name: "_embed", value: "1")
        ]

        guard let apiURL = components?.url else {
            throw MoewallsError.invalidFeedURL
        }

        let data = try await fetchData(from: apiURL)
        let decoded = try JSONDecoder().decode([WordPressPost].self, from: data)

        return decoded.compactMap { post in
            guard let pageURL = URL(string: post.link), isLikelyWallpaperPageURL(pageURL) else {
                return nil
            }

            let cleanedTitle = decodeHTMLEntities(stripHTMLTags(from: post.title.rendered))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTitle.isEmpty else {
                return nil
            }

            let thumbnailURL = post.embedded?.featuredMedia?.first?.sourceURL.flatMap(URL.init(string:))
            let category = resolveCategory(from: post)

            return MoewallsPost(
                id: post.link,
                title: cleanedTitle,
                pageURL: pageURL,
                category: category,
                thumbnailURL: thumbnailURL,
                downloadToken: nil
            )
        }
    }

    private func isLikelyWallpaperPageURL(_ url: URL) -> Bool {
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard components.count >= 2 else {
            return false
        }

        if components.first?.lowercased() == "page" {
            return false
        }

        let slug = components.last?.lowercased() ?? ""
        return slug.contains("live-wallpaper")
    }

    private func resolveCategory(from post: WordPressPost) -> String {
        let categoryTerm = post.embedded?.terms?
            .flatMap { $0 }
            .first(where: { ($0.taxonomy ?? "") == "category" })

        let trimmedName = categoryTerm?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "MoeWalls" : trimmedName
    }

    private func fetchPostDetailsBySlug(_ slug: String) async throws -> WordPressPost {
        var components = URLComponents(string: "https://moewalls.com/wp-json/wp/v2/posts")
        components?.queryItems = [
            URLQueryItem(name: "slug", value: slug),
            URLQueryItem(name: "_embed", value: "1")
        ]

        guard let apiURL = components?.url else {
            throw MoewallsError.invalidFeedURL
        }

        let data = try await fetchData(from: apiURL)
        let posts = try JSONDecoder().decode([WordPressPost].self, from: data)

        guard let post = posts.first else {
            throw MoewallsError.badResponse
        }

        return post
    }

    private func extractSlug(from pageURL: URL) -> String? {
        let parts = pageURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        return parts.last
    }

    private func destinationURL(for title: String, response: URLResponse) throws -> URL {
        let manager = FileManager.default
        let appSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport
            .appendingPathComponent("Livewallspace", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)

        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let contentDisposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let serverFileName = parseFileName(fromContentDisposition: contentDisposition)

        let preferredName: String
        if let serverFileName, !serverFileName.isEmpty {
            preferredName = serverFileName
        } else {
            preferredName = sanitizeFileName(title) + ".mp4"
        }

        return folder.appendingPathComponent(preferredName)
    }

    private func parseFileName(fromContentDisposition header: String) -> String? {
        let pattern = "filename=\\\"?([^\\\";]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let full = NSRange(header.startIndex..<header.endIndex, in: header)
        guard let match = regex.firstMatch(in: header, options: [], range: full),
              let range = Range(match.range(at: 1), in: header) else {
            return nil
        }
        return String(header[range])
    }

    private func extractOGImage(from html: String) -> URL? {
        let pattern = "<meta\\s+property=\\\"og:image\\\"\\s+content=\\\"([^\\\"]+)\\\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: full),
              let range = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        return URL(string: String(html[range]))
    }

    private func stripHTMLTags(from value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        var result = value
        let replacements = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (entity, replacement) in replacements {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private func decodeJavaScriptEscapes(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\\/", with: "/")
        guard let regex = try? NSRegularExpression(pattern: "\\\\u([0-9a-fA-F]{4})") else {
            return normalized
        }

        let nsString = normalized as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: normalized, options: [], range: range)
        guard !matches.isEmpty else {
            return normalized
        }

        var result = normalized
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let scalarRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result)
            else {
                continue
            }

            let hex = String(result[scalarRange])
            guard let codePoint = UInt32(hex, radix: 16),
                  let scalar = UnicodeScalar(codePoint)
            else {
                continue
            }

            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }

        return result
    }

    private func sanitizeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let collapsed = String(scalars).replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased().prefix(80).description
    }
}

private struct WordPressPost: Decodable {
    struct RenderedText: Decodable {
        let rendered: String
    }

    struct Embedded: Decodable {
        struct FeaturedMedia: Decodable {
            let sourceURL: String?

            private enum CodingKeys: String, CodingKey {
                case sourceURL = "source_url"
            }
        }

        struct Term: Decodable {
            let taxonomy: String?
            let name: String
        }

        let featuredMedia: [FeaturedMedia]?
        let terms: [[Term]]?

        private enum CodingKeys: String, CodingKey {
            case featuredMedia = "wp:featuredmedia"
            case terms = "wp:term"
        }
    }

    let id: Int
    let link: String
    let title: RenderedText
    let excerpt: RenderedText?
    let content: RenderedText?
    let embedded: Embedded?

    private enum CodingKeys: String, CodingKey {
        case id
        case link
        case title
        case excerpt
        case content
        case embedded = "_embedded"
    }
}
