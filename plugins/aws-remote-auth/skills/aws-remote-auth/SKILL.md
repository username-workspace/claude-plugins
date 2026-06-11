---
name: aws-remote-auth
description: >-
  Re-authenticate to AWS SSO on demand using a device code (autofill link) approved from any
  browser. Use when an AWS SSO session is expired or missing, when an aws/terraform command fails
  with "token has expired" or "SSO session ... expired", or to proactively refresh a profile before
  a long task. Works for any profile and SSO portal — nothing account-specific. Triggers: "re-auth
  AWS", "AWS SSO login", "refresh aws credentials", "aws token expired".
---

# AWS Remote Auth

## Overview

Re-authenticates an AWS SSO profile via the device-code flow and prints an autofill URL + code to
approve from any browser. A bundled PreToolUse hook also catches expired sessions on `aws` commands
automatically, so the model never sees a raw "token expired" error.

## On demand

Re-auth a profile (default: `$AWS_PROFILE`, else `default`):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sso-auth.py" login [profile] [--wait]
```

`--wait` prints the autofill URL + code, then **polls until the session becomes valid** and exits 0
on success. Run it **detached / in the background** so approval is detected automatically — no manual
"it's done" signal needed; the caller is notified when the command exits.

Check a session without re-authenticating:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sso-auth.py" status [profile]
```

Relay the printed autofill URL + code to the user. Once they approve in a browser, re-run the
original command — the SSO token is then cached.

## Automatic (hook)

The bundled PreToolUse hook (scoped to `aws *`) checks the target profile's SSO token **locally**
before the command runs. If expired or missing, it starts the device-code login, captures the
autofill URL + code, and blocks the command with that prompt instead of letting it fail. Relay the
prompt; after approval, re-run the command.

## Notes

- Expiry is read from `~/.aws/sso/cache` (no network). Profile is resolved from `--profile`, else
  `$AWS_PROFILE`, else `default`. SSO config is read from **both** `~/.aws/config` and
  `~/.aws/credentials` (or `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE`), across every layout:
  profiles declared in either file, legacy `sso_start_url` keys, the `sso_session` token-provider
  format, and assume-role chains via `source_profile` (the source profile owning the SSO is the one
  logged in).
- A pending login is reused (not relaunched) if you retry before approving. The autofill capture
  window is a **soft** deadline (`AWS_REMOTE_AUTH_CAPTURE_TIMEOUT`, default 12s — keep it under the
  hook's 20s budget): if the CLI prints the URL after the window, the next call recovers it from the
  running login's log instead of spawning a duplicate device login.
- `expiresAt` is honoured in every format the CLI has written (ISO `…Z`, legacy `… UTC`, bare
  timestamps — naive means UTC). Right after browser approval the CLI may take a moment to write the
  token cache; if a command still trips the hook, just re-run it.
- Requires AWS CLI v2 (`aws sso login --use-device-code`). Covers `aws` commands; for `terraform`
  or SDK calls, run `login` on demand first.
