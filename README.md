# ProfileLauncher

特定の URL を、指定した Brave のプロファイルで自動的に開く macOS 用の振り分けアプリ。

リンクをクリックすると macOS がデフォルトブラウザとして本アプリを起動 → URL をルールに照らして
判定 → 該当する Brave プロファイルで開く。どのルールにも一致しないものは Brave 任せ（前面の
プロファイル）で開く。

## 仕組み

```
リンクをクリック
   ↓ macOS がデフォルトブラウザ（= 本アプリ）を起動し URL を渡す
ProfileLauncher が rules.json を見て判定
   ├ ルール一致 → Brave を --profile-directory 指定で起動
   └ 不一致     → fallbackProfile（既定 null = Brave 任せ）で起動
```

## インストール

```bash
./install.sh
```

ビルド → `/Applications` へ配置 → LaunchServices 登録 → 一度起動 →
デフォルトブラウザに設定要求、まで自動で行います。
macOS の確認ダイアログが出たら「ProfileLauncher を使用」を選んでください。
反映されない場合のみ、システム設定 > デスクトップとDock > デフォルトのWebブラウザ で手動選択します。

デフォルトブラウザ設定だけをやり直したいとき:

```bash
/Applications/ProfileLauncher.app/Contents/MacOS/ProfileLauncher --set-default
```

アンインストール:

```bash
./uninstall.sh           # アプリを削除（rules.json は残す）
./uninstall.sh --purge   # 設定・ログも含めて完全削除
```

### ビルドのみ

```bash
./build.sh
```

`ProfileLauncher.app` が生成され、初回のみ既定の設定が
`~/Library/Application Support/ProfileLauncher/rules.json` にコピーされます（既存があれば上書きしません）。

## 端末をまたいで使う（設定の外出し）

アプリ本体（.app）は共通バイナリのまま、**設定ファイルだけ端末ごとに差し替え**ます。
プロファイル名は端末で異なるので、設定は次の優先順で解決されます。

1. 環境変数 `PROFILELAUNCHER_CONFIG`（dotfiles や iCloud/Dropbox 上のファイルを指す）
2. `~/.config/profilelauncher/rules.json`（XDG 風。git 管理しやすい）
3. `~/Library/Application Support/ProfileLauncher/rules.json`（既定）

dotfiles で共有する例:

```bash
# リポジトリに rules.json を置いておき、各端末でシンボリックリンク
mkdir -p ~/.config/profilelauncher
ln -s ~/dotfiles/profilelauncher/rules.json ~/.config/profilelauncher/rules.json
```

新しい端末では、まずその端末のプロファイル一覧を確認してからルールを書きます:

```bash
./ProfileLauncher.app/Contents/MacOS/ProfileLauncher --list-profiles
```

```
  DIRECTORY     DISPLAY NAME
  Default       main
  Profile 1     sub
  Profile 2     就活
```

`profile` にはディレクトリ名（`Profile 1`）でも表示名（`sub`）でも書けます。
表示名→ディレクトリの解決は Brave の `Local State` を参照して自動で行われます。

## rules.json

```json
{
  "bravePath": "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
  "fallbackProfile": null,
  "rules": [
    { "match": "github.com",     "profile": "main" },
    { "match": "*.github.com",   "profile": "main" },
    { "match": "mail.google.com","profile": "sub"  },
    { "match": "*.rikunabi.com", "profile": "就活" },
    { "match": "*mynavi*",       "profile": "就活" }
  ]
}
```

- `bravePath`: 省略可。既定は `/Applications/Brave Browser.app/...`。
- `fallbackProfile`: どのルールにも一致しなかった時のプロファイル。`null` なら Brave 任せ。
- `rules[].match`: ホスト名に対するグロブ（`*` のみ特殊）。`/` を含む場合は URL 全体に対して照合。
  上から順に評価し、最初に一致したものを採用。
- `rules[].profile`: ディレクトリ名または表示名。

設定は **URL を開くたびに読み直される**ため、`rules.json` を編集すれば次のリンクから即反映されます
（アプリの再起動・再ビルドは不要）。

## テスト

```bash
# 実際に Brave が開くか確認
./ProfileLauncher.app/Contents/MacOS/ProfileLauncher 'https://github.com'

# 動作ログ
tail -f ~/Library/Logs/ProfileLauncher.log
```

## デフォルトブラウザに設定

1. `mv ProfileLauncher.app /Applications/`
2. 一度起動して LaunchServices に登録（`open /Applications/ProfileLauncher.app`）
3. システム設定 → デスクトップとDock → 「デフォルトのWebブラウザ」で ProfileLauncher を選択
   - 候補に出ない場合は一度 `open` で起動してから再度確認

## 注意

- ad-hoc 署名のため、初回は Gatekeeper の確認が出ることがあります（右クリック→開く で許可）。
- Brave 本体は通常どおり別に存在している必要があります（本アプリは起動を仲介するだけ）。
