# [레퍼런스] 룰 목록과 추가 절차

현재 룰 42개의 목록입니다. 정의는 `app/Sources/SweepCore/DefaultRuleSet.swift`에 있고, 판정 방식은 `architecture.md`에 설명해 두었습니다.

우선순위가 높은 룰이 이깁니다. 같으면 deny가 이깁니다.

## deny

어떤 경우에도 후보로 올리지 않습니다.

| 우선순위 | ID | 대상 | 이유 |
|---|---|---|---|
| 900 | `apple-system-cache` | `~/Library/Caches/com.apple.*` | 훑기만 해도 미디어 접근 경고가 뜸 |
| 300 | `git-internal` | `.git` 내부 | 저장소 데이터 |
| 200 | `android-sdk` | `~/Library/Android/sdk` | SDK 본체, 재설치 부담이 큼 |
| 150 | `python-packages` | `site-packages`, `venv` | Python 패키지 코드 |
| 150 | `apple-bundle` | `.xcodeproj`, `.app`, `.framework` 내부 | 번들 구조가 깨짐 |
| 60 | `nuget-package-dir` | `packages/*/{build,bin,obj,lib,tools}` | NuGet이 배포한 `.targets` 파일 |
| 50 | `node-package-code` | `node_modules/**/{build,bin,obj,lib,dist,es,esm,umd}` | npm 패키지가 배포한 코드 |

## allow: 프로젝트 산출물

| 우선순위 | ID | 대상 | 재생성 비용 | 기본 선택 |
|---|---|---|---|---|
| 110 | `rn-native-build` | `node_modules/*/{android,ios}/build` | 재빌드 10분 이상 | 예 |
| 110 | `rn-native-cache` | `node_modules/**/.gradle`, `.cxx` | 재생성 2분 안팎 | 예 |
| 100 | `android-native` | `android/[모듈/]{build,.cxx,.gradle}` | 재빌드 10분 이상 | 예 |
| 100 | `ios-build` | `ios/build` | 재빌드 10분 이상 | 예 |
| 45 | `cocoapods-dir` | `Pods` | 재생성 2분 안팎 | 아니오 |
| 40 | `frontend-build` | `.next`, `.nuxt`, `.turbo`, `.svelte-kit`, `.parcel-cache`, `.angular` | 즉시 재빌드 | 예 |
| 40 | `swift-build` | `.build` | 재생성 2분 안팎 | 예 |
| 40 | `dart-tool` | `.dart_tool` | 즉시 재빌드 | 예 |
| 35 | `rust-target` | `target` | 재생성 2분 안팎 | 예 |
| 30 | `dotnet-output` | `bin`, `obj` | 즉시 재빌드 | 예 |
| 20 | `generic-build` | `build` | 즉시 재빌드 | 예 |
| 20 | `generic-dist` | `dist` | 즉시 재빌드 | 아니오 |

`generic-build`와 `generic-dist`는 위의 어떤 룰에도 걸리지 않은 것을 받는 가장 넓은 룰입니다. 여기 걸린 것 중 실제로는 소스인 경우는 git 추적 검사가 걸러냅니다.

## allow: 툴체인 캐시

전부 우선순위 100입니다.

| ID | 대상 | 재생성 비용 | 기본 선택 |
|---|---|---|---|
| `gradle-version-cache` | `~/.gradle/caches/<버전>` | 재다운로드 | 아니오 |
| `gradle-modules` | `~/.gradle/caches/modules-2` | 재다운로드 | 아니오 |
| `gradle-build-cache` | `~/.gradle/caches/build-cache-1` | 재생성 2분 안팎 | 예 |
| `gradle-jars` | `~/.gradle/caches/jars-*` | 재생성 2분 안팎 | 예 |
| `gradle-wrapper-dists` | `~/.gradle/wrapper/dists` | 재다운로드 | 아니오 |
| `npm-cache` | `~/.npm/_cacache` | 재다운로드 | 아니오 |
| `nuget-cache` | `~/.nuget/packages` | 재다운로드 | 아니오 |
| `bun-cache` | `~/.bun/install/cache` | 재다운로드 | 아니오 |
| `pnpm-store` | `~/Library/pnpm/store` | 재다운로드 | 아니오 |
| `xcode-derived` | `~/Library/Developer/Xcode/DerivedData` | 재빌드 10분 이상 | 예 |
| `simulator-cache` | `~/Library/Developer/CoreSimulator/Caches` | 재생성 2분 안팎 | 예 |

`gradle-modules`를 남겨두면 `transforms`는 네트워크 없이 다시 풀립니다. 그래서 기본 미선택입니다.

## allow: AI 에이전트

전부 우선순위 100입니다. 다시 만들 수 있는 캐시만 다룹니다. 세션 대화 기록(`~/.claude/projects`, `~/.codex/sessions`)과 Claude 데스크톱의 `vm_bundles`(세션 데이터 이미지 포함)는 넣지 않았습니다.

| ID | 대상 | 재생성 비용 | 잠금 |
|---|---|---|---|
| `ai-codex-runtime` | `~/.cache/codex-runtimes` | 재다운로드 | `codex` 실행 중 |
| `ai-codex-cache` | `~/.codex/cache`, `~/Library/Caches/{Codex,com.openai.codex}` | 재생성 2분 안팎 | `codex` 실행 중 |
| `ai-claude-desktop-cache` | `~/Library/Application Support/Claude/{Cache,Code Cache,GraphiteDawnCache}`, `~/Library/Caches/com.anthropic.claudefordesktop` | 재생성 2분 안팎 | Claude 데스크톱 실행 중 |
| `ai-claude-cli-logs` | `~/Library/Caches/claude-cli-nodejs` | 재생성 불필요 (MCP 로그) | 없음 |
| `ai-copilot-index` | `~/.cache/github-copilot` | 인덱스 재생성 | 없음 |

Claude 데스크톱은 `lockProcesses: ["Claude"]`로 잠그면 안 됩니다. 대소문자를 무시하는 비교라 CLI의 `claude` 프로세스에도 걸려서 늘 잠깁니다. 그래서 `lockCommands`에 앱 본체 경로(`Claude.app/Contents/MacOS/Claude`)를 넣었습니다.

## allow: 앱 캐시

전부 우선순위 100입니다. 화이트리스트에 없는 항목은 룰에 걸리지 않아 "성격 미확인"으로 표시되고 삭제가 막힙니다.

| ID | 대상 | 재생성 비용 | 기본 선택 |
|---|---|---|---|
| `cache-jetbrains` | `~/Library/Caches/JetBrains` | 인덱스 재생성 | 예 |
| `cache-homebrew` | `~/Library/Caches/Homebrew` | 재다운로드 | 예 |
| `cache-devtools` | `trivy`, `dotslash`, `node-gyp`, `ms-playwright`, `pnpm`, `pip`, `next-swc`, `Yarn`, `CocoaPods` 등 | 재다운로드 | 예 |
| `cache-arc` | `~/Library/Caches/{Arc,company.thebrowser.Browser}` | 재생성 2분 안팎 | 아니오 |
| `cache-chrome` | `~/Library/Caches/{Google,com.google.Chrome}` | 재생성 2분 안팎 | 아니오 |
| `cache-safari` | `~/Library/Caches/com.apple.Safari*` | 재생성 2분 안팎 | 아니오 |
| `dotcache-known` | `~/.cache/{puppeteer,mongodb-binaries,pip,uv,turbo,...}` | 재다운로드 | 예 |

## 룰 추가 절차

1. `DefaultRuleSet.swift`의 해당 배열에 `Rule`을 추가합니다. 예외 관계라면 기존 룰을 고치지 말고 우선순위를 높게 잡습니다.
2. `SweepCLI/main.swift`의 `runVerify()`에 기대 판정을 추가합니다. 경로가 실제로 존재하지 않아도 됩니다.
3. `sweep verify`를 돌려 전부 통과하는지 봅니다.
4. `sweep scan`으로 실제 스캔에서 의도한 항목만 잡히는지 확인합니다.

> 룰 변경은 verify 통과 없이 반영하지 않습니다. 우선순위 경쟁 구조라 새 룰이 기존 판정을 조용히 뒤집을 수 있습니다.

## 프로세스 잠금 필드

| 필드 | 매칭 방식 | 쓰는 경우 |
|---|---|---|
| `lockProcesses` | 실행 파일 이름 정확 비교, 대소문자 무시 | `Xcode`, `Arc`, `brew`, `webstorm` |
| `lockCommands` | 커맨드라인 전체 부분 문자열 | `GradleDaemon`, `VBCSCompiler` |

`lockCommands`는 실행 파일이 `java`나 `dotnet`이고 인수에만 이름이 드러나는 경우에만 씁니다. 부분 문자열 검색을 남용하면 `/opt/homebrew/bin/node`가 `brew`에 걸리는 식의 오탐이 납니다.

## 사용자 룰

`~/.config/sweep/rules.json`이 있으면 기본 룰 대신 그것을 씁니다. 메뉴에서 "룰 파일 편집"을 누르면 현재 룰이 그 위치로 내보내집니다. CLI로는 이렇게 만듭니다.

```bash
mkdir -p ~/.config/sweep
sweep rules --export > ~/.config/sweep/rules.json
```

파일을 읽을 수 없거나 형식이 깨지면 경고를 내고 기본 룰로 진행합니다.
