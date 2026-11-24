import Foundation

/// 기본 룰입니다.
///
/// 정규식은 절대경로 전체에 대해 맞춰봅니다. 우선순위가 높은 룰이 이기고, 같으면 deny가 이깁니다.
/// 넓은 deny를 아래에 깔고 좁은 예외 allow를 위에 얹는 구조라, 새 예외가 생겨도
/// 기존 룰을 건드리지 않고 높은 우선순위 룰 하나만 추가하면 됩니다.
public enum DefaultRuleSet {

    public static let dirNames: [String] = [
        "build", "bin", "obj", ".cxx", ".gradle", "target", ".dart_tool", ".build",
        "dist", "Pods", "DerivedData",
        ".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", ".angular",
    ]

    /// 개발 폴더로 흔히 쓰는 이름입니다. 이 중 실제로 있는 것만 검사 대상이 됩니다.
    ///
    /// 처음 실행할 때는 `ProjectRootFinder`가 홈을 얕게 훑어 저장소가 모인 폴더를 더 찾습니다.
    /// 이 목록은 그 결과와 합치는 몫이고, 폴더를 정하지 않은 CLI가 쓰는 기본값이기도 합니다.
    /// `~/go/src`와 `~/ghq`는 저장소가 4단 아래에 있어서 얕게 훑어서는 찾지 못합니다.
    public static let projectRootCandidates: [String] = [
        "~/Projects", "~/Developer", "~/dev", "~/code", "~/src",
        "~/work", "~/repos", "~/git", "~/GitHub", "~/workspace",
        "~/ghq", "~/go/src", "~/eclipse-workspace",
        // JetBrains IDE가 새 프로젝트를 만드는 기본 폴더입니다.
        "~/IdeaProjects", "~/AndroidStudioProjects", "~/PycharmProjects", "~/WebstormProjects",
        "~/RiderProjects", "~/GolandProjects", "~/CLionProjects", "~/PhpstormProjects",
        "~/RustroverProjects",
    ]

    /// 후보 중 실제로 있는 폴더입니다.
    public static func detectedProjectRoots(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        projectRootCandidates.compactMap { path in
            let full = home + path.dropFirst(1)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? SweepScanner.abbreviate(full) : nil
        }
    }

    /// 프로젝트 폴더를 뺀 고정 루트입니다. 프로젝트 폴더는 사용자 설정에서 붙습니다.
    public static let roots: [ScanRoot] = [
        // 툴체인 캐시
        .init(path: "~/.gradle/caches", mode: .children),
        .init(path: "~/.gradle/wrapper", mode: .children),
        .init(path: "~/.npm/_cacache", mode: .leaf),
        .init(path: "~/.nuget/packages", mode: .leaf),
        .init(path: "~/.bun/install/cache", mode: .leaf),
        .init(path: "~/Library/pnpm/store", mode: .leaf),
        .init(path: "~/Library/Developer/Xcode/DerivedData", mode: .leaf),
        .init(path: "~/Library/Developer/CoreSimulator/Caches", mode: .leaf),

        // AI 에이전트. Application Support는 앱 데이터가 섞여 있어 children으로 훑지 않고
        // 캐시 폴더만 하나씩 집습니다. 같은 폴더의 vm_bundles는 세션 데이터 이미지가 들어
        // 있어 일부러 넣지 않았습니다.
        .init(path: "~/.codex/cache", mode: .leaf),
        .init(path: "~/Library/Application Support/Claude/Cache", mode: .leaf),
        .init(path: "~/Library/Application Support/Claude/Code Cache", mode: .leaf),
        .init(path: "~/Library/Application Support/Claude/GraphiteDawnCache", mode: .leaf),

        // 앱 캐시. 화이트리스트에 없는 항목은 성격을 모르므로 크기만 보여주고 삭제는 막습니다.
        .init(path: "~/Library/Caches", mode: .children),
        .init(path: "~/.cache", mode: .children),
    ]

    /// 제목과 설명이 지금 언어를 따르도록 읽을 때마다 새로 만듭니다.
    public static var rules: [Rule] {
        mandatoryDenyRules + denyRules + projectRules + toolchainRules + aiAgentRules + appCacheRules
    }

    // MARK: - 룰셋과 무관하게 항상 걸리는 deny

    /// 사용자가 예전 룰 파일을 쓰고 있어도 이건 빠지면 안 됩니다.
    ///
    /// 훑는 것만으로 macOS가 개인정보 접근 경고를 띄우는 경로입니다. 껐다 켤 성질의
    /// 것이 아니라서 룰 파일이 뭐라 하든 `RuleEngine`이 항상 얹습니다.
    public static var mandatoryDenyRules: [Rule] { [
        // com.apple.Music이나 AMPLibraryAgent 안을 걸으면 "음악 및 미디어 보관함에
        // 접근하려고 합니다" 창이 뜹니다. 화이트리스트에 없어 어차피 못 지우는 것들이라,
        // 크기를 재려고 걷는 것 자체가 순수한 손해입니다.
        Rule(id: "apple-system-cache", kind: .deny, priority: 900,
             regex: #"/Library/Caches/com\.apple\."#,
             note: L("Apple 시스템 캐시입니다. 훑기만 해도 미디어 접근 경고가 뜹니다.", "Apple system cache. Even reading it triggers a media access prompt.")),
    ] }

    // MARK: - deny: 절대 건드리지 않는 것

    static var denyRules: [Rule] { [
        Rule(id: "git-internal", kind: .deny, priority: 300,
             regex: #"/\.git(/|$)"#,
             note: L("git 내부 데이터입니다.", "Git internals.")),

        Rule(id: "android-sdk", kind: .deny, priority: 200,
             regex: #"/Library/Android/sdk"#,
             note: L("SDK 본체입니다. 다시 받기가 번거로워서 건드리지 않습니다.", "The SDK itself. Too costly to reinstall.")),

        // Python 패키지가 설치된 곳입니다. 안에 build라는 이름의 실제 코드가 있습니다.
        Rule(id: "python-packages", kind: .deny, priority: 150,
             regex: #"/(site-packages|\.?venv)/"#,
             note: L("Python 패키지 코드입니다.", "Python package code.")),

        // 번들 내부는 구조가 정해져 있어 일부만 지우면 깨집니다.
        Rule(id: "apple-bundle", kind: .deny, priority: 150,
             regex: #"\.(xcodeproj|xcworkspace|app|framework|bundle|playground)/"#,
             note: L("Apple 번들 내부입니다.", "Inside an Apple bundle.")),

        // NuGet이 풀어놓은 패키지입니다. build 폴더에 .targets/.props가 들어 있어
        // 지우면 .NET 빌드가 깨집니다. 이번 정리에서 실제로 걸렀던 케이스입니다.
        Rule(id: "nuget-package-dir", kind: .deny, priority: 60,
             regex: #"/packages/[^/]+/(build|bin|obj|lib|tools|ref|runtimes)$"#,
             note: L("NuGet 패키지에 들어 있는 파일입니다.", "Files shipped in a NuGet package.")),

        // npm 패키지가 배포한 코드입니다. next/dist/build, yargs/build 등이 여기 걸립니다.
        // 아래 rn-native-build 룰이 우선순위로 이겨서 android/build만 예외가 됩니다.
        Rule(id: "node-package-code", kind: .deny, priority: 50,
             regex: #"/node_modules/.+/(build|bin|obj|lib|dist|es|esm|umd)$"#,
             note: L("npm 패키지에 들어 있는 코드입니다.", "Code shipped in an npm package.")),
    ] }

    // MARK: - allow: 프로젝트 빌드 산출물

    static var projectRules: [Rule] { [
        // React Native 라이브러리를 소스에서 빌드한 산출물입니다.
        // node-package-code(50)보다 우선순위가 높아 예외로 빠져나옵니다.
        Rule(id: "rn-native-build", kind: .allow, priority: 110,
             regex: #"/node_modules/(@[^/]+/)?[^/]+/(android|ios)/build$"#,
             category: .projectOutput, cost: .slow,
             title: L("RN 라이브러리 네이티브 빌드", "React Native library native build"),
             note: L("다시 빌드하면 생깁니다. Android 네이티브 컴파일이라 오래 걸립니다.", "Comes back on the next build. Native Android compilation is slow."),
             defaultSelected: true),

        // node_modules 안의 .gradle/.cxx는 예외 없이 빌드 캐시입니다.
        Rule(id: "rn-native-cache", kind: .allow, priority: 110,
             regex: #"/node_modules/.+/\.(gradle|cxx)$"#,
             category: .projectOutput, cost: .quick,
             title: L("RN 라이브러리 Gradle/CMake 캐시", "React Native library Gradle/CMake cache"),
             defaultSelected: true),

        Rule(id: "android-native", kind: .allow, priority: 100,
             regex: #"/android/([^/]+/)?(build|\.cxx|\.gradle)$"#,
             category: .projectOutput, cost: .slow,
             title: L("Android 빌드 산출물", "Android build output"),
             note: L("libreactnative.so 같은 네이티브 라이브러리가 여기 쌓입니다.", "Native libraries such as libreactnative.so pile up here."),
             defaultSelected: true,
             lockCommands: ["GradleDaemon", "gradle-launcher"]),

        Rule(id: "ios-build", kind: .allow, priority: 100,
             regex: #"/ios/build$"#,
             category: .projectOutput, cost: .slow,
             title: L("iOS 빌드 산출물", "iOS build output"),
             defaultSelected: true,
             lockProcesses: ["Xcode", "xcodebuild"]),

        Rule(id: "cocoapods-dir", kind: .allow, priority: 45,
             regex: #"/Pods$"#,
             category: .projectOutput, cost: .quick,
             title: L("CocoaPods 설치본", "CocoaPods install"),
             note: L("pod install을 다시 돌리면 됩니다. 같은 버전으로 받으려면 Podfile.lock이 있어야 합니다.", "Run pod install again. Podfile.lock keeps the same versions."),
             defaultSelected: false),

        Rule(id: "frontend-build", kind: .allow, priority: 40,
             regex: #"/\.(next|nuxt|turbo|svelte-kit|parcel-cache|angular)$"#,
             category: .projectOutput, cost: .instant,
             title: L("프론트엔드 빌드 캐시", "Frontend build cache"),
             defaultSelected: true),

        Rule(id: "swift-build", kind: .allow, priority: 40,
             regex: #"/\.build$"#,
             category: .projectOutput, cost: .quick,
             title: L("SwiftPM 빌드 산출물", "SwiftPM build output"),
             defaultSelected: true,
             lockProcesses: ["swift-build", "swift-frontend", "sourcekit-lsp"]),

        Rule(id: "dart-tool", kind: .allow, priority: 40,
             regex: #"/\.dart_tool$"#,
             category: .projectOutput, cost: .instant,
             title: L("Dart/Flutter 도구 캐시", "Dart/Flutter tool cache"),
             defaultSelected: true),

        Rule(id: "rust-target", kind: .allow, priority: 35,
             regex: #"/target$"#,
             category: .projectOutput, cost: .quick,
             title: L("Rust/Maven 산출물", "Rust/Maven output"),
             defaultSelected: true),

        Rule(id: "dotnet-output", kind: .allow, priority: 30,
             regex: #"/(bin|obj)$"#,
             category: .projectOutput, cost: .instant,
             title: L(".NET 빌드 산출물", ".NET build output"),
             defaultSelected: true,
             lockCommands: ["MSBuild.dll", "VBCSCompiler", "dotnet build"]),

        // 가장 넓은 룰입니다. 우선순위를 낮게 둬서 위의 어떤 룰에도 안 걸린 build만 잡습니다.
        // 여기 걸린 것 중 소스인 경우(git이 추적하는 build)는 룰이 아니라 안전장치가 막습니다.
        Rule(id: "generic-build", kind: .allow, priority: 20,
             regex: #"/build$"#,
             category: .projectOutput, cost: .instant,
             title: L("빌드 산출물", "Build output"),
             defaultSelected: true),

        Rule(id: "generic-dist", kind: .allow, priority: 20,
             regex: #"/dist$"#,
             category: .projectOutput, cost: .instant,
             title: L("배포 산출물", "Distribution output"),
             note: L("git이 추적하는 dist는 안전장치가 걸러냅니다.", "A dist tracked by git is protected by a safety check."),
             defaultSelected: false),
    ] }

    // MARK: - allow: 툴체인 캐시

    static var toolchainRules: [Rule] { [
        // 버전별 Gradle 캐시입니다. 어느 프로젝트가 그 버전을 쓰는지 스캔 중에 알아내서
        // 소유자로 표시합니다. 소유자가 있으면 기본 미선택으로 둡니다.
        Rule(id: "gradle-version-cache", kind: .allow, priority: 100,
             regex: #"/\.gradle/caches/[0-9]+\.[0-9]+(\.[0-9]+)?$"#,
             category: .toolchainCache, cost: .download,
             title: L("Gradle 버전 캐시", "Gradle version cache"),
             note: L("이 버전을 쓰는 프로젝트가 있으면 다음 빌드에서 다시 내려받습니다.", "Projects using this version download it again on the next build."),
             defaultSelected: false,
             lockCommands: ["GradleDaemon", "gradle-launcher"]),

        Rule(id: "gradle-modules", kind: .allow, priority: 100,
             regex: #"/\.gradle/caches/modules-2$"#,
             category: .toolchainCache, cost: .download,
             title: L("Gradle 의존성 원본", "Gradle dependency cache"),
             note: L("AAR/JAR 원본입니다. 이게 남아 있으면 transforms를 네트워크 없이 다시 만듭니다.", "Original AAR/JAR files. With these kept, transforms rebuild offline."),
             defaultSelected: false,
             lockCommands: ["GradleDaemon"]),

        Rule(id: "gradle-build-cache", kind: .allow, priority: 100,
             regex: #"/\.gradle/caches/build-cache-1$"#,
             category: .toolchainCache, cost: .quick,
             title: L("Gradle 빌드 캐시", "Gradle build cache"),
             defaultSelected: true,
             lockCommands: ["GradleDaemon"]),

        Rule(id: "gradle-jars", kind: .allow, priority: 100,
             regex: #"/\.gradle/caches/jars-[0-9]+$"#,
             category: .toolchainCache, cost: .quick,
             title: L("Gradle jar 캐시", "Gradle jar cache"),
             defaultSelected: true,
             lockCommands: ["GradleDaemon"]),

        Rule(id: "gradle-wrapper-dists", kind: .allow, priority: 100,
             regex: #"/\.gradle/wrapper/dists$"#,
             category: .toolchainCache, cost: .download,
             title: L("Gradle 배포판", "Gradle distributions"),
             note: L("프로젝트마다 필요한 버전을 다시 내려받습니다.", "Each project downloads its version again."),
             defaultSelected: false),

        Rule(id: "npm-cache", kind: .allow, priority: 100,
             regex: #"/\.npm/_cacache$"#,
             category: .toolchainCache, cost: .download,
             title: L("npm 캐시", "npm cache"),
             note: L("npm cache clean과 같은 효과입니다. 설치는 느려지지만 깨지지 않습니다.", "Same as npm cache clean. Installs get slower, nothing breaks."),
             defaultSelected: false),

        Rule(id: "nuget-cache", kind: .allow, priority: 100,
             regex: #"/\.nuget/packages$"#,
             category: .toolchainCache, cost: .download,
             title: L("NuGet 글로벌 패키지", "NuGet global packages"),
             note: L("dotnet restore를 돌리면 다시 받습니다.", "dotnet restore downloads them again."),
             defaultSelected: false),

        Rule(id: "bun-cache", kind: .allow, priority: 100,
             regex: #"/\.bun/install/cache$"#,
             category: .toolchainCache, cost: .download,
             title: L("Bun 설치 캐시", "Bun install cache"),
             defaultSelected: false),

        Rule(id: "pnpm-store", kind: .allow, priority: 100,
             regex: #"/pnpm/store$"#,
             category: .toolchainCache, cost: .download,
             title: L("pnpm 스토어", "pnpm store"),
             note: L("pnpm은 스토어에 받아둔 파일을 하드링크로 씁니다. 지우면 다시 설치해야 합니다.", "pnpm hard-links files from the store. Reinstall after deleting."),
             defaultSelected: false),

        Rule(id: "xcode-derived", kind: .allow, priority: 100,
             regex: #"/Developer/Xcode/DerivedData$"#,
             category: .toolchainCache, cost: .slow,
             title: "Xcode DerivedData",
             defaultSelected: true,
             lockProcesses: ["Xcode", "xcodebuild"]),

        Rule(id: "simulator-cache", kind: .allow, priority: 100,
             regex: #"/CoreSimulator/Caches$"#,
             category: .toolchainCache, cost: .quick,
             title: L("시뮬레이터 캐시", "Simulator cache"),
             defaultSelected: true,
             lockProcesses: ["Simulator"]),
    ] }

    // MARK: - allow: AI 에이전트 캐시

    /// 세션 대화 기록(`~/.claude/projects`, `~/.codex/sessions`)은 여기 없습니다.
    /// 다시 만들 수 없는 데이터라 "재생성할 수 있는 것만 지운다"는 전제에 맞지 않습니다.
    static var aiAgentRules: [Rule] { [
        // 설치를 마친 런타임과 설치하다 남은 임시 폴더가 같이 들어 있습니다.
        // lockProcesses는 대소문자를 무시하므로 CLI(codex)와 데스크톱 앱(Codex)을 함께 잡습니다.
        Rule(id: "ai-codex-runtime", kind: .allow, priority: 100,
             regex: #"/\.cache/codex-runtimes$"#,
             category: .aiAgent, cost: .download,
             title: L("Codex 런타임", "Codex runtime"),
             note: L("설치된 런타임과 설치하다 남은 임시 폴더입니다. 지우면 다시 받아야 합니다.", "Installed runtime plus leftover install folders. Downloads again after deleting."),
             defaultSelected: false,
             lockProcesses: ["codex"]),

        Rule(id: "ai-codex-cache", kind: .allow, priority: 100,
             regex: #"/(\.codex/cache|Library/Caches/(Codex|com\.openai\.codex))$"#,
             category: .aiAgent, cost: .quick,
             title: L("Codex 캐시", "Codex cache"),
             defaultSelected: true,
             lockProcesses: ["codex"]),

        // lockProcesses에 "Claude"를 넣으면 대소문자를 무시하는 비교라 CLI의 claude 프로세스에도
        // 걸려서 늘 잠깁니다. 데스크톱 앱 본체의 실행 경로로만 잠급니다. 헬퍼 프로세스는
        // Frameworks 아래에 있어 이 문자열에 걸리지 않습니다.
        Rule(id: "ai-claude-desktop-cache", kind: .allow, priority: 100,
             regex: #"/Library/(Application Support/Claude/(Cache|Code Cache|GraphiteDawnCache)|Caches/com\.anthropic\.claudefordesktop)$"#,
             category: .aiAgent, cost: .quick,
             title: L("Claude 앱 캐시", "Claude app cache"),
             defaultSelected: true,
             lockCommands: ["Claude.app/Contents/MacOS/Claude"]),

        Rule(id: "ai-claude-cli-logs", kind: .allow, priority: 100,
             regex: #"/Library/Caches/claude-cli-nodejs$"#,
             category: .aiAgent, cost: .disposable,
             title: L("Claude Code MCP 로그", "Claude Code MCP logs"),
             note: L("MCP 서버 로그입니다.", "MCP server logs."),
             defaultSelected: true),

        Rule(id: "ai-copilot-index", kind: .allow, priority: 100,
             regex: #"/\.cache/github-copilot$"#,
             category: .aiAgent, cost: .reindex,
             title: L("GitHub Copilot 인덱스", "GitHub Copilot index"),
             defaultSelected: true),
    ] }

    // MARK: - allow: 앱 캐시 (화이트리스트)

    static var appCacheRules: [Rule] { [
        Rule(id: "cache-jetbrains", kind: .allow, priority: 100,
             regex: #"/Library/Caches/JetBrains$"#,
             category: .appCache, cost: .reindex,
             title: L("JetBrains IDE 캐시", "JetBrains IDE cache"),
             note: L("프로젝트를 열면 인덱스를 다시 만듭니다. 큰 프로젝트는 몇 분 걸립니다.", "Reindexes when a project opens. Large projects take minutes."),
             defaultSelected: true,
             lockProcesses: ["idea", "webstorm", "rider", "pycharm", "datagrip", "goland", "phpstorm", "clion", "rustrover"]),

        Rule(id: "cache-homebrew", kind: .allow, priority: 100,
             regex: #"/Library/Caches/Homebrew$"#,
             category: .appCache, cost: .download,
             title: L("Homebrew 다운로드 캐시", "Homebrew download cache"),
             note: L("brew cleanup과 같은 효과입니다.", "Same as brew cleanup."),
             defaultSelected: true,
             lockProcesses: ["brew"]),

        Rule(id: "cache-devtools", kind: .allow, priority: 100,
             regex: #"/Library/Caches/(trivy|dotslash|node-gyp|ms-playwright|ms-playwright-go|puppeteer|pnpm|pip|next-swc|Yarn|CocoaPods|org\.swift\.swiftpm|typescript|deno|go-build|electron|electron-builder)$"#,
             category: .appCache, cost: .download,
             title: L("개발 도구 캐시", "Developer tool cache"),
             defaultSelected: true),

        // 브라우저는 실행 중에 캐시를 지우면 탭이 깨질 수 있어 각각 따로 잠급니다.
        Rule(id: "cache-arc", kind: .allow, priority: 100,
             regex: #"/Library/Caches/(Arc|company\.thebrowser\.Browser)$"#,
             category: .appCache, cost: .quick,
             title: L("Arc 브라우저 캐시", "Arc browser cache"),
             defaultSelected: false,
             lockProcesses: ["Arc"]),

        Rule(id: "cache-chrome", kind: .allow, priority: 100,
             regex: #"/Library/Caches/(Google|com\.google\.Chrome)$"#,
             category: .appCache, cost: .quick,
             title: L("Chrome 캐시", "Chrome cache"),
             defaultSelected: false,
             lockProcesses: ["Google Chrome"]),

        Rule(id: "cache-safari", kind: .allow, priority: 100,
             regex: #"/Library/Caches/com\.apple\.Safari"#,
             category: .appCache, cost: .quick,
             title: L("Safari 캐시", "Safari cache"),
             defaultSelected: false,
             lockProcesses: ["Safari"]),

        // ~/.cache 안에서 성격이 분명한 것만 골라냅니다.
        Rule(id: "dotcache-known", kind: .allow, priority: 100,
             regex: #"/\.cache/(puppeteer|ms-playwright|mongodb-binaries|yarn|pip|uv|deno|go-build|golangci-lint|turbo|nx|prisma|huggingface|electron|node-gyp|pre-commit|bazel|typescript|selenium|Cypress|jedi|matplotlib)$"#,
             category: .appCache, cost: .download,
             title: L("도구 캐시", "Tool cache"),
             defaultSelected: true),
    ] }

    public static var ruleSet: RuleSet {
        RuleSet(version: 1, roots: roots, dirNames: dirNames, rules: rules)
    }
}
