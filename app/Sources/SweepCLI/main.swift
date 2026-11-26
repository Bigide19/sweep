import Foundation
import SweepCore

// 메뉴바 앱과 같은 코어를 씁니다. UI 없이 룰과 안전장치를 검증하는 용도입니다.

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "scan"
let flags = Set(arguments.filter { $0.hasPrefix("--") })

enum Ansi {
    static let reset = "\u{1B}[0m"
    static let dim = "\u{1B}[2m"
    static let bold = "\u{1B}[1m"
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let cyan = "\u{1B}[36m"
}

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// 여러 번 줄 수 있는 플래그의 값을 모두 모읍니다. 쉼표로 묶어 줘도 됩니다.
func values(for flag: String) -> [String] {
    var result: [String] = []
    for (index, argument) in arguments.enumerated() where argument == flag && index + 1 < arguments.count {
        result += arguments[index + 1].split(separator: ",").map {
            SweepScanner.expand($0.trimmingCharacters(in: .whitespaces))
        }
    }
    return result
}

/// 스크립트에서 읽을 수 있는 형태입니다. 번호는 사람이 읽는 목록과 같은 순서입니다.
struct JSONCandidate: Encodable {
    let index: Int
    let path: String
    let ruleID: String
    let category: String
    let cost: String
    let bytes: Int64
    let sharedBytes: Int64
    let idleDays: Int?
    let deletable: Bool
    let defaultSelected: Bool
    let blockReason: String?
    let warnings: [String]

    // 값이 없어도 키는 남깁니다. 기본 인코딩은 nil인 키를 빼서 읽는 쪽이 키 유무를 따져야 합니다.
    enum CodingKeys: String, CodingKey {
        case index, path, ruleID, category, cost, bytes, sharedBytes, idleDays,
             deletable, defaultSelected, blockReason, warnings
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(path, forKey: .path)
        try container.encode(ruleID, forKey: .ruleID)
        try container.encode(category, forKey: .category)
        try container.encode(cost, forKey: .cost)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(sharedBytes, forKey: .sharedBytes)
        try container.encode(idleDays, forKey: .idleDays)
        try container.encode(deletable, forKey: .deletable)
        try container.encode(defaultSelected, forKey: .defaultSelected)
        try container.encode(blockReason, forKey: .blockReason)
        try container.encode(warnings, forKey: .warnings)
    }
}

func printJSON(_ result: ScanResult) {
    let items = orderedCandidates(result).enumerated().map { offset, c in
        JSONCandidate(index: offset + 1, path: c.path, ruleID: c.ruleID, category: c.category.rawValue,
                      cost: c.cost.rawValue, bytes: c.bytes, sharedBytes: c.sharedBytes,
                      idleDays: c.idleDays, deletable: c.isDeletable,
                      defaultSelected: c.defaultSelected,
                      blockReason: c.blockReason ?? (c.unclassified ? "unclassified" : nil),
                      warnings: c.warnings)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(items), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

/// 화면 목록과 같은 순서입니다. `--index` 번호가 이 순서를 따릅니다.
func orderedCandidates(_ result: ScanResult) -> [Candidate] {
    SweepCategory.allCases.sorted { $0.order < $1.order }
        .flatMap { category in result.candidates.filter { $0.category == category } }
}

// MARK: - 목록 출력

func printResult(_ result: ScanResult) {
    let disk = Format.disk()
    let after = disk.percentAfterFreeing(result.reclaimableBytes)
    print("")
    print("  \(Ansi.bold)sweep\(Ansi.reset)  후보 \(Format.bytes(result.reclaimableBytes))" +
          "  \(Ansi.dim)디스크 \(Format.bytes(disk.used)) / \(Format.bytes(disk.total))" +
          " \(disk.percent)% → \(after)%" +
          "  스캔 \(String(format: "%.1f", result.duration))초\(Ansi.reset)")

    var index = 0
    for category in SweepCategory.allCases.sorted(by: { $0.order < $1.order }) {
        let items = result.candidates.filter { $0.category == category }
        guard !items.isEmpty else { continue }

        let sum = Candidate.withoutNested(items.filter { $0.isDeletable }).reduce(Int64(0)) { $0 + $1.bytes }
        print("")
        print("  \(Ansi.cyan)▸ \(category.label)\(Ansi.reset)  \(Ansi.dim)\(Format.bytes(sum))\(Ansi.reset)")

        for item in items {
            index += 1
            let mark: String
            if item.blocked || item.unclassified {
                mark = "\(Ansi.red)✗\(Ansi.reset)"
            } else if item.defaultSelected {
                mark = "\(Ansi.green)x\(Ansi.reset)"
            } else {
                mark = " "
            }

            let project = item.project.map { "\(Ansi.bold)\($0)\(Ansi.reset) " } ?? ""
            let size = Format.bytes(item.bytes).leftPadded(to: 8)
            print("  \(String(index).leftPadded(to: 3)) [\(mark)] \(size)  \(project)\(item.display)")

            var notes: [String] = []
            if let reason = item.blockReason { notes.append("\(Ansi.red)\(reason)\(Ansi.reset)") }
            if let locked = item.lockedBy, item.blockReason == nil { notes.append("\(Ansi.red)\(locked) 실행 중\(Ansi.reset)") }
            notes.append(contentsOf: item.warnings.map { "\(Ansi.yellow)\($0)\(Ansi.reset)" })
            if !item.blocked && !item.unclassified { notes.append("\(Ansi.dim)\(item.cost.label)\(Ansi.reset)") }
            // 정리 강도가 유휴일로 고르니 그 근거를 같이 보여줍니다.
            if let idle = item.idleDays, idle >= 7 { notes.append("\(Ansi.dim)\(idle)일 방치\(Ansi.reset)") }
            if !notes.isEmpty {
                print("      \(Ansi.dim)└\(Ansi.reset) " + notes.joined(separator: " · "))
            }
        }
    }

    let blocked = result.candidates.filter { $0.blocked || $0.unclassified }
    print("")
    print("  \(Ansi.dim)후보 \(result.candidates.count)개 중 삭제 가능 \(result.candidates.count - blocked.count)개, 보호됨 \(blocked.count)개\(Ansi.reset)")
    if !result.skipped.isEmpty {
        print("  \(Ansi.dim)접근 불가로 건너뜀: \(result.skipped.count)곳\(Ansi.reset)")
    }
    print("")
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - 명령

func runScan() async {
    let scanner = SweepScanner()
    if !flags.contains("--quiet") {
        FileHandle.standardError.write("스캔 중...\n".data(using: .utf8)!)
    }
    let result = await scanner.scan()
    if flags.contains("--json") { printJSON(result) } else { printResult(result) }
}

func runVerify() async {
    // 실제 정리에서 사람이 직접 판단했던 케이스를 옮겨둔 것입니다. 룰 엔진이 같은
    // 결론을 내는지 확인합니다. 판정은 문자열만 보므로 경로가 없어도 됩니다.
    // 프로젝트 이름은 성격이 드러나게 지었습니다. 어떤 모양의 경로를 다루는지가
    // 이 목록의 요점이라, 특정 저장소 이름을 박아두면 읽는 사람만 헷갈립니다.
    let expectations: [(path: String, expected: RuleKind, ruleID: String?)] = [
        // 지워야 하는 것
        ("~/Projects/rn-app/android/app/build", .allow, "android-native"),
        ("~/Projects/rn-app/android/app/.cxx", .allow, "android-native"),
        ("~/Projects/rn-app/android/.gradle", .allow, "android-native"),
        ("~/Projects/rn-app/node_modules/react-native-reanimated/android/build", .allow, "rn-native-build"),
        ("~/Projects/rn-app/node_modules/react-native-reanimated/android/.cxx", .allow, "rn-native-cache"),
        ("~/Projects/expo-app/app/node_modules/@expo/log-box/android/build", .allow, "rn-native-build"),
        ("~/Projects/expo-app/app/node_modules/expo/node_modules/expo-constants/android/build", .allow, "rn-native-build"),
        ("~/Projects/ios-app/ios/build", .allow, "ios-build"),
        ("~/Projects/sample-app/build", .allow, "generic-build"),
        ("~/Projects/next-app/.next", .allow, "frontend-build"),
        ("~/Projects/dotnet-lib/DeveloperGuide/obj", .allow, "dotnet-output"),
        ("~/.gradle/caches/8.14.3", .allow, "gradle-version-cache"),
        ("~/.gradle/caches/9.3.1", .allow, "gradle-version-cache"),
        ("~/.npm/_cacache", .allow, "npm-cache"),
        ("~/Library/Caches/JetBrains", .allow, "cache-jetbrains"),
        ("~/Library/Caches/Homebrew", .allow, "cache-homebrew"),
        ("~/Library/Developer/Xcode/DerivedData", .allow, "xcode-derived"),
        ("~/.cache/codex-runtimes", .allow, "ai-codex-runtime"),
        ("~/.codex/cache", .allow, "ai-codex-cache"),
        ("~/Library/Caches/Codex", .allow, "ai-codex-cache"),
        ("~/Library/Application Support/Claude/Code Cache", .allow, "ai-claude-desktop-cache"),
        ("~/Library/Caches/claude-cli-nodejs", .allow, "ai-claude-cli-logs"),
        ("~/.cache/github-copilot", .allow, "ai-copilot-index"),
        ("~/Projects/node-app/node_modules", .allow, "node-modules"),
        ("~/Projects/monorepo/packages/web/node_modules", .allow, "node-modules"),
        ("~/Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)", .allow, "xcode-device-support"),
        ("~/Library/Developer/Xcode/watchOS DeviceSupport/Watch6,1 10.4 (21T216)", .allow, "xcode-device-support"),
        ("~/.cargo/registry", .allow, "cargo-registry"),
        ("~/.m2/repository", .allow, "maven-repo"),
        ("~/.pub-cache/hosted", .allow, "pub-cache"),
        ("~/.cache/huggingface", .allow, "ai-local-models"),
        ("~/.ollama/models", .allow, "ai-local-models"),

        // 건드리면 안 되는 것. 아래 셋은 실제로 걸러냈던 함정입니다.
        ("~/Projects/node-app/web/node_modules/next/dist/build", .deny, "node-package-code"),
        ("~/Projects/node-app/web/node_modules/yargs/build", .deny, "node-package-code"),
        ("~/Projects/dotnet-app/AgentApp/packages/Stub.System.Data.SQLite.Core.NetFramework.1.0.119.0/build", .deny, "nuget-package-dir"),
        ("~/Projects/node-app/venv/lib/python3.13/site-packages/pip/_internal/operations/build", .deny, "python-packages"),
        ("~/Library/Android/sdk/build-tools/34.0.0/build", .deny, "android-sdk"),
        // npm i -g로 깐 CLI입니다. 다시 깔아 줄 프로젝트가 없습니다.
        ("~/.nvm/versions/node/v22.0.0/lib/node_modules", .deny, "node-global-packages"),
        // 훑기만 해도 미디어 보관함 접근 경고가 뜨는 경로들입니다.
        ("~/Library/Caches/com.apple.Music", .deny, "apple-system-cache"),
        ("~/Library/Caches/com.apple.AMPLibraryAgent", .deny, "apple-system-cache"),
    ]

    // 검증은 배포하는 기본 룰을 대상으로 합니다. 사용자 룰 파일이나 덧씌우기가 끼면
    // 결과가 이 맥의 설정에 따라 흔들려서 회귀 검사 구실을 못 합니다.
    let engine = RuleEngine(ruleSet: DefaultRuleSet.ruleSet)

    /// git이 추적하는 build를 가진 임시 저장소를 만듭니다. 안전장치 검증용입니다.
    func makeTrackedBuildSandbox() -> (root: URL, buildPath: String)? {
        let fm = FileManager.default
        // 안전장치가 홈 밖으로는 저장소를 찾아 올라가지 않아서 홈 아래에 둡니다.
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sweep/verify-\(ProcessInfo.processInfo.processIdentifier)")
        let build = root.appendingPathComponent("build")
        guard let gitPath = ["/usr/bin/git", "/opt/homebrew/bin/git"].first(where: {
            fm.isExecutableFile(atPath: $0)
        }) else { return nil }

        func git(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        do {
            try? fm.removeItem(at: root)
            try fm.createDirectory(at: build, withIntermediateDirectories: true)
            try "tracked\n".write(to: build.appendingPathComponent("keep.txt"),
                                  atomically: true, encoding: .utf8)
            // 커밋까지 해야 "추적 중이지만 변경은 없는" 상태가 됩니다. 스테이징만 하면
            // 커밋하지 않은 변경 검사에 먼저 걸려서 정작 추적 검사를 확인하지 못합니다.
            // 사용자 git 설정에 기대지 않도록 이름과 메일은 인자로 넘깁니다.
            guard git(["init", "--quiet"]),
                  git(["add", "build/keep.txt"]),
                  git(["-c", "user.name=sweep", "-c", "user.email=sweep@localhost",
                       "-c", "commit.gpgsign=false",
                       "commit", "--quiet", "-m", "verify fixture"]) else {
                try? fm.removeItem(at: root)
                return nil
            }
        } catch {
            return nil
        }
        return (root, build.path)
    }
    var passed = 0
    var failed = 0

    print("")
    print("  \(Ansi.bold)룰 판정 검증\(Ansi.reset)")
    print("")
    for expectation in expectations {
        let path = SweepScanner.expand(expectation.path)
        let decision = engine.decide(path)
        let kindOK = decision.kind == expectation.expected
        let ruleOK = expectation.ruleID == nil || decision.rule?.id == expectation.ruleID
        let ok = kindOK && ruleOK

        if ok {
            passed += 1
            print("  \(Ansi.green)통과\(Ansi.reset)  \(expectation.expected.rawValue.leftPadded(to: 5))  \(Ansi.dim)\(decision.rule?.id ?? "-")\(Ansi.reset)  \(SweepScanner.abbreviate(path))")
        } else {
            failed += 1
            let got = "\(decision.kind?.rawValue ?? "매칭 없음")/\(decision.rule?.id ?? "-")"
            print("  \(Ansi.red)실패\(Ansi.reset)  기대 \(expectation.expected.rawValue)/\(expectation.ruleID ?? "-"), 실제 \(got)")
            print("        \(SweepScanner.abbreviate(path))")
        }
    }

    // git 추적 검사는 룰이 아니라 안전장치가 담당합니다. 실제 경로로 확인합니다.
    print("")
    print("  \(Ansi.bold)안전장치 검증\(Ansi.reset)")
    print("")
    // git이 추적하는 build를 막는지 봅니다. 특정 맥의 실제 저장소에 기대면 그 폴더가
    // 없는 곳에서는 검사가 통째로 건너뛰어집니다. 임시 저장소를 만들어 직접 재현합니다.
    //
    // 홈 아래에 만드는 이유가 있습니다. 안전장치는 홈 밖으로는 저장소를 찾아 올라가지
    // 않습니다. /tmp에 만들면 git 저장소로 인식되지 않아 검사가 성립하지 않습니다.
    if let sandbox = makeTrackedBuildSandbox() {
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let decision = engine.decide(sandbox.buildPath)
        let candidate = Candidate(path: sandbox.buildPath, ruleID: decision.rule?.id ?? "-",
                                  category: .projectOutput, cost: .instant,
                                  display: "build")
        let guarded = await SafetyGuards().apply(to: [candidate])
        // 사유까지 봅니다. 다른 검사(작업 중인 프로세스 등)에 걸려 막힌 것이면 이 검사를 확인한 게 아닙니다.
        if guarded.first?.blocked == true, guarded.first?.blockReason == L("git이 추적하는 소스", "Tracked by git") {
            passed += 1
            print("  \(Ansi.green)통과\(Ansi.reset)  룰은 \(decision.rule?.id ?? "-")(allow)로 봤지만 안전장치가 막았습니다")
            print("        \(Ansi.dim)\(guarded.first?.blockReason ?? "")\(Ansi.reset)")
        } else {
            failed += 1
            print("  \(Ansi.red)실패\(Ansi.reset)  git이 추적하는 build를 막지 못했습니다")
        }
    } else {
        failed += 1
        print("  \(Ansi.red)실패\(Ansi.reset)  검사용 임시 저장소를 만들지 못했습니다")
    }

    // 자기 자신 보호. 실행 파일이 든 디렉터리를 후보로 올리면 반드시 막혀야 합니다.
    // 경로를 박아두지 않고 실행 파일 위치에서 끌어내야 어디에 설치돼도 검증이 성립합니다.
    let selfDir = (SafetyGuards.selfExecutablePath as NSString).deletingLastPathComponent
    if !selfDir.isEmpty {
        let candidate = Candidate(path: selfDir, ruleID: "swift-build",
                                  category: .projectOutput, cost: .quick,
                                  display: SweepScanner.abbreviate(selfDir))
        let guarded = await SafetyGuards().apply(to: [candidate])
        if guarded.first?.blocked == true,
           guarded.first?.blockReason == L("실행 중인 Sweep이 들어 있음", "Contains the running Sweep") {
            passed += 1
            print("  \(Ansi.green)통과\(Ansi.reset)  실행 중인 자기 자신을 막았습니다")
            print("        \(Ansi.dim)\(guarded.first?.blockReason ?? "")\(Ansi.reset)  \(SweepScanner.abbreviate(selfDir))")
        } else {
            failed += 1
            print("  \(Ansi.red)실패\(Ansi.reset)  실행 중인 자기 자신을 막지 못했습니다  \(SweepScanner.abbreviate(selfDir))")
        }
    }

    print("")
    print("  \(Ansi.bold)룰 덧씌우기 검증\(Ansi.reset)")
    print("")

    func check(_ description: String, _ condition: Bool) {
        if condition {
            passed += 1
            print("  \(Ansi.green)통과\(Ansi.reset)  \(Ansi.dim)\(description)\(Ansi.reset)")
        } else {
            failed += 1
            print("  \(Ansi.red)실패\(Ansi.reset)  \(description)")
        }
    }

    let overlay = RuleOverlay(disabledRuleIDs: ["generic-build"],
                              excludedPaths: ["~/Projects/verify-excluded"])
    let overlaid = RuleEngine(ruleSet: overlay.apply(to: DefaultRuleSet.ruleSet))

    // 끈 룰은 판정에서 아예 빠져야 합니다.
    let disabledPath = SweepScanner.expand("~/Projects/verify-sample/build")
    check("끈 룰 generic-build는 더 이상 잡지 않습니다",
          overlaid.decide(disabledPath).rule?.id != "generic-build")

    // 제외 경로는 무엇보다 먼저 이겨야 합니다.
    let excludedPath = SweepScanner.expand("~/Projects/verify-excluded/sub/build")
    let excludedDecision = overlaid.decide(excludedPath)
    check("제외한 경로 아래는 deny로 막힙니다",
          excludedDecision.isDenied && excludedDecision.rule?.id == "user-exclude-0")

    // 덧씌우기가 비면 기본 룰이 그대로여야 합니다.
    check("빈 덧씌우기는 룰을 바꾸지 않습니다",
          RuleOverlay.empty.apply(to: DefaultRuleSet.ruleSet).rules.count == DefaultRuleSet.rules.count)

    // 검사할 폴더는 사람마다 달라서 코드에 박아두지 않습니다. 등록하면 루트로 들어가야 합니다.
    let rooted = RuleOverlay(projectRoots: ["~/verify-root"]).apply(to: DefaultRuleSet.ruleSet)
    check("등록한 검사 폴더가 스캔 루트에 들어갑니다",
          rooted.roots.contains { $0.path == "~/verify-root" && $0.mode == .walk })
    check("기본 루트에는 프로젝트 폴더가 박혀 있지 않습니다",
          !DefaultRuleSet.roots.contains { $0.mode == .walk })

    // 예전 룰 파일에 프로젝트 폴더가 루트로 박혀 있으면 자동 감지분과 겹칩니다.
    // 그대로 두면 같은 폴더를 두 번 걸어 스캔이 두 배로 늘어납니다.
    let legacy = RuleSet(version: 1,
                         roots: DefaultRuleSet.roots + [ScanRoot(path: "~/Projects", mode: .walk)],
                         dirNames: DefaultRuleSet.dirNames, rules: DefaultRuleSet.rules)
    let merged = RuleOverlay(projectRoots: ["~/Projects"]).apply(to: legacy)
    check("겹치는 검사 폴더는 한 번만 훑습니다",
          merged.roots.filter { RuleOverlay.normalize($0.path).hasSuffix("/Projects") }.count == 1)
    check("검사 폴더 안에 든 검사 폴더는 뺍니다",
          RuleOverlay.deduped([ScanRoot(path: "~/Projects", mode: .walk),
                               ScanRoot(path: "~/Projects/inner", mode: .walk)]).count == 1)

    // 예전에 내보낸 룰 파일에는 나중에 추가된 필수 deny가 없습니다. 그래도 걸려야 합니다.
    let stale = RuleSet(version: 1, roots: DefaultRuleSet.roots, dirNames: DefaultRuleSet.dirNames,
                        rules: DefaultRuleSet.rules.filter { $0.id != "apple-system-cache" })
    let repaired = RuleEngine(ruleSet: RuleEngine.withMandatoryDenies(stale))
    let musicCache = SweepScanner.expand("~/Library/Caches/com.apple.Music")
    check("필수 deny가 빠진 룰셋에도 다시 얹힙니다",
          repaired.decide(musicCache).rule?.id == "apple-system-cache")

    // 내보낸 뒤 손대지 않은 룰 파일이 기본 룰을 가리면 안 됩니다.
    // 그대로 두면 파일이 생긴 순간의 룰에 영영 묶입니다.
    let live = RuleOverlay.load()
    if let data = try? Data(contentsOf: RuleEngine.userRulesURL) {
        if let exported = live.exportedRulesDigest, RuleEngine.digest(of: data) == exported {
            check("내보낸 그대로인 룰 파일은 기본 룰을 가리지 않습니다",
                  RuleEngine.loadBaseRuleSet(overlay: live).rules.count == DefaultRuleSet.rules.count)
        } else {
            print("  \(Ansi.dim)건너뜀\(Ansi.reset)  룰 파일이 편집됐거나 지문이 없어 비교하지 않습니다")
            print("  \(Ansi.yellow)참고\(Ansi.reset)  이 파일이 기본 룰을 가리고 있습니다: \(SweepScanner.abbreviate(RuleEngine.userRulesURL.path))")
        }
    } else {
        print("  \(Ansi.dim)건너뜀\(Ansi.reset)  룰 파일이 없습니다")
    }

    // 중첩된 node_modules는 바깥 것에 포함되므로 따로 후보가 되면 안 됩니다.
    check("중첩된 node_modules는 따로 잡지 않습니다",
          engine.decide(SweepScanner.expand("~/Projects/node-app/node_modules/expo/node_modules")).rule?.id != "node-modules")

    await runWorkingProjectChecks(check: check)

    print("")
    print("  \(Ansi.bold)저용량 알림과 도구 출력 검증\(Ansi.reset)")
    print("")
    // 임계치 아래로 내려간 순간 한 번만 알리고, 충분히 회복한 뒤에야 다시 알립니다.
    let gb: Int64 = 1024 * 1024 * 1024
    let total = 500 * gb
    let first = LowDiskAlert.evaluate(free: 40 * gb, total: total, alerted: false)
    let again = LowDiskAlert.evaluate(free: 35 * gb, total: total, alerted: first.alerted)
    let edge = LowDiskAlert.evaluate(free: 60 * gb, total: total, alerted: again.alerted)
    let recovered = LowDiskAlert.evaluate(free: 100 * gb, total: total, alerted: edge.alerted)
    let next = LowDiskAlert.evaluate(free: 45 * gb, total: total, alerted: recovered.alerted)
    check("여유가 10% 아래로 내려가면 한 번 알립니다", first.notify && first.alerted)
    check("아래에 머무는 동안은 다시 알리지 않습니다", !again.notify)
    check("경계(10~15%)에서는 상태를 유지합니다", !edge.notify && edge.alerted)
    check("15% 이상으로 회복한 뒤 다시 내려가면 또 알립니다", !recovered.alerted && next.notify)
    // 큰 디스크는 10%가 수백 GB라 비율만으로는 늦습니다. 10GB 아래도 부족으로 봅니다.
    let big = LowDiskAlert.evaluate(free: 8 * gb, total: 8 * 1024 * gb, alerted: false)
    check("비율이 넉넉해도 10GB 아래면 알립니다", big.notify)

    let dockerSample = #"""
    {"Active":"10","Reclaimable":"10.5GB (67%)","Size":"15.49GB","TotalCount":"41","Type":"Images"}
    {"Active":"0","Reclaimable":"881.5MB","Size":"5.101GB","TotalCount":"152","Type":"Build Cache"}
    """#
    let parsed = InsightScanner.parseDockerDF(dockerSample)
    check("docker system df 출력에서 build cache 회수량을 읽습니다",
          parsed.first { $0.type == "Build Cache" }?.reclaimable == "881.5MB")
    check("비율이 붙은 회수량은 크기만 남깁니다",
          parsed.first { $0.type == "Images" }?.reclaimable == "10.5GB")

    print("")
    print("  \(Ansi.bold)선택 정책 검증\(Ansi.reset)")
    print("")

    // 합성 후보로 유휴일 판정만 떼어 확인합니다. 실제 파일에 기대면 그 파일의
    // 수정 시각에 따라 결과가 흔들려서 회귀 검사가 되지 않습니다.
    func policyCase(_ level: SelectionPolicy.Level, _ category: SweepCategory,
                    idle: Int, safetyOff: Bool = false, manualOnly: Bool = false, expected: Bool) {
        var candidate = Candidate(path: "/verify/policy", ruleID: "verify",
                                  category: category, cost: .instant,
                                  display: "verify", bytes: 1)
        // 경계에서 반올림에 걸리지 않도록 한 시간을 더 빼둡니다.
        candidate.lastModified = Date().addingTimeInterval(-(Double(idle) * 86_400 + 3_600))
        candidate.deselectedBySafety = safetyOff
        candidate.manualSelectOnly = manualOnly
        let got = level.policy.selects(candidate)
        let note = safetyOff ? ", 안전장치가 내림" : manualOnly ? ", 직접 고르는 룰" : ""
        let describe = "\(level.label)  \(category.label) \(idle)일 방치\(note) → \(expected ? "선택" : "해제")"
        if got == expected {
            passed += 1
            print("  \(Ansi.green)통과\(Ansi.reset)  \(Ansi.dim)\(describe)\(Ansi.reset)")
        } else {
            failed += 1
            print("  \(Ansi.red)실패\(Ansi.reset)  \(describe), 실제로는 \(got ? "선택" : "해제")")
        }
    }

    policyCase(.balanced, .projectOutput, idle: 10, expected: true)
    policyCase(.balanced, .projectOutput, idle: 3, expected: false)
    policyCase(.balanced, .toolchainCache, idle: 100, expected: true)
    policyCase(.balanced, .toolchainCache, idle: 30, expected: false)
    policyCase(.balanced, .appCache, idle: 400, expected: false)
    policyCase(.balanced, .toolchainCache, idle: 400, safetyOff: true, expected: false)
    policyCase(.safe, .toolchainCache, idle: 400, expected: false)
    policyCase(.aggressive, .appCache, idle: 100, expected: true)
    policyCase(.aggressive, .projectOutput, idle: 0, expected: true)
    // dist와 Pods는 손으로 관리하는 폴더일 수 있어 어느 단계에서도 미리 체크하지 않습니다.
    policyCase(.aggressive, .projectOutput, idle: 100, manualOnly: true, expected: false)

    print("")
    let summary = failed == 0
        ? "\(Ansi.green)전부 통과 (\(passed)건)\(Ansi.reset)"
        : "\(Ansi.red)\(failed)건 실패\(Ansi.reset), \(passed)건 통과"
    print("  \(summary)")
    print("")
    if failed > 0 { exit(1) }
}

// MARK: - 작업 중인 프로젝트와 node_modules 검증

/// 임시 저장소로 안전장치를 끝까지 재현합니다.
///
/// 모양은 `<검사 폴더>/group/app`입니다. app은 200일 전에 커밋한 저장소이고, 안에
/// node_modules와 그 안의 RN android/build가 있습니다. 실제 프로젝트를 건드리지 않으려고
/// 검사 폴더를 Sweep 데이터 폴더 아래에 따로 만들고, 그 폴더만 훑는 룰셋으로 스캔합니다.
func runWorkingProjectChecks(check: (String, Bool) -> Void) async {
    print("")
    print("  \(Ansi.bold)작업 중인 프로젝트 검증\(Ansi.reset)")
    print("")

    let fm = FileManager.default
    let container = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sweep/verify-work-\(ProcessInfo.processInfo.processIdentifier)")
        .resolvingSymlinksInPath()
    let group = container.appendingPathComponent("group")
    let app = group.appendingPathComponent("app")
    let nodeModules = app.appendingPathComponent("node_modules")
    let rnBuild = nodeModules.appendingPathComponent("rn-lib/android/build")
    defer { try? fm.removeItem(at: container) }

    guard let gitPath = ["/usr/bin/git", "/opt/homebrew/bin/git"].first(where: { fm.isExecutableFile(atPath: $0) }) else {
        check("검사용 git을 찾지 못했습니다", false)
        return
    }
    let old = Date().addingTimeInterval(-200 * 86_400)
    @discardableResult
    func git(_ args: [String], date: Date? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-c", "user.name=sweep", "-c", "user.email=sweep@localhost",
                             "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = app
        if let date {
            let stamp = "@\(Int(date.timeIntervalSince1970)) +0000"
            process.environment = ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    func write(_ text: String, _ name: String) {
        try? text.write(to: app.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    /// 최소 후보 크기(1MB)를 넘기려고 2MB짜리 파일을 둡니다.
    func blob(_ url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(count: 2 * 1024 * 1024))
    }
    /// 오래 방치한 것처럼 수정 시각을 되돌립니다. 선택 정책이 유휴일로 고르기 때문입니다.
    func age(_ url: URL) {
        let items = (fm.enumerator(atPath: url.path)?.allObjects as? [String]) ?? []
        for item in items + [""] {
            let path = item.isEmpty ? url.path : url.appendingPathComponent(item).path
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
    }

    do {
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
    } catch {
        check("임시 저장소를 만들지 못했습니다", false)
        return
    }
    write("{\"name\":\"app\"}\n", "package.json")
    write("{\"lockfileVersion\":3}\n", "package-lock.json")
    write("node_modules/\n", ".gitignore")
    blob(nodeModules.appendingPathComponent("pkg/index.js"))
    blob(rnBuild.appendingPathComponent("out.bin"))
    // 하나는 바깥 파일과 링크를 공유하고, 하나는 두 링크가 모두 node_modules 안에 있습니다.
    let outside = container.appendingPathComponent("outside.bin")
    blob(outside)
    try? fm.linkItem(at: outside, to: nodeModules.appendingPathComponent("pkg/shared.bin"))
    blob(nodeModules.appendingPathComponent("pkg/inner-a.bin"))
    try? fm.linkItem(at: nodeModules.appendingPathComponent("pkg/inner-a.bin"),
                     to: nodeModules.appendingPathComponent("pkg/inner-b.bin"))
    age(nodeModules)
    guard git(["init", "--quiet"]), git(["add", "."]),
          git(["commit", "--quiet", "-m", "fixture"], date: old) else {
        check("임시 저장소에 커밋하지 못했습니다", false)
        return
    }

    let ruleSet = RuleSet(version: 1, roots: [ScanRoot(path: container.path, mode: .walk)],
                          dirNames: DefaultRuleSet.dirNames, rules: DefaultRuleSet.rules)
    func scan() async -> [Candidate] {
        await SweepScanner(engine: RuleEngine(ruleSet: ruleSet), policy: .balanced).scan().candidates
    }
    func find(_ list: [Candidate], _ url: URL) -> Candidate? { list.first { $0.path == url.path } }
    /// 작업 폴더를 지정해 sleep을 띄웁니다. 개발 서버나 에이전트 세션을 흉내 냅니다.
    func spawn(in directory: URL) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.currentDirectoryURL = directory
        do { try process.run() } catch { return nil }
        return process
    }
    func stop(_ process: Process?) {
        process?.terminate()
        process?.waitUntilExit()
    }

    // 1. 아무것도 돌지 않는 오래된 프로젝트
    let idle = await scan()
    let modules = find(idle, nodeModules)
    let inner = find(idle, rnBuild)
    check("오래된 프로젝트의 node_modules를 후보로 올리고 미리 체크합니다",
          modules?.isDeletable == true && modules?.defaultSelected == true)
    check("node_modules 안의 RN android/build도 따로 남깁니다", inner?.isDeletable == true)
    if let modules, let inner {
        let merged = Candidate.withoutNested([modules, inner])
        check("둘을 함께 고르면 바깥만 남겨 두 번 세지 않습니다",
              merged.count == 1 && merged.first?.path == modules.path)
    }
    // 바깥과 공유하는 2MB만 공유로 잡혀야 합니다. 안쪽끼리 링크된 파일은 한 번만 세고 공유가 아닙니다.
    let shared = modules?.sharedBytes ?? 0
    check("바깥과 하드링크를 공유하는 몫만 따로 셉니다",
          shared >= 2 * 1024 * 1024 && shared < 4 * 1024 * 1024)

    // 바깥과 안쪽을 함께 넘겨도 바깥 하나만 처리합니다. 안쪽을 따로 지우려다 "이미 없는 경로"로 실패하지 않습니다.
    if let modules, let inner {
        let outcome = Sweeper().sweep([inner, modules], dryRun: true)
        check("삭제할 때도 바깥 후보 하나만 처리합니다",
              outcome.deleted.map(\.path) == [modules.path] && outcome.refused.isEmpty)
    }

    // 2. 프로젝트 안에서 프로세스가 돌 때
    var process = spawn(in: app)
    let busy = await scan()
    let busyReason = find(busy, nodeModules)?.blockReason ?? ""
    check("프로젝트 안에서 프로세스가 돌면 막습니다 (\(busyReason))",
          find(busy, nodeModules)?.blocked == true && busyReason.contains("sleep"))
    check("같은 프로젝트의 다른 산출물도 막습니다",
          find(busy, rnBuild)?.blockReason?.contains("sleep") == true)
    // 스캔 때는 비어 있던 프로젝트라도 지우기 직전에 다시 봅니다.
    if let modules {
        let outcome = Sweeper().sweep([modules], dryRun: true)
        check("스캔 뒤에 띄운 프로세스도 삭제 직전에 막습니다",
              outcome.deleted.isEmpty && outcome.refused.first?.reason.contains("sleep") == true)
    }
    stop(process)

    // 3. 프로젝트의 상위 폴더에서 도는 프로세스. 여러 저장소를 함께 다루는 세션이 이렇습니다.
    process = spawn(in: group)
    check("검사 폴더보다 깊은 상위 폴더에서 돌면 막습니다",
          find(await scan(), nodeModules)?.blockReason?.contains("sleep") == true)
    stop(process)

    // 3-1. 작업 폴더는 다른 곳인데 그 프로젝트의 파일을 실행하는 프로세스. 절대 경로로 띄운 MCP 서버가 이렇습니다.
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/bin/sh")
    // 명령이 하나뿐이면 sh가 sleep으로 바뀌어 인수가 사라집니다. 두 개로 둬서 sh가 남게 합니다.
    script.arguments = ["-c", "sleep 60; true", app.appendingPathComponent("server.js").path]
    script.currentDirectoryURL = fm.homeDirectoryForCurrentUser
    try? script.run()
    check("커맨드라인에 프로젝트 경로가 든 프로세스도 막습니다",
          find(await scan(), nodeModules)?.blockReason?.contains("sh") == true)
    stop(script)

    // 4. 검사 폴더 자체에서 도는 프로세스는 아래 전체를 쓰는 게 아닙니다.
    process = spawn(in: container)
    check("검사 폴더 자체에서 도는 프로세스로는 막지 않습니다",
          find(await scan(), nodeModules)?.blocked == false)
    stop(process)

    // 5. 사설 registry. scope registry는 그 scope의 패키지를 실제로 쓸 때만 칩니다.
    write("@corp:registry=https://npm.corp.example/\n", ".npmrc")
    let unusedScope = find(await scan(), nodeModules)
    check("쓰지 않는 scope의 registry는 사설 registry로 보지 않습니다",
          unusedScope?.defaultSelected == true)
    write("{\"name\":\"app\",\"dependencies\":{\"@corp/ui\":\"1.0.0\"}}\n", "package.json")
    let privateRegistry = find(await scan(), nodeModules)
    check("사설 registry의 패키지를 쓰면 미리 체크하지 않습니다",
          privateRegistry?.defaultSelected == false
          && privateRegistry?.warnings.contains { $0.contains("registry") } == true)
    try? fm.removeItem(at: app.appendingPathComponent(".npmrc"))
    git(["checkout", "--quiet", "--", "package.json"])

    // 6. lockfile 없음
    try? fm.removeItem(at: app.appendingPathComponent("package-lock.json"))
    let noLock = find(await scan(), nodeModules)
    check("lockfile이 없으면 미리 체크하지 않습니다",
          noLock?.defaultSelected == false && noLock?.warnings.contains { $0.contains("lockfile") } == true)
    git(["checkout", "--quiet", "--", "package-lock.json"])

    // 7. 최근 커밋
    git(["commit", "--quiet", "--allow-empty", "-m", "recent"])
    let recent = find(await scan(), nodeModules)
    check("최근에 커밋한 프로젝트는 미리 체크하지 않습니다",
          recent?.isDeletable == true && recent?.defaultSelected == false)

    // 저장소 밖에서도 node_modules 안의 후보는 바깥 node_modules를 품은 폴더를 프로젝트로 봅니다.
    check("저장소 밖 node_modules 안 후보의 프로젝트는 node_modules를 품은 폴더입니다",
          SafetyGuards.projectDirectory(for: "/opt/verify/app/node_modules/rn/android/build") == "/opt/verify/app")

    // 8. Xcode 기기 지원 파일은 플랫폼마다 가장 최신 버전을 남깁니다. 경로는 없어도 됩니다.
    let base = SweepScanner.expand("~/Library/Developer/Xcode/iOS DeviceSupport/")
    let versions = ["16.4 (20E247)", "iPhone15,2 17.0 (21A329)", "17.5 (21F79)"].map {
        Candidate(path: base + $0, ruleID: "xcode-device-support", category: .toolchainCache,
                  cost: .slow, display: $0, bytes: 1)
    }
    let guarded = await SafetyGuards(ruleSet: DefaultRuleSet.ruleSet).apply(to: versions)
    check("기기 지원 파일은 가장 최신 버전만 미리 체크에서 뺍니다",
          guarded.filter(\.deselectedBySafety).map(\.display) == ["17.5 (21F79)"])
}

func runClean() async {
    let scanner = SweepScanner()
    FileHandle.standardError.write("스캔 중...\n".data(using: .utf8)!)
    let result = await scanner.scan()

    var targets: [Candidate] = []
    // 번호는 스캔할 때마다 바뀔 수 있습니다. 미리보기와 실제 삭제 사이에 후보가 하나만
    // 늘어도 다른 항목을 지웁니다. 스크립트에서는 경로로 고르는 쪽이 안전합니다.
    let paths = values(for: "--path")
    if !paths.isEmpty {
        let wanted = Set(paths)
        targets = result.candidates.filter { wanted.contains($0.path) && $0.isDeletable }
        let found = Set(targets.map(\.path))
        for path in paths where !found.contains(path) {
            print("  \(Ansi.yellow)후보가 아니거나 지울 수 없는 경로입니다: \(SweepScanner.abbreviate(path))\(Ansi.reset)")
        }
    } else if let ruleID = value(for: "--rule") {
        targets = result.candidates.filter { $0.ruleID == ruleID && $0.isDeletable }
    } else if let list = value(for: "--index") {
        let wanted = Set(list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        targets = orderedCandidates(result).enumerated()
            .filter { wanted.contains($0.offset + 1) }
            .map { $0.element }
            .filter { $0.isDeletable }
    } else {
        targets = result.candidates.filter { $0.defaultSelected && $0.isDeletable }
    }

    // 제외한 경로와 그 아래는 빼고, 겹친 후보는 바깥만 남깁니다.
    let excluded = values(for: "--exclude")
    targets = Candidate.withoutNested(targets.filter { target in
        !excluded.contains { target.path == $0 || target.path.hasPrefix($0 + "/") }
    })

    guard !targets.isEmpty else {
        print("삭제할 대상이 없습니다.")
        return
    }

    let total = targets.reduce(Int64(0)) { $0 + $1.bytes }
    print("")
    for target in targets {
        print("  \(Format.bytes(target.bytes).leftPadded(to: 8))  \(SweepScanner.abbreviate(target.path))")
    }
    print("")
    print("  합계 \(Ansi.bold)\(Format.bytes(total))\(Ansi.reset), \(targets.count)개")
    print("")

    let dryRun = flags.contains("--dry-run") || !flags.contains("--yes")
    if dryRun {
        print("  \(Ansi.yellow)미리보기입니다. 실제로 지우려면 --yes 를 붙이세요.\(Ansi.reset)")
        print("")
        return
    }

    let outcome = Sweeper().sweep(targets)
    print("  \(Ansi.green)\(Format.bytes(outcome.reclaimedBytes)) 회수\(Ansi.reset), \(outcome.deleted.count)개 삭제")
    // 하드링크 공유나 다른 프로그램의 쓰기 때문에 회수량과 다를 수 있습니다. 참고값으로만 보여 줍니다.
    if let before = outcome.freeBefore, let after = outcome.freeAfter {
        let delta = after - before
        print("  \(Ansi.dim)남은 공간 \(delta >= 0 ? "+" : "-")\(Format.bytes(abs(delta))) (다른 프로그램도 디스크를 쓰므로 참고값)\(Ansi.reset)")
    }
    if !outcome.failed.isEmpty {
        print("  \(Ansi.red)실패 \(outcome.failed.count)개\(Ansi.reset)")
        for (candidate, error) in outcome.failed {
            print("    \(SweepScanner.abbreviate(candidate.path)): \(error)")
        }
    }
    if !outcome.refused.isEmpty {
        print("  \(Ansi.yellow)거부 \(outcome.refused.count)개\(Ansi.reset)")
        for (candidate, reason) in outcome.refused {
            print("    \(SweepScanner.abbreviate(candidate.path)): \(reason)")
        }
    }
    print("")
}

// MARK: - 지우지 않는 큰 항목

func runReport() {
    let insights = InsightScanner.scan(includeDownloads: flags.contains("--downloads"))
    print("")
    print("  \(Ansi.bold)지우지 않는 큰 항목\(Ansi.reset)  \(Ansi.dim)Sweep이 지우지 않고 줄이는 방법만 알려 줍니다\(Ansi.reset)")
    print("")
    guard !insights.isEmpty else {
        print("  \(Ansi.dim)눈에 띄게 큰 항목이 없습니다\(Ansi.reset)")
        print("")
        return
    }
    for insight in insights {
        let size = insight.bytes.map(Format.bytes) ?? "-"
        print("  \(size.leftPadded(to: 8))  \(Ansi.bold)\(insight.title)\(Ansi.reset)")
        if let path = insight.path { print("            \(Ansi.dim)\(SweepScanner.abbreviate(path))\(Ansi.reset)") }
        print("            \(insight.detail)")
        if let action = insight.action {
            print("            \(Ansi.cyan)sweep run \(action.id)\(Ansi.reset)  \(Ansi.dim)\(action.commandLine)\(Ansi.reset)")
        }
        print("")
    }
}

func runAction() {
    guard arguments.count >= 2, let id = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
        print("실행할 정리 명령을 지정하세요. sweep report에 나온 이름을 씁니다.")
        exit(1)
    }
    guard let action = InsightScanner.scan().compactMap(\.action).first(where: { $0.id == id }) else {
        print("지금 실행할 수 없는 명령입니다: \(id)")
        print("\(Ansi.dim)sweep report에 나온 명령만 실행합니다. Docker 정리는 Docker가 켜져 있어야 합니다.\(Ansi.reset)")
        exit(1)
    }
    print("")
    print("  \(action.title)  \(Ansi.dim)\(action.commandLine)\(Ansi.reset)")
    guard flags.contains("--yes") else {
        print("  \(Ansi.yellow)미리보기입니다. 실행하려면 --yes 를 붙이세요.\(Ansi.reset)")
        print("")
        return
    }
    let result = InsightScanner.run(action)
    print(result.output.split(separator: "\n").suffix(5).map { "    " + $0 }.joined(separator: "\n"))
    print(result.succeeded ? "  \(Ansi.green)완료\(Ansi.reset)" : "  \(Ansi.red)실패\(Ansi.reset)")
    print("")
}

func runRules() {
    if flags.contains("--export") {
        if let data = try? RuleEngine.exportDefaults(), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }
    let engine = RuleEngine()
    print("")
    print("  룰 \(engine.ruleSet.rules.count)개, 스캔 시작점 \(engine.ruleSet.roots.count)곳")
    print("  \(Ansi.dim)사용자 룰: \(SweepScanner.abbreviate(RuleEngine.userRulesURL.path))\(Ansi.reset)")
    print("")
    for rule in engine.ruleSet.rules.sorted(by: { $0.priority > $1.priority }) {
        let kind = rule.kind == .allow ? "\(Ansi.green)allow\(Ansi.reset)" : "\(Ansi.red)deny \(Ansi.reset)"
        print("  \(String(rule.priority).leftPadded(to: 4))  \(kind)  \(Ansi.bold)\(rule.id)\(Ansi.reset)")
        print("        \(Ansi.dim)\(rule.regex)\(Ansi.reset)")
        if let note = rule.note { print("        \(Ansi.dim)\(note)\(Ansi.reset)") }
    }
    print("")
}

func runHistory() {
    let total = Sweeper.totalReclaimed()
    print("")
    print("  누적 회수 \(Ansi.bold)\(Format.bytes(total))\(Ansi.reset)")
    print("  \(Ansi.dim)\(SweepScanner.abbreviate(Sweeper.historyURL.path))\(Ansi.reset)")
    print("")
}

func usage() {
    print("""

      sweep - 빌드 산출물과 캐시 정리

      사용법
        sweep scan [--json]        후보 목록을 봅니다 (기본)
        sweep clean                기본 선택 항목을 미리 봅니다
        sweep clean --yes          실제로 지웁니다
        sweep clean --path <경로>  경로로 골라서 (여러 번, 쉼표 가능)
        sweep clean --rule <id>    특정 룰에 걸린 것만
        sweep clean --index 1,3,5  번호로 골라서
        sweep clean --exclude <경로>  고른 것 중 이 경로 아래는 빼고
        sweep report [--downloads] 지우지 않는 큰 항목과 줄이는 방법
        sweep run <명령> [--yes]   report에 나온 도구 정리 명령을 실행합니다
        sweep verify               룰 판정과 안전장치를 검증합니다
        sweep rules [--export]     룰 목록 / JSON 내보내기
        sweep history              누적 회수량
        sweep roots                처음 실행할 때 제안할 프로젝트 폴더

    """)
}

switch command {
case "scan":    await runScan()
case "clean":   await runClean()
case "verify":  await runVerify()
case "rules":   runRules()
case "report":  runReport()
case "run":     runAction()
case "history": runHistory()
case "roots":
    let started = Date()
    // --home은 가짜 홈 폴더로 찾는 규칙을 시험할 때 씁니다.
    let home = value(for: "--home").map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    ProjectRootFinder.discover(home: home).forEach { print($0) }
    FileHandle.standardError.write(String(format: "%.2f초\n", Date().timeIntervalSince(started)).data(using: .utf8)!)
case "help", "-h", "--help": usage()
default:
    print("알 수 없는 명령입니다: \(command)")
    usage()
    exit(1)
}
