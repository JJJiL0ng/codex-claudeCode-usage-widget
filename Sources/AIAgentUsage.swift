import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt
import ServiceManagement

struct UsageWindow {
    let usedPercent: Double
    let durationMinutes: Int
    let resetsAt: Date?
}

struct UsageSnapshot {
    let primary: UsageWindow
    let secondary: UsageWindow?
    let plan: String?
}

enum Agent: CaseIterable {
    case claude
    case codex

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var logoResource: String {
        switch self {
        case .claude: return "ClaudeLogoTemplate"
        case .codex: return "OpenAILogoTemplate"
        }
    }

    func fetchSync() -> Result<UsageSnapshot, Error> {
        switch self {
        case .claude: return ClaudeUsageFetcher.fetchSync()
        case .codex: return CodexUsageFetcher.fetchSync()
        }
    }

    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(fetchSync())
        }
    }
}

private func remainingPercent(_ window: UsageWindow) -> Int {
    Int(max(0, min(100, 100 - window.usedPercent)).rounded())
}

enum UsageError: LocalizedError {
    case codexNotFound
    case claudeNotLoggedIn
    case claudeTokenExpired
    case rateLimited(until: Date)
    case timedOut
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex 실행 파일을 찾지 못했습니다"
        case .claudeNotLoggedIn:
            return "Claude Code 로그인 정보를 찾지 못했습니다"
        case .claudeTokenExpired:
            return "Claude 토큰이 만료됐습니다 (Claude Code를 실행하면 갱신됩니다)"
        case .rateLimited(let until):
            return "조회 제한 중, \(AppDelegate.timeFormatter.string(from: until)) 이후 재시도"
        case .timedOut:
            return "사용량 조회 시간이 초과됐습니다"
        case .invalidResponse:
            return "응답 형식이 올바르지 않습니다"
        case .server(let message):
            return message
        }
    }
}

enum ClaudeUsageFetcher {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let stateLock = NSLock()
    private static var blockedUntil: Date?

    static func fetchSync(timeout: TimeInterval = 20) -> Result<UsageSnapshot, Error> {
        // The usage endpoint answers 429 with Retry-After when polled too often; calling again extends the block.
        stateLock.lock()
        let blocked = blockedUntil.flatMap { $0 > Date() ? $0 : nil }
        stateLock.unlock()
        if let blocked { return .failure(UsageError.rateLimited(until: blocked)) }

        guard let credentials = readCredentials() else { return .failure(UsageError.claudeNotLoggedIn) }

        var request = URLRequest(url: usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<UsageSnapshot, Error> = .failure(UsageError.invalidResponse)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure((error as? URLError)?.code == .timedOut ? UsageError.timedOut : error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                let seconds = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 900
                let until = Date().addingTimeInterval(seconds + 5)
                stateLock.lock()
                blockedUntil = until
                stateLock.unlock()
                result = .failure(UsageError.rateLimited(until: until))
            } else if status == 401 {
                result = .failure(UsageError.claudeTokenExpired)
            } else if status != 200 {
                result = .failure(UsageError.server("Claude 사용량 조회 실패 (HTTP \(status))"))
            } else if let data, let snapshot = parseSnapshot(data, plan: credentials.plan) {
                result = .success(snapshot)
            }
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return .failure(UsageError.timedOut)
        }
        return result
    }

    static func parseSnapshot(_ data: Data, plan: String?) -> UsageSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let primary = parseWindow(object["five_hour"], durationMinutes: 300)
        else { return nil }

        return UsageSnapshot(
            primary: primary,
            secondary: parseWindow(object["seven_day"], durationMinutes: 10_080),
            plan: plan
        )
    }

    private static func parseWindow(_ value: Any?, durationMinutes: Int) -> UsageWindow? {
        guard
            let object = value as? [String: Any],
            let used = object["utilization"] as? NSNumber
        else { return nil }

        return UsageWindow(
            usedPercent: used.doubleValue,
            durationMinutes: durationMinutes,
            resetsAt: (object["resets_at"] as? String).flatMap(parseDate)
        )
    }

    static func parseDate(_ string: String) -> Date? {
        // resets_at uses microsecond precision, which ISO8601DateFormatter does not accept.
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static func readCredentials() -> (accessToken: String, plan: String?)? {
        let data = readKeychain() ?? FileManager.default.contents(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json").path
        )
        guard
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return nil }
        return (token, oauth["subscriptionType"] as? String)
    }

    private static func readKeychain() -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }
}

enum CodexUsageFetcher {
    static func fetchSync(timeout: TimeInterval = 20) -> Result<UsageSnapshot, Error> {
        guard let codexPath = findCodex() else { return .failure(UsageError.codexNotFound) }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let stateQueue = DispatchQueue(label: "dev.jihong.ai-agent-usage.codex-response")
        let semaphore = DispatchSemaphore(value: 0)
        var buffer = Data()
        var result: Result<UsageSnapshot, Error>?
        var finished = false

        func finish(_ value: Result<UsageSnapshot, Error>) {
            guard !finished else { return }
            finished = true
            result = value
            semaphore.signal()
        }

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            stateQueue.async {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard
                        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        (object["id"] as? NSNumber)?.intValue == 1
                    else { continue }

                    if let error = object["error"] as? [String: Any] {
                        finish(.failure(UsageError.server(error["message"] as? String ?? "Codex 사용량 조회 실패")))
                    } else if let snapshot = parseSnapshot(object) {
                        finish(.success(snapshot))
                    } else {
                        finish(.failure(UsageError.invalidResponse))
                    }
                }
            }
        }

        do {
            try process.run()
            let messages = [
                ["method": "initialize", "id": 0, "params": ["clientInfo": ["name": "ai_agent_usage", "title": "AI Agent Usage", "version": "1.0.0"]]],
                ["method": "initialized", "params": [:]],
                ["method": "account/rateLimits/read", "id": 1, "params": [:]]
            ] as [[String: Any]]

            for message in messages {
                let data = try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
                try input.fileHandleForWriting.write(contentsOf: data)
            }
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            return .failure(error)
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        if waitResult == .timedOut { return .failure(UsageError.timedOut) }
        return stateQueue.sync { result ?? .failure(UsageError.invalidResponse) }
    }

    private static func parseSnapshot(_ object: [String: Any]) -> UsageSnapshot? {
        guard let result = object["result"] as? [String: Any] else { return nil }
        let fallback = result["rateLimits"] as? [String: Any]
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let codex = (buckets?["codex"] as? [String: Any])
            ?? buckets?.values.compactMap { $0 as? [String: Any] }.first
            ?? fallback
        guard let limit = codex, let primary = parseWindow(limit["primary"]) else { return nil }

        return UsageSnapshot(
            primary: primary,
            secondary: parseWindow(limit["secondary"]),
            plan: limit["planType"] as? String
        )
    }

    private static func parseWindow(_ value: Any?) -> UsageWindow? {
        guard
            let object = value as? [String: Any],
            let used = object["usedPercent"] as? NSNumber,
            let duration = object["windowDurationMins"] as? NSNumber,
            let reset = object["resetsAt"] as? NSNumber
        else { return nil }

        return UsageWindow(
            usedPercent: used.doubleValue,
            durationMinutes: duration.intValue,
            resetsAt: Date(timeIntervalSince1970: reset.doubleValue)
        )
    }

    static func findCodex() -> String? {
        findExecutable("codex", preferred: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ])
    }
}

func findExecutable(_ name: String, preferred: [String] = []) -> String? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    var candidates = preferred + [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        home.appendingPathComponent(".local/bin/\(name)").path
    ]

    if let path = ProcessInfo.processInfo.environment["PATH"] {
        candidates += path.split(separator: ":").map { "\($0)/\(name)" }
    }

    let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
    if let versions = try? fileManager.contentsOfDirectory(atPath: nvmRoot.path) {
        candidates += versions.sorted().reversed().map {
            nvmRoot.appendingPathComponent($0).appendingPathComponent("bin/\(name)").path
        }
    }

    return candidates.first { fileManager.isExecutableFile(atPath: $0) }
}

struct ProcessOutput {
    let status: Int32
    let output: String
}

enum ProcessRunner {
    static func run(_ path: String, _ arguments: [String], directory: URL? = nil, timeout: TimeInterval) -> ProcessOutput? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        // Apps launched from Finder get a minimal PATH; node-based CLIs need their own bin dir to find `node`.
        var environment = ProcessInfo.processInfo.environment
        let searchPath = [(path as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (searchPath + [environment["PATH"]].compactMap { $0 }).joined(separator: ":")
        // Claude Code looks up its keychain entry by $USER.
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        // When the app is launched from inside a Claude Code session it inherits that session's variables
        // (CLAUDECODE, CLAUDE_CODE_CHILD_SESSION, its messaging socket…), which makes `claude -p` run as a
        // child of that session. API keys would also bill the kickoff to the API instead of the subscription.
        for key in environment.keys where key.hasPrefix("CLAUDE") && key != "CLAUDE_CONFIG_DIR" {
            environment[key] = nil
        }
        ["AI_AGENT", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "MCP_CONNECTION_NONBLOCKING"].forEach {
            environment[$0] = nil
        }
        process.environment = environment

        let lock = NSLock()
        var data = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let text = String(decoding: data, as: UTF8.self)
        lock.unlock()
        return ProcessOutput(status: timedOut ? -1 : process.terminationStatus, output: timedOut ? "시간 초과" : text)
    }
}

/// Sends the smallest possible request so a fresh 5-hour window starts counting right after a reset.
enum KickoffRunner {
    private static let prompt = "Reply with OK only."

    static func model(for agent: Agent) -> String {
        switch agent {
        case .claude: return UserDefaults.standard.string(forKey: "claudeKickoffModel") ?? "haiku"
        case .codex: return UserDefaults.standard.string(forKey: "codexKickoffModel") ?? "gpt-6-luna"
        }
    }

    static func ping(_ agent: Agent) -> Result<Void, Error> {
        let path: String?
        let arguments: [String]
        switch agent {
        case .claude:
            path = findExecutable("claude", preferred: [
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/claude").path
            ])
            arguments = [
                "-p", prompt, "--model", model(for: agent), "--tools", "",
                "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config"
            ]
        case .codex:
            path = CodexUsageFetcher.findCodex()
            arguments = [
                "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "-s", "read-only",
                "-m", model(for: agent), "-c", "model_reasoning_effort=\"low\"", prompt
            ]
        }

        guard let path else {
            return .failure(agent == .codex ? UsageError.codexNotFound : UsageError.server("Claude Code 실행 파일을 찾지 못했습니다"))
        }
        guard let result = ProcessRunner.run(path, arguments, directory: workingDirectory(), timeout: 120) else {
            log(agent, path: path, status: nil, output: "process failed to launch")
            return .failure(UsageError.server("\(agent.name) 실행 실패"))
        }
        log(agent, path: path, status: result.status, output: result.output)
        if result.status == 0 { return .success(()) }

        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let message = lines.last { $0.hasPrefix("ERROR:") } ?? lines.last ?? "종료 코드 \(result.status)"
        return .failure(UsageError.server(String(message.prefix(160))))
    }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AI Agent Usage/kickoff.log")

    /// Appends every kickoff result so failures can be diagnosed after the fact.
    private static func log(_ agent: Agent, path: String, status: Int32?, output: String) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(30).joined(separator: "\n")
        let entry = "[\(formatter.string(from: Date()))] \(agent.name) model=\(model(for: agent)) exit=\(status.map(String.init) ?? "-") bin=\(path)\n\(tail)\n\n"

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
            try? fileManager.removeItem(at: logURL)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: logURL)
        }
    }

    private static func workingDirectory() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Agent Usage/kickoff", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func needsKickoff(_ window: UsageWindow, now: Date = Date()) -> Bool {
        if let reset = window.resetsAt, reset <= now { return true }
        return window.usedPercent == 0
    }
}

enum PowerManager {
    static let wakeOwner = "AIAgentUsage"

    /// Requires a passwordless sudo rule for `/usr/bin/pmset schedule wake *`; fails quietly otherwise.
    static func scheduleWake(at date: Date) -> Bool {
        let arguments = ["-n", "/usr/bin/pmset", "schedule", "wake", pmsetFormatter.string(from: date), wakeOwner]
        return ProcessRunner.run("/usr/bin/sudo", arguments, timeout: 10)?.status == 0
    }

    static func sleepNow() {
        _ = ProcessRunner.run("/usr/bin/pmset", ["sleepnow"], timeout: 10)
    }

    static func preventIdleSleep() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AI Agent Usage 자동 시작" as CFString,
            &id
        )
        return status == kIOReturnSuccess ? id : nil
    }

    static func allowIdleSleep(_ id: IOPMAssertionID?) {
        if let id { IOPMAssertionRelease(id) }
    }

    /// Seconds since the last keyboard/mouse/trackpad input.
    static func idleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        else { return nil }
        return value.doubleValue / 1_000_000_000
    }

    static let pmsetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter
    }()
}

final class AgentSection {
    let agent: Agent
    let headerItem: NSMenuItem
    let primaryItem = NSMenuItem(title: "불러오는 중…", action: nil, keyEquivalent: "")
    let secondaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let kickoffItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let logo: NSImage?
    var snapshot: UsageSnapshot?
    var failed = false
    var refreshing = false
    var waiters: [() -> Void] = []
    var resetTimer: DispatchSourceTimer?
    var retryTimer: DispatchSourceTimer?
    var kickoffFailures = 0

    init(agent: Agent) {
        self.agent = agent
        headerItem = NSMenuItem(title: agent.name, action: nil, keyEquivalent: "")
        if let url = Bundle.main.url(forResource: agent.logoResource, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            logo = image
            let menuImage = image.copy() as! NSImage
            menuImage.size = NSSize(width: 14, height: 14)
            headerItem.image = menuImage
        } else {
            logo = nil
        }
        items.forEach { $0.isEnabled = false }
        [secondaryItem, kickoffItem, errorItem].forEach { $0.isHidden = true }
    }

    var items: [NSMenuItem] { [headerItem, primaryItem, secondaryItem, kickoffItem, errorItem] }

    var statusText: String {
        guard let snapshot else { return failed ? "—" : "…" }
        return "\(remainingPercent(snapshot.primary))%"
    }

    var attemptKey: String { "kickoff.\(agent).attempt" }
    var untilKey: String { "kickoff.\(agent).until" }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sections = Agent.allCases.map(AgentSection.init)
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let intervalMenu = NSMenu()
    private let agentsMenu = NSMenu()
    private let menu = NSMenu()
    private let kickoffMenu = NSMenu()
    private let wakeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 실행", action: #selector(toggleLogin), keyEquivalent: "")
    private let loginErrorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var timer: DispatchSourceTimer?

    private var refreshSeconds: Int {
        let saved = defaults.integer(forKey: "refreshSeconds")
        return saved > 0 ? saved : 900
    }

    /// Whether the user chose auto kickoff for this agent, regardless of whether the agent is tracked.
    private func kickoffChosen(_ agent: Agent) -> Bool { defaults.bool(forKey: "autoKickoff.\(agent)") }

    private func kickoffEnabled(_ agent: Agent) -> Bool { isEnabled(agent) && kickoffChosen(agent) }

    private var anyKickoff: Bool { Agent.allCases.contains(where: kickoffEnabled) }

    private func isEnabled(_ agent: Agent) -> Bool { defaults.bool(forKey: "enabled.\(agent)") }

    private var enabledSections: [AgentSection] { sections.filter { isEnabled($0.agent) } }

    /// Menu choices for which agents to track; the tag is the index into this list.
    private static let agentModes: [(title: String, agents: [Agent])] = [
        ("Claude Code + Codex", [.claude, .codex]),
        ("Claude Code만", [.claude]),
        ("Codex만", [.codex]),
        ("모두 끄기", [])
    ]

    private var scheduledWakes: [Date] {
        get { (defaults.array(forKey: "scheduledWakes") as? [Double] ?? []).map(Date.init(timeIntervalSince1970:)) }
        set { defaults.set(newValue.map(\.timeIntervalSince1970), forKey: "scheduledWakes") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // `autoKickoff` was the single switch before kickoff became per agent.
        let legacyKickoff = defaults.object(forKey: "autoKickoff") as? Bool ?? true
        defaults.register(defaults: [
            "enabled.claude": true,
            "enabled.codex": true,
            "autoKickoff.claude": legacyKickoff,
            "autoKickoff.codex": legacyKickoff
        ])
        configureMenu()
        scheduleTimer()
        refreshAll()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func configureMenu() {
        statusItem.button?.imagePosition = .imageOnly
        renderStatus()

        [updatedItem, wakeItem, loginErrorItem].forEach {
            $0.isEnabled = false
            $0.isHidden = true
        }

        for (index, mode) in Self.agentModes.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(changeAgents(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            agentsMenu.addItem(item)

            let kickoffItem = NSMenuItem(title: mode.title, action: #selector(changeKickoff(_:)), keyEquivalent: "")
            kickoffItem.target = self
            kickoffItem.tag = index
            kickoffMenu.addItem(kickoffItem)
        }

        for minutes in [1, 5, 15, 30, 60] {
            let item = NSMenuItem(title: "\(minutes)분", action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes * 60
            intervalMenu.addItem(item)
        }

        loginItem.target = self
        statusItem.menu = menu
        buildMenu()
    }

    /// Rebuilds the menu so only enabled agents get a section.
    private func buildMenu() {
        menu.removeAllItems()
        for section in enabledSections {
            section.items.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        if enabledSections.isEmpty {
            let empty = NSMenuItem(title: "추적 중인 에이전트 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            menu.addItem(.separator())
        }
        menu.addItem(updatedItem)
        menu.addItem(withTitle: "지금 새로고침", action: #selector(refreshNow), keyEquivalent: "r").target = self

        let agentsItem = NSMenuItem(title: "에이전트", action: nil, keyEquivalent: "")
        agentsItem.submenu = agentsMenu
        menu.addItem(agentsItem)
        let intervalItem = NSMenuItem(title: "갱신 간격", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let kickoffItem = NSMenuItem(title: "초기화 직후 자동 시작", action: nil, keyEquivalent: "")
        kickoffItem.submenu = kickoffMenu
        menu.addItem(kickoffItem)
        menu.addItem(wakeItem)
        menu.addItem(loginItem)
        menu.addItem(loginErrorItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        updateChecks()
    }

    private func scheduleTimer() {
        timer?.cancel()
        let seconds = refreshSeconds
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + .seconds(seconds),
            repeating: .seconds(seconds),
            leeway: .seconds(min(60, max(5, seconds / 10)))
        )
        source.setEventHandler { [weak self] in self?.refreshAll() }
        source.resume()
        timer = source
        updateChecks()
    }

    private func refreshAll(attempts: Int = 1, completion: @escaping () -> Void = {}) {
        let group = DispatchGroup()
        for section in enabledSections {
            group.enter()
            refresh(section, attempts: attempts) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    /// Fetches usage, kicks off a fresh window when needed, then calls every waiter.
    private func refresh(_ section: AgentSection, attempts: Int, completion: @escaping () -> Void) {
        guard isEnabled(section.agent) else { completion(); return }
        section.waiters.append(completion)
        guard !section.refreshing else { return }
        section.refreshing = true
        fetch(section, attemptsLeft: attempts)
    }

    private func fetch(_ section: AgentSection, attemptsLeft: Int) {
        section.agent.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure = result, attemptsLeft > 1 {
                    // Right after wake the network may not be up yet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.fetch(section, attemptsLeft: attemptsLeft - 1)
                    }
                    return
                }
                self.apply(result, to: section)
                self.kickoffIfNeeded(section) { self.finishRefresh(section) }
            }
        }
    }

    private func finishRefresh(_ section: AgentSection) {
        section.refreshing = false
        let waiters = section.waiters
        section.waiters = []
        renderStatus()
        waiters.forEach { $0() }
    }

    private func apply(_ result: Result<UsageSnapshot, Error>, to section: AgentSection) {
        switch result {
        case .success(let snapshot):
            section.snapshot = snapshot
            section.failed = false
            section.errorItem.isHidden = true
            render(section)
        case .failure(let error):
            section.failed = true
            if section.snapshot == nil { section.primaryItem.title = "사용량 없음" }
            section.errorItem.title = "오류: \(error.localizedDescription)"
            if case UsageError.rateLimited(let until) = error { scheduleRetry(section, at: until) }
            section.errorItem.isHidden = false
        }
        renderStatus()
    }

    private func kickoffIfNeeded(_ section: AgentSection, done: @escaping () -> Void) {
        let now = Date()
        let lastAttempt = defaults.object(forKey: section.attemptKey) as? Date
        let suppressedUntil = defaults.object(forKey: section.untilKey) as? Date
        if let window = section.snapshot?.primary, !KickoffRunner.needsKickoff(window, now: now) {
            section.kickoffFailures = 0
        }
        guard
            kickoffEnabled(section.agent),
            let window = section.snapshot?.primary,
            KickoffRunner.needsKickoff(window, now: now),
            lastAttempt.map({ now.timeIntervalSince($0) >= 110 }) ?? true,
            suppressedUntil.map({ now >= $0 }) ?? true
        else { done(); return }

        defaults.set(now, forKey: section.attemptKey)
        section.kickoffItem.title = "자동 시작: 핑 보내는 중… (\(KickoffRunner.model(for: section.agent)))"
        section.kickoffItem.isHidden = false

        DispatchQueue.global(qos: .utility).async {
            let ping = KickoffRunner.ping(section.agent)
            let after: Result<UsageSnapshot, Error>? = (try? ping.get()).map { section.agent.fetchSync() }

            DispatchQueue.main.async {
                switch ping {
                case .success:
                    let reset = (try? after?.get())?.primary.resetsAt
                    let until = reset.flatMap { $0 > now ? $0 : nil }
                        ?? now.addingTimeInterval(TimeInterval(window.durationMinutes * 60 - 900))
                    self.defaults.set(until, forKey: section.untilKey)
                    section.kickoffFailures = 0
                    section.kickoffItem.title = "자동 시작: \(Self.timeFormatter.string(from: now)) 핑 완료"
                    if let after { self.apply(after, to: section) }
                case .failure(let error):
                    section.kickoffFailures += 1
                    let retry = section.kickoffFailures < 3
                    section.kickoffItem.title = "자동 시작 실패\(retry ? " (2분 뒤 재시도)" : ""): \(error.localizedDescription)"
                    if retry { self.scheduleRetry(section, at: Date().addingTimeInterval(120)) }
                }
                done()
            }
        }
    }

    private func render(_ section: AgentSection) {
        guard let snapshot = section.snapshot else { return }
        section.headerItem.title = snapshot.plan.map { "\(section.agent.name) · \($0.capitalized)" } ?? section.agent.name
        section.primaryItem.title = describe(snapshot.primary)
        section.secondaryItem.title = snapshot.secondary.map(describe) ?? ""
        section.secondaryItem.isHidden = snapshot.secondary == nil
        updatedItem.title = "업데이트 \(Self.timeFormatter.string(from: Date()))"
        updatedItem.isHidden = false
        scheduleReset(section, at: snapshot.primary.resetsAt)
    }

    /// Refreshes right after the 5-hour window resets, and schedules a wake in case the Mac is asleep then.
    private func scheduleReset(_ section: AgentSection, at reset: Date?) {
        section.resetTimer?.cancel()
        section.resetTimer = nil
        guard kickoffEnabled(section.agent), let reset, reset > Date() else { return }

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + reset.timeIntervalSinceNow + 15, leeway: .seconds(5))
        source.setEventHandler { [weak self, weak section] in
            guard let self, let section else { return }
            self.refresh(section, attempts: 3) {}
        }
        source.resume()
        section.resetTimer = source
        scheduleWake(at: reset.addingTimeInterval(20))
    }

    private func scheduleRetry(_ section: AgentSection, at date: Date) {
        section.retryTimer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + max(1, date.timeIntervalSinceNow + 1), leeway: .seconds(5))
        source.setEventHandler { [weak self, weak section] in
            guard let self, let section else { return }
            section.retryTimer = nil
            self.refresh(section, attempts: 3) {}
        }
        source.resume()
        section.retryTimer = source
    }

    private func scheduleWake(at date: Date) {
        let now = Date()
        var wakes = scheduledWakes.filter { $0 > now.addingTimeInterval(-600) }
        scheduledWakes = wakes
        guard !wakes.contains(where: { abs($0.timeIntervalSince(date)) < 60 }) else {
            renderWakeItem()
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let scheduled = PowerManager.scheduleWake(at: date)
            DispatchQueue.main.async {
                if scheduled {
                    wakes = self.scheduledWakes
                    wakes.append(date)
                    self.scheduledWakes = wakes
                    self.renderWakeItem()
                } else {
                    self.wakeItem.title = "깨우기 예약 실패: 권한 설정 필요"
                    self.wakeItem.isHidden = false
                }
            }
        }
    }

    private func renderWakeItem() {
        let next = scheduledWakes.filter { $0 > Date() }.min()
        wakeItem.title = next.map { "다음 깨우기 예약: \(Self.resetFormatter.string(from: $0))" } ?? ""
        wakeItem.isHidden = next == nil || !anyKickoff
    }

    @objc private func didWake() {
        let wokeAt = Date()
        let isScheduledWake = scheduledWakes.contains { abs($0.timeIntervalSince(wokeAt)) < 180 }
        guard anyKickoff, isScheduledWake else {
            refreshAll(attempts: 3)
            return
        }

        // Woken by our own schedule: ping, then put the Mac back to sleep unless someone started using it.
        let assertion = PowerManager.preventIdleSleep()
        refreshAll(attempts: 6) {
            PowerManager.allowIdleSleep(assertion)
            let awake = Date().timeIntervalSince(wokeAt)
            if let idle = PowerManager.idleSeconds(), idle >= awake - 2 {
                PowerManager.sleepNow()
            }
        }
    }

    private func renderStatus() {
        guard let button = statusItem.button else { return }
        button.title = ""
        let active = enabledSections
        if active.isEmpty {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "AI Agent Usage")
            button.image?.isTemplate = true
            button.toolTip = "AI Agent Usage"
            return
        }
        button.image = Self.statusImage(active.map { ($0.logo, $0.statusText) })
        button.toolTip = active.map { section in
            guard let snapshot = section.snapshot else { return "\(section.agent.name) —" }
            return "\(section.agent.name) \(durationLabel(snapshot.primary.durationMinutes)) \(remainingPercent(snapshot.primary))% 남음"
        }.joined(separator: "\n")
    }

    /// Draws every agent's logo and percentage into one template image so the menu bar tints it correctly.
    static func statusImage(_ parts: [(logo: NSImage?, text: String)]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let logoSize: CGFloat = 16, logoGap: CGFloat = 3, groupGap: CGFloat = 8, height: CGFloat = 18

        let widths = parts.map { part -> CGFloat in
            let textWidth = ceil((part.text as NSString).size(withAttributes: attributes).width)
            return (part.logo == nil ? 0 : logoSize + logoGap) + textWidth
        }
        let totalWidth = widths.reduce(0, +) + groupGap * CGFloat(max(0, parts.count - 1))

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (part, width) in zip(parts, widths) {
                var textX = x
                if let logo = part.logo {
                    logo.draw(in: NSRect(x: x, y: (height - logoSize) / 2, width: logoSize, height: logoSize))
                    textX += logoSize + logoGap
                }
                let textSize = (part.text as NSString).size(withAttributes: attributes)
                (part.text as NSString).draw(at: NSPoint(x: textX, y: (height - textSize.height) / 2), withAttributes: attributes)
                x += width + groupGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func describe(_ window: UsageWindow) -> String {
        let percent = remainingPercent(window)
        let reset = window.resetsAt.map { " · 초기화 \(Self.resetFormatter.string(from: $0))" } ?? ""
        return "\(durationLabel(window.durationMinutes))  \(percent)% 남음\(reset)"
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)일" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return "\(minutes)분"
    }

    private func updateChecks() {
        intervalMenu.items.forEach { $0.state = $0.tag == refreshSeconds ? .on : .off }
        let enabled = Set(enabledSections.map(\.agent))
        agentsMenu.items.forEach { $0.state = Set(Self.agentModes[$0.tag].agents) == enabled ? .on : .off }
        let kickoff = Set(Agent.allCases.filter(kickoffChosen))
        kickoffMenu.items.forEach { $0.state = Set(Self.agentModes[$0.tag].agents) == kickoff ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func refreshNow() {
        refreshAll()
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "refreshSeconds")
        scheduleTimer()
    }

    @objc private func changeAgents(_ sender: NSMenuItem) {
        let chosen = Self.agentModes[sender.tag].agents
        for section in sections {
            let enabled = chosen.contains(section.agent)
            defaults.set(enabled, forKey: "enabled.\(section.agent)")
            if !enabled {
                section.resetTimer?.cancel()
                section.resetTimer = nil
                section.retryTimer?.cancel()
                section.retryTimer = nil
            }
        }
        buildMenu()
        renderStatus()
        renderWakeItem()
        refreshAll()
    }

    @objc private func changeKickoff(_ sender: NSMenuItem) {
        let chosen = Self.agentModes[sender.tag].agents
        for section in sections {
            defaults.set(chosen.contains(section.agent), forKey: "autoKickoff.\(section.agent)")
            if !kickoffEnabled(section.agent) {
                section.resetTimer?.cancel()
                section.resetTimer = nil
                section.kickoffItem.isHidden = true
            }
        }
        updateChecks()
        renderWakeItem()
        if anyKickoff { refreshAll() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            loginErrorItem.isHidden = true
            updateChecks()
        } catch {
            loginErrorItem.title = "로그인 항목 오류: \(error.localizedDescription)"
            loginErrorItem.isHidden = false
        }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}

private func selfTest() -> Bool {
    let window = UsageWindow(usedPercent: 9, durationMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1_789_888_857))
    let hasLogos = Agent.allCases.allSatisfy {
        Bundle.main.url(forResource: $0.logoResource, withExtension: "png") != nil
    }
    let claudeSample = Data(#"{"five_hour":{"utilization":2.0,"resets_at":"2026-10-02T19:09:59.678505+00:00"},"seven_day":{"utilization":0.0,"resets_at":null}}"#.utf8)
    let claude = ClaudeUsageFetcher.parseSnapshot(claudeSample, plan: "pro")
    let claudeOK = claude.map {
        remainingPercent($0.primary) == 98
            && $0.primary.resetsAt?.timeIntervalSince1970 == 1_790_968_199
            && $0.secondary.map(remainingPercent) == 100
            && $0.secondary?.resetsAt == nil
    } ?? false
    let now = Date(timeIntervalSince1970: 1_790_968_000)
    let kickoffOK = !KickoffRunner.needsKickoff(claude!.primary, now: now)
        && KickoffRunner.needsKickoff(claude!.primary, now: now.addingTimeInterval(600))
        && KickoffRunner.needsKickoff(UsageWindow(usedPercent: 0, durationMinutes: 300, resetsAt: nil), now: now)
        && !KickoffRunner.needsKickoff(UsageWindow(usedPercent: 30, durationMinutes: 300, resetsAt: nil), now: now)
    let pmsetOK = PowerManager.pmsetFormatter.string(from: now).range(of: #"^\d{2}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil
    let image = AppDelegate.statusImage([(nil, "98%"), (nil, "91%")])
    return remainingPercent(window) == 91 && hasLogos && claudeOK && kickoffOK && pmsetOK && image.isTemplate && image.size.width > 0
}

if CommandLine.arguments.contains("--self-test") {
    let passed = selfTest()
    print(passed ? "self-test: ok" : "self-test: failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--fetch-once") {
    var failed = false
    for agent in Agent.allCases {
        switch agent.fetchSync() {
        case .success(let usage):
            let weekly = usage.secondary.map { ", secondaryRemaining=\(remainingPercent($0))%" } ?? ""
            print("\(agent.name): primaryRemaining=\(remainingPercent(usage.primary))%\(weekly)")
        case .failure(let error):
            failed = true
            fputs("\(agent.name) fetch failed: \(error.localizedDescription)\n", stderr)
        }
    }
    exit(failed ? 1 : 0)
}

if let index = CommandLine.arguments.firstIndex(of: "--kickoff"), CommandLine.arguments.count > index + 1 {
    let name = CommandLine.arguments[index + 1].lowercased()
    guard let agent = Agent.allCases.first(where: { name == "\($0)" }) else {
        fputs("usage: --kickoff claude|codex\n", stderr)
        exit(2)
    }
    switch KickoffRunner.ping(agent) {
    case .success:
        print("\(agent.name) kickoff ok (\(KickoffRunner.model(for: agent)))")
        exit(0)
    case .failure(let error):
        fputs("\(agent.name) kickoff failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
