---
name: simlease
description: Use when building, running, or testing an iOS app on a simulator — claims a leased simulator through simlease so parallel AI agents never collide, labels the simulator window with the task name, and releases it when done.
---

# SimLease — leased simulators for AI agents

This machine uses [SimLease](https://github.com/alexissan/simlease) to coordinate simulators between parallel AI agents. Never pick a simulator UDID yourself.

## Rules

1. **Claim, don't pick.** Before any simulator build/install/run:

   ```bash
   SIMULATOR_ID=$(simlease claim --label "<short task name>")
   ```

   Use the ticket ID or branch name as the label (omit `--label` to default to the git branch). The UDID is the only stdout output, so command substitution is safe.

2. **The claim is sticky.** Re-running `simlease claim` from the same directory returns the same device — call it before every build instead of caching the UDID across sessions. Each claim renews the 2-hour lease.

3. **Renew on long sessions.** If a task runs long between builds: `simlease renew`.

4. **Release when the task is done:**

   ```bash
   simlease release
   ```

   This restores the simulator's original name and frees it for other agents.
   After release, treat every previously returned UDID as invalid. Run
   `simlease claim` again before any later simulator work.

5. **Never touch 🔒 simulators you didn't claim.** A device whose name starts with 🔒 is leased by another agent or session. If no device is free, `simlease claim` creates a fresh one — you never need to take someone else's.

6. **Check the board when confused:** `simlease status` shows every lease (task, device, agent, time left). `simlease focus` brings your simulator's window to the front for the human.

## Build integration

```bash
SIMULATOR_ID=$(simlease claim)
xcodebuild -scheme MyApp -destination "id=$SIMULATOR_ID" build
xcrun simctl install "$SIMULATOR_ID" path/to/MyApp.app
xcrun simctl launch "$SIMULATOR_ID" com.example.MyApp
```
