import Foundation

// MARK: - 룰 모델

/// 경로 하나에 대한 판정입니다.
public enum RuleKind: String, Codable, Sendable {
    /// 재생성할 수 있는 산출물이라 삭제 후보로 올립니다.
    case allow
    /// 소스이거나 패키지가 배포한 실제 코드라 후보에서 뺍니다.
    case deny
}

/// 지운 뒤 되돌리는 데 드는 비용입니다. 선택 판단의 근거로 화면에 그대로 노출합니다.
public enum RegenerateCost: String, Codable, Sendable, CaseIterable {
    case instant       // 재빌드가 수초 안에 끝납니다 (bin/obj, .next)
    case quick         // 1~2분 (Gradle transforms처럼 로컬에서 다시 풀기만 하면 되는 것)
    case slow          // 10분 이상 (Android 네이티브 컴파일)
    case download      // 네트워크 재다운로드가 필요합니다 (npm/NuGet 캐시)
    case reinstall     // 프로젝트에서 패키지 설치를 다시 돌려야 합니다 (node_modules)
    case reindex       // IDE 인덱스 재생성
    case disposable    // 로그처럼 다시 만들 필요가 없는 것

    public var label: String {
        switch self {
        case .instant:  return L("즉시 재빌드", "Rebuilds instantly")
        case .quick:    return L("재생성 2분 안팎", "Rebuilds in about 2 minutes")
        case .slow:     return L("재빌드 10분 이상", "Rebuild takes 10+ minutes")
        case .download: return L("재다운로드", "Downloads again")
        case .reinstall: return L("패키지 재설치", "Reinstall packages")
        case .reindex:  return L("다음에 열 때 재색인", "Reindexes on next open")
        case .disposable: return L("재생성 불필요", "Nothing to rebuild")
        }
    }

    /// 위험이 큰 순서입니다. 목록을 정렬할 때 씁니다.
    public var weight: Int {
        switch self {
        case .instant, .disposable: return 0
        case .quick: return 1
        case .reindex: return 2
        case .slow: return 3
        case .download: return 4
        // 다시 받는 데 더해 프로젝트마다 설치 명령을 돌려야 하고, 네이티브 모듈은 빌드까지 합니다.
        case .reinstall: return 5
        }
    }
}

/// 후보를 묶는 큰 갈래입니다.
public enum SweepCategory: String, Codable, Sendable, CaseIterable {
    case projectOutput   // 프로젝트 빌드 산출물
    case toolchainCache  // 툴체인 캐시 (Gradle, npm, NuGet)
    case aiAgent         // AI 에이전트 캐시 (Claude, Codex, Copilot)
    case appCache        // 앱 캐시 (~/Library/Caches)

    public var label: String {
        switch self {
        case .projectOutput:  return L("프로젝트 산출물", "Build Output")
        case .toolchainCache: return L("툴체인 캐시", "Toolchain Caches")
        case .aiAgent:        return L("AI 에이전트", "AI Agents")
        case .appCache:       return L("앱 캐시", "App Caches")
        }
    }

    public var order: Int {
        switch self {
        case .projectOutput: return 0
        case .toolchainCache: return 1
        case .aiAgent: return 2
        case .appCache: return 3
        }
    }
}

/// 스캔 시작점을 어떻게 훑을지 정합니다.
public enum RootMode: String, Codable, Sendable {
    /// 재귀로 내려가며 관심 디렉터리 이름을 만날 때마다 룰로 판정합니다. (~/Projects)
    case walk
    /// 바로 아래 자식 하나하나를 후보로 판정합니다. (~/Library/Caches)
    case children
    /// 경로 자체가 후보입니다. (~/.npm/_cacache)
    case leaf
}

public struct ScanRoot: Codable, Sendable {
    public let path: String
    public let mode: RootMode
    /// walk 모드에서만 씁니다. nil이면 기본 한계(12)를 적용합니다.
    public let maxDepth: Int?

    public init(path: String, mode: RootMode, maxDepth: Int? = nil) {
        self.path = path
        self.mode = mode
        self.maxDepth = maxDepth
    }
}

/// 경로 하나를 판정하는 룰입니다.
///
/// 여러 룰이 동시에 맞을 때는 `priority`가 높은 쪽이 이깁니다. 같으면 deny가 이깁니다.
/// 이 우선순위 구조가 핵심입니다. `node_modules` 안의 `build`는 패키지 실제 코드라
/// 지우면 안 되지만, 그중 `android/build`만은 Gradle 산출물이라 지워야 합니다.
/// 넓은 deny를 낮은 우선순위로, 좁은 예외 allow를 높은 우선순위로 두면 그대로 표현됩니다.
public struct Rule: Codable, Sendable, Identifiable {
    public let id: String
    public let kind: RuleKind
    public let priority: Int
    /// 절대경로 전체에 대해 맞춰보는 정규식입니다.
    public let regex: String

    // allow 룰에서만 의미가 있는 항목들입니다.
    public let category: SweepCategory?
    public let cost: RegenerateCost?
    public let title: String?
    public let note: String?
    /// 기본으로 체크해둘지 여부입니다. 재다운로드가 필요한 캐시는 false로 둡니다.
    public let defaultSelected: Bool?

    /// 이 이름의 프로그램이 돌고 있으면 삭제를 막습니다.
    /// 실행 파일 이름과 정확히 비교합니다(대소문자 무시). 경로 전체를 부분 문자열로
    /// 훑으면 `/opt/homebrew/bin/node`가 `brew`에 걸리는 식의 오탐이 납니다.
    public let lockProcesses: [String]?

    /// 커맨드라인 전체에 대한 부분 문자열 검색입니다.
    /// Gradle 데몬처럼 실행 파일은 `java`이고 인수에만 이름이 드러나는 경우에 씁니다.
    public let lockCommands: [String]?

    /// true면 어느 단계에서도 미리 체크하지 않습니다. 지우는 건 안전하지만 다시 받는 양이
    /// 커서 사람이 직접 판단해야 하는 것(로컬 AI 모델)에 씁니다. 예전 룰 파일에는 없는
    /// 필드라 옵셔널입니다.
    public let manualSelectOnly: Bool?

    public init(
        id: String,
        kind: RuleKind,
        priority: Int,
        regex: String,
        category: SweepCategory? = nil,
        cost: RegenerateCost? = nil,
        title: String? = nil,
        note: String? = nil,
        defaultSelected: Bool? = nil,
        lockProcesses: [String]? = nil,
        lockCommands: [String]? = nil,
        manualSelectOnly: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.regex = regex
        self.category = category
        self.cost = cost
        self.title = title
        self.note = note
        self.defaultSelected = defaultSelected
        self.lockProcesses = lockProcesses
        self.lockCommands = lockCommands
        self.manualSelectOnly = manualSelectOnly
    }
}

public struct RuleSet: Codable, Sendable {
    public let version: Int
    public let roots: [ScanRoot]
    /// walk 모드에서 만나면 룰 판정을 걸어볼 디렉터리 이름입니다.
    /// 이 목록에 없는 이름은 그냥 지나쳐 더 깊이 내려갑니다.
    public let dirNames: [String]
    public let rules: [Rule]

    public init(version: Int, roots: [ScanRoot], dirNames: [String], rules: [Rule]) {
        self.version = version
        self.roots = roots
        self.dirNames = dirNames
        self.rules = rules
    }
}

// MARK: - 후보 모델

/// 삭제 후보 하나입니다. 스캔 결과이면서 화면에 그대로 그려지는 단위입니다.
public struct Candidate: Sendable, Identifiable, Codable, Hashable {
    public var id: String { path }

    public var path: String
    public var ruleID: String
    public var category: SweepCategory
    public var cost: RegenerateCost
    /// 목록에 보여줄 짧은 이름입니다.
    public var display: String
    /// 판정한 룰의 제목입니다. 폴더 이름만으로 정체를 알 수 없는 캐시(`_cacache`)에 씁니다.
    public var title: String?
    public var bytes: Int64
    public var fileCount: Int
    /// 이 안의 파일 중 바깥과 하드링크로 공유하는 몫입니다. 지워도 이만큼은 디스크가
    /// 비지 않을 수 있습니다. pnpm 프로젝트의 node_modules가 스토어와 이렇게 공유합니다.
    public var sharedBytes: Int64 = 0

    /// 소속 프로젝트 이름입니다. ~/Projects 밖이면 nil입니다.
    public var project: String?
    /// 이 캐시를 쓰고 있는 프로젝트입니다. Gradle 버전 캐시에서 채웁니다.
    public var owner: String?
    /// 삭제를 막고 있는 프로세스입니다.
    public var lockedBy: String?
    /// 소속 프로젝트의 마지막 커밋 경과일입니다.
    public var lastCommitDays: Int?

    /// 이 안에서 가장 최근에 수정된 시각입니다. 마지막으로 빌드했거나 새로 받은 때로 봅니다.
    ///
    /// atime이 아니라 mtime을 씁니다. APFS는 읽을 때마다 atime을 갱신하지 않아서
    /// "마지막으로 읽은 날"을 믿을 수 없습니다. mtime은 "마지막으로 뭔가 새로 만든 날"이라
    /// 활성도 지표로는 이쪽이 정확합니다.
    public var lastModified: Date?

    /// 마지막 수정 이후 지난 날수입니다.
    public var idleDays: Int? {
        guard let lastModified else { return nil }
        return max(0, Int(Date().timeIntervalSince(lastModified) / 86_400))
    }

    /// 안전장치가 기본 선택에서 뺀 항목입니다. 선택 정책이 이걸 다시 켜면 안 됩니다.
    public var deselectedBySafety: Bool = false
    /// 사용자가 직접 골라야 하는 항목입니다. `dist`처럼 이름만으로는 산출물인지 손으로
    /// 관리하는 폴더인지 갈리는 룰이 여기에 해당하고, 어느 단계에서도 미리 체크하지 않습니다.
    public var manualSelectOnly: Bool = false

    /// true면 어떤 경우에도 지우지 않습니다.
    public var blocked: Bool = false
    public var blockReason: String?
    public var warnings: [String] = []
    /// 화이트리스트에 없어서 성격을 모르는 항목입니다. 크기만 보여주고 삭제는 막습니다.
    public var unclassified: Bool = false
    public var note: String?

    public var defaultSelected: Bool = false

    public init(path: String, ruleID: String, category: SweepCategory, cost: RegenerateCost,
                display: String, bytes: Int64 = 0, fileCount: Int = 0) {
        self.path = path
        self.ruleID = ruleID
        self.category = category
        self.cost = cost
        self.display = display
        self.bytes = bytes
        self.fileCount = fileCount
    }

    /// 실제로 지울 수 있는 상태인지입니다.
    public var isDeletable: Bool { !blocked && !unclassified }

    /// 다른 후보 안에 든 후보를 뺍니다.
    ///
    /// `node_modules`는 통째로 후보가 되면서 그 안의 RN `android/build`도 따로 후보로
    /// 남습니다. 바깥이 잠겼을 때 안쪽만이라도 지울 수 있게 하려는 것입니다. 둘을 함께
    /// 고르면 크기를 두 번 세고, 바깥을 먼저 지운 뒤 안쪽은 "이미 없는 경로"로 실패합니다.
    /// 합계를 내거나 지우기 전에 이걸 거칩니다.
    public static func withoutNested(_ candidates: [Candidate]) -> [Candidate] {
        let paths = Set(candidates.map(\.path))
        return candidates.filter { candidate in
            var current = (candidate.path as NSString).deletingLastPathComponent
            while current.count > 1 {
                if paths.contains(current) { return false }
                current = (current as NSString).deletingLastPathComponent
            }
            return true
        }
    }
}

/// 스캔 한 번의 결과 전체입니다.
public struct ScanResult: Sendable, Codable {
    public var candidates: [Candidate]
    public var scannedAt: Date
    public var duration: TimeInterval
    /// 스캔 중에 모은 Gradle 버전별 사용 프로젝트입니다.
    public var gradleOwners: [String: [String]]
    /// 접근이 막혀 건너뛴 경로입니다.
    public var skipped: [String]

    /// deny 룰이 각각 몇 곳을 걸렀는지입니다.
    ///
    /// 막힌 경로는 후보로 올라오지 않아 목록만 봐서는 deny 룰이 일하는지 알 수 없습니다.
    /// 크기는 재지 않습니다. 막을 대상을 재려고 트리를 걷는 건 배보다 배꼽입니다.
    public var deniedCounts: [String: Int]

    public init(candidates: [Candidate], scannedAt: Date, duration: TimeInterval,
                gradleOwners: [String: [String]] = [:], skipped: [String] = [],
                deniedCounts: [String: Int] = [:]) {
        self.candidates = candidates
        self.scannedAt = scannedAt
        self.duration = duration
        self.gradleOwners = gradleOwners
        self.skipped = skipped
        self.deniedCounts = deniedCounts
    }

    /// 지울 수 있는 후보의 합계입니다.
    public var reclaimableBytes: Int64 {
        Candidate.withoutNested(candidates.filter(\.isDeletable)).reduce(0) { $0 + $1.bytes }
    }

    public var totalBytes: Int64 {
        candidates.reduce(0) { $0 + $1.bytes }
    }
}

/// 삭제 한 번의 기록입니다. 이력 파일에 한 줄씩 쌓습니다.
public struct SweepRecord: Codable, Sendable {
    public var deletedAt: Date
    public var path: String
    public var ruleID: String
    public var bytes: Int64
    public var succeeded: Bool
    public var error: String?

    public init(deletedAt: Date, path: String, ruleID: String, bytes: Int64,
                succeeded: Bool, error: String? = nil) {
        self.deletedAt = deletedAt
        self.path = path
        self.ruleID = ruleID
        self.bytes = bytes
        self.succeeded = succeeded
        self.error = error
    }
}
