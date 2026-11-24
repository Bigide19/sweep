import AppKit
import SwiftUI
import SweepCore

/// 메뉴바 아이콘 하나를 직접 관리합니다.
///
/// SwiftUI의 `MenuBarExtra`로는 우클릭에 별도 메뉴를 붙일 방법이 없습니다. 좌클릭이든
/// 우클릭이든 똑같이 패널만 열립니다. `NSStatusItem`을 직접 들면 좌클릭은 패널,
/// 우클릭은 `NSMenu`로 갈라 쓸 수 있어서 이쪽을 택했습니다.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let rulesWindow: RulesWindowController
    /// 팝오버가 열려 있는 동안만 거는 이벤트 모니터입니다. 닫힐 때 반드시 풀어야 합니다.
    private var eventMonitors: [Any] = []
    /// 팝오버가 마지막으로 닫히기 시작한 시각입니다.
    ///
    /// 앱이 활성화된 상태에서는 transient가 아이콘의 mouseDown에 팝오버를 닫고, 이어서
    /// 들어오는 mouseUp 액션이 닫힌 걸 보고 다시 엽니다. 닫으려고 누른 클릭이 다시 여는
    /// 클릭이 되는 셈입니다. 닫힌 직후의 클릭은 그 클릭으로 보고 무시합니다.
    private var lastClosedAt: Date = .distantPast

    init(model: AppModel) {
        self.model = model
        self.rulesWindow = RulesWindowController(model: model)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // transient만으로는 부족합니다. 앱이 활성화되지 못하면 바깥 클릭을 받지 못해 닫히지
        // 않습니다. 그래서 아래 이벤트 모니터로 바깥 클릭과 Esc를 직접 받습니다.
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuView(model: model))

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sweep")
            button.imagePosition = .imageLeading
            // 기본은 좌클릭만 액션으로 들어옵니다. 우클릭까지 같은 액션으로 받아
            // 안에서 갈라냅니다.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.action = #selector(handleClick)
        }

        // 팝오버 안에서도 같은 창을 열 수 있어야 합니다. 창이 뜨면 팝오버는 비켜줍니다.
        model.showRulesWindow = { [weak self] in self?.showRules() }
        model.pickFolders = { [weak self] in self?.pickFolders() }

        // ⌘Tab이나 Space 전환처럼 마우스를 거치지 않고 다른 앱으로 넘어가면 전역 클릭
        // 모니터가 알 수 없습니다. 앱이 비활성화되는 순간을 따로 받아 닫습니다.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }

        updateButton()
        observeModel()
    }

    // MARK: - 클릭 분기

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        // 맥에서 control+좌클릭은 우클릭과 같은 뜻입니다. 함께 받아줍니다.
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard Date().timeIntervalSince(lastClosedAt) > 0.3 else { return }

        // 창을 여는 순간이 가장 최신이어야 하니 디스크를 다시 읽습니다.
        model.refreshDisk()
        // 메뉴바는 모니터마다 있어서, 누른 아이콘이 있는 화면을 기준으로 목록 높이를 잡아야
        // 작은 화면에서 푸터가 잘리지 않습니다. NSScreen.main은 다른 화면일 수 있습니다.
        if let screen = button.window?.screen {
            model.popoverScreenHeight = screen.visibleFrame.height
        }
        // 협조적 활성화인 activate()는 다른 앱이 앞에 있으면 거절당합니다. 그러면 팝오버가
        // 키 창이 되지 못해 첫 클릭이 활성화에 소모되고, transient도 동작하지 않습니다.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// 다른 앱 창, 바탕화면, 빈 메뉴바를 누르거나 Esc를 누르면 닫습니다.
    ///
    /// 전역 모니터는 다른 앱으로 가는 이벤트만 받습니다. Sweep 아이콘 클릭은 우리 앱
    /// 이벤트라 여기 오지 않으므로, 아이콘을 다시 눌렀을 때 닫혔다 곧바로 열리는 일이 없습니다.
    private func installEventMonitors() {
        removeEventMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // 53은 Esc입니다. 팝오버 안의 메뉴가 열려 있으면 메뉴가 먼저 Esc를 가져갑니다.
            guard event.keyCode == 53, let self, self.popover.isShown else { return event }
            self.closePopover()
            return nil
        }) {
            eventMonitors.append(local)
        }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    // MARK: - NSPopoverDelegate

    // 모니터는 열린 뒤에 걸고 닫힌 뒤에 풉니다. 여는 쪽에서 걸면, 늦게 도착한 이전
    // 닫힘 알림이 방금 건 모니터를 풀어버릴 수 있습니다.
    func popoverDidShow(_ notification: Notification) {
        installEventMonitors()
    }

    func popoverWillClose(_ notification: Notification) {
        lastClosedAt = Date()
    }

    func popoverDidClose(_ notification: Notification) {
        removeEventMonitors()
        model.popoverDidClose()
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        popover.performClose(nil)

        let menu = NSMenu()
        menu.addItem(item(L("다시 스캔", "Rescan"), #selector(rescan)))
        menu.addItem(item(L("룰 설정…", "Rules…"), #selector(showRules)))
        menu.addItem(item(L("삭제 이력", "Deletion History"), #selector(revealHistory)))
        menu.addItem(.separator())
        menu.addItem(item(L("Sweep 종료", "Quit Sweep"), #selector(quit), key: "q"))

        // statusItem.menu에 붙여두면 좌클릭에도 이 메뉴가 떠서 패널을 못 엽니다.
        // 우클릭 때만 즉석에서 띄우고 붙여두지는 않습니다.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    // MARK: - 메뉴 동작

    @objc private func rescan() { Task { await model.scan() } }
    @objc private func showRules() {
        closePopover()
        rulesWindow.show()
    }
    /// 첫 실행 화면에서 프로젝트 폴더를 직접 고릅니다.
    ///
    /// 선택 창이 앞으로 오면 transient 팝오버는 저절로 닫힙니다. 미리 닫아두고, 고른 뒤에
    /// 다시 열어서 사용자가 하던 화면으로 돌아가게 합니다.
    private func pickFolders() {
        closePopover()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = L("추가", "Add")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            model.addPickedFolders(panel.urls)
        }
        lastClosedAt = .distantPast
        togglePopover()
    }

    @objc private func revealHistory() { model.revealHistory() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - 라벨 갱신

    private func updateButton() {
        statusItem.button?.title = model.menuBarTitle
    }

    /// `menuBarTitle`이 읽는 상태가 바뀔 때마다 라벨을 다시 씁니다.
    ///
    /// `withObservationTracking`은 한 번 걸면 한 번만 알려주고 풀립니다. 그래서
    /// 알림을 받을 때마다 다시 겁니다. 또 변경 직전에 불리기 때문에 그 자리에서 값을
    /// 읽으면 이전 값이 나옵니다. 한 틱 미뤄서 읽습니다.
    private func observeModel() {
        withObservationTracking {
            _ = model.menuBarTitle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateButton()
                self.observeModel()
            }
        }
    }
}
