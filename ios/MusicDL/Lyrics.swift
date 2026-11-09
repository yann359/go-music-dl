import Foundation

enum LyricLoadError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

struct LyricLine: Identifiable, Equatable {
    var id: Int
    var time: Double?
    var text: String
    static func parse(_ raw: String) -> [LyricLine] {
        let expression = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]")
        let inline = try! NSRegularExpression(pattern: "<\\d+:\\d+(?:\\.\\d+)?>")
        let prefix = try! NSRegularExpression(pattern: "^\\s*(?:\\[\\d+:\\d+(?:\\.\\d+)?\\])+")
        var offset = 0.0
        if let match = raw.range(of: "\\[offset:-?\\d+\\]", options: .regularExpression) {
            offset = (Double(raw[match].dropFirst(8).dropLast()) ?? 0) / 1000
        }
        var values: [(Double?, String)] = []
        var credits = Set<String>()
        for line in raw.components(separatedBy: .newlines) {
            let string = line as NSString
            let matches = expression.matches(in: line, range: NSRange(location: 0, length: string.length))
            let withoutTimes = expression.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: string.length), withTemplate: "")
            var text = inline.stringByReplacingMatches(in: withoutTimes, range: NSRange(location: 0, length: (withoutTimes as NSString).length), withTemplate: "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty || (matches.isEmpty && text.hasPrefix("[")) { continue }
            if let credit = normalizedCredit(text) {
                if !credits.insert(credit.key).inserted { continue }
                text = credit.text
            } else { credits.removeAll() }
            if matches.isEmpty { values.append((nil, text)) }
            else {
                // Only consecutive tags BEFORE the first word denote repeated
                // whole lines. Tags within/after words denote word boundaries.
                let prefixEnd = prefix.firstMatch(in: line, range: NSRange(location: 0, length: string.length)).map { NSMaxRange($0.range) } ?? 0
                let starts = matches.filter { NSMaxRange($0.range) <= prefixEnd }
                for match in (normalizedCredit(text) == nil ? starts : Array(starts.prefix(1))) {
                    values.append((max(0, (Double(string.substring(with: match.range(at: 1))) ?? 0) * 60 + (Double(string.substring(with: match.range(at: 2))) ?? 0) + offset), text))
                }
            }
        }
        if values.contains(where: { $0.0 != nil }) {
            values = values.enumerated().filter { $0.element.0 != nil }.sorted {
                $0.element.0! == $1.element.0! ? $0.offset < $1.offset : $0.element.0! < $1.element.0!
            }.map(\.element)
        }
        return values.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    private static func normalizedCredit(_ text: String) -> (key: String, text: String)? {
        let parts = text.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "：" })
        guard parts.count == 2 else { return nil }
        let aliases = ["词": "作词", "詞": "作词", "作詞": "作词", "填词": "作词", "填詞": "作词", "曲": "作曲", "編曲": "编曲"]
        let role = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let canonical = aliases[role] ?? role
        guard ["作词", "作曲", "编曲", "词曲", "制作人", "製作人", "composer", "arranger", "lyricist", "lyrics by", "composed by", "arranged by"].contains(canonical) else { return nil }
        let name = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let key = (canonical + ":" + name).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).filter { !$0.isWhitespace }
        return (key, canonical + "：" + name)
    }
}

