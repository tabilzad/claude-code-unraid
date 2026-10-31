<!-- claude-code-unraid managed CLAUDE.md. Installed at /etc/claude-code/CLAUDE.md by the Claude Code for Unraid plugin (Settings, Claude Code, "Unraid context for every session" turns it off). Edit the template in the plugin repository, not this copy. -->
# This machine is an Unraid server

You run as root on an Unraid NAS, started by the Claude Code for Unraid plugin. Treat it as a production appliance: other people's data and services live here, and the user approves your commands in the terminal.

## Where things are

- `/mnt/user/<share>` is a user share: a FUSE view that merges the array disks and the pools. `/mnt/disk1`, `/mnt/disk2`, ... are the array disks and `/mnt/<pool>` (for example `/mnt/cache`) the pools. The same file is reachable both ways; use `/mnt/user` unless told otherwise.
- Never create a new top-level directory under `/mnt/user/`, `/mnt/<pool>/` or `/mnt/diskN/`: Unraid turns it into a new share. Create things inside an existing share.
- `/mnt/user/appdata/<app>` holds the configuration of Docker containers. Containers are defined in the Unraid WebGUI (templates under `/boot/config/plugins/dockerMan/templates-user/`); `docker ps`, `docker logs` and `docker compose` in an appdata folder are the normal tools.
- `/boot` is the USB flash drive: the OS image and `/boot/config` (settings, plugin files, share definitions, `super.dat`). It is read-only inside this session. The running system lives in RAM and is rebuilt from `/boot` at every reboot, so changes under `/etc`, `/usr` or `/root` do not persist unless a plugin or `/boot/config/go` re-applies them.
- Array and disk state: `mdcmd status`, `cat /proc/mdstat`, `/var/local/emhttp/var.ini` and `disks.ini`. Logs: `/var/log/syslog`; this plugin logs to `/var/log/claude-code-unraid/`.

## How to behave here

- Read before you change: `df -h`, `lsblk`, `docker ps`, `zpool status`, `btrfs filesystem show`, `smartctl -a /dev/sdX` are pre-approved and safe.
- Do not format, wipe, partition or overwrite disks, change the array, or run `rm -rf` on `/mnt` or `/boot`. The plugin's policy blocks these; the user does such things from the WebGUI.
- Stopping or restarting containers, services or the array affects other people. Say what it will interrupt and ask first.
- Keep your own files in the current workspace directory, not inside shares, unless the user points you to a place.
- Before asking for approval of a command that changes something, say in one line what it changes.
