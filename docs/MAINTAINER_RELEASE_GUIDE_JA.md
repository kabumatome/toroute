# 初回公開・リリース手順

1. 公開活動用GitHub ownerを用意し、commit emailをGitHubのnoreplyへ設定する。
2. `kabumatome/toroute`以外のownerで公開する場合は、そのownerに合わせて
   `./scripts/prepare-release.sh OWNER`を実行する。`kabumatome/toroute`で公開する
   場合は、owner/link/image設定がすでに一致していることを確認する。
3. `make validate`を実行し、公開情報・秘密情報を目視確認する。
4. GitHub public repositoryを作成し、branch/tag rules、private vulnerability
   reporting、Actions最小権限を設定する。
5. `Bootstrap GHCR package` workflowを実行する。
6. GHCR packageをPublicへ変更し、匿名pullを確認する。
7. Docker Hubを使う場合、専用の最小権限tokenとrepository variableを登録する。
8. CI、CodeQL、scheduled live testを成功させる。
9. release直前にrepository variable `TOROUTE_RELEASES_ENABLED=true`を設定し、release tagをその時点の`main`先頭commitへ付ける。
10. `v1.0.0-rc.1`で完全なrelease rehearsalを実施する。
11. workflow完了後は`TOROUTE_RELEASES_ENABLED`を削除または`false`へ戻す。
12. 証跡と独立reviewを確認してから、同じ明示ゲート手順で`v1.0.0`を作成する。

実メール、token、Bridge、環境固有Compose、Windows実パスをrepositoryへ入れない。
