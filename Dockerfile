FROM python:3.14-slim

ENV PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive

WORKDIR /app

# 必要なOSパッケージをインストール
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    libsndfile1 \
    libportaudio2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Python依存パッケージのインストール
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# アプリケーションコードのコピー
COPY . .

# 起動スクリプトの実行権限を保証
RUN chmod +x /app/entrypoint.sh

# ポートの公開 (8833: HTTP/SSE/OBS, 8766: WebSocket Ingest)
EXPOSE 8833 8766

ENTRYPOINT ["/app/entrypoint.sh"]
