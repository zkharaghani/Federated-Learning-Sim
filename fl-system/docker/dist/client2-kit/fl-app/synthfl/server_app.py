"""ServerApp: runs on the server (inside the SuperLink).

Protocol:
  0. Wait until the expected number of clients (SuperNodes) are connected.
  1. `query` every client -> each must answer state=ready. Clients also send
     #features and aggregate sums, from which the server builds the GLOBAL
     mean/std used by everyone for normalisation (no raw data is shared).
  2. For each round:
       a. send current global params to every client (`train`)
       b. each client does ONE SGD step and returns updated params + loss
       c. server computes the weighted average (FedAvg) of params and loss
       d. every `eval-every` rounds: `evaluate` on each client's local test split
"""

import json
import sys
import time

import numpy as np
from flwr.app import ArrayRecord, ConfigRecord, Context, Message, RecordDict
from flwr.serverapp import Grid, ServerApp

from synthfl.task import SYNTH_FEATURES, TRUE_B, TRUE_W, combine_stats, init_params, to_original_units

app = ServerApp()
# print each line immediately (stdout is a pipe -> would otherwise be buffered to the end)
sys.stdout.reconfigure(line_buffering=True)
STAT_KEYS = ["n", "x_sum", "x_sq", "y_sum", "y_sq"]


def wait_for_clients(grid: Grid, n: int, timeout: float) -> list[int]:
    start = time.time()
    while True:
        node_ids = list(grid.get_node_ids())
        if len(node_ids) >= n:
            return node_ids[:n]
        if time.time() - start > timeout:
            raise RuntimeError(f"Only {len(node_ids)}/{n} clients connected after {timeout}s")
        print(f"[server] waiting for clients: {len(node_ids)}/{n} connected ...")
        time.sleep(2)


def send(grid: Grid, node_ids, message_type: str, content: RecordDict, group: str):
    msgs = [Message(content=content, dst_node_id=nid, message_type=message_type, group_id=group)
            for nid in node_ids]
    replies = list(grid.send_and_receive(msgs, timeout=300))
    bad = [r for r in replies if r.has_error()]
    if bad or len(replies) < len(node_ids):
        errs = "; ".join(f"node {r.metadata.src_node_id}: {r.error.reason}" for r in bad)
        raise RuntimeError(f"{message_type}/{group}: {len(replies) - len(bad)}/{len(node_ids)} ok. {errs}")
    return replies


def check_ready(grid: Grid, node_ids):
    replies = send(grid, node_ids, "query", RecordDict(), "ready")
    feats = set()
    for r in replies:
        st, info = r.content["status"], r.content["info"]
        feats.add(int(info["num-features"]))
        print(f"[server] client {st['client-id']} (node {r.metadata.src_node_id}, host {st['host']}): "
              f"{st['state']}  data={st['source']}  train={int(info['num-examples'])} "
              f"test={int(info['num-test'])} features={int(info['num-features'])}")
    if any(r.content["status"]["state"] != "ready" for r in replies):
        raise RuntimeError("not all clients reported ready")
    if len(feats) != 1:
        raise RuntimeError(f"clients disagree on number of features: {feats}")
    stats = [dict(zip(STAT_KEYS, r.content["stats"].to_numpy_ndarrays())) for r in replies]
    print(f"[server] all {len(replies)} clients are READY")
    return feats.pop(), combine_stats(stats)


def fedavg(replies):
    weights = np.array([r.content["metrics"]["num-examples"] for r in replies], dtype=float)
    weights /= weights.sum()
    params = [r.content["arrays"].to_numpy_ndarrays() for r in replies]
    avg = [sum(w * p[i] for w, p in zip(weights, params)) for i in range(len(params[0]))]
    loss = float(sum(w * r.content["metrics"]["loss"] for w, r in zip(weights, replies)))
    return avg, loss


def run_eval(grid, node_ids, params, norm, rnd):
    content = RecordDict({"arrays": ArrayRecord(params), "norm": ArrayRecord(norm)})
    replies = send(grid, node_ids, "evaluate", content, f"eval-{rnd}")
    n = sum(r.content["metrics"]["num-examples"] for r in replies)
    sse = sum(r.content["metrics"]["sse"] for r in replies)
    sst = sum(r.content["metrics"]["sst"] for r in replies)
    return {"rmse": float(np.sqrt(sse / n)), "r2": 1.0 - sse / max(sst, 1e-12)}


def tell_clients_finished(grid: Grid, node_ids) -> None:
    """Final message: clients that run with EXIT_AFTER_RUN=true shut down after replying."""
    msgs = [Message(content=RecordDict(), dst_node_id=nid, message_type="query.finish", group_id="finish")
            for nid in node_ids]
    try:
        replies = list(grid.send_and_receive(msgs, timeout=60))
        ok = sum(not r.has_error() for r in replies)
        print(f"[server] told {ok}/{len(node_ids)} clients that training is finished")
    except Exception as e:  # never fail a finished run because of this
        print(f"[server] could not notify clients: {e}")


@app.main()
def main(grid: Grid, context: Context) -> None:
    cfg = context.run_config
    num_rounds, n_clients = int(cfg["num-rounds"]), int(cfg["num-clients"])
    eval_every = int(cfg["eval-every"])

    node_ids = wait_for_clients(grid, n_clients, timeout=float(cfg["wait-timeout"]))
    num_features, norm = check_ready(grid, node_ids)

    params = init_params(num_features)
    lr = float(cfg["lr"])
    if bool(cfg["lr-auto"]):
        # Largest curvature of a normalised mini-batch MSE is about (1+sqrt(d/B))^2,
        # so scale the step to stay stable for any number of features d.
        bsz = int(cfg["batch-size"])
        lr = lr / (1.0 + np.sqrt(num_features / bsz)) ** 2
    print(f"[server] features={num_features}  learning rate used={lr:.5f}")
    history = []
    for rnd in range(1, num_rounds + 1):
        content = RecordDict(
            {
                "arrays": ArrayRecord(params),
                "norm": ArrayRecord(norm),
                "config": ConfigRecord(
                    {"server-round": rnd, "lr": lr, "batch-size": int(cfg["batch-size"])}
                ),
            }
        )
        replies = send(grid, node_ids, "train", content, str(rnd))
        per_client = dict(sorted(
            (r.content["id"]["client-id"], round(r.content["metrics"]["loss"], 4)) for r in replies
        ))
        params, avg_loss = fedavg(replies)
        entry = {"round": rnd, "train_loss": avg_loss, "client_loss": per_client}
        line = f"[server] round {rnd:>3}: client losses={per_client}  averaged loss={avg_loss:.4f}"
        if rnd % eval_every == 0 or rnd == num_rounds:
            ev = run_eval(grid, node_ids, params, norm, rnd)
            entry.update(ev)
            line += f"  | test RMSE={ev['rmse']:.4f} R²={ev['r2']:.3f}"
        history.append(entry)
        print(line)

    print("[server] training finished")
    w, b = to_original_units(params, norm)
    if num_features == SYNTH_FEATURES:
        print(f"[server] final w = {np.round(w, 3).tolist()}  (synthetic truth {TRUE_W.tolist()})")
        print(f"[server] final b = {round(b, 3)}  (synthetic truth {TRUE_B})")
    print("[server] HISTORY_JSON " + json.dumps(history))
    tell_clients_finished(grid, node_ids)
