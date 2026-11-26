import Foundation
import SwiftUI
import ServiceManagement
import UserNotifications
import SweepCore

/// 메뉴바 앱의 상태 전부입니다. 로직은 SweepCore에 있고 여기서는 화면에 필요한
/// 형태로 들고 있기만 합니다.
@MainActor
@Observable
final class AppModel {

    enum ScanPhase {
        case idle
        case scanning(String)
        case done
    }

    var phase: ScanPhase = .idle
    var result: ScanResult?
    /// 체크된 후보의 경로입니다.
    var selected: Set<String> = []
    /// 접어둔 카테고리입니다.
    var collapsed: Set<SweepCategory> = []
    /// 팝오버를 띄운 화면의 높이입니다. 목록 높이의 상한을 정하는 데 씁니다.
    var popoverScreenHeight: CGFloat = 900
    /// 지울 수 없는 항목 묶음을 펼쳐둔 카테고리입니다. 기본은 접혀 있습니다.
    var expandedLocked: Set<SweepCategory> = []
    /// 삭제 버튼을 한 번 누른 뒤 확인을 기다리는 상태입니다.
    var awaitingConfirm = false

    /// 지우는 중입니다. 지우는 동안에는 스캔, 선택 변경, 단계 변경을 받지 않습니다.
    var isSweeping = false
    /// 이번 삭제에서 처리한 항목 수와 전체 수입니다.
    var sweepDone = 0
    var sweepTotal = 0
    /// 부스러지는 애니메이션이 도는 행의 경로입니다. 애니메이션이 끝나면 목록에서 빠집니다.
    var dissolving: Set<String> = []
    /// 다음 행이 부스러지기 시작할 수 있는 시각입니다. 작은 폴더 여럿이 한꺼번에 지워져도
    /// 한 줄씩 차례로 흩어지게 간격을 둡니다.
    @ObservationIgnored private var nextDissolveAt = Date.distantPast
    /// 행 하나가 부스러져 사라지는 데 걸리는 시간입니다. 화면의 애니메이션 길이와 같아야 합니다.
    static let dissolveDuration: TimeInterval = 1.6

    /// 처음 실행해서 검사할 프로젝트 폴더를 아직 정하지 않은 상태입니다.
    ///
    /// 감지한 폴더를 묻지 않고 쓰면, 사용자가 무엇을 검사하는지 보기도 전에 훑고 알림까지
    /// 보냅니다. 폴더를 확인받기 전에는 자동 스캔도 알림 권한 요청도 하지 않습니다.
    var needsSetup: Bool { overlay.projectRoots == nil }
    /// 첫 실행 화면에 제안하는 폴더와 그중 체크된 것입니다.
    var proposedRoots: [String] = []
    var acceptedRoots: Set<String> = []
    var isDetectingRoots = false
    /// 폴더를 확인한 뒤에 새로 생긴 프로젝트 폴더입니다. 저장한 폴더에 들지 않고,
    /// 사용자가 거절한 적도 없는 것만 담습니다. 묻기만 하고 저절로 더하지는 않습니다.
    var newRootSuggestions: [String] = []
    /// 폴더 선택 창을 여는 동작입니다. 팝오버를 닫았다 다시 여는 일이라 AppKit 쪽이 맡습니다.
    @ObservationIgnored var pickFolders: (() -> Void)?
    var lastMessage: String?
    /// 마지막 문구가 실패를 알리는지입니다. 실패 문구까지 초록색이면 성공으로 읽힙니다.
    var lastMessageIsWarning = false
    /// 진행 중인 삭제 작업입니다. 멈춤 버튼이 취소합니다.
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    var totalReclaimed: Int64 = Sweeper.totalReclaimed()

    /// 디스크 사용량입니다. 스캔과 달리 즉시 읽히는 값이라 앱을 켜자마자 보여줍니다.
    ///
    /// 뷰 본문에서 `Format.disk()`를 직접 부르면 관측 대상이 아니라서, 메뉴바 라벨처럼
    /// 다시 그릴 계기가 없는 자리에서는 처음 읽은 값에 머뭅니다. 그래서 상태로 들고 있습니다.
    var disk: Format.DiskUsage = Format.disk()

    /// 여유 공간이 줄었을 때 알릴지입니다.
    var lowDiskAlertEnabled: Bool = UserDefaults.standard.object(forKey: "lowDiskAlertEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lowDiskAlertEnabled, forKey: "lowDiskAlertEnabled") }
    }

    // 설정
    var autoScanInterval: AutoScanInterval {
        didSet {
            UserDefaults.standard.set(autoScanInterval.rawValue, forKey: "autoScanInterval")
            restartTimer()
        }
    }
    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// 사용자가 끈 룰과 제외한 경로입니다.
    var overlay: RuleOverlay = RuleOverlay.load()
    /// 룰 설정 창을 여는 동작입니다. 창 관리는 AppKit 쪽 일이라 모델은 부르기만 합니다.
    @ObservationIgnored var showRulesWindow: (() -> Void)?
    /// 룰 설정을 바꾼 뒤 아직 다시 훑지 않은 상태입니다.
    /// 룰이 바뀌면 후보 자체가 달라져서 재스캔 말고는 반영할 방법이 없습니다.
    var rulesDirty = false
    /// 화면에 보여줄 룰 전체입니다. 꺼둔 룰도 다시 켤 수 있어야 하므로 베이스를 씁니다.
    private(set) var baseRules: [Rule] = RuleEngine.loadBaseRuleSet().rules

    /// 화면 언어입니다. 룰 제목과 설명도 언어를 따르므로 바꾸면 룰을 다시 읽습니다.
    /// 차단 사유와 경고는 스캔할 때 만들어지는 문장이라 다음 스캔부터 바뀝니다.
    var language: AppLanguage = AppLanguage.current {
        didSet {
            AppLanguage.current = language
            baseRules = RuleEngine.loadBaseRuleSet().rules
        }
    }

    /// 무엇을 기본으로 체크해둘지 정하는 단계입니다.
    var cleanupLevel: SelectionPolicy.Level {
        didSet {
            UserDefaults.standard.set(cleanupLevel.rawValue, forKey: "cleanupLevel")
            reapplySelection()
        }
    }

    private var timer: Timer?
    /// 디스크 사용량 갱신 타이머입니다. 스캔 주기와 무관하게 따로 돕니다.
    private var diskTimer: Timer?

    enum AutoScanInterval: String, CaseIterable, Identifiable {
        case off, daily, weekly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return L("끔", "Off")
            case .daily: return L("매일", "Daily")
            case .weekly: return L("매주", "Weekly")
            }
        }
        var seconds: TimeInterval? {
            switch self {
            case .off: return nil
            case .daily: return 24 * 60 * 60
            case .weekly: return 7 * 24 * 60 * 60
            }
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "autoScanInterval") ?? AutoScanInterval.weekly.rawValue
        self.autoScanInterval = AutoScanInterval(rawValue: saved) ?? .weekly
        let savedLevel = UserDefaults.standard.string(forKey: "cleanupLevel") ?? SelectionPolicy.Level.balanced.rawValue
        self.cleanupLevel = SelectionPolicy.Level(rawValue: savedLevel) ?? .balanced
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        restartTimer()
        startDiskTimer()

        if needsSetup {
            detectRoots()
            return
        }
        requestNotificationPermission()
        checkForNewRoots()

        // 켜자마자 훑으면 로그인 직후 디스크를 함께 긁습니다. 잠깐 기다렸다가
        // 주기가 지났을 때만 돕니다. 껐다 켜기를 반복해도 주기가 밀리지 않습니다.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.scanIfDue()
        }
    }

    // MARK: - 디스크

    func refreshDisk() {
        disk = Format.disk()
        checkLowDisk()
    }

    /// 여유 공간이 임계치 아래로 내려간 순간 한 번 알립니다.
    ///
    /// 알렸다는 상태를 저장해 둡니다. 저장하지 않으면 이미 부족한 맥에서 앱을 켤 때마다 알립니다.
    private func checkLowDisk() {
        guard lowDiskAlertEnabled, !needsSetup, disk.total > 0 else { return }
        let key = "lowDiskAlerted"
        let decision = LowDiskAlert.evaluate(free: disk.free, total: disk.total,
                                             alerted: UserDefaults.standard.bool(forKey: key))
        UserDefaults.standard.set(decision.alerted, forKey: key)
        guard decision.notify else { return }

        let content = UNMutableNotificationContent()
        content.title = L("남은 공간 \(Format.bytes(disk.free))", "\(Format.bytes(disk.free)) left")
        content.body = L("디스크가 \(disk.percent)% 찼습니다. Sweep에서 정리할 항목을 확인하세요.",
                         "Your disk is \(disk.percent)% full. Open Sweep to review what can go.")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 메뉴바 라벨에 사용률이 걸려 있어서 주기적으로 다시 읽어야 합니다.
    /// 볼륨 조회 한 번이라 1분 간격이면 부담이 없습니다.
    private func startDiskTimer() {
        diskTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDisk() }
        }
    }

    /// 메뉴바 아이콘 옆에 붙일 문구입니다.
    /// 사용률은 항상, 정리 가능 용량은 찾은 게 있을 때만 붙입니다.
    var menuBarTitle: String {
        var parts: [String] = []
        // 볼륨 조회에 실패하면 total이 0입니다. 이때 0%를 띄우면 거짓말이 됩니다.
        if disk.total > 0 { parts.append("\(disk.percent)%") }
        if let result, result.reclaimableBytes > 0 {
            parts.append(Format.bytes(result.reclaimableBytes))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 스캔

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func scan(notifyWhenDone: Bool = false) async {
        // 우클릭 메뉴의 다시 스캔도 여기로 옵니다. 폴더를 확인받기 전에는 훑지 않습니다.
        guard !isScanning, !isSweeping, !needsSetup else { return }
        phase = .scanning(L("시작", "Starting…"))
        awaitingConfirm = false

        // 룰은 매번 다시 읽습니다. 사용자가 파일을 직접 고쳤을 수도 있고,
        // 룰 화면에서 켜고 끈 내용도 여기서 반영됩니다.
        let engine = RuleEngine(ruleSet: RuleEngine.loadRuleSet(overlay: overlay))
        baseRules = RuleEngine.loadBaseRuleSet().rules
        let scanner = SweepScanner(engine: engine, policy: cleanupLevel.policy)
        let scanned = await scanner.scan { [weak self] path in
            Task { @MainActor in
                guard let self, self.isScanning else { return }
                self.phase = .scanning(path)
            }
        }

        result = scanned
        // 룰이 기본 선택으로 표시한 것만 체크해둡니다. 나머지는 사용자가 직접 고릅니다.
        selected = Set(scanned.candidates.filter { $0.defaultSelected && $0.isDeletable }.map(\.path))
        phase = .done
        rulesDirty = false
        // 직접 누른 스캔도 주기를 새로 시작시킵니다. 기준은 "마지막으로 훑은 지"입니다.
        lastScanAt = Date()
        // 스캔이 수십 초 걸리는 동안 디스크 상황이 달라졌을 수 있습니다.
        refreshDisk()

        if notifyWhenDone { notifyScanResult(scanned) }
        checkForNewRoots()
    }

    // MARK: - 선택

    func candidates(in category: SweepCategory) -> [Candidate] {
        result?.candidates.filter { $0.category == category } ?? []
    }

    /// 고른 후보입니다. 바깥 후보와 그 안의 후보를 함께 골랐으면 바깥만 셉니다.
    var selectedCandidates: [Candidate] {
        Candidate.withoutNested(result?.candidates.filter { selected.contains($0.path) && $0.isDeletable } ?? [])
    }

    var selectedBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.bytes }
    }

    /// 단계를 바꿨을 때 부릅니다. 유휴일과 크기는 이미 재놨으니 다시 훑을 필요가 없습니다.
    /// 34초를 다시 기다리게 하지 않고 선택만 새로 계산합니다.
    private func reapplySelection() {
        guard !isSweeping, var scanned = result else { return }
        scanned.candidates = cleanupLevel.policy.apply(to: scanned.candidates)
        result = scanned
        selected = Set(scanned.candidates.filter { $0.defaultSelected && $0.isDeletable }.map(\.path))
        awaitingConfirm = false
    }

    func toggle(_ candidate: Candidate) {
        guard candidate.isDeletable, !isSweeping else { return }
        if selected.contains(candidate.path) {
            selected.remove(candidate.path)
        } else {
            selected.insert(candidate.path)
        }
        awaitingConfirm = false
    }

    func toggleAll(in category: SweepCategory) {
        guard !isSweeping else { return }
        let items = candidates(in: category).filter(\.isDeletable)
        let allSelected = items.allSatisfy { selected.contains($0.path) }
        for item in items {
            if allSelected { selected.remove(item.path) } else { selected.insert(item.path) }
        }
        awaitingConfirm = false
    }

    func toggleCollapse(_ category: SweepCategory) {
        if collapsed.contains(category) { collapsed.remove(category) } else { collapsed.insert(category) }
    }

    func toggleLocked(_ category: SweepCategory) {
        if expandedLocked.contains(category) { expandedLocked.remove(category) } else { expandedLocked.insert(category) }
    }

    /// 팝오버가 닫힐 때 부릅니다. 다시 열었을 때 지난번 확인 바나 결과 문구가 남아 있으면
    /// 지금 일어난 일처럼 읽힙니다.
    func popoverDidClose() {
        awaitingConfirm = false
        lastMessage = nil
        lastMessageIsWarning = false
    }

    // MARK: - 삭제

    /// 고른 항목을 지웁니다.
    ///
    /// 삭제는 백그라운드에서 돌립니다. 메인 스레드에서 지우면 큰 폴더 하나에 수십 초 동안
    /// 화면이 멈춥니다. 지운 항목은 그 자리에서 부스러뜨려 목록에서 빼고, 다시 훑지는
    /// 않습니다. 다시 훑으면 수십 초 동안 목록이 통째로 사라졌다 돌아옵니다.
    func sweep() async {
        let targets = selectedCandidates
        guard !targets.isEmpty, !isSweeping, !isScanning else { return }
        awaitingConfirm = false
        lastMessage = nil
        lastMessageIsWarning = false
        isSweeping = true
        sweepDone = 0
        sweepTotal = targets.count

        // 애니메이션을 확인할 때 실제 파일을 지우지 않으려고 둔 스위치입니다.
        // `defaults write kr.bigide.sweep debugDryRunDelete -bool YES`로 켭니다.
        let dryRun = UserDefaults.standard.bool(forKey: "debugDryRunDelete")
        let freeBefore = Format.disk().free

        let (events, continuation) = AsyncStream<(Candidate, Sweeper.ItemResult)>.makeStream()
        sweepTask = Task.detached(priority: .userInitiated) {
            _ = Sweeper().sweep(targets, dryRun: dryRun, finished: { candidate, item in
                // 시험 삭제는 순식간에 끝나서 진행 표시를 볼 수 없습니다. 실제처럼 늦춥니다.
                if dryRun { Thread.sleep(forTimeInterval: 0.35) }
                continuation.yield((candidate, item))
            })
            continuation.finish()
        }

        var reclaimed: Int64 = 0
        var failures: [String] = []
        for await (candidate, item) in events {
            sweepDone += 1
            reclaimed += item.freedBytes
            if item.removed {
                dissolve(candidate.path)
            } else {
                markFailed(candidate, freed: item.freedBytes)
            }
            if let error = item.error {
                failures.append("\(candidate.display): \(error)")
            }
        }
        let stopped = sweepTask?.isCancelled == true
        sweepTask = nil

        // 마지막 행이 다 흩어질 때까지 기다렸다가 마무리합니다.
        let remaining = nextDissolveAt.timeIntervalSinceNow + Self.dissolveDuration
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }

        totalReclaimed = Sweeper.totalReclaimed()
        var parts = [L("\(Format.bytes(reclaimed)) 회수", "Reclaimed \(Format.bytes(reclaimed))")]
        // 회수량은 지운 파일의 크기 합이라 하드링크 공유분까지 셉니다. 실제로 늘어난 남은 공간이
        // 눈에 띄게 적으면 같이 보여 줍니다. 다른 프로그램의 쓰기도 섞이는 참고값입니다.
        let gained = Format.disk().free - freeBefore
        if !dryRun, reclaimed > 0, gained < reclaimed / 2 {
            parts.append(L("남은 공간은 \(Format.bytes(max(0, gained))) 늘어남", "free space grew by \(Format.bytes(max(0, gained)))"))
        }
        if stopped { parts.append(L("멈춤", "stopped")) }
        if let first = failures.first {
            // 실패는 첫 건의 사유까지 보여줍니다. 개수만 보여주면 왜 실패했는지 알 길이 없습니다.
            parts.append(failures.count == 1
                         ? first
                         : L("실패 \(failures.count)개, \(first)", "\(failures.count) failed, \(first)"))
        }
        lastMessage = parts.joined(separator: ", ")
        lastMessageIsWarning = !failures.isEmpty
        isSweeping = false
        refreshDisk()
    }

    /// 진행 중인 삭제를 멈춥니다. 지우고 있던 항목은 마저 지우고 다음 항목부터 멈춥니다.
    func stopSweep() {
        sweepTask?.cancel()
    }

    /// 다 못 지운 행을 남은 크기로 고쳐 두고 체크를 풉니다. 다시 누르면 남은 것만 지웁니다.
    private func markFailed(_ candidate: Candidate, freed: Int64) {
        guard var scanned = result,
              let index = scanned.candidates.firstIndex(where: { $0.path == candidate.path }) else { return }
        let warning = freed > 0 ? L("일부만 지움", "Partly deleted") : L("삭제 실패", "Delete failed")
        scanned.candidates[index].bytes = max(0, candidate.bytes - freed)
        if !scanned.candidates[index].warnings.contains(warning) {
            scanned.candidates[index].warnings.append(warning)
        }
        result = scanned
        selected.remove(candidate.path)
    }

    /// 지운 행 하나를 부스러뜨리고, 애니메이션이 끝나면 목록에서 뺍니다.
    private func dissolve(_ path: String) {
        let start = max(Date(), nextDissolveAt)
        nextDissolveAt = start.addingTimeInterval(0.12)
        Task { @MainActor [weak self] in
            let delay = start.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self?.dissolving.insert(path)
            try? await Task.sleep(for: .seconds(Self.dissolveDuration))
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.result?.candidates.removeAll { $0.path == path }
            }
            self.selected.remove(path)
            self.dissolving.remove(path)
        }
    }

    // MARK: - 주기 실행

    /// 마지막으로 훑은 시각입니다. 앱을 껐다 켜도 주기가 이어지도록 저장합니다.
    ///
    /// 이게 없으면 주기가 "앱을 켠 뒤 흐른 시간"이 됩니다. 매주로 두면 맥이 7일 연속
    /// 켜져 있어야만 한 번 발화하고, 재부팅하면 0일부터 다시 셉니다. 사실상 안 돕니다.
    private var lastScanAt: Date? {
        get { UserDefaults.standard.object(forKey: "lastScanAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastScanAt") }
    }

    /// 주기가 지났는지 확인하러 깨어나는 간격입니다.
    ///
    /// 7일짜리 타이머 하나를 걸어두면 그 사이 맥이 잠들었다 깨면서 발화 시점을 놓칩니다.
    /// 짧게 깨어나 "지날 때가 됐는지"만 보는 쪽이 확실합니다.
    private static let heartbeat: TimeInterval = 30 * 60

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard autoScanInterval.seconds != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.heartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scanIfDue() }
        }
    }

    /// 마지막 스캔 이후 주기가 지났으면 훑습니다.
    func scanIfDue() async {
        guard let interval = autoScanInterval.seconds, !isScanning, !needsSetup else { return }
        let elapsed = Date().timeIntervalSince(lastScanAt ?? .distantPast)
        guard elapsed >= interval else { return }
        await scan(notifyWhenDone: true)
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastMessage = L("로그인 항목 설정에 실패했습니다: \(error.localizedDescription)", "Couldn't update the login item: \(error.localizedDescription)")
        }
    }

    // MARK: - 알림

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notifyScanResult(_ result: ScanResult) {
        let reclaimable = result.reclaimableBytes
        // 회수할 게 얼마 없으면 알리지 않습니다. 주기 알림이 잔소리가 되면 끄게 됩니다.
        guard reclaimable > 1024 * 1024 * 1024 else { return }

        let content = UNMutableNotificationContent()
        content.title = L("정리할 공간 \(Format.bytes(reclaimable))", "\(Format.bytes(reclaimable)) can be cleaned up")
        content.body = L("후보 \(result.candidates.count)개를 찾았습니다. 메뉴바에서 확인하세요.", "Found \(result.candidates.count) items. Open Sweep from the menu bar to review.")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 룰 설정

    /// 룰 하나가 마지막 스캔에서 무슨 일을 했는지입니다.
    ///
    /// JSON만 봐서는 절대 알 수 없는 정보라, 룰 화면의 존재 이유이기도 합니다.
    /// allow 룰은 후보로 잡은 개수와 용량을, deny 룰은 걸러낸 곳의 수를 셉니다.
    struct RuleStat {
        var matched = 0
        var bytes: Int64 = 0
        var denied = 0

        var isEmpty: Bool { matched == 0 && denied == 0 }
    }

    func stat(for rule: Rule) -> RuleStat {
        var stat = RuleStat()
        stat.denied = result?.deniedCounts[rule.id] ?? 0
        for candidate in result?.candidates ?? [] where candidate.ruleID == rule.id {
            stat.matched += 1
            stat.bytes += candidate.bytes
        }
        return stat
    }

    func isRuleEnabled(_ rule: Rule) -> Bool {
        !overlay.disabledRuleIDs.contains(rule.id)
    }

    func setRule(_ rule: Rule, enabled: Bool) {
        if enabled {
            overlay.disabledRuleIDs.remove(rule.id)
        } else {
            overlay.disabledRuleIDs.insert(rule.id)
        }
        saveOverlay()
    }

    // MARK: - 첫 실행

    /// 홈을 훑어 프로젝트 폴더를 찾습니다. 수백 개 폴더를 보는 일이라 메인 스레드 밖에서 돕니다.
    func detectRoots() {
        isDetectingRoots = true
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                ProjectRootFinder.discover()
            }.value
            guard let self else { return }
            self.proposedRoots = found
            self.acceptedRoots = Set(found)
            self.isDetectingRoots = false
        }
    }

    /// 거절했거나 직접 뺀 폴더입니다. 다시 제안하지 않습니다.
    private var dismissedRoots: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "dismissedProjectRoots") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "dismissedProjectRoots") }
    }

    /// 저장한 폴더 밖에 새 저장소 묶음이 생겼는지 봅니다. 찾기는 0.1초 안팎이라 스캔할 때마다 돕니다.
    func checkForNewRoots() {
        guard !needsSetup else { return }
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { ProjectRootFinder.discover() }.value
            guard let self else { return }
            let saved = (self.overlay.projectRoots ?? []).map(RuleOverlay.key)
            let dismissed = self.dismissedRoots
            self.newRootSuggestions = found.filter { path in
                let key = RuleOverlay.key(path)
                let covered = saved.contains { key == $0 || key.hasPrefix($0 + "/") }
                return !covered && !dismissed.contains(key)
            }
        }
    }

    func acceptSuggestion(_ path: String) {
        addProjectRoot(path)
        newRootSuggestions.removeAll { $0 == path }
    }

    func dismissSuggestion(_ path: String) {
        dismissedRoots.insert(RuleOverlay.key(path))
        newRootSuggestions.removeAll { $0 == path }
    }

    func toggleProposed(_ path: String) {
        if acceptedRoots.contains(path) { acceptedRoots.remove(path) } else { acceptedRoots.insert(path) }
    }

    /// 폴더 선택 창에서 고른 폴더를 제안 목록에 더합니다.
    ///
    /// 홈 밖의 폴더는 받지 않습니다. 훑을 수는 있어도 삭제 단계의 안전 확인이 홈 안만
    /// 허용해서, 찾아만 놓고 하나도 지울 수 없는 목록이 됩니다.
    func addPickedFolders(_ urls: [URL]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var rejected = false
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(home + "/") else { rejected = true; continue }
            let short = SweepScanner.abbreviate(path)
            if !proposedRoots.contains(short) { proposedRoots.append(short) }
            acceptedRoots.insert(short)
        }
        lastMessage = rejected ? L("홈 폴더 안만 고를 수 있습니다", "Only folders inside your home folder") : nil
    }

    /// 체크한 폴더를 저장하고 첫 스캔을 시작합니다. 아무것도 고르지 않아도 됩니다.
    /// 그때는 툴체인과 앱 캐시만 훑습니다.
    func confirmSetup() async {
        overlay.projectRoots = proposedRoots.filter { acceptedRoots.contains($0) }
        do {
            try overlay.save()
        } catch {
            lastMessage = L("설정을 저장하지 못했습니다: \(error.localizedDescription)", "Couldn't save settings: \(error.localizedDescription)")
            return
        }
        requestNotificationPermission()
        await scan()
    }

    /// 지금 검사 대상인 프로젝트 폴더입니다. 정한 적이 없으면 자동 감지 결과가 나옵니다.
    var projectRoots: [String] { overlay.resolvedProjectRoots() }

    /// 자동 감지 결과를 그대로 쓰고 있는 상태인지입니다. 화면에서 이걸 알려줘야
    /// 사용자가 "왜 이 폴더가 여기 있지"를 묻지 않습니다.
    var usesDetectedRoots: Bool { overlay.projectRoots == nil }

    func addProjectRoot(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 자동 감지 상태에서 처음 손대면 그 목록을 그대로 굳히고 시작합니다.
        var roots = overlay.resolvedProjectRoots()
        guard !roots.contains(trimmed) else { return }
        roots.append(trimmed)
        overlay.projectRoots = roots
        saveOverlay()
    }

    func removeProjectRoot(_ path: String) {
        // 직접 뺀 폴더를 다음 스캔에서 다시 제안하면 뺀 의미가 없습니다.
        dismissedRoots.insert(RuleOverlay.key(path))
        var roots = overlay.resolvedProjectRoots()
        roots.removeAll { $0 == path }
        overlay.projectRoots = roots
        saveOverlay()
    }

    func addExclusion(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !overlay.excludedPaths.contains(trimmed) else { return }
        overlay.excludedPaths.append(trimmed)
        saveOverlay()
    }

    func removeExclusion(_ path: String) {
        overlay.excludedPaths.removeAll { $0 == path }
        saveOverlay()
    }

    private func saveOverlay() {
        do {
            try overlay.save()
            // 룰이 바뀌면 후보가 달라집니다. 다시 훑기 전까지는 화면이 옛 결과입니다.
            rulesDirty = true
        } catch {
            lastMessage = L("룰 설정을 저장하지 못했습니다: \(error.localizedDescription)", "Couldn't save rules: \(error.localizedDescription)")
        }
    }

    // MARK: - 바로가기

    func openRulesFile() {
        let url = RuleEngine.userRulesURL
        // 파일이 없으면 기본 룰을 내보내 편집 출발점을 만들어 줍니다. 이때 지문을 같이
        // 남겨야, 열어보기만 하고 안 고친 파일이 기본 룰을 가리는 일을 막을 수 있습니다.
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try RuleEngine.exportDefaultsToUserFile(overlay: &overlay)
            } catch {
                lastMessage = L("룰 파일을 만들지 못했습니다: \(error.localizedDescription)", "Couldn't create the rules file: \(error.localizedDescription)")
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    func revealHistory() {
        let url = Sweeper.historyURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        } else {
            lastMessage = L("아직 삭제 이력이 없습니다", "No deletion history yet")
        }
    }
}
