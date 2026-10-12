# 変更履歴 (remediation_history.md)

## 2026-10-12
### 1. リポジトリ初期セットアップと環境調査
- `https://github.com/Maximilian2022/hayamimi` を `e:\hayamimi` にクローン
- ホスト環境の調査:
  - WSL 3.0 / WSL Containers CLI (`wslc.exe`) の存在と動作を確認
- 長期記憶・作業メモ・変更履歴ファイルの新規作成 (`docs/memory.md`, `docs/memo.md`, `docs/remediation_history.md`)

### 2. コンテナ設定の修正とWSL3ビルド・検証
- `Dockerfile`:
  - Windows環境でのGitクローン時に発生する改行コードCRLF混入による `env: 'bash\r': No such file or directory` エラーを防ぐため、`RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh` を追加
- `entrypoint.sh`:
  - ファイルの改行コードを LF に正規化
- WSL Containers (`wslc build`) による `hayamimi:latest` のビルド検証完了
- ホスト `models/` ディレクトリの作成とボリュームマウントによる Coreモデル群 (約1.1GB) の初回ダウンロード・永続化を完了
- `http://localhost:8833/mic` への通信・応答確認 (HTTP 200)

### 3. ランチャーおよびGUIの実装
- `start.bat`:
  - WSL Containers (`wslc`) の存在チェック
  - コンテナイメージが存在しない場合の自動ビルド処理
  - バックグラウンドでの `scripts/launcher_gui.ps1` 呼び出し
- `start_debug.bat`:
  - トラブルシューティング用のコンソール表示付き起動バッチ
- `scripts/launcher_gui.ps1`:
  - WPF (XAML) によるダークテーマのモダンカード風GUI
  - 状態インジケーター（LEDドット & 状態テキスト）
  - 「コンテナ起動 & Webを開く」ボタン（非同期起動・ヘルスチェック待機・ブラウザ自動起動）
  - 「コンテナ終了 & 閉じる」ボタン（非同期停止・コンテナクリーンアップ・GUI自動終了）
  - GUIウィンドウ終了時（[×]ボタン等）のコンテナ自動停止連動
  - クイックアクセスリンク（`/mic`, `/`, `/dashboard`）
  - リアルタイムログ出力コンソール

### 4. 文字化けおよびバッチ構文エラーの是正
- **現象**: `start.bat` 実行時に `cmd.exe` でマルチバイト文字の解釈破綻による構文エラーが発生。
- **原因と対応**:
  1. **バッチファイル (`start.bat`, `start_debug.bat`)**:
     - 改行コードを **CRLF (`\r\n`)** に統一。
     - `if (...)` ブロックを `goto` ラベル構文に刷新。
     - バッチコンソールメッセージを ASCII 英数字に正規化。
  2. **PowerShell スクリプト (`scripts/launcher_gui.ps1`)**:
     - **UTF-8 with BOM (`EF BB BF`)** かつ CRLF で保存。
     - 先頭に `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` および `$OutputEncoding = [System.Text.Encoding]::UTF8` を追加。

### 5. 「起動ボタンを押すと落ちる」不具合解消とロギング実装
- `ThreadPool` によるスレッドアクセス違反を解消し、`[System.Diagnostics.Process]`（`wslc.exe run -d`）と UIスレッド上の `DispatcherTimer`（500ms周期）によるイベント駆動設計にリファクタリング。
- `logs/launcher.log` への詳細ファイルロギングを実装。

### 6. ハイブリッド実行・CLI非表示・リアルタイム複数言語翻訳
- **ハイブリッド実行**:
  - `start.bat` / `start_debug.bat` で `pwsh.exe`（PowerShell 7）が存在すれば最優先で使用し、存在しなければ標準の `powershell.exe`（5.1）に自動フォールバック。
  - GUIヘッダーに稼働中のランタイムバッジ（`PowerShell 7 (pwsh)` / `PowerShell 5.1`）を表示。
- **CLIウィンドウ非表示**:
  - `start.bat` を `-WindowStyle Hidden` でバックグラウンド起動後、即時 exit。
  - 黒い画面を一切出さずに起動できる `start.vbs` を追加。
- **リアルタイム複数言語翻訳**:
  - GUI上に複数選択可能な翻訳言語チェックボックス（英語/中国語/韓国語/スペイン語/フランス語/ドイツ語）を新設。
  - 選択された言語を `--translate en,zh,...` としてコンテナ引数に渡す処理を追加。
  - `scripts/download_models.py` に `--translators` オプションを追加し、`entrypoint.sh` で `--translate` 指定時の自動ダウンロード処理を実装。
  - ホスト側 `models/` に `mojicast-fugumt-ja-en-ct2` (FuguMT) と `mojicast-m2m100-ct2` (M2M-100) をダウンロード・永続化。
  - `scripts/subtitle_server.py` の OBSオーバーレイ字幕 (`OVERLAY_HTML`) を複数言語の改行同時表示に対応。
  - コンテナイメージ `hayamimi:latest` を再ビルド。

### 7. コンテナログ出力の強化 (`logs/container.log`) とGUIリアルタイム連携
- **コンテナログのリアルタイム同期 (`logs/container.log`)**:
  - コンテナ起動直後から1秒周期で `wslc logs` をポーリング取得し、`logs/container.log` へ常時同期出力。
  - 新着ログ行を検知し、ランチャーGUIのログコンソールにも `[コンテナ] loading models...` 等のプレフィックス付きでリアルタイム反映。
  - コンテナ起動前にも `logs/container.log` を初期生成（存在保証）。
  - コンテナ起動失敗時、サーバー待機中、稼働中、および終了時・ウィンドウクローズ時の全フェーズで確実にログを永続化。
- **GUI上でのワンクリックログ参照**:
  - ログコンソールヘッダーに `[📄 container.log]`、`[📄 launcher.log]`、`[📁 logsフォルダ]` ボタンを追加。クリックで直接ログファイルやフォルダを開けるように拡張。
- **PowerShell 5.1 / 7 文字コード対策の徹底**:
  - `scripts/launcher_gui.ps1` を UTF-8 with BOM (`EF BB BF`) で保存し、PS 5.1 環境下での日本語文字化け・バックスラッシュ構文誤認エラーを完全解消。構文解析テスト (`ParseFile`) で双方のパスを確認。

### 8. 中国語の地域別分離（台湾語・香港語・中国語）の実装
- **言語仕様の明確化**:
  - 既存の `zh` は Meta M2M-100 の中国本土標準・普通話（簡体字中国語: Simplified Chinese）。
  - 台湾（繁体字 / 台湾華語）および香港（繁体字 / 香港広東語表記）に対応するため、OpenCC（`opencc-python-reimplemented`）による高精度地域バリアント変換パイプラインを構築。
- **バックエンド実装 (`scripts/translate_m2m.py`, `requirements.txt`, `Dockerfile`)**:
  - `requirements.txt` に軽量かつ純Pythonの `opencc-python-reimplemented==0.1.7` を追加。
  - `scripts/translate_m2m.py`:
    - `CHINESE_VARIANTS` マッピングを新設（`zh-tw` / `tw` → `s2twp`: 台湾繁体字・慣用句、`zh-hk` / `hk` → `s2hk`: 香港繁体字、`zh-cn` / `cn` → 簡体字）。
    - M2M-100 の基底 `zh` 翻訳結果から各地域の標準文字体系および語彙（例: 软件→軟體、出租车→計程車）へリアルタイム変換。
    - コンテナイメージ `hayamimi:latest` を再ビルドし、単体変換テスト完了。
- **GUIランチャーの拡張 (`scripts/launcher_gui.ps1`)**:
  - 翻訳設定カードに「中国語・簡体字 (zh)」「台湾語・繁体字 (zh-tw)」「香港語・繁体字 (zh-hk)」の個別チェックボックスを配置し、複数選択・同時出力を可能に。

### 9. 配布用セットアップシステムの実装 (`setup.bat`, `setup.ps1`)
- **`setup.bat`**:
  - GitHub (`https://raw.githubusercontent.com/Maximilian2022/hayamimi/main/setup.ps1`) から `setup.ps1` を一時フォルダにダウンロードし、実行ポリシーをバイパスして即座に起動する軽量バッチ（ASCII英数字 + CRLF）。ローカルに `setup.ps1` が存在する場合はローカル版をフォールバック実行。
- **`setup.ps1`**:
  - WPFによるモダンダークテーマのインストーラーGUI。
  - 保存先ディレクトリ選択（既定値: `マイドキュメント\hayamimi`、`[📁 参照...]` ダイアログによる自由指定）。
  - GitHubから最新リポジトリZIP（`main.zip`）を自動ダウンロード・解凍・配置。Git未インストール環境でも100%動作。
  - デスクトップショートカット（`hayamimi (早耳).lnk` -> `start.vbs`）の自動作成機能（CLI画面非表示起動）。
  - WSL Containers (`wslc`) の要件自動事前検出。
  - インストール完了時のワンクリック起動ボタン（`▶ hayamimi を起動する`）を実装。
  - UTF-8 with BOM、PS 5.1 / 7 ハイブリッド両対応。

### 10. インストーラー (`setup.ps1`) の進行停止不具合の解消
- **原因**:
  - PowerShell のスクリプトブロック内で代入した `$step = 1` がローカルスコープ変数となり、親スコープの `$step` が更新されないため、`DispatcherTimer` 内のステートマシンが `0`（未マッチ）で停止していた。
  - WebClient のダウンロード時に `User-Agent` が未指定だったため、GitHub 側で制限される可能性があった。
- **対応**:
  - すべてのステートマシン変数を `$script:` スコープ修飾子（`$script:step` 等）に是正。
  - ローカルにリポジトリファイルが存在する場合は GitHub ダウンロードをスキップして高速コピーするローカル検出ロジックを導入。
  - WebClient に `User-Agent` ヘッダーを付与。
  - 各ステップの進行ログとプログレス表示をリアルタイムに更新するよう改善。
