import MessageFilterCore
import SwiftUI

struct CategoryMappingPanel: View {
    let model: SiftAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: String(localized: "分类映射"),
                icon: "arrow.triangle.branch"
            ) {
                if model.mappedCategoryCount > 0 {
                    Text("\(model.mappedCategoryCount)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(Color.siftMint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.siftMint.opacity(0.12), in: Capsule())
                        .contentTransition(.numericText())
                }
            }

            NavigationLink {
                CategoryMappingView(model: model)
            } label: {
                Label(String(localized: "管理分类映射"), systemImage: "arrow.triangle.branch")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .insetSurface(cornerRadius: 12)
        }
        .padding(18)
        .cardSurface()
    }
}

private struct CategoryMappingView: View {
    let model: SiftAppModel
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(visibleGroups) { group in
                    CategoryMappingGroup(
                        model: model,
                        group: group,
                        leaves: matchingLeaves(in: group)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TaxonomySearchBar(text: $searchText)
        }
        .background(AtmosphericBackground())
        .navigationTitle(String(localized: "分类映射"))
        .toolbarTitleDisplayMode(.inline)
        .overlay {
            if !searchText.isEmpty, visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var visibleGroups: [LabelGroup] {
        SiftTaxonomy.groups.filter { !matchingLeaves(in: $0).isEmpty }
    }

    private func matchingLeaves(in group: LabelGroup) -> [LeafLabel] {
        let eligibleLeaves = group.leaves.filter {
            CategoryMappingPolicy.isEligibleSource(labelID: $0.id)
        }
        guard !searchText.isEmpty else {
            return eligibleLeaves
        }
        return eligibleLeaves.filter(matchesSearch)
    }

    private func matchesSearch(_ leaf: LeafLabel) -> Bool {
        leaf.title.localizedCaseInsensitiveContains(searchText)
            || leaf.groupTitle.localizedCaseInsensitiveContains(searchText)
            || leaf.id.localizedCaseInsensitiveContains(searchText)
    }
}

struct TaxonomySearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            searchField

            if !text.isEmpty {
                Button(String(localized: "清除搜索"), systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 50)
        .padding(.horizontal, 16)
        .modifier(TaxonomySearchSurface())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var searchField: some View {
        #if os(iOS)
        TextField(String(localized: "搜索分类"), text: $text)
            .font(.body)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        TextField(String(localized: "搜索分类"), text: $text)
            .font(.body)
        #endif
    }
}

private struct TaxonomySearchSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 25, style: .continuous)
                )
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 25, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .stroke(Color.siftHairline, lineWidth: 1)
                }
                .shadow(color: Color.siftCardShadow, radius: 12, x: 0, y: 5)
        }
    }
}

private struct CategoryMappingGroup: View {
    let model: SiftAppModel
    let group: LabelGroup
    let leaves: [LeafLabel]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(leaves) { leaf in
                    CategoryMappingRow(model: model, leaf: leaf)
                }
            }
        }
    }
}

private struct CategoryMappingRow: View {
    let model: SiftAppModel
    let leaf: LeafLabel

    private var selection: CategoryMappingTarget? {
        model.categoryMapping(for: leaf.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(leaf.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                mappingButton(target: nil)
                Divider()
                ForEach(CategoryMappingTarget.allCases) { target in
                    mappingButton(target: target)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: selection?.symbol ?? "arrow.uturn.backward.circle")
                    Text(selection?.title ?? String(localized: "系统默认"))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(selectionTint)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selectionTint.opacity(0.11), in: Capsule())
            }
            .accessibilityLabel(String(localized: "\(leaf.title) 的映射"))
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
        )
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var selectionTint: Color {
        switch selection {
        case .promotion:
            return .siftAmber
        case .junk:
            return .red
        case nil:
            return .secondary
        }
    }

    private var rowFill: Color {
        selection == nil ? Color.siftCardFill : selectionTint.opacity(0.10)
    }

    private var rowStroke: Color {
        selection == nil ? Color.siftHairline : selectionTint.opacity(0.45)
    }

    @ViewBuilder
    private func mappingButton(target: CategoryMappingTarget?) -> some View {
        let isSelected = selection == target
        Button {
            model.setCategoryMapping(target, for: leaf.id)
        } label: {
            Label(
                target?.title ?? String(localized: "系统默认"),
                systemImage: isSelected ? "checkmark" : (target?.symbol ?? "arrow.uturn.backward")
            )
        }
    }
}
