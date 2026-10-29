# Self-contained FL SERVER image: Flower SuperLink + the ServerApp code.
# Build from the repository root:  docker build -f docker/server/Dockerfile -t fl-server:1.0 .
FROM python:3.12-slim
ARG FLWR_VERSION=1.40.0
RUN pip install --no-cache-dir "flwr==${FLWR_VERSION}" "numpy>=1.26,<3" \
 && useradd --create-home --uid 1000 app
COPY --chown=app fl-app /app
COPY --chown=app docker/server/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /results && chown app /results
# No USER line on purpose: the entrypoint starts as root only to fix ownership of
# the mounted /results folder, then drops to the unprivileged user "app" (uid 1000).
# Running with `--user 1000` also works if the results folder is already writable.
WORKDIR /home/app
ENV PYTHONUNBUFFERED=1 \
    SUPERLINK_PORT=9092 \
    NUM_ROUNDS=30 \
    NUM_CLIENTS=2 \
    RUN_CONFIG="" \
    KEEP_RUNNING=false
EXPOSE 9092
VOLUME ["/certs", "/results"]
ENTRYPOINT ["/entrypoint.sh"]
