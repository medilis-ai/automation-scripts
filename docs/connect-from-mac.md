# Connecting to a GCP server from a Mac

**Who this is for:** anyone on the team connecting to the hailth.ai GCP
servers from a **Mac laptop**.

**Why you need this:** everyone else on the team uses **IAP Desktop**, a
Windows-only app that gives a simple double-click connection to any
server. IAP Desktop doesn't exist for Mac, so this guide replaces it with
two tools that do: Google's own command-line tool (`gcloud`) to open the
secure connection, and Microsoft's **Windows App** to actually see the
server's screen.

It's a few more steps than double-clicking an icon, but once it's set up
it only takes two commands and about 30 seconds each time.

> **Shortcut:** `scripts/connect-mac.sh` in this repo walks through all of
> this for you — checks/installs `gcloud`, logs you in, lists the
> servers with whether you actually have access to each one, lets you
> pick one with the arrow keys, opens the tunnel, and launches Windows App
> with the server address and username already filled in (you just paste
> the password, already copied to your clipboard). Run it with:
> ```bash
> ./scripts/connect-mac.sh
> ```
> Everything below explains what it's doing, and is also the manual
> fallback if the script doesn't work for some reason.

---

## How this works, in one sentence

`gcloud` opens a private, authenticated tunnel from your Mac straight to
the server (this is called **IAP** — Identity-Aware Proxy, the same
thing IAP Desktop uses internally) — then **Windows App** connects
through that tunnel exactly like a normal remote-desktop connection.

---

## One-time setup

### 1. Install the Google Cloud CLI (`gcloud`)

If you don't already have it:

```bash
brew install --cask google-cloud-sdk
```

Don't have Homebrew? Use Google's installer instead:
https://cloud.google.com/sdk/docs/install-sdk#mac

### 2. Sign in

```bash
gcloud auth login
```

This opens a browser window — sign in with your **medilis.com /
radsforvets.com Google account**, the same one that was given access to
GCP.

### 3. Set the default project

So you don't have to type `--project` every time:

```bash
gcloud config set project hailth-radiology
```

### 4. Install Windows App (the remote-desktop viewer)

Free, from the Mac App Store:
https://apps.apple.com/app/microsoft-remote-desktop/id1295203466

> That's it for one-time setup. Everything below, you'll repeat each
> time you want to connect.

---

## Every time you want to connect

### Step 1 — Check which servers are actually on

Not every server runs all the time. Before trying to connect, check its
status:

```bash
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

```bash
gcloud compute instances start SERVER_NAME --zone=ZONE --project=hailth-radiology
```

using the exact `NAME` and `ZONE` from the `list` output above. This
takes 20–40 seconds. You'll see a confirmation like:

```
Updated [https://compute.googleapis.com/compute/v1/projects/hailth-radiology/zones/ZONE/instances/SERVER_NAME].
Instance internal IP is 10.x.x.x
Instance external IP is x.x.x.x
```

Then re-run the `list` command from Step 1 to confirm it now says
`RUNNING` before moving on to Step 2 — the server also needs a few extra
seconds after that to actually finish booting Windows, so if the tunnel
still fails once, just wait ~30 seconds and try again.

If you weren't granted start/stop access, ask whoever manages the
project to start it for you instead.

> **Remember to stop it again when you're done** (same command, with
> `stop` instead of `start`) if it's not meant to stay on — servers left
> running cost money even when nobody's using them.
> ```bash
> gcloud compute instances stop SERVER_NAME --zone=ZONE --project=hailth-radiology
> ```

### Step 2 — Open the tunnel

Pick the server you want from the table below, and run its command.
**Leave this terminal window open** — closing it or pressing Ctrl+C ends
the connection.

```bash
gcloud compute start-iap-tunnel SERVER_NAME 3389 \
  --local-host-port=localhost:13389 \
  --zone=ZONE \
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
> real port, it's a private doorway only your own Mac can see. You can
> reuse `13389` every time; it never conflicts with anything on the
> server side.

### Step 3 — Connect with Windows App

1. Open **Windows App**.
2. Click **+** → **Add PC**.
3. Under "PC name", enter:
   ```
   localhost:13389
   ```
4. Save, then double-click it to connect.
5. Enter the server's username/password when prompted (see below for
   where to find them).
6. When you're done, close the Windows App window **and** stop the
   tunnel in Terminal with `Ctrl+C`.

### Where to find the login password

Each server has its own password stored in Secret Manager. Easiest way —
the Secret Manager Console (link should already be in your welcome
email), find the secret named `SERVER_NAME-support-login`, and view its
latest value.

Or from the command line:

```bash
gcloud secrets versions access latest \
  --secret=SERVER_NAME-support-login \
  --project=hailth-radiology
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
Mac.

---

## Troubleshooting

| What you see | What it means |
|---|---|
| `failed to connect to backend` | The server is switched off. Check Step 1. |
| `PERMISSION_DENIED` | You haven't been granted access to that specific server. |
| Tunnel opens, but Windows App can't connect | Make sure the tunnel terminal window is still open — closing it kills the connection. |
| `command not found: gcloud` | Re-open Terminal after installing (or run `exec zsh` once). |

---

## Quick copy-paste version (MedDream example)

```bash
# 1. check status
gcloud compute instances list --project=hailth-radiology

# 2. open tunnel (keep this window open)
gcloud compute start-iap-tunnel meddream 3389 \
  --local-host-port=localhost:13389 \
  --zone=us-east5-a \
  --project=hailth-radiology

# 3. in Windows App, connect to: localhost:13389
```
