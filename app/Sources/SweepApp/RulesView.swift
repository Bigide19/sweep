import SwiftUI
import SweepCore

/// 룰 설정 창입니다.
///
/// 정규식과 우선순위는 여기서 편집하지 않습니다. 그건 파일이 더 빠르고, 창에서 하면
/// 오히려 나쁩니다. 대신 파일이 절대 못 보여주는 것을 보여줍니다. 각 룰이 마지막 스캔에서
/// 실제로 무엇을 잡았고 무엇을 걸렀는지입니다.
struct RulesView: View {
    @Bindable var model: AppModel
    @State private var newExclusion = ""
    @State private var newRoot = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rootSection
                    exclusionSection
                    // 제목은 누구나 알아듣는 말로 두고, 룰 파일에 적히는 값(allow, deny)은
                    // 설명 끝에 붙여 파일과 대조할 수 있게 합니다.
                    ruleSection(kind: .allow,
                                title: L("삭제 대상", "Clean"),
                                caption: L("삭제 후보로 잡습니다 · allow", "Offered for deletion · allow"))
                    ruleSection(kind: .deny,
                                title: L("보호", "Protect"),
                                caption: L("건드리지 않습니다 · deny", "Never touched · deny"))
                }
                .padding(16)
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 460, idealHeight: 620)
        // 문구가 L()로 그릴 때 정해지므로, 언어가 바뀌면 트리를 새로 만들어 한 번에 바꿉니다.
        .id(model.language)
    }

    // MARK: - 헤더

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("룰 설정", "Rules")).font(.headline)
                Spacer()
                Button(L("룰 파일 편집", "Edit Rules File")) { model.openRulesFile() }
                    .controlSize(.small)
            }

            // 룰이 바뀌면 후보 자체가 달라집니다. 다시 훑기 전까지 아래 숫자는 옛 결과입니다.
            if model.rulesDirty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("다시 스캔해야 반영됩니다", "Rescan to apply changes"))
                        .font(.caption)
                    Spacer()
                    Button(L("다시 스캔", "Rescan")) { Task { await model.scan() } }
                        .controlSize(.small)
                        .disabled(model.isScanning)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
    }

    // MARK: - 경로 목록

    /// 프로젝트를 찾을 폴더입니다. 사람마다 다르니 코드에 박지 않고 여기서 받습니다.
    private var rootSection: some View {
        pathSection(
            title: L("검사할 폴더", "Scan Folders"),
            caption: model.usesDetectedRoots
                ? L("자동 감지", "Auto-detected")
                : "",
            icon: "folder",
            paths: model.projectRoots,
            field: $newRoot,
            placeholder: "~/code",
            add: { model.addProjectRoot($0) },
            remove: { model.removeProjectRoot($0) })
    }

    private var exclusionSection: some View {
        pathSection(
            title: L("제외할 경로", "Excluded Paths"),
            caption: "",
            icon: "minus.circle",
            paths: model.overlay.excludedPaths,
            field: $newExclusion,
            placeholder: L("~/Projects/건드리면-안-되는-것", "~/Projects/do-not-touch"),
            add: { model.addExclusion($0) },
            remove: { model.removeExclusion($0) })
    }

    /// 섹션 제목과 짧은 설명을 한 줄에 둡니다. 설명이 따로 한 줄을 차지할 만큼 길지 않습니다.
    private func sectionTitle(_ title: String, _ caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 경로 목록 하나를 그립니다. 검사할 폴더와 제외할 경로가 같은 모양이라 함께 씁니다.
    private func pathSection(title: String, caption: String, icon: String,
                             paths: [String], field: Binding<String>, placeholder: String,
                             add: @escaping (String) -> Void,
                             remove: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title, caption)

            if paths.isEmpty {
                Text(L("없음", "None")).font(.caption).foregroundStyle(.tertiary)
            }

            ForEach(paths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button {
                        remove(path)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            }

            HStack(spacing: 8) {
                TextField(placeholder, text: field)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit {
                        add(field.wrappedValue)
                        field.wrappedValue = ""
                    }
                Button(L("추가", "Add")) {
                    add(field.wrappedValue)
                    field.wrappedValue = ""
                }
                .disabled(field.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)

                // 손으로 치면 오타가 납니다. 오타 난 경로는 조용히 아무 일도 안 합니다.
                // 창이 뜨는 버튼이라 말줄임표를 붙입니다. macOS 관례입니다.
                Button(L("찾아보기…", "Browse…")) {
                    guard let picked = Self.pickFolder() else { return }
                    add(picked)
                    field.wrappedValue = ""
                }
            }
            .controlSize(.small)
        }
    }

    private static func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return SweepScanner.abbreviate(url.path)
    }

    // MARK: - 룰 목록

    private func ruleSection(kind: RuleKind, title: String, caption: String) -> some View {
        let rules = model.baseRules
            .filter { $0.kind == kind }
            .sorted { $0.priority > $1.priority }

        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title, caption)

            VStack(spacing: 0) {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { Divider() }
                    ruleRow(rule)
                }
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        let enabled = model.isRuleEnabled(rule)
        let stat = model.stat(for: rule)

        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { model.setRule(rule, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.title ?? rule.id)
                        .font(.callout)
                        .fontWeight(.medium)
                    if let category = rule.category {
                        tag(category.label)
                    }
                    if let cost = rule.cost {
                        tag(cost.label)
                    }
                }

                if let note = rule.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }

                Text(rule.regex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // 이 룰이 실제로 한 일입니다. 파일만 봐서는 알 수 없는 유일한 정보라
            // 오른쪽 끝 고정 자리를 내줍니다.
            VStack(alignment: .trailing, spacing: 1) {
                if stat.matched > 0 {
                    Text(L("\(stat.matched)개 \(Format.bytes(stat.bytes))", "\(stat.matched) · \(Format.bytes(stat.bytes))"))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.primary)
                }
                if stat.denied > 0 {
                    Text(L("\(stat.denied)곳 걸러냄", "\(stat.denied) skipped"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if stat.isEmpty {
                    Text(model.result == nil ? L("스캔 전", "Not scanned") : L("잡은 것 없음", "No matches"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(enabled ? 1 : 0.45)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}
