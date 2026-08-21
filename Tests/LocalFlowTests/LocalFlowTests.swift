import XCTest
@testable import LocalFlow

// Unit tests for the pure, deterministic logic: RuleCleaner, the
// dictionary find/replace pass, and snippet trigger matching.
// Nothing here touches the microphone, models, or persistence.

final class RuleCleanerTests: XCTestCase {

    // MARK: stripArtifacts

    func testStripsWhisperSpecialTokens() {
        let input = "<|startoftranscript|>Hello there<|endoftext|>"
        XCTAssertEqual(RuleCleaner.stripArtifacts(input), "Hello there")
    }

    func testStripsBracketedAnnotations() {
        let input = "[BLANK_AUDIO] Hello [MUSIC]"
        XCTAssertEqual(RuleCleaner.stripArtifacts(input), "Hello")
    }

    func testStripArtifactsTrimsWhitespace() {
        XCTAssertEqual(RuleCleaner.stripArtifacts("  Hello  "), "Hello")
    }

    // MARK: clean

    func testRemovesFillerWordsAndTidiesPunctuation() {
        let input = "um, hello  there , world"
        XCTAssertEqual(RuleCleaner.clean(input), "Hello there, world")
    }

    func testRemovesElongatedFillers() {
        XCTAssertEqual(RuleCleaner.clean("ummm so that works"), "So that works")
    }

    func testDoesNotRemoveWordsContainingFillerLetters() {
        let input = "The umbrella is here"
        XCTAssertEqual(RuleCleaner.clean(input), "The umbrella is here")
    }

    func testCapitalisesFirstLetter() {
        XCTAssertEqual(RuleCleaner.clean("hello"), "Hello")
    }

    func testCollapsesRepeatedWhitespace() {
        XCTAssertEqual(RuleCleaner.clean("Hello   there   world"), "Hello there world")
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(RuleCleaner.clean(""), "")
    }
}

final class DictionaryStoreTests: XCTestCase {

    func testCaseInsensitiveWholeWordReplacement() {
        let pairs = [WordPair(wrong: "acme", right: "ACME")]
        let result = DictionaryStore.applyPairs(pairs, to: "acme and Acme are acmelike")
        XCTAssertEqual(result, "ACME and ACME are acmelike")
    }

    func testMultiplePairsApply() {
        let pairs = [
            WordPair(wrong: "jon", right: "John"),
            WordPair(wrong: "pay just now", right: "PayJustNow"),
        ]
        let result = DictionaryStore.applyPairs(pairs, to: "jon works at pay just now")
        XCTAssertEqual(result, "John works at PayJustNow")
    }

    func testEmptyPairsAreSkipped() {
        let pairs = [WordPair(wrong: "", right: "X"), WordPair(wrong: "y", right: "")]
        let text = "nothing changes here"
        XCTAssertEqual(DictionaryStore.applyPairs(pairs, to: text), text)
    }

    func testRegexSpecialCharactersInWrongAreEscaped() {
        let pairs = [WordPair(wrong: "v1.0", right: "v2.0")]
        // The dot must match literally, not "v1 plus any character plus 0".
        let result = DictionaryStore.applyPairs(pairs, to: "release v1.0 today, not v1x0")
        XCTAssertEqual(result, "release v2.0 today, not v1x0")
    }

    func testNoPairsReturnsInputUnchanged() {
        XCTAssertEqual(DictionaryStore.applyPairs([], to: "as is"), "as is")
    }
}

final class SnippetStoreTests: XCTestCase {

    private let snippets = [
        Snippet(trigger: "insert my address", expansion: "1 Main Road, Cape Town"),
        Snippet(trigger: "sign off", expansion: "Kind regards,\nMark"),
    ]

    func testExactTriggerMatches() {
        XCTAssertEqual(
            SnippetStore.expansion(for: "insert my address", in: snippets),
            "1 Main Road, Cape Town"
        )
    }

    func testMatchIgnoresCaseAndPunctuation() {
        XCTAssertEqual(
            SnippetStore.expansion(for: "Insert my address.", in: snippets),
            "1 Main Road, Cape Town"
        )
        XCTAssertEqual(
            SnippetStore.expansion(for: "SIGN OFF!", in: snippets),
            "Kind regards,\nMark"
        )
    }

    func testPartialTranscriptDoesNotMatch() {
        XCTAssertNil(SnippetStore.expansion(for: "please insert my address", in: snippets))
    }

    func testEmptyTranscriptDoesNotMatch() {
        XCTAssertNil(SnippetStore.expansion(for: "", in: snippets))
        XCTAssertNil(SnippetStore.expansion(for: "...", in: snippets))
    }

    func testEmptyTriggerNeverMatches() {
        let withEmpty = [Snippet(trigger: "", expansion: "boom")]
        XCTAssertNil(SnippetStore.expansion(for: "anything", in: withEmpty))
    }
}
