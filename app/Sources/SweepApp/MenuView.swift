import SwiftUI
import SweepCore

/// 화면 전반의 글자 크기입니다.
///
/// macOS에서 `.caption`, `.caption2`, `.footnote`는 전부 10pt로 같습니다. 예전에는
/// 이 셋을 섞어 썼는데 크기가 다르지 않으니 위계가 생기지 않았고, 화면 전체가
/// 10pt 한 덩어리로 보였습니다. 실제로 차이가 나는 단계만 골라 세 층으로 나눕니다.
/// 여기만 고치면 화면 전체의 크기가 함께 움직입니다.
enum MenuFont {
    /// 후보 이름, 크기, 카테고리 헤더, 푸터에 씁니다. 12pt입니다.
    static let row = Font.callout
    /// 경로, 배지, 방치 일수처럼 본문에 딸린 정보입니다. 11pt입니다.
    static let meta = Font.subheadline
    /// 헤더에 크게 박히는 숫자입니다. 15pt이고, 숫자 폭이 고르게 보이도록 rounded를 씁니다.
    static let stat = Font.system(.title3, design: .rounded).weight(.medium)
}

/// 행의 열 너비입니다. 행마다 같은 값을 써야 크기와 일수가 세로로 줄을 맞춥니다.
private enum Column {
    static let check: CGFloat = 16
    static let idle: CGFloat = 34
    static let cost: CGFloat = 78
    static let size: CGFloat = 64
}

/// 행 높이입니다. 목록 높이를 미리 계산하는 데 씁니다. 실제 패딩과 함께 바꿔야 합니다.
private enum RowHeight {
    static let candidate: CGFloat = 24
    static let header: CGFloat = 34
}

struct MenuView: View {
    let model: AppModel
    /// 지우는 동안 붙잡아 둔 목록 높이입니다. 행이 빠질 때마다 팝오버 높이가 줄면
    /// 화면이 계속 출렁입니다. 다 지운 뒤 한 번에 줄입니다.
    @State private var frozenListHeight: CGFloat?

    /// 목록이 차지할 수 있는 최대 높이입니다.
    ///
    /// 예전에는 480pt로 고정해서 큰 화면에서도 후보 60여 개를 좁은 창으로 넘겨 봐야 했습니다.
    /// 목록은 세로로 훑는 것이라 폭보다 높이를 넉넉히 줍니다. 화면 높이에서 헤더와 푸터 몫만 뺍니다.
    private var listMaxHeight: CGFloat {
        // 220은 헤더와 푸터, 메뉴바 아래 여백 몫입니다. 헤더 구성을 바꾸면 함께 봐야 합니다.
        max(320, min(1000, model.popoverScreenHeight - 300))
    }

    /// 지금 펼쳐진 상태 그대로 목록을 그렸을 때의 높이입니다.
    private var estimatedListHeight: CGFloat {
        var rows = 0
        var headers = 0
        for category in SweepCategory.allCases {
            let items = model.candidates(in: category)
            guard !items.isEmpty else { continue }
            headers += 1
            guard !model.collapsed.contains(category) else { continue }
            let locked = items.filter { !$0.isDeletable }.count
            rows += items.count - locked
            if locked > 0 {
                rows += 1 + (model.expandedLocked.contains(category) ? locked : 0)
            }
        }
        // 스캔 중이라 아직 결과가 없을 때도 빈칸으로 쪼그라들지 않게 최소 높이를 둡니다.
        return max(120, CGFloat(headers) * RowHeight.header + CGFloat(rows) * RowHeight.candidate + 6)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.result == nil {
                emptyState
            } else {
                columnHeader
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(SweepCategory.allCases.sorted { $0.order < $1.order }, id: \.self) { category in
                            let items = model.candidates(in: category)
                            if !items.isEmpty {
                                categorySection(category, items: items)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                // 팝오버는 ScrollView의 이상적인 높이를 내용만큼 잡아주지 않아서, maxHeight만
                // 주면 목록이 몇 줄짜리로 쪼그라듭니다. 내용 높이를 직접 계산해 정합니다.
                .frame(height: frozenListHeight ?? min(listMaxHeight, estimatedListHeight))
            }

            Divider()
            footer
        }
        .frame(width: 520)
        .onChange(of: model.isSweeping) { _, sweeping in
            frozenListHeight = sweeping ? min(listMaxHeight, estimatedListHeight) : nil
        }
        // 문구는 L()이 그릴 때마다 읽는데, SwiftUI는 입력이 같은 하위 뷰를 다시 그리지 않습니다.
        // 언어가 바뀌면 트리를 통째로 새로 만들어 모든 문구가 한 번에 바뀌게 합니다.
        .id(model.language)
    }

    // MARK: - 헤더

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                // 제일 크게 보이는 숫자는 실제로 일어날 일이어야 합니다. 그래서 "정리 가능"
                // 전체가 아니라 지금 고른 만큼을 앞에 둡니다. 전체는 게이지 툴팁에 있습니다.
                if model.result != nil {
                    stat(L("지울 용량", "To Delete"), Format.bytes(model.selectedBytes), .accentColor)
                }
                stat(L("남은 공간", "Free"), Format.bytes(model.disk.free), .primary)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await model.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isSweeping || model.needsSetup)
                    .help(scanHelp)
                }
            }

            diskGauge

            if model.result != nil, case .scanning(let path) = model.phase {
                Text(path)
                    .font(MenuFont.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            if let message = model.lastMessage {
                Text(message)
                    .font(MenuFont.row)
                    .foregroundStyle(model.lastMessageIsWarning ? .orange : .green)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // 한 번에 하나씩 묻습니다. 처리하면 다음 폴더가 올라옵니다.
            if let path = model.newRootSuggestions.first {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.tint)
                    Text(L("새 프로젝트 폴더", "New project folder"))
                        .foregroundStyle(.secondary)
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L("추가", "Add")) { model.acceptSuggestion(path) }
                    Button(L("무시", "Ignore")) { model.dismissSuggestion(path) }
                }
                .font(MenuFont.meta)
                .controlSize(.small)
            }
        }
        .padding(14)
    }

    private var scanHelp: String {
        guard let result = model.result else { return L("스캔", "Scan") }
        return L("다시 스캔 (마지막 스캔 \(Format.relativeDate(result.scannedAt)))", "Rescan (last scan \(Format.relativeDate(result.scannedAt)))")
    }

    /// 디스크가 얼마나 찼는지, 그리고 지금 고른 걸 지우면 어디까지 내려가는지 보여줍니다.
    /// 숫자만 있으면 "38GB 정리 가능"이 큰지 작은지 감이 안 옵니다.
    private var diskGauge: some View {
        let disk = model.disk
        let selected = model.selectedBytes
        let reclaimable = model.result?.reclaimableBytes ?? 0
        let after = disk.percentAfterFreeing(selected)
        // 고를 수 있는데 아직 안 고른 몫입니다. 게이지에 연한 색으로 보여서
        // "정리 가능"과 "선택"의 관계가 글 없이 그림 하나로 읽힙니다.
        let pending = max(0, reclaimable - selected)
        // 비율은 여기서 미리 냅니다. ViewBuilder 클로저 안에는 함수를 선언할 수 없습니다.
        let selectedRatio = disk.total > 0 ? Double(selected) / Double(disk.total) : 0
        let pendingRatio = disk.total > 0 ? Double(pending) / Double(disk.total) : 0

        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let usedWidth = width * disk.usedRatio
                // 사용 구간 오른쪽 끝에 정리 가능분을 몰아놓고, 그중 선택분을 다시
                // 여유 공간 쪽에 붙입니다. 선택분이 곧 넘어갈 몫이라는 게 읽힙니다.
                let selectedWidth = min(usedWidth, width * selectedRatio)
                let pendingWidth = min(max(0, usedWidth - selectedWidth), width * pendingRatio)

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: max(0, usedWidth - selectedWidth - pendingWidth))
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: pendingWidth)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: selectedWidth)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .help(reclaimable > 0
                  ? L("정리 가능 \(Format.bytes(reclaimable)), 전부 고르면 \(disk.percentAfterFreeing(reclaimable))%", "\(Format.bytes(reclaimable)) reclaimable, \(disk.percentAfterFreeing(reclaimable))% if all selected")
                  : "")

            HStack(spacing: 5) {
                Text("\(Format.bytes(disk.used)) / \(Format.bytes(disk.total))")
                    .font(MenuFont.meta)
                    .foregroundStyle(.secondary)
                Text("\(disk.percent)%")
                    .font(MenuFont.meta.weight(.medium))
                    .foregroundStyle(disk.percent >= 90 ? .red : .secondary)
                if selected > 0 && after < disk.percent {
                    Text("→ \(after)%")
                        .font(MenuFont.meta.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(MenuFont.meta).foregroundStyle(.secondary)
            Text(value).font(MenuFont.stat).foregroundStyle(color)
        }
    }

    /// 첫 스캔 전과 첫 스캔 중에 보이는 자리입니다.
    ///
    /// 스캔 중에는 수십 초 동안 빈칸이면 멈춘 것처럼 보여서, 이름(sweep)에 맞춰 레이더가 훑는
    /// 그림을 둡니다. 스캔 전에는 그림 없이 버튼만 둡니다. 멈춘 레이더는 일하는 중처럼 읽힙니다.
    @ViewBuilder
    private var emptyState: some View {
        if case .scanning(let path) = model.phase {
            VStack(spacing: 14) {
                ScanRadar()
                    .frame(width: 132, height: 132)
                Text(path)
                    .font(MenuFont.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else if model.needsSetup {
            setupView
        } else {
            Button(L("스캔", "Scan")) { Task { await model.scan() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    /// 처음 실행했을 때 검사할 프로젝트 폴더를 확인받는 자리입니다.
    ///
    /// 찾은 폴더를 그대로 쓰지 않고 체크 목록으로 보여줍니다. 무엇을 훑는지 사용자가 먼저
    /// 봐야 하고, 못 찾은 폴더는 여기서 바로 더할 수 있어야 합니다.
    private var setupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("프로젝트 폴더", "Project Folders"))
                    .font(MenuFont.row.weight(.semibold))
                Text(L("빌드 산출물을 찾을 곳입니다", "Where to look for build output"))
                    .font(MenuFont.meta)
                    .foregroundStyle(.secondary)
            }

            if model.isDetectingRoots {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("찾는 중", "Looking…")).font(MenuFont.meta).foregroundStyle(.secondary)
                }
            } else if model.proposedRoots.isEmpty {
                Text(L("찾은 폴더 없음", "None found"))
                    .font(MenuFont.meta)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.proposedRoots, id: \.self) { path in
                    Toggle(isOn: Binding(get: { model.acceptedRoots.contains(path) },
                                         set: { _ in model.toggleProposed(path) })) {
                        Text(path).font(MenuFont.row)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack {
                Button(L("폴더 추가…", "Add Folder…")) { model.pickFolders?() }
                Spacer()
                Button(L("스캔", "Scan")) { Task { await model.confirmSetup() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isDetectingRoots)
            }
            .padding(.top, 4)
        }
        .padding(14)
    }

    /// 행 오른쪽 숫자 열의 이름입니다. 이게 없으면 "14d"가 무엇의 14일인지 알 수 없습니다.
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Spacer()
            Text(L("재빌드", "Rebuild"))
                .frame(width: Column.cost, alignment: .leading)
                .help(L("지운 뒤 되살리는 데 드는 비용", "What it takes to get it back after deleting"))
            Text(L("방치", "Idle"))
                .frame(width: Column.idle, alignment: .trailing)
                .help(L("안에서 마지막으로 수정된 뒤 지난 일수", "Days since anything inside was last modified"))
            Text(L("크기", "Size"))
                .frame(width: Column.size, alignment: .trailing)
        }
        .font(MenuFont.meta)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - 카테고리

    /// 룰 ID로 룰을 찾습니다. 행마다 지금 언어의 제목과 설명을 읽는 데 씁니다.
    private var rules: [String: Rule] {
        Dictionary(model.baseRules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func categorySection(_ category: SweepCategory, items: [Candidate]) -> some View {
        let deletable = items.filter(\.isDeletable)
        // 성격을 모르거나 잠긴 항목은 지울 수 없어서 고를 일도 없습니다. 예전에는 한 줄씩
        // 같은 사유 문장을 달고 섞여 있어서, 정작 고를 항목이 그 사이에 묻혔습니다.
        let locked = items.filter { !$0.isDeletable }
        let isCollapsed = model.collapsed.contains(category)

        return Section {
            if !isCollapsed {
                ForEach(deletable) { item in
                    let isDissolving = model.dissolving.contains(item.path)
                    CandidateRow(item: item, rule: rules[item.ruleID],
                                 isSelected: model.selected.contains(item.path)) {
                        model.toggle(item)
                    }
                    .modifier(DustDissolve(isActive: isDissolving))
                    // 흩날리는 알갱이가 윗줄 위로 지나가야 해서 앞으로 올립니다.
                    .zIndex(isDissolving ? 1 : 0)
                }
                if !locked.isEmpty {
                    lockedGroup(category, items: locked)
                }
            }
        } header: {
            categoryHeader(category, deletable: deletable, isCollapsed: isCollapsed)
        }
    }

    private func categoryHeader(_ category: SweepCategory, deletable: [Candidate],
                                isCollapsed: Bool) -> some View {
        let sum = deletable.reduce(Int64(0)) { $0 + $1.bytes }

        return HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(MenuFont.meta)
                .foregroundStyle(.secondary)
                .frame(width: Column.check)
            Text(category.label).font(MenuFont.row).fontWeight(.semibold)
            Text(Format.bytes(sum)).font(MenuFont.row).foregroundStyle(.secondary)
            Spacer()
            if !deletable.isEmpty {
                Button(L("전체", "All")) { model.toggleAll(in: category) }
                    .buttonStyle(.plain)
                    .font(MenuFont.meta)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleCollapse(category) }
        // 고정된 헤더 아래로 행이 지나가므로 바탕을 깔아 겹쳐 보이지 않게 합니다.
        .background(.bar)
    }

    private func lockedGroup(_ category: SweepCategory, items: [Candidate]) -> some View {
        let isExpanded = model.expandedLocked.contains(category)
        let sum = items.reduce(Int64(0)) { $0 + $1.bytes }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .frame(width: Column.check)
                Text(L("지울 수 없음 \(items.count)개", "\(items.count) locked"))
                    .font(MenuFont.meta)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Spacer()
                Text(Format.bytes(sum))
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: Column.size, alignment: .trailing)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleLocked(category) }
            .help(L("Sweep이 모르는 항목이거나 안전장치가 막은 항목입니다", "Unknown to Sweep, or blocked by a safety check"))

            if isExpanded {
                ForEach(items) { item in
                    CandidateRow(item: item, rule: rules[item.ruleID], isSelected: false) {}
                }
            }
        }
    }

    // MARK: - 푸터

    private var footer: some View {
        // Observable 모델에서 바인딩을 얻으려면 이 스코프 안에서 한 번 감싸야 합니다.
        @Bindable var model = model

        return HStack(spacing: 10) {
            if model.isSweeping {
                ProgressView().controlSize(.small)
                Text(L("삭제 중 \(model.sweepDone)/\(model.sweepTotal)", "Deleting \(model.sweepDone)/\(model.sweepTotal)"))
                    .font(MenuFont.row)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                // 지우고 있는 항목은 마저 지웁니다. 지우던 폴더를 반쯤 남기지 않으려는 것입니다.
                Button(L("멈춤", "Stop")) { model.stopSweep() }
                    .buttonStyle(.bordered)
            } else if model.awaitingConfirm {
                Text(L("\(Format.bytes(model.selectedBytes)) 영구 삭제할까요?", "Permanently delete \(Format.bytes(model.selectedBytes))?"))
                    .font(MenuFont.row.weight(.medium))
                    .foregroundStyle(.red)
                Spacer()
                // 취소를 오른쪽 끝, 곧 L("삭제…", "Delete…")가 있던 자리에 둡니다. 같은 자리에 진짜 삭제
                // 버튼이 오면 더블클릭 한 번으로 확인 단계를 건너뛰고 영구 삭제됩니다.
                Button(L("삭제", "Delete")) { Task { await model.sweep() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                Button(L("취소", "Cancel")) { model.awaitingConfirm = false }
                    .buttonStyle(.bordered)
            } else {
                Text(model.selected.isEmpty
                     ? L("선택 없음", "Nothing selected")
                     : L("\(model.selectedCandidates.count)개 · \(Format.bytes(model.selectedBytes))", "\(model.selectedCandidates.count) items · \(Format.bytes(model.selectedBytes))"))
                    .font(MenuFont.row)
                    .foregroundStyle(.secondary)
                Spacer()

                // 자주 바꾸지 않는 설정은 푸터 자리를 차지하지 않게 메뉴 안에 둡니다.
                Menu {
                    Picker(L("기본 선택", "Auto-select"), selection: $model.cleanupLevel) {
                        ForEach(SelectionPolicy.Level.allCases) { level in
                            Text("\(level.label) · \(level.detail)").tag(level)
                        }
                    }
                    Picker(L("자동 스캔", "Auto-scan"), selection: $model.autoScanInterval) {
                        ForEach(AppModel.AutoScanInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    Picker(L("언어", "Language"), selection: $model.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    Toggle(L("로그인 시 실행", "Launch at Login"), isOn: $model.launchAtLogin)
                    Divider()
                    Button(L("룰 설정…", "Rules…")) { model.showRulesWindow?() }
                    Button(L("삭제 이력", "Deletion History")) { model.revealHistory() }
                    Divider()
                    Text(L("누적 회수 \(Format.bytes(model.totalReclaimed))", "Reclaimed so far: \(Format.bytes(model.totalReclaimed))"))
                    Button(L("Sweep 종료", "Quit Sweep")) { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button(L("삭제…", "Delete…")) { model.awaitingConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.isScanning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - 후보 한 줄

/// 후보 하나를 한 줄로 그립니다.
///
/// 예전에는 이름 줄과 비용, 방치 일수 줄로 두 줄을 썼습니다. 비용 문구는 거의 모든 행에서
/// 같은 말("재다운로드 필요")이 반복돼서 정보가 없었고, 그만큼 한 화면에 보이는 행이 반으로
/// 줄었습니다. 고를 때 필요한 이름, 경고, 방치 일수, 크기만 남기고 나머지는 툴팁으로 옮겼습니다.
private struct CandidateRow: View {
    let item: Candidate
    /// 후보를 잡은 룰입니다. 스캔할 때 후보에 적어둔 제목은 그때 언어로 굳어 있어서,
    /// 화면에서는 지금 언어로 다시 읽은 룰의 제목과 설명을 씁니다.
    let rule: Rule?
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // 지울 수 없는 항목은 체크박스 대신 잠금 표시를 둡니다.
            Group {
                if item.isDeletable {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.system(size: 14))
                } else {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                }
            }
            .frame(width: Column.check)

            Text(title)
                .font(MenuFont.row).fontWeight(.medium)
                .foregroundStyle(item.isDeletable ? .primary : .tertiary)
                .lineLimit(1)
                .layoutPriority(2)

            Text(subtitle)
                .font(MenuFont.meta)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            // 미분류는 묶음 헤더가 이미 설명하므로 행마다 사유를 반복하지 않습니다.
            if let reason = item.blockReason, !item.unclassified {
                badge(reason, .red)
            }
            ForEach(item.warnings, id: \.self) { warning in
                badge(warning, .orange)
            }

            // 이름만으로 정체를 모를 때 바로 열어볼 수 있게 합니다. 행마다 늘 보이면
            // 시끄러우니 마우스를 올린 행에만 띄웁니다.
            if isHovering {
                Button(action: revealInFinder) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(L("Finder에서 보기", "Show in Finder"))
            }

            Spacer(minLength: 8)

            // 지우면 무엇을 치르는지입니다. 문장 대신 아이콘과 짧은 값으로 열을 맞춰서
            // 위아래로 훑으며 비교할 수 있게 합니다.
            Group {
                if item.isDeletable { CostChip(cost: item.cost) }
            }
            .frame(width: Column.cost, alignment: .leading)

            // 정리 강도가 방치 일수로 판단하니 그 근거를 그대로 보여줍니다.
            Text(idleText)
                .font(MenuFont.meta)
                .foregroundStyle(.tertiary)
                .frame(width: Column.idle, alignment: .trailing)

            Text(Format.bytes(item.bytes))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(item.isDeletable ? .primary : .tertiary)
                .frame(width: Column.size, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L("Finder에서 보기", "Show in Finder"), action: revealInFinder)
            Button(L("경로 복사", "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
        .help(tooltip)
    }

    /// 프로젝트 산출물은 프로젝트 이름이 앞에 와야 한눈에 구별됩니다.
    ///
    /// 툴체인과 AI 캐시는 폴더 이름(`_cacache`, `modules-2`)으로는 정체를 알 수 없어서 룰 제목을
    /// 씁니다. 앱 캐시는 폴더 이름이 곧 앱 이름(Homebrew, JetBrains)이라 그대로 둡니다.
    private var ruleTitle: String? { rule?.title ?? item.title }

    private var usesRuleTitle: Bool {
        item.project == nil && ruleTitle != nil
            && (item.category == .toolchainCache || item.category == .aiAgent)
    }

    private var title: String {
        if let project = item.project { return project }
        if usesRuleTitle, let ruleTitle { return ruleTitle }
        return (item.path as NSString).lastPathComponent
    }

    private var subtitle: String {
        if item.project != nil { return item.display }
        if usesRuleTitle { return SweepScanner.abbreviate(item.path) }
        return SweepScanner.abbreviate((item.path as NSString).deletingLastPathComponent)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    private var idleText: String {
        guard let idle = item.idleDays, idle >= 7 else { return "" }
        return L("\(idle)일", "\(idle)d")
    }

    private var tooltip: String {
        var lines = [SweepScanner.abbreviate(item.path)]
        if item.isDeletable { lines.append(item.cost.label) }
        if let idle = item.idleDays { lines.append(idle == 0 ? L("오늘 수정", "Modified today") : L("\(idle)일 전 수정", "Modified \(idle) days ago")) }
        if let reason = item.blockReason { lines.append(reason) }
        if let note = rule?.note ?? item.note { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(MenuFont.meta)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .layoutPriority(1)
    }
}

// MARK: - 재생성 비용 표시

/// 지운 뒤 되돌리는 데 드는 비용을 아이콘과 짧은 값으로 보여줍니다.
///
/// "재빌드 수초", "재다운로드 필요" 같은 문장은 매 행 반복되면 읽히지 않습니다. 아이콘 모양으로
/// 종류(빌드, 다운로드, 인덱스)를, 색으로 부담(10분 이상만 주황)을 구별합니다.
private struct CostChip: View {
    let cost: RegenerateCost

    var body: some View {
        if let style {
            HStack(spacing: 3) {
                Image(systemName: style.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                Text(style.text)
                    .font(MenuFont.meta)
                    .lineLimit(1)
            }
            .foregroundStyle(style.color)
            .help(cost.label)
        }
    }

    private var style: (symbol: String, text: String, color: Color)? {
        switch cost {
        // 대부분의 산출물이 여기 해당해서, 눈에 띄는 색을 주면 모든 행이 시끄러워집니다.
        case .instant:    return ("bolt.fill", L("즉시", "Instant"), .secondary)
        case .quick:      return ("clock", L("~2분", "~2 min"), .secondary)
        case .slow:       return ("hourglass", L("10분+", "10+ min"), .orange)
        case .download:   return ("arrow.down.circle", L("다운로드", "Download"), .secondary)
        case .reindex:    return ("magnifyingglass", L("재색인", "Reindex"), .secondary)
        // 다시 만들 일이 없으니 보여줄 비용도 없습니다.
        case .disposable: return nil
        }
    }
}

// MARK: - 스캔 애니메이션

/// 레이더처럼 한 바퀴씩 훑는 그림입니다. 앱 이름과 메뉴바 아이콘(✨)을 그대로 가져왔습니다.
private struct ScanRadar: View {
    /// 한 바퀴 도는 데 걸리는 초입니다.
    private let period: Double = 2.4

    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period * 360

            ZStack {
                ForEach([1.0, 0.68, 0.36], id: \.self) { scale in
                    Circle()
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                        .scaleEffect(scale)
                }

                // 빛줄기 끝에서 뒤로 갈수록 옅어지는 부채꼴입니다.
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.accentColor.opacity(0), location: 0),
                            .init(color: Color.accentColor.opacity(0), location: 0.72),
                            .init(color: Color.accentColor.opacity(0.45), location: 1),
                        ]),
                        center: .center))
                    .rotationEffect(.degrees(angle))

                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse)
            }
        }
    }
}

// MARK: - 삭제 애니메이션

/// 지운 행이 모래처럼 부스러져 오른쪽 위로 흩날립니다.
///
/// 행을 그림으로 떠서 조각내는 방식은 다크 모드에서 색이 틀어질 수 있어 쓰지 않습니다.
/// 대신 행을 왼쪽부터 지워가는 마스크를 씌우고, 지워지는 경계에서 알갱이를 뿌립니다.
private struct DustDissolve: ViewModifier {
    let isActive: Bool
    @State private var start: Date?
    @State private var grains: [DustGrain] = []

    /// 왼쪽 끝에서 오른쪽 끝까지 지워지는 데 걸리는 시간입니다. 나머지는 알갱이가 흩어지는 몫입니다.
    private static let wipe: Double = 0.8
    /// 알갱이가 위아래로 날아가도 잘리지 않게 행 밖으로 넓혀 그리는 폭입니다.
    private static let spill: CGFloat = 24

    func body(content: Content) -> some View {
        if isActive {
            TimelineView(.animation) { context in
                let elapsed = start.map { context.date.timeIntervalSince($0) } ?? 0
                let front = min(1, elapsed / Self.wipe) * 1.1 - 0.1

                content
                    .mask { eraser(front) }
                    .overlay {
                        Canvas { graphics, size in
                            draw(graphics, size: size, elapsed: elapsed)
                        }
                        .padding(.vertical, -Self.spill)
                        .allowsHitTesting(false)
                    }
            }
            .onAppear {
                start = Date()
                grains = DustGrain.scatter(count: 520)
            }
        } else {
            content
        }
    }

    /// 경계 왼쪽은 이미 흩어진 자리라 비우고, 경계는 살짝 흐리게 둡니다.
    private func eraser(_ front: Double) -> some View {
        let edge = max(0, front)
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: edge),
            .init(color: .black, location: min(1, max(0.0001, edge + 0.1))),
            .init(color: .black, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    private func draw(_ graphics: GraphicsContext, size: CGSize, elapsed: Double) {
        let width = size.width
        let rowHeight = size.height - Self.spill * 2
        for grain in grains {
            // 경계가 이 알갱이 자리를 지나는 순간 떨어져 나옵니다.
            let born = Self.wipe * (grain.x + 0.1) / 1.1
            let age = elapsed - born
            guard age > 0, age < grain.life else { continue }

            // 바람에 밀리듯 오른쪽으로 점점 빨라지고, 위로 떠오르며 조금씩 흔들립니다.
            let x = grain.x * width + grain.vx * age + 70 * age * age
            let y = Self.spill + grain.y * rowHeight + grain.vy * age - 18 * age * age
                + sin(age * 9 + grain.phase) * 1.5
            let fade = pow(1 - age / grain.life, 1.4)

            let rect = CGRect(x: x, y: y, width: grain.size, height: grain.size)
            graphics.fill(Path(rect), with: .color(grain.color.opacity(fade)))
        }
    }
}

/// 흩날리는 알갱이 하나입니다. 위치는 행 크기에 대한 비율로 둡니다.
private struct DustGrain {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
    var size: CGFloat
    var phase: Double
    var color: Color

    static func scatter(count: Int) -> [DustGrain] {
        (0..<count).map { _ in
            let roll = Double.random(in: 0..<1)
            return DustGrain(
                x: .random(in: 0...1),
                y: .random(in: 0.2...0.8),
                vx: .random(in: 15...70),
                vy: .random(in: -30...8),
                life: .random(in: 0.45...0.8),
                size: .random(in: 1.4...2.8),
                phase: .random(in: 0...(2 * .pi)),
                // 글자색 알갱이가 대부분이고, 강조색이 조금 섞여 체크된 행의 바탕색을 이어받습니다.
                color: roll < 0.6 ? .primary : roll < 0.82 ? .secondary : .accentColor)
        }
    }
}
