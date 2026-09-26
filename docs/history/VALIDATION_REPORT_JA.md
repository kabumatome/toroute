# ToRoute 0.4.0-rc.12 検証報告

作成日: 2026-07-23
区分: 公開用技術資料
判定: **rc.12 verified-commit Windows/Docker 12項目成功 / G2合格 / Public image未公開**

## 1. 復元元

rc.9は、SHA-256
`b00804753587b9bdecf5ef18c91918548d2406eb6500aa4c809e5bbcaeac56ba`
の`ToRoute_0.4.0-rc.8_source.zip`から復元した。

復元元metadata:

- version: `0.4.0-rc.8`
- source commit: `e7d284614aec9b5ab8f7872dac8b9b080c38525d`
- source date epoch: `1784646268`

ZIPは過去に確定したrc.8 hashと完全一致した。元Git履歴はZIPへ含まれないため、rc.9のローカルGit履歴は復元作業用の新しい履歴であり、元commitを偽装しない。

## 2. 変更前rc.8 Source gate再確認

`.git`なしの配布ZIP展開版をそのまま使用した。

| Gate | 結果 |
|---|---:|
| ZIP破損検査 | 成功 |
| Windows CMD／PowerShell静的契約 | 成功 |
| privacy scan | 成功 |
| repository／workflow policy | 成功 |
| release tooling | 成功 |
| runtime budget policy | 成功 |
| OCI／SBOM／provenance／vulnerability policy | 成功 |
| `go vet ./...` | 成功 |
| 全8 package race detector | 成功 |
| amd64 static build | 成功 |
| Linux arm64 cross-build | 成功 |
| aggregate statement coverage | 67.6% |

## 3. rc.8 Container RC実証

2026-07-22のWindows Docker Desktop実証は全12項目成功。

- Windows PowerShell runtime self-test
- Docker Engine／Compose／Buildx前提
- amd64 runtime／netprobe／proxycheck build
- image metadata／設定境界
- non-root／read-only／capabilityなし／no-new-privileges
- Tor Bootstrap 100%／Docker health
- application networkの直接egress防止
- SOCKS5 remote DNS／HTTPS／Tor判定
- HTTP CONNECT／HTTPS／Tor判定
- SAFECOOKIE／NEWNYM
- runtime metrics／package inventory
- log secret scan
- arm64 QEMU build／native config

Sanitized full-http amd64実測:

| 指標 | rc.8実測 | active上限 |
|---|---:|---:|
| image size | 140,775,431 bytes | 180,000,000 |
| packages | 101 | 115 |
| Bootstrap | 17,647 ms | 180,000 |
| steady memory max | 152,064,000 bytes | 230,686,720 |
| idle CPU | 36,056 usec/s | 50,000 |
| PIDs/threads | 28 | 48 |

全budget内。生証跡の利用者path、host識別情報、exit IP、image/container/network IDは公開資料へ含めない。

## 4. rc.9の変更

直接`toroute healthcheck --json`が100% readyを返した後、Docker Engineの定期health probe結果が`State.Health.Status`へ反映されるまで数秒差がある。

rc.8の成功実行ではDocker probeが先に成功した。一方、別実行では直接readyの約2秒後、次の5秒probeより前に`starting`を読み、runnerが失敗した。

rc.9では次を実装する。

- 直接ready後、Docker healthを最大45秒同期
- `starting`: 2秒後に再確認
- `healthy`: 成功
- `unhealthy`: 即失敗
- container停止、health欠落、JSON異常: 即失敗
- timeout: fail-closed
- 全観測を`docker-health-sync.jsonl`へ保存
- Bootstrap時間は直接Tor readyまでとし、同期時間を含めない
- PowerShell 5.1自己試験で全health transitionを確認
- hardened container inspectより前に同期することを静的policyで固定

ToRoute runtime、Tor設定、Dockerfileのhealth policyには変更を加えない。

## 5. 残る公開前gate

| Gate | 状態 |
|---|---|
| rc.12 Windows Docker runner回帰 | 全12項目・全budget成功 |
| obfs4 Bridge秘密情報staging異常系 | 合格（実Bridge接続は未実行） |
| Tor／Privoxy child failure実container試験 | 合格 |
| actual amd64／arm64 Trivy | 未実行 |
| actual SPDX SBOM／SLSA provenance | 未実行 |
| registry single-candidate promotion | 未実行 |
| anonymous exact／alias pull | 未実行 |
| CodeQL／ShellCheck／actionlint | GitHub実行待ち |
| independent security review | 未実施 |

## 6. 判定

G2 Container RCはrc.12のverified-commit Windows Docker再実証で確定合格とする。全12項目と全active runtime budgetが成功し、source identityは検証対象OCI imageのversion／revision labelと一致した。次はactual vulnerability、SBOM／provenance、registry rehearsalを行うG3工程である。

## rc.10 Windows launcher修正

rc.9で利用者環境のコマンド画面が即時終了した報告を受け、表示保持をroot CMDの末尾`pause`だけに依存しない構造へ変更した。Explorer起動は現在の画面内で永続的な子`cmd.exe /k`へ再起動し、inner CMDの直接起動もrootへ戻す。PowerShell起動前に`launcher-bootstrap.log`を生成するため、PowerShell parserやDockerへ到達しない失敗も回収可能である。CIの非対話実行はGitHub Actionsが自動設定する`GITHUB_ACTIONS=true`に限定し、一般環境向けの画面保持回避変数は提供しない。


## rc.11 設計監査

Bridge秘密ファイルのowner／mode検査、release明示enable、current-main tag検査、
追跡中の古い`SOURCE_METADATA.json`除去、定期Actions停止、docs-only CI抑制を実装した。

## rc.12 証跡privacy／provenance監査

2026-09-13に受領したrc.10 Windows Docker証跡は全12項目成功。公開可能な集約値は次の通り。

| 指標 | rc.10実測 | active上限 | 判定 |
|---|---:|---:|---:|
| image size | 140,801,992 bytes | 180,000,000 | 合格 |
| packages | 101 | 115 | 合格 |
| Bootstrap | 43,854 ms | 180,000 | 合格 |
| steady memory max | 136,544,256 bytes | 230,686,720 | 合格 |
| idle CPU | 31,557 usec/s | 50,000 | 合格 |
| PIDs/threads | 28 | 48 | 合格 |

生ZIPにはWindows利用者path、host／OS情報、container等のID、Tor exit IPが含まれるため公開しない。
実メール、token、private key、実Bridge lineは検出されなかった。誤検出したメール形式は
systemd unit名`container-getty@tty1.service`だった。

公開リポジトリへは`docs/evidence/rc10-windows-docker-public-summary.json`のみを置く。
このsummaryはsource identity未検証を明示し、`release_gate_eligible=false`とする。
rc.12では未識別source archiveをDocker build前に拒否し、source identityと検証対象OCI labelの一致を確認して公開用summary生成を回帰試験する。

## rc.12 verified-commit Windows Docker再実証

2026-09-13、Git checkoutのcommit
`09340692f842bfccd34b3b8f38b4d1ee25a5ef21`でフル検証を実施し、全12項目が成功した。

| 指標 | rc.12実測 | active上限 | 判定 |
|---|---:|---:|---:|
| image size | 140,802,162 bytes | 180,000,000 | 合格 |
| packages | 101 | 115 | 合格 |
| Bootstrap | 38,346 ms | 180,000 | 合格 |
| steady memory max | 137,338,880 bytes | 230,686,720 | 合格 |
| idle CPU | 33,183 usec/s | 50,000 | 合格 |
| PIDs/threads | 28 | 48 | 合格 |

source identity、OCI version `0.4.0-rc.12`、OCI revisionが一致した。
公開用summaryは`docs/evidence/rc12-windows-docker-public-summary.json`に置き、
`release_gate_eligible=true`とする。生ZIPにはWindows利用者path、host／OS情報、
local Docker ID、Tor exit IPが含まれるため公開しない。実credential、private key、
実Bridge lineは検出されず、メール形式の検出はsystemd unit名
`getty@tty1.service`のみだった。


## rc.12 実コンテナchild failure実証

2026-09-13、commit `70e39999f4b65df294eb84516a255566b3cfb3c6`の試験ハーネスと、
commit `5521fdac131c48657a7c5ec4e9080fd0ef36817d`から構築したローカルruntime imageで
外部通信を遮断した障害試験を実施した。

- Privoxyを明示終了: supervisorがTorを停止し、containerは非zero終了
- Torを明示終了: supervisorがPrivoxyを停止し、containerは非zero終了
- 両caseでchild固有の診断を確認
- read-only、capabilityなし、no-new-privileges、PID上限を維持
- test containerは終了時に削除され、host portは公開しない

判定: supervisorの実container child failure補助gateは合格。


## rc.12 arm64 QEMU live実証

2026-09-13、commit `8088262334b16236175cceb4209ab93e336565d3`から
`linux/arm64` runtime imageをbuildし、Docker DesktopのQEMU emulationでlive smokeを実施した。

- arm64 runtime起動: 成功
- Tor Bootstrap 100%／circuit確立: 成功
- SOCKS5 remote DNS／HTTPS／Tor判定: 成功
- HTTP CONNECT／HTTPS／Tor判定: 成功
- test container自動削除: 成功
- live smoke exit code: 0

response body、Tor exit IP、host path、container IDは記録しない。判定: arm64 live補助gate合格。


## rc.12 Bridge秘密情報staging異常系実証

2026-09-13、commit `8e32d3591fa5dcaed6f81bf07cd5d4c837d3ef7b`で、
Windows Docker Desktopからリポジトリ外の一時ファイルに置いた無効なダミーBridge行を使用した。

- ephemeral Docker volumeへmode `0600`、owner `65532:65532`でstaging: 成功
- 無効Bridgeのためhealth到達前に非zero終了: 期待どおり（exit code 1）
- 利用者向け診断でcontainer logとBridge内容を非表示: 成功
- 終了後の`toroute-bridge-*` container／volume残存なし: 成功
- host一時ファイル削除: 成功

判定: Bridge秘密情報のstaging、失敗時の秘匿診断、cleanupの異常系補助gateは合格。
有効な実Bridgeを用いる接続試験は、秘密情報をGitHubや対話へ掲載せず、保守担当者が
リポジトリ外のファイルpathだけをハーネスへ渡して行う別gateとする。
