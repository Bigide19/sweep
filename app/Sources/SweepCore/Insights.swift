import Foundation

/// Sweep이 지우지 않지만 크기와 줄이는 방법을 알려 주는 항목입니다.
///
/// VM 이미지, Docker 디스크, 로컬 스냅샷처럼 디스크를 크게 차지하지만 "다시 만들 수 있는
/// 산출물"이 아닌 것들입니다. 후보(`Candidate`)로 다루면 경로 단위 삭제와 이력에 섞이는데,
/// 이것들은 지우는 방법이 앱 안의 기능이거나 도구 명령이라 경로를 지우면 오히려 망가집니다.
/// 그래서 따로 모아 보여 주기만 하고, 도구가 제공하는 정리 명령이 있을 때만 그 명령을 실행합니다.
public struct Insight: Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case virtualMachine, docker, simulators, localSnapshots, purgeable,
             trash, xcodeArchives, agentImage, installers
    }

    public var id: String { kind.rawValue + ":" + (path ?? title) }
    public let kind: Kind
    public let title: String
    public let path: String?
    /// 크기를 알 수 없으면 nil입니다. 로컬 스냅샷은 크기를 알려 주는 API가 없습니다.
    public let bytes: Int64?
    /// 무엇이고 어떻게 줄이는지입니다.
    public let detail: String
    /// 도구가 제공하는 정리 명령입니다. 없으면 보여 주기만 합니다.
    public let action: ToolAction?
}

/// 정해진 도구 명령 하나입니다. 경로를 지우지 않고 도구에게 정리를 맡깁니다.
public struct ToolAction: Sendable, Hashable {
    public let id: String
    public let title: String
    public let executable: String
    public let arguments: [String]
    /// 정리 명령은 몇 분 걸릴 수 있지만, 데몬이 멈춰 있으면 끝나지 않으니 상한을 둡니다.
    public let timeout: TimeInterval
    public let environment: [String: String]?

    public var commandLine: String {
        ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
    }
}

public enum InsightScanner {

    /// 이보다 작으면 보여 주지 않습니다. 직접 손볼 만한 크기만 올립니다.
    static let minBytes: Int64 = 1024 * 1024 * 1024

    /// 큰 항목을 모읍니다. 외부 명령마다 타임아웃이 있어 오래 매달리지 않습니다.
    ///
    /// `includeDownloads`는 다운로드 폴더의 설치 파일까지 볼지입니다. 다운로드 폴더는 macOS가
    /// 보호하는 폴더라 읽으면 권한 창이 뜹니다. 사용자가 명시적으로 원할 때만 봅니다.
    ///
    /// `includeOtherAppData`는 다른 앱의 `~/Library/Containers`(Docker, UTM)와 휴지통을 읽을지입니다.
    /// 메뉴바 앱이 읽으면 macOS가 권한 창을 띄울 수 있어서 앱은 끄고, 터미널 권한으로 도는 CLI만 켭니다.
    public static func scan(includeDownloads: Bool = false, includeOtherAppData: Bool = true) -> [Insight] {
        var insights: [Insight] = []
        insights += virtualMachines(includeContainers: includeOtherAppData)
        if let docker = docker(readDiskImage: includeOtherAppData) { insights.append(docker) }
        if let simulators = unavailableSimulators() { insights.append(simulators) }
        if let archives = sizedFolder("~/Library/Developer/Xcode/Archives", kind: .xcodeArchives,
                                      title: L("Xcode 아카이브", "Xcode archives"),
                                      detail: L("배포한 빌드와 dSYM입니다. 다시 만들 수 없어서 Sweep은 지우지 않습니다. 오래된 것은 Xcode Organizer에서 지웁니다.",
                                                "Shipped builds and their dSYMs. They can't be rebuilt, so Sweep leaves them. Remove old ones in the Xcode Organizer.")) {
            insights.append(archives)
        }
        if let image = sizedFolder("~/Library/Application Support/Claude/vm_bundles", kind: .agentImage,
                                   title: L("Claude 데스크톱 VM 이미지", "Claude desktop VM image"),
                                   detail: L("Claude 앱이 쓰는 VM 이미지입니다. 세션 데이터가 들어 있어 Sweep은 지우지 않습니다.",
                                             "The VM image the Claude app uses. It holds session data, so Sweep leaves it.")) {
            insights.append(image)
        }
        if includeOtherAppData, let trash = sizedFolder("~/.Trash", kind: .trash, title: L("휴지통", "Trash"),
                                   detail: L("휴지통에 든 파일도 디스크를 차지합니다. Finder에서 휴지통을 비우면 돌아옵니다.",
                                             "Files in the Trash still take up space. Empty the Trash in Finder to get it back.")) {
            insights.append(trash)
        }
        if let snapshots = localSnapshots() { insights.append(snapshots) }
        if let purgeable = purgeable() { insights.append(purgeable) }
        if includeDownloads, let installers = installers() { insights.append(installers) }
        return insights
    }

    /// 정리 명령을 실행합니다. 출력에 오류 문구가 섞여 나오도록 표준 오류도 함께 받습니다.
    public static func run(_ action: ToolAction) -> (succeeded: Bool, output: String) {
        let result = SafetyGuards.run(action.executable, action.arguments, timeout: action.timeout,
                                      environment: action.environment, mergeStderr: true)
        let succeeded = result.status == 0
        // 경로를 지운 게 아니라 크기를 셀 수 없습니다. 무엇을 언제 실행했는지만 남깁니다.
        try? Sweeper.appendHistory([SweepRecord(deletedAt: Date(), path: action.commandLine,
                                                ruleID: "action:" + action.id, bytes: 0,
                                                succeeded: succeeded,
                                                error: succeeded ? nil : lastLine(result.out))])
        return (succeeded, result.out)
    }

    static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").last.map(String.init)
    }

    // MARK: - VM

    static func virtualMachines(includeContainers: Bool) -> [Insight] {
        let fm = FileManager.default
        var places: [(folder: String, ext: String, app: String)] = [
            ("~/Parallels", "pvm", "Parallels"),
            ("~/Virtual Machines.localized", "vmwarevm", "VMware Fusion"),
        ]
        if includeContainers {
            places.append(("~/Library/Containers/com.utmapp.UTM/Data/Documents", "utm", "UTM"))
        }
        var result: [Insight] = []
        for place in places {
            let folder = SweepScanner.expand(place.folder)
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where (name as NSString).pathExtension == place.ext {
                let path = folder + "/" + name
                let bytes = SweepScanner.measure(path).bytes
                guard bytes >= minBytes else { continue }
                let snapshots = snapshotCount(path)
                var detail = L("\(place.app)의 가상 머신입니다. 디스크 압축은 게스트 OS 안에서 지운 공간만 돌려받습니다. VM을 끄고 \(place.app)에서 공간 확보를 실행합니다.",
                               "A \(place.app) virtual machine. Compacting only returns space freed inside the guest OS. Shut it down and reclaim space in \(place.app).")
                if snapshots > 0 {
                    detail += L(" 스냅샷 \(snapshots)개가 있습니다. 필요 없는 스냅샷을 지우면 그 뒤에 바뀐 만큼 줄어듭니다.",
                                " It has \(snapshots) snapshot(s). Deleting ones you don't need frees what changed after them.")
                }
                result.append(Insight(kind: .virtualMachine,
                                      title: (name as NSString).deletingPathExtension,
                                      path: path, bytes: bytes, detail: detail, action: nil))
            }
        }
        return result
    }

    /// Parallels는 스냅샷마다 `{UUID}.mem`, `.sav` 같은 파일 묶음을 Snapshots 폴더에 둡니다.
    static func snapshotCount(_ vm: String) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: vm + "/Snapshots") else { return 0 }
        return Set(names.filter { $0.hasPrefix("{") }.map { ($0 as NSString).deletingPathExtension }).count
    }

    // MARK: - Docker

    static let dockerCandidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    /// GUI 앱은 PATH가 짧아서 Docker CLI가 부르는 보조 프로그램을 못 찾을 수 있습니다.
    static let toolEnvironment = [
        "PATH": "/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin",
        "HOME": NSHomeDirectory(),
    ]

    /// Docker 디스크 이미지입니다.
    ///
    /// Docker를 켜지는 않습니다. 켜면 재시작 정책이 걸린 컨테이너가 함께 올라옵니다.
    /// 이미 켜져 있을 때만 build cache 정리 명령을 붙입니다. 이미지와 컨테이너는 사용자가
    /// 무엇을 다시 받아야 하는지 알고 골라야 해서 여기서 건드리지 않습니다.
    ///
    /// `readDiskImage`가 false면 Docker 앱의 Containers 폴더를 읽지 않습니다. 그때는 Docker가
    /// 켜져 있을 때만 CLI로 알아낸 정보를 보여 줍니다.
    static func docker(readDiskImage: Bool) -> Insight? {
        let raw = SweepScanner.expand("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        // 희소 파일이라 논리 크기는 수십 GB로 나옵니다. 실제로 차지한 크기를 봅니다.
        let allocated: Int64? = readDiskImage
            ? (try? URL(fileURLWithPath: raw).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize.map(Int64.init)
            : nil

        let title = L("Docker 디스크 이미지", "Docker disk image")
        let later = L(" Docker.raw는 Docker가 빈 공간을 돌려준 뒤에 줄어듭니다.",
                      " Docker.raw shrinks after Docker hands the space back.")
        guard let cli = dockerCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              run(cli, ["info", "--format", "{{.ServerVersion}}"], timeout: 5).status == 0 else {
            guard let allocated, allocated >= minBytes else { return nil }
            return Insight(kind: .docker, title: title, path: raw, bytes: allocated,
                           detail: L("Docker가 꺼져 있습니다. 켜져 있을 때 build cache만 따로 정리할 수 있습니다. 이미지와 볼륨은 Docker Desktop에서 고릅니다.",
                                     "Docker isn't running. While it runs, Sweep can clear the build cache alone. Pick images and volumes in Docker Desktop."),
                           action: nil)
        }

        let df = run(cli, ["system", "df", "--format", "{{json .}}"], timeout: 15)
        let rows = parseDockerDF(df.out)
        let cache = rows.first { $0.type == "Build Cache" }
        let images = rows.first { $0.type == "Images" }
        var detail = cache.map { L("build cache \($0.size) 중 \($0.reclaimable)를 지울 수 있습니다.",
                                   "\($0.reclaimable) of the \($0.size) build cache can be cleared.") }
            ?? L("build cache 크기를 읽지 못했습니다.", "Couldn't read the build cache size.")
        if let images {
            detail += L(" 안 쓰는 이미지 \(images.reclaimable)는 직접 고릅니다.",
                        " Unused images (\(images.reclaimable)) are yours to pick.")
        }
        detail += later
        let action = ToolAction(id: "docker-builder-prune",
                                title: L("build cache 정리", "Clear build cache"),
                                executable: cli, arguments: ["builder", "prune", "-f"],
                                timeout: 600, environment: toolEnvironment)
        return Insight(kind: .docker, title: title, path: raw, bytes: allocated,
                       detail: detail, action: action)
    }

    /// `docker system df --format '{{json .}}'`의 한 줄씩을 읽습니다.
    public static func parseDockerDF(_ text: String) -> [(type: String, size: String, reclaimable: String)] {
        text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["Type"] as? String else { return nil }
            let reclaimable = (object["Reclaimable"] as? String) ?? "0B"
            // "10.5GB (67%)"처럼 비율이 붙어 나옵니다. 크기만 씁니다.
            let size = reclaimable.split(separator: " ").first.map(String.init) ?? reclaimable
            return (type, (object["Size"] as? String) ?? "?", size)
        }
    }

    // MARK: - 시뮬레이터

    /// 지금 Xcode에 런타임이 없어 쓸 수 없게 된 시뮬레이터입니다.
    ///
    /// Xcode가 깔린 맥에서만 봅니다. 명령줄 도구만 있으면 simctl이 없고, 둘 다 없으면
    /// xcrun이 설치 창을 띄웁니다.
    static func unavailableSimulators() -> Insight? {
        let developer = run("/usr/bin/xcode-select", ["-p"], timeout: 5).out
        guard developer.contains(".app/Contents/Developer") else { return nil }
        let list = run("/usr/bin/xcrun", ["simctl", "list", "-j", "devices", "unavailable"], timeout: 20)
        guard list.status == 0, let data = list.out.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = object["devices"] as? [String: [[String: Any]]] else { return nil }
        let udids = runtimes.values.flatMap { $0 }.compactMap { $0["udid"] as? String }
        guard !udids.isEmpty else { return nil }
        let devices = SweepScanner.expand("~/Library/Developer/CoreSimulator/Devices")
        let bytes = udids.reduce(Int64(0)) { $0 + SweepScanner.measure(devices + "/" + $1).bytes }
        let action = ToolAction(id: "simctl-delete-unavailable",
                                title: L("쓸 수 없는 시뮬레이터 삭제", "Delete unavailable simulators"),
                                executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"],
                                timeout: 300, environment: nil)
        return Insight(kind: .simulators,
                       title: L("쓸 수 없는 시뮬레이터 \(udids.count)개", "\(udids.count) unavailable simulators"),
                       path: devices, bytes: bytes,
                       detail: L("지금 Xcode에 런타임이 없어 실행할 수 없는 기기입니다. 앱 데이터가 들어 있지만 다시 쓸 방법이 없습니다.",
                                 "Devices whose runtime the current Xcode no longer has. They hold app data but can't run again."),
                       action: action)
    }

    // MARK: - macOS가 관리하는 공간

    static func localSnapshots() -> Insight? {
        let out = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 10).out
        let count = out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
        guard count > 0 else { return nil }
        return Insight(kind: .localSnapshots,
                       title: L("Time Machine 로컬 스냅샷 \(count)개", "\(count) local Time Machine snapshots"),
                       path: nil, bytes: nil,
                       detail: L("백업 디스크가 연결되지 않았을 때 남겨 두는 스냅샷입니다. macOS가 공간이 필요해지면 스스로 지웁니다.",
                                 "Snapshots kept while the backup disk is away. macOS removes them when it needs the space."),
                       action: nil)
    }

    /// macOS가 필요할 때 스스로 비우는 공간입니다. 남은 공간 표시에 이미 포함돼 있습니다.
    static func purgeable() -> Insight? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeAvailableCapacityKey]),
              let important = values.volumeAvailableCapacityForImportantUsage,
              let plain = values.volumeAvailableCapacity else { return nil }
        let bytes = important - Int64(plain)
        guard bytes >= minBytes else { return nil }
        return Insight(kind: .purgeable, title: L("macOS가 비울 수 있는 공간", "Space macOS can purge"),
                       path: nil, bytes: bytes,
                       detail: L("캐시와 로컬 스냅샷처럼 macOS가 필요할 때 스스로 비우는 공간입니다. 남은 공간에 이미 포함돼 있습니다.",
                                 "Caches and local snapshots macOS clears on demand. Already counted as free."),
                       action: nil)
    }

    // MARK: - 다운로드 폴더

    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso", "xip", "exe", "msi", "apk", "aab", "ipa"]

    /// 받은 지 30일이 넘은 설치 파일입니다. 설치를 마쳤으면 다시 받을 수 있는 것들입니다.
    static func installers() -> Insight? {
        let folder = SweepScanner.expand("~/Downloads")
        let url = URL(fileURLWithPath: folder)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return nil }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var files: [(name: String, bytes: Int64)] = []
        for entry in entries where installerExtensions.contains(entry.pathExtension.lowercased()) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            files.append((entry.lastPathComponent, Int64(values.totalFileAllocatedSize ?? 0)))
        }
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        guard total >= minBytes / 2 else { return nil }
        let top = files.sorted { $0.bytes > $1.bytes }.prefix(3).map(\.name).joined(separator: ", ")
        return Insight(kind: .installers,
                       title: L("오래된 설치 파일 \(files.count)개", "\(files.count) old installers"),
                       path: folder, bytes: total,
                       detail: L("받은 지 30일이 넘은 설치 파일입니다(\(top)). 설치를 마쳤으면 Finder에서 지웁니다.",
                                 "Installers downloaded over 30 days ago (\(top)). Delete them in Finder once installed."),
                       action: nil)
    }

    // MARK: - 유틸

    static func sizedFolder(_ path: String, kind: Insight.Kind, title: String, detail: String) -> Insight? {
        let full = SweepScanner.expand(path)
        guard FileManager.default.fileExists(atPath: full) else { return nil }
        let bytes = SweepScanner.measure(full).bytes
        guard bytes >= minBytes else { return nil }
        return Insight(kind: kind, title: title, path: full, bytes: bytes, detail: detail, action: nil)
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (out: String, status: Int32) {
        SafetyGuards.run(path, args, timeout: timeout, environment: toolEnvironment)
    }
}
