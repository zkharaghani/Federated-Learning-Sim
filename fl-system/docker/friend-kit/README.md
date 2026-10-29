# Federated learning: client 2

You run one client of a small federated learning test. Your computer trains a
model on its own data and sends only model parameters to the server, never the
data itself. You don't need to open any ports.

**You need:** Windows with WSL (Ubuntu), or any Linux; internet the first time;
and the same network as the server computer.

---

## 1. Open Ubuntu
- **Windows:** Start menu → **Ubuntu**. If you don't have it, open PowerShell
  as administrator, run `wsl --install -d Ubuntu`, restart Windows, open Ubuntu
  and choose a username and password.
- **Linux:** open a terminal.

Run all the following commands **in Ubuntu**, not in PowerShell.

## 2. Unzip the kit into your home folder
If the zip is in your Windows Downloads folder:
```bash
cd ~
sudo apt-get update && sudo apt-get install -y unzip
ls /mnt/c/Users/                      # shows your Windows user name
unzip /mnt/c/Users/<YOUR-WINDOWS-NAME>/Downloads/client2-kit.zip -d ~
cd ~/client2-kit
ls
```
You should see `ca.crt`, `client.env`, `run_client.sh`, `install_docker.sh` and others.

## 3. Install Docker (once)
```bash
bash install_docker.sh
```
It asks for your Ubuntu password and ends with **"Docker works."**
If you already use Docker Desktop for Windows instead: enable it for Ubuntu under
Settings → Resources → WSL Integration and skip this step.

## 4. Start the client (when the server owner says the server is running)
```bash
cd ~/client2-kit
bash run_client.sh
```
The first time, it builds the client (a few minutes, needs internet). Then it
connects to the server and shows the log. You'll see a line for each training round, like
`[client client2] round 5: one SGD step, loss=...`.

Ctrl+C only stops *watching* the log. The client keeps running.

## 5. Stop the client when the test is finished
```bash
bash stop_client.sh
```

---

## Optional: train on your own data file
Edit `client.env` (`nano client.env`) and set, for example:
```
DATA_FILE=/home/<you>/data/my_data.csv
```
`.csv` (numbers only, last column = target) or `.npz` (`X_train`, `y_train`).
The file is read-only inside the container and never leaves your computer.
Leave it empty for synthetic data.

## If something goes wrong
| Message | What to do |
|---|---|
| `Docker is not installed` | `bash install_docker.sh` |
| `Docker is not running` | `sudo service docker start`, then run again |
| `WARNING: cannot reach ...` | Server not started yet, or the network blocks it. Ask the server owner; try a phone hotspot for both computers |
| `Connection attempt failed` repeating in the log | Same as above |
| certificate / SSL error | Your `ca.crt` is out of date. Ask for a new kit |

Send the last 20 lines of the log to the server owner: `sudo docker logs --tail 20 fl-client2`
