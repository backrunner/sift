import MessageFilterCore
import SwiftUI

/// 我的提交:优先展示本地缓存,下拉时从 CloudKit 刷新,最多最近 200 条。
struct SubmissionHistoryView: View {
    @Bindable var model: SiftAppModel
    @State private var pendingConfirmation: Confirmation?

    private enum Confirmation {
        case delete(RemoteSubmissionSummary)
        case eraseAll
    }

    var body: some View {
        historyList
            .overlay {
                if model.submissionHistory.isEmpty && model.isLoadingHistory {
                    ProgressView(String(localized: "正在加载提交记录…"))
                } else if model.submissionHistory.isEmpty && model.hasLoadedSubmissionHistory {
                    emptyState
                }
            }
        .background(AtmosphericBackground())
        .navigationTitle(String(localized: "我的提交"))
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            model.refreshRemoteAccountStatus()
            model.refreshSubmissionHistoryIfNeeded()
        }
        .refreshable {
            await model.refreshSubmissionHistory()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(
                    String(localized: "清空"),
                    systemImage: "trash",
                    role: .destructive
                ) {
                    pendingConfirmation = .eraseAll
                }
                .tint(.red)
                .disabled(model.submittedSampleCount == 0 || model.isErasingRemoteData)
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: isShowingConfirmation,
            titleVisibility: .visible
        ) {
            switch pendingConfirmation {
            case .delete(let summary):
                Button(String(localized: "抹除"), role: .destructive) {
                    model.deleteSubmission(summary)
                    pendingConfirmation = nil
                }
            case .eraseAll:
                Button(String(localized: "抹除全部云端数据"), role: .destructive) {
                    model.eraseAllRemoteData()
                    pendingConfirmation = nil
                }
            case nil:
                EmptyView()
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingConfirmation = nil
            }
        } message: {
            switch pendingConfirmation {
            case .delete:
                Text(String(localized: "将从云端删除这条匿名样本，不可撤销。"))
            case .eraseAll:
                Text(String(localized: "将从云端删除你匿名提交的全部样本与统计备份，此操作不可撤销，不影响本地功能。"))
            case nil:
                EmptyView()
            }
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .delete:
            return String(localized: "抹除这条提交？")
        case .eraseAll:
            return String(localized: "抹除全部已提交数据？")
        case nil:
            return ""
        }
    }

    private var isShowingConfirmation: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingConfirmation = nil
                }
            }
        )
    }

    private var historyList: some View {
        List {
            ForEach(model.submissionHistory) { summary in
                SubmissionRow(summary: summary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingConfirmation = .delete(summary)
                        } label: {
                            Label(String(localized: "抹除"), systemImage: "xmark")
                        }
                        .tint(.red)
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
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.22), value: model.submissionHistory.count)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                model.submissionHistoryErrorMessage == nil
                    ? String(localized: "还没有提交过样本")
                    : String(localized: "无法加载提交记录"),
                systemImage: model.submissionHistoryErrorMessage == nil ? "tray" : "icloud.slash"
            )
        } description: {
            Text(
                model.submissionHistoryErrorMessage
                    ?? String(localized: "在首页「提交样本」里匿名贡献第一条脱敏样本吧。")
            )
        } actions: {
            if model.submissionHistoryErrorMessage != nil {
                Button(String(localized: "重试"), systemImage: "arrow.clockwise") {
                    model.retrySubmissionHistory()
                }
                .buttonStyle(.bordered)
            }
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
