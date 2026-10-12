#!/usr/bin/env bash
set -e

echo "=== hayamimi (早耳) 起動準備中 ==="

# モデルディレクトリの確認
MODELS_DIR="/app/models"
if [ ! -d "$MODELS_DIR" ] || [ -z "$(ls -A "$MODELS_DIR" 2>/dev/null)" ]; then
    echo "モデルファイルが見つかりません。初回セットアップとして core モデル (--minimal) をダウンロードします..."
    python scripts/download_models.py --minimal
    echo "モデルのダウンロードが完了しました。"
else
    echo "既存のモデルディレクトリを確認しました: $MODELS_DIR"
fi

echo "=== hayamimi サーバーを起動します ==="
echo "  OBS オーバーレイ:      http://0.0.0.0:8833/"
echo "  Webマイク入力画面:    http://0.0.0.0:8833/mic (HTTPS経由推奨: https://<HOST>:8843/mic)"
echo "  ダッシュボード:        http://0.0.0.0:8833/dashboard"
echo "  WebSocket 音声入力:    ws://0.0.0.0:8766/ingest"

exec python scripts/realtime_transcribe.py --input ws --serve 8833 --ws-host 0.0.0.0 --ws-port 8766 "$@"
