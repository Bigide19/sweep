import Foundation

/// 디스크 여유 공간이 줄었을 때 한 번만 알리는 판단입니다.
///
/// 임계치 아래에 머무는 동안 매번 알리면 잔소리가 돼서 알림을 끄게 됩니다. 아래로 내려간
/// 순간 한 번 알리고, 여유가 충분히 돌아와야 다음 알림을 준비합니다. 회복 기준을 임계치보다
/// 높게 둔 건 경계에서 오르내릴 때마다 알림이 반복되지 않게 하려는 것입니다.
public enum LowDiskAlert {
    /// 여유 공간 비율이 이보다 낮아지면 알립니다.
    public static let threshold = 0.10
    /// 여유 공간 비율이 이 이상으로 돌아오면 다음 알림을 준비합니다.
    public static let recovery = 0.15
    /// 비율과 별개로 이보다 적게 남으면 부족으로 봅니다. 큰 디스크는 10%가 수백 GB라
    /// 비율만 보면 실제로 빠듯해진 뒤에야 알립니다.
    public static let floorBytes: Int64 = 10 * 1024 * 1024 * 1024
    public static let recoveryFloorBytes: Int64 = 15 * 1024 * 1024 * 1024

    /// 이번에 알릴지와 저장할 새 상태입니다. `alerted`는 이미 알리고 아직 회복하지 않은 상태입니다.
    public static func evaluate(free: Int64, total: Int64, alerted: Bool) -> (notify: Bool, alerted: Bool) {
        guard total > 0 else { return (false, alerted) }
        let ratio = Double(free) / Double(total)
        if ratio < threshold || free < floorBytes { return (!alerted, true) }
        if ratio >= recovery && free >= recoveryFloorBytes { return (false, false) }
        return (false, alerted)
    }
}
