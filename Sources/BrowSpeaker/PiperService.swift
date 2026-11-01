import AppKit
import Darwin
import Observation

struct PiperSynthesizer: ClipSynthesizer {
    func synthesize(_ text: String, voice: String, speed: Double) async throws -> Data {
        try await PiperService.shared.synthesize(text, voice: voice, speed: speed)
    }
}

/// Optional local engine: Piper neural voices (https://github.com/OHF-Voice/piper1-gpl),
/// installed by the app in its own Python environment. Free, no account, and
/// the text never leaves the Mac.
///
/// A local Piper HTTP server keeps the voices loaded between paragraphs; it is
/// started on first use and stopped with the app.
@MainActor
@Observable
final class PiperService {
    static let shared = PiperService()

    struct InstalledVoice: Identifiable, Hashable {
        let id: String
        let label: String
    }

    struct CatalogVoice: Identifiable, Hashable {
        let id: String
        let label: String
        let megabytes: Int
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private(set) var isInstalled = false
    private(set) var installedVoices: [InstalledVoice] = []
    private(set) var catalog: [CatalogVoice] = []
    /// The long operation in progress (install, download), shown in Settings.
    private(set) var busy: String?
    private(set) var status: String?

    var voices: [Voice] {
        isInstalled ? installedVoices.map { Voice(engine: .piper, id: $0.id, label: $0.label) } : []
    }

    @ObservationIgnored private var server: Process?
    @ObservationIgnored private var port = 0
    @ObservationIgnored private var serverStart: Task<Int, Error>?

    /// Kept short on purpose: espeak-ng (bundled with Piper) fails to find its
    /// data when that path is longer than about 160 characters.
    private static let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.browspeaker/piper", isDirectory: true)
    private static let envDir = baseDir.appendingPathComponent("env", isDirectory: true)
    private static let python = envDir.appendingPathComponent("bin/python")
    private static let voicesDir = baseDir.appendingPathComponent("voices", isDirectory: true)
    private static let installedMarker = baseDir.appendingPathComponent(".installed")
    private static let logFile = baseDir.appendingPathComponent("piper.log")

    init() {
        reload()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PiperService.shared.stopServer() }
        }
    }

    func reload() {
        isInstalled = FileManager.default.fileExists(atPath: Self.installedMarker.path)
        installedVoices = Self.scanVoices()
    }

    // MARK: Install and voices

    func install() async {
        await perform("Installation de Piper (environ 200 Mo)…") {
            guard let python = await Self.findPython() else {
                throw Failure("Python 3.9 ou plus récent est requis (python.org ou « brew install python »).")
            }
            try FileManager.default.createDirectory(at: Self.voicesDir, withIntermediateDirectories: true)
            try await Self.run(python, ["-m", "venv", "--clear", Self.envDir.path])
            try await Self.run(Self.python, ["-m", "pip", "install", "--disable-pip-version-check", "-q", "piper-tts[http]"])
            FileManager.default.createFile(atPath: Self.installedMarker.path, contents: nil)
            self.reload()
            self.status = "Piper est installé. Téléchargez une voix ci-dessous."
        }
        await loadCatalog()
    }

    func download(_ voice: CatalogVoice) async {
        await perform("Téléchargement de \(voice.label)…") {
            try await Self.run(Self.python, ["-m", "piper.download_voices", "--download-dir", Self.voicesDir.path, voice.id])
            self.reload()
            self.status = "\(voice.label) est prête : choisissez-la dans « Aa » › Voix."
        }
    }

    func remove(_ voice: InstalledVoice) {
        for ext in ["onnx", "onnx.json"] {
            try? FileManager.default.removeItem(at: Self.voicesDir.appendingPathComponent("\(voice.id).\(ext)"))
        }
        reload()
    }

    func uninstall() {
        stopServer()
        try? FileManager.default.removeItem(at: Self.baseDir)
        catalog = []
        status = nil
        reload()
    }

    /// Voices in the system speech language, from the piper-voices catalog.
    func loadCatalog() async {
        guard catalog.isEmpty,
              let url = URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return }
        let family = String(AVVoices.systemLanguage.prefix(2))
        let qualityRank = ["high": 0, "medium": 1, "low": 2, "x_low": 3]
        catalog = entries.compactMap { id, entry -> (CatalogVoice, Int)? in
            guard let language = entry["language"] as? [String: Any], language["family"] as? String == family,
                  let code = language["code"] as? String, let quality = entry["quality"] as? String,
                  let name = entry["name"] as? String
            else { return nil }
            let files = entry["files"] as? [String: [String: Any]] ?? [:]
            let bytes = files.filter { $0.key.hasSuffix(".onnx") }.compactMap { $0.value["size_bytes"] as? Int }.reduce(0, +)
            let voice = CatalogVoice(id: id, label: Self.label(name: name, code: code, quality: quality), megabytes: bytes / 1_000_000)
            return (voice, qualityRank[quality] ?? 9)
        }
        .sorted { ($0.1, $0.0.label) < ($1.1, $1.0.label) }
        .map(\.0)
    }

    private func perform(_ message: String, _ work: () async throws -> Void) async {
        guard busy == nil else { return }
        busy = message
        status = nil
        do {
            try await work()
        } catch {
            status = "Échec : \(error.localizedDescription)"
        }
        busy = nil
    }

    private static func scanVoices() -> [InstalledVoice] {
        let files = (try? FileManager.default.contentsOfDirectory(at: voicesDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "onnx" }.compactMap { model in
            let config = model.appendingPathExtension("json")
            guard let data = try? Data(contentsOf: config),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let id = model.deletingPathExtension().lastPathComponent
            let code = (json["language"] as? [String: Any])?["code"] as? String ?? ""
            let quality = (json["audio"] as? [String: Any])?["quality"] as? String ?? ""
            let name = json["dataset"] as? String ?? id
            return InstalledVoice(id: id, label: label(name: name, code: code, quality: quality))
        }
        .sorted { $0.label < $1.label }
    }

    /// "Siwis — Piper (fr_FR, medium)"
    private static func label(name: String, code: String, quality: String) -> String {
        "\(name.replacingOccurrences(of: "_", with: " ").capitalized) — Piper (\(code), \(quality))"
    }

    // MARK: Synthesis

    func synthesize(_ text: String, voice: String, speed: Double) async throws -> Data {
        let port = try await ensureServer(voice: voice)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/synthesize")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "voice": voice, "length_scale": 1 / max(speed, 0.25),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure("le serveur Piper a répondu \(status)") }
        return data
    }

    private func ensureServer(voice: String) async throws -> Int {
        if let server, server.isRunning { return port }
        if let serverStart { return try await serverStart.value }
        let start = Task { try await startServer(voice: voice) }
        serverStart = start
        defer { serverStart = nil }
        return try await start.value
    }

    private func startServer(voice: String) async throws -> Int {
        guard isInstalled else { throw Failure("Piper n'est pas installé") }
        let port = Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Watchdog: the server also stops if the app goes away without quitting
        // normally (crash, force quit).
        let watchdog = """
        "$0" "$@" & c=$!; trap 'kill $c 2>/dev/null; exit' TERM INT; \
        while kill -0 \(getpid()) 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 2; done; kill $c 2>/dev/null
        """
        process.arguments = ["-c", watchdog, Self.python.path, "-m", "piper.http_server",
                             "--host", "127.0.0.1", "--port", "\(port)", "--data-dir", Self.voicesDir.path, "-m", voice]
        let log = try Self.openLog()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        server = process
        self.port = port

        let probe = URL(string: "http://127.0.0.1:\(port)/voices")!
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(250))
            guard process.isRunning else { break }
            if let (_, response) = try? await URLSession.shared.data(from: probe),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return port
            }
        }
        stopServer()
        throw Failure("le serveur Piper n'a pas démarré (détails : \(Self.logFile.path))")
    }

    func stopServer() {
        server?.terminate()
        server = nil
    }

    // MARK: Helpers

    /// Prefers a recent Homebrew or python.org Python; Apple's python3 only when
    /// the developer tools are already installed (otherwise it asks to install them).
    private static func findPython() async -> URL? {
        var candidates: [String] = []
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            candidates += ["3.13", "3.12", "3.11", "3.10"].map { "\(dir)/python\($0)" } + ["\(dir)/python3"]
        }
        candidates += ["/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                       "/Library/Developer/CommandLineTools/usr/bin/python3",
                       "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if (try? await run(url, ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)"])) != nil {
                return url
            }
        }
        return nil
    }

    /// Runs a command to completion; output goes to the log file (a pipe could
    /// fill up and block pip).
    private static func run(_ executable: URL, _ arguments: [String]) async throws {
        let log = try openLog()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = log
        process.standardError = log
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        try? log.close()
        guard status == 0 else {
            let tail = (try? String(contentsOf: logFile, encoding: .utf8))?
                .split(separator: "\n").suffix(2).joined(separator: " ") ?? ""
            throw Failure("\(executable.lastPathComponent) a échoué. \(tail)")
        }
    }

    private static func openLog() throws -> FileHandle {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFile)
        handle.seekToEndOfFile()
        return handle
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return ok ? Int(UInt16(bigEndian: address.sin_port)) : 59125
    }
}
