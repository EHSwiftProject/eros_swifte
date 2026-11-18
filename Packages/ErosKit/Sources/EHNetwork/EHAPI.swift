import EHModels
import Foundation

/// The eight JSON API calls of `api.php`, as Flutter's `network/api.dart` and `request.dart` send them.
public enum EHAPI {
    /// The most galleries one `gdata` call may ask for.
    public static let gdataBatchSize = 25

    /// One request per 25 ids, in order.
    public static func gdata(_ ids: [GalleryID], site: EHSite) -> [EHRequest] {
        stride(from: 0, to: ids.count, by: gdataBatchSize).map { start in
            let batch = ids[start..<min(start + gdataBatchSize, ids.count)]
            return request(["method": "gdata", "gidlist": batch.map { [$0.gid, $0.token] as [Any] }], site: site)
        }
    }

    public static func showpage(gid: Int, page: Int, imageKey: String, showKey: String, site: EHSite) -> EHRequest {
        request(["method": "showpage", "gid": gid, "page": page, "imgkey": imageKey, "showkey": showKey], site: site)
    }

    /// `nl` is added only with a reload token.
    public static func imagedispatch(
        gid: Int, page: Int, imageKey: String, mpvKey: String, reloadToken: String?, site: EHSite
    ) -> EHRequest {
        var body: [String: Any] = ["method": "imagedispatch", "gid": gid, "page": page, "imgkey": imageKey, "mpvkey": mpvKey]
        if let reloadToken { body["nl"] = reloadToken }
        return request(body, site: site)
    }

    /// `rating` is 1 to 10 (half stars).
    public static func rategallery(_ id: GalleryID, rating: Int, apiUID: Int, apiKey: String, site: EHSite) -> EHRequest {
        request(authorized("rategallery", id, apiUID, apiKey, ["rating": rating]), site: site)
    }

    public static func votecomment(
        _ id: GalleryID, commentID: Int, vote: Int, apiUID: Int, apiKey: String, site: EHSite
    ) -> EHRequest {
        request(authorized("votecomment", id, apiUID, apiKey, ["comment_id": commentID, "comment_vote": vote]), site: site)
    }

    public static func taggallery(
        _ id: GalleryID, tags: String, vote: Int, apiUID: Int, apiKey: String, site: EHSite
    ) -> EHRequest {
        request(authorized("taggallery", id, apiUID, apiKey, ["tags": tags, "vote": vote]), site: site)
    }

    public static func tagsuggest(_ text: String, site: EHSite) -> EHRequest {
        request(["method": "tagsuggest", "text": text], site: site)
    }

    /// `tagweight` is sent as a JSON string, as Flutter does; a nil `color` is sent as "".
    public static func setusertag(
        tagID: Int, watch: Bool, hide: Bool, color: String?, weight: Int, apiUID: Int, apiKey: String, site: EHSite
    ) -> EHRequest {
        request(
            [
                "method": "setusertag", "apiuid": apiUID, "apikey": apiKey, "tagid": tagID,
                "tagwatch": watch ? 1 : 0, "taghide": hide ? 1 : 0, "tagcolor": color ?? "",
                "tagweight": String(weight),
            ], site: site)
    }

    private static func authorized(
        _ method: String, _ id: GalleryID, _ apiUID: Int, _ apiKey: String, _ extra: [String: Any]
    ) -> [String: Any] {
        var body: [String: Any] = ["method": method, "apiuid": apiUID, "apikey": apiKey, "gid": id.gid, "token": id.token]
        body.merge(extra) { $1 }
        return body
    }

    /// A POST of the JSON body to `api.php`, keys sorted so the bytes are stable.
    private static func request(_ body: [String: Any], site: EHSite) -> EHRequest {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return EHRequest(
            method: .post, url: EHEndpoints.api(site: site), site: site, body: .json(data),
            cachePolicy: .none, expectsJSON: true)
    }
}
