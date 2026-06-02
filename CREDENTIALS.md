# Working with Credentials

Credentials live **only in your Mac's keychain** (encrypted at rest, unlocked
when you log into your Mac). No secret value is ever written to a file by these
scripts — not on your Mac, not in the VM. A small index file records only the
*structure* (which credentials exist, their type, their env-var name or domain).

## The two mechanisms

**env** — injected as an environment variable into the VM session when you run
`ccvm`. The value is fetched from the keychain at that moment, lives in memory
for that session only, and is gone when you close the session. It is never
written to a file inside the VM, never in shell history.
Use for: tools that read a credential from an env var or git helper
(`GITHUB_TOKEN`, database passwords, framework API keys).

**proxy** — the value stays on your Mac and is injected into outbound HTTPS
requests to a specific domain by Squid. The VM never holds it.
Use for: pure HTTP APIs where you want the key to never enter the VM at all.

> **Honest note on proxy injection.** Adding an `Authorization` header to an
> *HTTPS* request requires the proxy to terminate TLS for that domain (a scoped
> man-in-the-middle, using a CA trusted only inside the VM). That means traffic
> to those specific domains is decrypted on your Mac, where you control it.
> This is the same technique corporate proxies use. It is powerful but more
> involved, so **env is the default and recommended choice** for the three
> credentials you're starting with. Reach for proxy only when "the key must
> never exist inside the VM, even in memory" is a hard requirement.

## Add a credential

```bash
./manage_credentials add github            # uses built-in default (env, GITHUB_TOKEN)
./manage_credentials add anthropic         # env, ANTHROPIC_API_KEY (Console/API users)
./manage_credentials add gcp               # env, mounts a JSON key file (see below)
./manage_credentials add stripe --type=proxy   # prompts for the domain
./manage_credentials add mysvc --type=env      # prompts for the env-var name
```

If you omit `--type` and the name isn't a built-in, it asks you interactively.

## List / remove

```bash
./manage_credentials list
./manage_credentials remove github
```

To change a value, just `add` it again — it overwrites.

## Using credentials inside the VM

**env credentials** are ordinary environment variables:

```bash
echo $GITHUB_TOKEN        # present
gh auth status            # gh CLI picks it up
git push origin my-branch # git credential helper uses it
```

**proxy credentials** need no action — the request to the registered domain
just succeeds; the proxy added the header. Claude never sees the key.

## The three you're starting with

- **Anthropic.** On a Pro/Max plan the simplest path is the one-time `/login`
  inside Claude Code — no credential needed here. Only add an `anthropic`
  credential if you bill through the Console/API (then it's `env`,
  `ANTHROPIC_API_KEY`).
- **GitHub.** `./manage_credentials add github` → paste a token with push/pull
  scope. Injected as `GITHUB_TOKEN`; `gh` and `git` use it automatically.
- **GCP.** `./manage_credentials add gcp` → give the **path** to your
  service-account JSON key file on your Mac. On each `ccvm`, that file's
  contents are written to `/home/claude/.run-creds/gcp.json` inside the VM for
  the session and `GOOGLE_APPLICATION_CREDENTIALS` points at it. The file is
  not part of the VM image and is recreated fresh each session from the value
  in your keychain. (If you later switch to `gcloud auth application-default
  login` instead, just run `gcloud` inside the VM; no credential entry needed.)

## After adding a credential

- env type → available next time you run `ccvm`.
- proxy type → re-run `./setup_claude_code` so Squid picks up the new domain.

## What the index file looks like (no values, ever)

```
# ~/.claude-vm/credentials.index
# name        type    env-var / domain
github         env     GITHUB_TOKEN
gcp            env     GOOGLE_APPLICATION_CREDENTIALS
openai         proxy   api.openai.com
```
