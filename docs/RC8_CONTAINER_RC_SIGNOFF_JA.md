# ToRoute 0.4.0-rc.8 Container RC 合格記録

作成日: 2026-07-23  
区分: 公開用技術資料

## 判定

2026-07-22のWindows Docker Desktop実証は全12項目成功。G2 Container RCの主要gateを合格とする。

## 成功項目

- Windows PowerShell runtime self-test
- Docker Engine／Compose／Buildx前提
- amd64 runtime／netprobe／proxycheck build
- image metadata、設定境界、non-root、read-only、capabilityなし
- Tor Bootstrap 100%とDocker health
- application networkの直接egress防止
- SOCKS5 remote DNS／HTTPS／Tor判定
- HTTP CONNECT／HTTPS／Tor判定
- SAFECOOKIE／NEWNYM
- runtime metrics／package inventory
- log secret scan
- arm64 QEMU build／native config

## Sanitized full-http amd64実測

| 指標 | 実測 | release上限 |
|---|---:|---:|
| image size | 140,775,431 bytes | 180,000,000 |
| packages | 101 | 115 |
| Bootstrap | 17,647 ms | 180,000 |
| steady memory max | 152,064,000 bytes | 230,686,720 |
| idle CPU | 36,056 usec/s | 50,000 |
| PIDs/threads | 28 | 48 |

生証跡に含まれる利用者path、host識別情報、exit IP、image/container/network IDは本記録へ含めない。

## rc.9の理由

rc.8の成功実行では、直接healthcheckがready=trueになった直前にDockerの5秒startup probeも成功していた。一方、別実行では直接readyの約2秒後、次のDocker probe前に`State.Health.Status=starting`を読み、検証runnerが失敗した。これはToRoute runtimeの失敗ではなく非同期health反映の競合である。

rc.9はTor ready後にDocker healthを最大45秒同期し、`starting`は待機、`healthy`は成功、`unhealthy`またはcontainer停止は即失敗とする。全観測を`docker-health-sync.jsonl`へ保存する。
