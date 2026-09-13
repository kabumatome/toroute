# ローカルフル検証手順

この手順は実機で完全な検証を行うためのものです。制約された作業環境では
`go`、`gofmt`、`docker`、`shellcheck` が使えない場合があるため、Go/Docker/Windows
検証は開発者PCまたはCI用マシンで実行します。

## 1. 前提ツールを確認する

ソースルートで次を実行します。

```bash
bash ./scripts/check-validation-environment.sh
```

必須ツールは次の通りです。

- Git
- Python 3
- PyYAML (`python3 -c 'import yaml'` が成功すること)
- Go
- gofmt
- Docker
- Docker Compose v2 (`docker compose version` が成功すること)
- ShellCheck

## 2. ソース検証を実行する

```bash
python3 ./scripts/validate-source.py
```

この入口は次をまとめて実行します。

- `gofmt`
- privacy scan
- OCI / attestation / vulnerability policy regression
- runtime budget policy regression
- release tooling regression
- repository and workflow policy validation
- ShellCheck (`scripts/*.sh`)
- `go vet ./...`
- race tests and coverage (`./scripts/test-go.sh`)

## 3. Docker/Compose検証を実行する

Docker Desktop または Docker Engine が使える環境で、必要に応じて次を実行します。

```bash
make docker-validation-images
make docker-config-test
make docker-network-test
make docker-child-failure-test
```

ライブTor経路まで確認する場合は、ネットワーク到達性と時間に余裕がある環境で次も実行します。live smokeはホストPythonを必要としません。

```bash
make docker-live-test
# arm64 QEMU live: DOCKER_PLATFORM=linux/arm64 IMAGE=toroute:local-arm64 make docker-live-test
make docker-benchmark
```

## 4. Windowsランチャー検証を実行する

Windows でDocker Desktopを起動した状態で、展開済みソースルートから次を実行します。

```cmd
.\RUN_DOCKER_VALIDATION.cmd
```

この検証は、amd64/arm64イメージ、Composeネットワーク、SOCKS/HTTP経路、
SAFECOOKIE/NEWNYM、runtime metrics、ログスキャン、証跡ZIP生成を確認します。

## 5. Issue #6 を閉じる条件

Issue #6 は、少なくとも次が完了してから閉じます。

- `python3 ./scripts/validate-source.py` が成功
- Docker/Compose検証が成功
- Windows配布を予定する場合は `RUN_DOCKER_VALIDATION.cmd` が成功
- 生成された証跡にBridge、token、private hostname、ローカル個人パスなどが含まれないことを確認

GitHub Actions は現在リポジトリ設定で無効です。Actionsを有効化する場合は、先に上記検証を
通し、`docs/RELEASE_CRITERIA.md` の Public release gate に従って、selected actions、
full-length SHA pinning、read-only default workflow token、fork PR secrets 無効を維持します。

## 6. Windows hostを汚さない隔離source検証

WindowsへGo、PyYAML、ShellCheckを導入しない場合は、Git for WindowsとDocker Desktop
だけを使用し、現在のrepositoryをread-only mountした一時container内で検証する。

```powershell
docker run --rm `
  --mount "type=bind,source=$($PWD.Path),target=/src,readonly" `
  --env DEBIAN_FRONTEND=noninteractive `
  golang:1.26.5-bookworm `
  bash -c 'set -Eeuo pipefail; git clone --no-hardlinks /src /work; cd /work; apt-get update; apt-get install -y --no-install-recommends python3 python3-yaml shellcheck zip unzip; python3 ./scripts/validate-source.py'
```

`--rm`でcontainer、apt導入物、module／build cacheを終了時に破棄する。source bind
mountはread-onlyであり、検証生成物はhostへ書き戻さない。Go base imageだけはDocker
cacheに残るため、全隔離検証の終了後に完全一致tagを指定して削除できる。


## 7. Bridge／obfs4 live検証（秘密情報が必要な場合のみ）

実Bridge lineはrepository外の専用ファイルへ保存し、公開Issue、対話サービス、command line、環境変数へ本文を貼らない。通常のCompose secretはowner/mode条件を直接満たさないため、境界を緩和せず専用harnessで一時volumeへ安全にstageする。

```bash
./scripts/bridge-live-test.sh toroute:local-validation /absolute/path/outside/repository/bridges.txt
```

harnessはrepository内pathとsymlinkを拒否し、secret本文をstdinだけで渡す。終了時は成功・失敗を問わずtest containerとsecret volumeを削除する。失敗時のcontainer logはBridge漏えい防止のため表示しない。
