# 全Forkリポジトリ更新調査レポート

親リポジトリ（[oboroge0/hayamimi](https://github.com/oboroge0/hayamimi)）からフォークされた全32リポジトリを調査した結果のまとめです。  
全32件中、**17リポジトリ**に親リポジトリにない独自コミット（機能追加・バグ修正・UI開発等）が存在していました。

---

## 1. 取り込み価値の高い注目機能・修正（おすすめピックアップ）

### 【Sランク：今すぐ取り込むべき重要修正・新機能】

#### 1. WASAPIループバックバッファ拡大による音切れ修正
- **フォーク元**: [t-eimizu/hayamimi](https://github.com/t-eimizu/hayamimi) (`fix/loopback-capture-buffer`)
- **コミット**: `23801c5` (`input: widen the WASAPI loopback capture buffer to 2s`)
- **内容**: 
  - `--input speaker` や `--input mix` の使用時、ASRや話者分離処理がGILを保持している間に `SoundcardRuntimeWarning: data discontinuity in recording` が発生し、音声がドロップ（音切れ・文字起こしの取りこぼし）していた問題を修正。
  - バッファサイズを `WINDOW_SIZE * 4` (128ms) から `SAMPLE_RATE * 2` (2秒) に拡大（共有モードのため遅延は増加せず、バッファ耐性のみ向上）。
- **取り込み価値**: **極めて高い（バグ修正）**。数行の修正ですぐに安定性が劇的に向上します。

#### 2. 特定Windowsアプリの音声キャプチャ機能 (`--input app`)
- **フォーク元**: [nathan60107/hayamimi](https://github.com/nathan60107/hayamimi) (`main`)
- **コミット**: `76cfc5d` (`feat: added an app option to the input parameter to capture audio from a specific Windows app.`)
- **追加ファイル**: `scripts/windows_audio.py`
- **内容**:
  - Windowsの「Application Loopback Capture」APIを使用し、スピーカー全体ではなく **「特定のアプリケーション（例: Discord、Zoom、特定のブラウザタブ等）」の音声だけをピンポイントでキャプチャ** して文字起こし可能にする機能。
  - 起動時にアクティブな音声セッションを持つプロセス一覧（PID・アプリ名）を表示し、番号で選択可能。
- **取り込み価値**: **非常に高い**。ゲーム音や通知音、BGMを拾わず、通話相手の声だけを完璧に書き起こせます。

---

### 【Aランク：実用性・利便性が大幅に向上する機能】

#### 3. Chrome拡張機能（サイドパネル字幕表示）
- **フォーク元**: [goyle0/hayamimi](https://github.com/goyle0/hayamimi) (`main`, `feature/chrome-extension`)
- **コミット**: `d265698` (`Add Chrome extension that shows captions in the side panel`)
- **追加ディレクトリ**: `chrome_extension/`
- **内容**:
  - `realtime_transcribe.py --serve` のSSE字幕ストリーム（`http://127.0.0.1:8833/events`）を受信し、Google Chromeのサイドパネルにリアルタイム字幕（確定テキスト、進行中テキスト、整形テキスト）を表示する拡張機能。
  - Web会議や動画視聴中にブラウザ内で字幕をすっきり確認できます。
- **取り込み価値**: **高い**。スタンドアロンな拡張機能ディレクトリのため、既存コードを壊さず安全に追加可能。

#### 4. 言語切り替えガードの誤判定防止修正 (`--lang-switch-guard`)
- **フォーク元**: [wheesnoza/hayamimi](https://github.com/wheesnoza/hayamimi) (`agent/bugfix/lid-guard-hotwords`)
- **コミット**: `7b8fceb` (`Fix --lang-switch-guard: short detections no longer confirm a switch`)
- **内容**:
  - 日本語の音声認識中に、短い効果音やノイズ等で誤って中国語や英語と判定された際、ガード秒数未満の短い検出が言語切り替えカウンタを進めてしまい、勝手に言語が変わってしまうバグを修正。
  - 合わせて `--lid-switch-confirm` オプションをCLIに公開。
- **取り込み価値**: **高い（安定性向上）**。特に日本語メインの環境で意図しない言語切り替えを防げます。

#### 5. 英語認識モデル Tier v2（Parakeet TDT）のデフォルト化
- **フォーク元**: [hirochimi/hayamimi-study](https://github.com/hirochimi/hayamimi-study) / [t-eimizu/hayamimi](https://github.com/t-eimizu/hayamimi) (`agent/feature/en-v2-default`)
- **コミット**: `f87d7f8` (`asr: default en tier to v2, prioritize it in preload`)
- **内容**:
  - 英語モデルを旧来の `v3`（多言語モデル）から認識精度の高い専用モデル `v2`（Parakeet TDT）へデフォルト変更。
  - プリロード順序の最適化やダウンロードスクリプトの対応。
- **取り込み価値**: **高い**。英語混じりの会話や英語音声の認識精度が向上します。

#### 6. デスクトップ透過オーバーレイ字幕ウィンドウ（Electron）＆ 翻訳ホット切替
- **フォーク元**: [ConstantinopleMayor/hayamimi](https://github.com/ConstantinopleMayor/hayamimi) (`main`)
- **コミット**: `66ff285` (`Add desktop subtitle window app; hot-switch translation at runtime`)
- **追加ディレクトリ**: `desktop-subtitle/`
- **内容**:
  - 常に最前面に表示される透明なオーバーレイ字幕ウィンドウ（ドラッグ移動、クリックスルー、ウィンドウサイズ自動調整）。
  - 実行中に翻訳言語を動的変更できる `POST /api/translate` エンドポイントおよび標準入力コマンドの追加。
- **取り込み価値**: **中〜高**。OBSやデスクトップ画面上に直接字幕を出したい場合に便利。

---

## 2. その他のユニークな拡張・実験的プロジェクト

| リポジトリ | ブランチ | 主な内容 | 特徴・備考 |
| :--- | :--- | :--- | :--- |
| **`masatohirano/hayamimi`** | `main` 他 | 会議字幕ダッシュボード & バッファUI | スクロール可能な確定バッファUI、最新発言を上にする履歴表示、ワンクリック起動バッチなど |
| **`slord399/hayamimi`** | `main` | GUIコントロールパネル (`gui.py`) | PyInstaller対応のデスクトップGUI画面、多言語（日英）対応 |
| **`hirochimi`, `t-eimizu`, `MBK-fr`** | `agent/feature/stackchan-firmware` | ｽﾀｯｸﾁｬﾝ (M5Stack CoreS3) 連携 | M5Stack CoreS3上で動くファームウェア。HayamimiのWebSocket `/ingest` にマイク音声をストリーミング |
| **`MBK-fr/hayamimi`** | `agent/feature/v0.5.0-prep` | 4クラス句読点モデル (`--punct-model 4class`) | 重いBERT句読点モデルに代わる軽量な4クラス句読点モデルの追加 |
| **`k-hazumi/hayamimi`** | `feat/en-ja-realtime-translation` | ローカル日英・英日リアルタイム翻訳 | ローカルモデルによるリアルタイム翻訳機能 |
| **`k-hazumi/hayamimi`** | `agent/feature/mobile-app` | Flutter製モバイルアプリ | INT8量子化モデルとFlutterによるモバイル文字起こしアプリ |
| **`foreversaga/hayamimi`** | `feature/realtime-translation-v2` | Docker化 Hy-MT2 リアルタイム翻訳 | 不変字幕スパン保護、Dockerコンテナ化 |
| **`fukugan-ai/hayamimi`** | `main` / `feat/long-buffer` | Rustによるネイティブ実装（約900コミット） | `hayamimi-relay` としてRustでフルスクラッチ再実装・高速化している大規模プロジェクト |

---

## 3. 全17変更リポジトリ一覧

1. **`hirochimi/hayamimi-study`**: 英語v2モデルデフォルト化、ｽﾀｯｸﾁｬﾝ連携ファームウェア
2. **`t-eimizu/hayamimi`**: WASAPIループバックバッファ2秒拡大、英語v2デフォルト化、ｽﾀｯｸﾁｬﾝ連携
3. **`goyle0/hayamimi`**: Chromeサイドパネル字幕拡張機能
4. **`fukugan-ai/hayamimi`**: Rustネイティブ化プロジェクト（大規模）
5. **`slord399/hayamimi`**: GUIコントロールパネル (`gui.py`)
6. **`MBK-fr/hayamimi`**: 4クラス句読点モデル、ｽﾀｯｸﾁｬﾝ連携
7. **`nathan60107/hayamimi`**: Windows特定アプリ音声キャプチャ (`scripts/windows_audio.py`)
8. **`bingyo/hayamimi`**: VAD更新タイミング修正、WASAPIループバック初期実装
9. **`mii443/hayamimi`**: マルチプレックス・マルチスピーカーインジェスト
10. **`aki0912/kotomimi`**: 日本語ASR評価メトリクス・ベンチマーク整備
11. **`ConstantinopleMayor/hayamimi`**: デスクトップ透過字幕ウィンドウ、ランタイム翻訳切替
12. **`masatohirano/hayamimi`**: 会議字幕バッファUI、ワンクリック起動バッチ
13. **`k-hazumi/hayamimi`**: Flutterモバイルアプリ、ローカルリアルタイム翻訳
14. **`wheesnoza/hayamimi`**: 言語切り替えガードバグ修正、WebSocket音声インジェスト、スペイン語翻訳
15. **`zhuyansen/hayamimi`**: 言語切り替えガード修正、WebSocket音声インジェスト
16. **`mitsukoo/hayamimi`**: Android PoC
17. **`foreversaga/hayamimi`**: Docker化 Hy-MT2 翻訳
