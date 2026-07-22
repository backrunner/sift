func categoryDisplayTitle(groupTitle: String, labelTitle: String) -> String {
    guard !groupTitle.isEmpty, groupTitle != labelTitle else {
        return labelTitle
    }
    return "\(groupTitle) / \(labelTitle)"
}

func categoryShowsDistinctGroupTitle(groupTitle: String, labelTitle: String) -> Bool {
    !groupTitle.isEmpty && groupTitle != labelTitle
}
