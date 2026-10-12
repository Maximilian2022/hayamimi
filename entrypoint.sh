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

# 引数に --translate が指定されている場合、翻訳モデルの存在確認・自動ダウンロード
if [[ "$*" == *"--translate"* ]]; then
    if [ ! -d "$MODELS_DIR/mojicast-fugumt-ja-en-ct2" ] || [ ! -d "$MODELS_DIR/mojicast-m2m100-ct2" ]; then
        echo "翻訳モデルが見つかりません。ダウンロードしています (FuguMT & M2M-100: 約600MB)..."
        python scripts/download_models.py --minimal --translators
        echo "翻訳モデルのダウンロードが完了しました。"
    else
        echo "既存の翻訳モデルを確認しました。"
    fi
fi

echo "=== hayamimi サーバーを起動します ==="
echo "  OBS オーバーレイ:      http://0.0.0.0:8833/"
echo "  Webマイク入力画面:    http://0.0.0.0:8833/mic (HTTPS経由推奨: https://<HOST>:8843/mic)"
echo "  ダッシュボード:        http://0.0.0.0:8833/dashboard"
echo "  WebSocket 音声入力:    ws://0.0.0.0:8766/ingest"

exec python scripts/realtime_transcribe.py --input ws --serve 8833 --ws-host 0.0.0.0 --ws-port 8766 "$@"
