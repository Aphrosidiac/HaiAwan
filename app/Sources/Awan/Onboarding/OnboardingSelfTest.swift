import AppKit
import SwiftUI

/// `Awan --onboarding-selftest` — tutorial panel + plan step checks (XCTest isn't available with the Command Line
/// Tools, so this runs in-process like the other self-tests). Layout numbers are checked against the
/// reference captures with the snapshot instruments. Prints PASS/FAIL lines, exits 0/1.
@MainActor
enum OnboardingSelfTest {
    static func run(_ args: [String]) -> Never {
        var failures = 0
        var count = 0
        func check(_ ok: Bool, _ name: String) {
            count += 1
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(name)")
        }

        // Window sizes per stage
        check(OnboardingLayout.size(for: .intro) == CGSize(width: 720, height: 480), "setup steps keep the 720×480 card")
        check(OnboardingLayout.size(for: .interview) == CGSize(width: 720, height: 480), "interview keeps the card")
        check(OnboardingStage.tutorial.filter { $0 != .interview }.allSatisfy { OnboardingLayout.size(for: $0) == CGSize(width: 500, height: 571) },
              "every tutorial step uses the 500×571 panel")
        check(OnboardingLayout.size(for: .plans) == CGSize(width: 800, height: 543), "plan step is 800×543")

        // Page dots
        check(OnboardingStage.dotted.count == 7, "seven page dots")
        check(OnboardingStage.micCheck.dotIndex == 0 && OnboardingStage.speakerCheck.dotIndex == 0, "mic + speaker share dot 1")
        check(OnboardingStage.voiceHello.dotIndex == 1 && OnboardingStage.dictation.dotIndex == 6, "talk is dot 2, dictation dot 7")
        check(OnboardingStage.finale.dotIndex == 7, "finale shows every dot done")

        // Back targets
        check(OnboardingStage.micCheck.previousPanelStage == nil, "no Back on the first step")
        check(OnboardingStage.drawDemo.previousPanelStage == .voiceHello, "Back from pointing skips the interview")
        check(OnboardingStage.finale.previousPanelStage == .dictation, "Back from the finale goes to dictation")

        // Continue gating
        check(!OnboardingModel.isSatisfied(.micCheck, completed: []), "Continue dim until the mic is heard")
        check(OnboardingModel.isSatisfied(.micCheck, completed: [.micCheck]), "Continue live once the mic is heard")
        check(!OnboardingModel.isSatisfied(.voiceHello, completed: [.micCheck]), "Continue dim until the first voice turn")
        check(OnboardingModel.isSatisfied(.speakerCheck, completed: []) && OnboardingModel.isSatisfied(.finale, completed: []),
              "speaker check and finale are self-reported")

        // Flow: finale → plans → squad; Skip demo → plans (with starters when no interview happened)
        let m = OnboardingModel()
        m.stage = .finale
        m.advance()
        check(m.stage == .plans && m.plansShown, "finale → plan step")
        m.choosePlan(nil, yearly: false)
        check(m.stage == .squad, "\"Use Awan for free\" → squad")
        let m2 = OnboardingModel()
        m2.stage = .voiceHello
        m2.skipDemo()
        check(m2.stage == .plans && m2.cast == .skipped, "Skip demo → plan step, starter squad")
        TourMusic.shared.stop()

        print("\(count - failures)/\(count) onboarding checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
