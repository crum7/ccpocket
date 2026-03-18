# Claude 認証トラブルシューティング

CC Pocket は Bridge マシン上に保存された Claude Code のログイン状態を使います。
認証エラーが出たら、そのマシンで Claude Code に再ログインしてください。

## おすすめの対処

**Bridge マシン** で次を実行します。

1. `claude` で Claude Code を起動
2. `/login` を実行
3. ブラウザでサインインを完了

次のリクエストから、CC Pocket が新しいログイン状態を使います。

## シェルから実行する方法

対話画面を開かずに、次のコマンドでも再認証できます。

```bash
claude auth login
```

## よくある原因

- Claude Code のログイン期限が切れた
- Claude Code の更新で以前のログイン情報が無効になった
- Anthropic 側で保存済みトークンが失効した

## ヘッドレス / SSH の場合

Bridge マシンに直接画面がない場合は:

1. ターミナルアプリから Bridge マシンへ SSH 接続
2. `claude` を実行
3. `/login` を入力
4. 表示された URL を iPhone や PC のブラウザで開く
5. サインイン完了後、結果をターミナルへ貼り付ける
