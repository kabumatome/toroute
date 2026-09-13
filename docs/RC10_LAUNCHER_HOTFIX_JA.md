# ToRoute 0.4.0-rc.10 Windows launcher修正

作成日: 2026-07-24  
区分: 公開用技術資料

## 入力正本

- source archive: `ToRoute_0.4.0-rc.9_source.zip`
- SHA-256: `6ae3ebcfe0fdf1f19d6486e5a65b2ebd289435b3353862dac1b6cb1e356f2566`
- source commit metadata: `c717cdedaaf07674d50c5903098d9a02bb3bba89`

## 利用者報告

ルートCMDを起動するとコマンド画面が一瞬で閉じ、Docker検証が開始された形跡を確認できなかった。

rc.9のルートCMDには末尾`pause`が存在したが、表示保持を単一入口の末尾処理へ依存していた。inner CMDの直接起動には保持処理がなく、外部環境や入口の違いでPowerShell前の診断を失う余地があった。

## rc.10修正

- Explorer起動を専用の`cmd.exe /k`consoleへ再起動
- root CMDの処理終了後も専用consoleを保持
- inner CMDの直接起動をroot CMDへ転送
- PowerShell parserより前に`validation-results/launcher-bootstrap.log`を生成
- `last-launch.log`と結果ZIPの場所を常時表示
- 一般環境向けのno-pause環境変数を廃止
- GitHub Actionsのplatform markerだけを非対話実行として扱う
- root／inner CMDの全labelと`goto`先を静的検査
- persistent console、bootstrap log、direct-inner redirectをrepository contractへ追加

## 変更しない範囲

Tor、Privoxy、Go runtime、Dockerfile、Compose network、health synchronization、SOCKS／HTTP／NEWNYM、runtime budgetには変更を加えない。
