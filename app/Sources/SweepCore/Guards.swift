import Foundation

/// 룰만으로는 못 막는 것을 걸러냅니다.
///
/// 룰은 경로 모양만 봅니다. 하지만 `build`라는 이름이 산출물인지 소스인지는 경로만으로
/// 알 수 없습니다. git이 그 경로를 추적하고 있으면 그건 사람이 쓴 파일입니다.
/// 여기서 하는 검사가 룰의 마지막 방어선입니다. git으로 확인할 수 없는 경우는 통과시키지
/// 않고 막거나 기본 선택에서 뺍니다. 확인을 못 했다는 건 안전하다는 뜻이 아닙니다.
public struct SafetyGuards: Sendable {

    /// Gradle 버전별로 그 버전을 쓰는 프로젝트입니다. 스캔 중에 모아서 넘겨받습니다.
    let gradleOwners: [String: [String]]
    /// 활성 프로젝트로 볼 기준입니다.
    let activeWithinDays: Int

    public init(gradleOwners: [String: [String]] = [:], activeWithinDays: Int = 30) {
        self.gradleOwners = gradleOwners
        self.activeWithinDays = activeWithinDays
    }

    public func apply(to candidates: [Candidate]) async -> [Candidate] {
        var result = candidates

        // 검사 4: 실행 중인 프로세스. 목록을 한 번만 받아 전체 후보에 씁니다.
        let running = Self.runningProcesses()
        let engine = RuleEngine()
        // 명령줄 도구가 없는 맥에서 /usr/bin/git은 부를 때마다 설치 창을 띄웁니다.
        // 스캔마다 한 번만 확인하고, 없으면 git을 아예 부르지 않습니다.
        let gitAvailable = Self.isGitAvailable()

        // git 관련 검사는 저장소 단위로 묶어야 명령 실행 횟수를 줄일 수 있습니다.
        var byRepo: [String: [Int]] = [:]
        for (index, candidate) in result.enumerated() {
            if let repo = Self.gitRoot(for: candidate.path) {
                byRepo[repo, default: []].append(index)
            }
        }

        let repoReports = await withTaskGroup(of: (String, RepoReport).self) { group -> [String: RepoReport] in
            for repo in byRepo.keys where gitAvailable {
                let paths = byRepo[repo]!.map { result[$0].path }
                group.addTask {
                    (repo, Self.inspect(repo: repo, candidatePaths: paths))
                }
            }
            var out: [String: RepoReport] = [:]
            for await (repo, report) in group { out[repo] = report }
            return out
        }

        for index in result.indices {
            var c = result[index]

            // 검사 4: 프로세스 잠금
            if let rule = engine.rule(id: c.ruleID) {
                var lock: String?
                // 실행 파일 이름이 정확히 일치할 때만 잠급니다.
                if let names = rule.lockProcesses {
                    lock = names.first { running.names.contains($0.lowercased()) }
                }
                // 인수에만 이름이 드러나는 프로세스는 커맨드라인을 봅니다.
                if lock == nil, let patterns = rule.lockCommands {
                    lock = patterns.first { running.commandLine.contains($0) }
                }
                if let lock {
                    c.lockedBy = lock
                    c.blocked = true
                    // 경로로 잠근 경우(Claude.app/Contents/MacOS/Claude)는 끝 이름만 보여줍니다.
                    c.blockReason = L("\((lock as NSString).lastPathComponent) 실행 중", "\((lock as NSString).lastPathComponent) is running")
                }
            }

            // 검사 3: 툴체인 소유자. 이 캐시를 쓰는 프로젝트가 있으면 알려주고
            // 기본 선택에서 뺍니다. Gradle 8.14.3을 지우면 그 버전을 쓰는 프로젝트가
            // 다음 빌드에서 배포판을 다시 내려받아야 합니다.
            if c.ruleID == "gradle-version-cache" {
                let version = (c.path as NSString).lastPathComponent
                if let owners = gradleOwners[version], !owners.isEmpty {
                    c.owner = owners.joined(separator: ", ")
                    c.warnings.append(L("\(c.owner!) 사용 중", "Used by \(c.owner!)"))
                    // 선택 정책이 이걸 다시 켜지 못하게 표시해 둡니다.
                    c.deselectedBySafety = true
                }
            }

            let repo = Self.gitRoot(for: c.path)

            // 검사 7: 저장소 밖의 빌드 산출물. git으로 소스인지 확인할 수 없으니 미리
            // 체크하지 않습니다. 검사 폴더에 섞인 압축 푼 SDK의 bin 같은 것이 여기 걸립니다.
            if repo == nil, c.category == .projectOutput {
                c.warnings.append(L("git 저장소 밖", "Outside git"))
                c.deselectedBySafety = true
            }

            if let repo, Self.isToolCheckout(repo) {
                // 검사 8: git으로 받은 SDK입니다. Homebrew는 .gitignore가 설치한 프로그램 전체를
                // 무시하게 되어 있어서, 검사 1을 그대로 통과해 산출물로 보입니다.
                c.blocked = true
                c.blockReason = L("SDK 저장소", "SDK checkout")
            } else if let repo, !gitAvailable || repoReports[repo]?.failed != false {
                // 검사 9: git을 못 쓰거나 명령이 실패했습니다. 추적 여부를 모르니 막습니다.
                c.blocked = true
                c.blockReason = L("git 확인 실패", "Git check failed")
            } else if let repo, let report = repoReports[repo] {
                let relative = Self.relative(c.path, from: repo)

                // 검사 1: git이 추적하는 경로면 소스입니다. 무조건 막습니다.
                if report.trackedPrefixes.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                    c.blocked = true
                    c.blockReason = L("git이 추적하는 소스", "Tracked by git")
                }
                // gitignore도 안 되어 있고 추적도 안 되는 경로는 성격이 애매합니다.
                else if !report.ignored.contains(relative) {
                    c.warnings.append(L("gitignore에 없음", "Not in .gitignore"))
                }

                // 검사 2: 커밋하지 않은 변경이 이 안에 있으면 막습니다.
                if report.dirtyPaths.contains(where: { $0.hasPrefix(relative + "/") || $0 == relative }) {
                    c.blocked = true
                    c.blockReason = L("커밋하지 않은 변경 있음", "Has uncommitted changes")
                }

                // 검사 5: 활성 프로젝트면 재빌드 부담을 알려줍니다.
                if let days = report.lastCommitDays {
                    c.lastCommitDays = days
                    if days <= activeWithinDays && (c.cost == .slow || c.cost == .reindex) {
                        c.warnings.append(L("\(days)일 전 커밋 · \(c.cost.label)", "Last commit \(days)d ago · \(c.cost.label)"))
                    }
                }
            }

            // 검사 6: 자기 자신. 다른 검사보다 뒤에 두어야 이 사유가 화면에 남습니다.
            // 실행 중인 Sweep이 들어 있다는 게 사용자에게 가장 분명한 설명입니다.
            if Self.containsRunningSweep(c.path) {
                c.blocked = true
                c.blockReason = L("실행 중인 Sweep이 들어 있음", "Contains the running Sweep")
            }

            result[index] = c
        }

        return result
    }

    // MARK: - 저장소 단위 검사

    struct RepoReport: Sendable {
        /// gitignore가 무시하는 경로입니다. 저장소 기준 상대경로입니다.
        var ignored: Set<String> = []
        /// git이 추적하는 파일의 상위 디렉터리들입니다.
        var trackedPrefixes: Set<String> = []
        /// 커밋하지 않은 변경 경로입니다.
        var dirtyPaths: Set<String> = []
        var lastCommitDays: Int?
        /// git 명령 중 하나라도 실패했으면 true입니다. 결과가 비어 있어도 믿을 수 없습니다.
        var failed = false
    }

    static func inspect(repo: String, candidatePaths: [String]) -> RepoReport {
        var report = RepoReport()
        // 한글 경로를 \354\225... 같은 8진수로 바꿔 내보내지 않게 합니다. 바뀐 채로는
        // 후보 경로와 비교할 수 없어서 커밋하지 않은 변경을 놓칩니다.
        let git = ["-c", "core.quotePath=false"]
        func failed() -> RepoReport {
            var failure = RepoReport()
            failure.failed = true
            return failure
        }
        let relatives = candidatePaths.map { relative($0, from: repo) }

        // check-ignore는 여러 경로를 한 번에 받습니다. 무시되는 경로면 산출물이라는
        // 뜻이라, 대부분의 후보가 여기서 한 번에 통과합니다.
        let ignoreInput = relatives.joined(separator: "\n") + "\n"
        // 무시되는 경로가 하나도 없으면 1로 끝납니다. 정상입니다.
        let ignoreOut = run("/usr/bin/git", git + ["check-ignore", "--stdin"], cwd: repo, stdin: ignoreInput)
        guard ignoreOut.status == 0 || ignoreOut.status == 1 else { return failed() }
        report.ignored = Set(ignoreOut.out.split(separator: "\n").map(String.init))

        // 무시되지 않은 후보만 실제 추적 여부를 확인합니다. 여기 걸리면 소스입니다.
        for relative in relatives where !report.ignored.contains(relative) {
            let tracked = run("/usr/bin/git", git + ["ls-files", "--", relative], cwd: repo)
            guard tracked.status == 0 else { return failed() }
            if !tracked.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.trackedPrefixes.insert(relative)
            }
        }

        // 추적하지 않는 폴더는 기본으로 "newdir/" 한 줄로 접혀서, 그 안의 후보와 비교할 수
        // 없습니다. 파일 단위로 펼칩니다. 무시된 파일은 어차피 나오지 않습니다.
        let status = run("/usr/bin/git", git + ["status", "--porcelain", "--untracked-files=all"], cwd: repo)
        guard status.status == 0 else { return failed() }
        for line in status.out.split(separator: "\n") {
            // "XY path" 또는 "XY old -> new" 형태입니다.
            let trimmed = line.dropFirst(3)
            let path = trimmed.components(separatedBy: " -> ").last ?? String(trimmed)
            report.dirtyPaths.insert(path.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }

        // 커밋이 하나도 없는 저장소에서는 실패합니다. 정상이라 실패로 치지 않습니다.
        let log = run("/usr/bin/git", ["log", "-1", "--format=%ct"], cwd: repo)
        if let seconds = Double(log.out.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let elapsed = Date().timeIntervalSince(Date(timeIntervalSince1970: seconds))
            report.lastCommitDays = max(0, Int(elapsed / 86_400))
        }

        return report
    }

    // MARK: - 자기 자신 보호

    /// 지금 돌고 있는 Sweep의 실행 파일 경로입니다.
    ///
    /// 메뉴바 앱은 `.build/bundle/Sweep.app` 안에서 돌고 CLI도 `.build/release/sweep`에
    /// 있습니다. 둘 다 `~/Projects/sweep/app/.build` 후보에 통째로 들어가기 때문에,
    /// 막지 않으면 Sweep이 실행 중인 자기 자신을 지웁니다.
    public static let selfExecutablePath: String = {
        let url = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        return url.resolvingSymlinksInPath().path
    }()

    /// 후보가 지금 돌고 있는 Sweep을 품고 있는지 봅니다.
    ///
    /// 실행 중인 것만 막습니다. 예전에 만들어두고 지금 안 쓰는 번들까지 막으면
    /// 영영 못 지우는 용량이 생기는데, 그건 몇 초면 다시 빌드되는 것들입니다.
    public static func containsRunningSweep(_ path: String) -> Bool {
        let selfPath = selfExecutablePath
        guard !selfPath.isEmpty, !path.isEmpty else { return false }
        return selfPath == path || selfPath.hasPrefix(path + "/")
    }

    // MARK: - 유틸

    /// 명령줄 도구가 깔려 있어 git을 부를 수 있는지입니다.
    static func isGitAvailable() -> Bool {
        run("/usr/bin/xcode-select", ["-p"]).status == 0
    }

    /// git으로 받아 쓰는 SDK인지 봅니다. 저장소이긴 하지만 사용자가 만드는 프로젝트가 아닙니다.
    ///
    /// 이름이 아니라 안에 든 파일로 알아봅니다. 사람마다 받아둔 폴더 이름이 다릅니다.
    public static func isToolCheckout(_ repo: String) -> Bool {
        let markers = [
            "Library/Homebrew",        // Homebrew
            "packages/flutter_tools",  // Flutter
            "emsdk.py",                // Emscripten
            "bootstrap-vcpkg.sh",      // vcpkg
            "gclient.py",              // depot_tools
        ]
        return markers.contains { FileManager.default.fileExists(atPath: repo + "/" + $0) }
    }

    /// 후보 경로에서 위로 올라가며 저장소 루트를 찾습니다.
    public static func gitRoot(for path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var current = (path as NSString).deletingLastPathComponent
        while current.count > home.count, current.hasPrefix(home) {
            if FileManager.default.fileExists(atPath: current + "/.git") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func relative(_ path: String, from base: String) -> String {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// 실행 중인 프로세스를 두 갈래로 모읍니다.
    ///
    /// `names`는 실행 파일 이름만 소문자로 모은 집합입니다. 정확히 비교하려고 이렇게 둡니다.
    /// `commandLine`은 인수까지 포함한 전체 텍스트로, Gradle 데몬처럼 실행 파일이 `java`인
    /// 프로세스를 찾을 때만 씁니다.
    static func runningProcesses() -> (names: Set<String>, commandLine: String) {
        let comm = run("/bin/ps", ["-Ao", "comm="]).out
        let names = Set(comm.split(separator: "\n").map {
            ($0 as NSString).lastPathComponent.lowercased()
        })
        let commandLine = run("/bin/ps", ["-Ao", "command="]).out
        return (names, commandLine)
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String],
                    cwd: String? = nil, stdin: String? = nil) -> (out: String, status: Int32) {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return ("", -1) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        let inPipe = Pipe()
        if stdin != nil { process.standardInput = inPipe }

        do { try process.run() } catch { return ("", -1) }

        if let stdin, let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
            try? inPipe.fileHandleForWriting.close()
        }

        // 파이프를 다 읽기 전에 기다리면 출력이 많을 때 서로 막힙니다.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
