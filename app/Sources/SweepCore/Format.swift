import Foundation

public enum Format {

    /// du -h와 비슷하게 읽히도록 맞춥니다. 1024 기준입니다.
    public static func bytes(_ value: Int64) -> String {
        let units: [(Double, String)] = [
            (1024 * 1024 * 1024 * 1024, "TB"),
            (1024 * 1024 * 1024, "GB"),
            (1024 * 1024, "MB"),
            (1024, "KB"),
        ]
        let size = Double(value)
        for (unit, suffix) in units where size >= unit {
            let scaled = size / unit
            return scaled >= 100
                ? String(format: "%.0f%@", scaled, suffix)
                : String(format: "%.1f%@", scaled, suffix)
        }
        return "\(value)B"
    }

    /// 디스크가 얼마나 찼는지입니다.
    public struct DiskUsage: Sendable {
        public let free: Int64
        public let total: Int64

        public var used: Int64 { max(0, total - free) }
        public var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
        public var percent: Int { Int((usedRatio * 100).rounded()) }

        /// 지정한 용량을 지웠을 때의 사용률입니다. 정리 효과를 미리 보여줍니다.
        public func percentAfterFreeing(_ bytes: Int64) -> Int {
            guard total > 0 else { return 0 }
            let remaining = max(0, used - bytes)
            return Int((Double(remaining) / Double(total) * 100).rounded())
        }
    }

    /// 홈이 있는 볼륨의 사용량입니다.
    /// `ForImportantUsage`를 쓰면 Finder와 시스템 설정이 보여주는 값과 맞습니다.
    public static func disk() -> DiskUsage {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ]) else { return DiskUsage(free: 0, total: 0) }
        return DiskUsage(free: Int64(values.volumeAvailableCapacityForImportantUsage ?? 0),
                         total: Int64(values.volumeTotalCapacity ?? 0))
    }

    public static func relativeDate(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return L("방금", "just now") }
        if elapsed < 3600 { return L("\(Int(elapsed / 60))분 전", "\(Int(elapsed / 60))m ago") }
        if elapsed < 86_400 { return L("\(Int(elapsed / 3600))시간 전", "\(Int(elapsed / 3600))h ago") }
        return L("\(Int(elapsed / 86_400))일 전", "\(Int(elapsed / 86_400))d ago")
    }
}
