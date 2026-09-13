# ToRoute Container RC 実証記録

更新日: 2026-09-13
区分: 公開用技術資料

## 判定

**0.4.0-rc.12はverified-commit G2 Container RCの全12項目と全active budgetに合格。**

2026-07-22のWindows Docker Desktop一括検証で全12項目が成功した。生証跡の利用者path、host識別情報、Tor exit IP、image/container/network IDは公開ソースへ含めない。

## 成功した実証

| 検証 | 結果 | 実測 |
|---|---:|---:|
| Windows PowerShell runtime self-test | 成功 | 0.973秒 |
| Docker／Compose／Buildx前提 | 成功 | 1.228秒 |
| amd64 runtime／検証image build | 成功 | 25.623秒 |
| metadata／non-root／設定境界 | 成功 | 6.830秒 |
| hardened Compose／readiness | 成功 | 18.527秒 |
| direct-egress防止／proxy到達 | 成功 | 2.678秒 |
| SOCKS5 remote DNS／Tor実通信 | 成功 | 6.127秒 |
| HTTP CONNECT／Tor実通信 | 成功 | 4.126秒 |
| NEWNYM／SAFECOOKIE | 成功 | 2.426秒 |
| runtime metrics／package inventory | 成功 | 14.607秒 |
| log secret scan | 成功 | 0.140秒 |
| arm64 QEMU build／config | 成功 | 58.423秒 |

Bootstrap progressは`0 → 45 → 56 → 100%`、直接readyまで17,647 ms。

## Runtime baseline: full-http / amd64

| 指標 | 実測 |
|---|---:|
| image size | 140,775,431 bytes |
| installed packages | 101 |
| Bootstrap | 17,647 ms |
| steady memory min | 149,897,216 bytes |
| steady memory median | 151,982,080 bytes |
| steady memory max | 152,064,000 bytes |
| PIDs/threads max | 28 |
| idle CPU | 36,056 usec/s |

CPU値はライブSOCKS／HTTPとNEWNYM直後の10秒sampleを含む保守的な値で、active上限50,000 usec/s以内。

## Hardening

- user `65532:65532`
- read-only root filesystem
- `cap_drop: ALL`
- `NoNewPrivs: 1`
- effective capabilities zero
- PID上限128
- host port mappingなし
- client networkは`internal: true`
- egress networkのみdefault gateway
- clientから外向きtargetへの直接接続失敗
- ToRoute proxyへの接続成功

## Network／Control

- SOCKS5 remote DNS成功
- SOCKS5 HTTPS／Tor判定成功
- HTTP CONNECT HTTPS／Tor判定成功
- SAFECOOKIE認証成功
- NEWNYM受理後もhealth成功
- secret／Bridge／Control materialのログ流出なし

## arm64

Docker Desktop QEMUでlinux/arm64 runtime imageをbuildし、read-only／non-root条件でnative `check-config`成功、`aarch64`確認。arm64のライブTor通信は追加gateとして残る。

## rc.9 runner同期

Tor直接readyとDocker Engine health state反映には数秒差があり得る。rc.9は直接ready後に最大45秒同期し、`starting`は待機、`healthy`は成功、`unhealthy`、container停止、health欠落、timeoutはfail-closedとする。全観測を`docker-health-sync.jsonl`へ保存する。


## 2026-09-13 rc.10 再実証

Windows Docker Desktopで全12項目が再度成功し、rc.9 health同期とrc.10 launcherを確認した。
Bootstrapは43,854 ms、image 140,801,992 bytes、packages 101、steady memory max
136,544,256 bytes、idle CPU 31,557 usec/s、PIDs 28で、全active budget内だった。

生証跡にはWindows利用者path、host／OS識別情報、local container等のID、Tor exit IPが
含まれるため公開しない。固定allowlistで生成した
`docs/evidence/rc10-windows-docker-public-summary.json`だけを公開可能と判定した。

この実行のOCI revisionは`source-archive`でGit commitへ結び付かなかったため、
機能回帰証拠としてのみ採用し、release identity／promotion証拠には採用しない。
rc.12は未識別archiveをfail-closedにし、commit identity付き再実証を要求する。

## 2026-09-13 rc.12 verified-commit再実証

Git checkoutのcommit `09340692f842bfccd34b3b8f38b4d1ee25a5ef21`からWindows
Docker Desktopフル検証を実行し、全12項目が成功した。source identity、検証対象OCI
imageのversion `0.4.0-rc.12`、revisionが一致し、public summaryの
`release_gate_eligible=true`を確認した。

| 指標 | rc.12実測 | active上限 | 判定 |
|---|---:|---:|---:|
| image size | 140,802,162 bytes | 180,000,000 | 合格 |
| packages | 101 | 115 | 合格 |
| Bootstrap | 38,346 ms | 180,000 | 合格 |
| steady memory max | 137,338,880 bytes | 230,686,720 | 合格 |
| idle CPU | 33,183 usec/s | 50,000 | 合格 |
| PIDs/threads | 28 | 48 | 合格 |

生ZIPのSHA-256は
`7862c15eed5547cf4d07f79b547f13098aa28fccd26b64c944caf2f767ca6435`。
生証跡にはWindows利用者path、host／OS情報、local Docker ID、network情報、Tor exit
IPが含まれるため非公開を維持し、
`docs/evidence/rc12-windows-docker-public-summary.json`だけを公開可能証跡とする。
