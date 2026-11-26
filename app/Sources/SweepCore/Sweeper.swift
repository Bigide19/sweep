import Foundation

/// 실제 삭제를 담당합니다.
///
/// 휴지통으로 보내지 않고 바로 지웁니다. 용량을 되찾는 게 목적인데 휴지통에 넣으면
/// 디스크 점유가 그대로라 목적에 어긋납니다. 대신 무엇을 언제 얼마나 지웠는지
/// 이력을 남겨서 나중에 되짚어볼 수 있게 합니다.
public struct Sweeper: Sendable {

    public struct Outcome: Sendable {
        public var deleted: [Candidate] = []
        public var failed: [(candidate: Candidate, error: String)] = []
        public var refused: [(candidate: Candidate, reason: String)] = []
        /// 실제로 되찾은 용량입니다. 일부만 지워진 항목은 지운 만큼만 셉니다.
        public var reclaimedBytes: Int64 = 0
        /// 멈춤 요청을 받아 처리하지 않고 남긴 항목 수입니다.
        public var skipped = 0
        /// 삭제 전후의 남은 공간입니다. 다른 프로그램도 디스크를 쓰므로 회수량과 같지 않습니다.
        /// 하드링크 공유처럼 회수량이 부풀려진 경우를 짐작하는 참고값입니다. 시험 삭제면 nil입니다.
        public var freeBefore: Int64?
        public var freeAfter: Int64?
    }

    /// 항목 하나를 처리한 결과입니다.
    public struct ItemResult: Sendable {
        /// 원래 경로가 사라졌는지입니다. 사라졌으면 화면에서 그 줄을 뺍니다.
        public var removed: Bool
        /// 실제로 비운 용량입니다.
        public var freedBytes: Int64
        /// 다 지우지 못했을 때의 사유입니다. 성공이면 nil입니다.
        public var error: String?
    }

    public init() {}

    /// 후보를 지웁니다. blocked 상태이거나 성격을 모르는 항목은 요청이 들어와도 거부합니다.
    ///
    /// `finished`는 항목 하나를 처리할 때마다 불립니다. 큰 폴더 하나에 수십 초가 걸리기도
    /// 해서, 화면은 이걸 받아 지운 줄부터 하나씩 치웁니다. 호출한 Task가 취소되면 지금
    /// 항목까지만 마치고 멈춥니다.
    public func sweep(_ candidates: [Candidate],
                      dryRun: Bool = false,
                      progress: (@Sendable (Candidate) -> Void)? = nil,
                      finished: (@Sendable (Candidate, ItemResult) -> Void)? = nil) -> Outcome {
        var outcome = Outcome()
        if !dryRun {
            Self.purgeStaging()
            outcome.freeBefore = Format.disk().free
        }
        // 바깥과 안쪽 후보가 함께 넘어오면 바깥만 지웁니다. 안쪽은 바깥과 함께 사라집니다.
        let candidates = Candidate.withoutNested(candidates)

        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                outcome.skipped = candidates.count - index
                break
            }
            // 마지막 방어선입니다. UI가 실수로 넘겨도 여기서 막힙니다.
            guard candidate.isDeletable else {
                let reason = candidate.blockReason ?? L("삭제할 수 없는 항목", "Can't be deleted")
                outcome.refused.append((candidate, reason))
                finished?(candidate, ItemResult(removed: false, freedBytes: 0, error: reason))
                continue
            }
            // 스캔한 뒤 상황이 바뀌었을 수 있어 지우기 직전에 다시 확인합니다.
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                let reason = L("이미 없는 경로", "Already gone")
                outcome.refused.append((candidate, reason))
                finished?(candidate, ItemResult(removed: false, freedBytes: 0, error: reason))
                continue
            }
            guard Self.isSafePath(candidate.path) else {
                let reason = L("안전하지 않은 경로", "Unsafe path")
                outcome.refused.append((candidate, reason))
                finished?(candidate, ItemResult(removed: false, freedBytes: 0, error: reason))
                continue
            }

            // 스캔한 뒤 그 프로젝트에서 개발 서버나 세션을 띄웠을 수 있습니다. 앱은 몇 시간 전
            // 스캔 결과로 지우기도 해서, 프로젝트 산출물은 지우기 직전에 다시 봅니다.
            if candidate.category == .projectOutput,
               let reason = SafetyGuards.activeProcessReason(
                   for: candidate.path, list: ProcessInspector.workingProcesses(),
                   containers: SafetyGuards.containerRoots(RuleEngine.loadRuleSet())) {
                outcome.refused.append((candidate, reason))
                finished?(candidate, ItemResult(removed: false, freedBytes: 0, error: reason))
                continue
            }

            progress?(candidate)

            if dryRun {
                outcome.deleted.append(candidate)
                outcome.reclaimedBytes += candidate.bytes
                finished?(candidate, ItemResult(removed: true, freedBytes: candidate.bytes, error: nil))
                continue
            }

            let result = Self.remove(candidate)
            outcome.reclaimedBytes += result.freedBytes
            if let error = result.error {
                outcome.failed.append((candidate, error))
            } else {
                outcome.deleted.append(candidate)
            }
            // 한 항목씩 바로 남깁니다. 오래 걸리는 삭제 도중에 앱이 꺼져도 지운 것은 기록됩니다.
            try? Self.appendHistory([SweepRecord(deletedAt: Date(), path: candidate.path,
                                                 ruleID: candidate.ruleID, bytes: result.freedBytes,
                                                 succeeded: result.error == nil, error: result.error)])
            finished?(candidate, result)
        }
        if !dryRun { outcome.freeAfter = Format.disk().free }
        return outcome
    }

    /// 항목 하나를 지웁니다.
    ///
    /// 바로 지우지 않고 먼저 대기 폴더로 옮긴 뒤 지웁니다. `removeItem`은 파일을 하나씩
    /// 지우다 막히면 그 자리에서 멈추는데, 보안 프로그램이 파일 하나만 막아도 캐시가
    /// 반쯤 지워진 채 남습니다. 도구는 반쯤 남은 캐시를 믿고 쓰다가 깨지지만, 경로가
    /// 아예 없으면 처음부터 다시 만듭니다. 같은 볼륨 안의 이름 바꾸기는 한 번에 끝나서
    /// 원래 경로는 즉시 온전히 사라집니다.
    ///
    /// 대기 폴더를 후보 옆이 아니라 앱 데이터 폴더에 두는 이유는 저장소 안에 남은 조각이
    /// git에 추적 안 된 파일로 보이지 않게 하려는 것입니다.
    static func remove(_ candidate: Candidate) -> ItemResult {
        let fm = FileManager.default
        let staged = stagingURL.appendingPathComponent(UUID().uuidString)
        var target = candidate.path
        // `moveItem`은 볼륨이 다르면 복사한 뒤 지웁니다. 수십 GB를 복사할 수 있어서
        // 이름만 바꾸는 rename을 직접 부릅니다. 실패하면 그 자리에서 바로 지웁니다.
        if (try? fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)) != nil,
           rename(candidate.path, staged.path) == 0 {
            target = staged.path
        }

        do {
            try fm.removeItem(atPath: target)
            return ItemResult(removed: true, freedBytes: candidate.bytes, error: nil)
        } catch {
            // removeItem은 첫 실패에서 나머지를 남긴 채 멈춥니다. 막힌 파일만 두고 마저 지웁니다.
            removeRemaining(target)
            let left = SweepScanner.measure(target).bytes
            let freed = max(0, candidate.bytes - left)
            let removed = target != candidate.path
            return ItemResult(removed: removed, freedBytes: freed,
                              error: describe(error, blocked: firstFile(in: target),
                                              left: left, staged: removed))
        }
    }

    /// 삭제 실패를 사람이 읽을 문장으로 바꿉니다. 막힌 파일 이름과 남은 용량을 붙입니다.
    static func describe(_ error: Error, blocked: String?, left: Int64, staged: Bool) -> String {
        let nsError = error as NSError
        var parts: [String] = []
        // 오류에 실린 경로는 대개 맨 위 폴더라서, 실제로 남은 파일에서 이름을 찾습니다.
        if let blocked {
            parts.append(L("\(blocked) 삭제가 막혔습니다", "\(blocked) couldn't be deleted"))
        } else {
            parts.append(nsError.localizedDescription)
        }
        // 권한 오류는 대개 보안 프로그램이 막은 경우입니다. 파일 권한은 스캔 때 이미 봤습니다.
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        if nsError.code == NSFileWriteNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
            parts.append(L("보안 프로그램이 막았을 수 있습니다", "a security app may have blocked it"))
        }
        if left > 0 {
            parts.append(staged
                ? L("\(Format.bytes(left))는 다음 삭제 때 다시 지웁니다", "\(Format.bytes(left)) will be retried next time")
                : L("\(Format.bytes(left)) 남음", "\(Format.bytes(left)) left"))
        }
        return parts.joined(separator: ", ")
    }

    /// 지울 수 있는 것은 모두 지웁니다. 실패한 파일은 건너뛰고, 비게 된 폴더는 안쪽부터 치웁니다.
    static func removeRemaining(_ path: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return }
        var directories: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let full = (path as NSString).appendingPathComponent(relative)
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                directories.append(full)
            } else {
                try? fm.removeItem(atPath: full)
            }
        }
        for directory in directories.reversed() { rmdir(directory) }
        rmdir(path)
    }

    /// 지우다 남은 파일 하나의 이름입니다. 폴더가 아니라 파일 자체면 그 이름입니다.
    static func firstFile(in path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let item as URL in enumerator
        where (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            return item.lastPathComponent
        }
        return FileManager.default.fileExists(atPath: path) ? url.lastPathComponent : nil
    }

    // MARK: - 대기 폴더

    /// 지우려고 옮겨 둔 항목이 머무는 곳입니다. 스캔 대상이 아닌 앱 데이터 폴더 안입니다.
    static var stagingURL: URL {
        historyURL.deletingLastPathComponent().appendingPathComponent("Deleting", isDirectory: true)
    }

    /// 지난번에 다 못 지운 조각을 치웁니다. Sweep이 만든 대기 폴더 안만 봅니다.
    static func purgeStaging() {
        let fm = FileManager.default
        guard let leftovers = try? fm.contentsOfDirectory(atPath: stagingURL.path) else { return }
        for name in leftovers where UUID(uuidString: name) != nil {
            try? fm.removeItem(at: stagingURL.appendingPathComponent(name))
        }
    }

    /// 홈 디렉터리 안이고, 최소 두 단계는 깊어야 합니다. 룰이 잘못돼서 ~나 ~/Projects
    /// 같은 상위 경로가 넘어오는 사고를 막는 마지막 확인입니다.
    static func isSafePath(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return false }
        let components = path.dropFirst(home.count + 1).split(separator: "/")
        guard components.count >= 2 else { return false }
        // 실행 중인 자기 자신을 품은 경로는 어떤 경우에도 지우지 않습니다.
        // 스캔 때 안전장치가 이미 막지만, 여기가 마지막 방어선이라 한 번 더 봅니다.
        guard !SafetyGuards.containsRunningSweep(path) else { return false }
        // 상대경로 조작이 섞인 경로는 거부합니다.
        guard !path.contains("/../"), !path.hasSuffix("/..") else { return false }
        return true
    }

    // MARK: - 이력

    public static var historyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sweep/history.jsonl")
    }

    static func appendHistory(_ records: [SweepRecord]) throws {
        let url = historyURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var text = ""
        for record in records {
            let data = try encoder.encode(record)
            text += (String(data: data, encoding: .utf8) ?? "") + "\n"
        }
        guard let data = text.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } else {
            try data.write(to: url)
        }
    }

    /// 지금까지 되찾은 누적 용량입니다.
    public static func totalReclaimed() -> Int64 {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").reduce(Int64(0)) { sum, line in
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(SweepRecord.self, from: data),
                  record.succeeded else { return sum }
            return sum + record.bytes
        }
    }
}
