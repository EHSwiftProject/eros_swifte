import EHModels

extension CustomGroup {
    /// The list request this group stands for, starting at `position`.
    ///
    /// A popular group sends nothing else (no search, categories, advanced options or position). Advanced options
    /// count only when `enableAdvance` is true. A nil `searchText` sends no search; an empty one sends an empty
    /// `f_search`, as Flutter's `join` does.
    public func listQuery(position: ListPosition = .first) -> ListQuery {
        switch listType {
        case .popular:
            return ListQuery(source: .popular)
        case .gallery, .watched:
            return ListQuery(
                source: listType == .watched ? .watched : .front, search: searchText?.joined(separator: " "),
                excludedCategories: cats, advanced: enableAdvance == true ? advancedSearch : nil, position: position)
        }
    }
}
