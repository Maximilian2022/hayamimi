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

2. **ランタイムとエントリポイント**:
   - **ハイブリッド自動選択**:
     - `start.bat` / `start_debug.bat`: `pwsh.exe` (PowerShell 7) を最優先で使用。存在しない場合は標準の `powershell.exe` (PowerShell 5.1) に自動フォールバック。
   - **CLIウィンドウ非表示**:
     - `start.bat`: `-WindowStyle Hidden` でバックグラウンド起動後、即時 exit。
     - `start.vbs`: VBScript Shellラッパーにより、黒いコマンドプロンプトを0秒表示（完全非表示）で起動可能。

3. **リアルタイム多言語同時翻訳**:
   - GUIランチャー上で英語 (en)、中国語 (zh)、韓国語 (ko)、スペイン語 (es)、フランス語 (fr)、ドイツ語 (de) などを複数選択可能。
   - 選択された言語群を `--translate en,zh,...` としてコンテナ引数に渡す。
   - 翻訳エンジン:
     - 英語 (en): FuguMT CTranslate2 (`mojicast-fugumt-ja-en-ct2`)
     - 多言語 (zh/ko/es/fr/de等100言語): M2M-100 418M CTranslate2 (`mojicast-m2m100-ct2`)
   - 翻訳字幕出力:
     - ダッシュボード (`/dashboard`): 確定文ごとに複数言語の翻訳行が並列カード表示される。
     - OBSオーバーレイ (`/`): 複数言語の翻訳イベントが改行されて同時表示されるよう更新。

4. **二層ロギング仕様 (`logs/`)**:
   - プロジェクト直下に `logs/` フォルダを自動配置（`.gitignore` 済み）。
   - `logs/launcher.log`: ランチャーの動作ログ、コマンド実行結果、例外スタックトレース。
   - `logs/container.log`: WSL Containers 内部（ASRエンジン、モデルロード、VAD、WebSocket等）の標準出力・標準エラーログを常時同期保存。
   - ランチャーGUI上のログコンソールにもコンテナの新着ログ（`[コンテナ] ...`）をリアルタイム表示。
   - GUI上の「📄 container.log」「📄 launcher.log」「📁 logsフォルダ」ボタンからワンクリックで開くことが可能。
