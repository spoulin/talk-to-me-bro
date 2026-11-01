import Foundation
import Observation

/// A piece of text spoken in one go, followed by a silence. Paragraphs are
/// split into sentences, and further at pauses ("…", parentheses and brackets,
/// `[pause]` in the dictionary).
/// What a paragraph is, to read it with its own voice.
enum BlockKind: String, CaseIterable, Identifiable {
    case text, title, caption, quote

    var id: Self { self }
}

struct SpeechSegment {
    let block: Int
    let kind: BlockKind
    /// The text given to the voice, after dictionary replacements.
    let spoken: String
    let map: SpokenMap
    /// Seconds of silence after this segment.
    var pauseAfter: Double
    var isFirstInBlock = false
}

/// Maps ranges of the spoken text back to the paragraph's text, so the word
/// highlighted is the one in the article even when it is read differently.
struct SpokenMap {
    struct Piece {
        let spoken: NSRange
        let original: NSRange
        /// A dictionary replacement: any part of it maps to the whole original word.
        let replaced: Bool
    }

    var pieces: [Piece] = []

    func original(for spoken: NSRange) -> NSRange {
        guard let first = piece(at: spoken.location) else { return NSRange(location: NSNotFound, length: 0) }
        let last = piece(at: max(spoken.location, NSMaxRange(spoken) - 1)) ?? first
        let start = first.replaced ? first.original.location : first.original.location + (spoken.location - first.spoken.location)
        let end = last.replaced ? NSMaxRange(last.original)
            : last.original.location + (NSMaxRange(spoken) - last.spoken.location)
        return NSRange(location: start, length: max(end - start, 0))
    }

    private func piece(at location: Int) -> Piece? {
        pieces.first { NSLocationInRange(location, $0.spoken) } ?? pieces.last { $0.spoken.location <= location }
    }
}

enum SpeechScript {
    /// Silence for a `[pause]` without a duration.
    static let defaultPause = 0.6

    static func segments(for blocks: [String], kinds: [BlockKind] = [], from index: Int, pacing: Pacing,
                         entries: [PronunciationEntry], announceCaptions: Bool = false,
                         language: String = "") -> [SpeechSegment] {
        let captionLabel = announceCaptions ? Self.captionLabel(in: language) : ""
        let rules = Rule.compile(entries, pacing: pacing)
        var segments: [SpeechSegment] = []
        for block in index..<blocks.count {
            let firstOfBlock = segments.count
            let kind = kinds.indices.contains(block) ? kinds[block] : .text
            appendSegments(of: blocks[block] as NSString, block: block, kind: kind, pacing: pacing, rules: rules,
                           announcement: kind == .caption ? captionLabel : "", to: &segments)
            if segments.count > firstOfBlock { segments[firstOfBlock].isFirstInBlock = true }
        }
        return segments
    }

    private static func appendSegments(of text: NSString, block: Int, kind: BlockKind, pacing: Pacing, rules: [Rule],
                                       announcement: String, to segments: inout [SpeechSegment]) {
        var sentences: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            sentences.append(range)
        }
        if sentences.isEmpty { sentences = [NSRange(location: 0, length: text.length)] }

        for (s, sentence) in sentences.enumerated() {
            var spoken = ""
            var map = SpokenMap()
            func append(_ string: String, original: NSRange, replaced: Bool) {
                let location = (spoken as NSString).length
                spoken += string
                map.pieces.append(.init(spoken: NSRange(location: location, length: (string as NSString).length),
                                        original: original, replaced: replaced))
            }
            func close(pause: Double) {
                if spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty {
                    // Nothing to say (a lone "…"): lengthen the silence before it instead.
                    if let last = segments.indices.last, segments[last].block == block {
                        segments[last].pauseAfter += pause
                    }
                } else {
                    segments.append(SpeechSegment(block: block, kind: kind, spoken: spoken, map: map, pauseAfter: pause))
                }
                spoken = ""
                map = SpokenMap()
            }

            if !announcement.isEmpty, s == 0 {
                append(announcement + " ", original: NSRange(location: sentence.location, length: 0), replaced: true)
            }
            var cursor = sentence.location
            for match in matches(in: text, range: sentence, rules: rules) {
                if match.range.location > cursor {
                    let gap = NSRange(location: cursor, length: match.range.location - cursor)
                    append(text.substring(with: gap), original: gap, replaced: false)
                }
                switch match.action {
                case .pause(let seconds):
                    close(pause: seconds)
                case .skip:
                    break
                case .replace(let parts):
                    for part in parts {
                        switch part {
                        case .text(let string): append(string, original: match.range, replaced: true)
                        case .pause(let seconds): close(pause: seconds)
                        }
                    }
                }
                cursor = NSMaxRange(match.range)
            }
            if NSMaxRange(sentence) > cursor {
                let rest = NSRange(location: cursor, length: NSMaxRange(sentence) - cursor)
                append(text.substring(with: rest), original: rest, replaced: false)
            }
            close(pause: s == sentences.count - 1 ? pacing.paragraph : pacing.sentence)
        }
        // A paragraph ending on a pause marker: the paragraph pause still applies.
        if let last = segments.indices.last, segments[last].block == block {
            segments[last].pauseAfter = max(segments[last].pauseAfter, pacing.paragraph)
        }
    }

    /// "Caption:" in the article's language (the voice reads the article, whatever
    /// the interface language), falling back to the system speech language.
    private static func captionLabel(in language: String) -> String {
        let code = String((language.isEmpty ? AVVoices.systemLanguage : language).prefix(2)).lowercased()
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else {
            return "Caption:"
        }
        return bundle.localizedString(forKey: "Caption:", value: "Caption:", table: nil)
    }

    // MARK: Rules

    private struct Match {
        let range: NSRange
        let action: Rule.Action
    }

    private struct Rule {
        enum Part {
            case text(String)
            case pause(Double)
        }

        enum Action {
            /// A silence instead of the matched text ("…", parentheses).
            case pause(Double)
            /// Not read at all (note numbers like "[12]").
            case skip
            case replace([Part])
        }

        let regex: NSRegularExpression
        let action: Action

        /// Dictionary entries first (longest words first, so they win over
        /// shorter ones and over the built-in rules), then the built-in rules.
        static func compile(_ entries: [PronunciationEntry], pacing: Pacing) -> [Rule] {
            let dictionary = entries
                .filter { !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted { $0.word.count > $1.word.count }
                .compactMap { entry -> Rule? in
                    let word = NSRegularExpression.escapedPattern(for: entry.word.trimmingCharacters(in: .whitespaces))
                    // Whole words only: no letter or digit right before or after.
                    guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(word)(?![\\p{L}\\p{N}])",
                                                               options: [.caseInsensitive])
                    else { return nil }
                    return Rule(regex: regex, action: .replace(parts(of: entry.replacement)))
                }
            let builtIn = [
                // Note numbers: "malvoyantes[1]".
                Rule(regex: try! NSRegularExpression(pattern: "\\[\\d{1,3}\\]"), action: .skip),
                Rule(regex: try! NSRegularExpression(pattern: "\\.{3,}|…"), action: .pause(pacing.sentence + 0.3)),
                // A short silence before an aside and after it.
                Rule(regex: try! NSRegularExpression(pattern: "[()\\[\\]]"), action: .pause(pacing.sentence + 0.15)),
            ]
            return dictionary + builtIn
        }

        /// "le [pause 1.5] soccer" → text, pause, text.
        static func parts(of replacement: String) -> [Part] {
            let token = try! NSRegularExpression(pattern: "\\[pause(?:\\s+([0-9]+(?:[.,][0-9]+)?))?\\]", options: [.caseInsensitive])
            let ns = replacement as NSString
            var parts: [Part] = []
            var cursor = 0
            for result in token.matches(in: replacement, range: NSRange(location: 0, length: ns.length)) {
                if result.range.location > cursor {
                    parts.append(.text(ns.substring(with: NSRange(location: cursor, length: result.range.location - cursor))))
                }
                let value = result.range(at: 1).location == NSNotFound ? nil
                    : Double(ns.substring(with: result.range(at: 1)).replacingOccurrences(of: ",", with: "."))
                parts.append(.pause(min(value ?? defaultPause, 10)))
                cursor = NSMaxRange(result.range)
            }
            if cursor < ns.length { parts.append(.text(ns.substring(from: cursor))) }
            return parts
        }
    }

    /// Non-overlapping matches in the sentence, earlier rules winning.
    private static func matches(in text: NSString, range: NSRange, rules: [Rule]) -> [Match] {
        var found: [Match] = []
        for rule in rules {
            for result in rule.regex.matches(in: text as String, range: range)
            where !found.contains(where: { NSIntersectionRange($0.range, result.range).length > 0 }) {
                found.append(Match(range: result.range, action: rule.action))
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }
}

// MARK: - Voices by type

/// A voice for titles, captions and quotes; nil reads them with the text voice.
@MainActor
@Observable
final class VoiceRoles {
    static let shared = VoiceRoles()

    var title: String? = UserDefaults.standard.string(forKey: "voice.title") {
        didSet { UserDefaults.standard.set(title, forKey: "voice.title"); SpeechController.settingsChanged() }
    }
    var caption: String? = UserDefaults.standard.string(forKey: "voice.caption") {
        didSet { UserDefaults.standard.set(caption, forKey: "voice.caption"); SpeechController.settingsChanged() }
    }
    var quote: String? = UserDefaults.standard.string(forKey: "voice.quote") {
        didSet { UserDefaults.standard.set(quote, forKey: "voice.quote"); SpeechController.settingsChanged() }
    }
    /// Says "Caption:" before photo captions, so they don't blend into the story.
    var announceCaptions = UserDefaults.standard.bool(forKey: "announceCaptions") {
        didSet { UserDefaults.standard.set(announceCaptions, forKey: "announceCaptions"); SpeechController.settingsChanged() }
    }

    func voiceKey(for kind: BlockKind) -> String? {
        switch kind {
        case .text: nil
        case .title: title
        case .caption: caption
        case .quote: quote
        }
    }
}

// MARK: - Dictionary

struct PronunciationEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var word = ""
    var replacement = ""
}

/// Words to read differently, kept between launches.
@MainActor
@Observable
final class Pronunciations {
    static let shared = Pronunciations()
    private static let defaultsKey = "pronunciations"

    var entries: [PronunciationEntry] = [] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.defaultsKey)
            SpeechController.settingsChanged()
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([PronunciationEntry].self, from: data) {
            entries = saved
        }
    }
}
