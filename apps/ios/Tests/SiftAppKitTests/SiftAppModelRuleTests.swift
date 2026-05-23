#if canImport(Testing)
import Foundation
import MessageFilterCore
import SiftAppKit
import Testing

private let rulesPersistenceKey = "Sift.customRules"
private let remoteSamplePrivacyConsentKey = "Sift.hasAcceptedRemoteSamplePrivacy"
private let lastRemoteSampleReceiptTokenKey = "Sift.lastRemoteSampleReceiptToken"

@MainActor
@Test
func ruleAddEditToggleAndDeletePersistAcrossModelInstances() throws {
    let defaults = UserDefaults.standard
    let originalData = defaults.data(forKey: rulesPersistenceKey)
    defaults.removeObject(forKey: rulesPersistenceKey)
    defer {
        if let originalData {
            defaults.set(originalData, forKey: rulesPersistenceKey)
        } else {
            defaults.removeObject(forKey: rulesPersistenceKey)
        }
    }

    let model = SiftAppModel()
    #expect(model.rules.isEmpty)

    model.ruleDraftName = "Pickup code"
    model.ruleDraftLocation = .body
    model.ruleDraftPatternKind = .substring
    model.ruleDraftPattern = "取件码"
    model.ruleDraftLabelID = "life.pickup_code"

    #expect(model.addCustomRuleFromDraft())
    let addedRule = try #require(model.rules.first)
    #expect(addedRule.name == "Pickup code")
    #expect(addedRule.text?.pattern == "取件码")
    #expect(addedRule.targetLabelID == "life.pickup_code")

    let reloadedAfterAdd = SiftAppModel()
    let persistedAddedRule = try #require(reloadedAfterAdd.rules.first)
    #expect(persistedAddedRule.id == addedRule.id)
    #expect(persistedAddedRule.text?.pattern == "取件码")

    #expect(reloadedAfterAdd.updateRule(
        id: addedRule.id,
        name: "Bank sender",
        location: .sender,
        patternKind: .regex,
        pattern: "^955\\d{2}$",
        labelID: "finance.bank"
    ))

    let editedRule = try #require(reloadedAfterAdd.rules.first)
    #expect(editedRule.name == "Bank sender")
    #expect(editedRule.sender?.kind == .regex)
    #expect(editedRule.sender?.pattern == "^955\\d{2}$")
    #expect(editedRule.text == nil)
    #expect(editedRule.targetLabelID == "finance.bank")

    let reloadedAfterEdit = SiftAppModel()
    let persistedEditedRule = try #require(reloadedAfterEdit.rules.first)
    #expect(persistedEditedRule.name == "Bank sender")
    #expect(persistedEditedRule.sender?.pattern == "^955\\d{2}$")

    var toggledRule = persistedEditedRule
    toggledRule.enabled = false
    reloadedAfterEdit.rules[0] = toggledRule

    let reloadedAfterToggle = SiftAppModel()
    let persistedToggledRule = try #require(reloadedAfterToggle.rules.first)
    #expect(!persistedToggledRule.enabled)

    reloadedAfterToggle.deleteRule(id: addedRule.id)
    #expect(reloadedAfterToggle.rules.isEmpty)

    let reloadedAfterDelete = SiftAppModel()
    #expect(!reloadedAfterDelete.rules.contains { $0.id == addedRule.id })
}

@MainActor
@Test
func remoteSubmitWithoutEndpointKeepsVisibleFeedback() {
    let defaults = UserDefaults.standard
    let originalConsent = defaults.object(forKey: remoteSamplePrivacyConsentKey)
    defaults.set(true, forKey: remoteSamplePrivacyConsentKey)
    defer {
        if let originalConsent {
            defaults.set(originalConsent, forKey: remoteSamplePrivacyConsentKey)
        } else {
            defaults.removeObject(forKey: remoteSamplePrivacyConsentKey)
        }
    }

    let model = SiftAppModel()
    model.submissionDestination = .remote
    model.submissionText = "您的验证码为 123456，请勿告知他人。"

    model.submitSample()

    #expect(model.isSubmittingSample == false)
    #expect(model.sampleSubmissionFeedback?.kind == .error)
    #expect(model.sampleSubmissionFeedback?.message == "匿名提交服务暂未配置")
}

@MainActor
@Test
func remoteSubmitRequiresPrivacyConsent() {
    let defaults = UserDefaults.standard
    let originalConsent = defaults.object(forKey: remoteSamplePrivacyConsentKey)
    defaults.removeObject(forKey: remoteSamplePrivacyConsentKey)
    defer {
        if let originalConsent {
            defaults.set(originalConsent, forKey: remoteSamplePrivacyConsentKey)
        } else {
            defaults.removeObject(forKey: remoteSamplePrivacyConsentKey)
        }
    }

    let model = SiftAppModel()
    model.submissionDestination = .remote
    model.submissionText = "您的验证码为 123456，请勿告知他人。"

    model.submitSample()

    #expect(model.isSubmittingSample == false)
    #expect(model.sampleSubmissionFeedback?.kind == .error)
    #expect(model.sampleSubmissionFeedback?.message == "请先阅读并同意匿名提交隐私说明")
}

@MainActor
@Test
func remoteReceiptPersistsAcrossModelInstances() {
    let defaults = UserDefaults.standard
    let originalReceipt = defaults.string(forKey: lastRemoteSampleReceiptTokenKey)
    defaults.removeObject(forKey: lastRemoteSampleReceiptTokenKey)
    defer {
        if let originalReceipt {
            defaults.set(originalReceipt, forKey: lastRemoteSampleReceiptTokenKey)
        } else {
            defaults.removeObject(forKey: lastRemoteSampleReceiptTokenKey)
        }
    }

    let model = SiftAppModel()
    model.lastReceiptToken = "receipt-test-token"

    let reloaded = SiftAppModel()
    #expect(reloaded.lastReceiptToken == "receipt-test-token")
}
#endif
