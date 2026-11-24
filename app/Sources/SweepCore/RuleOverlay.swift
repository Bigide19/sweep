import Foundation

/// 기본 룰 위에 덧씌우는 사용자 설정입니다.
///
/// 룰 전체를 복사해 파일로 두면 그 순간의 룰에 묶입니다. 이후에 기본 룰이 좋아져도
/// 반영되지 않고, 사용자는 자기가 뭘 고쳤는지도 알기 어렵습니다. 그래서 "무엇을 껐는가"와
/// "어디를 뺐는가"만 저장하고 룰 본체는 계속 기본을 씁니다.
public struct RuleOverlay: Codable, Sendable, Equatable {

    /// 끈 룰의 id입니다. 판정에서 아예 빠집니다.
    public var disabledRuleIDs: Set<String>
    /// 사용자가 손대지 말라고 지정한 경로입니다. 무엇보다 먼저 이깁니다.
    public var excludedPaths: [String]

    /// 프로젝트를 찾을 폴더입니다.
    ///
    /// nil이면 아직 정한 적이 없다는 뜻이라 흔한 개발 폴더를 자동으로 찾아 씁니다.
    /// 사용자가 한 번이라도 손대면 그 목록이 그대로 기록됩니다.
    public var projectRoots: [String]?

    /// Sweep이 룰 파일을 내보낼 때 쓴 내용의 지문입니다.
    ///
    /// 파일이 이 지문 그대로면 사용자가 열어보기만 하고 고치지 않은 것입니다. 그때는
    /// 기본 룰을 계속 씁니다. "지금 기본 룰과 같은가"로 판정하면 안 됩니다. 기본 룰을
    /// 한 줄만 고쳐도 예전에 내보낸 파일이 갑자기 "사용자가 편집한 것"으로 둔갑합니다.
    public var exportedRulesDigest: String?

    public init(disabledRuleIDs: Set<String> = [], excludedPaths: [String] = [],
                projectRoots: [String]? = nil, exportedRulesDigest: String? = nil) {
        self.disabledRuleIDs = disabledRuleIDs
        self.excludedPaths = excludedPaths
        self.projectRoots = projectRoots
        self.exportedRulesDigest = exportedRulesDigest
    }

    /// 실제로 훑을 프로젝트 폴더입니다. 정한 적이 없으면 자동 감지 결과를 씁니다.
    public func resolvedProjectRoots() -> [String] {
        projectRoots ?? DefaultRuleSet.detectedProjectRoots()
    }

    public static let empty = RuleOverlay()

    public var isEmpty: Bool { disabledRuleIDs.isEmpty && excludedPaths.isEmpty }

    // MARK: - 저장

    /// 룰 파일과 나란히 둡니다. CLI와 앱이 같은 설정을 봐야 해서 UserDefaults가 아니라 파일입니다.
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sweep/settings.json")
    }

    public static func load() -> RuleOverlay {
        guard let data = try? Data(contentsOf: url),
              let overlay = try? JSONDecoder().decode(RuleOverlay.self, from: data) else {
            return .empty
        }
        return overlay
    }

    public func save() throws {
        let url = Self.url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url)
    }

    // MARK: - 적용

    /// 제외 경로에 붙이는 우선순위입니다. 기본 룰 중 가장 높은 것(300)보다 위여야
    /// "빼라고 했는데 안 빠지는" 일이 없습니다.
    static let excludePriority = 1000

    public func apply(to base: RuleSet) -> RuleSet {
        var rules = base.rules.filter { !disabledRuleIDs.contains($0.id) }

        // 제외 경로는 그 아래 전부를 덮어야 하므로 접두사 deny로 만듭니다.
        // 경로에 든 문자가 정규식으로 해석되지 않도록 이스케이프합니다.
        for (index, path) in excludedPaths.enumerated() {
            let expanded = (path as NSString).expandingTildeInPath
            rules.append(Rule(id: "user-exclude-\(index)",
                              kind: .deny,
                              priority: Self.excludePriority,
                              regex: "^" + NSRegularExpression.escapedPattern(for: expanded),
                              note: L("사용자가 제외한 경로입니다.", "Excluded by you.")))
        }

        // 프로젝트 폴더는 사람마다 다릅니다. 고정 루트 뒤에 붙입니다.
        let roots = base.roots + resolvedProjectRoots().map { ScanRoot(path: $0, mode: .walk) }

        return RuleSet(version: base.version, roots: Self.deduped(roots),
                       dirNames: base.dirNames, rules: rules)
    }

    /// 같은 곳을 두 번 훑지 않도록 정리합니다.
    ///
    /// 예전에 내보낸 룰 파일에는 프로젝트 폴더가 루트로 박혀 있습니다. 거기에 자동 감지
    /// 결과를 그냥 더하면 같은 폴더를 두 번 걷습니다. 스캔 시간도 후보 용량도 두 배가
    /// 되는데, 화면만 봐서는 왜 그런지 알 수가 없습니다.
    public static func deduped(_ roots: [ScanRoot]) -> [ScanRoot] {
        // 안쪽 폴더가 바깥 폴더보다 먼저 와도 걸러야 해서 walk 루트를 미리 모아 둡니다.
        let walkRoots = roots.filter { $0.mode == .walk }.map { key($0.path) }
        var seen: Set<String> = []
        var result: [ScanRoot] = []

        for root in roots {
            let path = key(root.path)
            guard seen.insert(path).inserted else { continue }
            // walk 루트 안에 또 walk 루트를 두면 겹치는 만큼 두 번 봅니다.
            if root.mode == .walk, walkRoots.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            result.append(root)
        }
        return result
    }

    /// 같은 폴더인지 비교할 때 쓰는 값입니다. 맥 기본 디스크는 대소문자를 가리지 않아서
    /// `~/projects`와 `~/Projects`가 같은 폴더입니다. 둘 다 남으면 같은 곳을 두 번 훑습니다.
    public static func key(_ path: String) -> String {
        normalize(path).lowercased()
    }

    public static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
