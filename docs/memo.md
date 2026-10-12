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
  5. **中国語の地域別分離（台湾語・香港語・中国語）**:
     - 既存の `zh` は Meta M2M-100 の中国本土標準・普通話（簡体字中国語）。
     - `requirements.txt` に `opencc-python-reimplemented` を追加し、`translate_m2m.py` で台湾繁体字・慣用句（`zh-tw` / `s2twp`）および香港繁体字（`zh-hk` / `s2hk`）へのリアルタイム変換パイプラインを実装。
     - GUIランチャー上で「中国語・簡体字」「台湾語・繁体字」「香港語・繁体字」を独立選択・同時出力可能に。
  6. **ワンクリック配布用インストーラー (`setup.bat`, `setup.ps1`)**:
     - `setup.bat`: GitHub から最新の `setup.ps1` を取得・実行する軽量バッチ。
     - `setup.ps1`: WPF モダンGUIインストーラー。保存先選択（既定: マイドキュメント\hayamimi）、GitHub ZIP自動ダウンロード＆展開、デスクトップショートカット作成、WSL Containers環境チェック、完了後即時起動をサポート。
  7. **Webマイク画面へのリアルタイム複数言語翻訳UI移設 (`scripts/mic_page.html`)**:
     - ランチャー画面からWeb画面（`http://localhost:8833/mic`）へ移設。
     - 8言語（英語、中国語・簡体、台湾語・繁体、香港語・繁体、韓国語、スペイン語、フランス語、ドイツ語）の複数同時選択可能なピル型チェックボタングリッドを実装。
     - クリック時に自動で `POST /config` を即時非同期送信し、ワンクリックで翻訳先言語がリアルタイム反映されるように改修。
     - `wslc build -t hayamimi:latest .` でコンテナイメージ反映完了。
  8. **Windows Terminal (pwsh) の完全非表示・最小化**:
     - Windows 11 の既定ターミナルが Windows Terminal に設定されている場合の空ウィンドウ残留バグを解消。
     - `scripts/launcher_gui.ps1` / `setup.ps1`: 最先頭で Win32 API (`GetConsoleWindow` / `ShowWindow(hWnd, 0)`) により親ターミナルを自動非表示化。
     - `start.vbs`: `pwsh.exe` または `powershell.exe` を直接 `WshShell.Run(cmd, 0, False)` で完全サイレント起動。
     - `start.bat`: `start.vbs` が存在する場合は `wscript.exe` 経由で完全非表示起動しバッチを即終了。
