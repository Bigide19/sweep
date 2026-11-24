import Foundation

/// 화면 언어입니다. 앱 설정에서 고르고, 정한 적이 없으면 시스템 언어를 따릅니다.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case ko
    case en

    public var id: String { rawValue }

    /// 메뉴에 보이는 이름입니다. 지금 어느 언어로 보고 있든 자기 말로 적어야 찾을 수 있습니다.
    public var nativeName: String {
        switch self {
        case .ko: return "한국어"
        case .en: return "English"
        }
    }

    private static let defaultsKey = "language"

    /// 저장소를 UserDefaults 하나로 둬서 코어와 앱이 따로 상태를 들고 있지 않게 합니다.
    /// 전역 변수로 두면 스캔이 도는 백그라운드 스레드에서 읽을 때 동시성 문제가 생깁니다.
    public static var current: AppLanguage {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let language = AppLanguage(rawValue: raw) {
                return language
            }
            return Locale.preferredLanguages.first?.hasPrefix("ko") == true ? .ko : .en
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// 한국어와 영어 문구 중 지금 언어에 맞는 쪽을 고릅니다.
///
/// 문구가 많지 않고 언어도 둘뿐이라 .strings 카탈로그 대신 쓰는 자리에 둘을 나란히 적습니다.
/// 카탈로그는 앱을 다시 켜야 언어가 바뀌지만, 이 방식은 메뉴에서 고르는 즉시 바뀝니다.
public func L(_ ko: String, _ en: String) -> String {
    AppLanguage.current == .ko ? ko : en
}
