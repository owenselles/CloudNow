@testable import CloudNow
import Foundation
import Testing

@Suite("Localization integrity and locale mapping")
@MainActor
struct LocalizationIntegrityTests {
    /// Complete manifest of cloud UI keys added on this provider branch versus main.
    private static let branchAddedCloudUIKeys: Set<String> = [
        "about",
        "access",
        "access_not_confirmed",
        "accessibility",
        "account_access_required",
        "accounts_stay_signed_in_when_switching_services",
        "active_service",
        "active_session_switch_message",
        "awaiting_official_xbox_cloud_support",
        "browse",
        "catalog_last_updated",
        "catalog_may_be_out_of_date",
        "choose_another_service",
        "choose_cloud_gaming_service",
        "cloud_gaming_access",
        "cloud_play_unavailable",
        "cloud_service",
        "cloud_service_unavailable",
        "cloud_session_active",
        "cloud_session_in_use",
        "compatible_input_required",
        "connected",
        "controller_changes_next_session",
        "details",
        "developer",
        "end_and_switch_to_service",
        "end_session_before_sign_out",
        "ending_session",
        "free_with_ads",
        "free_with_ads_session_description",
        "game_pass",
        "gameplay_time_exhausted",
        "gfn_frame_rate_display_and_membership_unavailable",
        "gfn_frame_rate_display_unavailable",
        "gfn_frame_rate_membership_unavailable",
        "gfn_resolution_membership_unavailable",
        "high_contrast",
        "info",
        "input",
        "keyboard_and_mouse",
        "magnifier",
        "membership",
        "microsoft_account",
        "microsoft_sign_in_code_expired",
        "microsoft_sign_in_declined",
        "microphone_permission_denied_message",
        "not_eligible",
        "open_settings",
        "owned",
        "parked_session_switch_message",
        "playability",
        "playable",
        "publisher",
        "rating",
        "requesting_microsoft_sign_in_code",
        "requires_xbox_cloud_subscription",
        "reset_active_service_confirmation_message",
        "reset_failed",
        "screenshots",
        "share_optional_diagnostic_data",
        "sign_in_to_xbox_cloud_gaming",
        "sign_in_with_microsoft",
        "stream_free_with_ads",
        "subscription_access",
        "switch_to_service",
        "text_to_speech",
        "touch",
        "unavailable",
        "unavailable_reasons",
        "use_geforce_now",
        "verifying_xbox_cloud_access",
        "waiting_for_microsoft_sign_in",
        "xbox_accessibility",
        "xbox_allocating_session",
        "xbox_cloud_catalog",
        "xbox_cloud_catalog_unavailable",
        "xbox_cloud_gaming",
        "xbox_cloud_runtime_inactive_message",
        "xbox_cloud_unconfigured_message",
        "xbox_compatibility_profile_invalid",
        "xbox_connecting_stream",
        "xbox_controller_changes_next_session",
        "xbox_empty_home_message",
        "xbox_ending_session",
        "xbox_estimated_wait",
        "xbox_free_with_ads_candidate_description",
        "xbox_launch_unavailable",
        "xbox_optional_data_description",
        "xbox_privacy",
        "xbox_provisioning_console",
        "xbox_requesting_access",
        "xbox_resolution_checking_membership",
        "xbox_resolution_membership_unavailable",
        "xbox_resolution_requires_confirmed_ultimate",
        "xbox_resolution_requires_ultimate",
        "xbox_stream_settings",
        "xbox_waiting_capacity",
    ]

    /// Product names intentionally remain unchanged in every locale.
    private static let brandedEnglishValueAllowlist: Set<String> = [
        "game_pass",
        "xbox_cloud_gaming",
    ]

    /// These short UI nouns are valid identical cognates in the listed language.
    private static let englishCognateAllowlistByLanguage: [String: Set<String>] = [
        "da": ["input"],
        "de": ["details", "info", "screenshots", "touch"],
        "id": ["info", "input"],
        "ms": ["input"],
        "nl": ["details"],
    ]

    struct MappingCase: Sendable {
        let input: String
        let expected: String
    }

    @Test("Every supported translation exactly matches the English key set")
    func everyTableMatchesEnglishKeys() {
        let english = L10n.translationTable(for: "en-US")
        let expectedKeys = Set(english.keys)

        for (locale, table) in L10n.supportedTranslationTables.sorted(by: { $0.key < $1.key }) {
            let actualKeys = Set(table.keys)
            let missing = expectedKeys.subtracting(actualKeys)
            let unexpected = actualKeys.subtracting(expectedKeys)
            #expect(missing.isEmpty, "\(locale) is missing keys: \(missing.sorted())")
            #expect(unexpected.isEmpty, "\(locale) has unexpected keys: \(unexpected.sorted())")
        }
    }

    @Test("Every locale directly provides every branch-added cloud UI translation")
    func everyTableProvidesBranchAddedCloudUIKeys() {
        #expect(Self.branchAddedCloudUIKeys.count == 97)
        for (locale, table) in L10n.supportedTranslationTables.sorted(by: { $0.key < $1.key }) {
            let missing = Self.branchAddedCloudUIKeys.subtracting(table.keys)
            #expect(missing.isEmpty, "\(locale) is missing cloud UI keys: \(missing.sorted())")
        }
    }

    @Test("Branch-added cloud UI translations do not fall back to English")
    func branchAddedCloudUIValuesAreLocalized() {
        let english = L10n.translationTable(for: "en-US")

        for (locale, table) in L10n.supportedTranslationTables.sorted(by: { $0.key < $1.key })
            where Locale(identifier: locale).language.languageCode?.identifier != "en"
        {
            let language = Locale(identifier: locale)
                .language.languageCode?.identifier ?? locale
            let allowedMatches = Self.brandedEnglishValueAllowlist.union(
                Self.englishCognateAllowlistByLanguage[language] ?? []
            )
            for key in Self.branchAddedCloudUIKeys.sorted() {
                #expect(
                    table[key] != english[key] || allowedMatches.contains(key),
                    "\(locale).\(key) repeats English without an allowlist entry"
                )
            }
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

    @Test(
        "Regional service locales resolve language-only translation tables",
        arguments: [
            MappingCase(input: "ar_SA", expected: "ar"),
            MappingCase(input: "ca_ES", expected: "ca"),
            MappingCase(input: "ja_JP", expected: "ja"),
            MappingCase(input: "he_IL", expected: "he"),
            MappingCase(input: "nb_NO", expected: "nb"),
            MappingCase(input: "no_NO", expected: "nb"),
            MappingCase(input: "nn_NO", expected: "nb"),
            MappingCase(input: "uk_UA", expected: "uk"),
        ]
    )
    func regionalTranslationTableResolution(testCase: MappingCase) {
        #expect(
            L10n.translationLocaleCode(for: testCase.input) == testCase.expected
        )
        #expect(
            L10n.translationTable(for: testCase.input)
                == L10n.translationTable(for: testCase.expected)
        )
    }

    @Test("Arabic and Hebrew use right-to-left presentation")
    func rightToLeftPresentation() {
        #expect(L10n.isRightToLeft(localeIdentifier: "ar-SA"))
        #expect(L10n.isRightToLeft(localeIdentifier: "he_IL"))
        #expect(!L10n.isRightToLeft(localeIdentifier: "de-DE"))
        #expect(!L10n.isRightToLeft(localeIdentifier: "en-US"))
    }

    @Test("Language names use the active UI locale")
    func localizedLanguageNames() {
        let english = L10n.localizedLanguageName(
            for: "ja_JP",
            locale: Locale(identifier: "en_US")
        )
        let german = L10n.localizedLanguageName(
            for: "ja_JP",
            locale: Locale(identifier: "de_DE")
        )

        #expect(!english.isEmpty)
        #expect(!german.isEmpty)
        #expect(german != english)
    }

    @Test("Lists and durations follow the presentation locale")
    func localeAwareComposedValues() {
        let values = ["Alpha", "Beta", "Gamma"]
        let englishList = L10n.localizedList(
            values,
            locale: Locale(identifier: "en_US")
        )
        let germanList = L10n.localizedList(
            values,
            locale: Locale(identifier: "de_DE")
        )
        let arabicList = L10n.localizedList(
            values,
            locale: Locale(identifier: "ar_SA")
        )

        #expect(germanList != englishList)
        #expect(arabicList != englishList)
        for value in values {
            #expect(germanList.contains(value))
            #expect(arabicList.contains(value))
        }

        let englishDuration = L10n.localizedSeconds(
            1.2,
            locale: Locale(identifier: "en_US")
        )
        let germanDuration = L10n.localizedSeconds(
            1.2,
            locale: Locale(identifier: "de_DE")
        )
        let arabicDuration = L10n.localizedSeconds(
            1.2,
            locale: Locale(identifier: "ar_SA")
        )

        #expect(!englishDuration.isEmpty)
        #expect(!germanDuration.isEmpty)
        #expect(arabicDuration != englishDuration)
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
