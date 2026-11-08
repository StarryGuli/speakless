import Foundation

struct SearchHit: Identifiable, Equatable {
    var id: String { url }
    var title: String
    var url: String
    var snippet: String
}

/// 不要 key 的网页搜索：先用必应（国内直连），不行再用 DuckDuckGo。拿网页版结果页里的标题、链接和摘要。
/// 只会把「搜索关键词」发出去，不带你的录音、选中的文字或窗口内容。
enum WebSearch {
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral   // 跟随系统代理
        c.timeoutIntervalForRequest = 12
        return URLSession(configuration: c)
    }()

    static func search(_ query: String, limit: Int = 6) async throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if let r = try? await bing(q, limit: limit), !r.isEmpty { return r }
        return try await duck(q, limit: limit)
    }

    private static func get(_ url: URL, post: String? = nil) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let post {
            req.httpMethod = "POST"
            req.httpBody = post.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(message: "Search returned HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func bing(_ q: String, limit: Int) async throws -> [SearchHit] {
        var comps = URLComponents(string: "https://cn.bing.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "setlang", value: "zh-Hans")]
        let page = try await get(comps.url!)
        var hits: [SearchHit] = []
        for block in matches(#"<li class="b_algo"[^>]*>(.*?)</li>"#, in: page) {
            guard let a = firstMatch(#"<h2[^>]*><a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: block, groups: 2) else { continue }
            let snippet = firstMatch(#"<p[^>]*>(.*?)</p>"#, in: block, groups: 1)?.first ?? ""
            let url = unwrapBing(decode(a[0]))
            guard url.hasPrefix("http") else { continue }
            hits.append(SearchHit(title: clean(a[1]), url: url, snippet: clean(snippet)))
            if hits.count >= limit { break }
        }
        return hits
    }

    private static func duck(_ q: String, limit: Int) async throws -> [SearchHit] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        let page = try await get(URL(string: "https://html.duckduckgo.com/html/")!, post: "q=\(enc)")
        var hits: [SearchHit] = []
        for block in matches(#"<div class="result[^"]*results_links[^>]*>(.*?)</div>\s*</div>"#, in: page) + matches(#"<div class="links_main[^>]*>(.*?)</div>"#, in: page) {
            guard let a = firstMatch(#"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: block, groups: 2) else { continue }
            let snippet = firstMatch(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block, groups: 1)?.first ?? ""
            var url = decode(a[0])
            if let r = url.range(of: "uddg="), let end = url[r.upperBound...].firstIndex(of: "&") ?? Optional(url.endIndex) {
                url = String(url[r.upperBound..<end]).removingPercentEncoding ?? url
            }
            if url.hasPrefix("//") { url = "https:" + url }
            guard url.hasPrefix("http"), !hits.contains(where: { $0.url == url }) else { continue }
            hits.append(SearchHit(title: clean(a[1]), url: url, snippet: clean(snippet)))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// 必应有时把链接包成 bing.com/ck/a?...&u=a1<base64>
    private static func unwrapBing(_ url: String) -> String {
        guard url.contains("bing.com/ck/a"), let r = url.range(of: "&u=a1") ?? url.range(of: "?u=a1") else { return url }
        var b64 = String(url[r.upperBound...].prefix { $0 != "&" }).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        if let d = Data(base64Encoded: b64), let s = String(data: d, encoding: .utf8), s.hasPrefix("http") { return s }
        return url
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    private static func firstMatch(_ pattern: String, in s: String, groups: Int) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1...groups).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&#0183;", with: "·")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func clean(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decode(noTags).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
