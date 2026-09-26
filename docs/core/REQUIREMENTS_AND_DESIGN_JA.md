# ToRoute 要件定義・設計・進捗状況

作成日: 2026-07-23
区分: 公開用技術資料

## 1. 最終目標

ToRouteは、dperson/torproxyで一般的だった簡単なSOCKS／HTTP利用を維持しながら、安全既定、typed設定、Control認証、non-root／read-only、network isolation、multiarch、検証済みartifact昇格を備えるTor client containerを提供する。

v1.0は、設定、実コンテナ、実通信、供給網、配布物が同時に検証された状態とする。

## 2. v1.0 scope

含む:

- SOCKS5 `9050`
- 明示有効化HTTP adapter `8118`
- typed `TOROUTE_*` API
- Tor／Privoxy native config validation
- `status`／`healthcheck`／`newnym`
- Unix Control socket＋SAFECOOKIE
- exit country／exclude country
- obfs4 Bridge secret file
- non-root／read-only／capabilityなし
- Tor／Privoxy process-group supervision
- 限定dperson移行
- amd64／arm64
- GHCR、任意Docker Hub
- vulnerability、SBOM、provenance、digest identity

対象外:

- relay／exit relay／bridge relay
- Onion Service hosting
- transparent proxy／iptables／DNSPort／TransPort
- UDP／QUIC／WebRTC
- Tor Browser相当のfingerprint対策
- 任意`TOR_*`と無制限torrc
- host全体の匿名化

## 3. 主要セキュリティ境界

- UID/GID `65532:65532`
- read-only root filesystem
- `cap_drop: ALL`
- `no-new-privileges`
- TCP ControlPortなし
- Unix socket＋SAFECOOKIE server proof検証
- Bridge fileのsymlink、owner、mode、size、line検査
- unknown／empty／legacy／generic `TOR_*`をfail-closed
- runtime/data pathのsymlink／overlap／共有system directory拒否
- child異常終了時のTERM→KILL→有限reap
- secret／Bridge／Control materialをログへ出さない
- applicationをinternal networkへ隔離し、ToRouteだけにegressを付与

## 4. 現在の進捗

| 評価軸 | 完了率 | 判定 |
|---|---:|---|
| 要件・脅威モデル・scope | 97% | G0ほぼ完了 |
| コアGo実装 | 94% | Source RC |
| ソース自動試験 | 94% | 全8 race／vet／policy、coverage 67.6% |
| Docker／Compose設計 | 100% | rc.12 verified-commit実Docker全12項目成功 |
| 実コンテナ／Tor通信 | 100% | rc.12 amd64・arm64 SOCKS／HTTP、NEWNYM、isolation成功 |
| arm64 | 100% | QEMU build／config／SOCKS／HTTP live成功 |
| runtime budget／軽量化 | 96% | rc.12 verified-commit実測、全budget合格 |
| release／registry workflow | 87% | build-once設計、実registry待ち |
| vulnerability／SBOM／provenance | 88% | policy完成、actual candidate待ち |
| 文書／配布 | 95% | rc.8実証と復元来歴へ同期 |
| 公開導入／独立review | 35% | Owner確定後の工程 |
| **総合公開準備度** | **約91%** | **G2合格、G3準備中** |

## 5. 機能別進捗

| 機能 | 完了率 | 現状／残件 |
|---|---:|---|
| SOCKS5 | 98% | remote DNS／HTTPS／Tor判定成功 |
| HTTP adapter | 97% | Privoxy native／CONNECT／Tor判定成功 |
| typed設定 | 96% | image境界を含めfail-closed確認 |
| Tor renderer | 96% | client-only／native validation成功 |
| Control／SAFECOOKIE | 96% | 実Tor往復／NEWNYM成功 |
| status／healthcheck | 97% | cold-start、100%、Docker health確認 |
| exit country | 90% | parser／renderer／GeoIPあり、live country補助確認待ち |
| Bridge／obfs4 | 92% | 秘密情報staging／異常系／cleanup実Docker成功、実Bridge live待ち |
| read-only runtime | 98% | native config／起動／metrics成功 |
| supervisor | 100% | race・Tor failure・Privoxy failure実コンテナ試験成功 |
| Compose isolation | 98% | direct-connect失敗、proxy到達成功 |
| amd64 | 98% | build／config／live成功 |
| arm64 | 100% | QEMU build／config／SOCKS／HTTP live成功 |
| release identity | 90% | local source／OCI identity一致、実registry promotion待ち |
| vulnerability | 88% | 両platform policy完成、actual Trivy待ち |
| SBOM/provenance | 87% | validator完成、actual attestation待ち |

## 6. Runtime baseline

レビュー済み0.4.0-rc.8 full-http amd64実測:

- image: 140,775,431 bytes
- packages: 101
- Bootstrap: 17,647 ms
- memory max: 152,064,000 bytes
- idle CPU: 36,056 usec/s
- PIDs/threads: 28

active上限はimage 180 MB、packages 115、Bootstrap 180秒、memory 220 MiB、idle CPU 50,000 usec/s、PIDs/threads 48。全項目合格。

## 7. Gate

- G0 仕様凍結: ほぼ完了
- G1 Source RC: 合格
- G2 Container RC: rc.12 verified-commit全12項目・全budget成功で合格
- G3 Release RC: actual Trivy／SBOM／provenance／registry rehearsal待ち
- G4 Public v1.0: Owner設定、独立review、正式registry公開待ち

rc.9はTor直接readyとDocker health反映の同期、rc.10はWindows launcher、rc.11はBridge秘密ファイル・release誤操作・Actions費用制御、rc.12は証跡privacy／provenanceを対象とする。rc.12のverified-commit再実証で全変更のWindows Docker回帰を確認した。

## 8. 残る技術P0

1. actual amd64／arm64 vulnerability scan
2. actual SPDX SBOM／SLSA provenance
3. GHCR／Docker Hub single-candidate promotion rehearsal
4. anonymous exact／alias pullとplatform identity
5. GitHub Actions／CodeQL／ShellCheck／actionlint
6. independent security review

Bridge liveは実Bridge秘密情報を必要とする任意補助gateとして継続する。秘密情報stagingの異常系、arm64 live、actual child failure testは2026-09-13のローカルDocker実証で合格した。

## 9. Definition of Done

clean source、race／vet／policy、amd64／arm64 config、amd64 live SOCKS／HTTP、non-root／read-only／capability、direct-connect防止、active runtime budget、両platform vulnerability、SPDX／SLSA identity、tested candidateとpublished exact tagの同一性、anonymous pull、秘密情報なし、独立review、再現可能ZIP／tarを満たすまでstable v1.0を公開しない。

## 10. 2026-09-13 設計監査結果

Private維持を前提に、完成を「公開操作」ではなく「公開判断以外の技術ゲートを
再現可能に通せる候補」と再定義した。監査でBridge秘密ファイルのowner／mode検査、
releaseの明示enableとcurrent-main検査、追跡中の古い`SOURCE_METADATA.json`除去、
定期Actions停止、文書のみの変更に対する重いCI抑制を必須修正とした。

rc.12 verified-commit Windows Docker回帰は完了した。技術完成の残ゲートはactual amd64／arm64
vulnerability、SPDX／SLSA、registry rehearsal、GitHub静的解析、独立security reviewである。
repository公開、GHCR公開、stable tag作成は所有者の明示判断なしに実行しない。


## 11. 2026-09-13 実証証跡監査

rc.10 Windows Docker実証は全12項目と全runtime budgetに成功した。一方、生ZIPには
Windows利用者path、host／OS情報、local ID、Tor exit IPが含まれ、OCI revisionが
`source-archive`だった。よって生ZIPは非公開、sanitized summaryだけ公開可能、
この実行はContainer機能回帰には採用するがrelease identityには採用しないと判定した。

rc.12では、有効なGit HEADまたはpackage生成済み`SOURCE_METADATA.json`がないarchiveを
fail-closedにし、OCI labelとのidentity一致も確認するallowlist型public-summary generatorと漏えい・異常入力回帰試験を追加する。

## 12. rc.12 verified-commit Windows Docker結果

commit `09340692f842bfccd34b3b8f38b4d1ee25a5ef21`で全12項目と全active
runtime budgetが成功した。source identityとOCI version／revision labelは一致し、
sanitized public summaryは`release_gate_eligible=true`である。生ZIPは利用者path、
host情報、local ID、Tor exit IPを含むため公開しない。
