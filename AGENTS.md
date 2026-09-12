# Repository Purpose

This repository is a personal, single-user soft fork of the upstream Windscribe Desktop App. Its purpose is to package and run the full client on NixOS through a flake and NixOS module, while carrying the small Linux-specific behavior changes needed by the owner's setup, particularly around split tunneling, Tailscale, and DNS integration.

Keep fork-specific changes simple and narrowly scoped so upstream releases remain easy to merge. Do not optimize for a general userbase or upstream contribution requirements unless explicitly requested.

See `CLAUDE.md` for the upstream project's technical architecture, conventions, and build guidance.
