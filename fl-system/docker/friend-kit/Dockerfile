# FL client 2: Flower SuperNode + the ClientApp code.
# Built automatically by run_client.sh (needs internet the first time only).
FROM python:3.12-slim
ARG FLWR_VERSION=1.40.0
RUN pip install --no-cache-dir "flwr==${FLWR_VERSION}" "numpy>=1.26,<3" \
 && useradd --create-home --uid 1000 app
COPY --chown=app fl-app /app
COPY --chown=app entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER app
WORKDIR /home/app
ENV PYTHONUNBUFFERED=1 SUPERLINK_ADDRESS="" CLIENT_ID="client2" PARTITION_ID=1 NUM_PARTITIONS=2 DATA_PATH=""
ENTRYPOINT ["/entrypoint.sh"]
