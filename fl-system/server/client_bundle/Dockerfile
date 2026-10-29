# Image for a Flower SuperNode (the FL client runtime).
# The ClientApp code itself is shipped by the server at run time (FAB);
# this image only needs Flower + the app's dependencies.
ARG FLWR_VERSION=1.40.0
FROM python:3.12-slim
ARG FLWR_VERSION
RUN pip install --no-cache-dir "flwr==${FLWR_VERSION}" "numpy>=1.26" \
 && useradd --create-home --uid 1000 app
USER app
WORKDIR /home/app
ENTRYPOINT ["flower-supernode"]
