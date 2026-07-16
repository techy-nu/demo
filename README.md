# pyupdate-demo — End-to-End Update & Rollback Experiment

This is a minimal, real, runnable demo of the architecture we discussed:

```
GitHub repo → GitHub Actions (CI + Release) → GitHub Releases (versioned tarball)
   → on-device update agent → systemd → atomic swap → health check → rollback if failed
```

It runs a tiny Python HTTP service (`app/main.py`) as a systemd service, and an
update agent that checks GitHub for new releases, downloads them, verifies them,
swaps them in atomically, and rolls back automatically if the new version fails
its health check.

You can run the "device" part on a Raspberry Pi, a spare Linux box, or just a
Linux VM/VPS (even WSL2 works for everything except systemd testing — for real
systemd behavior you want an actual Linux machine or VM, not WSL1).

---

## Prerequisites

- A GitHub account
- A Linux machine (physical, VM, or cloud VPS) with `python3`, `curl`, `systemd`
- ~30–45 minutes

---

## Step 1 — Create the GitHub repo

1. Create a new **public** repo on GitHub, e.g. `pyupdate-demo` (public avoids
   needing an auth token for the demo — for a private repo you'd add a
   `GITHUB_TOKEN`-authenticated `curl` header, noted at the end).
2. Push this project's contents to it:
   ```bash
   cd pyupdate-demo
   git init
   git add .
   git commit -m "Initial commit: demo app + CI/CD + update agent"
   git branch -M main
   git remote add origin https://github.com/<yourusername>/pyupdate-demo.git
   git push -u origin main
   ```
3. **Important**: open `deploy/update-agent.sh` and change:
   ```bash
   GITHUB_REPO="yourusername/pyupdate-demo"
   ```
   to your actual `<yourusername>/pyupdate-demo`, then commit and push that change.

You should immediately see the **CI workflow** run automatically on the `main`
branch push (check the "Actions" tab on GitHub) — this is Workflow 1 from our
earlier discussion, running tests on every push.

---

## Step 2 — Cut your first release (v1.0.0)

```bash
git tag -a v1.0.0 -m "First release"
git push origin v1.0.0
```

Watch the **Actions** tab — the `release.yml` workflow (Workflow 2) will run,
build a tarball containing `app/` + a `VERSION` file, compute a checksum, and
publish both as a **GitHub Release** for tag `v1.0.0`. Confirm it appears under
the repo's "Releases" page with two attached assets: the `.tar.gz` and `.tar.gz.sha256`.

---

## Step 3 — Prepare the device

On your Linux device (as a user with `sudo`):

```bash
# Create a dedicated, unprivileged user to run the service
sudo useradd --system --no-create-home --shell /usr/sbin/nologin pyupdate

# Create the app directory structure
sudo mkdir -p /opt/pyupdate-demo/releases /opt/pyupdate-demo/deploy
sudo chown -R pyupdate:pyupdate /opt/pyupdate-demo

# Copy the update agent script onto the device
sudo cp deploy/update-agent.sh /opt/pyupdate-demo/deploy/update-agent.sh
sudo chmod +x /opt/pyupdate-demo/deploy/update-agent.sh

# Install the systemd units
sudo cp deploy/systemd/pyupdate-demo.service /etc/systemd/system/
sudo cp deploy/systemd/pyupdate-updater.service /etc/systemd/system/
sudo cp deploy/systemd/pyupdate-updater.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

> Note: the update agent script itself runs as root (via the `pyupdate-updater.service`,
> which has no `User=` set, so it defaults to root) because it needs to `systemctl restart`
> the app service and write to `/opt/pyupdate-demo`. The **application** runs as the
> unprivileged `pyupdate` user. This separation matters for security — worth pointing out
> if this is for a class demo.

---

## Step 4 — Run the first manual deploy

Rather than waiting for the timer, trigger the update agent by hand the first time:

```bash
sudo /opt/pyupdate-demo/deploy/update-agent.sh
```

Expected output: it detects no current version, downloads `v1.0.0`, verifies the
checksum, extracts it, flips the `current` symlink, restarts the service, and
confirms the health check passes.

Verify:

```bash
curl http://127.0.0.1:8080/healthz
# {"status": "ok", "version": "1.0.0"}

cat /opt/pyupdate-demo/state.json
# {"version": "1.0.0", "previous_version": "none"}

sudo systemctl status pyupdate-demo.service
```

**This is your baseline — v1.0.0 is live.**

---

## Step 5 — Ship a real update (v1.1.0) and watch it apply with zero downtime

Make a small visible change, e.g. edit `app/main.py`'s `/` route to say something
different, then:

```bash
git add app/main.py
git commit -m "Update banner text"
git tag -a v1.1.0 -m "Second release"
git push origin main
git push origin v1.1.0
```

Wait for the release workflow to finish on GitHub (check Releases tab for `v1.1.0`),
then run the update agent again on the device:

```bash
sudo /opt/pyupdate-demo/deploy/update-agent.sh
tail -f /opt/pyupdate-demo/update.log
```

While this runs, in a **second terminal** hammer the health endpoint to observe
the downtime window:

```bash
while true; do curl -s -o /dev/null -w "%{http_code} " http://127.0.0.1:8080/healthz; sleep 0.2; done
```

You should see this gap be very small (just the systemd restart time — typically
well under a second for this tiny app), not a multi-second outage, because the
symlink flip itself is instantaneous and only the service restart takes any time
at all. Confirm the version moved:

```bash
curl http://127.0.0.1:8080/healthz
# {"status": "ok", "version": "1.1.0"}
```

**This proves: versioned releases, delta-free-but-small downloads, and near-zero downtime.**

---

## Step 6 — The important part: simulate a BAD release and watch automatic rollback

This is the step that actually proves your rollback logic works, not just that it
exists on paper.

Cut a deliberately broken release using a `-broken` tag suffix (the release
workflow detects this and sets `APP_BROKEN=1` in the shipped `VERSION` file,
which makes `main.py`'s `/healthz` return HTTP 500):

```bash
git tag -a v1.2.0-broken -m "Intentionally broken release for rollback demo"
git push origin v1.2.0-broken
```

Wait for the release to build, then run the update agent:

```bash
sudo /opt/pyupdate-demo/deploy/update-agent.sh
```

Watch what happens:
1. It downloads and verifies `v1.2.0-broken` — verification passes (the tarball itself isn't corrupted, it's just designed to fail its health check).
2. It swaps `current` to the new release and restarts the service.
3. It polls `/healthz` for up to 30 seconds and sees HTTP 500 the whole time.
4. It automatically flips `current` **back** to `v1.1.0` and restarts the service again.
5. It exits with a non-zero code and logs the failure.

Confirm:

```bash
cat /opt/pyupdate-demo/update.log
curl http://127.0.0.1:8080/healthz
# {"status": "ok", "version": "1.1.0"}   <-- back to the last known-good version
```

**This is the whole point of the exercise**: the device never got stuck on a
broken version, and recovering required zero network access — it rolled back
purely using what was already on local disk.

---

## Step 7 — Turn on the automatic timer (instead of running manually)

Now that you've watched it work manually, enable the timer so it runs on its own:

```bash
sudo systemctl enable --now pyupdate-updater.timer
sudo systemctl list-timers pyupdate-updater.timer
```

Cut a new good release (e.g. `v1.3.0`) and just wait — within the 2-minute demo
interval, the timer will fire, detect it, and apply it without you running
anything by hand. Watch it happen live:

```bash
journalctl -u pyupdate-updater.service -f
```

---

## Step 8 — What to show your professor / in a write-up

You now have, on video or live:
- A `git tag` → GitHub Actions build → GitHub Release, fully automated (Workflows 1 & 2 from before).
- A device that autonomously detects and applies new versions on a timer.
- Proof of near-zero-downtime updates (the `while true; curl` loop output).
- Proof of automatic, network-independent rollback on a bad release.
- An audit trail (`update.log`, `state.json`) showing exactly what happened and when.

That's a complete, demonstrable version of the architecture — the same shape
you'd scale up for a real fleet, just without a fleet dashboard/coordinator layer yet.

---

## Optional next steps (mention as "future work" if this is for a class)

- **Private repo support**: add `-H "Authorization: Bearer $GITHUB_TOKEN"` to the
  `curl` calls in `update-agent.sh`, with the token stored in `/etc/pyupdate-demo/token`
  (root-only readable), not hardcoded in the script.
- **Signing**: add `gpg --verify` or `cosign` signature verification alongside the
  checksum check, using a public key baked into the device at provisioning time.
- **Webhook instead of polling**: replace the timer with a small listener that
  GitHub's `release.published` webhook hits directly, for near-instant updates
  instead of a poll interval.
- **Multiple services**: duplicate the pattern for additional systemd units if you
  have more than one background process, all sharing the same release directory
  structure.
# pyupdate-demo
