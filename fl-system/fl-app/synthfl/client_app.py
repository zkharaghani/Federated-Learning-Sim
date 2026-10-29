"""ClientApp: runs inside the SuperNode on each client.

Message types from the server:
  query    -> readiness: replies state=ready, data source, #features, and
              aggregate sums (no raw rows) for global normalisation
  train    -> receives global params, does ONE SGD step on local training data,
              replies updated params + loss + num_examples
  evaluate -> receives global params, scores them on the local test split
"""

import os
import socket

import numpy as np
from flwr.app import ArrayRecord, ConfigRecord, Context, Message, MetricRecord, RecordDict
from flwr.clientapp import ClientApp

from synthfl.task import evaluate, load_data, local_stats, normalise, sgd_step

app = ClientApp()
_CACHE: dict = {}


def _data(context: Context):
    key = (str(context.node_config.get("data-path", "")), context.node_config.get("partition-id", 0))
    if key not in _CACHE:  # avoid re-reading the file every round (process may be reused)
        _CACHE[key] = load_data(context.node_config, context.run_config)
    return _CACHE[key]


def _client_id(context: Context) -> str:
    return str(context.node_config.get("client-id", context.node_config.get("partition-id", "?")))


def _norm(msg: Message):
    return msg.content["norm"].to_numpy_ndarrays()


@app.query()
def ready(msg: Message, context: Context) -> Message:
    Xtr, ytr, Xte, _, source = _data(context)
    content = RecordDict(
        {
            "status": ConfigRecord(
                {"state": "ready", "client-id": _client_id(context),
                 "host": socket.gethostname(), "source": source}
            ),
            "info": MetricRecord(
                {"num-examples": len(Xtr), "num-test": len(Xte), "num-features": Xtr.shape[1]}
            ),
            "stats": ArrayRecord(list(local_stats(Xtr, ytr).values())),
        }
    )
    return Message(content=content, reply_to=msg)


@app.train()
def train(msg: Message, context: Context) -> Message:
    cfg = msg.content["config"]
    rnd = int(cfg["server-round"])
    Xtr, ytr, _, _, _ = _data(context)
    Xn, yn = normalise(Xtr, ytr, _norm(msg))

    seed = 10_000 * int(context.node_config.get("partition-id", 0)) + rnd
    new_params, loss = sgd_step(
        msg.content["arrays"].to_numpy_ndarrays(), Xn, yn,
        lr=float(cfg["lr"]), batch_size=int(cfg["batch-size"]),
        rng=np.random.default_rng(seed),
    )
    print(f"[client {_client_id(context)}] round {rnd}: one SGD step, loss={loss:.4f}")
    content = RecordDict(
        {
            "arrays": ArrayRecord(new_params),
            "metrics": MetricRecord(
                {"loss": loss, "num-examples": len(Xtr)}
            ),
            "id": ConfigRecord({"client-id": _client_id(context)}),
        }
    )
    return Message(content=content, reply_to=msg)


@app.evaluate()
def evaluate_fn(msg: Message, context: Context) -> Message:
    _, _, Xte, yte, _ = _data(context)
    m = evaluate(msg.content["arrays"].to_numpy_ndarrays(), Xte, yte, _norm(msg))
    content = RecordDict(
        {"metrics": MetricRecord(m), "id": ConfigRecord({"client-id": _client_id(context)})}
    )
    return Message(content=content, reply_to=msg)


@app.query("finish")
def finish(msg: Message, context: Context) -> Message:
    """Server says training is over. Leave a marker file; the container's
    entrypoint sees it and stops the client (when EXIT_AFTER_RUN=true)."""
    marker = os.environ.get("FL_DONE_FILE", f"/tmp/fl-done-{_client_id(context)}")
    with open(marker, "w") as f:
        f.write("finished\n")
    print(f"[client {_client_id(context)}] server says training is finished")
    return Message(content=RecordDict(), reply_to=msg)
