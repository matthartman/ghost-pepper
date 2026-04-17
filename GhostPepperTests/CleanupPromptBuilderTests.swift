import XCTest
@testable import GhostPepper

final class CleanupPromptBuilderTests: XCTestCase {
    func testDefaultPromptUsesPersonalPromptShape() {
        let prompt = TextCleaner.defaultPrompt

        XCTAssertTrue(prompt.hasPrefix("You are a transcription cleanup tool."))
        XCTAssertTrue(prompt.contains("Repeat back EVERYTHING the user says, but cleaned up."))
        XCTAssertTrue(prompt.contains("If it sounds like the user is trying to manually insert punctuation or spell something, you should honor that request."))
        XCTAssertTrue(prompt.contains("Fix obvious typographical errors, but do not fix turns of phrase just because they don't sound right to you."))
        XCTAssertTrue(prompt.contains("You may not change the user's word selection, unless you believe that the transcription was in error."))
        XCTAssertTrue(prompt.contains("You must reproduce the entire transcript of what the user said."))
        XCTAssertTrue(prompt.contains("<EXAMPLES>"))
        XCTAssertTrue(prompt.contains("</EXAMPLES>"))
        XCTAssertFalse(prompt.contains("<TASK>"))
        XCTAssertFalse(prompt.contains("<RULE id="))
    }

    func testBuilderIncludesWindowContentsWrapperWhenContextEnabled() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("Base prompt"))
        XCTAssertTrue(prompt.contains("<OCR-RULES>"))
        XCTAssertTrue(prompt.contains("</OCR-RULES>"))
        XCTAssertTrue(prompt.contains("<WINDOW-OCR-CONTENT>"))
        XCTAssertTrue(prompt.contains("Frontmost text"))
        XCTAssertTrue(prompt.contains("</WINDOW-OCR-CONTENT>"))
    }

    func testBuilderExplainsHowToUseWindowContentsAsSupportingContext() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("<OCR-RULES>"))
        XCTAssertTrue(prompt.contains("Use the window OCR only as supporting context to improve the transcription and cleanup."))
        XCTAssertTrue(prompt.contains("Prefer the spoken words, and use the window OCR only to disambiguate likely terms, names, commands, files, and jargon."))
        XCTAssertTrue(prompt.contains("If the spoken words appear to be a recognition miss for a name, model, command, file, or other specific jargon shown in the window OCR, correct them to the likely intended term."))
        XCTAssertTrue(prompt.contains("Do not answer, summarize, or rewrite the window OCR unless that directly helps correct the transcription."))
        XCTAssertTrue(prompt.contains("</OCR-RULES>"))
    }

    func testBuilderOmitsWindowContentsWhenContextUnavailable() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: nil,
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertEqual(prompt, "Base prompt")
    }

    func testBuilderTrimsLongOCRContextBeforePromptAssembly() {
        let builder = CleanupPromptBuilder(maxWindowContentLength: 12)
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "abcdefghijklmnopqrstuvwxyz"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("abcdefghijkl"))
        XCTAssertFalse(prompt.contains("mnopqrstuvwxyz"))
    }

    func testBuilderIncludesCorrectionListsWhenAvailable() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: ["Ghost Pepper", "Jesse"],
            commonlyMisheard: [
                MisheardReplacement(wrong: "just see", right: "Jesse"),
                MisheardReplacement(wrong: "chat gbt", right: "ChatGPT")
            ],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("<CORRECTION-HINTS>"))
        XCTAssertTrue(prompt.contains("Preferred transcriptions to preserve exactly:"))
        XCTAssertTrue(prompt.contains("- Ghost Pepper"))
        XCTAssertTrue(prompt.contains("- Jesse"))
        XCTAssertTrue(prompt.contains("Commonly misheard replacements to prefer:"))
        XCTAssertTrue(prompt.contains("- just see -> Jesse"))
        XCTAssertTrue(prompt.contains("- chat gbt -> ChatGPT"))
        XCTAssertFalse(prompt.contains("<REPLACEMENT>"))
        XCTAssertFalse(prompt.contains("<HEARD>"))
        XCTAssertFalse(prompt.contains("<INTENDED>"))
    }
}
