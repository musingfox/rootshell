import Foundation
import XCTest

final class InputLanguagePolicyTests: XCTestCase {
    private let installed = ["en-US", "zh-Hans-pinyin", "zh-Hant", "ja-JP"]

    func testResolvePrefersExactMatchOverPrefix() {
        XCTAssertEqual(InputLanguagePolicy.resolve("zh-Hant", among: installed), "zh-Hant")
        XCTAssertEqual(InputLanguagePolicy.resolve("zh-Hans", among: installed), "zh-Hans-pinyin")
        XCTAssertEqual(InputLanguagePolicy.resolve("ja", among: installed), "ja-JP")
        XCTAssertNil(InputLanguagePolicy.resolve("ko", among: installed))
        XCTAssertNil(InputLanguagePolicy.resolve("en-US", among: []))
    }

    func testSystemMoveToAnotherLanguageDropsPreference() {
        // Globe or the keyboard's language list moved the system to English.
        XCTAssertTrue(InputLanguagePolicy.shouldDropPreference(resolvedPreferred: "ja-JP", systemLanguage: "en-US"))
        // A preference whose keyboard was removed can no longer be honored.
        XCTAssertTrue(InputLanguagePolicy.shouldDropPreference(resolvedPreferred: nil, systemLanguage: "en-US"))
    }

    func testMatchingOrTransientSystemModeKeepsPreference() {
        XCTAssertFalse(InputLanguagePolicy.shouldDropPreference(resolvedPreferred: "ja-JP", systemLanguage: "ja-JP"))
        XCTAssertFalse(InputLanguagePolicy.shouldDropPreference(resolvedPreferred: "ja-JP", systemLanguage: "emoji"))
        XCTAssertFalse(InputLanguagePolicy.shouldDropPreference(resolvedPreferred: "ja-JP", systemLanguage: "dictation"))
        XCTAssertFalse(InputLanguagePolicy.shouldDropPreference(resolvedPreferred: "ja-JP", systemLanguage: nil))
    }

    func testNextWrapsAndStartsFromFirstWhenCurrentIsUnknown() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(InputLanguagePolicy.next(after: "a", in: ids), "b")
        XCTAssertEqual(InputLanguagePolicy.next(after: "c", in: ids), "a")
        XCTAssertEqual(InputLanguagePolicy.next(after: nil, in: ids), "a")
        XCTAssertEqual(InputLanguagePolicy.next(after: "missing", in: ids), "a")
    }

    func testNextNeedsAtLeastTwoSources() {
        XCTAssertNil(InputLanguagePolicy.next(after: "a", in: ["a"]))
        XCTAssertNil(InputLanguagePolicy.next(after: nil, in: []))
    }
}
