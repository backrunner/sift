import Foundation

/// Fills one `{placeholder}` template with locale-appropriate values and
/// applies light surface noise. Deterministic for a given generator state.
func fillSyntheticTemplate(
    _ template: String,
    language: SeedLanguage,
    generator: inout SeededGenerator
) -> String {
    let pools = language.pools

    let brand = generator.choice(pools.brands)
    let name = generator.choice(pools.names)
    let url = generator.choice(pools.urlHosts) + String(generator.integer(in: 100000...999999))

    var replacements: [String: String] = [:]
    replacements["{tail}"] = String(generator.integer(in: 1000...9999))
    replacements["{amount}"] = "\(generator.integer(in: 1...999)).\(String(format: "%02d", generator.integer(in: 0...99)))"
    replacements["{amount2}"] = "\(generator.integer(in: 100...99999)).\(String(format: "%02d", generator.integer(in: 0...99)))"
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
    replacements["{tier}"] = generator.choice(pools.tiers)
    replacements["{url}"] = url

    let body = replacements.reduce(template) { text, replacement in
        text.replacingOccurrences(of: replacement.key, with: replacement.value)
    }

    func substitute(_ affix: String) -> String {
        affix
            .replacingOccurrences(of: "{brand}", with: brand)
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{url}", with: url)
    }

    let prefix = substitute(generator.choice(pools.prefixes))
    let suffix = substitute(generator.choice(pools.suffixes))

    var output = "\(prefix)\(body)\(suffix)"
    output = applyTextNoise(output, language: language, generator: &generator)
    return output
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

    return output
}
