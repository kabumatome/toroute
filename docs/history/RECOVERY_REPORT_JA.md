# 成果物回収・再構築報告

会話上限後、現在の作業領域は初期化されており、以前のToRouteおよび旧試作名のソース
ZIPは残っていなかった。File Libraryにも本体は見つからなかった。

回収できたもの:

- dperson/torproxyを利用していた旧Compose
- ControlPort無認証警告、Tor data directory所有権エラーを含むbuild log
- bootstrap 30%停止・接続拒否を含むruntime log
- 会話に残った要件、修正履歴、P0ブロッカー、release設計

今回、これらを基にToRoute名でソース、テスト、Dockerfile、Compose、CI、
release workflow、日英文書、公開scriptを新規再構築した。旧環境固有Composeや固有名は
公開リポジトリへ取り込んでいない。


## 再構築後の到達点

- ToRoute名、`TOROUTE_`設定API、Go module placeholderを統一。
- コアGo実装、race tests、Dockerfile、Compose、CI、release workflowを復元。
- `make validate`を27.18秒で完走し、反復race試験にも成功。
- single BuildKit candidate、registry-local digest、OCI runtime/attestation、
  platform別SBOM/provenance、両platform脆弱性policyを公開ゲートへ実装。
- Docker daemonがないため、Container RC以降はGitHub Actionsでの実証待ち。


## 0.3.0-rc.1更新

- Debian 13 slimをv1.0既定baseとして維持する理由と、post-v1.0 Alpine比較gateを追加。
- image package inventory、Bootstrap、memory、PID、idle CPUの証跡とruntime budgetを追加。
- CIのsource互換試験とpolicy試験を分離し、低資源環境の診断性を改善。
- release／bootstrapへ`python3-yaml`を明示追加し、repository policyの実行不能を修正。
- 正式候補へ全package inventoryを保存し、Trivy Action v0.36.0とscanner v0.72.0を固定。
