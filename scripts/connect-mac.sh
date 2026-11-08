#!/usr/bin/env bash
# Interactive helper for connecting to a hailth.ai GCP VM from a Mac via
# IAP, when IAP Desktop (Windows-only) isn't an option. See
# docs/connect-from-mac.md for the full manual walkthrough this automates.

# This script needs real bash (arrays, [[ ]], process substitution). If
# it was started with `sh connect-mac.sh` instead of `./connect-mac.sh`
# or `bash connect-mac.sh`, macOS's bash-as-sh quietly runs in POSIX
# mode, which breaks the syntax below — re-exec under plain bash instead
# of failing with a confusing "syntax error" partway through.
if [[ "$(shopt -po posix 2>/dev/null)" == "set -o posix" ]]; then
  exec bash --norc --noprofile -- "$0" "$@"
fi

set -euo pipefail

PROJECT_ID="hailth-radiology"
RDP_PORT=3389

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "This script needs an interactive terminal (arrow keys, prompts). Run it directly in Terminal, not piped." >&2
  exit 1
fi

TUNNEL_PID=""
cleanup() {
  tput cnorm 2>/dev/null || true
  if [[ -n "$TUNNEL_PID" ]]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Percent-encodes a value for use inside the rdp:// URI below (the app's
# own query-string parser expects this, including for characters like
# ':' that `open` otherwise chokes on when handed this scheme raw).
urlencode() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
    [a-zA-Z0-9.~_-]) out+="$c" ;;
    *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Step 1 — make sure gcloud is installed
# ---------------------------------------------------------------------------
if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud (the Google Cloud CLI) is not installed." >&2

  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew isn't installed either, so this script can't install it for you." >&2
    echo "Install Homebrew first: https://brew.sh — then re-run this script." >&2
    exit 1
  fi

  read -rp "Install gcloud now via Homebrew? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    brew install --cask google-cloud-sdk
    if ! command -v gcloud >/dev/null 2>&1; then
      echo "gcloud was installed but isn't on your PATH yet. Open a new Terminal window and re-run this script." >&2
      exit 1
    fi
  else
    echo "Can't continue without gcloud. Exiting." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Generic arrow-key menu: reads from MENU_OPTIONS, sets MENU_SELECTED_INDEX
# ---------------------------------------------------------------------------
menu_select() {
  local idx=0
  local count=${#MENU_OPTIONS[@]}
  local key rest

  draw() {
    local i
    for ((i = 0; i < count; i++)); do
      if [[ $i -eq $idx ]]; then
        printf " \033[7m> %s\033[0m\n" "${MENU_OPTIONS[$i]}"
      else
        printf "   %s\n" "${MENU_OPTIONS[$i]}"
      fi
    done
  }

  tput civis
  draw
  while true; do
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
      IFS= read -rsn2 rest
      case "$rest" in
      '[A') # up
        idx=$(((idx - 1 + count) % count))
        ;;
      '[B') # down
        idx=$(((idx + 1) % count))
        ;;
      esac
      tput cuu "$count"
      draw
    elif [[ -z "$key" ]]; then
      # Enter
      break
    fi
  done
  tput cnorm
  MENU_SELECTED_INDEX=$idx
}

# ---------------------------------------------------------------------------
# Step 2 — log in, if not already
# ---------------------------------------------------------------------------
do_login() {
  echo
  echo "You need to sign in with your Google account first."
  MENU_OPTIONS=("Open a browser window to sign in (recommended)" "Show a code to enter on another device (no browser)")
  menu_select
  echo

  if [[ $MENU_SELECTED_INDEX -eq 0 ]]; then
    gcloud auth login
  else
    gcloud auth login --no-launch-browser
  fi

  active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)
  if [[ -z "$active_account" ]]; then
    echo "ERROR: login didn't complete. Re-run the script and try again." >&2
    exit 1
  fi
}

active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)

if [[ -n "$active_account" ]]; then
  echo "Already logged in as: $active_account"
else
  do_login
fi

# "Active" above only means gcloud has a cached account locally — the
# token itself can still have gone stale enough that Google demands
# reauthentication (its "reauth"/RAPT check, which only fires on an
# actual API call, not on the cheap "auth list" check above). That
# can't be satisfied non-interactively, so without this, the script
# would just crash here with gcloud's raw error text. set_project is
# the first real API call, so it doubles as the freshness check.
set_project() {
  # No internal set +e/-e here on purpose: this only ever runs with
  # errexit already off (the caller wraps every call in set +e/set -e),
  # and re-enabling it partway through, before this function returns,
  # makes bash treat this function's own `return 2`/`return 1` below as
  # a failing command under errexit — which exits the whole script
  # instead of just returning control to the caller. Confirmed the hard
  # way: that silently killed the script before it could ever reach the
  # reauth retry logic.
  local err_file rc
  err_file=$(mktemp)
  gcloud config set project "$PROJECT_ID" -q >/dev/null 2>"$err_file"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    cat "$err_file" >&2
    if grep -qi "reauth" "$err_file"; then
      rm -f "$err_file"
      return 2
    fi
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  return 0
}

set +e
set_project
rc=$?
set -e

if [[ $rc -eq 2 ]]; then
  echo
  echo "Your sign-in has expired and needs to be refreshed."
  do_login
  if ! set_project; then
    echo "ERROR: still couldn't set the active project after re-authenticating." >&2
    exit 1
  fi
elif [[ $rc -ne 0 ]]; then
  echo "ERROR: couldn't set the active project ($PROJECT_ID) — see the error above." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3 — list VMs, let the user pick one
# ---------------------------------------------------------------------------
echo
echo "Fetching VM list for project $PROJECT_ID..."
vm_lines=()
while IFS=$'\t' read -r name zone status; do
  vm_lines+=("$name"$'\t'"$zone"$'\t'"$status")
done < <(gcloud compute instances list --project="$PROJECT_ID" --format="value(name,zone,status)")

if [[ ${#vm_lines[@]} -eq 0 ]]; then
  echo "No VMs found (or you don't have compute.viewer on this project)." >&2
  exit 1
fi

MENU_OPTIONS=()
for line in "${vm_lines[@]}"; do
  IFS=$'\t' read -r name zone status <<<"$line"
  printf -v label "%-22s %-26s [%s]" "$name" "$zone" "$status"
  MENU_OPTIONS+=("$label")
done

echo
echo "Pick a server (use the arrow keys, then Enter):"
menu_select
IFS=$'\t' read -r VM_NAME VM_ZONE VM_STATUS <<<"${vm_lines[$MENU_SELECTED_INDEX]}"
echo
echo "Selected: $VM_NAME ($VM_ZONE) — currently $VM_STATUS"

# ---------------------------------------------------------------------------
# Step 4 — start it if it's off
# ---------------------------------------------------------------------------
if [[ "$VM_STATUS" != "RUNNING" ]]; then
  read -rp "This server is switched off. Start it now? [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Can't open a tunnel to a server that isn't running. Exiting." >&2
    exit 1
  fi
  gcloud compute instances start "$VM_NAME" --zone="$VM_ZONE" --project="$PROJECT_ID"
  echo

  # One minute is a reasonable estimate for a stopped Windows VM to
  # finish booting — used only to drive the progress bar's percentage.
  # The loop itself keeps polling the VM's actual status past that
  # estimate if it hasn't even reached RUNNING yet (that's the GCE-level
  # power-on event, not "Windows is ready") — otherwise it'd be easy to
  # walk straight into a doomed tunnel attempt against a VM that isn't
  # even up yet.
  EST_SECONDS=60
  POLL_INTERVAL=10
  BAR_WIDTH=30
  elapsed=0
  echo "Waiting for $VM_NAME to come up..."
  while true; do
    current_status=$(gcloud compute instances describe "$VM_NAME" --zone="$VM_ZONE" --project="$PROJECT_ID" --format="value(status)" 2>/dev/null || echo "UNKNOWN")

    if [[ "$current_status" == "RUNNING" && $elapsed -ge $EST_SECONDS ]]; then
      pct=100
    else
      pct=$((elapsed * 100 / EST_SECONDS))
      [[ $pct -gt 99 ]] && pct=99
    fi

    filled=$((pct * BAR_WIDTH / 100))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    bar+=$(printf '%*s' "$((BAR_WIDTH - filled))" '' | tr ' ' '-')
    printf "\r  [%s] %3d%%  status: %-12s" "$bar" "$pct" "$current_status"

    if [[ "$current_status" == "RUNNING" && $elapsed -ge $EST_SECONDS ]]; then
      echo
      break
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  echo "  Done."
fi

# ---------------------------------------------------------------------------
# Step 5 — check you can actually see this VM's password before opening a tunnel
# ---------------------------------------------------------------------------
SECRET_ID="${VM_NAME}-support-login"
echo
echo "Checking access to this server's credentials ($SECRET_ID)..."
err_file=$(mktemp)
if ! VM_SECRET_JSON=$(gcloud secrets versions access latest --secret="$SECRET_ID" --project="$PROJECT_ID" 2>"$err_file"); then
  echo "ERROR: you don't have permission to view the credentials for '$VM_NAME'." >&2
  echo "Ask whoever manages the project to grant you access, or pick a different server." >&2
  rm -f "$err_file"
  exit 1
fi
rm -f "$err_file"
echo "Access confirmed."

# The secret's value is JSON: {"username":"support","password":"..."} —
# pull out just the fields we need. Deliberately NOT using strict
# json.load() here: on at least one VM, the stored secret has had a
# genuinely invalid escape (a bare backslash) in it, which also means
# the VM's own boot script (which parses this the same strict way, via
# PowerShell's ConvertFrom-Json) likely failed to set that password too
# — see the note this script prints below if that happens. A plain
# regex extracts the field's raw text either way, which is what you
# actually need to type/paste, parseable or not — but it still has to
# decode real JSON escapes like & (Terraform's jsonencode() HTML-
# escapes every '&' in the password into exactly that — it's the only
# character in this module's password charset that's ever affected,
# since Go's JSON encoder only HTML-escapes '&', '<' and '>'), while
# leaving a genuinely invalid escape alone instead of crashing on it.
creds_line=$(printf '%s' "$VM_SECRET_JSON" | python3 -c '
import re, sys
raw = sys.stdin.read()

def unescape(s):
    simple = {"\"": "\"", "\\": "\\", "/": "/", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t"}
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            nc = s[i + 1]
            if nc in simple:
                out.append(simple[nc]); i += 2; continue
            if nc == "u" and i + 6 <= n:
                try:
                    out.append(chr(int(s[i + 2:i + 6], 16))); i += 6; continue
                except ValueError:
                    pass
            out.append(c); i += 1; continue
        out.append(c); i += 1
    return "".join(out)

def field(name):
    m = re.search(r"\"" + name + r"\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", raw)
    return unescape(m.group(1)) if m else None
u, p = field("username"), field("password")
if u is None or p is None:
    sys.exit(1)
print(u + "\t" + p)
') || {
  echo "ERROR: couldn't find username/password fields in the secret value for '$VM_NAME'." >&2
  echo "Check the raw value in the Secret Manager Console ($SECRET_ID) — it may be malformed." >&2
  exit 1
}
IFS=$'\t' read -r VM_USERNAME VM_PASSWORD <<<"$creds_line"
unset VM_SECRET_JSON creds_line

if printf '%s' "$VM_PASSWORD" | grep -q '\\'; then
  echo
  echo "NOTE: this password contains a backslash character, which is unexpected" >&2
  echo "for this VM's setup and isn't valid JSON — it suggests the secret's" >&2
  echo "stored value may not match what Terraform generated. The VM's own boot" >&2
  echo "script parses this the same strict way and may have failed to actually" >&2
  echo "set this password as a result. If login fails, that's the likely reason" >&2
  echo "— worth checking/resetting the secret (and rebooting the VM) properly." >&2
  echo
fi

# ---------------------------------------------------------------------------
# Step 6 — pick a free local port, copy the password, show instructions
# ---------------------------------------------------------------------------
LOCAL_PORT=13389
while nc -z localhost "$LOCAL_PORT" 2>/dev/null; do
  LOCAL_PORT=$((LOCAL_PORT + 1))
done

if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$VM_PASSWORD" | pbcopy
  password_note="copied to your clipboard — just paste it"
else
  password_note="$VM_PASSWORD"
fi
unset VM_PASSWORD

echo
echo "Opening the tunnel to $VM_NAME..."
gcloud compute start-iap-tunnel "$VM_NAME" "$RDP_PORT" \
  --local-host-port="localhost:$LOCAL_PORT" \
  --zone="$VM_ZONE" \
  --project="$PROJECT_ID" &
TUNNEL_PID=$!

echo "Waiting for it to come up..."
tunnel_up=0
for ((i = 0; i < 30; i++)); do
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "ERROR: the tunnel process exited early — see the gcloud output above." >&2
    exit 1
  fi
  if nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
    tunnel_up=1
    break
  fi
  sleep 1
done

if [[ $tunnel_up -ne 1 ]]; then
  echo "ERROR: tunnel didn't come up within 30 seconds." >&2
  exit 1
fi

# Windows App registers both the "rdp://" URI scheme and .rdp files
# (com.microsoft.rdc.macos) — this pre-fills the server address and
# username so there's no manual "Add PC" step. Only the password still
# needs pasting: Windows App has no documented way to accept it via this
# scheme, and embedding it in a plaintext file/URI isn't something to do
# even if it did.
RDP_URI="rdp://full%20address=s%3Alocalhost%3A${LOCAL_PORT}&username=s%3A$(urlencode "$VM_USERNAME")"

echo
echo "================================================================"
echo " Connecting to: $VM_NAME"
echo "================================================================"
if open "$RDP_URI" 2>/dev/null; then
  echo
  echo " Windows App should be opening now."
  echo " Password: $password_note"
  echo
  echo " Command used: open \"$RDP_URI\""
else
  echo
  echo " Couldn't open Windows App automatically — do it manually:"
  echo "   Install: https://apps.apple.com/app/microsoft-remote-desktop/id1295203466"
  echo "   1. Click + -> Add PC"
  echo "   2. PC name:   localhost:$LOCAL_PORT"
  echo "   3. Save, then double-click it to connect"
  echo "   4. Username:  $VM_USERNAME"
  echo "   5. Password:  $password_note"
  echo
  echo " Or run this yourself: open \"$RDP_URI\""
fi
cat <<EOF

 Leave THIS window open while you're connected — press Ctrl+C
 here when you're done to disconnect.
================================================================

EOF

wait "$TUNNEL_PID"
