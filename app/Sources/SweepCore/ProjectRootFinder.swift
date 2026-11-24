import Foundation

/// 처음 실행할 때 프로젝트 폴더를 찾아 제안합니다.
///
/// 결과는 제안일 뿐이고 사용자가 확인한 것만 저장합니다. 찾는 방식은 홈 아래 몇 단까지
/// 내려가며 `.git`이 있는 폴더를 모으는 것입니다. 저장소 여럿이 한 폴더에 모여 있으면
/// 그 폴더를, 홈 바로 아래 저장소는 저장소 자체를 제안합니다.
public enum ProjectRootFinder {

    /// 홈에서 몇 단 아래까지 저장소를 찾을지입니다. `~/a/b/c`까지 봅니다.
    static let maxDepth = 3

    /// 들어가지 않는 홈 바로 아래 폴더입니다.
    ///
    /// Desktop, Documents, Downloads는 macOS 보호 폴더라 들여다보는 순간 접근 허용 창이
    /// 뜹니다. 거기 둔 프로젝트는 사용자가 폴더 선택으로 직접 추가합니다. 동기화 폴더에서
    /// 지우면 다른 기기에서도 지워지니 빼고, 가상 머신 폴더는 크기만 크고 프로젝트가 없습니다.
    static let skippedHomeChildren: Set<String> = [
        "Library", "Applications", "Desktop", "Documents", "Downloads",
        "Movies", "Music", "Pictures", "Public",
        "Dropbox", "Google Drive", "OneDrive", "Box", "iCloud Drive",
        "Parallels", "Virtual Machines.localized", "VirtualBox VMs",
    ]

    /// 어느 깊이에서든 들어가지 않는 폴더입니다. 저장소가 없거나 너무 많습니다.
    static let skippedNames: Set<String> = ["node_modules", "Pods", "vendor", "venv"]

    /// 제안할 폴더 목록입니다. `~/...` 꼴로 돌려줍니다.
    ///
    /// `home`은 시험용입니다. 가짜 홈 폴더를 만들어 찾는 규칙을 확인할 때 씁니다.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let homeVolume = volumeID(of: home)
        var repos: [URL] = []
        visit(home, depth: 0, homeVolume: homeVolume, repos: &repos)

        var roots: [String] = []
        for repo in repos where !SafetyGuards.isToolCheckout(repo.path) {
            let parent = repo.deletingLastPathComponent()
            // 홈 바로 아래 저장소를 그대로 묶으면 홈 전체가 검사 폴더가 됩니다.
            let root = parent.path == home.path ? repo : parent
            roots.append(SweepScanner.abbreviate(root.path))
        }
        roots += DefaultRuleSet.detectedProjectRoots(home: home.path)

        // 같은 폴더와 다른 폴더 안에 든 폴더를 걸러 겹쳐 훑지 않게 합니다.
        let deduped = RuleOverlay.deduped(roots.map { ScanRoot(path: $0, mode: .walk) })
        return deduped.map(\.path).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func visit(_ dir: URL, depth: Int, homeVolume: AnyHashable?, repos: inout [URL]) {
        let fm = FileManager.default
        if depth > 0, fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            repos.append(dir)
            return
        }
        guard depth < maxDepth else { return }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .volumeIdentifierKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            if depth == 0, skippedHomeChildren.contains(name) || name.hasPrefix("OneDrive") { continue }
            if skippedNames.contains(name) { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  values.isPackage != true else { continue }
            // 마운트한 네트워크 폴더나 외장 디스크로 넘어가지 않습니다. 느리고, 지울 곳도 아닙니다.
            if let homeVolume, let volume = values.volumeIdentifier as? AnyHashable, volume != homeVolume { continue }
            visit(entry, depth: depth + 1, homeVolume: homeVolume, repos: &repos)
        }
    }

    private static func volumeID(of url: URL) -> AnyHashable? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? AnyHashable
    }
}
