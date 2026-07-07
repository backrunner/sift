import MessageFilterCore
import SwiftUI

// MARK: - 统计面板

/// 今日拦截概览 + 近 7 天迷你趋势。数据来自过滤扩展写入的每日计数桶,
/// 通过 CloudKit 私有库跨设备备份。只有计数,永远不含短信内容。
struct StatisticsPanel: View {
    @Bindable var model: SiftAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "拦截统计"), icon: "chart.bar.fill") {
                Text(Self.dayLabel(model.todayStats.day))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                StatTile(title: String(localized: "垃圾拦截"), value: model.todayStats.junk, tint: .red)
                StatTile(title: String(localized: "推广归类"), value: model.todayStats.promotion, tint: .siftAmber)
                StatTile(title: String(localized: "正常放行"), value: model.todayStats.transaction, tint: .siftMint)
            }

            if model.weeklyStats.contains(where: { $0.total > 0 }) {
                WeeklyTrend(days: model.weeklyStats)
            } else {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "sparkles")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.siftHalo)
                        .frame(width: 18)
                    Text(String(localized: "过滤器开始工作后，这里会展示每日拦截趋势。统计只记录数量，不保存短信内容。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetSurface(cornerRadius: 12)
            }
        }
        .padding(18)
        .cardSurface()
        .animation(.snappy(duration: 0.25), value: model.todayStats)
        .onAppear { model.refreshStatistics() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshStatistics()
            }
        }
    }

    private static func dayLabel(_ day: String) -> String {
        String(day.suffix(5)).replacingOccurrences(of: "-", with: "/")
    }
}

private struct SettingsRowContent<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let icon: String
    var tint: Color = .siftMint
    var isEnabled: Bool = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 8) {
                trailing
            }
            .foregroundStyle(.secondary)
            .layoutPriority(0)
        }
        .frame(maxWidth: .infinity, minHeight: subtitle == nil ? 44 : 52, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private extension SettingsRowContent where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        icon: String,
        tint: Color = .siftMint,
        isEnabled: Bool = true
    ) {
        self.init(title: title, subtitle: subtitle, icon: icon, tint: tint, isEnabled: isEnabled) {
            EmptyView()
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .insetSurface(cornerRadius: 12)
    }
}

private struct WeeklyTrend: View {
    let days: [DailyFilterStats]

    private var peak: Int {
        max(days.map(\.total).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "近 7 天"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(day.junk > 0 ? Color.siftAmber.opacity(0.85) : Color.siftMint.opacity(0.75))
                            .frame(height: max(CGFloat(day.total) / CGFloat(peak) * 46, day.total > 0 ? 5 : 2))
                            .frame(maxHeight: 46, alignment: .bottom)
                        Text(String(day.day.suffix(2)))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetSurface(cornerRadius: 12)
    }
}

// MARK: - 高级版购买引导

/// 高级版 Paywall:实时价格(自动反映降价/限时免费)、购买、恢复购买,
/// 覆盖加载失败/取消/等待批准/失败等全部边界。
struct PremiumPaywallView: View {
    @Bindable var model: SiftAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(colors: [Color.siftAmber, Color.siftMint], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Text(String(localized: "Sift 高级版"))
                        .font(.title2.weight(.bold))
                    Text(String(localized: "一次购买，永久解锁"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 12) {
                    PaywallFeatureRow(icon: "brain.filled.head.profile", title: String(localized: "Transformer 多语言模型"), detail: String(localized: "针对中·英·日等 12 种语言离线训练，识别更准"))
                    PaywallFeatureRow(icon: "globe.asia.australia.fill", title: String(localized: "跨语种垃圾短信识别"), detail: String(localized: "出差、留学场景下的外语短信同样精准分类"))
                    PaywallFeatureRow(icon: "infinity", title: String(localized: "永久可用"), detail: String(localized: "非订阅制，一次购买长期有效，支持在新设备恢复"))
                }
                .padding(16)
                .cardSurface(cornerRadius: 16)

                priceSection

                purchaseButton

                Button {
                    Task {
                        let feedback = await model.premium.restorePurchases()
                        model.showToast(feedback.kind, feedback.message)
                        if model.premium.isUnlocked {
                            dismiss()
                        }
                    }
                } label: {
                    if model.premium.isRestoring {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "恢复购买"))
                            .font(.footnote.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.siftMint)
                .disabled(model.premium.isRestoring)

                HStack(spacing: 14) {
                    Button(String(localized: "隐私政策")) { openURL(model.privacyPolicyURL) }
                    Button(String(localized: "服务条款")) { openURL(model.termsOfServiceURL) }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
        .background(AtmosphericBackground())
        .sensoryFeedback(.success, trigger: model.premium.isUnlocked)
        .animation(.snappy(duration: 0.25), value: model.premium.isUnlocked)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "关闭")) { dismiss() }
                    .font(.callout.weight(.semibold))
            }
        }
        .onAppear {
            if case .unavailable = model.premium.productState {
                model.premium.refresh()
            }
        }
    }

    @ViewBuilder
    private var priceSection: some View {
        switch model.premium.productState {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "正在获取价格…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .insetSurface(cornerRadius: 14)

        case .unavailable(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "重试")) { model.premium.refresh() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.siftMint)
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .insetSurface(cornerRadius: 14)

        case .available(let product):
            VStack(spacing: 6) {
                if product.isFree {
                    Text(String(localized: "限时免费"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.siftAmber, in: Capsule())
                } else if let promo = model.premium.promoText {
                    Text(promo)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.siftAmber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.siftAmber.opacity(0.14), in: Capsule())
                }
                Text(product.isFree ? "¥0" : product.displayPrice)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(String(localized: "一次性买断 · 无订阅 · 全家庭共享跟随 Apple ID"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .insetSurface(cornerRadius: 14)
        }
    }

    @ViewBuilder
    private var purchaseButton: some View {
        if model.premium.isUnlocked {
            Label(String(localized: "已解锁高级版"), systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.siftMint)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.siftMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            ActionButton(
                title: purchaseTitle,
                icon: "crown.fill",
                style: .primary,
                isEnabled: canPurchase,
                isLoading: model.premium.isPurchasing
            ) {
                Task {
                    if let feedback = await model.premium.purchase() {
                        model.showToast(feedback.kind, feedback.message)
                    }
                    if model.premium.isUnlocked {
                        dismiss()
                    }
                }
            }
        }
    }

    private var canPurchase: Bool {
        if case .available = model.premium.productState {
            return !model.premium.isPurchasing
        }
        return false
    }

    private var purchaseTitle: String {
        if case .available(let product) = model.premium.productState {
            return product.isFree ? String(localized: "免费获取") : String(localized: "以 \(product.displayPrice) 购买")
        }
        return String(localized: "购买")
    }
}

private struct PaywallFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.siftMint)
                .frame(width: 30, height: 30)
                .background(Color.siftMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Bindable var model: SiftAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingErase = false
    @State private var exportedJSON: String?
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                premiumSection
                dataSection
                legalSection
                aboutSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .animation(.snappy(duration: 0.22), value: exportedJSON != nil)
            .animation(.snappy(duration: 0.22), value: model.premium.isUnlocked)
        }
        .scrollIndicators(.hidden)
        .background(AtmosphericBackground())
        .onAppear { model.refreshRemoteAccountStatus() }
        .alert("iCloud", isPresented: remoteAccountAlertBinding) {
            Button(String(localized: "关闭"), role: .cancel) {
                model.dismissRemoteAccountAlert()
            }
        } message: {
            Text(model.remoteAccountAlertMessage ?? "")
        }
        .sheet(isPresented: $model.isShowingPaywall) {
            NavigationStack {
                PremiumPaywallView(model: model)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .navigationTitle(String(localized: "设置"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "完成")) { dismiss() }
                    .font(.callout.weight(.semibold))
            }
        }
        .confirmationDialog(
            String(localized: "抹除全部已提交数据？"),
            isPresented: $isConfirmingErase,
            titleVisibility: .visible
        ) {
            Button(String(localized: "抹除全部云端数据"), role: .destructive) {
                model.eraseAllRemoteData()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "将从云端删除你匿名提交的全部样本与统计备份，此操作不可撤销，不影响本地功能。"))
        }
    }

    private var remoteAccountAlertBinding: Binding<Bool> {
        Binding(
            get: { model.remoteAccountAlertMessage != nil },
            set: { if !$0 { model.dismissRemoteAccountAlert() } }
        )
    }

    private var premiumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "高级版"), icon: "crown.fill")

            Button {
                guard !model.premium.isUnlocked else { return }
                model.isShowingPaywall = true
            } label: {
                SettingsRowContent(
                    title: model.premium.isUnlocked ? String(localized: "已解锁") : String(localized: "未解锁"),
                    subtitle: model.premium.isUnlocked ? String(localized: "Transformer 多语言模型永久可用") : String(localized: "解锁 Transformer 多语言模型"),
                    icon: model.premium.isUnlocked ? "checkmark.seal.fill" : "crown.fill",
                    tint: model.premium.isUnlocked ? .siftMint : .siftAmber
                ) {
                    if !model.premium.isUnlocked {
                        if case .available(let product) = model.premium.productState {
                            Text(product.isFree ? String(localized: "限时免费") : product.displayPrice)
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Color.siftMint)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .insetSurface(cornerRadius: 12)

            Button {
                Task {
                    let feedback = await model.premium.restorePurchases()
                    model.showToast(feedback.kind, feedback.message)
                }
            } label: {
                SettingsRowContent(
                    title: String(localized: "恢复购买"),
                    icon: "arrow.clockwise",
                    isEnabled: !model.premium.isRestoring
                ) {
                    if model.premium.isRestoring {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .insetSurface(cornerRadius: 12)
            .disabled(model.premium.isRestoring)
        }
        .padding(18)
        .cardSurface()
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: String(localized: "数据与隐私"),
                subtitle: String(localized: "样本匿名存储于 iCloud，你可以随时导出或彻底抹除。"),
                icon: "hand.raised.fill"
            )

            if model.canUseRemoteSubmission {
                NavigationLink {
                    SubmissionHistoryView(model: model)
                } label: {
                    mySubmissionsRow(isEnabled: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .insetSurface(cornerRadius: 12)
            } else {
                Button {
                    model.showRemoteAccountRequiredAlert()
                } label: {
                    mySubmissionsRow(isEnabled: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .insetSurface(cornerRadius: 12)
            }

            Button {
                guard model.canUseRemoteSubmission else {
                    model.showRemoteAccountRequiredAlert()
                    return
                }
                guard !isExporting else { return }
                isExporting = true
                Task {
                    defer { isExporting = false }
                    exportedJSON = await model.exportMySubmissionsJSON()
                }
            } label: {
                SettingsRowContent(
                    title: String(localized: "导出我的全部提交"),
                    icon: "square.and.arrow.up",
                    isEnabled: model.canUseRemoteSubmission && !isExporting
                ) {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .insetSurface(cornerRadius: 12)
            .disabled(isExporting)

            if let exportedJSON {
                ShareLink(item: exportedJSON, preview: SharePreview(String(localized: "Sift 提交数据导出"))) {
                    HStack {
                        Label(String(localized: "分享导出内容（JSON）"), systemImage: "doc.text")
                            .font(.callout.weight(.semibold))
                        Spacer()
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.siftMint)
                .insetSurface(cornerRadius: 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                guard model.canUseRemoteSubmission else {
                    model.showRemoteAccountRequiredAlert()
                    return
                }
                isConfirmingErase = true
            } label: {
                SettingsRowContent(
                    title: String(localized: "抹除全部已提交数据"),
                    icon: "trash.fill",
                    tint: .red,
                    isEnabled: model.canUseRemoteSubmission && !model.isErasingRemoteData
                ) {
                    if model.isErasingRemoteData {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .insetSurface(cornerRadius: 12)
            .disabled(model.isErasingRemoteData)

            Text(String(localized: "抹除会删除云端所有由本 Apple ID 提交的匿名样本与统计备份。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .cardSurface()
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "法律"), icon: "doc.text.magnifyingglass")
            VStack(spacing: 10) {
                Button {
                    openURL(model.privacyPolicyURL)
                } label: {
                    SettingsRowContent(title: String(localized: "隐私说明"), icon: "hand.raised.fill", tint: .siftMint)
                }
                .buttonStyle(.plain)
                .insetSurface(cornerRadius: 12)

                Button {
                    openURL(model.termsOfServiceURL)
                } label: {
                    SettingsRowContent(title: String(localized: "服务条款"), icon: "checkmark.seal", tint: .siftHalo)
                }
                .buttonStyle(.plain)
                .insetSurface(cornerRadius: 12)
            }
        }
        .padding(18)
        .cardSurface()
    }

    private func mySubmissionsRow(isEnabled: Bool) -> some View {
        SettingsRowContent(
            title: String(localized: "我的提交"),
            icon: "tray.full",
            isEnabled: isEnabled
        ) {
            if model.submittedSampleCount > 0 {
                Text("\(model.submittedSampleCount)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.siftMint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.siftMint.opacity(0.12), in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "关于"), icon: "info.circle")
            SettingsRowContent(title: String(localized: "版本"), icon: "app.badge") {
                Text(Self.appVersion)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .insetSurface(cornerRadius: 12)

            SettingsRowContent(
                title: String(localized: "模型版本"),
                icon: model.selectedModelVariant.symbol,
                tint: .siftMint
            ) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatModelVersion(model.modelVersion))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(model.selectedModelVariant.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(minWidth: 76, alignment: .trailing)
            }
            .insetSurface(cornerRadius: 12)
        }
        .padding(18)
        .cardSurface()
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
