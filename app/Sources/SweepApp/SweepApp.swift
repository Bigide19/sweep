import AppKit
import SweepCore

/// 진입점입니다. SwiftUI `App` 대신 AppKit으로 직접 띄웁니다.
///
/// 화면은 전부 메뉴바 아이콘이 띄우는 팝오버라 씬이 필요 없습니다. 예전에는 `App` 프로토콜이
/// 씬을 하나 요구해서 빈 `Settings` 씬으로 자리만 채웠는데, 그 빈 "Sweep Settings" 창이
/// 실행할 때 실제로 떠버렸습니다.
@main
enum SweepMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // app.delegate는 약한 참조입니다. run()이 돌아오지 않으니 이 지역 변수가 계속 붙잡아 둡니다.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// `MenuBarExtra` 대신 `NSStatusItem`을 직접 쓰기 때문에 델리게이트가 필요합니다.
/// 우클릭 메뉴를 붙이려면 이 방법밖에 없습니다. 배경은 StatusItemController에 적어두었습니다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        let model = AppModel()
        self.model = model
        self.statusItem = StatusItemController(model: model)
    }

    /// 메뉴바에 보이지는 않지만 단축키는 이 메뉴를 거쳐 갑니다. 없으면 룰 창 입력란에서
    /// ⌘C, ⌘V가 먹지 않습니다. SwiftUI `App`을 쓸 때는 이걸 대신 만들어 줬습니다.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: L("Sweep 종료", "Quit Sweep"),
                                 action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }

    /// 상주 앱이라 창이 없다고 끝나면 안 됩니다. 종료는 우클릭 메뉴로만 합니다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
