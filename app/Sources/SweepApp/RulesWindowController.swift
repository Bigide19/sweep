import AppKit
import SwiftUI
import SweepCore

/// 룰 설정 창 하나를 들고 있습니다.
///
/// 팝오버에는 룰 전체가 들어가지 않습니다. 목록을 보면서 끄고 켜려면 창이 필요합니다.
/// 여러 번 열어도 창은 하나만 씁니다. 같은 창이 계속 뜨면 사용자가 어디를 보고 있었는지 잃지 않습니다.
@MainActor
final class RulesWindowController {

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if let window {
            // 창을 만든 뒤에 언어를 바꿨을 수 있어서 열 때마다 제목을 다시 씁니다.
            window.title = L("Sweep 룰 설정", "Sweep Rules")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: RulesView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Sweep 룰 설정", "Sweep Rules")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 620))
        window.center()
        // 닫으면 창을 버리지 않고 숨겨두었다가 다시 씁니다.
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // LSUIElement 앱이라 활성화를 직접 걸어야 창이 앞으로 나옵니다. 협조적 activate()는
        // 다른 앱이 앞에 있으면 거절당해서 창이 뒤에 깔립니다.
        NSApp.activate(ignoringOtherApps: true)
    }
}
