---
name: cadence-guardrails:guardrails-init
description: >
  Configure git-guardrails with your GitHub identity. Self-destructs after setup
  so it reappears when the plugin updates.
license: MIT
metadata:
  author: cameronsjo
  version: "1.0"
---

Configure git-guardrails by detecting the user's GitHub identity and writing the required environment variables to `~/.claude/settings.json`.

## Steps

1. **Check current state** - Read `~/.claude/settings.json` and check if `CADENCE_ALLOWED_OWNERS` already exists in the `env` block. If configured, show current values and ask if the user wants to reconfigure or exit. (Legacy `GIT_GUARDRAILS_ALLOWED_OWNERS` / `GIT_GUARDRAILS_ALLOWED_REPOS` keys are no longer read by the binary as of cadence-hooks 0.8.0 — offer to migrate them if present.)

2. **Detect GitHub identity** - Run `gh api user --jq .login` to get the authenticated GitHub username. If `gh` is not installed or not authenticated, ask the user to provide their GitHub username manually via AskUserQuestion.

3. **Ask for additional owners** - Use AskUserQuestion:
   - Pre-fill the detected username as the primary owner
   - Ask: "Any additional GitHub orgs or users to allow?" with options:
     - "Just my account (Recommended)" — use only the detected username
     - "Add orgs/users" — prompt for space-separated list to append
   - If the user chooses to add more, ask for the list as free text

4. **Ask for allowed repos** - Use AskUserQuestion:
   - "Any specific repos from other owners you need write access to?" with options:
     - "None (Recommended)" — leave `CADENCE_ALLOWED_REPOS` empty
     - "Add repos" — prompt for space-separated `owner/repo` list
   - These are repos you don't own but have write access to (collaborator repos, org repos)

5. **Write to settings.json** - Read `~/.claude/settings.json`, add/update these keys in the `env` block:
   - `CADENCE_ALLOWED_OWNERS` — space-separated list of GitHub users/orgs
   - `CADENCE_ALLOWED_REPOS` — space-separated list of `owner/repo` pairs (only if the user provided any)
   - If legacy `GIT_GUARDRAILS_ALLOWED_OWNERS` or `GIT_GUARDRAILS_ALLOWED_REPOS` keys exist, remove them after copying their values forward.
   - Preserve all other existing env vars. Do not modify anything else in settings.json.

6. **Verify** - Read back the settings.json and confirm the values were written correctly. Show the user what was set.

7. **Self-destruct** - After successful configuration:
   - Find this plugin's cache directory: `~/.claude/plugins/cache/*/git-guardrails/commands/guardrails-init.md`
   - Delete ONLY this command file from the cached copy
   - Tell the user: "The /guardrails-init command has been removed from your local cache. It will reappear next time the git-guardrails plugin updates."

8. **Summary** - Show what was configured and remind the user:
   - Restart Claude Code for the env vars to take effect
   - The hooks will now guard `git push` and `gh` write operations against repos outside the allowed list
   - To reconfigure later: reinstall the plugin or manually edit `~/.claude/settings.json` env block

## Important

- The env vars go in `~/.claude/settings.json` under the `env` key, NOT as shell exports
- `CADENCE_ALLOWED_OWNERS` is REQUIRED — hooks block all pushes/writes if unset
- `CADENCE_ALLOWED_REPOS` is OPTIONAL — only needed for collaborator/org repos
- Requires cadence-hooks 0.8.0 or newer. Earlier versions read `GIT_GUARDRAILS_ALLOWED_*` — if the user is on an older binary, keep the legacy names until they upgrade (`brew upgrade cadence-hooks`)
- The self-destruct targets the CACHE copy, not the source repo
- If `gh` CLI is unavailable, fall back to manual input — don't fail
