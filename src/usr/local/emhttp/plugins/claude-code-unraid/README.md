**Claude Code for Unraid**

Installs Anthropic's Claude Code CLI natively on the Unraid host (`claude` in any terminal), keeps its login, settings and conversations across reboots, brings supervised sessions back after the array starts, and wraps the agent in an enforced policy: Manual permission mode, no bypass mode, a command guard, an audit log and a read-only flash drive. Works with the array stopped and Docker disabled, for diagnostics and recovery.

**Claude Code runs as root.** The permission prompts are your control; the policy reduces accidents, it is not a security boundary. Read the project's security notes before use.

Not affiliated with, endorsed by, or supported by Anthropic PBC or Lime Technology, Inc. Claude Code is proprietary Anthropic software, downloaded from Anthropic's official release servers at install time and verified against Anthropic's signed release manifest; it is never redistributed by this plugin. Requires a Claude subscription or API key.

Settings: Settings, User Utilities, Claude Code. Terminal: `claude`, `claude-unraid status|doctor|work|start|attach`.
