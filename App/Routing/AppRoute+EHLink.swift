import EHModels
import EHNetwork

nonisolated extension AppRoute {
    /// The page a site link opens (entry E1): a gallery and an image page their own routes; a tag's or an uploader's
    /// galleries a list on the link's site, titled with the tag ("namespace:name") or the uploader's name; a search
    /// its results.
    ///
    /// External opens (`AppRouter.open(_:)`) and the links a page follows itself (search Q2's URL jump, pushed onto the
    /// current stack with `NavigationLink(value:)`) both make their route here.
    init(_ link: EHLink) {
        switch link {
        case .gallery(let id, let site):
            self = .gallery(id, site)
        case .imagePage(let imageKey, let gid, let page, let site):
            self = .imagePage(imageKey: imageKey, gid: gid, page: page, site: site)
        case .tag(let tag, let site):
            self = .list(ListQuery(source: .tag(tag)), title: tag.raw, site: site)
        case .uploader(let name, let site):
            self = .list(ListQuery(source: .uploader(name)), title: name, site: site)
        case .search(let text, let site):
            self = .search(text, site)
        }
    }
}
