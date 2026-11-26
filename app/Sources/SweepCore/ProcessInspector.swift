import Foundation
import Darwin

/// 실행 중인 프로세스와 그 작업 폴더입니다.
public struct WorkingProcess: Sendable, Hashable {
    public let pid: Int32
    public let name: String
    public let cwd: String
    /// 인수까지 합친 커맨드라인입니다. 못 읽었으면 빈 문자열입니다.
    public var command: String = ""
}

/// 어떤 프로젝트 안에서 프로세스가 돌고 있는지 알아냅니다.
///
/// 실행 파일 이름으로 잠그는 검사(`lockProcesses`)는 "Xcode가 떠 있으면 DerivedData를
/// 막는다" 같은 도구 단위 판단입니다. 그것만으로는 개발 서버나 에이전트 세션이 돌고 있는
/// 프로젝트의 산출물을 막지 못합니다. 그 프로세스들은 `node`, `claude`처럼 흔한 이름이라
/// 이름으로는 어느 프로젝트를 쓰는지 알 수 없고, 작업 폴더를 봐야 압니다.
public enum ProcessInspector {

    /// 같은 사용자로 돌고 있는 프로세스의 작업 폴더입니다.
    ///
    /// 개별 프로세스를 못 읽는 건 정상입니다. 다른 사용자나 시스템 프로세스는 권한이 없어서
    /// 실패하는데, 그걸 실패로 치면 모든 프로젝트가 영영 막힙니다. 그런 프로세스는 건너뛰고,
    /// 목록 자체를 못 받았을 때만 nil을 돌려줍니다. nil이면 호출한 쪽이 막아야 합니다.
    ///
    /// Sweep 자신과 그 조상 프로세스는 뺍니다. 저장소 안의 셸에서 `sweep`을 실행하면
    /// 그 셸이 곧 그 저장소의 프로세스라서, 빼지 않으면 그 저장소가 늘 막힙니다.
    public static func workingProcesses() -> [WorkingProcess]? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        // 목록을 받는 사이에 프로세스가 늘 수 있어 여유를 둡니다.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return nil }

        let excluded = selfAndAncestors()
        let uid = getuid()
        var result: [WorkingProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 && !excluded.contains(pid) {
            guard let info = bsdInfo(pid), info.pbi_uid == uid,
                  let cwd = workingDirectory(pid) else { continue }
            let args = arguments(pid)
            let label = args.first.map(displayName) ?? name(pid) ?? "pid \(pid)"
            result.append(WorkingProcess(pid: pid, name: label, cwd: realPath(cwd),
                                         command: args.joined(separator: " ")))
        }
        return result
    }

    /// 이 프로젝트를 쓰고 있다고 볼 프로세스입니다.
    ///
    /// 작업 폴더가 프로젝트 안이면 당연히 해당합니다. 프로젝트의 상위 폴더에서 도는
    /// 프로세스도 그 아래 여러 저장소를 함께 다루는 경우가 많아 포함합니다. 다만 검사 폴더
    /// 자체(`~/Projects`)나 그보다 위에서 도는 프로세스는 뺍니다. 그런 데몬까지 치면 검사
    /// 폴더 아래 전체가 늘 막힙니다. `containers`가 비어 있으면 프로젝트 안만 봅니다.
    public static func processes(using project: String, containers: [String],
                                 from list: [WorkingProcess]) -> [WorkingProcess] {
        let project = realPath(project)
        let container = containers.map(realPath)
            .filter { project.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
        return list.filter { process in
            if isInside(process.cwd, project) { return true }
            // 작업 폴더는 다른 곳이어도 그 프로젝트의 파일을 실행 중일 수 있습니다.
            // 절대 경로로 띄운 로컬 MCP 서버나 npm link로 건 CLI가 이렇습니다.
            if mentions(process.command, project) { return true }
            guard let container, isInside(project, process.cwd) else { return false }
            // 검사 폴더보다 깊은 상위 폴더만 칩니다.
            return process.cwd.count > container.count && isInside(process.cwd, container)
        }
    }

    /// 커맨드라인에 프로젝트 경로나 그 안의 경로가 들어 있는지입니다.
    /// `app`을 찾을 때 `app2/...`가 걸리지 않도록 경로 끝을 확인합니다.
    static func mentions(_ command: String, _ project: String) -> Bool {
        guard !command.isEmpty else { return false }
        if command.contains(project + "/") { return true }
        return command.hasSuffix(project) || command.contains(project + " ")
            || command.contains(project + "\"") || command.contains(project + "'")
    }

    /// 심볼릭 링크와 `/private` 같은 별칭을 푼 실제 경로입니다.
    ///
    /// `URL.resolvingSymlinksInPath`는 `/private/tmp`를 `/tmp`로 바꿔 버려서, 커널이 돌려주는
    /// 작업 폴더(`/private/tmp/...`)와 비교하면 어긋납니다. 양쪽을 realpath로 맞춥니다.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path`가 `directory`이거나 그 안인지입니다.
    static func isInside(_ path: String, _ directory: String) -> Bool {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path == directory || path.hasPrefix(prefix)
    }

    /// 화면에 보여줄 이름입니다. 여러 개면 첫 이름과 나머지 개수만 씁니다.
    public static func summary(_ processes: [WorkingProcess]) -> String {
        let names = Array(Set(processes.map(\.name)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : L("\(first) 외 \(names.count - 1)개", "\(first) and \(names.count - 1) more")
    }

    // MARK: - libproc

    static func selfAndAncestors() -> Set<pid_t> {
        var result: Set<pid_t> = []
        var current = getpid()
        // launchd(1)에 닿거나 고리가 생기면 멈춥니다.
        while current > 1, !result.contains(current) {
            result.insert(current)
            guard let info = bsdInfo(current) else { break }
            current = pid_t(info.pbi_ppid)
        }
        return result
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// 프로세스의 인수 전체입니다. 첫 원소가 argv[0]입니다.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // 앞 4바이트는 argc, 이어서 실행 경로, 0으로 채운 여백, argv 순서입니다. 그 뒤는 환경 변수라 argc만큼만 읽습니다.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < Int(argc), index < size {
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            result.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return result
    }

    /// argv[0]의 끝 이름입니다.
    ///
    /// 실행 파일 이름보다 이쪽이 사람이 아는 이름에 가깝습니다. Claude Code CLI는 실행 파일이
    /// 버전 번호(`2.1.331`)로 설치돼서 proc_name으로는 그 숫자만 나옵니다.
    static func displayName(_ argv0: String) -> String {
        let base = (argv0 as NSString).lastPathComponent
        // 로그인 셸은 "-zsh"처럼 앞에 하이픈이 붙습니다.
        return base.hasPrefix("-") ? String(base.dropFirst()) : base
    }

    static func name(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
