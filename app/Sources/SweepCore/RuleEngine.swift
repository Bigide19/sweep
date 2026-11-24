import Foundation
import CryptoKit

/// 룰 판정 결과입니다.
public struct Decision: Sendable {
    public let rule: Rule?
    public var kind: RuleKind? { rule?.kind }
    public var isAllowed: Bool { rule?.kind == .allow }
    public var isDenied: Bool { rule?.kind == .deny }
    /// 어떤 룰에도 안 걸린 상태입니다. walk 모드에서는 계속 내려가고,
    /// children 모드에서는 성격을 모르는 항목으로 표시합니다.
    public var isUnmatched: Bool { rule == nil }
}

/// 경로 하나를 받아 어떤 룰이 이기는지 판정합니다.
public final class RuleEngine: @unchecked Sendable {
    private let compiled: [(rule: Rule, regex: NSRegularExpression)]
    public let ruleSet: RuleSet
    public let dirNames: Set<String>

    public init(ruleSet: RuleSet) {
        self.ruleSet = ruleSet
        self.dirNames = Set(ruleSet.dirNames)

        // 우선순위 내림차순, 같으면 deny를 앞에 둡니다. 첫 매칭이 곧 승자가 되도록
        // 미리 정렬해두면 판정 때 전체를 훑지 않아도 됩니다.
        let sorted = ruleSet.rules.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if a.kind != b.kind { return a.kind == .deny }
            return a.id < b.id
        }
        self.compiled = sorted.compactMap { rule in
            guard let re = try? NSRegularExpression(pattern: rule.regex) else {
                FileHandle.standardError.write(L("룰 \(rule.id)의 정규식을 컴파일할 수 없습니다: \(rule.regex)\n", "Can't compile the regex of rule \(rule.id): \(rule.regex)\n").data(using: .utf8)!)
                return nil
            }
            return (rule, re)
        }
    }

    public convenience init() {
        self.init(ruleSet: RuleEngine.loadRuleSet())
    }

    /// 절대경로에 대해 이기는 룰을 찾습니다.
    public func decide(_ path: String) -> Decision {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        for (rule, regex) in compiled {
            if regex.firstMatch(in: path, options: [], range: range) != nil {
                return Decision(rule: rule)
            }
        }
        return Decision(rule: nil)
    }

    public func rule(id: String) -> Rule? {
        compiled.first { $0.rule.id == id }?.rule
    }

    // MARK: - 룰 로딩

    /// 사용자 룰 파일 위치입니다. 있으면 기본 룰 대신 씁니다.
    public static var userRulesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sweep/rules.json")
    }

    /// 실제로 쓸 룰입니다. 베이스 룰에 사용자 덧씌우기를 적용해 돌려줍니다.
    public static func loadRuleSet(overlay: RuleOverlay? = nil) -> RuleSet {
        let resolved = overlay ?? RuleOverlay.load()
        return withMandatoryDenies(resolved.apply(to: loadBaseRuleSet(overlay: resolved)))
    }

    /// 어떤 룰셋을 쓰든 필수 deny는 반드시 들어갑니다.
    ///
    /// 예전에 내보낸 룰 파일을 쓰고 있으면 그 파일에는 나중에 추가된 필수 deny가 없습니다.
    /// 그대로 두면 훑지 말아야 할 경로를 훑습니다. 룰 파일이 뭐라 하든 여기서 얹습니다.
    public static func withMandatoryDenies(_ ruleSet: RuleSet) -> RuleSet {
        let existing = Set(ruleSet.rules.map(\.id))
        let missing = DefaultRuleSet.mandatoryDenyRules.filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return ruleSet }
        return RuleSet(version: ruleSet.version, roots: ruleSet.roots,
                       dirNames: ruleSet.dirNames, rules: ruleSet.rules + missing)
    }

    /// 덧씌우기 전의 베이스 룰입니다. 사용자가 실제로 고친 룰 파일이 있으면 그것을 씁니다.
    public static func loadBaseRuleSet(overlay: RuleOverlay? = nil) -> RuleSet {
        let url = userRulesURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return DefaultRuleSet.ruleSet
        }

        // 우리가 내보낸 그대로면 사용자가 열어보기만 한 것입니다. 그걸 사용자 룰로
        // 대접하면 앞으로의 기본 룰 개선을 영영 못 받습니다.
        let resolved = overlay ?? RuleOverlay.load()
        if let exported = resolved.exportedRulesDigest, digest(of: data) == exported {
            return DefaultRuleSet.ruleSet
        }

        do {
            return try JSONDecoder().decode(RuleSet.self, from: data)
        } catch {
            FileHandle.standardError.write(
                L("룰 파일을 읽을 수 없어 기본 룰로 진행합니다: \(error.localizedDescription)\n", "Can't read the rules file, using defaults: \(error.localizedDescription)\n").data(using: .utf8)!)
            return DefaultRuleSet.ruleSet
        }
    }

    /// 기본 룰을 사용자 파일로 내보내고, 쓴 내용의 지문을 덧씌우기에 남깁니다.
    /// 지문이 있어야 나중에 "고친 파일"과 "열어보기만 한 파일"을 구별할 수 있습니다.
    public static func exportDefaultsToUserFile(overlay: inout RuleOverlay) throws {
        let data = try exportDefaults()
        try FileManager.default.createDirectory(at: userRulesURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: userRulesURL)
        overlay.exportedRulesDigest = digest(of: data)
        try overlay.save()
    }

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 현재 룰을 JSON으로 내보냅니다. 사용자가 고쳐 쓸 출발점입니다.
    public static func exportDefaults() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(DefaultRuleSet.ruleSet)
    }
}
