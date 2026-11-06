import AppKit
import LemmaCore
import Observation

@MainActor @Observable
final class QuestionJob: Identifiable {
    let packet: BrowserPacket
    nonisolated let id: UUID
    var provider: QuestionProvider { packet.provider ?? .chatGPTWeb }
    var message = "Preparing the question…"
    var answer = ""
    var model: String?
    var finished = false
    var failed = false
    /// Why the ChatGPT page stopped, when it can say: draft, conversation, signedOut, attach, insert, ready, timeout,
    /// load or crash. The Questions panel offers what fits.
    var failureReason: String?
    /// The reader chose to replace the draft ChatGPT's composer held.
    var replacesDraft = false
    /// The note's question, for the list of questions.
    var title: String
    let startedAt = Date.now
    @ObservationIgnored var process: QuestionProcess?
    @ObservationIgnored var task: Task<Void, Never>?
    init(_ packet: BrowserPacket, title: String = "") {
        self.packet = packet; id = packet.id
        self.title = title.isEmpty ? QuestionJob.question(in: packet.prompt) : title
    }

    /// The question in a prepared draft: the lines after “Question:” up to the next blank line.
    static func question(in prompt: String) -> String {
        guard let range = prompt.range(of: "Question:\n", options: .backwards) else { return String(prompt.prefix(80)) }
        return prompt[range.upperBound...].components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

@MainActor @Observable
final class QuestionRuntime {
    var jobs: [QuestionJob] = []
    var selectedID: UUID?
    var connectionProvider = QuestionProvider.chatGPTWeb { didSet { showsCompanion = false } }
    var panel = "connections"
    /// Connections shows the Chrome companion's setup rather than an assistant.
    var showsCompanion = false
    /// What each CLI reports about its sign-in, or why Lemma could not tell.
    var connections: [QuestionProvider: String] = [:]
    var signIns: [QuestionProvider: CLISignInState] = [:]
    var checking: Set<QuestionProvider> = []
    /// The outcome of Check for each API provider.
    var apiStatus: [QuestionProvider: String] = [:]
    var apiStatusFailed: Set<QuestionProvider> = []
    /// Whether a key is saved, read from the Keychain without reading the key.
    var keyPresence: [QuestionProvider: Bool] = [:]
    var loginMessage = ""
    var loginURL: URL?
    var loginProvider: QuestionProvider?
    var loginCommand: String?
    /// True once the embedded ChatGPT page has been asked to load; the page is never loaded before the reader asks.
    var webLoaded = false
    @ObservationIgnored var loginProcess: QuestionProcess?
    @ObservationIgnored var loginTask: Task<Void, Never>?
    @ObservationIgnored var executableOverrides: [QuestionProvider: URL] = [:]
    @ObservationIgnored var keys: any APIKeyStore = QuestionRuntime.defaultKeyStore()
    @ObservationIgnored var apiClient = APIClient()
    @ObservationIgnored var checkClient = APIClient(configuration: APIClient.configuration(idleTimeout: 20, totalTimeout: 30))
    /// The login shell's PATH; tests replace it so they never run the reader's shell start-up files.
    @ObservationIgnored var loginShellPath: @Sendable () async -> [String] = { await CLIEnvironment.loginShellPath() }
    @ObservationIgnored private var statusCheckedAt: [QuestionProvider: Date] = [:]
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var webSession: ChatGPTSession?
    @ObservationIgnored private var webViewers = 0
    @ObservationIgnored private var webRelease: Task<Void, Never>?
    let root: URL
    init(root: URL) { self.root = root }

    var selected: QuestionJob? { jobs.first { $0.id == selectedID } }
    /// The most recent ChatGPT Web question: the embedded page shows its chat.
    var latestWebJob: QuestionJob? { jobs.first { $0.provider == .chatGPTWeb } }
    var webBusy: Bool { jobs.contains { $0.provider == .chatGPTWeb && !$0.finished } }
    var provider: QuestionProvider {
        QuestionProvider(rawValue: UserDefaults.standard.string(forKey: LemmaPreferences.questionProvider) ?? "") ?? .chatGPTWeb
    }

    /// QA copies of Lemma and tests keep keys in memory and never touch the reader's Keychain.
    static func defaultKeyStore() -> any APIKeyStore {
        let environment = ProcessInfo.processInfo.environment
        let testing = environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        if QAHooks.isAllowed, environment["LEMMA_QA_DIR"] != nil || testing { return MemoryAPIKeyStore() }
        return KeychainAPIKeyStore()
    }

    // MARK: Choices

    func preferredPath(_ provider: QuestionProvider) -> String { UserDefaults.standard.string(forKey: "questions.\(provider.rawValue).path") ?? "" }
    func chosenModel(_ provider: QuestionProvider) -> String {
        (UserDefaults.standard.string(forKey: "questions.\(provider.rawValue).model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The API model: the reader's choice, else the provider's current default.
    func model(for provider: QuestionProvider) -> String { chosenModel(provider).isEmpty ? provider.defaultModel : chosenModel(provider) }

    func resolvedExecutable(_ provider: QuestionProvider) async -> URL? {
        if let override = executableOverrides[provider] { return override }
        let search = CLIEnvironment.searchPath(loginShell: await loginShellPath())
        return QuestionCLI.executable(provider, preferred: preferredPath(provider), searchPath: search)
    }

    private func environment(for executable: URL) async -> [String: String] {
        QuestionCLI.environment(for: executable, searchPath: CLIEnvironment.searchPath(loginShell: await loginShellPath()))
    }

    func notFoundMessage(_ provider: QuestionProvider) -> String {
        let typed = preferredPath(provider).trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? "\(provider.label) was not found. Install it, or choose its executable in Assistants › Connections."
            : "“\(typed)” is not an executable \(provider.label). Choose the installed CLI in Assistants › Connections, or clear the field for automatic discovery."
    }

    // MARK: Questions

    func start(_ packet: BrowserPacket, store: StudyStore, replacingDraft: Bool = false) {
        self.app = store.app
        // The open book is current; the library's copy of it may not have the note yet.
        let question = store.workspace?.notes.first { $0.id == packet.noteID }?.question
            ?? store.library.first { $0.id == packet.workspaceID }?.notes.first { $0.id == packet.noteID }?.question ?? ""
        let job = QuestionJob(packet, title: question); jobs.insert(job, at: 0); selectedID = job.id
        job.replacesDraft = replacingDraft
        panel = "requests"
        connectionProvider = job.provider
        if job.provider == .chatGPTWeb {
            cancelWebRelease(); webLoaded = true
            web.start(job)
            return
        }
        job.task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = job.provider.kind == .api ? try await answerWithAPI(job, store: store) : try await answerWithCLI(job, store: store)
                if let result { finish(job, result: result) }
            } catch {
                guard !job.finished else { return }
                // A declined answer's partial text is discarded, as the providers advise, not left in the panel.
                if case .refused = error as? APIFailure { job.answer = "" }
                finish(job, result: BrowserResult(requestID: job.id, status: "error", message: describe(error, provider: job.provider)))
            }
        }
    }

    /// Runs the reader's CLI. It is unmodified and keeps its own sign-in; Lemma only reads its answer.
    private func answerWithCLI(_ job: QuestionJob, store: StudyStore) async throws -> BrowserResult? {
        let provider = job.provider, packet = job.packet
        guard let executable = await resolvedExecutable(provider) else { throw AssistantFailure(notFoundMessage(provider)) }
        // A CLI that reports no sign-in stops here with a clear message. A status Lemma cannot read does not block
        // the question: the CLI itself then explains any problem.
        if case .signedOut = await signInState(provider, executable: executable, maxAge: 300) {
            throw AssistantFailure("\(provider.label) is not signed in. Sign in from Assistants › Connections or in Terminal; Lemma uses whatever sign-in \(provider.label) has.")
        }
        guard !job.finished, !Task.isCancelled else { return nil }
        let mailbox = store.mailbox
        let directory = mailbox.directory(packet.id)
        let images = packet.images.map { directory.appendingPathComponent($0.name) }
        let data = try QuestionCLI.input(provider: provider, prompt: packet.prompt, images: images.map { try Data(contentsOf: $0) })
        let model = chosenModel(provider)
        let environment = await environment(for: executable)
        var arguments = QuestionCLI.arguments(provider: provider, images: images, model: model)
        job.message = "\(provider.label) is answering… You can keep reading."
        try mailbox.saveResult(BrowserResult(requestID: job.id, status: "sent", message: job.message))
        for _ in 0..<4 {
            let run = try await runCLI(job, executable: executable, arguments: arguments, directory: directory, environment: environment, input: data)
            guard !job.finished, !Task.isCancelled else { return nil }
            if let error = run.parser.error { throw AssistantFailure(error) }
            if run.exitCode == 0, run.parser.completed, !run.parser.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return BrowserResult(requestID: job.id, status: "complete", answer: run.parser.answer, message: "Answer saved beside its source.",
                                     model: run.parser.model ?? (model.isEmpty ? nil : model))
            }
            // An older CLI that does not know one of Lemma's hardening options is asked again without it.
            if run.parser.answer.isEmpty, let flag = QuestionCLI.rejectedOption(in: run.diagnostics), let reduced = QuestionCLI.dropping(flag, from: arguments) {
                arguments = reduced
                continue
            }
            let command = provider == .codex ? "codex exec" : "claude --print"
            if run.diagnostics.isEmpty {
                throw AssistantFailure(run.inputClosed ? "\(provider.label) stopped reading the question (exit code \(run.exitCode)). Try again from the note."
                                       : "\(provider.label) stopped before returning a complete answer (exit code \(run.exitCode)). Try again from the note.")
            }
            throw AssistantFailure(QuestionCLI.failureDescription(command: command, exitCode: run.exitCode, output: "", errors: run.diagnostics))
        }
        throw AssistantFailure("\(provider.label) refused Lemma's options. Update \(provider.label), then ask again.")
    }

    private struct CLIRun {
        var parser = QuestionEventParser()
        var exitCode: Int32 = -1
        var diagnostics = ""
        var inputClosed = false
    }

    private func runCLI(_ job: QuestionJob, executable: URL, arguments: [String], directory: URL, environment: [String: String], input: Data) async throws -> CLIRun {
        let process = QuestionProcess(); job.process = process
        let stream = try process.start(executable: executable, arguments: arguments, directory: directory, environment: environment, input: input)
        var run = CLIRun(), buffer = Data(), diagnostics = Data()
        for await event in stream {
            guard !job.finished else { break }
            switch event {
            case .output(let bytes):
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    run.parser.consume(Data(buffer[..<newline]), provider: job.provider)
                    buffer.removeSubrange(...newline)
                }
                job.answer = run.parser.answer; job.model = run.parser.model
            case .diagnostic(let bytes):
                diagnostics.append(bytes)
                if diagnostics.count > 12000 { diagnostics = diagnostics.suffix(12000) }
            case .inputClosed: run.inputClosed = true
            case .exited(let code): run.exitCode = code
            }
        }
        if !buffer.isEmpty { run.parser.consume(buffer, provider: job.provider) }
        run.diagnostics = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return run
    }

    /// Sends the question straight to the provider's API with the reader's key, streaming the answer into the panel.
    private func answerWithAPI(_ job: QuestionJob, store: StudyStore) async throws -> BrowserResult? {
        let provider = job.provider, packet = job.packet
        guard let key = try keys.key(for: provider), !key.isEmpty else { throw APIFailure.missingKey }
        let model = model(for: provider)
        let directory = store.mailbox.directory(packet.id)
        let images = try packet.images.map { APIImage(label: $0.label, png: try Data(contentsOf: directory.appendingPathComponent($0.name))) }
        job.message = "\(provider.label) is answering… You can keep reading."
        try store.mailbox.saveResult(BrowserResult(requestID: job.id, status: "sent", message: job.message))
        var fallbacks = true
        while true {
            let request = try APIRequestBuilder.answer(provider, key: key, model: model, prompt: packet.prompt, images: images, serverFallbacks: fallbacks)
            var parser = APIAnswerParser(provider: provider)
            var shown = Date.distantPast
            do {
                for try await event in apiClient.events(request, provider: provider) {
                    guard !job.finished else { return nil }
                    parser.consume(event)
                    // The panel redraws a few times a second rather than for every token.
                    if Date().timeIntervalSince(shown) > 0.15 { job.answer = parser.answer; job.model = parser.model; shown = .now }
                }
            } catch let failure as APIFailure where provider == .anthropic && fallbacks && failure.rejectsServerFallbacks {
                fallbacks = false
                continue
            }
            guard !job.finished, !Task.isCancelled else { return nil }
            job.answer = parser.answer; job.model = parser.model
            let result = try parser.result()
            let answer = result.truncated ? result.answer + "\n\n*The answer reached \(provider.company)'s output limit and may be incomplete.*" : result.answer
            return BrowserResult(requestID: job.id, status: "complete", answer: answer,
                                 message: result.truncated ? "Saved; the answer reached the output limit and may be incomplete." : "Answer saved beside its source.",
                                 model: result.model ?? model)
        }
    }

    func describe(_ error: Error, provider: QuestionProvider, model: String? = nil) -> String {
        if let failure = error as? APIFailure { return failure.message(provider, model: model ?? self.model(for: provider)) }
        return APIKeyFormat.redacted(error.localizedDescription)
    }

    func finish(_ job: QuestionJob, result: BrowserResult) {
        guard !job.finished else { return }
        var result = result
        result.message = result.message.map { APIKeyFormat.redacted($0) }
        // Questions belong to the shared app, not the last window that asked one. That window may have closed
        // while another window's answer was still streaming.
        let store = job.packet.workspaceID.flatMap { app?.owner(of: $0) } ?? app?.front
        do {
            try app?.mailbox.saveResult(result)
            job.answer = result.answer ?? job.answer; job.model = result.model ?? job.model
            job.message = result.message ?? result.status; job.failed = result.status == "error"; job.finished = true
            job.process = nil
            store?.pollBrowser()
        } catch { job.message = "Could not save the answer: \(error.localizedDescription)"; store?.error = job.message }
        if job.provider == .chatGPTWeb { scheduleWebRelease() }
    }

    /// Asks a finished question again, as a new request with the same draft and images, to the same note.
    func retry(_ job: QuestionJob, replacingDraft: Bool = false) {
        guard job.finished, let app else { return }
        let store = job.packet.workspaceID.flatMap { app.owner(of: $0) } ?? app.front
        store.askAgain(job.packet, replacingDraft: replacingDraft)
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.finished else { return }
        job.process?.cancel(); job.task?.cancel()
        if job.provider == .chatGPTWeb { webSession?.cancel(id) }
        job.failureReason = "cancelled"
        finish(job, result: BrowserResult(requestID: id, status: "error", message: "Question cancelled. Its source note is kept."))
    }

    // MARK: CLI sign-in

    func check(_ provider: QuestionProvider) async {
        guard provider.kind == .cli, !checking.contains(provider) else { return }
        checking.insert(provider); defer { checking.remove(provider) }
        guard let executable = await resolvedExecutable(provider) else {
            signIns[provider] = nil; connections[provider] = notFoundMessage(provider); return
        }
        await signInState(provider, executable: executable)
    }

    /// Asks the CLI how it is signed in. Any account type counts. `maxAge` reuses a recent “signed in” before a
    /// question; any other answer is asked again, since the reader may have just signed in from Terminal.
    @discardableResult
    func signInState(_ provider: QuestionProvider, executable: URL, maxAge: TimeInterval = 0) async -> CLISignInState {
        if maxAge > 0, let checked = statusCheckedAt[provider], Date().timeIntervalSince(checked) < maxAge,
           let state = signIns[provider], case .signedIn = state { return state }
        let state: CLISignInState
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let environment = await environment(for: executable)
            var arguments = QuestionCLI.statusArguments(provider)
            var run = try await QuestionProcess.capture(executable: executable, arguments: arguments, directory: root, environment: environment)
            // Current Claude Code prints JSON by default; an older version may not know `--json`.
            if run.code != 0, QuestionCLI.rejectedOption(in: run.errors + "\n" + run.output) == "--json" {
                arguments.removeAll { $0 == "--json" }
                run = try await QuestionProcess.capture(executable: executable, arguments: arguments, directory: root, environment: environment)
            }
            state = QuestionCLI.signInState(provider, exitCode: run.code, output: run.output, errors: run.errors)
        } catch {
            state = .unknown("Lemma could not start \(executable.path): \(error.localizedDescription)")
        }
        signIns[provider] = state; statusCheckedAt[provider] = .now
        switch state {
        case .signedIn(let method): connections[provider] = "Signed in · \(method)"
        case .signedOut: connections[provider] = "Not signed in. Sign in below, or set up \(provider.label) in Terminal."
        case .unknown(let detail): connections[provider] = detail
        }
        return state
    }

    /// Starts the CLI's own sign-in. The CLI opens the provider's page in the reader's default browser, where
    /// sign-in completes; Lemma shows the CLI's output, offers to reopen that page and passes on a pasted code.
    /// It never sees a password, and the CLI stores its own credentials.
    func signIn(_ provider: QuestionProvider, method: CLISignInMethod) {
        endLogin()
        loginProvider = provider; loginMessage = "Starting sign-in…"; loginCommand = method.terminal
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let executable = await resolvedExecutable(provider) else { loginMessage = notFoundMessage(provider); return }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let environment = await environment(for: executable)
                guard loginProvider == provider, !Task.isCancelled else { return }
                let process = QuestionProcess(); loginProcess = process
                let stream = try process.start(executable: executable, arguments: method.arguments, directory: root, environment: environment)
                var text = ""
                for await event in stream {
                    guard loginProvider == provider, !Task.isCancelled else { return }
                    switch event {
                    case .output(let data), .diagnostic(let data):
                        text += String(decoding: data, as: UTF8.self)
                        let readable = Self.withoutTerminalCodes(text)
                        loginMessage = String(readable.suffix(2400))
                        if loginURL == nil { loginURL = Self.authorizationURL(in: readable) }
                    case .inputClosed: break
                    case .exited(let code):
                        loginProcess = nil
                        if code == 0 {
                            loginMessage = "Sign-in complete."; loginURL = nil; loginProvider = nil; loginCommand = nil
                            statusCheckedAt[provider] = nil
                            await check(provider)
                        } else {
                            loginMessage = String(Self.withoutTerminalCodes(text).suffix(1600)) + "\n\nSign-in did not finish (exit code \(code)). Try again, or run “\(method.terminal)” in Terminal."
                        }
                    }
                }
            } catch {
                loginMessage = "Could not start sign-in: \(error.localizedDescription)"; loginProcess = nil
            }
        }
    }

    func openLoginPage() { if let loginURL { NSWorkspace.shared.open(loginURL) } }

    func endLogin() {
        loginProcess?.cancel(); loginTask?.cancel(); loginProcess = nil; loginTask = nil
        loginProvider = nil; loginURL = nil; loginMessage = ""; loginCommand = nil
    }

    /// The first web address in a CLI's sign-in output.
    static func authorizationURL(in text: String) -> URL? {
        guard let range = text.range(of: "https://[^\\s\"'<>]+", options: .regularExpression) else { return nil }
        var value = String(text[range])
        while let last = value.last, ".,;:)]".contains(last) { value.removeLast() }
        return URL(string: value)
    }

    /// Output without terminal colour and cursor codes, which some CLIs print even through a pipe.
    static func withoutTerminalCodes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    // MARK: API keys

    func refreshKeys() {
        for provider in QuestionProvider.allCases where provider.kind == .api { keyPresence[provider] = keys.hasKey(for: provider) }
    }

    func saveKey(_ key: String, for provider: QuestionProvider) throws {
        try keys.save(key, for: provider)
        keyPresence[provider] = true
        apiStatus[provider] = "Saved in your Keychain. Check sends one request to confirm it."; apiStatusFailed.remove(provider)
    }

    func removeKey(for provider: QuestionProvider) throws {
        try keys.remove(for: provider)
        keyPresence[provider] = false
        apiStatus[provider] = "Removed from your Keychain."; apiStatusFailed.remove(provider)
    }

    /// Check: one request that needs the key and the model but generates nothing. Only ever run when the reader clicks Check.
    func checkKey(_ provider: QuestionProvider) async {
        guard provider.kind == .api, !checking.contains(provider) else { return }
        checking.insert(provider); defer { checking.remove(provider) }
        let model = model(for: provider)
        do {
            guard let key = try keys.key(for: provider), !key.isEmpty else { throw APIFailure.missingKey }
            try await checkClient.check(APIRequestBuilder.check(provider, key: key, model: model), provider: provider)
            apiStatus[provider] = "The key works, and \(model) is available."; apiStatusFailed.remove(provider)
        } catch {
            apiStatus[provider] = describe(error, provider: provider, model: model); apiStatusFailed.insert(provider)
        }
    }

    // MARK: ChatGPT Web

    /// The embedded page is created on first use and released after a quiet period, so an idle WebKit process does
    /// not keep using memory and CPU.
    var web: ChatGPTSession {
        if let webSession { return webSession }
        let session = ChatGPTSession(runtime: self)
        webSession = session
        return session
    }
    var hasWebSession: Bool { webSession != nil }

    func connectWeb() { cancelWebRelease(); web.connect(); webLoaded = true }

    func closeWeb() {
        guard !webBusy else { return }
        cancelWebRelease()
        webSession?.release(); webSession = nil; webLoaded = false
    }

    func webViewAppeared() { webViewers += 1; cancelWebRelease() }
    func webViewDisappeared() { webViewers = max(0, webViewers - 1); scheduleWebRelease() }

    func scheduleWebRelease(after delay: Duration = .seconds(90)) {
        webRelease?.cancel()
        guard webSession != nil else { return }
        webRelease = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !webBusy, webViewers == 0 else { return }
            closeWeb()
        }
    }

    private func cancelWebRelease() { webRelease?.cancel(); webRelease = nil }

    func showConversation(_ url: URL) {
        guard !webBusy else { return }
        cancelWebRelease()
        web.openConversation(url); webLoaded = true
        connectionProvider = .chatGPTWeb; panel = "connections"
    }

    func shutdown() {
        for job in jobs where !job.finished { cancel(job.id) }
        endLogin()
        cancelWebRelease()
    }
}

struct AssistantFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
