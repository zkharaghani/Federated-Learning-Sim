# Self-contained FL CLIENT image: Flower SuperNode + the ClientApp code and deps.
# Build from the repository root:  docker build -f docker/client/Dockerfile -t fl-client:1.0 .
FROM python:3.12-slim
ARG FLWR_VERSION=1.40.0
RUN pip install --no-cache-dir "flwr==${FLWR_VERSION}" "numpy>=1.26,<3" \
 && useradd --create-home --uid 1000 app
# App code is baked in for auditing; Flower also verifies/receives the same
# app bundle (FAB) from the server when a run starts.
COPY --chown=app fl-app /app
COPY --chown=app docker/client/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER app
WORKDIR /home/app
ENV PYTHONUNBUFFERED=1 \
    SUPERLINK_ADDRESS="" \
    CLIENT_ID="client1" \
    PARTITION_ID=0 \
    NUM_PARTITIONS=2 \
    DATA_PATH=""
VOLUME ["/certs", "/data"]
ENTRYPOINT ["/entrypoint.sh"]
