# AutoSRE Slack Integration

This directory documents how AutoSRE talks to Slack for human-in-the-loop
(HITL) approval of Tier-2 and higher remediation actions.

AutoSRE does not require Slack to run. When Slack is disabled, HITL
approvals fall back to the web UI at `/approvals`. Slack is an additional
delivery channel: it lets an operator approve or reject a pending action
from a chat message instead of opening a browser tab.

## What Slack is used for

Only one flow: `approve_node` in the LangGraph investigation. When the
agent proposes a Tier-2 action (for example `scale_deployment`), the graph
pauses on a LangGraph `interrupt()`. AutoSRE then:

1. Detects the paused incident by polling the runner every few seconds.
2. Posts a Block Kit message to a configured Slack channel. The message
   contains the alert name, service, proposed tool, arguments, risk tier,
   rationale, and two buttons: **Approve** and **Reject**.
3. Waits for a click. The click arrives either over Socket Mode (default)
   or over an HTTP interactivity endpoint (alternative).
4. Validates the click: correct signature or envelope, correct user ID in
   the allowlist, correct incident ID.
5. Resumes the graph by calling `runner.approve_incident()`, which sends
   a `Command(resume=...)` back into LangGraph.
6. Updates the Slack message in place, replacing the buttons with a
   terminal status line.

The Slack message is a UI. It is not the audit trail. The authoritative
approval record lives in the incident's checkpointed state and in the
`executed_actions` list. Slack is never queried to reconstruct what
happened.

## Required credentials

AutoSRE reads four Slack values from environment variables. All four
begin with the `AUTOSRE_SLACK__` prefix (double underscore = nested).

| Variable | Purpose | Format |
|---|---|---|
| `AUTOSRE_SLACK__BOT_TOKEN` | Authenticates AutoSRE as a bot user when posting or updating messages in Slack. | `xoxb-...` |
| `AUTOSRE_SLACK__APP_TOKEN` | Authenticates the Socket Mode WebSocket connection. Only used in socket mode. | `xapp-...` |
| `AUTOSRE_SLACK__APPROVAL_CHANNEL` | The channel ID where approval requests are posted. | `C...` |
| `AUTOSRE_SLACK__APPROVER_USER_IDS` | JSON list of Slack user IDs allowed to approve or reject. | `["U...","U..."]` |

Two additional variables exist for the HTTP transport variant. They are
not needed when `AUTOSRE_SLACK__MODE` is `socket` (the default).

| Variable | Purpose | Format |
|---|---|---|
| `AUTOSRE_SLACK__MODE` | Selects the transport. Defaults to `socket`. | `socket` or `http` |
| `AUTOSRE_SLACK__SIGNING_SECRET` | Verifies HMAC signature on inbound HTTP interactions. Only used in HTTP mode. | string |

Example `.env` block:

```bash
export AUTOSRE_SLACK__MODE="socket"
export AUTOSRE_SLACK__BOT_TOKEN="xoxb-..."
export AUTOSRE_SLACK__APP_TOKEN="xapp-..."
export AUTOSRE_SLACK__APPROVAL_CHANNEL="C..."
export AUTOSRE_SLACK__APPROVER_USER_IDS='["U...","U..."]'
```

If `AUTOSRE_SLACK__BOT_TOKEN` is unset, AutoSRE logs
`Slack integration disabled` at startup and every approval falls back to
the web UI. No other configuration is required to run without Slack.

## Slack token types: what each prefix means

Slack issues several classes of access token. The prefix on the string
identifies the class and determines what the token can do. AutoSRE uses
two of them.

### `xoxb-` — Bot User OAuth Token

Represents the bot user attached to the Slack App. It is scoped to the
scopes you selected under **Bot Token Scopes** in the app configuration.
The token is tied to the app, not to the user who installed it, so it
remains valid even if that user is later deactivated.

AutoSRE uses the bot token to call `chat.postMessage` and `chat.update`.
It never calls Slack APIs that require a user identity.

### `xapp-` — App-Level Token

A separate token used only for App-level APIs. For a Socket Mode app, the
app-level token is used to call `apps.connections.open`, which returns a
short-lived WebSocket URL. The Slack SDK then connects to that URL and
receives events and interactions over the socket.

An app-level token is not interchangeable with a bot token. It is a
distinct credential with a distinct scope list. AutoSRE's Socket Mode
client receives it via `AUTOSRE_SLACK__APP_TOKEN`.

### `xoxp-` — User OAuth Token

Not used by AutoSRE. Mentioned here only to disambiguate: a user token
acts on behalf of a human user, which is the wrong identity model for an
automated agent. Do not set `AUTOSRE_SLACK__BOT_TOKEN` to an `xoxp-`
value. The Slack SDK will reject it with `invalid_auth`.

## Creating the Slack App

The steps below produce the four values. It is a one-time manual setup in
the Slack admin UI. Nothing in this repository automates it.

### Step 1: Create the app

1. Open https://api.slack.com/apps.
2. Click **Create New App**.
3. Choose **From scratch**.
4. Enter an app name (for example `AutoSRE`).
5. Select the workspace where the approval channel lives.
6. Click **Create App**.

The app now exists in a disabled state with no tokens and no scopes.

### Step 2: Enable Socket Mode

1. In the left sidebar, open **Settings** then **Socket Mode**.
2. Toggle **Enable Socket Mode** to on.
3. Slack prompts you to create an App-Level Token. Name it something
   descriptive (for example `autosre-socket`).
4. Add the scope `connections:write`. This is the only scope required.
5. Click **Generate**.
6. Copy the token. It begins with `xapp-`. This is the value for
   `AUTOSRE_SLACK__APP_TOKEN`.

Do not navigate away before copying. Slack shows the token only once.

Note on the Slack SDK version: recent releases of `slack-sdk` changed
`SignatureVerifier` so it raises `ValueError` at construction when given
an empty signing secret. Socket Mode apps legitimately have no signing
secret, so AutoSRE constructs the verifier lazily and only when
`AUTOSRE_SLACK__MODE=http`. If you run an older SDK that requires a
non-empty secret, set `AUTOSRE_SLACK__MODE=socket` and leave the signing
secret unset; the SDK path for HTTP will never be constructed.

### Step 3: Add bot token scopes

1. In the left sidebar, open **Features** then **OAuth & Permissions**.
2. Scroll to **Scopes**.
3. Under **Bot Token Scopes**, click **Add an OAuth Scope**.
4. Add `chat:write`. This allows the bot to post messages and update
   existing messages.

AutoSRE does not need `chat:write.public`. That scope only matters when
posting to public channels the bot has not joined. The bot is invited to
its approval channel explicitly (Step 7 below), so plain `chat:write` is
sufficient and grants a smaller surface.

AutoSRE does not need `channels:history`, `im:history`, or any read
scope. It does not read Slack messages; it only posts and updates the
messages it owns.

### Step 4: Install the app to the workspace

1. Still under **OAuth & Permissions**, scroll to **OAuth Tokens for Your
   Workspace**.
2. Click **Install to Workspace**.
3. Slack shows the requested scopes. Click **Allow**.
4. After the redirect back to the app settings page, copy the
   **Bot User OAuth Token**. It begins with `xoxb-`. This is the value for
   `AUTOSRE_SLACK__BOT_TOKEN`.

If the workspace requires admin approval for new installs, this step
submits a request instead. Wait for approval before proceeding.

### Step 5: Enable interactivity

1. In the left sidebar, open **Features** then **Interactivity &
   Shortcuts**.
2. Toggle **Interactivity** to on.

In Socket Mode, you do not set a Request URL. Slack delivers button
clicks over the WebSocket. The Request URL field can remain empty.

If you prefer HTTP mode (see the "Transport modes" section below), set
the Request URL here to `https://<your-agent-host>/slack/interactivity`
and copy the Signing Secret from **Basic Information** into
`AUTOSRE_SLACK__SIGNING_SECRET`.

### Step 6: Get the channel ID

Slack channel names can be renamed. Channel IDs cannot. AutoSRE stores
the ID, not the name, so a rename does not break the integration.

To find the channel ID:

1. In Slack, open the channel you plan to use. A dedicated channel such
   as `#autosre-approvals` is recommended over a general channel.
2. Click the channel name at the top of the conversation, or right-click
   it in the left sidebar.
3. Choose **View channel details**.
4. Scroll to the bottom of the details panel.
5. Copy the **Channel ID**. It begins with `C`, for example
   `C01234ABCD`.

Alternative method: open the channel in a browser. The URL looks like
`https://app.slack.com/client/T012ABCDEFG/C01234A5BCD`. The segment
starting with `C` is the channel ID.

Copy that value into `AUTOSRE_SLACK__APPROVAL_CHANNEL`.

Do not use the `#channel-name` form. AutoSRE expects an ID.

### Step 7: Invite the bot to the channel

The bot cannot post to a channel it has not joined.

1. Open the approval channel in Slack.
2. Type `/invite @AutoSRE` (or whatever display name you chose in Step 1).
3. Press Enter. Slack confirms the bot has been added.

If you skip this step, `chat.postMessage` returns `not_in_channel` and
AutoSRE logs the failure.

### Step 8: Get approver user IDs

The approver allowlist restricts who can click the Approve button. Without
it, any workspace member with access to the channel could authorize a
remediation. `SlackConfig` refuses to enable Slack when the allowlist is
empty.

To get a user ID:

1. In Slack, click the user's avatar or name to open their profile.
2. Click **More** (three dots) at the top of the profile panel.
3. Choose **Copy member ID**.
4. Paste into a JSON array.

Example with two approvers:

```bash
export AUTOSRE_SLACK__APPROVER_USER_IDS='["U012ABCDEF","U0987654321"]'
```

To verify the ID is correct, open the user's profile in a browser. The
URL ends with the user ID. For example,
`https://app.slack.com/team/U012ABCDEF` confirms the ID is `U012ABCDEF`.

The list must be a JSON array of strings, quoted as shown. A
comma-separated bare list like `U012ABCDEF,U0987654321` will fail
validation, because the config layer parses it as JSON.

User IDs are stable. Unlike display names, they do not change when a
person renames their Slack account.

## Transport modes: Socket Mode vs HTTP

Two transports can carry inbound interactions. Both are production-ready.

### Socket Mode (default, recommended)

AutoSRE opens an outbound WebSocket to Slack at startup. Button clicks
arrive over that socket. No inbound network access is required.

Advantages:
- Works behind NAT, corporate firewalls, and Kubernetes NetworkPolicies
  that block inbound traffic.
- No public DNS, TLS certificate, or ingress route is needed.
- No signing secret required for verification, because the socket itself
  is authenticated by the app-level token.

Limitations:
- The connection must be maintained. If it drops, Slack's SDK reconnects
  automatically, but a sustained outage delays approvals.
- Slack does not allow Socket Mode apps in the public Marketplace.
- Only one process may hold the Socket Mode connection for a given app.
  Running multiple AutoSRE replicas with socket mode will cause Slack to
  route each interaction to an arbitrary replica, and only one will
  receive it.

### HTTP mode

Slack posts interactions to an HTTPS endpoint on the AutoSRE service.

Advantages:
- Works with multiple replicas behind a load balancer. Any replica can
  handle the interaction.
- No long-lived connection to maintain.

Limitations:
- Requires an inbound HTTPS route to the AutoSRE service.
- Requires a signing secret, and HMAC verification of every inbound
  request.
- More moving parts: ingress, TLS, DNS.

### How to choose

For a single-replica deployment (local Kind, single-node staging), use
Socket Mode. It is the default and requires no extra infrastructure.

For a multi-replica deployment behind a load balancer, use HTTP mode.

Set the mode with:

```bash
export AUTOSRE_SLACK__MODE="socket"   # or "http"
```

## Required bot scopes

AutoSRE requests the minimum set it needs.

| Scope | Why |
|---|---|
| `chat:write` | Post and update the approval message |

No other bot scopes are required. `chat:write.public`, `channels:history`,
`channels:read`, `users:read`, and `reactions:write` are not used by
AutoSRE. If a future feature needs one of them, add it explicitly under
**Bot Token Scopes** and reinstall the app. Adding a scope to the manifest
without reinstalling does not grant it.

## Verifying the integration

### Without a real Slack workspace

Confirm the wiring compiles and the disabled path runs cleanly:

```bash
cd agents
bash test_e2e.sh --test-locally --incident-id=INC-003
```

Look for the startup log line:

```
Slack integration disabled (set AUTOSRE_SLACK__BOT_TOKEN to enable)
```

No errors. No crashed pods. No approval panel missing from the UI.

### With a real Slack workspace

Export the four values, then start the agent:

```bash
export AUTOSRE_SLACK__BOT_TOKEN="xoxb-..."
export AUTOSRE_SLACK__APP_TOKEN="xapp-..."
export AUTOSRE_SLACK__APPROVAL_CHANNEL="C..."
export AUTOSRE_SLACK__APPROVER_USER_IDS='["U..."]'
bash test_e2e.sh --run
```

Look for the startup log line:

```
Slack integration enabled (mode=socket channel=C...)
```

Trigger a Tier-2 incident (INC-002 or any incident whose expected action
is `scale_deployment`). Within a few seconds a message appears in the
approval channel with two buttons.

Click Approve. The buttons are replaced with a status line, and the
AutoSRE incident resumes. The evidence is the corresponding entry in the
incident's `executed_actions`.

### Failure modes to watch for

| Symptom | Cause | Fix |
|---|---|---|
| `invalid_auth` at startup | Bot token is wrong or was rotated. | Regenerate the bot token and update the environment. |
| `not_in_channel` when posting | Bot has not been invited. | Run `/invite @AutoSRE` in the channel. |
| Socket connects but no messages arrive | Channel ID is wrong, or the incident never reaches HITL. | Verify the ID starts with `C`. Verify the incident is Tier-2. |
| Button click ignored | Clicking user is not in `AUTOSRE_SLACK__APPROVER_USER_IDS`. | Add the user ID and restart. AutoSRE logs the rejected user ID. |
| `signature_verification_failed` (HTTP mode only) | Signing secret is wrong. | Recopy from **Basic Information**. |

## What AutoSRE does not do with Slack

These are worth stating explicitly, because the opposite is often assumed.

- It does not read channel messages. No `channels:history` or
  `im:history` scopes are requested.
- It does not listen for slash commands.
- It does not post routine status updates. Only HITL approval requests
  produce a Slack message.
- It does not use Slack as its audit trail. The checkpointed incident
  state is authoritative.
- It does not use a user token. All writes are performed as the bot.
- It does not fall back to Slack when the web UI is unavailable, nor the
  reverse. Both surfaces call the same `POST /incidents/{id}/approve`
  endpoint and are equivalent.

## Security notes

Bot tokens and app tokens grant write access to the Slack workspace. They
must be treated as secrets.

- Never commit them to Git. Store them in a `.env` file that is
  git-ignored, or inject them from a secret manager.
- Rotate them immediately if they leak. Both can be regenerated from the
  Slack app settings; the old tokens are revoked on rotation.
- The approver allowlist is the only authorization gate. Slack
  authentication alone is not enough: any workspace member who can see
  the channel can click the button. Only Slack user IDs on the allowlist
  are accepted.
- In HTTP mode, every inbound interaction is HMAC-verified against the
  signing secret before any parsing or side effect. Requests with an
  invalid signature are rejected with HTTP 401 and are never dispatched.
- The `tool_args` displayed in the Slack message are redacted for common
  secret-bearing key names (`password`, `token`, `secret`, `api_key`,
  `authorization`, `credential`) before rendering. This is a secondary
  defense; the primary rule is that tools should never accept a raw
  credential as an argument.

## References

The setup procedure above matches the current Slack documentation. The
relevant pages:

- Bot and app-level tokens:
  https://docs.slack.dev/authentication/tokens/
- Token prefix reference:
  https://api.slack.com/authentication/token-types
- Socket Mode setup:
  https://docs.slack.dev/apis/events-api/using-socket-mode/
- Socket Mode client (Python SDK):
  https://docs.slack.dev/tools/python-slack-sdk/socket-mode/
- Interactivity and user interactions:
  https://docs.slack.dev/interactivity/handling-user-interaction/
- `chat:write` scope:
  https://docs.slack.dev/reference/scopes/chat.write/
- `chat.update` API:
  https://docs.slack.dev/reference/methods/chat.update/
- `connections:write` scope:
  https://docs.slack.dev/reference/scopes/connections.write/

## See also

- `agents/src/autosre/slack/` — implementation of the client, handler,
  listener, and Socket Mode transport.
- `agents/src/autosre/api/main.py` — lifespan wiring that constructs and
  starts the Slack components.
- `infra/terraform/README.md` — how OpenObserve alerts reach the agent
  and trigger the investigations that eventually produce a Slack
  approval request.

---

## Notes on the four variables, condensed

For a quick reference, the four variables map to Slack artifacts as follows.

`AUTOSRE_SLACK__BOT_TOKEN` is the `xoxb-` token Slack issues after a
successful install. It is found under **OAuth & Permissions → OAuth
Tokens for Your Workspace** in the app settings. It authenticates the
outbound Web API calls AutoSRE makes to post and update messages.

`AUTOSRE_SLACK__APP_TOKEN` is the `xapp-` token generated under
**Settings → Basic Information → App-Level Tokens** with the
`connections:write` scope. It authenticates the WebSocket connection used
by Socket Mode. It is only needed in socket mode.

`AUTOSRE_SLACK__APPROVAL_CHANNEL` is the `C`-prefixed channel ID. It is
found by right-clicking the channel in Slack, choosing **View channel
details**, and scrolling to the bottom of the panel. It identifies where
AutoSRE posts approval requests.

`AUTOSRE_SLACK__APPROVER_USER_IDS` is a JSON array of `U`-prefixed Slack
user IDs. Each ID is copied from a user's profile via **More → Copy
member ID**. The list restricts who can authorize a remediation; without
it, `SlackConfig` refuses to enable the integration.

---
