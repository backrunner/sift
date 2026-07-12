import MessageFilterCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct SiftRootView: View {
    @State private var model = SiftAppModel()

    public init() {}

    public var body: some View {
        @Bindable var model = model
        return NavigationStack {
            ScrollView {
                dashboardSections
            }
            .scrollIndicators(.hidden)
            .background(AtmosphericBackground())
            .ignoresSafeArea(edges: .top)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .tint(.siftMint)
        .overlay(alignment: .top) {
            ToastOverlay(toast: $model.currentToast)
        }
        .alert("iCloud", isPresented: remoteAccountAlertBinding) {
            Button(String(localized: "关闭"), role: .cancel) {
                model.dismissRemoteAccountAlert()
            }
        } message: {
            Text(model.remoteAccountAlertMessage ?? "")
        }
    }

    @ViewBuilder
    private var dashboardSections: some View {
        VStack(spacing: 18) {
            DashboardHero(model: model)
            StatisticsPanel(model: model)
            if !model.hasConfirmedFilterSetup {
                InterceptionSetupPanel(model: model)
            }
            TestSamplePanel(model: model)
            SubmitSamplePanel(model: model)
            RulesPanel(model: model)
            CategoryMappingPanel(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.top, safeAreaTop + 14)
        .padding(.bottom, 32)
    }

    private var safeAreaTop: CGFloat {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 44
        #else
        0
        #endif
    }

    private var remoteAccountAlertBinding: Binding<Bool> {
        Binding(
            get: { model.remoteAccountAlertMessage != nil },
            set: { if !$0 { model.dismissRemoteAccountAlert() } }
        )
    }
}

struct AtmosphericBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.siftCanvas
                .ignoresSafeArea()

            // 柔和强调色光斑：左上 mint，右下 cool blue。
            // 让亮色不再"白板"，暗色下也提供方向感的色温。
            GeometryReader { proxy in
                let size = max(proxy.size.width, proxy.size.height)
                ZStack {
                    Circle()
                        .fill(Color.siftMint.opacity(colorScheme == .dark ? 0.18 : 0.14))
                        .frame(width: size * 0.95, height: size * 0.95)
                        .blur(radius: 90)
                        .offset(x: -size * 0.35, y: -size * 0.45)

                    Circle()
                        .fill(Color.siftHalo.opacity(colorScheme == .dark ? 0.22 : 0.16))
                        .frame(width: size * 0.85, height: size * 0.85)
                        .blur(radius: 100)
                        .offset(x: size * 0.4, y: size * 0.55)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct DashboardHero: View {
    @Bindable var model: SiftAppModel
    @State private var isShowingModelPicker = false
    @State private var isShowingSettings = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Sift")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Button {
                isShowingModelPicker = true
            } label: {
                HStack(spacing: 5) {
                    if model.isSwitchingModelVariant || model.isTransformerDownloadActive {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    } else {
                        Image(systemName: model.selectedModelVariant.symbol)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text(modelSwitchTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    LinearGradient(
                        colors: [Color.siftMint, Color.siftMint.opacity(0.86)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: Capsule()
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: isShowingModelPicker)

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.siftInsetFill, in: Circle())
                    .overlay(Circle().stroke(Color.siftHairline, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "设置"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .sheet(isPresented: $isShowingModelPicker) {
            NavigationStack {
                ModelPickerView(model: model)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView(model: model)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var modelSwitchTitle: String {
        if model.isTransformerDownloadActive {
            if let progress = model.transformerDownloadProgressText {
                return String(localized: "下载") + " \(progress)"
            }
            return String(localized: "下载中")
        }
        return model.selectedModelVariant.title
    }
}

private struct ModelPickerView: View {
    @Bindable var model: SiftAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.availableModelVariants) { variant in
                    let isLocked = variant == .transformer && !model.premium.isUnlocked
                    let shouldDismissAfterTap = variant == .classic
                        || (variant == .transformer && model.isTransformerModelAvailable && model.premium.isUnlocked)
                    ModelVariantCard(
                        variant: variant,
                        isSelected: model.selectedModelVariant == variant,
                        isAvailable: model.isModelVariantAvailable(variant),
                        isLockedByPremium: isLocked,
                        // The premium model is identified by its 高级版 tag;
                        // its downloadable manifest version is not user-facing.
                        version: variant == .transformer
                            ? nil
                            : model.modelVersion(for: variant).map(formatModelVersion),
                        downloadPhase: variant == .transformer ? model.transformerDownloadPhase : nil,
                        downloadProgress: variant == .transformer ? model.transformerDownloadProgress : nil,
                        downloadSizeText: variant == .transformer ? model.transformerDownloadByteCountText : nil
                    ) {
                        // 未购买时 selectModelVariant 会转为打开购买引导:
                        // 此时保持选择器在场,paywall 作为嵌套 sheet 叠加展示,
                        // 购买成功后用户再次点 Transformer 才开始下载/切换。
                        model.selectModelVariant(variant)
                        if shouldDismissAfterTap {
                            dismiss()
                        }
                    }
                    .disabled(model.isSwitchingModelVariant || model.isTransformerDownloadActive)
                    .frame(maxWidth: .infinity)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.siftHalo)
                    Text(String(localized: "经典模型可通过本地样本在设备上微调；Transformer 模型面向多语言场景离线训练，不支持设备端微调，切换后本地微调入口将隐藏。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 12)
                .padding(.trailing, 8)
                .insetSurface(cornerRadius: 12)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .animation(.snappy(duration: 0.22), value: model.selectedModelVariant)
        }
        .scrollIndicators(.hidden)
        .background(AtmosphericBackground())
        .sheet(isPresented: $model.isShowingPaywall) {
            NavigationStack {
                PremiumPaywallView(model: model)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            String(localized: "使用计费网络下载高级模型？"),
            isPresented: $model.isShowingMeteredTransformerDownloadConfirmation
        ) {
            Button(String(localized: "继续下载")) {
                model.confirmMeteredTransformerDownload()
            }
            Button(String(localized: "取消"), role: .cancel) {
                model.cancelPendingTransformerDownload()
            }
        } message: {
            Text(model.meteredTransformerDownloadMessage)
        }
        .navigationTitle(String(localized: "选择模型"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "完成")) {
                    dismiss()
                }
                .font(.callout.weight(.semibold))
            }
        }
    }
}

private struct ModelVariantCard: View {
    let variant: ModelVariant
    let isSelected: Bool
    let isAvailable: Bool
    var isLockedByPremium: Bool = false
    let version: String?
    var downloadPhase: TransformerModelDownloadPhase?
    var downloadProgress: TransformerModelDownloadProgress?
    var downloadSizeText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: variant.symbol)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(isSelected ? Color.siftMint : .secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        (isSelected ? Color.siftMint.opacity(0.14) : Color.siftInsetFill),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(variant.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let version {
                            Text(version)
                                .font(.caption2.weight(.bold).monospaced())
                                .foregroundStyle(Color.siftMint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.siftMint.opacity(0.12), in: Capsule())
                        }
                        if !isAvailable {
                            Text(String(localized: "未内置"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.siftInsetFill, in: Capsule())
                        }
                        if variant == .transformer {
                            HStack(spacing: 3) {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 8, weight: .bold))
                                Text(String(localized: "高级版"))
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(Color.siftAmber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.siftAmber.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(variant.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    downloadStatusView
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.siftMint)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pillSurface(cornerRadius: 16, isSelected: isSelected)
            .contentShape(Rectangle())
            .opacity(isAvailable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }

    @ViewBuilder
    private var downloadStatusView: some View {
        if variant == .transformer, let downloadPhase {
            switch downloadPhase {
            case .notDownloaded:
                if !isLockedByPremium && !isSelected {
                    downloadLine(
                        icon: "arrow.down.circle",
                        text: String(localized: "切换时下载") + downloadSizeSuffix,
                        tint: Color.siftHalo,
                        progress: nil
                    )
                }
            case .checking:
                downloadLine(
                    icon: nil,
                    text: String(localized: "正在准备下载…"),
                    tint: Color.siftHalo,
                    progress: nil,
                    showsSpinner: true
                )
            case .waitingForTrafficConfirmation:
                    downloadLine(
                        icon: "exclamationmark.triangle.fill",
                        text: String(localized: "计费网络待确认") + downloadSizeSuffix,
                        tint: Color.siftAmber,
                        progress: nil
                    )
            case .downloading:
                downloadLine(
                    icon: nil,
                    text: downloadingText,
                    tint: Color.siftMint,
                    progress: downloadProgress?.fractionCompleted,
                    showsSpinner: downloadProgress?.fractionCompleted == nil
                )
            case .installing:
                downloadLine(
                    icon: nil,
                    text: String(localized: "正在安装模型…"),
                    tint: Color.siftMint,
                    progress: nil,
                    showsSpinner: true
                )
            case .ready:
                if !isSelected {
                    downloadLine(
                        icon: "checkmark.circle.fill",
                        text: String(localized: "已下载，可离线使用"),
                        tint: Color.siftMint,
                        progress: nil
                    )
                }
            case let .failed(message):
                downloadLine(
                    icon: "exclamationmark.circle.fill",
                    text: message,
                    tint: Color.siftAmber,
                    progress: nil
                )
            }
        }
    }

    private var downloadSizeSuffix: String {
        guard let downloadSizeText else {
            return ""
        }
        return " · \(downloadSizeText)"
    }

    private var downloadingText: String {
        guard let progress = downloadProgress else {
            return String(localized: "正在下载…")
        }
        if let fraction = progress.fractionCompleted {
            return String(localized: "正在下载") + " \(Int((fraction * 100).rounded()))%"
        }
        return String(localized: "正在下载") + " \(formatDownloadBytes(progress.receivedBytes))"
    }

    @ViewBuilder
    private func downloadLine(
        icon: String?,
        text: String,
        tint: Color,
        progress: Double?,
        showsSpinner: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(tint)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.caption2.weight(.bold))
                }
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(tint)

            if let progress {
                ProgressView(value: progress)
                    .tint(tint)
                    .controlSize(.mini)
            }
        }
        .padding(.top, 3)
    }
}

private func formatDownloadBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

/// 从 manifest 里的 `<codename>-<major>.<minor>` 格式（如 `corpus-0.1`）
/// 中提取纯版本号 `major.minor`，展示在 "模型版本 <version>" 胶囊里。
func formatModelVersion(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        return "0.1"
    }
    let parts = trimmed.split(separator: "-").map(String.init)
    guard let last = parts.last,
          let major = last.split(separator: ".").first,
          Int(major) != nil
    else {
        return trimmed
    }

    let versionParts = last.split(separator: ".")
    let major2 = versionParts.first.map(String.init) ?? "0"
    let minor2 = versionParts.dropFirst().first.map(String.init) ?? "1"
    return "\(major2).\(minor2)"
}

private struct InterceptionSetupPanel: View {
    @Bindable var model: SiftAppModel
    @Environment(\.openURL) private var openURL
    @State private var didOpenSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: String(localized: "短信拦截设置"),
                icon: "gearshape"
            )

            VStack(alignment: .leading, spacing: 10) {
                SetupStepRow(
                    index: "1",
                    title: String(localized: "打开系统设置"),
                    detail: String(localized: "进入 iPhone 的设置应用。")
                )

                SetupStepRow(
                    index: "2",
                    title: String(localized: "找到信息"),
                    detail: String(localized: "进入「信息」里的未知与垃圾信息。")
                )

                SetupStepRow(
                    index: "3",
                    title: String(localized: "启用 Sift"),
                    detail: String(localized: "打开筛选并允许 Sift 参与拦截。")
                )
            }

            HStack(spacing: 10) {
                ActionButton(
                    title: String(localized: "前往设置"),
                    icon: "gearshape.fill",
                    style: .secondary,
                    isEnabled: settingsURL != nil
                ) {
                    guard let url = settingsURL else { return }
                    didOpenSettings = true
                    openURL(url)
                }

                ActionButton(
                    title: String(localized: "已完成"),
                    style: didOpenSettings ? .primary : .neutral,
                    isEnabled: didOpenSettings
                ) {
                    model.hasConfirmedFilterSetup = true
                }
            }
        }
        .padding(18)
        .cardSurface()
    }

    private var settingsURL: URL? {
        #if canImport(UIKit)
        URL(string: UIApplication.openSettingsURLString)
        #else
        nil
        #endif
    }
}

private struct SetupStepRow: View {
    let index: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.siftMint.opacity(0.18))
                    .frame(width: 28, height: 28)
                Text(index)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.siftMint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .insetSurface()
    }
}

private struct TestSamplePanel: View {
    @Bindable var model: SiftAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "测试样本"), icon: "brain.head.profile")

            GlassTextEditor(title: String(localized: "短信正文"), placeholder: String(localized: "输入短信正文"), text: $model.testBody, minHeight: 104)
                .onChange(of: model.testBody) { _, _ in model.clearCurrentDecision() }

            ActionButton(
                title: String(localized: "开始测试"),
                icon: "text.magnifyingglass",
                style: .primary,
                isEnabled: model.canClassifyCurrentDraft
            ) {
                model.classifyCurrentDraft()
            }

            if let decision = model.lastDecision {
                ResultStrip(decision: decision)
            }
        }
        .padding(18)
        .cardSurface()
    }
}

private struct SubmitSamplePanel: View {
    @Bindable var model: SiftAppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "提交样本"), icon: "tray.and.arrow.up") {
                if model.submittedSampleCount > 0 {
                    Text(String(localized: "已贡献 \(model.submittedSampleCount) 条"))
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.siftMint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.siftMint.opacity(0.12), in: Capsule())
                }
            }

            if model.supportsLocalPersonalization {
                SubmissionModeSelector(
                    selection: $model.submissionDestination,
                    isRemoteEnabled: model.canUseRemoteSubmission
                ) {
                    model.showRemoteAccountRequiredAlert()
                }
                    .onChange(of: model.submissionDestination) { _, _ in
                        model.sampleSubmissionFeedback = nil
                    }
            } else {
                TransformerSubmissionNotice()
            }

            if model.submissionDestination == .remote {
                RemoteSubmissionPrivacyCard(
                    isAccepted: $model.hasAcceptedRemoteSamplePrivacy,
                    privacyPolicyURL: model.privacyPolicyURL,
                    termsOfServiceURL: model.termsOfServiceURL,
                    isEnabled: model.canUseRemoteSubmission
                ) { url in
                    openURL(url)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            GlassTextEditor(title: String(localized: "样本文本"), placeholder: String(localized: "粘贴一条待标注短信"), text: $model.submissionText, minHeight: 104)
                .onChange(of: model.submissionText) { _, _ in
                    model.sampleSubmissionFeedback = nil
                    model.refreshSanitizedPreview()
                }

            if let validationMessage = model.submissionValidationMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.siftAmber)
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .insetSurface(cornerRadius: 10)
                .transition(.opacity)
            }

            if model.shouldShowSanitizedPreview {
                PrivacyPreview(text: model.sanitizedPreview)
            }

            CategoryMenu(
                selectedLabelID: Binding(
                    get: { model.selectedLabelID },
                    set: { model.selectSubmissionLabel($0) }
                )
            )

            let isRemoteSubmissionBlocked = model.submissionDestination == .remote && !model.canUseRemoteSubmission
            ActionButton(
                title: model.submissionDestination == .local ? String(localized: "加入本地微调队列") : String(localized: "匿名提交脱敏样本"),
                icon: "checkmark.shield",
                style: .primary,
                isEnabled: (model.canSubmitSample || isRemoteSubmissionBlocked) && !model.isSubmittingSample,
                isLoading: model.isSubmittingSample
            ) {
                if isRemoteSubmissionBlocked {
                    model.showRemoteAccountRequiredAlert()
                } else {
                    model.submitSample()
                }
            }
            .opacity(isRemoteSubmissionBlocked ? 0.52 : 1)

            if let feedback = model.sampleSubmissionFeedback {
                SubmissionFeedbackStrip(feedback: feedback)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if model.submissionDestination == .remote, let receiptToken = model.lastReceiptToken {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "回执"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(receiptToken)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .foregroundStyle(.primary.opacity(0.84))
                    ActionButton(
                        title: String(localized: "删除远程样本"),
                        icon: "trash",
                        style: .danger,
                        isEnabled: !model.isSubmittingSample
                    ) {
                        if model.canUseRemoteSubmission {
                            model.deleteLastRemoteSample()
                        } else {
                            model.showRemoteAccountRequiredAlert()
                        }
                    }
                    .opacity(model.canUseRemoteSubmission ? 1 : 0.52)
                }
                .padding(12)
                .insetSurface()
            }
        }
        .padding(18)
        .cardSurface()
        .onAppear { model.refreshRemoteAccountStatus() }
        .animation(.snappy(duration: 0.22), value: model.sampleSubmissionFeedback?.id)
        .animation(.snappy(duration: 0.22), value: model.submissionDestination)
        .animation(.snappy(duration: 0.22), value: model.selectedModelVariant)
        .animation(.snappy(duration: 0.22), value: model.submissionValidationMessage)
    }
}

/// Shown instead of the local/remote selector while the transformer model is
/// active: that variant cannot be fine-tuned on device.
private struct TransformerSubmissionNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.badge.clock")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.siftHalo)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Transformer 模型不支持本地微调"))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
                Text(String(localized: "样本可继续通过 iCloud 匿名共享，用于云端训练下一版模型；切回经典模型可恢复本地微调。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .insetSurface(cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }
}

private struct RemoteSubmissionPrivacyCard: View {
    @Binding var isAccepted: Bool
    let privacyPolicyURL: URL
    let termsOfServiceURL: URL
    let isEnabled: Bool
    let openPrivacyPolicy: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "hand.raised.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.siftMint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "匿名贡献隐私说明"))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(String(localized: "会通过 iCloud 共享脱敏后的样本文本、分类、模型版本和粗粒度语言地区（如 zh-CN）；不发送发送方、账号或设备标识。你可以用回执删除最近一次远程样本。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(String(localized: "我同意匿名贡献"), isOn: $isAccepted)
                .font(.footnote.weight(.semibold))
                .toggleStyle(.switch)
                .tint(.siftMint)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)

            HStack(spacing: 12) {
                Button {
                    openPrivacyPolicy(privacyPolicyURL)
                } label: {
                    Label(String(localized: "隐私说明"), systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.siftMint)

                Button {
                    openPrivacyPolicy(termsOfServiceURL)
                } label: {
                    Label(String(localized: "服务条款"), systemImage: "checkmark.seal")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.siftMint)
            }
        }
        .padding(12)
        .insetSurface(cornerRadius: 12)
        .accessibilityElement(children: .contain)
    }
}

private struct SubmissionModeSelector: View {
    @Binding var selection: SubmissionDestination
    let isRemoteEnabled: Bool
    let onRemoteUnavailable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "提交方式"))
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                SubmissionModeChip(
                    title: String(localized: "仅本地"),
                    subtitle: String(localized: "数据留在设备"),
                    icon: "lock.shield",
                    isSelected: selection == .local
                ) {
                    selection = .local
                }

                SubmissionModeChip(
                    title: String(localized: "匿名提交"),
                    subtitle: String(localized: "发送脱敏文本"),
                    icon: "icloud.and.arrow.up",
                    isSelected: selection == .remote,
                    isEnabled: isRemoteEnabled
                ) {
                    if isRemoteEnabled {
                        selection = .remote
                    } else {
                        onRemoteUnavailable()
                    }
                }
            }
        }
        .animation(.bouncy(duration: 0.22), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct SubmissionModeChip: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(isSelected ? Color.siftMint : .secondary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.siftMint)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
            .pillSurface(cornerRadius: 14, isSelected: isSelected)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}

private struct RulesPanel: View {
    let model: SiftAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: String(localized: "自定义规则"),
                icon: "slider.horizontal.3"
            ) {
                if model.customRuleCount > 0 {
                    RuleCountBadge(total: model.customRuleCount, active: model.activeRuleCount)
                }
            }

            NavigationLink {
                RuleManagementView(model: model)
            } label: {
                Label(String(localized: "管理规则"), systemImage: "slider.horizontal.3")
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

private struct RuleCountBadge: View {
    let total: Int
    let active: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("\(active)")
                .contentTransition(.numericText())
            Text("/")
                .foregroundStyle(Color.siftMint.opacity(0.55))
            Text("\(total)")
                .contentTransition(.numericText())
        }
        .font(.caption.weight(.bold).monospacedDigit())
        .foregroundStyle(Color.siftMint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.siftMint.opacity(0.12), in: Capsule())
    }
}

private struct RuleManagementView: View {
    @Bindable var model: SiftAppModel
    @State private var isDraftExpanded = false
    @State private var editingRuleID: UUID?
    @State private var openRuleID: UUID?

    private var customRuleRows: [RuleRowReference] {
        model.customRuleIndices.compactMap { index in
            guard model.rules.indices.contains(index) else {
                return nil
            }
            return RuleRowReference(id: model.rules[index].id, ruleIndex: index)
        }
    }

    var body: some View {
        #if os(iOS)
        Group {
            ruleList
        }
        .navigationTitle(String(localized: "规则管理"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if customRuleRows.count > 1 {
                    EditButton()
                        .font(.callout.weight(.semibold))
                }
            }
        }
        .sheet(item: editingRuleBinding) { row in
            NavigationStack {
                RuleEditView(model: model, ruleID: row.id) {
                    editingRuleID = nil
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        #else
        ruleList
        #endif
    }

    private var editingRuleBinding: Binding<RuleRowReference?> {
        Binding(
            get: {
                guard let id = editingRuleID,
                      let index = model.rules.firstIndex(where: { $0.id == id })
                else {
                    return nil
                }
                return RuleRowReference(id: id, ruleIndex: index)
            },
            set: { newValue in
                editingRuleID = newValue?.id
            }
        )
    }

    @ViewBuilder
    private var ruleList: some View {
        List {
            VStack(alignment: .leading, spacing: 0) {
                DisclosureCardHeader(
                    icon: "plus.circle",
                    title: String(localized: "新建规则"),
                    isExpanded: isDraftExpanded
                ) {
                    isDraftExpanded.toggle()
                }

                if isDraftExpanded {
                    Divider()
                        .background(Color.siftHairline)
                        .padding(.top, 14)
                        .padding(.bottom, 16)

                    RuleDraftForm(model: model)
                    .transition(.opacity)
                }
            }
            .padding(18)
            .cardSurface()
            .animation(.snappy(duration: 0.28), value: isDraftExpanded)
            .ruleManagementListRow(top: 14, bottom: 12)

            SectionHeader(
                title: String(localized: "规则列表"),
                icon: "list.bullet.rectangle"
            ) {
                if !customRuleRows.isEmpty {
                    RuleCountBadge(total: model.customRuleCount, active: model.activeRuleCount)
                }
            }
            .padding(.horizontal, 3)
            .ruleManagementListRow(top: 8, bottom: 4)

            if customRuleRows.isEmpty {
                RuleEmptyState()
                    .ruleManagementListRow(top: 4, bottom: 16)
            } else {
                ForEach(model.rules) { rule in
                    RuleListRow(
                        rule: rule,
                        isEnabled: ruleEnabledBinding(for: rule.id),
                        openRuleID: $openRuleID,
                        onEdit: { editingRuleID = rule.id },
                        onDelete: { model.deleteRule(id: rule.id) }
                    )
                    .ruleManagementListRow(top: 6, bottom: 6)
                }
                .onMove { source, destination in
                    model.moveCustomRules(from: source, to: destination)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AtmosphericBackground())
    }

    private func ruleEnabledBinding(for ruleID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                model.rules.first(where: { $0.id == ruleID })?.enabled ?? false
            },
            set: { newValue in
                guard let index = model.rules.firstIndex(where: { $0.id == ruleID }) else {
                    return
                }
                var rule = model.rules[index]
                rule.enabled = newValue
                model.rules[index] = rule
            }
        )
    }
}

private struct RuleRowReference: Identifiable {
    let id: UUID
    let ruleIndex: Int
}

private struct RuleDraftForm: View {
    @Bindable var model: SiftAppModel

    private var patternPlaceholder: String {
        switch model.ruleDraftPatternKind {
        case .substring:
            return model.ruleDraftLocation == .sender ? "955" : String(localized: "取件码")
        case .regex:
            return model.ruleDraftLocation == .sender ? "^955\\d{2}$" : #"取件码\s*\d{4,8}"#
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassTextField(title: String(localized: "规则名称（可选）"), placeholder: model.defaultRuleNamePlaceholder, text: $model.ruleDraftName)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "匹配位置"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SegmentedChoiceRow {
                    RuleChoiceChip(
                        title: RuleMatchLocation.sender.title,
                        icon: RuleMatchLocation.sender.symbol,
                        isSelected: model.ruleDraftLocation == .sender
                    ) {
                        model.ruleDraftLocation = .sender
                    }

                    RuleChoiceChip(
                        title: RuleMatchLocation.body.title,
                        icon: RuleMatchLocation.body.symbol,
                        isSelected: model.ruleDraftLocation == .body
                    ) {
                        model.ruleDraftLocation = .body
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "匹配方式"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SegmentedChoiceRow {
                    RuleChoiceChip(
                        title: RulePatternKind.substring.title,
                        icon: "tag",
                        isSelected: model.ruleDraftPatternKind == .substring
                    ) {
                        model.ruleDraftPatternKind = .substring
                    }

                    RuleChoiceChip(
                        title: RulePatternKind.regex.title,
                        icon: "function",
                        isSelected: model.ruleDraftPatternKind == .regex
                    ) {
                        model.ruleDraftPatternKind = .regex
                    }
                }
            }

            GlassTextField(title: String(localized: "匹配内容"), placeholder: patternPlaceholder, text: $model.ruleDraftPattern)

            CategoryMenu(titleLabel: String(localized: "分类"), selectedLabelID: $model.ruleDraftLabelID)

            ActionButton(
                title: String(localized: "添加规则"),
                icon: "plus",
                style: .primary,
                isEnabled: model.canAddCustomRule
            ) {
                _ = model.addCustomRuleFromDraft()
            }
        }
    }
}

private struct SegmentedChoiceRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .padding(4)
        .background(Color.siftInsetFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.siftHairline, lineWidth: 1)
        )
    }
}

private struct RuleChoiceChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .foregroundStyle(isSelected ? Color.siftMint : .secondary)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.siftCardFill)
                        .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: isSelected)
    }
}

private struct RuleListRow: View {
    let rule: CustomRule
    let isEnabled: Binding<Bool>
    @Binding var openRuleID: UUID?
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    private let actionButtonWidth: CGFloat = 44
    private let actionButtonHeight: CGFloat = 44
    private let interButtonSpacing: CGFloat = 6
    private let cardToActionsGap: CGFloat = 6

    private var revealWidth: CGFloat {
        actionButtonWidth * 2 + interButtonSpacing + cardToActionsGap
    }

    private var isOpen: Bool { openRuleID == rule.id }

    private var isEditingList: Bool {
        #if os(iOS)
        editMode?.wrappedValue.isEditing == true
        #else
        false
        #endif
    }

    private var displayOffset: CGFloat {
        if isEditingList { return 0 }
        let base: CGFloat = isOpen ? -revealWidth : 0
        return base + dragOffset
    }

    private var locationTitle: String {
        rule.sender != nil ? RuleMatchLocation.sender.title : RuleMatchLocation.body.title
    }

    private var locationIcon: String {
        rule.sender != nil ? RuleMatchLocation.sender.symbol : RuleMatchLocation.body.symbol
    }

    private var patternKindTitle: String {
        if let sender = rule.sender { return sender.kind.title }
        if let text = rule.text { return text.kind.title }
        return ""
    }

    private var patternKindIcon: String {
        if let sender = rule.sender {
            return sender.kind == .regex ? "function" : "tag"
        }
        if let text = rule.text {
            return text.kind == .regex ? "function" : "tag"
        }
        return "tag"
    }

    private var targetLabel: LeafLabel {
        SiftTaxonomy.leaf(id: rule.targetLabelID) ?? SiftTaxonomy.leaves[0]
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            actionButtons
                .opacity(displayOffset < 0 ? 1 : 0)

            cardContent
                .background(Color.clear)
                .contentShape(Rectangle())
                .offset(x: displayOffset)
                .gesture(swipeGesture, including: isEditingList ? .subviews : .all)
                .onTapGesture {
                    if isOpen {
                        withAnimation(.snappy(duration: 0.22)) {
                            openRuleID = nil
                        }
                    }
                }
        }
        .onChange(of: isEditingList) { _, editing in
            if editing {
                withAnimation(.snappy(duration: 0.22)) {
                    dragOffset = 0
                    if isOpen { openRuleID = nil }
                }
            }
        }
        .onChange(of: openRuleID) { _, newValue in
            if newValue != rule.id, dragOffset != 0 {
                withAnimation(.snappy(duration: 0.22)) {
                    dragOffset = 0
                }
            }
        }
    }

    private var cardContent: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(rule.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    RuleTag(icon: locationIcon, text: locationTitle, tint: .secondary)
                    RuleTag(icon: patternKindIcon, text: patternKindTitle, tint: .secondary)
                    RuleTag(icon: "tag", text: targetLabel.title, tint: .accent)
                }
            }

            Spacer(minLength: 6)

            Toggle("", isOn: isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.siftMint)
                .scaleEffect(0.78, anchor: .center)
                .frame(width: 42, height: 26)
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardSurface(cornerRadius: 14)
    }

    private var actionButtons: some View {
        HStack(spacing: interButtonSpacing) {
            Button {
                closeRow()
                onEdit()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                    .background(Color.siftMint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                closeRow()
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isEditingList else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if !isDragging {
                    guard abs(dx) > abs(dy) * 1.2 else { return }
                    isDragging = true
                }
                let base: CGFloat = isOpen ? -revealWidth : 0
                let projected = base + dx
                if projected > 0 {
                    dragOffset = -base + rubberBand(projected)
                } else if projected < -revealWidth {
                    let overshoot = -(projected + revealWidth)
                    dragOffset = (-revealWidth - base) - rubberBand(overshoot)
                } else {
                    dragOffset = dx
                }
            }
            .onEnded { value in
                let wasDragging = isDragging
                isDragging = false
                guard wasDragging else { return }
                let base: CGFloat = isOpen ? -revealWidth : 0
                let finalOffset = base + value.translation.width
                let velocity = value.predictedEndTranslation.width - value.translation.width
                let shouldOpen: Bool = {
                    if velocity < -200 { return true }
                    if velocity > 200 { return false }
                    return finalOffset < -revealWidth / 2
                }()
                withAnimation(.snappy(duration: 0.22)) {
                    dragOffset = 0
                    if shouldOpen {
                        openRuleID = rule.id
                    } else if isOpen {
                        openRuleID = nil
                    }
                }
            }
    }

    private func rubberBand(_ x: CGFloat) -> CGFloat {
        let limit: CGFloat = 80
        return limit * (1 - 1 / (x / limit + 1))
    }

    private func closeRow() {
        withAnimation(.snappy(duration: 0.22)) {
            dragOffset = 0
            openRuleID = nil
        }
    }
}

private struct RuleTag: View {
    enum Tint { case secondary, accent }
    let icon: String
    let text: String
    var tint: Tint = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 0.5))
    }

    private var foreground: Color {
        switch tint {
        case .secondary: return .secondary
        case .accent:    return .siftMint
        }
    }

    private var background: Color {
        switch tint {
        case .secondary: return Color.siftInsetFill
        case .accent:    return Color.siftMint.opacity(0.12)
        }
    }

    private var border: Color {
        switch tint {
        case .secondary: return Color.siftHairline
        case .accent:    return Color.siftMint.opacity(0.28)
        }
    }
}

private struct RuleEditView: View {
    @Bindable var model: SiftAppModel
    let ruleID: UUID
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var pattern: String = ""
    @State private var location: RuleMatchLocation = .body
    @State private var patternKind: RulePatternKind = .substring
    @State private var labelID: String = "life.pickup_code"
    @State private var didLoad = false

    private var patternPlaceholder: String {
        switch patternKind {
        case .substring:
            return location == .sender ? "955" : String(localized: "取件码")
        case .regex:
            return location == .sender ? "^955\\d{2}$" : #"取件码\s*\d{4,8}"#
        }
    }

    private var canSave: Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if patternKind == .regex {
            return (try? NSRegularExpression(pattern: trimmed)) != nil
        }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GlassTextField(title: String(localized: "规则名称（可选）"), placeholder: model.defaultRuleNamePlaceholder, text: $name)

                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "匹配位置"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    SegmentedChoiceRow {
                        RuleChoiceChip(
                            title: RuleMatchLocation.sender.title,
                            icon: RuleMatchLocation.sender.symbol,
                            isSelected: location == .sender
                        ) { location = .sender }

                        RuleChoiceChip(
                            title: RuleMatchLocation.body.title,
                            icon: RuleMatchLocation.body.symbol,
                            isSelected: location == .body
                        ) { location = .body }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "匹配方式"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    SegmentedChoiceRow {
                        RuleChoiceChip(
                            title: RulePatternKind.substring.title,
                            icon: "tag",
                            isSelected: patternKind == .substring
                        ) { patternKind = .substring }

                        RuleChoiceChip(
                            title: RulePatternKind.regex.title,
                            icon: "function",
                            isSelected: patternKind == .regex
                        ) { patternKind = .regex }
                    }
                }

                GlassTextField(title: String(localized: "匹配内容"), placeholder: patternPlaceholder, text: $pattern)

                CategoryMenu(titleLabel: String(localized: "分类"), selectedLabelID: $labelID)
            }
            .padding(18)
            .cardSurface()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(AtmosphericBackground())
        .navigationTitle(String(localized: "编辑规则"))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { onDismiss() }
                    .font(.callout.weight(.semibold))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存")) {
                    let success = model.updateRule(
                        id: ruleID,
                        name: name,
                        location: location,
                        patternKind: patternKind,
                        pattern: pattern,
                        labelID: labelID
                    )
                    if success {
                        onDismiss()
                    }
                }
                .font(.callout.weight(.semibold))
                .disabled(!canSave)
            }
        }
        .onAppear(perform: loadFromRule)
    }

    private func loadFromRule() {
        guard !didLoad,
              let rule = model.rules.first(where: { $0.id == ruleID })
        else { return }
        didLoad = true
        name = rule.name
        labelID = rule.targetLabelID
        if let sender = rule.sender {
            location = .sender
            pattern = sender.pattern
            patternKind = sender.kind == .regex ? .regex : .substring
        } else if let text = rule.text {
            location = .body
            pattern = text.pattern
            patternKind = text.kind == .regex ? .regex : .substring
        }
    }
}

private struct RuleEmptyState: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.siftMint)
                .frame(width: 32, height: 32)
                .background(Color.siftMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "还没有自定义规则"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(localized: "先在上面的表单里添加一条子串或正则规则。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }
}

private struct ResultStrip: View {
    let decision: ClassificationDecision

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: decision.source == .rule ? "scope" : "brain.head.profile")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.siftMint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "模型测试"))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
            }
            .layoutPriority(0)

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(decision.groupTitle) / \(decision.labelTitle)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .minimumScaleFactor(0.82)
                Text(String(localized: "置信度 \(confidenceText)"))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
        }
        .padding(14)
        .insetSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }

    private var confidenceText: String {
        "\(Int((decision.confidence * 100).rounded()))%"
    }

}

private struct GlassTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(minHeight: FormInputMetrics.textLineHeight)
                .padding(.horizontal, FormInputMetrics.horizontalPadding)
                .padding(.vertical, FormInputMetrics.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetSurface(cornerRadius: FormInputMetrics.cornerRadius)
        }
    }
}

private struct GlassTextEditor: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.footnote)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, FormInputMetrics.horizontalPadding)
                        .padding(.vertical, FormInputMetrics.verticalPadding)
                        .allowsHitTesting(false)
                }

                SiftMultilineTextView(text: $text)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: minHeight)
            }
            .frame(minHeight: minHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .insetSurface(cornerRadius: FormInputMetrics.cornerRadius)
        }
    }
}

enum FormInputMetrics {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let cornerRadius: CGFloat = 10
    static let textLineHeight: CGFloat = 20
}

#if canImport(UIKit)
private struct SiftMultilineTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = SiftTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.font = UIFont.preferredFont(forTextStyle: .footnote)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = UIColor(Color.siftMint)
        textView.textContainerInset = UIEdgeInsets(
            top: FormInputMetrics.verticalPadding,
            left: FormInputMetrics.horizontalPadding,
            bottom: FormInputMetrics.verticalPadding,
            right: FormInputMetrics.horizontalPadding
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .sentences
        textView.spellCheckingType = .no
        textView.returnKeyType = .default
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

private final class SiftTextView: UITextView {
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        guard let font else { return rect }

        let targetHeight = ceil(font.pointSize)
        if rect.height > targetHeight {
            rect.origin.y = rect.midY - targetHeight / 2
            rect.size.height = targetHeight
        }
        return rect
    }
}
#else
private struct SiftMultilineTextView: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
            .font(.footnote)
            .foregroundStyle(.primary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, FormInputMetrics.horizontalPadding - 4)
            .padding(.vertical, FormInputMetrics.verticalPadding - 6)
            .background(.clear)
    }
}
#endif

private struct CategoryMenu: View {
    var titleLabel: String = String(localized: "分类")
    @Binding var selectedLabelID: String
    @State private var isShowingPicker = false

    private var selectedLabel: LeafLabel {
        SiftTaxonomy.leaf(id: selectedLabelID) ?? SiftTaxonomy.leaves[0]
    }

    var body: some View {
        Button {
            isShowingPicker = true
        } label: {
            HStack(spacing: 12) {
                Text(titleLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Text(selectedLabel.groupTitle)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    Text(selectedLabel.title)
                        .foregroundStyle(.primary)
                }
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingPicker) {
            NavigationStack {
                CategorySelectionView(title: titleLabel, selectedLabelID: $selectedLabelID)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.selection, trigger: selectedLabelID)
        .insetSurface(cornerRadius: 12)
    }
}

private struct CategorySelectionView: View {
    let title: String
    @Binding var selectedLabelID: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(visibleGroups) { group in
                    CategoryGroupCard(
                        group: group,
                        leaves: matchingLeaves(in: group),
                        selectedLabelID: selectedLabelID
                    ) { leaf in
                        selectedLabelID = leaf.id
                        dismiss()
                    }
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
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "完成")) {
                    dismiss()
                }
                .font(.callout.weight(.semibold))
            }
        }
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
        guard !searchText.isEmpty else {
            return group.leaves
        }
        return group.leaves.filter { leaf in
            leaf.title.localizedCaseInsensitiveContains(searchText)
                || leaf.groupTitle.localizedCaseInsensitiveContains(searchText)
                || leaf.id.localizedCaseInsensitiveContains(searchText)
        }
    }
}

private struct CategoryGroupCard: View {
    let group: LabelGroup
    let leaves: [LeafLabel]
    let selectedLabelID: String
    let onSelect: (LeafLabel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(leaves) { leaf in
                    let isSelected = leaf.id == selectedLabelID
                    Button {
                        onSelect(leaf)
                    } label: {
                        HStack(spacing: 12) {
                            Text(leaf.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)

                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(Color.siftMint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            isSelected ? Color.siftMint.opacity(0.12) : Color.siftCardFill,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isSelected ? Color.siftMint.opacity(0.45) : Color.siftHairline, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SubmissionFeedbackStrip: View {
    let feedback: SampleSubmissionFeedback

    private var icon: String {
        switch feedback.kind {
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch feedback.kind {
        case .success: return .siftMint
        case .error:   return .red
        case .info:    return .siftHalo
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(feedback.message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct PrivacyPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.siftMint)
                Text(String(localized: "脱敏预览"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(text)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary.opacity(0.86))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .insetSurface(cornerRadius: 10)
        }
    }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var subtitleLineLimit: Int = 2
    let icon: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.siftMint)
                .frame(width: 30, height: 30)
                .background(Color.siftMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLineLimit)
                        .minimumScaleFactor(subtitleLineLimit == 1 ? 0.86 : 1)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, subtitleLineLimit: Int = 2, icon: String) {
        self.init(
            title: title,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            icon: icon,
            accessory: { EmptyView() }
        )
    }
}

enum ActionButtonStyle {
    case primary
    case secondary
    case neutral
    case danger
}

struct ActionButton: View {
    let title: String
    var icon: String?
    var style: ActionButtonStyle = .primary
    var isEnabled: Bool = true
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.callout.weight(.semibold))
                        .symbolRenderingMode(.monochrome)
                }
                Text(isLoading ? "" : title)
                    .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(border)
            .opacity(isEnabled || isLoading ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        switch style {
        case .primary:
            shape.fill(
                LinearGradient(
                    colors: [Color.siftMint, Color.siftMint.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .secondary:
            shape.fill(Color.siftMint.opacity(0.14))
        case .neutral:
            shape.fill(Color.siftInsetFill)
        case .danger:
            shape.fill(Color.red.opacity(0.12))
        }
    }

    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        switch style {
        case .primary:
            EmptyView()
        case .secondary:
            shape.stroke(Color.siftMint.opacity(0.30), lineWidth: 1)
        case .neutral:
            shape.stroke(Color.siftHairline, lineWidth: 1)
        case .danger:
            shape.stroke(Color.red.opacity(0.28), lineWidth: 1)
        }
    }

    private var foreground: Color {
        switch style {
        case .primary:   return .white
        case .secondary: return .siftMint
        case .neutral:   return .secondary
        case .danger:    return .red
        }
    }
}

private struct ToastOverlay: View {
    @Binding var toast: SiftToast?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack {
            if let toast {
                ToastBubble(toast: toast)
                    .id(toast.id)
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        clear()
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.28), value: toast?.id)
        .onChange(of: toast?.id) { _, newID in
            dismissTask?.cancel()
            guard newID != nil else { return }
            dismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                guard !Task.isCancelled else { return }
                clear()
            }
        }
        .allowsHitTesting(toast != nil)
    }

    private func clear() {
        toast = nil
        dismissTask?.cancel()
        dismissTask = nil
    }
}

private struct ToastBubble: View {
    let toast: SiftToast

    private var icon: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .success: return .siftMint
        case .error:   return .siftAmber
        case .info:    return .siftHalo
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(toast.message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.siftCardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.siftHairline, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 6)
    }
}

private struct DisclosureCardHeader: View {
    let icon: String
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.siftMint)
                    .frame(width: 30, height: 30)
                    .background(Color.siftMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(Color.siftInsetFill)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isExpanded)
    }
}

extension View {
    func ruleManagementListRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
    }

    func cardSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius))
    }

    func insetSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(InsetSurfaceModifier(cornerRadius: cornerRadius, isSelected: false))
    }

    func pillSurface(cornerRadius: CGFloat = 999, isSelected: Bool = false) -> some View {
        modifier(InsetSurfaceModifier(cornerRadius: cornerRadius, isSelected: isSelected))
    }
}

private struct CardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(Color.siftCardFill))
            .overlay(shape.strokeBorder(Color.siftHairline, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: Color.siftCardShadow, radius: 14, x: 0, y: 4)
    }
}

private struct InsetSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isSelected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fillColor: Color = isSelected
            ? Color.siftMint.opacity(0.12)
            : Color.siftInsetFill
        let strokeColor: Color = isSelected
            ? Color.siftMint.opacity(0.45)
            : Color.siftHairline

        return content
            .background(shape.fill(fillColor))
            .overlay(shape.strokeBorder(strokeColor, lineWidth: 1))
            .clipShape(shape)
    }
}

private extension SenderMatcher.Kind {
    var title: String {
        switch self {
        case .exact:
            return String(localized: "精确")
        case .prefix:
            return String(localized: "前缀")
        case .substring:
            return String(localized: "子串")
        case .regex:
            return String(localized: "正则")
        }
    }
}

private extension TextMatcher.Kind {
    var title: String {
        switch self {
        case .keyword:
            return String(localized: "关键词")
        case .substring:
            return String(localized: "子串")
        case .regex:
            return String(localized: "正则")
        }
    }
}

extension Color {
    static let siftMint = Color(
        light: Color(red: 0.10, green: 0.62, blue: 0.55),
        dark: Color(red: 0.36, green: 0.85, blue: 0.76)
    )

    static let siftAmber = Color(
        light: Color(red: 0.95, green: 0.62, blue: 0.20),
        dark: Color(red: 1.0, green: 0.78, blue: 0.42)
    )

    static let siftHalo = Color(
        light: Color(red: 0.42, green: 0.55, blue: 0.95),
        dark: Color(red: 0.46, green: 0.58, blue: 1.0)
    )

    static let siftCanvas = Color(
        light: Color(red: 0.962, green: 0.964, blue: 0.972),
        dark: Color(red: 0.063, green: 0.068, blue: 0.082)
    )

    static let siftCardFill = Color(
        light: .white,
        dark: Color(red: 0.115, green: 0.122, blue: 0.140)
    )

    static let siftInsetFill = Color(
        light: Color(red: 0.945, green: 0.948, blue: 0.958),
        dark: Color(red: 0.165, green: 0.172, blue: 0.190)
    )

    static let siftHairline = Color(
        light: Color.black.opacity(0.06),
        dark: Color.white.opacity(0.08)
    )

    static let siftCardShadow = Color(
        light: Color.black.opacity(0.045),
        dark: Color.black.opacity(0.45)
    )

    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
            return isDark ? NSColor(dark) : NSColor(light)
        })
        #else
        self = light
        #endif
    }
}
