# ToRoute

> **状態: 0.4.0-rc.12 Source candidateです。rc.8でContainer RC全12項目に成功し、rc.9でDocker health同期を強化しました。rc.10はWindowsのダブルクリック起動を専用の永続consoleへ固定し、起動前ログを追加したlauncher修正版です。rc.11はBridge秘密ファイル検査とrelease／Actions費用制御を強化した監査修正版です。rc.12はsource identity不明archiveを拒否し、公開可能な最小証跡を生成する修正版です。一般公開v1.0ではありません。**

ToRouteは、Docker上のアプリケーションへTorネットワーク経由のTCP
アウトバウンドSOCKS5プロキシを提供する、独立したコミュニティ
プロジェクトです。Tor Projectの公式製品・後継製品ではありません。

## 主な機能

- SOCKS5 `9050/tcp`
- 明示有効化するHTTP proxy `8118/tcp`
- 型付き・fail-closed設定API
- Unix control socket＋SAFECOOKIE
- Bootstrap対応healthcheckとJSON status
- 出口国・除外国
- 検証済みobfs4 Bridgeファイル
- non-root、read-only root filesystem
- amd64／arm64公開設計

relay、exit relay、Onion Service、透過ルーティング、UDP、ブラウザ指紋
対策、匿名性の保証は対象外です。

## 推奨Compose

アプリは`internal`なclient networkだけへ参加させ、ToRouteだけが外向き
networkにも参加します。`gw_priority`で外向き側をデフォルト経路にします。

```yaml
services:
  toroute:
    image: ghcr.io/kabumatome/toroute:1.0.0
    read_only: true
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /run/toroute:uid=65532,gid=65532,mode=0700
    volumes:
      - toroute-data:/var/lib/toroute
    networks:
      client: {}
      egress:
        gw_priority: 1

  app:
    image: your-application-image
    environment:
      ALL_PROXY: socks5h://toroute:9050
    networks: [client]

networks:
  client:
    internal: true
  egress: {}
volumes:
  toroute-data: {}
```

クライアントが対応している場合は`socks5h`を使用してください。内部networkは
偶発的なTCP直通を減らしますが、DNS漏えい防止や完全なsandboxではありません。


Torが直接healthcheckで100% readyになった後、Windows実証runnerはDocker healthが`healthy`へ反映されるまで最大45秒待機します。`starting`／`healthy`の全観測は`docker-health-sync.jsonl`へ保存し、`unhealthy`、container停止、health欠落、timeoutはfail-closedで停止します。

## WindowsでのDocker実証

Docker Desktopを起動し、展開したSource RCのルートで次を実行すると、buildから結果ZIP作成まで自動で行います。WSL、Git Bash、Go、Python、curlの事前導入は不要です。

```cmd
.\RUN_DOCKER_VALIDATION.cmd
```

0.4.0-rc.10では、エクスプローラーからのダブルクリックを現在の画面内で永続的な子`cmd.exe /k`へ再起動します。PowerShell前の診断は`validation-results\launcher-bootstrap.log`、parser以降は`validation-results\last-launch.log`へ保存します。
0.4.0-rc.5ではread-only root filesystem上の`check-config`を修正しました。0.4.0-rc.6ではruntime budgetをactive化し依存を削減、0.4.0-rc.8では直接cgroup file読込を含むDocker実証12項目を完走しました。rc.9はTor直接ready後のDocker health反映だけを同期します。

既定ではamd64 build、設定境界、non-root/read-only/capability、Compose直通防止、SOCKS5 remote DNS、HTTP CONNECT、Tor判定、NEWNYM、runtime計測、ログ監査、arm64 QEMUを確認します。結果は`validation-results`に保存されます。

詳しくは[Windows Docker実証手順](docs/validation/DOCKER_VALIDATION_WINDOWS_JA.md)を参照してください。

## ベースイメージと軽量化

v1.0の既定runtimeは`debian:trixie-slim`です。これはCPU性能のためではなく、
Tor、Privoxy、obfs4proxy、GeoIP、Tiniを一つの署名済みdistributionから揃え、
最初の安定版でnative packageとlibcの分岐を増やさないためです。実行中の負荷は
主にTorの暗号処理・回線構築・network処理で決まり、base imageの差は主にpull容量、
展開容量、package管理、互換性へ現れます。

Alpineはpost-v1.0の正式な比較対象として残します。feature parityを落とさず、
同じamd64/arm64・Bridge・live Tor・脆弱性・SBOM/provenance試験に合格し、
実測で十分な改善が出た場合だけvariantまたは既定baseとして採用します。
公開候補ではimage size、Bootstrap時間、steady memory、PID、idle CPUをJSON証跡に
記録します。詳細は[ベースイメージ判断](docs/release/BASE_IMAGE_DECISION.md)を参照してください。

## CLI

```text
toroute run
toroute check-config
toroute print-config [--format torrc|privoxy|json]
toroute status [--json]
toroute healthcheck [--json]
toroute newnym
toroute exec [--] <command> [args...]
toroute compat dperson [-l CC] [-n]
toroute version
```

`status`は情報表示、`healthcheck`はBootstrap 100かつTCP SOCKS listenerが
存在するまで失敗します。`newnym`は将来のstream向けで、出口IP変更を保証しません。
Torのcold startではdirectory取得に時間がかかる場合があります。image healthcheckは最大420秒の起動猶予中に5秒間隔でreadyを確認し、一度readyになった後は30秒間隔の通常監視へ移ります。起動猶予中もBootstrap 100%未満をreadyとは扱いません。


詳細は[Container RC実証記録](docs/history/CONTAINER_RC_EVIDENCE_JA.md)、[要件定義・設計・進捗状況](docs/core/REQUIREMENTS_AND_DESIGN_JA.md)、[検証報告](docs/history/VALIDATION_REPORT_JA.md)を参照してください。

## 公開名とOwner

名称は当面ToRouteを使用します。Owner置換とGitHub／Docker Hub公開操作は、技術v1.0候補の完成後に実施します。必要になった場合はrename後に全gateを再実行します。

## ドキュメント

設計・設定・検証・リリース・過去証跡の入口は[ドキュメント索引](docs/README.md)です。
