# Windows Docker実証手順

この手順は、ToRouteのSource RCをWindows上のDocker Desktopで実証するためのものです。WSL、Git Bash、Python、Go、curlの事前導入は不要です。

## 必要なもの

- Windows 10またはWindows 11
- Docker Desktop
- Linux containersモード
- Docker Engine 25.0以降
- Docker Compose 2.33.1以降
- インターネット接続
- 目安として空きディスク5 GB以上

Docker Desktopは起動した状態にしてください。arm64試験はDocker Desktop内蔵QEMUを使用するため、amd64ビルドより時間がかかります。

## フル検証

Source ZIPを展開し、展開したToRouteディレクトリで次を実行します。 **Windowsの圧縮フォルダー表示からCMDを直接実行せず、必ず「すべて展開」してから実行してください。**

```cmd
.\RUN_DOCKER_VALIDATION.cmd
```

0.4.0-rc.10では、エクスプローラーからダブルクリックすると現在の画面内で永続的な子`cmd.exe /k`へ再起動し、検証終了後も閉じません。PowerShellより前の起動診断は`validation-results\launcher-bootstrap.log`、parser以降は`validation-results\last-launch.log`へ保存します。内側のCMDを直接実行してもルートlauncherへ戻ります。

処理内容は次のとおりです。

1. Docker daemon、Linux containers、Compose、Buildxを確認
2. amd64のToRoute、netprobe、proxycheckをローカルbuild
3. non-root、read-only、capability削除、no-new-privilegesを確認
4. 未知設定、危険な旧設定、実行binary差替えが拒否されることを確認
5. 二重ネットワークを起動し、ToRouteのdefault gatewayを確認
6. client networkからの直接通信を拒否し、ToRoute SOCKSには到達できることを確認
7. SOCKS5 remote DNSでTor通信を確認
8. HTTP CONNECTでTor通信を確認
9. NEWNYMとControl socket往復を確認
10. image容量、package数、Bootstrap時間、メモリ、PID、idle CPUを採取
11. ログのBridge、認証値、秘密鍵らしき文字列を検査
12. arm64 imageをbuildし、QEMUでnative config validationを実行
13. 結果一式をZIPへ保存

TorのBootstrapとarm64 emulationを含むため、初回は長くなる場合があります。Docker Desktopではmulti-platform imageをQEMUでbuild・実行できますが、native実行より遅くなるのは正常です。

## 短縮検証

Torの外部通信とruntime計測を省略する場合:

```cmd
.\RUN_DOCKER_VALIDATION.cmd -Quick
```

arm64も省略する場合:

```cmd
.\RUN_DOCKER_VALIDATION.cmd -Quick -SkipArm64
```

build cacheを使わず再検証する場合:

```cmd
.\RUN_DOCKER_VALIDATION.cmd -NoCache
```

失敗時にコンテナを残して確認する場合:

```cmd
.\RUN_DOCKER_VALIDATION.cmd -KeepContainers
```

## Docker実行前の自己診断

0.4.0-rc.6では、Docker buildへ進む前にWindows PowerShell上で`ProcessStartInfo`ベースのnative command runnerを実行し、空白を含む引数、stdout、stderr、非0終了コード、UTF-8、JSON証跡生成、source identityを確認します。Git checkoutでは実HEADを優先し、`.git`を含まない配布ZIPではパッケージ時に生成される`SOURCE_METADATA.json`を使用します。rc.12以降は、どちらも利用できないarchiveを未検証の`source-archive`として続行せず、Docker build前にfail-closedで停止します。GitHubの自動生成「Download ZIP」ではなく、公式source packageまたはGit checkoutを使用してください。

自己診断だけを実行する場合は次を使用します。

```cmd
RUN_DOCKER_VALIDATION.cmd -PreflightOnly
```


## 結果

実行後、次の場所に結果が作成されます。

```text
validation-results\ToRoute-Docker-Validation-YYYYMMDD-HHMMSS\
validation-results\ToRoute-Docker-Validation-YYYYMMDD-HHMMSS.zip
```

ZIPには以下が含まれます。

- `SUMMARY.md`
- `result.json`
- Docker／Buildx version
- image／container inspect
- ToRoute status
- SOCKS／HTTP proxycheck結果
- package一覧
- runtime metrics
- container logs
- build／Compose command logs

成功時・失敗時とも、生成された生ZIPは非公開で保管してください。標準検証でもWindows利用者path、host／OS情報、ローカルimage／container／network ID、Tor exit IPが含まれ得るため、生ZIPや個別logをGitHubへ公開してはいけません。

公開用には、Python 3が使えるmaintainer環境で次を実行し、固定allowlistの最小summaryだけを生成します。

```bash
python3 scripts/sanitize-validation-evidence.py \
  validation-results/ToRoute-Docker-Validation-YYYYMMDD-HHMMSS.zip \
  --output public-validation-summary.json
```

生成summaryは検証名、成否、所要時間、runtime budget、検証済みcommit identityだけを含みます。source identityが40桁Git commitでない場合、または検証対象OCI imageのversion／revision labelと一致しない場合は`release_gate_eligible=false`となります。

## 画面がすぐ閉じる、または何も始まらない場合

0.4.0-rc.10ではルートCMDが現在の画面内で永続的な子consoleへ再起動します。開始できない場合は、次の2ファイルを共有してください。

```text
validation-results\launcher-bootstrap.log
validation-results\last-launch.log
```

Docker検証本体まで到達した場合は、同じディレクトリに結果ZIPも作成されます。`last-launch.log`にはPowerShell選択結果、script parser結果、実行引数、終了コードが記録されます。

既存のコマンドプロンプトから実行する場合は、展開先で次を実行できます。

```cmd
RUN_DOCKER_VALIDATION.cmd
```

GitHub Actionsではplatformが設定する`GITHUB_ACTIONS=true`を検出し、非対話で実行します。一般のWindows環境では画面保持を無効化する環境変数を提供しません。

## rc.7のcgroup計測方式

Windowsから複数行の`/bin/sh -c`を渡す方式は使用しない。`memory.current`、`pids.current`、`cpu.stat`（cgroup v1では対応するlegacy file）を`docker exec ... /bin/cat`で個別に読み、数値解析はPowerShell側で行う。runtime metricsだけが失敗しても、ログ監査とarm64検証は続行し、最終結果はfail-closedで失敗として記録する。

## Tor readyとDocker healthの同期

`toroute healthcheck --json`が100% readyを返しても、Docker Engineの定期health probe結果が`State.Health.Status`へ反映されるまで数秒差が生じる場合があります。rc.9ではready後に最大45秒、2秒間隔でDocker stateを確認します。

- `starting`: 待機を継続
- `healthy`: 成功
- `unhealthy`: 即失敗
- container停止、health欠落、JSON異常: 即失敗
- 45秒timeout: 失敗

全観測は`docker-health-sync.jsonl`へ保存されます。Bootstrap時間はTor直接readyまでを測定し、Docker同期待ち時間は加算しません。
