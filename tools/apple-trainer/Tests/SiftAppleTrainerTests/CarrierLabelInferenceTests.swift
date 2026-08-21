import XCTest
@testable import SiftAppleTrainer

final class CarrierLabelInferenceTests: XCTestCase {
    func testMonthlyConsumptionStatementWinsOverPromotionalTail() {
        let text = "尊敬 的 客户 个人实际消费 38 元 余额 12 元 本月免费项目使用情况 国内数据流量 已使用 4 GB 剩余 6 GB 清爽夏日送 1 GB 关注中国移动 官方微信号"

        XCTAssertEqual(inferCarrierAdvertisingLabel(text), "carrier.billing")
    }

    func testUsageOnlyMessageRemainsDataReminder() {
        let text = "本月 流量 已 使用 4 GB 套餐 剩余 6 GB"

        XCTAssertEqual(inferCarrierAdvertisingLabel(text), "carrier.data_reminder")
    }

    func testOfferWithoutAccountSummaryRemainsPromotion() {
        let text = "中国移动 流量 优惠 活动 回复 1 开通"

        XCTAssertEqual(inferCarrierAdvertisingLabel(text), "carrier.promotion")
    }
}
