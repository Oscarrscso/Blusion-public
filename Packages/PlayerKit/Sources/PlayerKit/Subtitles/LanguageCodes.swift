import Foundation

/// Subtitle languages arrive as ISO 639-2 (`eng`), ISO 639-1 (`en`), region variants (`pt-BR`, `pob`) or free text (`English`).
public enum LanguageCodes {
    private static let table: [(iso2: String, iso1: String, name: String, aliases: [String])] = [
        ("eng", "en", "English", ["english"]), ("spa", "es", "Spanish", ["spanish", "español", "espanol", "lat", "spl"]),
        ("fre", "fr", "French", ["fra", "french", "français", "francais"]), ("ger", "de", "German", ["deu", "german", "deutsch"]),
        ("ita", "it", "Italian", ["italian", "italiano"]), ("por", "pt", "Portuguese", ["portuguese", "português", "portugues", "pob", "pt-br", "pt-pt"]),
        ("rus", "ru", "Russian", ["russian"]), ("jpn", "ja", "Japanese", ["japanese"]), ("kor", "ko", "Korean", ["korean"]),
        ("chi", "zh", "Chinese", ["zho", "chinese", "zhs", "zht", "zh-cn", "zh-tw", "chs", "cht"]), ("ara", "ar", "Arabic", ["arabic"]),
        ("hin", "hi", "Hindi", ["hindi"]), ("dut", "nl", "Dutch", ["nld", "dutch", "nederlands"]), ("swe", "sv", "Swedish", ["swedish"]),
        ("nor", "no", "Norwegian", ["nob", "nno", "norwegian"]), ("dan", "da", "Danish", ["danish"]), ("fin", "fi", "Finnish", ["finnish"]),
        ("pol", "pl", "Polish", ["polish"]), ("tur", "tr", "Turkish", ["turkish"]), ("gre", "el", "Greek", ["ell", "greek"]),
        ("heb", "he", "Hebrew", ["hebrew"]), ("cze", "cs", "Czech", ["ces", "czech"]), ("hun", "hu", "Hungarian", ["hungarian"]),
        ("rum", "ro", "Romanian", ["ron", "romanian"]), ("ukr", "uk", "Ukrainian", ["ukrainian"]), ("vie", "vi", "Vietnamese", ["vietnamese"]),
        ("tha", "th", "Thai", ["thai"]), ("ind", "id", "Indonesian", ["indonesian"]), ("bul", "bg", "Bulgarian", ["bulgarian"]),
        ("hrv", "hr", "Croatian", ["croatian"]), ("srp", "sr", "Serbian", ["serbian"]), ("slo", "sk", "Slovak", ["slk", "slovak"]),
        ("slv", "sl", "Slovenian", ["slovenian"]), ("cat", "ca", "Catalan", ["catalan"]), ("per", "fa", "Persian", ["fas", "persian", "farsi"]),
    ]

    /// Every language we can name, alphabetically, for pickers.
    public static var all: [(code: String, name: String)] {
        table.map { ($0.iso2, $0.name) }.sorted { $0.1 < $1.1 }
    }

    /// Canonical ISO 639-2/B code, or the lower-cased input when unknown.
    public static func normalise(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = key.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? key
        for entry in table where entry.iso2 == key || entry.iso1 == key || entry.name.lowercased() == key || entry.aliases.contains(key)
            || entry.iso2 == base || entry.iso1 == base || entry.aliases.contains(base) {
            return entry.iso2
        }
        return key
    }

    public static func displayName(_ raw: String) -> String {
        let code = normalise(raw)
        if let entry = table.first(where: { $0.iso2 == code }) { return entry.name }
        return raw.isEmpty ? "Unknown" : (raw.count <= 3 ? raw.uppercased() : raw)
    }

    /// The two-letter code (`en`) services such as OpenSubtitles take, or nil for a language not in the table.
    public static func iso639_1(_ raw: String) -> String? {
        let code = normalise(raw)
        return table.first { $0.iso2 == code }?.iso1
    }

    public static func matches(_ language: String, preferred: String) -> Bool {
        normalise(language) == normalise(preferred)
    }
}
