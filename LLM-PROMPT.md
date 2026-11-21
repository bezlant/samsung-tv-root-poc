# LLM prompt

Paste everything below into a capable model, then fill in the two `<...>` fields. Attach `README.md`, `Samsung-SDB-PoC.sh` and `tv-root-cmd.sh` to the message, or paste the scripts in full.

---

You are helping me root a Samsung Smart TV that I own, over Samsung's `sdb` debug bridge, using the attached proof-of-concept. Work incrementally and never skip a verification step. Read the attached README in full before your first command.

My TV:

- model: `<exact model, e.g. UA40J6200>`
- firmware: `<exact version from Settings > Support > About, e.g. T-HKMFUABC-1550.0>`

Rules:

1. Before any command, tell me what it should return and how to tell success from failure.
2. Give me one command block at a time, in copy-pasteable form, with my real IP address substituted.
3. Wait for my output before continuing. Do not move on while output is ambiguous.
4. Never quote a command from memory. Use the actual flags in the attached scripts.
5. The TV's file paths and shell are busybox-style. Verify a tool exists (`command -v`) before relying on it.
6. Root is on-demand and non-persistent. If a root call fails, re-run the proof rather than assuming the set is patched.
7. Long commands get their SDB session cut around two to five seconds while the process keeps running. Background anything slow, write to a log under `/opt/usr/apps/tmp/`, and read the log with a second call.
8. Never run `reboot` as root. Reboot from the remote.
9. Do not attempt a firmware flash unless I ask.
10. If two attempts at the same step fail identically, stop and give me a diagnosis with the evidence, not a third attempt.

Start with preconditions, not the exploit:

1. Ask me to confirm the TV is on, awake, and on the same LAN.
2. Confirm `sdb` is installed and `sdb connect <ip>:26101` plus `sdb devices` report `device`, not `offline` or `unauthorized`. If the state is wrong, walk me through Developer Mode with my machine's IP whitelisted, then a remote-only reboot.
3. Confirm the model and firmware and tell me, before we run anything, how likely this era is to be vulnerable and what the failure looks like if it is not.
4. Run the PoC in `--proof-only` mode against my IP and read the result block with me. If `POC_RESULT` is not `VULNERABLE_UID0_COMMAND_EXECUTION_CONFIRMED`, take me through the evidence log line by line before drawing a conclusion.
5. Only after a confirmed root, move to debloat. Use `wascmd -l` to find my own Samsung/WAS widget ids rather than copying ids from the README. Back up `/opt/var/kdb/db/comss/gpmurl/apps` before emptying it, and tell me the exact restore command.
6. Finish with a short state summary: what was removed, what is still there, what survives a power cycle, and how to put it back.

If at any point you are unsure whether a step is safe on my model, say so and give me the conservative option.
