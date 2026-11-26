# [레퍼런스] 룰 목록과 추가 절차

현재 룰 49개의 목록입니다. 정의는 `app/Sources/SweepCore/DefaultRuleSet.swift`에 있고 판정 방식은 `architecture.md`에 설명해 두었습니다.

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
| 60 | `node-global-packages` | `lib/node_modules` | `npm i -g`로 설치한 CLI. 다시 깔아 줄 프로젝트가 없음 |
| 60 | `nuget-package-dir` | `packages/*/{build,bin,obj,lib,tools}` | NuGet이 배포한 `.targets` 파일 |
| 50 | `node-package-code` | `node_modules/**/{build,bin,obj,lib,dist,es,esm,umd}` | npm 패키지가 배포한 코드 |

## allow: 프로젝트 산출물

| 우선순위 | ID | 대상 | 재생성 비용 | 기본 선택 |
|---|---|---|---|---|
| 110 | `rn-native-build` | `node_modules/*/{android,ios}/build` | 재빌드 10분 이상 | 예 |
| 110 | `rn-native-cache` | `node_modules/**/.gradle`, `.cxx` | 재생성 2분 안팎 | 예 |
| 100 | `android-native` | `android/[모듈/]{build,.cxx,.gradle}` | 재빌드 10분 이상 | 예 |
| 100 | `ios-build` | `ios/build` | 재빌드 10분 이상 | 예 |
| 40 | `node-modules` | 프로젝트의 맨 바깥 `node_modules` | 패키지 재설치 | 조건부 (아래) |
| 45 | `cocoapods-dir` | `Pods` | 재생성 2분 안팎 | 아니오 |
| 40 | `frontend-build` | `.next`, `.nuxt`, `.turbo`, `.svelte-kit`, `.parcel-cache`, `.angular` | 즉시 재빌드 | 예 |
| 40 | `swift-build` | `.build` | 재생성 2분 안팎 | 예 |
| 40 | `dart-tool` | `.dart_tool` | 즉시 재빌드 | 예 |
| 35 | `rust-target` | `target` | 재생성 2분 안팎 | 예 |
| 30 | `dotnet-output` | `bin`, `obj` | 즉시 재빌드 | 예 |
| 20 | `generic-build` | `build` | 즉시 재빌드 | 예 |
| 20 | `generic-dist` | `dist` | 즉시 재빌드 | 아니오 |

### node_modules

중첩된 `node_modules`는 바깥 것에 포함되므로 맨 바깥 것만 후보가 됩니다. 후보로 올린 뒤에도 스캐너는 그 안을 계속 훑어서 RN 라이브러리의 `android/build`를 따로 찾습니다. 프로젝트가 활성이라 `node_modules`를 통째로 지우기 부담스러울 때도 네이티브 빌드 산출물은 지울 수 있게 하려는 것입니다. 바깥과 안쪽을 함께 고르면 합계와 삭제에서 바깥 하나만 셉니다.

지워도 안전한지와 별개로, 다시 설치하는 비용이 커서 미리 체크하는 조건을 따로 둡니다. 셋 중 하나라도 걸리면 경고를 달고 체크하지 않습니다.

| 조건 | 이유 |
|---|---|
| 마지막 커밋이 90일 이내 | 곧 다시 설치하게 됩니다 |
| lockfile 없음 (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock` 등) | 다시 설치하면 버전이 달라질 수 있습니다 |
| `.npmrc`가 공개 registry가 아닌 곳을 가리키거나 토큰을 담음 | 다시 설치할 때 인증이 필요합니다 |

lockfile과 `.npmrc`는 workspace 루트에 있을 수 있어서 저장소 루트까지 올라가며 찾습니다.

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
| `xcode-device-support` | `~/Library/Developer/Xcode/{iOS,watchOS,tvOS,visionOS} DeviceSupport/<버전>` | 재빌드 10분 이상 | 아니오, 플랫폼별 최신 버전은 안전장치가 항상 뺌 |
| `cargo-registry` | `~/.cargo/{registry,git}` | 재다운로드 | 아니오 |
| `maven-repo` | `~/.m2/repository` | 재다운로드 | 아니오 |
| `pub-cache` | `~/.pub-cache/hosted` | 재다운로드 | 아니오 |

`gradle-modules`를 남겨두면 `transforms`는 네트워크 없이 다시 풀립니다. 그래서 기본 미선택입니다.

`~/.pub-cache`는 통째로 잡지 않고 `hosted`만 잡습니다. `bin`에는 `dart pub global activate`로 설치한 실행 파일이 있습니다. Go 모듈 캐시(`~/go/pkg/mod`)는 넣지 않았습니다. 파일이 읽기 전용이라 일반 삭제로 지워지지 않고 `go clean -modcache`로 지워야 합니다.

## allow: AI 에이전트

전부 우선순위 100입니다. 다시 만들 수 있는 캐시만 다룹니다. 세션 대화 기록(`~/.claude/projects`, `~/.codex/sessions`)과 Claude 데스크톱의 `vm_bundles`(세션 데이터 이미지 포함)는 넣지 않았습니다.

| ID | 대상 | 재생성 비용 | 잠금 |
|---|---|---|---|
| `ai-codex-runtime` | `~/.cache/codex-runtimes` | 재다운로드 | `codex` 실행 중 |
| `ai-codex-cache` | `~/.codex/cache`, `~/Library/Caches/{Codex,com.openai.codex}` | 재생성 2분 안팎 | `codex` 실행 중 |
| `ai-claude-desktop-cache` | `~/Library/Application Support/Claude/{Cache,Code Cache,GraphiteDawnCache}`, `~/Library/Caches/com.anthropic.claudefordesktop` | 재생성 2분 안팎 | Claude 데스크톱 실행 중 |
| `ai-claude-cli-logs` | `~/Library/Caches/claude-cli-nodejs` | 재생성 불필요 (MCP 로그) | 없음 |
| `ai-copilot-index` | `~/.cache/github-copilot` | 인덱스 재생성 | 없음 |
| `ai-local-models` | `~/.cache/huggingface`, `~/.ollama/models` | 재다운로드 | `ollama` 실행 중 |

`ai-local-models`는 `manualSelectOnly`라 어느 단계에서도 미리 체크하지 않습니다. 모델 하나가 수 GB라서 무엇을 다시 받을지 사람이 정해야 합니다.

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

## 작업 중인 프로젝트

프로젝트 산출물은 룰과 상관없이 한 가지를 더 봅니다. 그 프로젝트를 작업 폴더로 쓰는 프로세스가 있으면 막습니다. 개발 서버나 에이전트 세션은 `node`, `claude`처럼 흔한 이름이라 아래 잠금 필드로는 어느 프로젝트를 쓰는지 알 수 없기 때문입니다.

| 프로세스의 작업 폴더 | 판정 |
|---|---|
| 프로젝트(가장 바깥 git 저장소) 안 | 차단 |
| 프로젝트의 상위 폴더이면서 검사 폴더보다 깊음 | 차단. 여러 저장소를 함께 다루는 세션입니다 |
| 검사 폴더 자체(`~/Projects`)나 그 위 | 무시. 검사 폴더 아래 전체가 늘 막히게 됩니다 |

작업 폴더가 다른 곳이어도 커맨드라인에 프로젝트 경로가 들어 있으면 막습니다. 절대 경로로 띄운 로컬 MCP 서버나 `npm link`로 건 CLI가 여기에 해당합니다.

Sweep 자신과 그 조상 프로세스는 셈에서 뺍니다. 저장소 안의 셸에서 `sweep`을 실행했을 때 그 저장소가 늘 막히지 않게 하려는 것입니다. 같은 검사를 삭제 직전에 한 번 더 합니다.

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
