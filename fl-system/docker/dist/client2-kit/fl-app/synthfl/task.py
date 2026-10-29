"""Model + data loading shared by the ServerApp and ClientApp.

Model: linear regression  y = X @ w + b   (pure NumPy)

Data source per client (chosen by the SuperNode's --node-config):
  * data-path="/data/mydata.npz"  -> arrays X_train, y_train [, X_test, y_test]
  * data-path="/data/mydata.csv"  -> numeric columns, LAST column = target
  * no data-path                   -> private synthetic dataset (seeded by partition-id)
Multi-dimensional X (e.g. time series of shape (n, 1, 19, 40)) is flattened.
Raw data never leaves the client; only parameters, losses and aggregate
statistics (sums used for global normalisation) are sent to the server.
"""

from __future__ import annotations

import csv
from pathlib import Path

import numpy as np

SYNTH_FEATURES = 5
TRUE_W = np.array([2.0, -3.0, 0.5, 1.5, -1.0], dtype=np.float64)
TRUE_B = 0.7


# ----------------------------------------------------------------- data
def _synthetic(partition_id: int, num_samples: int):
    rng = np.random.default_rng(1000 + partition_id)
    shift = 0.5 * partition_id  # client-specific covariate shift -> non-IID
    X = rng.normal(loc=shift, scale=1.0, size=(num_samples, SYNTH_FEATURES))
    y = X @ TRUE_W + TRUE_B + rng.normal(0.0, 0.1, size=num_samples)
    return X, y


def _load_csv(path: Path):
    with path.open(newline="") as f:
        rows = [r for r in csv.reader(f) if r]
    try:
        [float(v) for v in rows[0]]
    except ValueError:
        rows = rows[1:]  # header row
    a = np.asarray(rows, dtype=np.float64)
    return a[:, :-1], a[:, -1]


def _split(X, y, test_fraction=0.2, seed=0):
    idx = np.random.default_rng(seed).permutation(len(X))
    n_test = max(1, int(len(X) * test_fraction))
    te, tr = idx[:n_test], idx[n_test:]
    return X[tr], y[tr], X[te], y[te]


def load_data(node_config, run_config):
    """Return (X_train, y_train, X_test, y_test, source_description)."""
    pid = int(node_config.get("partition-id", 0))
    data_path = str(node_config.get("data-path", "") or "")
    if not data_path:
        X, y = _synthetic(pid, int(run_config["samples-per-client"]))
        return (*_split(X, y, seed=pid), f"synthetic(partition={pid})")

    path = Path(data_path)
    if not path.is_file():
        raise FileNotFoundError(f"data-path does not exist on this client: {path}")
    if path.suffix == ".npz":
        with np.load(path, allow_pickle=False) as z:  # never unpickle
            arrays = {k: z[k] for k in z.files}
        X, y = arrays["X_train"], arrays["y_train"]
        if "X_test" in arrays and "y_test" in arrays:
            Xtr, ytr, Xte, yte = X, y, arrays["X_test"], arrays["y_test"]
        else:
            Xtr, ytr, Xte, yte = _split(X, y)
    elif path.suffix == ".csv":
        Xtr, ytr, Xte, yte = _split(*_load_csv(path))
    else:
        raise ValueError(f"Unsupported data file type: {path.suffix} (use .npz or .csv)")

    def prep(X, y):
        return X.reshape(len(X), -1).astype(np.float64), y.reshape(-1).astype(np.float64)

    return (*prep(Xtr, ytr), *prep(Xte, yte), f"file({path.name})")


# ---------------------------------------------------- global normalisation
def local_stats(X, y) -> dict[str, np.ndarray]:
    """Sums only (no raw rows) -> server combines them into global mean/std."""
    return {
        "n": np.array([len(X)], dtype=np.float64),
        "x_sum": X.sum(0), "x_sq": (X**2).sum(0),
        "y_sum": np.array([y.sum()]), "y_sq": np.array([(y**2).sum()]),
    }


def combine_stats(all_stats: list[dict[str, np.ndarray]]) -> list[np.ndarray]:
    n = sum(s["n"][0] for s in all_stats)
    mean_x = sum(s["x_sum"] for s in all_stats) / n
    std_x = np.sqrt(np.maximum(sum(s["x_sq"] for s in all_stats) / n - mean_x**2, 0)) + 1e-8
    mean_y = sum(s["y_sum"] for s in all_stats) / n
    std_y = np.sqrt(np.maximum(sum(s["y_sq"] for s in all_stats) / n - mean_y**2, 0)) + 1e-8
    return [mean_x, std_x, mean_y, std_y]


def normalise(X, y, norm):
    mean_x, std_x, mean_y, std_y = norm
    return (X - mean_x) / std_x, (y - mean_y[0]) / std_y[0]


def to_original_units(params, norm):
    """Convert weights learned on normalised data back to y = X @ w + b."""
    mean_x, std_x, mean_y, std_y = norm
    w = params[0] * std_y[0] / std_x
    b = mean_y[0] + std_y[0] * params[1][0] - float(w @ mean_x)
    return w, b


# ------------------------------------------------------------------ model
def init_params(num_features: int, seed: int = 42) -> list[np.ndarray]:
    rng = np.random.default_rng(seed)
    return [rng.normal(0.0, 0.01, size=num_features), np.zeros(1)]


def sgd_step(params, X, y, lr: float, batch_size: int, rng):
    """Exactly ONE SGD step on one mini-batch. Returns (new_params, loss_before_step)."""
    w, b = params
    idx = rng.choice(len(X), size=min(batch_size, len(X)), replace=False)
    Xb, yb = X[idx], y[idx]
    err = Xb @ w + b[0] - yb
    loss = float(np.mean(err**2))
    grad_w = 2.0 * Xb.T @ err / len(Xb)
    grad_b = np.array([2.0 * err.mean()])
    return [w - lr * grad_w, b - lr * grad_b], loss


def evaluate(params, X, y, norm):
    """Sums the server needs for global MSE, RMSE and R² (original units).
    SST is taken around the *global* target mean so R² aggregates exactly."""
    Xn, yn = normalise(X, y, norm)
    w, b = params
    pred_n = Xn @ w + b[0]
    mse_n = float(np.mean((pred_n - yn) ** 2))
    pred = pred_n * norm[3][0] + norm[2][0]
    return {
        "mse": mse_n,
        "sse": float(np.sum((pred - y) ** 2)),
        "sst": float(np.sum((y - norm[2][0]) ** 2)),
        "num-examples": len(y),
    }
