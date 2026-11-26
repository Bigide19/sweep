import Foundation

public struct ScanOptions: Sendable {
    /// 이 크기보다 작은 후보는 목록에서 뺍니다. 0.1MB짜리 수십 개는 노이즈일 뿐입니다.
    public var minCandidateBytes: Int64
    /// 성격을 모르는 항목은 이 크기 이상일 때만 보여줍니다.
    public var minUnclassifiedBytes: Int64
    public var includeUnclassified: Bool
    /// walk 모드의 기본 깊이 한계입니다.
    public var defaultMaxDepth: Int

    public init(minCandidateBytes: Int64 = 1 * 1024 * 1024,
                minUnclassifiedBytes: Int64 = 50 * 1024 * 1024,
                includeUnclassified: Bool = true,
                defaultMaxDepth: Int = 12) {
        self.minCandidateBytes = minCandidateBytes
        self.minUnclassifiedBytes = minUnclassifiedBytes
        self.includeUnclassified = includeUnclassified
        self.defaultMaxDepth = defaultMaxDepth
    }

    public static let `default` = ScanOptions()
}

public final class SweepScanner: @unchecked Sendable {
    private let engine: RuleEngine
    private let options: ScanOptions
    private let policy: SelectionPolicy

    public init(engine: RuleEngine = RuleEngine(),
                options: ScanOptions = .default,
                policy: SelectionPolicy = .balanced) {
        self.engine = engine
        self.options = options
        self.policy = policy
    }

    /// 룰에 걸린 경로와 그 판정을 담는 중간 결과입니다.
    private struct Raw {
        let path: String
        let rule: Rule?
        let unclassified: Bool
    }

    // MARK: - 진입점

    public func scan(progress: (@Sendable (String) -> Void)? = nil) async -> ScanResult {
        let started = Date()
        var raws: [Raw] = []
        var gradleOwners: [String: Set<String>] = [:]
        var skipped: [String] = []
        var deniedCounts: [String: Int] = [:]

        for root in engine.ruleSet.roots {
            let path = Self.expand(root.path)
            progress?(Self.abbreviate(path))
            guard FileManager.default.fileExists(atPath: path) else { continue }

            switch root.mode {
            case .walk:
                walk(path,
                     remainingDepth: root.maxDepth ?? options.defaultMaxDepth,
                     raws: &raws, gradleOwners: &gradleOwners, skipped: &skipped,
                     deniedCounts: &deniedCounts)
            case .children:
                collectChildren(path, raws: &raws, skipped: &skipped, deniedCounts: &deniedCounts)
            case .leaf:
                let decision = engine.decide(path)
                if decision.isAllowed {
                    raws.append(Raw(path: path, rule: decision.rule, unclassified: false))
                } else if decision.isDenied, let id = decision.rule?.id {
                    deniedCounts[id, default: 0] += 1
                }
            }
        }

        // 크기 계산이 스캔 시간의 대부분입니다. 후보별로 독립이라 병렬로 돌립니다.
        var candidates = await measureAll(raws, progress: progress)

        // 안전장치를 붙입니다. 여기서 blocked가 결정됩니다.
        let owners = gradleOwners.mapValues { Array($0).sorted() }
        let guards = SafetyGuards(gradleOwners: owners, ruleSet: engine.ruleSet)
        candidates = await guards.apply(to: candidates)

        // 무엇을 체크해둘지는 안전장치가 끝난 뒤에 정합니다. 잠긴 항목과
        // 안전장치가 내려둔 항목을 정책이 다시 올리면 안 되기 때문입니다.
        candidates = policy.apply(to: candidates)

        candidates = filterAndSort(candidates)

        return ScanResult(candidates: candidates,
                          scannedAt: started,
                          duration: Date().timeIntervalSince(started),
                          gradleOwners: owners,
                          skipped: skipped,
                          deniedCounts: deniedCounts)
    }

    // MARK: - walk 모드

    /// 재귀로 내려가며 관심 디렉터리 이름을 만날 때마다 룰로 판정합니다.
    ///
    /// allow든 deny든 판정이 나면 그 아래로는 내려가지 않습니다. allow면 통째로 지울
    /// 대상이라 안을 볼 이유가 없고, deny면 건드리지 않을 영역이기 때문입니다.
    private func walk(_ path: String,
                      remainingDepth: Int,
                      raws: inout [Raw],
                      gradleOwners: inout [String: Set<String>],
                      skipped: inout [String],
                      deniedCounts: inout [String: Int]) {
        guard remainingDepth > 0 else { return }

        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []) else {
            skipped.append(Self.abbreviate(path))
            return
        }

        for entry in entries {
            let name = entry.lastPathComponent
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }

            // 심볼릭 링크를 따라가면 같은 곳을 두 번 세거나 순환에 빠질 수 있습니다.
            if values.isSymbolicLink == true { continue }

            if values.isDirectory != true {
                // Gradle 버전 캐시의 주인을 알아내려면 프로젝트가 어떤 wrapper를 쓰는지
                // 봐야 합니다. 어차피 디렉터리를 훑는 길에 파일 이름도 보이니 여기서 모읍니다.
                if name == "gradle-wrapper.properties" {
                    collectGradleWrapper(entry.path, into: &gradleOwners)
                }
                continue
            }

            if name == ".git" { continue }

            let full = entry.path

            if engine.dirNames.contains(name) {
                let decision = engine.decide(full)
                if decision.isAllowed {
                    raws.append(Raw(path: full, rule: decision.rule, unclassified: false))
                    // node_modules는 후보로 올린 뒤에도 안을 봅니다. 활성 프로젝트라 통째로는
                    // 못 지울 때도 안쪽의 RN android/build는 따로 지울 수 있어야 합니다.
                    // 둘이 겹치는 문제는 합계와 삭제 직전에 Candidate.withoutNested가 풉니다.
                    guard name == "node_modules" else { continue }
                } else if decision.isDenied {
                    if let id = decision.rule?.id { deniedCounts[id, default: 0] += 1 }
                    continue  // 건드리지 않을 영역입니다
                }
                // 어떤 룰에도 안 걸렸으면 평범한 디렉터리로 보고 계속 내려갑니다
            }

            // node_modules 안에도 지울 것이 있습니다. RN 라이브러리의 android/build가
            // 대표적인데, 통째로 건너뛰면 이걸 놓칩니다. 반대로 전부 훑으면 패키지가
            // 수천 개라 느려집니다. 깊이만 짧게 잡아 패키지 바로 아래 몇 단만 봅니다.
            // (@scope/pkg/android/build 가 4단이라 5로 둡니다. 중첩 node_modules를
            //  만나면 여기서 다시 5로 리셋되므로 깊게 중첩돼도 찾아냅니다.)
            let nextDepth = (name == "node_modules") ? 5 : remainingDepth - 1
            walk(full, remainingDepth: nextDepth,
                 raws: &raws, gradleOwners: &gradleOwners, skipped: &skipped,
                 deniedCounts: &deniedCounts)
        }
    }

    private func collectGradleWrapper(_ path: String, into owners: inout [String: Set<String>]) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // distributionUrl=...\://services.gradle.org/distributions/gradle-8.14.3-bin.zip
        guard let range = text.range(of: #"gradle-([0-9]+\.[0-9]+(\.[0-9]+)?)-(bin|all)\.zip"#,
                                     options: .regularExpression) else { return }
        let matched = String(text[range])
        let version = matched
            .replacingOccurrences(of: "gradle-", with: "")
            .replacingOccurrences(of: "-bin.zip", with: "")
            .replacingOccurrences(of: "-all.zip", with: "")
        // 저장소가 아닌 프로젝트도 이 Gradle 버전을 쓰는 건 같습니다. 그때는
        // gradle/wrapper/gradle-wrapper.properties를 품은 폴더를 프로젝트로 봅니다.
        let projectDir = URL(fileURLWithPath: path)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = Self.projectName(for: path) ?? projectDir.lastPathComponent
        owners[version, default: []].insert(project)
    }

    // MARK: - children 모드

    /// 바로 아래 자식만 후보로 판정합니다. ~/Library/Caches처럼 항목마다 성격이
    /// 다른 곳에 씁니다. 화이트리스트에 없으면 성격을 모른다고 표시만 하고 삭제는 막습니다.
    private func collectChildren(_ path: String, raws: inout [Raw], skipped: inout [String],
                                 deniedCounts: inout [String: Int]) {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []) else {
            skipped.append(Self.abbreviate(path))
            return
        }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }

            let decision = engine.decide(entry.path)
            if decision.isDenied {
                if let id = decision.rule?.id { deniedCounts[id, default: 0] += 1 }
                continue
            }
            if decision.isAllowed {
                raws.append(Raw(path: entry.path, rule: decision.rule, unclassified: false))
            } else if options.includeUnclassified {
                raws.append(Raw(path: entry.path, rule: nil, unclassified: true))
            }
        }
    }

    // MARK: - 크기 계산

    private func measureAll(_ raws: [Raw], progress: (@Sendable (String) -> Void)?) async -> [Candidate] {
        guard !raws.isEmpty else { return [] }

        var sizes = [Measured](repeating: Measured(), count: raws.count)
        let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount)
        let paths = raws.map(\.path)

        await withTaskGroup(of: (Int, Measured).self) { group in
            var next = 0
            func addTask(_ index: Int) {
                let path = paths[index]
                group.addTask { (index, SweepScanner.measure(path)) }
            }
            while next < min(concurrency, paths.count) {
                addTask(next); next += 1
            }
            while let (index, measured) = await group.next() {
                sizes[index] = measured
                progress?(Self.abbreviate(paths[index]))
                if next < paths.count {
                    addTask(next); next += 1
                }
            }
        }

        return raws.enumerated().map { index, raw in
            makeCandidate(raw, measured: sizes[index])
        }
    }

    /// 크기를 잰 결과입니다.
    struct Measured: Sendable {
        var bytes: Int64 = 0
        var files = 0
        var newest: Date?
        /// 바깥 경로와 하드링크로 공유하는 파일의 크기입니다.
        var sharedBytes: Int64 = 0
    }

    /// 디렉터리가 실제로 점유한 크기입니다. du와 같은 기준(할당 크기)으로 셉니다.
    ///
    /// 어차피 트리를 전부 훑으므로 가장 최근 수정 시각도 같이 모읍니다. 따로 재면
    /// 같은 트리를 두 번 걷게 되는데, 크기 계산이 스캔 시간의 대부분이라 그건 두 배입니다.
    ///
    /// 하드링크는 따로 다룹니다. 같은 파일이 이 안에 두 번 나오면 du처럼 한 번만 셉니다.
    /// 링크 일부가 이 바깥에 있으면 지워도 디스크가 비지 않으므로 `sharedBytes`로 따로
    /// 모읍니다. 링크 수가 1인 보통 파일은 inode를 보지 않아서 추가 비용이 거의 없습니다.
    static func measure(_ path: String) -> Measured {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .isRegularFileKey, .contentModificationDateKey,
                                         .linkCountKey]
        var bytes: Int64 = 0
        var files = 0
        // inode별로 (이 안에서 본 횟수, 전체 링크 수, 크기)입니다.
        var linked: [UInt64: (seen: Int, links: Int, size: Int64)] = [:]
        // 디렉터리 자신의 시각부터 넣습니다. 안이 비어 있으면 이것만 남습니다.
        var newest = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: []) else {
            return Measured(newest: newest)
        }
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if let modified = values.contentModificationDate, modified > (newest ?? .distantPast) {
                newest = modified
            }
            if let links = values.linkCount, links > 1, let key = inodeKey(item.path) {
                if var entry = linked[key] {
                    // 이 안에서 이미 센 파일입니다. 크기는 다시 더하지 않습니다.
                    entry.seen += 1
                    linked[key] = entry
                    continue
                }
                linked[key] = (1, links, size)
            }
            bytes += size
            files += 1
        }
        let shared = linked.values.reduce(Int64(0)) { sum, entry in
            entry.seen < entry.links ? sum + entry.size : sum
        }
        return Measured(bytes: bytes, files: files, newest: newest, sharedBytes: shared)
    }

    /// 볼륨과 inode를 묶은 키입니다. 후보 하나는 한 볼륨 안에 있지만 마운트 지점이 섞일 수 있어 둘 다 씁니다.
    private static func inodeKey(_ path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (UInt64(UInt32(bitPattern: info.st_dev)) << 40) ^ info.st_ino
    }

    // MARK: - 후보 만들기

    private func makeCandidate(_ raw: Raw, measured: Measured) -> Candidate {
        let project = Self.projectName(for: raw.path)
        let bytes = measured.bytes
        let files = measured.files
        let newest = measured.newest

        if raw.unclassified {
            var c = Candidate(path: raw.path, ruleID: "unclassified",
                              category: .appCache, cost: .download,
                              display: Self.abbreviate(raw.path),
                              bytes: bytes, fileCount: files)
            c.unclassified = true
            c.blockReason = L("Sweep이 모르는 항목", "Unknown to Sweep")
            c.project = project
            c.lastModified = newest
            return c
        }

        guard let rule = raw.rule else {
            var c = Candidate(path: raw.path, ruleID: "unknown",
                              category: .appCache, cost: .download,
                              display: Self.abbreviate(raw.path),
                              bytes: bytes, fileCount: files)
            c.blocked = true
            c.blockReason = L("판정한 룰 없음", "No matching rule")
            c.lastModified = newest
            return c
        }

        var c = Candidate(path: raw.path,
                          ruleID: rule.id,
                          category: rule.category ?? .projectOutput,
                          cost: rule.cost ?? .instant,
                          display: Self.displayName(for: raw.path, project: project),
                          bytes: bytes,
                          fileCount: files)
        c.project = project
        c.title = rule.title
        c.note = rule.note
        c.lastModified = newest
        // 기본 선택은 선택 정책이 정합니다. 다만 프로젝트 산출물 룰이 false로 둔 것은
        // 이름이 모호해서 일부러 내린 값이라 따릅니다. 툴체인과 앱 캐시의 false는 정책이
        // 생기기 전의 값이라 따르면 표준과 최대 단계에서 고를 캐시가 하나도 남지 않습니다.
        c.defaultSelected = false
        c.manualSelectOnly = rule.manualSelectOnly == true
            || (rule.defaultSelected == false && c.category == .projectOutput)
        c.sharedBytes = measured.sharedBytes
        // 작은 공유는 알릴 가치가 없습니다. 눈에 띄는 차이가 날 때만 경고합니다.
        if measured.sharedBytes >= 50 * 1024 * 1024 && measured.sharedBytes * 10 >= bytes {
            c.warnings.append(L("\(Format.bytes(measured.sharedBytes))는 하드링크 공유, 그만큼 덜 빌 수 있음",
                                "\(Format.bytes(measured.sharedBytes)) hard-linked elsewhere, may free less"))
        }
        return c
    }

    private func filterAndSort(_ candidates: [Candidate]) -> [Candidate] {
        candidates
            .filter { c in
                if c.unclassified { return c.bytes >= options.minUnclassifiedBytes }
                return c.bytes >= options.minCandidateBytes
            }
            .sorted { a, b in
                if a.category.order != b.category.order { return a.category.order < b.category.order }
                return a.bytes > b.bytes
            }
    }

    // MARK: - 경로 유틸

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// 홈 경로를 ~로 줄입니다.
    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// 가장 바깥 git 저장소 폴더 이름을 프로젝트 이름으로 봅니다.
    ///
    /// 검사 폴더 바로 아래를 프로젝트로 보면 검사 폴더를 어디로 정했느냐에 따라 이름이
    /// 달라집니다. 저장소는 어디에 두든 같은 단위라 기준으로 삼습니다. 가장 가까운 저장소가
    /// 아니라 바깥 저장소를 쓰는 이유는, 안쪽 저장소가 `vendor/` 아래 받아둔 의존성인
    /// 경우가 많아서입니다. 사용자가 아는 이름은 바깥 프로젝트입니다.
    public static func projectName(for path: String) -> String? {
        outermostGitRoot(for: path).map { ($0 as NSString).lastPathComponent }
    }

    /// 목록에 보여줄 짧은 이름입니다. 프로젝트 기준 상대경로로 줄입니다.
    static func displayName(for path: String, project: String?) -> String {
        guard project != nil, let repo = outermostGitRoot(for: path) else { return abbreviate(path) }
        return SafetyGuards.relative(path, from: repo)
    }

    static func outermostGitRoot(for path: String) -> String? {
        var outermost: String?
        var current = path
        while let repo = SafetyGuards.gitRoot(for: current) {
            outermost = repo
            current = repo
        }
        return outermost
    }
}
