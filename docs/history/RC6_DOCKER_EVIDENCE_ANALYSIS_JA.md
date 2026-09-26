# ToRoute 0.4.0-rc.6 Docker証跡分析

作成日: 2026-07-21  
区分: 公開用技術資料

## 判定

rc.6 exact imageは、runtime metrics取得の直前まで製品経路を正常完走した。総合結果は証跡runnerの引用不具合により失敗であり、全項目成功とは扱わない。

## 成功した項目

- Windows PowerShell runtime self-test
- Docker Desktop／Compose／Buildx前提
- amd64 runtime／netprobe／proxycheck build
- image metadata、UID/GID 65532、read-only root、capabilityなし、no-new-privileges
- Tor／Privoxy native configと設定境界
- hardened Compose readiness、Bootstrap 100%
- application networkの直接egress失敗とproxy到達
- SOCKS5 remote DNS、HTTPS、Tor判定
- HTTP CONNECT、HTTPS、Tor判定
- SAFECOOKIE／NEWNYM後のhealth

## 実測できた値

- image size: 140,775,431 bytes
- installed package count: 101
- Bootstrap: 33,969 ms
- Tor: 0.4.9.11
- image user: `65532:65532`
- host公開port: なし

rc.5比でimageは1,820,713 bytes、package数は2件減少した。

## 最初の失敗

Windows PowerShellから複数行の`/bin/sh -c`引数をDockerへ渡した際、引用符が二重化され、shellが`fi`未完了として終了コード2を返した。cgroup fileやToRoute runtimeの異常ではない。

## rc.7での対策

- Windows runnerから`/bin/sh -c`を全面撤去
- `/proc/1/status`、`/proc/net/route`、cgroup filesを`docker exec /bin/cat`で直接取得
- cgroup v1/v2の解析をPowerShell側で実施
- native引数にCR／LF／NULが含まれた時点で拒否
- PowerShell 5.1自己試験でcgroup v1/v2 parserを検証
- metrics failureをcontinue-on-failure化し、log auditとarm64証跡を継続

## rc.7再実証で確定する項目

- memory min／median／max
- idle CPU usec/s
- PIDs／threads max
- log secret scan
- arm64 QEMU build／native config
- active runtime budget総合判定
