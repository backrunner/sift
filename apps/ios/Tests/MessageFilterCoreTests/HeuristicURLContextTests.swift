import Testing
@testable import MessageFilterCore

@Test(arguments: [
    "The contact number changed. Details at this link: https://review.example.test/meeting?calendar=updated",
    "The contact number changed. Details at this link: HTTP://example.test/review",
    "The contact number changed. Details at this link: www.example.test/review",
    "連絡先が変更されました。リンク：https://example.test/会議/レビュー。",
    "联系方式更新，链接：https://example.test/会议/日历。"
])
private func urlWordsDoNotCreateMeetingContext(body: String) {
    #expect(HeuristicClassifier.highPrecisionDecision(for: body)?.labelID != "work.meeting")
}

@Test(arguments: [
    "The project review moved to Friday. Meeting link: https://example.test/a",
    "项目评审会改到周五，会议链接：https://example.test/a。",
    "プロジェクト会議は金曜に変更されました。リンク：https://example.test/a。"
])
private func meetingProseStillProvidesContext(body: String) {
    #expect(HeuristicClassifier.highPrecisionDecision(for: body)?.labelID == "work.meeting")
}

@Test
private func linkPresenceRemainsAvailableToCredentialTheftBoundary() {
    let body = "Claim your refund: https://example.test/a. Enter your card information to collect it."
    #expect(HeuristicClassifier.highPrecisionDecision(for: body)?.labelID == "spam")
}

@Test
private func unspacedTextAfterURLRemainsVisibleToSafetyBoundaries() {
    let body = "退款待领取，请点击https://example.test/check填写银行卡信息。"
    #expect(HeuristicClassifier.highPrecisionDecision(for: body)?.labelID == "spam")
}
