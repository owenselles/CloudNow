@testable import CloudNow
import Foundation
import Testing

@Suite("Localization integrity and locale mapping")
@MainActor
struct LocalizationIntegrityTests {
    struct MappingCase: Sendable {
        let input: String
        let expected: String
    }

    @Test("Every supported translation contains the complete English key set")
    func everyTableContainsEnglishKeys() {
        let english = L10n.translationTable(for: "en-US")

        for (locale, table) in L10n.supportedTranslationTables.sorted(by: { $0.key < $1.key }) {
            let missing = Set(english.keys).subtracting(table.keys)
            #expect(missing.isEmpty, "\(locale) is missing keys: \(missing.sorted())")
        }
    }

    @Test("Formatted strings preserve English placeholder positions and types")
    func formatPlaceholderCompatibility() {
        let english = L10n.translationTable(for: "en-US")

        for (locale, table) in L10n.supportedTranslationTables.sorted(by: { $0.key < $1.key }) {
            for key in english.keys.sorted() {
                let expected = placeholderSignature(english[key] ?? "")
                let actual = placeholderSignature(table[key] ?? "")
                #expect(
                    actual == expected,
                    "\(locale).\(key) expected placeholders \(expected), got \(actual)"
                )
            }
        }
    }

    @Test(
        "Locale aliases resolve the expected translation table",
        arguments: [
            ("en-GB", "en-US"),
            ("fr-CA", "fr-FR"),
            ("de-CH", "de-DE"),
            ("es-MX", "es-ES"),
            ("it-CH", "it-IT"),
            ("pt-BR", "pt-BR"),
            ("pt-PT", "pt-PT"),
            ("nl-BE", "nl-NL"),
        ]
    )
    func localeAliases(alias: String, expectedTable: String) {
        #expect(L10n.translationTable(for: alias) == L10n.translationTable(for: expectedTable))
    }

    @Test("Unsupported locales fall back to English")
    func unsupportedLocaleFallback() {
        let english = L10n.translationTable(for: "en-US")

        #expect(L10n.translationTable(for: "eo-001") == english)
        #expect(L10n.text("settings", localeIdentifier: "eo-001") == english["settings"])
    }

    @Test(
        "tvOS locale canonicalization preserves supported regional behavior",
        arguments: [
            MappingCase(input: "en_GB", expected: "en-GB"),
            MappingCase(input: "es_MX", expected: "es-MX"),
            MappingCase(input: "fr_CA", expected: "fr-CA"),
            MappingCase(input: "de_AT", expected: "de-AT"),
            MappingCase(input: "it_CH", expected: "it-CH"),
            MappingCase(input: "pt_PT", expected: "pt-PT"),
            MappingCase(input: "pt_AO", expected: "pt-BR"),
            MappingCase(input: "nb_NO", expected: "nb-NO"),
            MappingCase(input: "xx_YY", expected: "en-US"),
        ]
    )
    func tvOSCanonicalization(testCase: MappingCase) {
        #expect(L10n.canonicalTVOSLanguageIdentifier(for: testCase.input) == testCase.expected)
    }

    @Test(
        "NVIDIA locale mapping uses the service's supported region codes",
        arguments: [
            MappingCase(input: "en-GB", expected: "en_GB"),
            MappingCase(input: "es-MX", expected: "es_419"),
            MappingCase(input: "es-ES", expected: "es_ES"),
            MappingCase(input: "fr-CA", expected: "fr_CA"),
            MappingCase(input: "fr-CH", expected: "fr_FR"),
            MappingCase(input: "de-AT", expected: "de_DE"),
            MappingCase(input: "it-CH", expected: "it_IT"),
            MappingCase(input: "pt-PT", expected: "pt_PT"),
            MappingCase(input: "pt-BR", expected: "pt_BR"),
            MappingCase(input: "zh-Hans", expected: "zh_CN"),
            MappingCase(input: "zh-Hant-TW", expected: "zh_TW"),
        ]
    )
    func nvidiaLocaleMapping(testCase: MappingCase) {
        #expect(
            L10n.nvidiaLocaleCode(forTVOSLanguageIdentifier: testCase.input) == testCase.expected
        )
    }

    @Test("Simplified and Traditional Chinese aliases remain distinct")
    func chineseScripts() {
        let simplified = L10n.translationTable(for: "zh-CN")
        let traditional = L10n.translationTable(for: "zh-TW")

        #expect(simplified == L10n.translationTable(for: "zh-Hans"))
        #expect(traditional == L10n.translationTable(for: "zh-Hant-HK"))
        #expect(simplified != traditional)
    }

    @Test(
        "Keyboard layouts follow NVIDIA locale mapping",
        arguments: [
            MappingCase(input: "en_GB", expected: "en-GB"),
            MappingCase(input: "es_MX", expected: "es-419"),
            MappingCase(input: "pt_PT", expected: "pt-PT"),
            MappingCase(input: "zh_TW", expected: "zh-TW"),
        ]
    )
    func keyboardLayoutMapping(testCase: MappingCase) {
        #expect(
            L10n.keyboardLayoutCode(for: Locale(identifier: testCase.input)) == testCase.expected
        )
    }

    @Test(
        "Known store names use product branding",
        arguments: [
            ("STEAM", "Steam"),
            ("EPIC_GAMES_STORE", "Epic Games"),
            ("GOG", "GOG"),
            ("EA_APP", "EA App"),
            ("UBISOFT", "Ubisoft Connect"),
            ("MICROSOFT", "Xbox"),
            ("BATTLENET", "Battle.net"),
        ]
    )
    func knownStoreNames(code: String, expected: String) {
        #expect(L10n.storeName(for: code) == expected)
    }

    @Test("Unknown store codes receive a readable fallback")
    func unknownStoreName() {
        #expect(L10n.storeName(for: "FUTURE_GAME_STORE") == "Future Game Store")
    }

    @Test("Missing keys return the key without crashing")
    func missingKeyFallback() {
        let missing = "fixture_key_that_does_not_exist"

        #expect(L10n.text(missing, localeIdentifier: "de-DE") == missing)
    }

    private func placeholderSignature(_ format: String) -> [String] {
        let pattern =
            #"%(?:(\d+)\$)?[-+#0 ']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|j)?([@dDuUxXoOfFeEgGaAcCsSp])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(format.startIndex..., in: format)
        var sequentialPosition = 1
        return regex.matches(in: format, range: range).map { match in
            let explicitPosition = Range(match.range(at: 1), in: format)
                .flatMap { Int(format[$0]) }
            let position = explicitPosition ?? sequentialPosition
            if explicitPosition == nil {
                sequentialPosition += 1
            }
            let typeRange = Range(match.range(at: 2), in: format)
            let type = typeRange.map { placeholderType(String(format[$0])) } ?? "unknown"
            return "\(position):\(type)"
        }.sorted()
    }

    private func placeholderType(_ specifier: String) -> String {
        switch specifier.lowercased() {
        case "@", "s": "string"
        case "d", "u", "x", "o", "i": "integer"
        case "f", "e", "g", "a": "floating"
        case "c": "character"
        case "p": "pointer"
        default: "unknown"
        }
    }
}
