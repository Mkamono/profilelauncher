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

> **注意**: 上位が存在すると下位は無視されます。例えば `~/.config/...` があると
> Application Support 側を編集しても反映されません。`build.sh` の自動生成も install の
> メッセージも、すべて「アプリが実際に読むファイル」に揃えてあります。今どのファイルが
> 使われているかは次で確認できます（迷ったらこれ）:
>
> ```bash
> /Applications/ProfileLauncher.app/Contents/MacOS/ProfileLauncher --config-path
> ```
>
> `--doctor` / `--check` でも "config file" 行に表示され、無視されている設定があれば警告が出ます。

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

`profile` にはディレクトリ名（`Profile 1`）でも表示名（`sub`）でも書けます（大文字小文字は区別しません）。
表示名→ディレクトリの解決は Brave の `Local State` を参照して自動で行われます。

### 動かないときの一発診断（`--doctor`）

「この端末では動くのに別の端末で動かない」ときは、まずこれを壊れている端末で実行します。
デフォルトブラウザが自分か／Brave 実体があるか／設定・プロファイル・直近ログをまとめて出します。

```bash
/Applications/ProfileLauncher.app/Contents/MacOS/ProfileLauncher --doctor
```

```
  [PASS] default browser: ProfileLauncher handles http+https
  [PASS] Brave executable: /Applications/Brave Browser.app/Contents/MacOS/Brave Browser
  [PASS] brave profiles: 3 found: Default="main", Profile 1="sub", ...
  ...
```

よくある原因:

- **config file が FAIL（PARSE ERROR）** … `rules.json` が壊れた JSON。読み込みは
  ルール0件にフォールバックするため、**全 URL が振り分けられず前面プロファイルで開く**。
  → JSON を直す（`--check` で再検証）。末尾の `,` や閉じ忘れ、空ファイルが典型。
- **default browser が FAIL** … リンクは別ブラウザに飛び、本アプリは呼ばれない（ログも増えない）。
  → `--set-default` を実行するか、システム設定で手動指定。
- **Brave executable が FAIL** … その端末では Brave が別の場所にある。
  → `rules.json` の `bravePath` をその端末のパスに設定。
- リンクをクリックしても **recent log が増えない** … やはりデフォルトブラウザになっていない。

### ルールがその端末で有効か検証する（`--check`）

端末ごとにプロファイル名は異なります。rules.json の各ルールが、その端末に実在する
プロファイルへ解決できるかを検証できます。`install.sh` の最後でも自動実行されます。

```bash
/Applications/ProfileLauncher.app/Contents/MacOS/ProfileLauncher --check
```

```
Rules:
  [0] ok  github.com             -> main  (uses Default)
  [1] ERR example.com            -> 仕事用  (NO SUCH PROFILE here)
...
1 reference(s) do not match any profile here.
```

存在しないプロファイルを指定したルールに一致した URL は、**ジャンクな空プロファイルを作らず**、
Brave の前面プロファイルで開きます（その旨はログに残ります）。`--check` を直して正しい名前に
合わせてください。

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
