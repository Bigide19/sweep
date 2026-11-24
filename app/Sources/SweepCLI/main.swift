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

        let sum = items.filter { $0.isDeletable }.reduce(Int64(0)) { $0 + $1.bytes }
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
    printResult(result)
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

        // 건드리면 안 되는 것. 아래 셋은 실제로 걸러냈던 함정입니다.
        ("~/Projects/node-app/web/node_modules/next/dist/build", .deny, "node-package-code"),
        ("~/Projects/node-app/web/node_modules/yargs/build", .deny, "node-package-code"),
        ("~/Projects/dotnet-app/AgentApp/packages/Stub.System.Data.SQLite.Core.NetFramework.1.0.119.0/build", .deny, "nuget-package-dir"),
        ("~/Projects/node-app/venv/lib/python3.13/site-packages/pip/_internal/operations/build", .deny, "python-packages"),
        ("~/Library/Android/sdk/build-tools/34.0.0/build", .deny, "android-sdk"),
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
        if guarded.first?.blocked == true {
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
        if guarded.first?.blocked == true {
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

func runClean() async {
    let scanner = SweepScanner()
    FileHandle.standardError.write("스캔 중...\n".data(using: .utf8)!)
    let result = await scanner.scan()

    var targets: [Candidate] = []
    if let ruleID = value(for: "--rule") {
        targets = result.candidates.filter { $0.ruleID == ruleID && $0.isDeletable }
    } else if let list = value(for: "--index") {
        let wanted = Set(list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        let ordered = SweepCategory.allCases.sorted { $0.order < $1.order }
            .flatMap { category in result.candidates.filter { $0.category == category } }
        targets = ordered.enumerated()
            .filter { wanted.contains($0.offset + 1) }
            .map { $0.element }
            .filter { $0.isDeletable }
    } else {
        targets = result.candidates.filter { $0.defaultSelected && $0.isDeletable }
    }

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
        sweep scan                 후보 목록을 봅니다 (기본)
        sweep clean                기본 선택 항목을 미리 봅니다
        sweep clean --yes          실제로 지웁니다
        sweep clean --rule <id>    특정 룰에 걸린 것만
        sweep clean --index 1,3,5  번호로 골라서
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
