import Foundation

enum L10n {
    private static let tablesByLocale: [String: [String: String]] = {
        var tables: [String: [String: String]] = [
            "ar": L10nAR.strings,
            "ca": L10nCA.strings,
            "cs": L10nCS.strings,
            "da": L10nDA.strings,
            "el": L10nEL.strings,
            "fi": L10nFI.strings,
            "he": L10nHE.strings,
            "hi": L10nHI.strings,
            "hr": L10nHR.strings,
            "hu": L10nHU.strings,
            "id": L10nID.strings,
            "ja": L10nJA.strings,
            "ko": L10nKO.strings,
            "ms": L10nMS.strings,
            "nb": L10nNB.strings,
            "pl": L10nPL.strings,
            "ro": L10nRO.strings,
            "ru": L10nRU.strings,
            "sk": L10nSK.strings,
            "sv": L10nSV.strings,
            "th": L10nTH.strings,
            "tr": L10nTR.strings,
            "uk": L10nUK.strings,
            "vi": L10nVI.strings,
            "en": L10nEN.strings,
            "fr": L10nFR.strings,
            "de": L10nDE.strings,
            "es": L10nES.strings,
            "it": L10nIT.strings,
            "pt-BR": L10nPTBR.strings,
            "pt-PT": L10nPTPT.strings,
            "zh-Hans": L10nZHHans.strings,
            "zh-Hant": L10nZHHant.strings,
        ]

        let aliases: [(table: [String: String], codes: [String])] = [
            (L10nEN.strings, ["en-AU", "en-CA", "en-IN", "en-IE", "en-NZ", "en-SG", "en-ZA", "en-GB", "en-US"]),
            (L10nFR.strings, ["fr-BE", "fr-CA", "fr-FR", "fr-CH"]),
            (L10nDE.strings, ["de-AT", "de-DE", "de-CH"]),
            (L10nES.strings, [
                "es-AR", "es-BO", "es-CL", "es-CO", "es-CR", "es-DO", "es-EC",
                "es-SV", "es-GT", "es-HN", "es-419", "es-MX", "es-NI", "es-PA",
                "es-PY", "es-PE", "es-PR", "es-ES", "es-US", "es-UY", "es-VE",
            ]),
            (L10nIT.strings, ["it-IT", "it-CH"]),
            (L10nPTBR.strings, ["pt-BR"]),
            (L10nPTPT.strings, ["pt-PT"]),
            (L10nNL.strings, ["nl-BE", "nl-NL"]),
            (L10nZHHans.strings, ["zh-Hans-CN", "zh-Hans"]),
            (L10nZHHant.strings, ["zh-Hant-HK", "zh-Hant-MO", "zh-Hant-TW", "zh-Hant"]),
        ]

        for alias in aliases {
            for code in alias.codes {
                tables[code] = alias.table
            }
        }

        return tables
    }()

    private static let fallbackLocaleCode = "en"

    static var localeCode: String {
        guard let preferred = Locale.preferredLanguages.first else { return fallbackLocaleCode }
        let canonical = canonicalTVOSLanguageIdentifier(for: preferred)
        return tablesByLocale[canonical] != nil ? canonical : fallbackLocaleCode
    }

    static func text(_ key: String) -> String {
        tablesByLocale[localeCode]?[key] ?? tablesByLocale[fallbackLocaleCode]?[key] ?? key
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), locale: Locale.autoupdatingCurrent, arguments: args)
    }

    static func storeName(for appStore: String) -> String {
        switch appStore {
        case "STEAM": "Steam"
        case "EPIC_GAMES_STORE": "Epic Games"
        case "GOG": "GOG"
        case "EA_APP": "EA App"
        case "UBISOFT": "Ubisoft Connect"
        case "MICROSOFT": "Xbox"
        case "BATTLENET": "Battle.net"
        default: appStore.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func streamStatsModeLabel(_ mode: StreamStatsMode) -> String {
        switch mode {
        case .off: text("off")
        case .hud: text("hud")
        case .diagnostic: text("diagnostic")
        }
    }

    static func colorModeLabel(_ mode: ColorModePreference) -> String {
        switch mode {
        case .automatic: text("automatic")
        case .preferHDR: text("prefer_hdr")
        case .preferSDR10: text("prefer_10_bit_sdr")
        case .forceSDR8: text("compatibility_sdr")
        }
    }

    static func colorModeDescription(_ mode: ColorModePreference) -> String {
        switch mode {
        case .automatic: text("uses_hdr_only_when_support_is_known_and_the_full_pipeline_qualifies")
        case .preferHDR: text("attempts_hdr_when_the_local_pipeline_supports_it_and_falls_back_safely")
        case .preferSDR10: text("uses_10_bit_sdr_where_possible")
        case .forceSDR8: text("uses_8_bit_sdr_for_maximum_compatibility")
        }
    }

    static func streamColorModeLabel(_ mode: StreamColorMode) -> String {
        switch mode {
        case .sdr8: text("sdr_8_bit")
        case .sdr10: text("sdr_10_bit")
        case .hdr10: text("hdr10")
        }
    }

    static func detectedColorModeLabel(_ mode: DetectedColorMode) -> String {
        switch mode {
        case .sdr8: text("sdr_8_bit")
        case .sdr10: text("sdr_10_bit")
        case .hdr10: text("hdr10")
        case .unknown8Bit: text("unknown_8_bit")
        case .unknown10Bit: text("unknown_10_bit")
        }
    }

    static func hdrSupportLabel(_ support: HDRSupport) -> String {
        switch support {
        case .supported: text("supported")
        case .unsupported: text("unsupported")
        case .unknown: text("unknown")
        }
    }

    static func colorFallbackReasonLabel(_ reason: ColorFallbackReason) -> String {
        switch reason {
        case .gameHDRUnknown: text("game_hdr_unknown")
        case .gameHDRUnsupported: text("game_hdr_unsupported")
        case .accountHDRUnavailable: text("account_hdr_unavailable")
        case .serverHDRUnavailable: text("server_hdr_unavailable")
        case .displayHDRUnavailable: text("display_hdr_unavailable")
        case .decoder10BitUnavailable: text("decoder_10_bit_unavailable")
        case .hdrRenderPipelineUnavailable: text("hdr_render_pipeline_unavailable")
        case .serverReturnedSDR: text("server_returned_sdr")
        case .decoderReturned8Bit: text("decoder_returned_8_bit")
        case .softwareDecoder: text("software_decoder")
        case .missingColorMetadata: text("missing_color_metadata")
        case .unsupportedPixelFormat: text("unsupported_pixel_format")
        case .unstablePlayback: text("unstable_playback")
        case .sessionNegotiationFailed: text("session_negotiation_failed")
        }
    }

    static func decoderPathLabel(_ path: VideoDecoderPath) -> String {
        switch path {
        case .hardware: text("hardware")
        case .softwareI420: text("software_i420")
        case .unknown: text("unknown")
        }
    }

    static func metadataDiagnosticSummary(
        transferFunction: String?,
        colorPrimaries: String?,
        yCbCrMatrix: String?,
        hasDisplayColorVolumeMetadata: Bool,
        hasContentLightLevelMetadata: Bool
    ) -> String {
        var parts: [String] = []
        if transferFunction == nil { parts.append(text("no_transfer")) }
        if colorPrimaries == nil { parts.append(text("no_primaries")) }
        if yCbCrMatrix == nil { parts.append(text("no_matrix")) }
        if !hasDisplayColorVolumeMetadata { parts.append(text("no_mastering_metadata")) }
        if !hasContentLightLevelMetadata { parts.append(text("no_content_light_metadata")) }
        return parts.isEmpty ? text("metadata_complete") : parts.joined(separator: " · ")
    }

    static func diagnosticSessionSummary(
        sessionIdPrefix: String,
        serverIp: String,
        resolution: String,
        fps: Int,
        codec: String
    ) -> String {
        format("diagnostic_session_summary", sessionIdPrefix, serverIp, resolution, fps, codec)
    }

    static func displayLayerMetrics(
        totalFrames: Int,
        droppedFrames: Int,
        corruptedFrames: Int,
        accumulatedFrameDelayMs: Double
    ) -> String {
        format("display_layer_metrics", totalFrames, droppedFrames, corruptedFrames, accumulatedFrameDelayMs)
    }

    static func colorDiagnosticStatus(
        preference: String,
        requested: String,
        detected: String,
        display: String
    ) -> String {
        format("color_diagnostic_status", preference, requested, detected, display)
    }

    static func decodedVideoStatus(
        decoderPath: String,
        mode: String,
        width: Int,
        height: Int,
        pixelFormatName: String,
        bitDepth: String,
        metadataSummary: String
    ) -> String {
        format("decoded_video_status", decoderPath, mode, width, height, pixelFormatName, bitDepth, metadataSummary)
    }

    static func videoCodecLabel(_ codec: VideoCodec) -> String {
        switch codec {
        case .h264: "H264"
        case .h265: "H265"
        case .av1: "AV1"
        }
    }

    static func streamStatsModeDescription(_ mode: StreamStatsMode) -> String {
        switch mode {
        case .off: text("disables_periodic_webrtc_statistics_collection")
        case .hud: text("collects_the_lightweight_statistics_shown_in_the_in_stream_overlay")
        case .diagnostic: text("adds_receiver_timing_renderer_metrics_frame_counters_and_instruments_signposts")
        }
    }

    static func overlayTriggerButtonLabel(_ button: OverlayTriggerButton) -> String {
        switch button {
        case .start: text("start_(≡)")
        case .options: text("options/back_(⊟)")
        }
    }

    static func remoteInputModeLabel(_ mode: RemoteInputMode) -> String {
        switch mode {
        case .mouse: text("remote_mouse")
        case .gamepad: text("remote_gamepad")
        case .dualsense: text("remote_touchpad")
        }
    }

    static func librarySortLabel(_ order: LibrarySortOrder) -> String {
        switch order {
        case .default: text("default")
        case .titleAZ: text("title_az")
        case .titleZA: text("title_za")
        case .recentFirst: text("recently_played_sort")
        }
    }

    static func preferredZoneLabel(_ zoneUrl: String?) -> String {
        guard let zoneUrl else { return text("automatic") }
        let host = URL(string: zoneUrl)?.host ?? zoneUrl
        return host.components(separatedBy: ".").first?.uppercased() ?? zoneUrl
    }

    static func nvidiaLocaleCode(for locale: Locale = .autoupdatingCurrent) -> String {
        nvidiaLocaleCode(forTVOSLanguageIdentifier: tvOSLanguageIdentifier(for: locale))
    }

    static func tvOSLanguageIdentifier(for locale: Locale = .autoupdatingCurrent) -> String {
        let language = locale.language.languageCode?.identifier.lowercased() ?? "en"
        let region = locale.region?.identifier.uppercased()
        let identifier = locale.identifier.lowercased()
        if identifier.contains("hant") || ["HK", "MO", "TW"].contains(region ?? "") {
            switch region {
            case "HK": return "zh-Hant-HK"
            case "MO": return "zh-Hant-MO"
            case "TW": return "zh-Hant-TW"
            default: return "zh-Hant-TW"
            }
        }
        if identifier.contains("hans") || language == "zh" {
            return "zh-Hans"
        }
        switch language {
        case "ca":
            return "ca-ES"
        case "cs":
            return "cs-CZ"
        case "da":
            return "da-DK"
        case "de":
            switch region {
            case "AT": return "de-AT"
            case "CH": return "de-CH"
            default: return "de-DE"
            }
        case "en":
            switch region {
            case "AU": return "en-AU"
            case "CA": return "en-CA"
            case "GB": return "en-GB"
            case "IE": return "en-IE"
            case "IN": return "en-IN"
            case "NZ": return "en-NZ"
            case "SG": return "en-SG"
            case "ZA": return "en-ZA"
            default: return "en-US"
            }
        case "es":
            switch region {
            case "AR": return "es-AR"
            case "BO": return "es-BO"
            case "CL": return "es-CL"
            case "CO": return "es-CO"
            case "CR": return "es-CR"
            case "EC": return "es-EC"
            case "ES": return "es-ES"
            case "GT": return "es-GT"
            case "HN": return "es-HN"
            case "MX": return "es-MX"
            case "NI": return "es-NI"
            case "PA": return "es-PA"
            case "PE": return "es-PE"
            case "PR": return "es-PR"
            case "DO": return "es-DO"
            case "UY": return "es-UY"
            case "VE": return "es-VE"
            case "US": return "es-US"
            default: return "es-419"
            }
        case "fr":
            switch region {
            case "BE": return "fr-BE"
            case "CA": return "fr-CA"
            case "CH": return "fr-CH"
            default: return "fr-FR"
            }
        case "it":
            return region == "CH" ? "it-CH" : "it-IT"
        case "pt":
            return region == "PT" ? "pt-PT" : "pt-BR"
        case "hr":
            return "hr-HR"
        case "hu":
            return "hu-HU"
        case "id":
            return "id-ID"
        case "ja":
            return "ja-JP"
        case "ko":
            return "ko-KR"
        case "ms":
            return "ms-MY"
        case "nb", "no", "nn":
            return "nb-NO"
        case "nl":
            return region == "BE" ? "nl-BE" : "nl-NL"
        case "pl":
            return "pl-PL"
        case "ro":
            return "ro-RO"
        case "sk":
            return "sk-SK"
        case "fi":
            return "fi-FI"
        case "sv":
            return "sv-SE"
        case "th":
            return "th-TH"
        case "tr":
            return "tr-TR"
        case "el":
            return "el-GR"
        case "ru":
            return "ru-RU"
        case "ar":
            return "ar-SA"
        case "hi":
            return "hi-IN"
        case "he":
            return "he-IL"
        case "vi":
            return "vi-VN"
        case "uk":
            return "uk-UA"
        default:
            return "en-US"
        }
    }

    static func nvidiaLocaleCode(forTVOSLanguageIdentifier identifier: String) -> String {
        let locale = Locale(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
        let language = locale.language.languageCode?.identifier.lowercased() ?? "en"
        let region = locale.region?.identifier.uppercased()
        switch language {
        case "ca":
            return "en_US"
        case "cs":
            return "cs_CZ"
        case "da":
            return "da_DK"
        case "de":
            switch region {
            case "AT": return "de_DE"
            case "CH": return "de_DE"
            default: return "de_DE"
            }
        case "en":
            switch region {
            case "AU": return "en_AU"
            case "CA": return "en_CA"
            case "GB": return "en_GB"
            case "IE": return "en_IE"
            case "IN": return "en_IN"
            case "NZ": return "en_NZ"
            case "SG": return "en_SG"
            case "ZA": return "en_ZA"
            default: return "en_US"
            }
        case "es":
            switch region {
            case "AR", "BO", "CL", "CO", "CR", "EC", "GT", "HN", "MX", "NI", "PA", "PE", "PR", "DO", "UY", "VE", "US", "419":
                return "es_419"
            case "ES":
                return "es_ES"
            default:
                return "es_419"
            }
        case "fr":
            switch region {
            case "CA": return "fr_CA"
            default: return "fr_FR"
            }
        case "hr":
            return "hr_HR"
        case "hu":
            return "hu_HU"
        case "id":
            return "id_ID"
        case "it":
            return "it_IT"
        case "ja":
            return "ja_JP"
        case "ko":
            return "ko_KR"
        case "ms":
            return "ms_MY"
        case "nb", "no", "nn":
            return "nb_NO"
        case "nl":
            return "nl_NL"
        case "pl":
            return "pl_PL"
        case "pt":
            return region == "PT" ? "pt_PT" : "pt_BR"
        case "ro":
            return "ro_RO"
        case "sk":
            return "sk_SK"
        case "fi":
            return "fi_FI"
        case "sv":
            return "sv_SE"
        case "th":
            return "th_TH"
        case "tr":
            return "tr_TR"
        case "el":
            return "el_GR"
        case "ru":
            return "ru_RU"
        case "ar":
            return "ar_SA"
        case "hi":
            return "hi_IN"
        case "he":
            return "he_IL"
        case "vi":
            return "vi_VN"
        case "uk":
            return "uk_UA"
        case "zh":
            switch region {
            case "HK", "MO", "TW":
                return "zh_TW"
            default:
                return "zh_CN"
            }
        default:
            return "en_US"
        }
    }

    static func canonicalTVOSLanguageIdentifier(for value: String) -> String {
        let normalized = value.replacingOccurrences(of: "_", with: "-")
        let locale = Locale(identifier: normalized)
        return tvOSLanguageIdentifier(for: locale)
    }

    static func keyboardLayoutCode(for locale: Locale = .autoupdatingCurrent) -> String {
        nvidiaLocaleCode(for: locale).replacingOccurrences(of: "_", with: "-")
    }

    static let supportedLanguageCodes: [String] = [
        "ar",
        "ca",
        "zh-Hans",
        "zh-Hant-HK",
        "zh-Hant-MO",
        "zh-Hant-TW",
        "hr",
        "cs",
        "da",
        "nl-BE",
        "nl-NL",
        "en-AU",
        "en-CA",
        "en-IN",
        "en-IE",
        "en-NZ",
        "en-SG",
        "en-ZA",
        "en-GB",
        "en-US",
        "fi",
        "fr-BE",
        "fr-CA",
        "fr-FR",
        "fr-CH",
        "de-AT",
        "de-DE",
        "de-CH",
        "el",
        "he",
        "hi",
        "hu",
        "id",
        "it-IT",
        "it-CH",
        "ja",
        "ko",
        "ms",
        "nb",
        "pl",
        "pt-BR",
        "pt-PT",
        "ro",
        "ru",
        "sk",
        "es-AR",
        "es-BO",
        "es-CL",
        "es-CO",
        "es-CR",
        "es-DO",
        "es-EC",
        "es-SV",
        "es-GT",
        "es-HN",
        "es-419",
        "es-MX",
        "es-NI",
        "es-PA",
        "es-PY",
        "es-PE",
        "es-PR",
        "es-ES",
        "es-US",
        "es-UY",
        "es-VE",
        "sv",
        "th",
        "tr",
        "uk",
        "vi",
    ]

    static func localizedLanguageName(for code: String) -> String {
        let locale = Locale.autoupdatingCurrent
        let id = code.replacingOccurrences(of: "_", with: "-")
        if let name = locale.localizedString(forIdentifier: id) {
            return name
        }
        let language = Locale(identifier: id).localizedString(forIdentifier: id)
        return language ?? id
    }
}
