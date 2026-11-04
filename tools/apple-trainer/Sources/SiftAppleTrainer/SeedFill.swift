import Foundation

/// Fills one template with typed locale-appropriate values, without unrelated
/// sender/suffix decorations. Deterministic for a given generator state.
func fillSyntheticTemplate(
    _ template: String,
    language: SeedLanguage,
    generator: inout SeededGenerator
) -> String {
    let pools = language.pools

    let brand = generator.choice(pools.brands)
    let rawName = generator.choice(pools.names)
    let name = language == .ja ? rawName.replacingOccurrences(of: "様", with: "") : rawName
    let url = generator.choice(pools.urlHosts) + String(generator.integer(in: 100000...999999))

    var replacements: [String: String] = [:]
    replacements["{tail}"] = String(generator.integer(in: 1000...9999))
    replacements["{amount}"] = "\(generator.integer(in: 1...999)).\(String(format: "%02d", generator.integer(in: 0...99)))"
    replacements["{amount2}"] = "\(generator.integer(in: 100...99999)).\(String(format: "%02d", generator.integer(in: 0...99)))"
    if language == .ja {
        replacements["{amount}"] = String(replacements["{amount}"]!.split(separator: ".")[0])
        replacements["{amount2}"] = String(replacements["{amount2}"]!.split(separator: ".")[0])
    }
    replacements["{time}"] = "\(String(format: "%02d", generator.integer(in: 0...23))):\(String(format: "%02d", generator.integer(in: 0...59)))"
    replacements["{date}"] = "2026-\(String(format: "%02d", generator.integer(in: 1...12)))-\(String(format: "%02d", generator.integer(in: 1...28)))"
    replacements["{days}"] = String(generator.integer(in: 1...30))
    replacements["{percent}"] = "\(generator.integer(in: 1...45)).\(generator.integer(in: 0...9))"
    replacements["{minutes}"] = String(generator.integer(in: 1...30))
    replacements["{count}"] = String(generator.integer(in: 1...99))
    replacements["{points}"] = String(generator.integer(in: 10...9999))
    replacements["{code}"] = String(generator.integer(in: 100000...999999))
    replacements["{order}"] = String(generator.integer(in: 100000000...999999999))
    replacements["{flight}"] = generator.choice(["CA", "MU", "CZ", "BA", "AF", "LH", "JL", "KE", "GA", "VN", "TG", "SU", "IB", "9C"]) + String(generator.integer(in: 1000...9999))
    replacements["{train}"] = generator.choice(["G", "D", "K", "T", "Z", "C", "ICE", "TGV", "AVE"]) + String(generator.integer(in: 100...9999))
    replacements["{remain}"] = String(generator.integer(in: 1...100))
    replacements["{temp}"] = String(generator.integer(in: 30...42))
    replacements["{coldTemp}"] = String(generator.integer(in: -12...3))
    replacements["{discountTenths}"] = String(generator.integer(in: 5...9))
    replacements["{brand}"] = brand
    replacements["{bank}"] = generator.choice(pools.banks)
    replacements["{platform}"] = generator.choice(pools.platforms)
    replacements["{merchant}"] = generator.choice(pools.merchants)
    replacements["{courier}"] = generator.choice(pools.couriers)
    replacements["{carrier}"] = generator.choice(pools.carriers)
    replacements["{hospital}"] = generator.choice(pools.hospitals)
    replacements["{city}"] = generator.choice(pools.cities)
    replacements["{name}"] = name
    replacements["{station}"] = generator.choice(pools.stations)
    replacements["{task}"] = generator.choice(pools.tasks)
    let courses: [String]
    let restaurants: [String]
    switch language {
    case .zh:
        courses = ["信息安全基础", "消防安全实操", "新员工流程入门", "客户沟通技巧"]
        restaurants = ["松风餐厅", "小巷面馆", "河畔咖啡"]
    case .en:
        courses = ["information security basics", "fire safety practice", "new employee procedures", "customer communication skills"]
        restaurants = ["Maple Kitchen", "Riverside Cafe", "Market Noodle House"]
    case .ja:
        courses = ["情報セキュリティ基礎", "防火安全の実習", "新入社員の業務手順", "顧客対応の基本"]
        restaurants = ["松風食堂", "川辺カフェ", "小路の麺屋"]
    default:
        courses = []
        restaurants = []
    }
    if !courses.isEmpty { replacements["{course}"] = generator.choice(courses) }
    if !restaurants.isEmpty { replacements["{restaurant}"] = generator.choice(restaurants) }
    let publicCases: [String]
    switch language {
    case .zh: publicCases = ["居住登记申请", "护照换发申请", "出生证明补领申请", "地址变更申请"]
    case .en: publicCases = ["your residence registration application", "your passport renewal application", "your birth certificate replacement request", "your address change application"]
    case .ja: publicCases = ["住民登録の申請", "旅券更新の申請", "証明書再発行の申請", "住所変更の申請"]
    default: publicCases = []
    }
    if !publicCases.isEmpty { replacements["{publicCase}"] = generator.choice(publicCases) }
    replacements["{tier}"] = generator.choice(pools.tiers)
    replacements["{url}"] = url

    let body = replacements.reduce(template) { text, replacement in
        text.replacingOccurrences(of: replacement.key, with: replacement.value)
    }

    // Context-free decorations changed sender intent (e.g. merchant names on
    // government notices, or unsubscribe/security text on unrelated services).
    // Keep typed body rendering only. Surface noise is not semantic diversity.
    return body
}

/// Random surface noise: punctuation/whitespace/emoji jitter so the model
/// generalises beyond clean templates. Each transform fires with low
/// probability so the original text usually survives intact.
func applyTextNoise(
    _ text: String,
    language: SeedLanguage,
    generator: inout SeededGenerator
) -> String {
    var output = text

    // Surface variation must not change amounts, hostnames or URL paths.
    let structuredPattern = #"(?:https?://|www\.)\S+|(?<![A-Za-z0-9_@])(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:/\S*)?|\d+(?:[.,]\d+)+"#
    let expression = try! NSRegularExpression(pattern: structuredPattern)
    let original = output as NSString
    let matches = expression.matches(in: output, range: NSRange(location: 0, length: original.length))
    var protected: [(String, String)] = []
    for (index, match) in matches.enumerated().reversed() {
        let marker = "SIFTSTRUCTUREDVALUE\(index)TOKEN"
        protected.append((marker, original.substring(with: match.range)))
        let range = Range(match.range, in: output)!
        output.replaceSubrange(range, with: marker)
    }

    // 半角/全角标点互换只对使用全角标点的语言有意义。
    if language == .zh || language == .ja {
        if generator.integer(in: 0...9) < 3 {
            output = output
                .replacingOccurrences(of: "，", with: ",")
                .replacingOccurrences(of: "。", with: ".")
        } else if generator.integer(in: 0...9) < 2 {
            output = output
                .replacingOccurrences(of: ",", with: "，")
                .replacingOccurrences(of: ".", with: "。")
        }
    }

    let emojiSets: [String] = ["✨", "🎉", "💸", "📦", "🚚", "🔔", "⚡", "🛒", "❗", "💰", "🌧", "☀️"]
    if generator.integer(in: 0...9) < 2 {
        let emoji = generator.choice(emojiSets)
        output = "\(emoji) \(output)"
    }
    if generator.integer(in: 0...19) < 2 {
        let emoji = generator.choice(emojiSets)
        output = "\(output) \(emoji)"
    }

    if generator.integer(in: 0...19) < 2 {
        output = output.replacingOccurrences(of: "!", with: "!!")
    }

    if generator.integer(in: 0...19) < 2 {
        output = output.replacingOccurrences(of: " ", with: "  ")
    }

    for (marker, value) in protected {
        output = output.replacingOccurrences(of: marker, with: value)
    }

    return output
}
