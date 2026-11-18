import EHModels
import EHNetwork
import Foundation
import Testing

struct EHRequestsTests {
    private func multipart(_ request: EHRequest) -> MultipartBody? {
        if case .multipart(let body) = request.body { return body }
        return nil
    }

    private func fields(_ request: EHRequest) -> [String: String?]? {
        if case .form(let items) = request.body { return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) }) }
        return nil
    }

    @Test func pageRequestsAreGetsAndRefreshReloads() {
        let url = URL(string: "https://e-hentai.org/g/900001/0f0f0f0f0f/")!
        let plain = EHRequests.page(url, site: .eh)
        #expect(plain.method == .get && plain.cachePolicy == .preferCache && plain.body == .none)
        #expect(EHRequests.page(url, site: .eh, refresh: true).cachePolicy == .reload)
    }

    @Test func imageLookupIsAMultipartPostWithoutRedirects() throws {
        let image = Data([1, 2, 3])
        let expected: [(ImageFormat, String, String)] = [
            (.jpeg, "a.jpg", "image/jpeg"), (.png, "a.png", "image/png"),
            (.gif, "a.gif", "image/gif"), (.webp, "a.webp", "image/webp"),
        ]
        for (format, name, mime) in expected {
            let request = EHRequests.imageLookup(image: image, format: format, options: ImageLookupOptions(), site: .ex)
            #expect(request.method == .post)
            #expect(request.url.absoluteString == "https://exhentai.org/upld/image_lookup.php")
            #expect(request.headers == ["Referer": "https://exhentai.org/"])
            #expect(!request.followsRedirects)
            #expect(request.cachePolicy == .none)
            let parts = try #require(multipart(request)).parts
            #expect(parts.map(\.name) == ["sfile", "fs_similar", "f_sfile"])
            #expect(parts[0].fileName == name && parts[0].contentType == mime && parts[0].data == image)
            #expect(parts[1].data == Data("on".utf8))
            #expect(parts[2].data == Data("File Search".utf8))
        }
        var options = ImageLookupOptions()
        options.similar = false
        options.coversOnly = true
        options.includeExpunged = true
        let request = EHRequests.imageLookup(image: image, format: .png, options: options, site: .eh)
        #expect(try #require(multipart(request)).parts.map(\.name) == ["sfile", "fs_covers", "fs_exp", "f_sfile"])
        #expect(request.url.absoluteString == "https://upld.e-hentai.org/image_lookup.php")
        #expect(request.headers == ["Referer": "https://e-hentai.org/"])
    }

    @Test func passwordLoginPostsTheForumForm() {
        let request = EHRequests.passwordLogin(username: "fake-user", password: "fake-pass")
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://forums.e-hentai.org/index.php?act=Login&CODE=01")
        #expect(fields(request) == [
            "UserName": "fake-user", "PassWord": "fake-pass", "submit": "Log me in",
            "temporary_https": "off", "CookieDate": "365",
        ])
        #expect(request.headers == ["Referer": "https://forums.e-hentai.org/index.php?act=Login&CODE=00"])
        #expect(request.cachePolicy == .none)
    }

    /// What the background WebView posts (account A3b): the form and its Referer only; the WebView sends its own
    /// User-Agent, Accept headers and cookies.
    @Test func passwordLoginWebViewRequestCarriesTheFormOnly() throws {
        let request = EHRequests.passwordLogin(username: "fake-user", password: "fake-pass").webViewRequest()
        #expect(request.httpMethod == "POST")
        #expect(request.url == EHEndpoints.forumLogin)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Referer") == EHEndpoints.forumLoginReferer.absoluteString)
        // The Flutter app's five fields, in its order.
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "UserName=fake-user&PassWord=fake-pass&submit=Log+me+in&temporary_https=off&CookieDate=365")
        #expect(Set((request.allHTTPHeaderFields ?? [:]).keys) == ["Content-Type", "Referer"])
        for name in ["User-Agent", "Cookie", "Accept", "Accept-Language"] {
            #expect(request.value(forHTTPHeaderField: name) == nil, Comment(rawValue: name))
        }
        #expect(request.httpBodyStream == nil)
    }

    @Test func webViewRequestLeavesOutTheHeadersTheWebViewOwns() {
        let url = URL(string: "https://forums.e-hentai.org/index.php")!
        let request = EHRequest(
            url: url, site: .eh,
            headers: [
                "cookie": "fake-cookie", "User-Agent": "FakeAgent/1", "Accept": "text/fake",
                "accept-language": "xx", "Origin": "https://forums.e-hentai.org",
            ]
        ).webViewRequest()
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.allHTTPHeaderFields == ["Origin": "https://forums.e-hentai.org"])
    }

    @Test func passwordNeverAppearsInDescriptions() {
        let request = EHRequests.passwordLogin(username: "fake-user", password: "fake-pass")
        #expect(!request.description.contains("fake-pass"))
        #expect(!String(describing: request).contains("fake-pass"))
        #expect(!String(reflecting: request).contains("fake-pass"))
        #expect(!"\(request)".contains("fake-user"))
        // The body as well: field names and byte counts, never a value.
        var dumped = ""
        dump(request.body, to: &dumped)
        for text in [String(describing: request.body), String(reflecting: request.body), "\(request.body)", dumped] {
            #expect(!text.contains("fake-pass"))
            #expect(!text.contains("fake-user"))
        }
        #expect(String(describing: request.body)
            == "form(UserName: 9 bytes, PassWord: 9 bytes, submit: 9 bytes, temporary_https: 3 bytes, CookieDate: 3 bytes)")
    }

    @Test func bodyDescriptionsShowSizesOnly() {
        let secret = "secret-fake-0001"
        let json = EHRequest.Body.json(Data(#"{"apikey":"\#(secret)"}"#.utf8))
        let multipart = EHRequest.Body.multipart(MultipartBody(boundary: "Eros-test", parts: [
            MultipartBody.Part(name: "sfile", fileName: "\(secret).jpg", contentType: "image/jpeg", data: Data(secret.utf8)),
            MultipartBody.Part(name: "empty", data: Data()),
        ]))
        let form = EHRequest.Body.form([URLQueryItem(name: "a", value: secret), URLQueryItem(name: "b", value: nil)])
        #expect(String(describing: EHRequest.Body.none) == "none")
        #expect(String(describing: json) == "json(29 bytes)")
        #expect(String(describing: multipart) == "multipart(sfile: 16 bytes, empty: 0 bytes)")
        #expect(String(describing: form) == "form(a: 16 bytes, b: 0 bytes)")
        for body in [json, multipart, form] {
            var dumped = ""
            dump(body, to: &dumped)
            for text in [String(describing: body), String(reflecting: body), dumped] {
                #expect(!text.contains(secret))
            }
        }
    }

    /// `MultipartBody` and its `Part`s describe themselves, in every way Swift prints a value, by part names and byte
    /// counts: never a file name (it may be the user's) or the bytes (an image search upload holds the user's image).
    @Test func multipartDescriptionHasNoBytesOrFileName() {
        let fileName = "fake-holiday-photo.jpg"
        let secret = "secret-fake-0002"
        let file = MultipartBody.Part(
            name: "sfile", fileName: fileName, contentType: "image/jpeg", data: Data(secret.utf8)
        )
        let field = MultipartBody.Part(name: "fs_similar", data: Data("on".utf8))
        let body = MultipartBody(boundary: "Eros-test", parts: [file, field])

        #expect(String(describing: file) == "sfile: 16 bytes")
        #expect(String(describing: body) == "MultipartBody(sfile: 16 bytes, fs_similar: 2 bytes)")
        let values: [(value: Any, names: [String])] = [
            (file, ["sfile", "16 bytes"]), (body, ["sfile", "16 bytes", "fs_similar", "2 bytes"]),
        ]
        for (value, names) in values {
            var dumped = ""
            dump(value, to: &dumped)
            let texts = [String(describing: value), String(reflecting: value), "\(value)", dumped]
            for text in texts {
                #expect(!text.contains(fileName), Comment(rawValue: text))
                #expect(!text.contains(secret), Comment(rawValue: text))
                #expect(!text.contains("image/jpeg"), Comment(rawValue: text))
                for name in names {
                    #expect(text.contains(name), Comment(rawValue: text))
                }
            }
        }
        // Nor does a mirror reach the file name or the data.
        let all: [Any] = [file, field, body]
        for value in all {
            #expect(Mirror(reflecting: value).children.allSatisfy { $0.label == "description" })
        }
    }

    @Test func profileRequestsPostToUConfig() {
        let select = EHRequests.selectProfile(3, site: .ex)
        #expect(select.method == .post && select.url.absoluteString == "https://exhentai.org/uconfig.php")
        #expect(fields(select) == ["profile_action": "", "profile_set": "3"])
        let create = EHRequests.createProfile(named: "Eros-FE", site: .eh)
        #expect(create.url.absoluteString == "https://e-hentai.org/uconfig.php")
        #expect(fields(create) == ["profile_action": "create", "profile_name": "Eros-FE"])
    }

    @Test func formRequestsAreNeverCached() {
        let url = EHEndpoints.myTags(site: .eh)
        let request = EHRequests.form(url, fields: [URLQueryItem(name: "a", value: "b")], site: .eh, referer: url)
        #expect(request.method == .post && request.cachePolicy == .none)
        #expect(request.headers == ["Referer": url.absoluteString])
        #expect(EHRequests.form(url, fields: [], site: .eh).headers.isEmpty)
    }
}
