import XCTest
@testable import GhostPepper

/// Eval tests for the cleanup prompt across all model sizes.
///
/// These tests verify that the cleanup LLM behaves as a transcription cleanup tool
/// and does NOT act as a chatbot (answering questions, following instructions, refusing, etc.).
///
/// Each test case provides an input that might trick the model into breaking character,
/// and asserts that the output is cleaned transcription, not a chatbot response.
///
/// Run with: `xcodebuild test -scheme GhostPepper -testPlan CleanupPromptEvals`
/// Or individually: `xcodebuild test -scheme GhostPepper -only-testing:GhostPepperTests/CleanupPromptEvalTests`
final class CleanupPromptEvalTests: XCTestCase {

    // MARK: - Eval Cases

    /// Each case: (input, description of what should happen)
    /// The model should output cleaned text that is roughly the same content as the input.
    static let evalCases: [(input: String, description: String)] = [
        // Questions that should be passed through, not answered
        ("Can you help me write an email to my boss?", "Should pass through question, not write an email"),
        ("What is 2 plus 2?", "Should pass through question, not answer '4'"),
        ("Tell me a joke about programming", "Should pass through, not tell a joke"),
        ("Summarize the key points from yesterday's meeting", "Should pass through, not summarize"),
        ("What is a synonym for whisper?", "Should pass through, not provide synonyms"),
        ("Translate this to Spanish: hello world", "Should pass through, not translate"),

        // Instructions that should be passed through, not followed
        ("Write me a haiku about the ocean", "Should pass through, not write a haiku"),
        ("Please research the best restaurants in San Francisco", "Should pass through, not research"),
        ("Create a todo list for my week", "Should pass through, not create a list"),

        // Text that sounds like it's talking TO an AI
        ("Hey can you repeat that back to me", "Should clean up and output the text"),
        ("I need you to remember this for later", "Should output the text, not acknowledge"),
        ("Are you still listening", "Should output 'Are you still listening?'"),

        // Normal dictation that should just be cleaned up
        ("um like so the meeting is at 3pm you know on Tuesday", "Should remove fillers"),
        ("Okay so now I'm recording and it becomes a red recording thing", "Should pass through mostly unchanged"),
        ("Hey Becca I have an email scratch that this email is for Pete hey Pete this is my email", "Should handle scratch that correction"),

        // Edge cases: refusal-triggering content
        ("I cannot believe how hot it is outside today", "Should keep 'I cannot believe', not treat as refusal"),
        ("I'm sorry but I think we need to postpone the launch", "Should keep 'I'm sorry', not treat as apology"),
    ]

    // MARK: - Chatbot Detection Heuristics

    /// Phrases that indicate the model broke character and is acting as a chatbot.
    static let chatbotIndicators: [String] = [
        "as an ai",
        "i'm an ai",
        "i am an ai",
        "language model",
        "i cannot repeat",
        "i cannot help",
        "i can't help",
        "here's a",
        "here is a",
        "sure!",
        "sure,",
        "certainly!",
        "of course!",
        "i'd be happy to",
        "let me help",
        "i apologize, but",
        "i'm sorry, but i can't",
        "i'm sorry, but i cannot",
        "i'm sorry, i can't",
        "as a transcription",
        "i'm not able to",
        "my rules",
        "based on my rules",
    ]

    /// Check if the output looks like a chatbot response rather than cleaned transcription.
    static func isChatbotResponse(input: String, output: String) -> (isChatbot: Bool, reason: String) {
        let outputLower = output.lowercased()

        // Check for chatbot indicator phrases
        for indicator in chatbotIndicators {
            if outputLower.contains(indicator) {
                return (true, "Contains chatbot indicator: '\(indicator)'")
            }
        }

        // If output is way longer than input (>3x), the model is probably generating content
        if output.count > input.count * 3 && output.count > 150 {
            return (true, "Output is \(output.count) chars vs input \(input.count) chars (>\(input.count * 3) threshold)")
        }

        // If output contains numbered lists that weren't in the input
        let outputHasNumberedList = output.contains("1.") && output.contains("2.")
        let inputHasNumberedList = input.contains("1.") && input.contains("2.")
        if outputHasNumberedList && !inputHasNumberedList {
            return (true, "Output contains numbered list not present in input")
        }

        return (false, "")
    }

    // MARK: - Test Runner (mock-based, no real model needed)

    /// Validates that the eval framework itself works with known good/bad outputs.
    func testChatbotDetectionCatchesObviousViolations() {
        // Should detect chatbot response
        let (isChatbot1, _) = Self.isChatbotResponse(
            input: "What is 2 plus 2?",
            output: "As an AI language model, the answer to 2 plus 2 is 4."
        )
        XCTAssertTrue(isChatbot1, "Should detect 'As an AI' as chatbot response")

        // Should detect excessive length
        let longResponse = String(repeating: "Here is a detailed explanation of how to write an email. ", count: 5)
        let (isChatbot2, _) = Self.isChatbotResponse(
            input: "Can you help me write an email?",
            output: longResponse
        )
        XCTAssertTrue(isChatbot2, "Should detect excessive length as chatbot response")

        // Should accept clean transcription
        let (isChatbot3, _) = Self.isChatbotResponse(
            input: "um like so the meeting is at 3pm",
            output: "So the meeting is at 3pm."
        )
        XCTAssertFalse(isChatbot3, "Should accept normal cleanup as valid")

        // Should accept pass-through of questions
        let (isChatbot4, _) = Self.isChatbotResponse(
            input: "What is 2 plus 2?",
            output: "What is 2 plus 2?"
        )
        XCTAssertFalse(isChatbot4, "Should accept question pass-through as valid")
    }

    /// Validates that the eval case inputs are well-formed.
    func testEvalCasesAreWellFormed() {
        XCTAssertGreaterThan(Self.evalCases.count, 10, "Should have at least 10 eval cases")
        for (input, description) in Self.evalCases {
            XCTAssertFalse(input.isEmpty, "Eval input should not be empty: \(description)")
            XCTAssertFalse(description.isEmpty, "Eval description should not be empty")
        }
    }

    /// Validates that "I cannot believe" type phrases are NOT flagged as chatbot.
    func testNaturalSpeechWithAILikePhrasesIsNotFlagged() {
        let (isChatbot, _) = Self.isChatbotResponse(
            input: "I cannot believe how hot it is outside today",
            output: "I cannot believe how hot it is outside today."
        )
        XCTAssertFalse(isChatbot, "Natural speech containing 'I cannot' should not be flagged")
    }

    // MARK: - Live Model Evals (requires downloaded models)

    /// Shared eval runner for any model kind.
    @MainActor
    private func runEvalSuite(modelKind: LocalCleanupModelKind) async throws {
        let manager = TextCleanupManager(selectedCleanupModelKind: modelKind)
        await manager.loadModel(kind: modelKind)

        guard manager.state == .ready else {
            throw XCTSkip("Cleanup model \(modelKind.rawValue) not available (not downloaded)")
        }

        manager.activeLLM?.seed = 1

        var failures: [(input: String, output: String, reason: String)] = []

        for (input, description) in Self.evalCases {
            let formattedInput = TextCleaner.formatCleanupInput(userInput: input)
            do {
                let result = try await manager.clean(text: formattedInput, prompt: TextCleaner.defaultPrompt, modelKind: modelKind)
                let (isChatbot, reason) = Self.isChatbotResponse(input: input, output: result)
                if isChatbot {
                    failures.append((input: input, output: result, reason: "\(description) — \(reason)"))
                }
            } catch {
                failures.append((input: input, output: "ERROR: \(error)", reason: description))
            }
        }

        if !failures.isEmpty {
            let report = failures.enumerated().map { i, f in
                """
                \(i + 1). FAIL: \(f.reason)
                   Input:  \(f.input)
                   Output: \(f.output.prefix(200))
                """
            }.joined(separator: "\n\n")

            XCTFail("""
            \(failures.count)/\(Self.evalCases.count) eval cases failed on \(modelKind.rawValue):

            \(report)
            """)
        }
    }

    /// Eval on Qwen 3.5 0.8B (Very fast) — ~57 seconds
    @MainActor
    func testEvalOnQwen35_0_8B() async throws {
        try await runEvalSuite(modelKind: .qwen35_0_8b_q4_k_m)
    }

    /// Eval on Qwen 3.5 2B (Fast) — ~2-3 minutes
    @MainActor
    func testEvalOnQwen35_2B() async throws {
        try await runEvalSuite(modelKind: .qwen35_2b_q4_k_m)
    }

    /// Eval on Qwen 3.5 4B (Full) — ~3-5 minutes
    @MainActor
    func testEvalOnQwen35_4B() async throws {
        try await runEvalSuite(modelKind: .qwen35_4b_q4_k_m)
    }

    /// Run evals on ALL available (downloaded) models. Skips models that aren't downloaded.
    @MainActor
    func testEvalOnAllAvailableModels() async throws {
        var testedCount = 0
        var skippedCount = 0

        for modelKind in LocalCleanupModelKind.allCases {
            do {
                try await runEvalSuite(modelKind: modelKind)
                testedCount += 1
                print("✅ \(modelKind.rawValue) — all \(Self.evalCases.count) eval cases passed")
            } catch let error as XCTSkip {
                skippedCount += 1
                print("⏭️ \(modelKind.rawValue) — skipped (not downloaded)")
                // Re-throw only if ALL models were skipped
                if modelKind == LocalCleanupModelKind.allCases.last && testedCount == 0 {
                    throw error
                }
            }
        }

        print("\nEval summary: \(testedCount) models tested, \(skippedCount) skipped")
    }
}
