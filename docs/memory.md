# 長期記憶・設計決定事項 (memory.md)

## プロジェクト概要
- hayamimi (早耳): CPUで動作するリアルタイム多言語音声認識・翻訳システム
- 提供インターフェース:
  - OBSオーバーレイ: `http://localhost:8833/`
  - Webマイク入力: `http://localhost:8833/mic`
  - ライブダッシュボード: `http://localhost:8833/dashboard`
  - WebSocket 音声受信: `ws://localhost:8766/ingest`

## システム要件とアーキテクチャ決定事項
1. **WSL3 / WSL Containers (WSLC) 実行基盤**:
   - ターゲット: WSLやDockerに不慣れな一般Windowsユーザー
   - Docker Desktop不要、Microsoft純正の「WSL Containers (`wslc.exe`)」を直接コンテナエンジンとして採用
   - コンテナイメージ名: `hayamimi:latest`
   - コンテナ名: `hayamimi_app`
   - ポートフォワーディング: `-p 8833:8833 -p 8766:8766`
   - ボリュームマウント: `-v "<ProjectRoot>\models:/app/models"` により、Coreモデルおよび翻訳モデルをホスト側に永続化し、次回以降の高速起動を実現

2. **ランタイムとエントリポイント (CLI完全非表示化方針)**:
   - **ハイブリッド自動選択**:
     - `start.bat` / `start_debug.bat`: `pwsh.exe` (PowerShell 7) を最優先で使用。存在しない場合は標準の `powershell.exe` (PowerShell 5.1) に自動フォールバック。
   - **Windows Terminal / CLIウィンドウ完全非表示 (3層防御)**:
     - `start.vbs`: `wscript.exe` 経由で PowerShell を直接 `WshShell.Run(cmd, 0, False)` で完全サイレント起動し、Windows Terminal のウィンドウ発生を未然に防止。
     - `start.bat`: `start.vbs` が存在すれば `wscript.exe` にリダイレクトしてバッチ自身を即座に exit。
     - `scripts/launcher_gui.ps1` & `setup.ps1`: 最先頭で Win32 API (`GetConsoleWindow` / `ShowWindow(hWnd, 0)` [SW_HIDE]) を呼び出し、自身のコンソールおよび親の Windows Terminal (wt.exe) ウィンドウを即時に非表示化。

3. **リアルタイム多言語同時翻訳 (Webマイク画面集約アーキテクチャ)**:
   - 設定UIの配置:
     - PowerShell ランチャー画面ではなく、Webのマイク入力画面（`http://localhost:8833/mic`）の「音声認識 & リアルタイム翻訳設定」カード内に複数言語同時選択UIを配置。
     - 8言語（英語 `en`, 中国語・簡体字 `zh`, 台湾語・繁体字 `zh-tw`, 香港語・繁体字 `zh-hk`, 韓国語 `ko`, スペイン語 `es`, フランス語 `fr`, ドイツ語 `de`）のピル型チェックボタングリッドを実装。
   - 動的リロードパイプライン:
     - バックエンドの `TranslatorPool` は `POST /config`（JSON `{ translate: [...] }`）による稼働中の動的モデル追加・削除に対応。
     - フロントエンドのチェックボックス操作時に即座に `POST /config` が非同期送信され、サーバー再起動なしでワンクリックで言語の追加・解除がリアルタイム反映される。
   - 翻訳エンジン:
     - 英語 (en): FuguMT CTranslate2 (`mojicast-fugumt-ja-en-ct2`)
     - 多言語 (zh/ko/es/fr/de等100言語): M2M-100 418M CTranslate2 (`mojicast-m2m100-ct2`)
     - 台湾繁体字 (`zh-tw`) / 香港繁体字 (`zh-hk`): M2M-100 の `zh` 出力を OpenCC (`s2twp` / `s2hk`) で台湾・香港の標準表記・慣用語に高精度変換。
   - 翻訳字幕出力:
     - ダッシュボード (`/dashboard`): 確定文ごとに複数言語の翻訳行が並列カード表示される。
     - OBSオーバーレイ (`/`): 複数言語の翻訳イベントが各言語タグ付きで改行同時表示される。

4. **二層ロギング仕様 (`logs/`)**:
   - プロジェクト直下に `logs/` フォルダを自動配置（`.gitignore` 済み）。
   - `logs/launcher.log`: ランチャーの動作ログ、コマンド実行結果、例外スタックトレース。
   - `logs/container.log`: WSL Containers 内部（ASRエンジン、モデルロード、VAD、WebSocket等）の標準出力・標準エラーログを常時同期保存。
   - ランチャーGUI上のログコンソールにもコンテナの新着ログ（`[コンテナ] ...`）をリアルタイム表示。
   - GUI上の「📄 container.log」「📄 launcher.log」「📁 logsフォルダ」ボタンからワンクリックで開くことが可能。

5. **ワンクリック配布・セットアップ仕様 (`setup.bat`, `setup.ps1`)**:
   - 初回導入者向けに、GitHub (`Maximilian2022/hayamimi`) からインストーラーを取得する `setup.bat` を提供。
   - `setup.ps1` はモダンWPF GUI。保存先（既定: `MyDocuments\hayamimi`）の選択、リポジトリZIPの自動ダウンロード＆展開、デスクトップショートカット（`start.vbs` リンク）作成、WSL Containers環境の自動診断を実行。

6. **WSL Containers (wslc) 環境非依存・自動セットアップ仕様**:
   - `Get-WslcCommand` によるインテリジェント探索:
     - `where.exe` だけでなく、`C:\Program Files\WSL\wslc.exe` や AppData 既知パスを走査。PATH 未登録環境でも自動認識。
   - 呼び出しの完全保護:
     - すべてのコマンド実行を `ProcessStartInfo` に絶対パスを指定して実行し、PowerShell の `CommandNotFoundException` を防止。
   - 未導入PC向け全自動セットアップ (`Invoke-InstallWslContainers`):
     - 未検出時はGUI上にアラートバナーと「📥 WSL3 を自動インストール」ボタンを常設し、起動時・インストール時・バッチ実行時の各エントリポイントで確認プロンプトを自動表示。
     - 4段階パイプライン（`wsl --install --no-distribution` → `wsl --update` → `wsl --update --pre-release` → GitHub MSI直接ダウンロード）により、環境を選ばず100% WSL3 を導入可能。
     - システム環境変数 PATH (`Machine`) への自動追記と、稼働中プロセスの `$env:Path` リロードにより、PC再起動前でも即座に認識・動作可能。
   - 初回イメージ全自動構築:
     - `hayamimi:latest` イメージが存在しない新規環境では、初回起動時に自動で `wslc build` をバックグラウンド実行。

