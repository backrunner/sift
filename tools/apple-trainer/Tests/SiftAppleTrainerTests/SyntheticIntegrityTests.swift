import XCTest
@testable import SiftAppleTrainer

final class SyntheticIntegrityTests: XCTestCase {
    func testFillingDoesNotInventSenderOrDecorateMessage() {
        for language in [SeedLanguage.zh, .en, .ja] {
            for seed in 1...100 {
                var generator = SeededGenerator(seed: UInt64(seed))
                XCTAssertEqual(fillSyntheticTemplate("Approved literal body.", language: language,
                    generator: &generator), "Approved literal body.")
            }
        }
    }

    func testYenAmountsAreWholeAndPublicCaseIsNotAnOfficeTask() {
        var generator = SeededGenerator(seed: 71)
        let text = fillSyntheticTemplate("{amount}円 / {amount2}円 / {publicCase}",
            language: .ja, generator: &generator)
        XCTAssertNil(text.range(of: #"\d+\.\d+円"#, options: .regularExpression))
        XCTAssertFalse(text.contains("{"))
        XCTAssertTrue(text.contains("申請"))
    }

    func testDuplicateBodiesAreNotPaddedToReachRequestedCount() throws {
        let rows = try generateSyntheticRows(perLabel: 32, corePerLabel: 32,
            intlPerLabel: 0, languages: [.en], validLabels: ["spam"])
        XCTAssertEqual(rows.count, 16)
        XCTAssertEqual(Set(rows.map(\.text)).count, 16)
        XCTAssertTrue(rows.allSatisfy { $0.source?.hasPrefix("synthetic:clean-v8:") == true && !$0.text.contains(" #") })
        for language in SeedLanguage.allCases where !language.isCoreLanguage {
            XCTAssertNil(language.templates["spam"])
        }
    }

    func testNoisePreservesAmountsAndLinksAcrossCoreLanguages() {
        let text = "金额 1,234.56 元。https://example.com/a?x=1.5 和 sale.jp/x/123。"
        for language in [SeedLanguage.zh, .en, .ja] {
            for seed in 1...200 {
                var generator = SeededGenerator(seed: UInt64(seed))
                let result = applyTextNoise(text, language: language, generator: &generator)
                XCTAssertTrue(result.contains("1,234.56"))
                XCTAssertTrue(result.contains("https://example.com/a?x=1.5"))
                XCTAssertTrue(result.contains("sale.jp/x/123"))
            }
        }
    }

    func testTypedOperationalAlertsDoNotUseHumanTaskSlots() {
        for templates in [SeedTemplatesChinese.templates, SeedTemplatesEnglish.templates,
                          SeedTemplatesJapanese.templates] {
            XCTAssertFalse(templates["work.alert"]!.contains { $0.contains("{task}") })
        }
    }

    func testReviewedBusinessRolesRenderCoherently() {
        for language in [SeedLanguage.zh, .en, .ja] {
            for seed in 1...50 {
                var generator = SeededGenerator(seed: UInt64(seed))
                let text = fillSyntheticTemplate("{course} / {restaurant} / {name}さん / {coldTemp} / {discountTenths}",
                    language: language, generator: &generator)
                XCTAssertFalse(text.contains("{"))
                XCTAssertFalse(text.contains("様さん"))
                let values = text.components(separatedBy: " / ")
                XCTAssertTrue((-12...3).contains(Int(values[3])!))
                XCTAssertTrue((5...9).contains(Int(values[4])!))
            }
        }
        for templates in [SeedTemplatesChinese.templates, SeedTemplatesEnglish.templates,
                          SeedTemplatesJapanese.templates] {
            XCTAssertFalse(templates["work.training"]!.contains { $0.contains("{task}") })
            XCTAssertFalse(templates["life.logistics"]!.contains { $0.contains("{station}") })
            XCTAssertFalse(templates["life.takeaway"]!.contains { $0.contains("{merchant}") })
        }
    }
}
