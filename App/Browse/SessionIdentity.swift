import EHModels
import EHNetwork

/// Who the session is, as far as the lists care: the E-Hentai member id while logged in, nil otherwise. The lists
/// reload when it changes (`GalleryListView`), and the gallery groups drop the lists they keep for groups not shown
/// (`GalleryGroupsModel.updateSession(_:)`, browse B6).
///
/// One value rather than the pair: `AppEnvironment.refreshSession()` updates `session` and `isLoggedIn` one after the
/// other, and the state in between (the new member id, still logged out; or no member id, still logged in) must not
/// count as a change of its own, or one login would reload a list twice.
nonisolated struct SessionIdentity: Equatable {
    let memberID: String?

    init(isLoggedIn: Bool, memberID: String?) {
        self.memberID = isLoggedIn ? memberID : nil
    }
}

extension AppEnvironment {
    /// Who the session is now (`SessionIdentity`), from `isLoggedIn` and the E-Hentai member id in `session`.
    var sessionIdentity: SessionIdentity {
        SessionIdentity(isLoggedIn: isLoggedIn, memberID: session.cookies[.eh]?[CookieNames.memberID])
    }
}
