import Foundation

/// 무엇을 기본으로 체크해둘지 정합니다.
///
/// 룰이 "지워도 되는가"를 정한다면 이쪽은 "지금 골라줄까"를 정합니다. 둘은 다른 질문입니다.
/// 지워도 되는 것과 지금 지우는 게 이득인 것이 같지 않기 때문입니다. 어제 받은 npm 캐시는
/// 지워도 되지만 내일 다시 받게 되니 고를 이유가 없습니다.
///
/// 판단 기준은 마지막 수정 이후 지난 날수 하나입니다. 오래 손대지 않았다는 건
/// 다시 만드는 비용을 당분간 치를 일이 없다는 뜻입니다.
public struct SelectionPolicy: Sendable, Equatable {

    /// 사용자가 고르는 단계입니다.
    public enum Level: String, Codable, Sendable, CaseIterable, Identifiable {
        case safe
        case balanced
        case aggressive

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .safe:       return L("최소", "Minimal")
            case .balanced:   return L("표준", "Standard")
            case .aggressive: return L("최대", "Maximum")
            }
        }

        /// 메뉴 항목 옆에 붙는 설명입니다. 정확한 일수는 문서에 두고 여기서는 범위만 말합니다.
        public var detail: String {
            switch self {
            case .safe:       return L("빌드 산출물", "Build output")
            case .balanced:   return L("빌드 산출물, 오래된 툴체인 캐시", "Build output, old toolchain caches")
            case .aggressive: return L("빌드 산출물, 오래된 캐시 전부", "Build output, all old caches")
            }
        }

        public var policy: SelectionPolicy {
            switch self {
            case .safe:       return .safe
            case .balanced:   return .balanced
            case .aggressive: return .aggressive
            }
        }
    }

    /// 각 갈래를 고르기 위한 최소 유휴일입니다. nil이면 그 갈래는 아예 고르지 않습니다.
    public var projectOutputIdleDays: Int?
    public var toolchainCacheIdleDays: Int?
    public var appCacheIdleDays: Int?

    public init(projectOutputIdleDays: Int?, toolchainCacheIdleDays: Int?, appCacheIdleDays: Int?) {
        self.projectOutputIdleDays = projectOutputIdleDays
        self.toolchainCacheIdleDays = toolchainCacheIdleDays
        self.appCacheIdleDays = appCacheIdleDays
    }

    public static let safe = SelectionPolicy(projectOutputIdleDays: 7,
                                             toolchainCacheIdleDays: nil,
                                             appCacheIdleDays: nil)

    public static let balanced = SelectionPolicy(projectOutputIdleDays: 7,
                                                 toolchainCacheIdleDays: 90,
                                                 appCacheIdleDays: nil)

    /// 과감하게는 프로젝트 산출물의 유휴일을 아예 따지지 않습니다. 재빌드로 되돌아오는
    /// 것들이라, 방금 빌드했더라도 지우는 판단 자체는 성립합니다.
    public static let aggressive = SelectionPolicy(projectOutputIdleDays: 0,
                                                   toolchainCacheIdleDays: 30,
                                                   appCacheIdleDays: 90)

    /// 이 후보를 기본으로 체크해둘지입니다.
    public func selects(_ candidate: Candidate) -> Bool {
        guard candidate.isDeletable else { return false }
        // 안전장치가 내려둔 건 정책이 다시 올리지 않습니다.
        guard !candidate.deselectedBySafety else { return false }
        guard !candidate.manualSelectOnly else { return false }

        let threshold: Int?
        switch candidate.category {
        case .projectOutput:  threshold = projectOutputIdleDays
        // AI 에이전트 캐시도 런타임과 인덱스라 툴체인 캐시와 같은 기준으로 고릅니다.
        case .toolchainCache, .aiAgent: threshold = toolchainCacheIdleDays
        case .appCache:       threshold = appCacheIdleDays
        }
        guard let threshold else { return false }

        // 수정 시각을 못 읽은 항목은 고르지 않습니다. 모르면 손대지 않는 쪽이 맞습니다.
        guard let idle = candidate.idleDays else { return false }
        return idle >= threshold
    }

    public func apply(to candidates: [Candidate]) -> [Candidate] {
        candidates.map { candidate in
            var updated = candidate
            updated.defaultSelected = selects(candidate)
            return updated
        }
    }
}
