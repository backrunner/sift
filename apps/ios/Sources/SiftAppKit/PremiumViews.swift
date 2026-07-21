import MessageFilterCore
import Foundation
import SwiftUI

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
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)

            HStack(spacing: 8) {
                trailing
            }
            .foregroundStyle(.secondary)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
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

// MARK: - 高级版购买引导

/// 高级版 Paywall:实时价格(自动反映降价/限时免费)、购买、恢复购买,
/// 覆盖加载失败/取消/等待批准/失败等全部边界。
struct PremiumPaywallView: View {
    @Bindable var model: SiftAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                heroSection
                benefitsSection
                offerSection
                    .padding(.top, 28)

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
                .padding(.top, 16)

                HStack(spacing: 18) {
                    Button(String(localized: "隐私政策")) { openURL(model.privacyPolicyURL) }
                    Button(String(localized: "服务条款")) { openURL(model.termsOfServiceURL) }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, minHeight: max(proxy.size.height - 24, 0), alignment: .center)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
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

    private var heroSection: some View {
        VStack(spacing: 12) {
            Group {
                if reduceMotion {
                    crownBubble
                } else {
                    crownBubble
                        .keyframeAnimator(initialValue: CGFloat.zero, repeating: true) { content, verticalOffset in
                            content.offset(x: 0, y: verticalOffset)
                        } keyframes: { _ in
                            // Start at rest, then preserve a continuous vertical loop.
                            CubicKeyframe(-2, duration: 1.1)
                            CubicKeyframe(2, duration: 2.2)
                            CubicKeyframe(0, duration: 1.1)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 82)

            VStack(spacing: 5) {
                Text(String(localized: "Sift 高级版"))
                    .font(.largeTitle.weight(.bold))
                Text(String(localized: "更准确的多语言短信识别"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 24)
    }

    private var crownBubble: some View {
        ZStack {
            Circle()
                .fill(Color.siftAmber.opacity(0.14))
            Circle()
                .stroke(Color.siftAmber.opacity(0.28), lineWidth: 1)
            Image(systemName: "crown.fill")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.siftAmber, Color.siftMint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: 78, height: 78)
        .compositingGroup()
    }

    private var benefitsSection: some View {
        VStack(spacing: 0) {
            PaywallFeatureRow(
                icon: "brain.filled.head.profile",
                title: String(localized: "支持中、英、日等 12 种语言")
            )
            Divider()
                .padding(.leading, 44)
            PaywallFeatureRow(
                icon: "globe.asia.australia.fill",
                title: String(localized: "跨语言识别垃圾短信")
            )
            Divider()
                .padding(.leading, 44)
            PaywallFeatureRow(
                icon: "infinity",
                title: String(localized: "一次购买，永久使用")
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.siftCardFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.siftHairline, lineWidth: 1)
        )
    }

    private var offerSection: some View {
        VStack(spacing: 14) {
            priceSection
            purchaseButton
        }
        .padding(.vertical, 14)
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .cardSurface(cornerRadius: 18)
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
            .frame(height: 44)

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
            .padding(.vertical, 6)

        case .available(let product):
            HStack(alignment: .center, spacing: 12) {
                Text(String(localized: "现在购入"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.isFree ? String(localized: "限时免费") : product.displayPrice)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    if !product.isFree, let promo = model.premium.promoText {
                        Text(promo)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.siftAmber)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var purchaseButton: some View {
        if !model.isTransformerDeviceSupported {
            Label(String(localized: "此设备不支持 Transformer 高级模型"), systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.siftAmber)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.siftAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if model.premium.isUnlocked {
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
        guard model.isTransformerDeviceSupported else {
            return false
        }
        if case .available = model.premium.productState {
            return !model.premium.isPurchasing
        }
        return false
    }

    private var purchaseTitle: String {
        if case .available(let product) = model.premium.productState {
            return product.isFree ? String(localized: "免费获取") : String(localized: "立即购买")
        }
        return String(localized: "购买")
    }
}

private struct PaywallFeatureRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.siftMint)
                .frame(width: 30, height: 30)
                .background(Color.siftMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.siftMint.opacity(0.8))
        }
        .frame(minHeight: 48)
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Bindable var model: SiftAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingErase = false
    @State private var isConfirmingTransformerCleanup = false
    @State private var transformerStorageByteCount: Int64?
    @State private var exportedJSON: String?
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                premiumSection
                dataSection
                if model.isTransformerModelDownloaded {
                    storageManagementSection
                }
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
        .task(id: model.isTransformerModelDownloaded) {
            guard model.isTransformerModelDownloaded else {
                transformerStorageByteCount = nil
                return
            }
            transformerStorageByteCount = await TransformerModelStore.installedModelByteCount()
        }
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
            Text(String(localized: "将从云端删除你匿名提交的全部样本，此操作不可撤销，不影响本地功能。"))
        }
        .alert(
            String(localized: "清理 Transformer 存储？"),
            isPresented: $isConfirmingTransformerCleanup
        ) {
            Button(String(localized: "清理存储"), role: .destructive) {
                model.clearDownloadedTransformerModel()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(transformerCleanupConfirmationMessage)
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
                guard model.isTransformerDeviceSupported, !model.premium.isUnlocked else { return }
                model.isShowingPaywall = true
            } label: {
                SettingsRowContent(
                    title: premiumSettingsTitle,
                    subtitle: premiumSettingsSubtitle,
                    icon: premiumSettingsIcon,
                    tint: premiumSettingsTint,
                    isEnabled: model.isTransformerDeviceSupported
                ) {
                    if model.isTransformerDeviceSupported, !model.premium.isUnlocked {
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
            .disabled(!model.isTransformerDeviceSupported || model.premium.isUnlocked)
            .insetSurface(cornerRadius: 12)
        }
        .padding(18)
        .cardSurface()
    }

    private var premiumSettingsTitle: String {
        guard model.isTransformerDeviceSupported else {
            return String(localized: "设备不支持")
        }
        return model.premium.isUnlocked ? String(localized: "已解锁") : String(localized: "未解锁")
    }

    private var premiumSettingsSubtitle: String {
        guard model.isTransformerDeviceSupported else {
            return String(localized: "高级模型需要 A12 或更新芯片")
        }
        return model.premium.isUnlocked
            ? String(localized: "Transformer 多语言模型永久可用")
            : String(localized: "解锁 Transformer 多语言模型")
    }

    private var premiumSettingsIcon: String {
        guard model.isTransformerDeviceSupported else {
            return "exclamationmark.triangle.fill"
        }
        return model.premium.isUnlocked ? "checkmark.seal.fill" : "crown.fill"
    }

    private var premiumSettingsTint: Color {
        guard model.isTransformerDeviceSupported else {
            return .secondary
        }
        return model.premium.isUnlocked ? .siftMint : .siftAmber
    }

    private var storageManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "存储管理"), icon: "internaldrive.fill")

            SettingsRowContent(
                title: String(localized: "Transformer 模型"),
                subtitle: transformerStorageSubtitle,
                icon: "brain.filled.head.profile"
            ) {
                if let transformerStorageByteCount {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.formatStorageByteCount(transformerStorageByteCount))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(String(localized: "存储占用"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .insetSurface(cornerRadius: 12)

            Button {
                isConfirmingTransformerCleanup = true
            } label: {
                SettingsRowContent(
                    title: String(localized: "清理存储"),
                    icon: "trash.fill",
                    tint: .red,
                    isEnabled: canClearTransformerModel
                ) {
                    if model.isClearingTransformerModel {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .insetSurface(cornerRadius: 12)
            .disabled(!canClearTransformerModel)
        }
        .padding(18)
        .cardSurface()
    }

    private var transformerStorageSubtitle: String {
        let version = model.modelVersion(for: .transformer) ?? String(localized: "未知")
        return String(
            format: String(localized: "已下载 · 版本 %@"),
            version
        )
    }

    private static func formatStorageByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private var canClearTransformerModel: Bool {
        !model.isClearingTransformerModel
            && !model.isTransformerDownloadActive
            && !model.isSwitchingModelVariant
    }

    private var transformerCleanupConfirmationMessage: String {
        if model.selectedModelVariant == .transformer {
            return String(localized: "清理后会切换回经典模型，并删除已下载的 Transformer 模型文件。再次使用时需要重新下载。")
        }
        return String(localized: "将删除已下载的 Transformer 模型文件。再次使用时需要重新下载。")
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: String(localized: "数据与隐私"),
                subtitle: String(localized: "匿名存储，随时导出或抹除。"),
                subtitleLineLimit: 1,
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

            Text(String(localized: "抹除会删除云端所有由本 Apple ID 提交的匿名样本。"))
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
            Text("\(model.submittedSampleCount)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.siftMint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.siftMint.opacity(0.12), in: Capsule())
                .contentTransition(.numericText())
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
                title: model.selectedModelVariant == .transformer
                    ? String(localized: "高级模型")
                    : String(localized: "模型版本"),
                icon: model.selectedModelVariant.symbol,
                tint: .siftMint
            ) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.modelVersion)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(settingsModelTypeTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(minWidth: 96, alignment: .trailing)
            }
            .insetSurface(cornerRadius: 12)
        }
        .padding(18)
        .cardSurface()
    }

    private var settingsModelTypeTitle: String {
        switch model.selectedModelVariant {
        case .classic:
            return String(localized: "经典模型")
        case .transformer:
            return String(localized: "高级模型")
        }
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
