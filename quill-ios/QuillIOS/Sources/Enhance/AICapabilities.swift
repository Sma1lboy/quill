import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// DEV diagnostics: probe everything the FoundationModels stack exposes on
/// this device — on-device model, per-use-case variants, supported
/// languages, and the iOS 27 Private Cloud Compute model (Apple-hosted
/// larger model, the "more API" beyond on-device).
enum AICapabilities {
    struct Report {
        var lines: [(String, String)] = []
    }

    static func probe() -> Report {
        var report = Report()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let base = SystemLanguageModel.default
            report.lines.append(("on-device model", describe(base.availability)))
            report.lines.append((
                "languages",
                "\(base.supportedLanguages.count) supported"
            ))
            let zh = base.supportedLanguages.contains {
                $0.languageCode?.identifier.hasPrefix("zh") == true
            }
            report.lines.append(("chinese", zh ? "supported" : "not supported"))

            let tagging = SystemLanguageModel(useCase: .contentTagging)
            report.lines.append(("tagging variant", describe(tagging.availability)))
        } else {
            report.lines.append(("on-device model", "requires iOS 26"))
        }

        if #available(iOS 27.0, *) {
            let pcc = PrivateCloudComputeLanguageModel()
            report.lines.append(("private cloud", describePCC(pcc.availability)))
            report.lines.append(("pcc quota", describeQuota(pcc.quotaUsage)))
        } else {
            report.lines.append(("private cloud", "requires iOS 27"))
        }
        #else
        report.lines.append(("foundation models", "not in SDK"))
        #endif
        return report
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func describe(_ a: SystemLanguageModel.Availability) -> String {
        switch a {
        case .available: return "available"
        case .unavailable(.appleIntelligenceNotEnabled): return "AI not enabled"
        case .unavailable(.modelNotReady): return "model not ready"
        case .unavailable(.deviceNotEligible): return "device not eligible"
        case .unavailable: return "unavailable"
        }
    }

    @available(iOS 27.0, *)
    private static func describePCC(_ a: PrivateCloudComputeLanguageModel.Availability) -> String {
        switch a {
        case .available: return "available"
        case .unavailable(.deviceNotEligible): return "device not eligible"
        case .unavailable(.systemNotReady): return "system not ready"
        case .unavailable: return "unavailable"
        }
    }

    @available(iOS 27.0, *)
    private static func describeQuota(_ q: PrivateCloudComputeLanguageModel.QuotaUsage) -> String {
        switch q.status {
        case .belowLimit: return "below limit"
        case .limitReached: return "limit reached"
        @unknown default: return "unknown"
        }
    }
    #endif
}
