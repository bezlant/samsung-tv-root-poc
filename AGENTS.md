# AGENTS.md

You are driving a root procedure on a Samsung Smart TV that the human owns. Read `README.md` fully before your first command. Then read `LLM-PROMPT.md` for the phase order. This file is the rules layer.

## Setup

Ask, before anything else:

1. Exact model (Settings > Support > About This TV, or the label on the back).
2. Exact firmware string (same screen, looks like `T-HKMFUABC-1550.0`).
3. That the TV is on, awake, and on the same LAN as the machine you are running on.

If the firmware is not Tizen 2.x or the platform prefix is not `T-HKM*`, say so and lower expectations before running anything. This PoC is untested outside 2015 HAWKM sets.

## Precondition gate

Do not run the exploit until all four are true:

- `sdb connect <ip>:26101` exits 0.
- `sdb devices` shows `<ip>:26101` in state `device`.
- `sdb -s <ip>:26101 shell 0 getdate` returns a date.
- Developer Mode is confirmed on, with the agent machine's LAN IP whitelisted.

If `devices` shows `offline` or `unauthorized`, stop and walk the human through Developer Mode and a reboot from the remote. A router handing out a new DHCP lease silently breaks the whitelist: verify the machine's current IP is the one on the TV screen, and fix that instead of retrying.

## Running it

```bash
./Samsung-SDB-PoC.sh --target <ip>
```

Expected success block:

```
IDENTITY=uid=0(root) gid=0(root) ...
SECURITY_CONTEXT=sdbd
POC_RESULT=VULNERABLE_UID0_COMMAND_EXECUTION_CONFIRMED
```

`POC_RESULT=UID0_NOT_CONFIRMED_OR_SESSION_INCOMPLETE` is not proof the set is patched. Read the evidence log, and check `READY_MARK_OBSERVED`, `DONE_MARK_OBSERVED` and `KERNEL`/session lines first.

For a root shell, `--shell`. For scripted work, `TARGET=<ip>:26101 SDB=<path> ./tv-root-cmd.sh "cmd"`.

## Rules

1. One command block at a time. State what success looks like before running it.
2. Long commands die silently at the two-to-five second SDB session timeout while the process keeps running. Background anything slower than a `ls` to a log under `/opt/usr/apps/tmp/`, then read the log in a separate call.
3. Never run `reboot`, `halt` or `init` as root. The vendor chain has a `dd` that factory resets `/opt` on the next boot. Reboot with the remote.
4. `wascmd -u` takes the numeric Samsung/WAS id. `applist` prints Tizen ids. Use `wascmd -l` to map them; a wrong id returns `APPID_NOT_EXIST` with exit code 0 and changes nothing.
5. Every install attempt consumes the staged `.wgt`, including failures. `ls` the file immediately before installing.
6. Back up every file before editing it, and put the restore command in your summary.
7. Root is non-persistent and re-triggerable. If a call fails, re-run the proof; do not assume the set is patched.
8. Do not flash firmware unless asked.
9. Do not touch boot-critical units, `/etc/startup*` or existing systemd units. A new standalone unit is acceptable only if the human asks for persistence.
10. Two identical failures at the same step means stop and diagnose with evidence, not a third attempt.

## Debloat, in order

1. Inventory: `wascmd -l` and `applist`. Show the human the list and let them choose.
2. Back up `/opt/var/kdb/db/comss/gpmurl/apps`.
3. Remove chosen widgets one at a time, verifying the directory is gone and re-reading `applist` between each.
4. Empty the backed-up preinstall list so the store cannot re-add them.
5. Standby/wake the TV and confirm the removals hold.

Do not remove anything the human has not named. Gallery, Playback and the App Launcher are load-bearing on this generation.

## Close out with

- What was removed and verified absent.
- What survived and what will return after a power cycle.
- The exact restore commands.
- Whether a standby/wake test was run and its result, stated honestly.
