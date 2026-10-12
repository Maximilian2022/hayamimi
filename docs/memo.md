# 作業メモ (memo.md)

## 現在のステータス
- リポジトリのクローン完了: `https://github.com/Maximilian2022/hayamimi`
- WSL 3.0 / WSL Containers CLI (`wslc.exe`) でのコンテナ化・動作検証完了
- 不具合解消・改善項目:
  1. **ハイブリッド実行ランタイム**:
     - `start.bat` / `start_debug.bat`: `pwsh.exe` (PowerShell 7) があれば優先使用、なければ標準の `powershell.exe` (PowerShell 5.1) に自動フォールバック。
     - GUI上のバッジで現在動作中のランタイムを表示。
  2. **CLI非表示・最小化**:
     - `start.bat`: `-WindowStyle Hidden` でバックグラウンド起動し即時 exit。
     - `start.vbs`: 黒い画面を全く表示させずに完全非表示起動できるランチャーを追加。
  3. **リアルタイム複数言語翻訳**:
     - GUI上に「🌐 リアルタイム翻訳」カードを追加（en, zh, ko, es, fr, de 等をチェックボックスで複数選択可能）。
     - 選択された言語を `--translate en,zh,...` としてコンテナ引数に渡す。
     - `entrypoint.sh` および `download_models.py` に `--translators`（FuguMT & M2M-100: 計約600MB）の自動ダウンロード・検証処理を実装。
     - ホスト側 `models/` ディレクトリに `mojicast-fugumt-ja-en-ct2` および `mojicast-m2m100-ct2` をダウンロード・永続化完了。
     - `subtitle_server.py` の OBS字幕オーバーレイ (`/`) を複数言語翻訳の改行同時表示に対応。
  4. **コンテナログのファイル出力 (`logs/container.log`)**:
     - ランチャーがヘルスチェック中・稼働中・終了時に `wslc logs` を取得し、`logs/container.log` に自動同期保存。
     - GUI上のログコンソールにもコンテナの新着ログ（`[コンテナ] ...`）をリアルタイム表示。
     - GUI上から直接 `container.log`、`launcher.log`、`logs` フォルダを開くワンクリックボタンを追加。
     - `logs/launcher.log` (ランチャー操作ログ) と `logs/container.log` (ASRエンジンログ) の2層ロギング体制が完成。
