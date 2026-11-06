import XCTest
import AppKit
import PDFKit
import LemmaCore
@testable import Lemma

/// Answers API requests from a script; no request leaves the Mac.
final class AssistantAPIStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var chunks: [Data] = []
    nonisolated(unsafe) static var hang = false
    nonisolated(unsafe) static var stopped = false
    nonisolated(unsafe) static var sent: [(request: URLRequest, body: Data)] = []

    static func configuration(status: Int = 200, chunks: [Data] = [], hang: Bool = false) -> URLSessionConfiguration {
        self.status = status; self.chunks = chunks; self.hang = hang; stopped = false; sent = []
        let configuration = APIClient.configuration(idleTimeout: 5, totalTimeout: 10)
        configuration.protocolClasses = [AssistantAPIStub.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        Self.sent.append((request, request.httpBody ?? body))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.hang { return }
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopped = true }
}

final class AssistantFlowTests: XCTestCase {
    @MainActor
    func testLiveSubscriptionRoundTripsOnPublicFixtureOnly() async throws {
        guard ProcessInfo.processInfo.environment["LEMMA_ASSISTANT_LIVE"] == "1" else {
            throw XCTSkip("Opt-in: sends only the generated public mathematics fixture to each installed CLI.")
        }
        var evidence: [[String: Any]] = []
        for provider in [QuestionProvider.codex, .claudeCode] {
            let (store, _, source) = try fixture()
            store.questions.loginShellPath = { await CLIEnvironment.loginShellPath() }
            let original = try Data(contentsOf: source)
            let note = try XCTUnwrap(store.currentNote), bookID = try XCTUnwrap(store.workspace?.id)
            let image = try Data(contentsOf: store.repository.assetURL(workspaceID: bookID, name: note.anchor.imageName))
            store.askWeb(mode: .askAndSave, content: QuestionContent(prompt: "Public integration test. The image says X transpose X. In one short sentence, explain why full column rank makes this matrix invertible. Do not use tools.", images: [("Source A", image)]), noteID: note.id, provider: provider)
            let deadline = Date().addingTimeInterval(120)
            while store.questions.jobs.first?.finished != true, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let job = try XCTUnwrap(store.questions.jobs.first)
            XCTAssertTrue(job.finished, provider.label); XCTAssertFalse(job.failed, job.message)
            let saved = try XCTUnwrap(store.repository.load(id: bookID)?.notes.first)
            XCTAssertEqual(saved.explanation?.provider, provider); XCTAssertNil(saved.pendingRequestID)
            XCTAssertFalse(saved.explanation?.body.isEmpty ?? true)
            XCTAssertEqual(try Data(contentsOf: source), original)
            evidence.append(["provider": provider.rawValue, "finished": job.finished, "failed": job.failed, "message": job.message, "answer": saved.explanation?.body ?? "", "model": saved.explanation?.model ?? "provider default"])
            store.questions.shutdown()
        }
        if let path = ProcessInfo.processInfo.environment["LEMMA_ASSISTANT_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testBothCLIsReturnToOriginalBookWhileAnotherBookIsOpen() async throws {
        for provider in [QuestionProvider.codex, .claudeCode] {
            let (store, root, source) = try fixture()
            let original = try Data(contentsOf: source)
            let executable = try mockCLI(root, provider: provider)
            store.questions.executableOverrides[provider] = executable
            let bookID = try XCTUnwrap(store.workspace?.id), note = try XCTUnwrap(store.currentNote)
            let content = QuestionContent(prompt: "Explain $X^\\top X$.\n$(nothing)", images: [("Source A", try Data(contentsOf: store.repository.assetURL(workspaceID: bookID, name: note.anchor.imageName)))])
            store.askWeb(mode: .askAndSave, content: content, noteID: note.id, provider: provider)
            let requestID = try XCTUnwrap(store.currentNote?.pendingRequestID)
            let other = root.appendingPathComponent("other.pdf")
            let otherPDF = try XCTUnwrap(PDFDocument(url: source))
            otherPDF.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Another book"]
            XCTAssertTrue(otherPDF.write(to: other)); store.open(other)
            let activeID = store.workspace?.id
            XCTAssertNotEqual(activeID, bookID)
            try await wait { store.questions.jobs.first?.finished == true }
            XCTAssertFalse(try XCTUnwrap(store.questions.jobs.first).failed)
            let saved = try XCTUnwrap(store.repository.load(id: bookID)?.notes.first(where: { $0.id == note.id }))
            XCTAssertNil(saved.pendingRequestID); XCTAssertEqual(saved.explanation?.body, "Full rank gives uniqueness: $X^\\top X$.")
            XCTAssertEqual(saved.explanation?.provider, provider)
            XCTAssertEqual(store.workspace?.id, activeID); XCTAssertTrue(store.workspace?.notes.isEmpty == true)
            XCTAssertEqual(store.selectedNoteID, nil); XCTAssertEqual(try Data(contentsOf: source), original)
            let input = try Data(contentsOf: store.mailbox.directory(requestID).appendingPathComponent("received-input"))
            if provider == .claudeCode {
                let value = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
                let content = try XCTUnwrap((value["message"] as? [String: Any])?["content"] as? [[String: Any]])
                XCTAssertEqual(content.count, 2, "The selected image travels alongside the text.")
            } else { XCTAssertTrue(String(decoding: input, as: UTF8.self).contains("$(nothing)")) }
            store.questions.shutdown(); store.flush()
        }
    }

    @MainActor
    func testClosingTheLastQuestionWindowDoesNotLoseAnotherWindowsAnswer() async throws {
        let (first, root, source) = try fixture()
        defer { first.questions.shutdown(); first.app.prepareForTermination() }
        first.questions.executableOverrides[.codex] = try mockCLI(root, provider: .codex, slow: true)
        first.questions.executableOverrides[.claudeCode] = try mockCLI(root, provider: .claudeCode)
        let noteID = try XCTUnwrap(first.currentNote?.id)
        first.askWeb(mode: .askAndSave, content: try content(first), noteID: noteID, provider: .codex)
        let firstJob = try XCTUnwrap(first.questions.jobs.first)
        try await wait { firstJob.process != nil }

        var second: StudyStore? = StudyStore(app: first.app, windowID: UUID())
        weak var closedWindow = second
        let other = root.appendingPathComponent("other-window.pdf")
        let pdf = try XCTUnwrap(PDFDocument(url: source))
        pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Another window"]
        XCTAssertTrue(pdf.write(to: other))
        second!.open(other)
        second!.reader.selection = (0, CGRect(x: 20, y: 35, width: 240, height: 60), "X transpose X")
        second!.addNote(); second!.updateNote { $0.question = "Another question" }
        second!.askWeb(mode: .askAndSave, content: try content(second!), noteID: try XCTUnwrap(second!.currentNote?.id), provider: .claudeCode)
        let secondJob = try XCTUnwrap(first.questions.jobs.first)
        try await wait { secondJob.finished }
        second!.flush(); second = nil
        try await wait { closedWindow == nil }
        try await wait { firstJob.finished }
        first.pollBrowser()
        XCTAssertEqual(try first.mailbox.result(firstJob.id)?.status, "complete", "A completed answer must be written even after the last question's window closes.")
        XCTAssertNil(first.currentNote?.pendingRequestID)
        XCTAssertEqual(first.currentNote?.explanation?.body, "Full rank gives uniqueness: $X^\\top X$.")
        first.questions.retry(firstJob)
        XCTAssertNotEqual(first.questions.jobs.first?.id, firstJob.id, "Ask Again still works after the last question's window closed.")
        XCTAssertEqual(first.currentNote?.pendingRequestID, first.questions.jobs.first?.id)
        first.cancelQuestion(noteID: noteID)
    }

    /// Lemma used to reject anything but a subscription login. Every sign-in the CLI supports is now used as it is.
    @MainActor
    func testCLIsSignedInWithAnAPIKeyAreUsedAndSignedOutOnesExplain() async throws {
        for (provider, status) in [(QuestionProvider.claudeCode, #"{"loggedIn":true,"authMethod":"api_key"}"#), (.codex, "Logged in using an API key - sk-proj-***ABCD")] {
            let (store, root, _) = try fixture()
            store.questions.executableOverrides[provider] = try mockCLI(root, provider: provider, status: status)
            store.askWeb(mode: .askAndSave, content: try content(store), noteID: try XCTUnwrap(store.currentNote?.id), provider: provider)
            try await wait { store.questions.jobs.first?.finished == true }
            let job = try XCTUnwrap(store.questions.jobs.first)
            XCTAssertFalse(job.failed, job.message)
            XCTAssertEqual(store.questions.connections[provider], "Signed in · API key")
            store.questions.shutdown()
        }
        let (store, root, _) = try fixture()
        store.questions.executableOverrides[.claudeCode] = try mockCLI(root, provider: .claudeCode, status: #"{"loggedIn":false,"authMethod":"none"}"#, statusCode: 1)
        store.askWeb(mode: .askAndSave, content: try content(store), noteID: try XCTUnwrap(store.currentNote?.id), provider: .claudeCode)
        try await wait { store.questions.jobs.first?.finished == true }
        let job = try XCTUnwrap(store.questions.jobs.first)
        XCTAssertTrue(job.failed); XCTAssertTrue(job.message.contains("not signed in"), job.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mailbox.directory(job.id).appendingPathComponent("received-input").path), "Nothing is sent.")
    }

    /// An older CLI that refuses a hardening option, and exits while a large question is still being written: Lemma
    /// survives the broken pipe, asks again without the option, and the answer arrives.
    @MainActor
    func testAnOlderCLIThatRefusesAnOptionIsAskedAgainAndABrokenPipeIsHarmless() async throws {
        let (store, root, _) = try fixture()
        store.questions.executableOverrides[.claudeCode] = try mockCLI(root, provider: .claudeCode, refuse: "--safe-mode")
        let large = Data((0..<600_000).map { UInt8($0 % 251) })
        store.askWeb(mode: .askAndSave, content: QuestionContent(prompt: "A test question", images: [("Source A", large)]), noteID: try XCTUnwrap(store.currentNote?.id), provider: .claudeCode)
        try await wait(seconds: 20) { store.questions.jobs.first?.finished == true }
        let job = try XCTUnwrap(store.questions.jobs.first)
        XCTAssertFalse(job.failed, job.message)
        XCTAssertEqual(store.currentNote?.explanation?.body, "Full rank gives uniqueness: $X^\\top X$.")
        let arguments = try String(contentsOf: store.mailbox.directory(job.id).appendingPathComponent("received-arguments"), encoding: .utf8)
        XCTAssertFalse(arguments.contains("--safe-mode")); XCTAssertTrue(arguments.contains("--tools"))
    }

    @MainActor
    func testCancellationKeepsExistingExplanationAndIgnoresLateResponse() async throws {
        let (store, root, _) = try fixture()
        let provider = QuestionProvider.codex
        store.questions.executableOverrides[provider] = try mockCLI(root, provider: provider, slow: true)
        store.updateNote { $0.explanation = SavedExplanation(body: "Keep my earlier answer.") }
        let noteID = try XCTUnwrap(store.currentNote?.id)
        store.askWeb(mode: .askAndSave, content: QuestionContent(prompt: "A test question", images: []), noteID: noteID, provider: provider)
        let id = try XCTUnwrap(store.currentNote?.pendingRequestID)
        try await wait { store.questions.jobs.first?.process != nil }
        store.cancelQuestion(noteID: noteID)
        XCTAssertNil(store.currentNote?.pendingRequestID)
        XCTAssertEqual(store.currentNote?.explanation?.body, "Keep my earlier answer.")
        try store.mailbox.saveResult(BrowserResult(requestID: id, status: "complete", answer: "Late answer"))
        store.pollBrowser()
        XCTAssertEqual(store.currentNote?.explanation?.body, "Keep my earlier answer.")
    }

    // MARK: API providers

    @MainActor
    func testAnAPIAnswerStreamsIntoItsNoteWithProviderAndModel() async throws {
        let (store, _, _) = try fixture()
        store.questions.keys = MemoryAPIKeyStore([.anthropic: "sk-ant-api03-test-key-0001"])
        let events = [#"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#,
                      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Full rank gives "}}"#,
                      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"uniqueness."}}"#,
                      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, #"{"type":"message_stop"}"#]
        store.questions.apiClient = APIClient(configuration: AssistantAPIStub.configuration(chunks: events.map { Data("data: \($0)\n\n".utf8) }))
        let content = try content(store)
        let bookID = try XCTUnwrap(store.workspace?.id), noteID = try XCTUnwrap(store.currentNote?.id)
        store.askWeb(mode: .askAndSave, content: content, noteID: noteID, provider: .anthropic)
        try await wait { store.questions.jobs.first?.finished == true }
        let job = try XCTUnwrap(store.questions.jobs.first)
        XCTAssertFalse(job.failed, job.message)
        let saved = try XCTUnwrap(store.repository.load(id: bookID)?.notes.first { $0.id == noteID })
        XCTAssertEqual(saved.explanation?.body, "Full rank gives uniqueness."); XCTAssertNil(saved.pendingRequestID)
        XCTAssertEqual(saved.explanation?.provider, .anthropic); XCTAssertEqual(saved.explanation?.model, "claude-opus-5-5")
        let (request, body) = try XCTUnwrap(AssistantAPIStub.sent.first)
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-api03-test-key-0001")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(content.images[0].data.base64EncodedString()), "The passage image is sent.")
        // Nothing about the key is written beside the question.
        for name in try FileManager.default.contentsOfDirectory(atPath: store.mailbox.directory(job.id).path) {
            let text = String(decoding: try Data(contentsOf: store.mailbox.directory(job.id).appendingPathComponent(name)), as: UTF8.self)
            XCTAssertFalse(text.contains("sk-ant-api03"), name)
        }
    }

    @MainActor
    func testAPIFailuresKeepTheNoteAndSayWhatToDo() async throws {
        let (store, _, _) = try fixture()
        let noteID = try XCTUnwrap(store.currentNote?.id)
        store.updateNote { $0.explanation = SavedExplanation(body: "Keep my earlier answer.") }
        store.askWeb(mode: .askAndSave, content: try content(store), noteID: noteID, provider: .openAI)
        try await wait { store.questions.jobs.first?.finished == true }
        XCTAssertEqual(store.questions.jobs.first?.message, "Add your OpenAI API key in Assistants › Connections first.")
        XCTAssertNil(store.currentNote?.pendingRequestID)

        store.questions.keys = MemoryAPIKeyStore([.openAI: "sk-proj-wrong-key-0002"])
        store.questions.apiClient = APIClient(configuration: AssistantAPIStub.configuration(status: 401, chunks: [Data(#"{"error":{"message":"Incorrect API key provided: sk-proj-****0002.","code":"invalid_api_key"}}"#.utf8)]))
        store.askWeb(mode: .askAndSave, content: try content(store), noteID: noteID, provider: .openAI)
        try await wait { store.questions.jobs.first?.finished == true && store.questions.jobs.count == 2 }
        let job = try XCTUnwrap(store.questions.jobs.first)
        XCTAssertTrue(job.failed); XCTAssertTrue(job.message.hasPrefix("OpenAI API rejected the API key."), job.message)
        XCTAssertFalse(job.message.contains("sk-proj"))
        XCTAssertEqual(store.currentNote?.explanation?.body, "Keep my earlier answer."); XCTAssertNil(store.currentNote?.pendingRequestID)
    }

    @MainActor
    func testCancellingAnAPIQuestionStopsTheRequest() async throws {
        let (store, _, _) = try fixture()
        store.questions.keys = MemoryAPIKeyStore([.gemini: "AIzaTestKeyForStubOnly000"])
        store.questions.apiClient = APIClient(configuration: AssistantAPIStub.configuration(hang: true))
        let noteID = try XCTUnwrap(store.currentNote?.id)
        store.askWeb(mode: .askAndSave, content: try content(store), noteID: noteID, provider: .gemini)
        try await wait { !AssistantAPIStub.sent.isEmpty }
        store.cancelQuestion(noteID: noteID)
        try await wait { AssistantAPIStub.stopped }
        XCTAssertEqual(store.questions.jobs.first?.message, "Question cancelled. Its source note is kept.")
        XCTAssertNil(store.currentNote?.pendingRequestID)
    }

    // MARK: Helpers

    @MainActor
    private func fixture() throws -> (StudyStore, URL, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = UserDefaults.standard.object(forKey: "lastWorkspaceID")
        addTeardownBlock { UserDefaults.standard.set(previous, forKey: "lastWorkspaceID"); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.pdf")
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 300, height: 400), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("X transpose X" as NSString).draw(at: CGPoint(x: 30, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0); XCTAssertTrue(document.write(to: source))
        let store = StudyStore(root: root.appendingPathComponent("support")); store.open(source)
        // Tests never run the reader's shell start-up files or touch the Keychain.
        store.questions.loginShellPath = { [] }
        store.questions.keys = MemoryAPIKeyStore()
        store.reader.selection = (0, CGRect(x: 20, y: 35, width: 240, height: 60), "X transpose X"); store.addNote()
        store.updateNote { $0.question = "Why full rank?" }
        return (store, root, source)
    }

    @MainActor
    private func content(_ store: StudyStore) throws -> QuestionContent {
        let note = try XCTUnwrap(store.currentNote), bookID = try XCTUnwrap(store.workspace?.id)
        return QuestionContent(prompt: "Explain $X^\\top X$.", images: [("Source A", try Data(contentsOf: store.repository.assetURL(workspaceID: bookID, name: note.anchor.imageName)))])
    }

    /// A stand-in CLI: answers the status command with `status`, refuses `refuse` like an older version (before reading
    /// its input), and otherwise records its input and arguments and prints a fixed answer.
    private func mockCLI(_ root: URL, provider: QuestionProvider, slow: Bool = false, status: String? = nil, statusCode: Int = 0, refuse: String? = nil) throws -> URL {
        let file = root.appendingPathComponent(provider.executableName!)
        let status = status ?? (provider == .codex ? "Logged in using ChatGPT" : #"{"loggedIn":true,"authMethod":"claude.ai"}"#)
        let response = provider == .codex
            ? #"{"type":"item.completed","item":{"type":"agent_message","text":"Full rank gives uniqueness: $X^\\top X$."}}"# + "\n" + #"{"type":"turn.completed"}"#
            : #"{"type":"result","is_error":false,"result":"Full rank gives uniqueness: $X^\\top X$."}"#
        let refusal = refuse.map { """
        for argument in "$@"; do
          if [ "$argument" = "\($0)" ]; then echo "error: unknown option '\($0)'" >&2; exit 1; fi
        done
        """ } ?? ""
        let script = """
        #!/bin/sh
        if [ "$1" = login ] || [ "$1" = auth ]; then
          printf '%s\\n' '\(status)'
          exit \(statusCode)
        fi
        \(refusal)
        printf '%s\\n' "$@" > received-arguments
        cat > received-input
        \(slow ? "sleep 3" : "sleep 0.1")
        printf '%s\\n' '\(response)'
        """
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    @MainActor
    private func wait(seconds: TimeInterval = 10, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(predicate(), "The question must complete without a browser or terminal window.")
    }
}
