#!/usr/bin/env bash
set -e

# 異常終了時のトラップハンドラ (原因究明用)
trap 'rc=$?; if [ $rc -ne 0 ]; then echo "[entrypoint ERROR] コンテナ内プロセスが異常終了しました (ExitCode: $rc)" >&2; fi' EXIT

echo "=== hayamimi (早耳) 起動準備中 ==="
echo "[entrypoint] 引数: $*"

# モデルディレクトリの確認とダウンロード判定
MODELS_DIR="/app/models"
NEED_CORE=0
NEED_TRANSLATE=0

if [ ! -d "$MODELS_DIR" ] || [ -z "$(ls -A "$MODELS_DIR" 2>/dev/null)" ] || [ ! -d "$MODELS_DIR/sherpa-onnx-zipformer-ja-en-reazonspeech-2025-01-17" ]; then
    NEED_CORE=1
fi

if [[ "$*" == *"--translate"* ]]; then
    if [ ! -d "$MODELS_DIR/mojicast-fugumt-ja-en-ct2" ] || [ ! -d "$MODELS_DIR/mojicast-m2m100-ct2" ]; then
        NEED_TRANSLATE=1
    fi
fi

if [ $NEED_CORE -eq 1 ] || [ $NEED_TRANSLATE -eq 1 ]; then
    if [ $NEED_TRANSLATE -eq 1 ] || [[ "$*" == *"--translate"* ]]; then
        echo "初回セットアップ: Coreモデル + 翻訳モデル (計約1.7GB) をダウンロードしています..."
        python scripts/download_models.py --minimal --translators
    else
        echo "初回セットアップ: Coreモデル (約1.1GB) をダウンロードしています..."
        python scripts/download_models.py --minimal
    fi
    echo "モデルファイルの準備が完了しました。"
else
    echo "既存のモデルディレクトリを確認しました: $MODELS_DIR"
    echo "[entrypoint] 検出されたモデル一覧: $(ls -1 "$MODELS_DIR" 2>/dev/null | tr '\n' ' ')"
fi

echo "=== hayamimi サーバーを起動します ==="
echo "  OBS オーバーレイ:      http://0.0.0.0:8833/"
echo "  Webマイク入力画面:    http://0.0.0.0:8833/mic (HTTPS経由推奨: https://<HOST>:8843/mic)"
echo "  ダッシュボード:        http://0.0.0.0:8833/dashboard"
echo "  WebSocket 音声入力:    ws://0.0.0.0:8766/ingest"

echo "[entrypoint] realtime_transcribe.py を起動中..."
exec python scripts/realtime_transcribe.py --input ws --serve 8833 --ws-host 0.0.0.0 --ws-port 8766 "$@"
