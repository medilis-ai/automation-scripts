# Connecting to a GCP server from Windows

**Who this is for:** anyone on the team connecting to the hailth.ai GCP
servers from a **Windows laptop/PC** who'd rather use a script than
install and configure IAP Desktop.

**Why you might want this instead of IAP Desktop:** IAP Desktop works
fine on Windows and is still a perfectly good option — this is simply an
alternative that automates the same underlying mechanism (an IAP
tunnel) from the command line, if you prefer that or IAP Desktop isn't
set up on your machine yet.

> **Shortcut:** `scripts/connect-windows.ps1` in this repo walks through
> all of this for you — checks/installs `gcloud`, logs you in, lists the
> servers, lets you pick one with the arrow keys, checks you're actually
> allowed to see its password, opens the tunnel, and launches Remote
> Desktop Connection with the server address and username already filled
> in (you just paste the password, already copied to your clipboard).
> Run it with:
> ```powershell
> .\scripts\connect-windows.ps1
> ```
> If PowerShell blocks it from running (script execution policy), either
> right-click the file and choose **Run with PowerShell**, or run it once
> with:
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\scripts\connect-windows.ps1
> ```
> Everything below explains what it's doing, and is also the manual
> fallback if the script doesn't work for some reason.

---

## How this works, in one sentence

`gcloud` opens a private, authenticated tunnel from your PC straight to
the server (this is **IAP** — Identity-Aware Proxy, the same thing IAP
Desktop uses internally) — then Windows' own built-in Remote Desktop
Connection (`mstsc.exe`) connects through that tunnel exactly like a
normal remote-desktop connection.

---

## One-time setup

### 1. Install the Google Cloud CLI (`gcloud`)

If you don't already have it, and you have `winget` (built into Windows
10/11):

```powershell
winget install --id Google.CloudSDK -e
```

Don't have `winget`? Use Google's installer instead:
https://cloud.google.com/sdk/docs/install-sdk#windows

### 2. Sign in

```powershell
gcloud auth login
```

This opens a browser window — sign in with your **medilis.com /
radsforvets.com Google account**, the same one that was given access to
GCP.

### 3. Set the default project

So you don't have to type `--project` every time:

```powershell
gcloud config set project hailth-radiology
```

> That's it for one-time setup. Remote Desktop Connection (`mstsc.exe`)
> is already built into Windows — nothing to install for that part.

---

## Every time you want to connect

### Step 1 — Check which servers are actually on

Not every server runs all the time. Before trying to connect, check its
status:

```powershell
gcloud compute instances list --project=hailth-radiology
```

You'll get a table like this:

```
NAME                 ZONE                     STATUS
meddream              us-east5-a               RUNNING
meddream-dicom-jmp    us-east5-a               TERMINATED
dicom-gateway         us-east5-a               RUNNING
dicom-gateway-uk      europe-west2-b           TERMINATED
dicom-gateway-au      australia-southeast1-a   TERMINATED
```

- **`RUNNING`** → you can connect, skip to Step 2.
- **`TERMINATED`** → the server is switched off. Connecting will fail
  with an error like `failed to connect to backend` — that's not a bug,
  it just means nobody's home. See Step 1b below.

### Step 1b — Start it, if it's off

If you've been granted start/stop access, turn it on yourself:

```powershell
gcloud compute instances start SERVER_NAME --zone=ZONE --project=hailth-radiology
```

using the exact `NAME` and `ZONE` from the `list` output above. This
takes 20–40 seconds. Then re-run the `list` command from Step 1 to
confirm it now says `RUNNING` — the server also needs a few extra
seconds after that to actually finish booting Windows, so if the
connection still fails once, just wait ~30 seconds and try again.

If you weren't granted start/stop access, ask whoever manages the
project to start it for you instead.

> **Remember to stop it again when you're done** if it's not meant to
> stay on — servers left running cost money even when nobody's using
> them.
> ```powershell
> gcloud compute instances stop SERVER_NAME --zone=ZONE --project=hailth-radiology
> ```

### Step 2 — Open the tunnel

Pick the server you want from the table below, and run its command.
**Leave this PowerShell window open** — closing it ends the connection.

```powershell
gcloud compute start-iap-tunnel SERVER_NAME 3389 `
  --local-host-port=localhost:13389 `
  --zone=ZONE `
  --project=hailth-radiology
```

You'll see:

```
Testing if tunnel connection works.
Listening on port [13389].
```

That "Listening" line means it worked — leave it running and move to
Step 3.

> **Port 13389 is just a made-up local number** — it's not the server's
> real port, it's a private doorway only your own PC can see. You can
> reuse `13389` every time; it never conflicts with anything on the
> server side.

### Step 3 — Connect with Remote Desktop Connection

1. Open **Remote Desktop Connection** (`mstsc`), or run:
   ```powershell
   mstsc /v:localhost:13389
   ```
2. Enter the server's username/password when prompted (see below for
   where to find them).
3. When you're done, close the Remote Desktop window **and** stop the
   tunnel in PowerShell with `Ctrl+C`.

### Where to find the login password

Each server has its own password stored in Secret Manager. Easiest way
— the Secret Manager Console (link should already be in your welcome
email), find the secret named `SERVER_NAME-support-login`, and view its
latest value (it's JSON: `{"username":"support","password":"..."}`).

Or from PowerShell:

```powershell
gcloud secrets versions access latest --secret=SERVER_NAME-support-login --project=hailth-radiology
```

---

## Quick reference — servers and zones

| Server name | Zone | What it is |
|---|---|---|
| `meddream` | `us-east5-a` | MedDream viewer |
| `meddream-dicom-jmp` | `us-east5-a` | Jump server |
| `dicom-gateway` | `us-east5-a` | DICOM gateway (hub) |
| `dicom-gateway-uk` | `europe-west2-b` | DICOM gateway (UK) |
| `dicom-gateway-au` | `australia-southeast1-a` | DICOM gateway (AU) |

You'll only be able to open a tunnel to the servers you've actually been
granted access to — if you get a `PERMISSION_DENIED` on one, that's
expected for anything outside your grant, not something broken on your
PC.

---

## Troubleshooting

| What you see | What it means |
|---|---|
| `failed to connect to backend` | The server is switched off. Check Step 1. |
| `PERMISSION_DENIED` | You haven't been granted access to that specific server. |
| Tunnel opens, but Remote Desktop can't connect | Make sure the PowerShell window with the tunnel is still open — closing it kills the connection. |
| `gcloud: command not found` (or similar) | Open a new PowerShell window after installing (PATH only refreshes in new windows). |

---

## Quick copy-paste version (MedDream example)

```powershell
# 1. check status
gcloud compute instances list --project=hailth-radiology

# 2. open tunnel (keep this window open)
gcloud compute start-iap-tunnel meddream 3389 `
  --local-host-port=localhost:13389 `
  --zone=us-east5-a `
  --project=hailth-radiology

# 3. run: mstsc /v:localhost:13389
```
