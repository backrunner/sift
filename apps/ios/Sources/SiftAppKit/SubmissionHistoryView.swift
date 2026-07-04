import MessageFilterCore
import SwiftUI

/// 我的提交:下拉无限加载(最多最近 200 条),支持对任意一条单独抹除。
/// 数据来自 CloudKit 按 creator 的分页查询;本地不缓存文本内容。
struct SubmissionHistoryView: View {
    @Bindable var model: SiftAppModel
    @State private var pendingDeletion: RemoteSubmissionSummary?

    var body: some View {
        Group {
            if model.submissionHistory.isEmpty && model.isLoadingHistory {
                ProgressView(String(localized: "正在加载提交记录…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.submissionHistory.isEmpty && model.historyFullyLoaded {
                emptyState
            } else {
                historyList
            }
        }
        .background(AtmosphericBackground())
        .navigationTitle(String(localized: "我的提交"))
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            if model.submissionHistory.isEmpty {
                model.loadMoreSubmissionHistory()
            }
        }
        .refreshable {
            model.resetSubmissionHistory()
            model.loadMoreSubmissionHistory()
        }
        .confirmationDialog(
            String(localized: "抹除这条提交？"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "抹除"), role: .destructive) {
                if let pendingDeletion {
                    model.deleteSubmission(pendingDeletion)
                }
                pendingDeletion = nil
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(String(localized: "将从云端删除这条匿名样本，不可撤销。"))
        }
    }

    private var historyList: some View {
        List {
            ForEach(model.submissionHistory) { summary in
                SubmissionRow(summary: summary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = summary
                        } label: {
                            Label(String(localized: "抹除"), systemImage: "trash.fill")
                        }
                    }
                    .onAppear {
                        if summary.recordName == model.submissionHistory.last?.recordName {
                            model.loadMoreSubmissionHistory()
                        }
                    }
            }

            if model.isLoadingHistory && !model.submissionHistory.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if model.historyFullyLoaded && model.submissionHistory.count >= SiftAppModel.historyMaxItems {
                Text(String(localized: "最多显示最近 \(SiftAppModel.historyMaxItems) 条；更早的提交仍可通过「导出/抹除全部」管理。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.22), value: model.submissionHistory.count)
    }

    private var emptyState: some View {
        VStack {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "tray")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.siftMint)
                    .frame(width: 32, height: 32)
                    .background(Color.siftMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(String(localized: "还没有提交过样本"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(String(localized: "在首页「提交样本」里匿名贡献第一条脱敏样本吧。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardSurface()
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer(minLength: 0)
        }
    }
}

private struct SubmissionRow: View {
    let summary: RemoteSubmissionSummary

    private var labelTitle: String {
        SiftTaxonomy.leaf(id: summary.label)?.title ?? summary.label
    }

    private var dateText: String {
        guard let date = summary.submittedAt ?? summary.createdAtMillis.map({
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }) else {
            return ""
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(labelTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.siftMint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.siftMint.opacity(0.12), in: Capsule())
                Spacer(minLength: 0)
                Text(dateText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(summary.text)
                .font(.footnote)
                .foregroundStyle(.primary.opacity(0.86))
                .lineLimit(3)
        }
        .padding(12)
        .cardSurface(cornerRadius: 14)
    }
}
