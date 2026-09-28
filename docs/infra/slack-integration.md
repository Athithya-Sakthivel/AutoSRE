# AutoSRE Slack Integration

This directory documents how AutoSRE uses Slack for human-in-the-loop (HITL) approval of Tier-2 and higher remediation actions.

Slack is optional. Without it, approvals use the web UI at `/approvals`. When enabled, Slack provides an additional approval channel.

## How Slack approval works

Only the `approve_node` flow uses Slack.

When an investigation proposes a Tier-2 action such as `scale_deployment`, the LangGraph pauses on `interrupt()`. AutoSRE then:

1. Detects the paused incident by polling the runner.
2. Posts a Block Kit approval message containing the alert, service, proposed tool, arguments, risk tier, rationale, and **Approve** / **Reject** buttons.
3. Receives the button click through Socket Mode or HTTP.
4. Validates the transport authentication, approver user ID, and incident ID.
5. Calls `runner.approve_incident()`, which resumes LangGraph with `Command(resume=...)`.
6. Updates the Slack message with the terminal status.

Slack is only a UI. The authoritative record is the incident's checkpointed state and its `executed_actions` list.

## Configuration

All Slack settings use the `AUTOSRE_SLACK__` prefix.

| Variable                           | Required    | Purpose                                                       |
| ---------------------------------- | ----------- | ------------------------------------------------------------- |
| `AUTOSRE_SLACK__BOT_TOKEN`         | Yes         | Bot OAuth token (`xoxb-`) used to post and update messages    |
| `AUTOSRE_SLACK__APP_TOKEN`         | Socket Mode | App-level token (`xapp-`) used for the Socket Mode connection |
| `AUTOSRE_SLACK__APPROVAL_CHANNEL`  | Yes         | Channel ID where approval requests are posted (`C...`)        |
| `AUTOSRE_SLACK__APPROVER_USER_IDS` | Yes         | JSON array of Slack user IDs allowed to approve or reject     |
| `AUTOSRE_SLACK__MODE`              | No          | `socket` (default) or `http`                                  |
| `AUTOSRE_SLACK__SIGNING_SECRET`    | HTTP only   | Slack signing secret used to verify HTTP requests             |

Example:

```bash
export AUTOSRE_SLACK__MODE="socket"
export AUTOSRE_SLACK__BOT_TOKEN="xoxb-..."
export AUTOSRE_SLACK__APP_TOKEN="xapp-..."
export AUTOSRE_SLACK__APPROVAL_CHANNEL="C..."
export AUTOSRE_SLACK__APPROVER_USER_IDS='["U...","U..."]'
```

If `AUTOSRE_SLACK__BOT_TOKEN` is unset, AutoSRE logs:

```text
Slack integration disabled (set AUTOSRE_SLACK__BOT_TOKEN to enable)
```

Approvals then use the web UI.

### Token types

AutoSRE uses two Slack token types:

* **`xoxb-` bot token** — authenticates Web API calls such as `chat.postMessage` and `chat.update`.
* **`xapp-` app-level token** — authenticates the Socket Mode connection and is only needed in Socket Mode.

It does not use `xoxp-` user tokens.

## Slack app setup

### 1. Create the app

1. Open https://api.slack.com/apps.
2. Click **Create New App** → **From scratch**.
3. Enter an app name such as `AutoSRE`.
4. Select the workspace containing the approval channel.
5. Click **Create App**.

### 2. Enable Socket Mode

For the default transport:

1. Open **Settings** → **Socket Mode**.
2. Enable Socket Mode.
3. Create an App-Level Token, for example `autosre-socket`.
4. Add `connections:write`.
5. Generate and copy the `xapp-` token into `AUTOSRE_SLACK__APP_TOKEN`.

Socket Mode does not require a signing secret.

> Recent `slack-sdk` versions raise `ValueError` when `SignatureVerifier` is constructed with an empty secret. AutoSRE therefore creates the verifier only in HTTP mode. Older SDKs may behave differently, but Socket Mode does not require a signing secret.

### 3. Add the bot scope

Open **Features** → **OAuth & Permissions** → **Scopes** and add:

```text
chat:write
```

This is the only bot scope AutoSRE needs.

It does not read Slack history or require `chat:write.public`, `channels:history`, `channels:read`, `users:read`, or `reactions:write`.

### 4. Install the app

Under **OAuth & Permissions**:

1. Click **Install to Workspace**.
2. Approve the requested scope.
3. Copy the **Bot User OAuth Token** (`xoxb-...`) into `AUTOSRE_SLACK__BOT_TOKEN`.

Workspace admin approval may be required.

### 5. Enable interactivity

Open **Features** → **Interactivity & Shortcuts** and enable **Interactivity**.

For Socket Mode, leave the Request URL empty.

For HTTP mode, set:

```text
https://<your-agent-host>/slack/interactivity
```

and copy the signing secret from **Basic Information** into:

```bash
export AUTOSRE_SLACK__SIGNING_SECRET="..."
```

### 6. Configure the approval channel

Use a dedicated channel such as `#autosre-approvals`.

AutoSRE stores the channel ID, not the name, so channel renames do not break the integration.

To find the ID:

1. Open the channel.
2. Open **View channel details**.
3. Copy the **Channel ID** (`C...`).

You can also get it from a Slack URL such as:

```text
https://app.slack.com/client/T012ABCDEFG/C01234A5BCD
```

The `C...` segment is the channel ID.

Set:

```bash
export AUTOSRE_SLACK__APPROVAL_CHANNEL="C..."
```

Do not use `#channel-name`.

### 7. Invite the bot

In the approval channel:

```text
/invite @AutoSRE
```

The bot must be a member of the channel or `chat.postMessage` will return `not_in_channel`.

### 8. Configure approvers

Only Slack users listed in `AUTOSRE_SLACK__APPROVER_USER_IDS` can approve or reject an action.

To copy a user's ID:

1. Open the user's profile.
2. Click **More**.
3. Select **Copy member ID**.

Example:

```bash
export AUTOSRE_SLACK__APPROVER_USER_IDS='["U012ABCDEF","U0987654321"]'
```

The value must be a JSON array of strings. A bare comma-separated list is invalid.

Slack user IDs are stable even when display names change. `SlackConfig` refuses to enable the integration when the allowlist is empty.

## Transport modes

### Socket Mode

Socket Mode is the default. AutoSRE maintains an outbound WebSocket connection to Slack.

Use it when the agent is a single replica or when inbound connectivity is undesirable.

**Advantages**

* No public endpoint, DNS, TLS, or ingress required.
* Works behind NAT, firewalls, and restrictive network policies.
* No signing secret required.

**Considerations**

* The connection must remain available; the SDK reconnects automatically.
* Slack does not allow Socket Mode apps in the public Marketplace.
* A given app should not be used for multiple AutoSRE Socket Mode replicas; interactions are delivered to a single connection.

### HTTP mode

Slack sends interactions to AutoSRE over HTTPS.

Use it for multi-replica deployments behind a load balancer.

**Requirements**

* Public or otherwise reachable HTTPS endpoint.
* TLS/DNS/ingress configuration.
* Signing secret and HMAC verification.

Set:

```bash
export AUTOSRE_SLACK__MODE="http"
export AUTOSRE_SLACK__SIGNING_SECRET="..."
```

## Verification

### Without Slack

Run the local end-to-end test:

```bash
cd agents
bash test_e2e.sh --test-locally --incident-id=INC-003
```

Confirm the log contains:

```text
Slack integration disabled (set AUTOSRE_SLACK__BOT_TOKEN to enable)
```

The application should continue running normally and the web approval UI should remain available.

### With Slack

Configure the Slack variables and run:

```bash
export AUTOSRE_SLACK__BOT_TOKEN="xoxb-..."
export AUTOSRE_SLACK__APP_TOKEN="xapp-..."
export AUTOSRE_SLACK__APPROVAL_CHANNEL="C..."
export AUTOSRE_SLACK__APPROVER_USER_IDS='["U..."]'

bash test_e2e.sh --run
```

Confirm:

```text
Slack integration enabled (mode=socket channel=C...)
```

Trigger a Tier-2 incident such as `INC-002` or another incident whose expected action is `scale_deployment`.

The approval message should appear in the configured channel. Clicking **Approve** should replace the buttons with a status line and resume the incident. Verify the corresponding entry in `executed_actions`.

## Common failures

| Symptom                         | Cause                                           | Fix                                                      |
| ------------------------------- | ----------------------------------------------- | -------------------------------------------------------- |
| `invalid_auth`                  | Invalid or rotated bot token                    | Regenerate the bot token and update the environment      |
| `not_in_channel`                | Bot is not a channel member                     | `/invite @AutoSRE`                                       |
| No approval message             | Wrong channel ID or incident never reached HITL | Verify the `C...` channel ID and incident tier           |
| Button click ignored            | User is not allowlisted                         | Add the user's `U...` ID and restart                     |
| `signature_verification_failed` | Wrong HTTP signing secret                       | Copy the signing secret again from **Basic Information** |

## Security

Treat bot and app tokens as secrets.

* Never commit tokens to Git. Use a git-ignored `.env` file or a secret manager.
* Rotate leaked credentials immediately. Old tokens are revoked when rotated.
* Authentication is not authorization. Only users in `AUTOSRE_SLACK__APPROVER_USER_IDS` may approve or reject remediation.
* In HTTP mode, every request is HMAC-verified before parsing or dispatch. Invalid signatures receive HTTP 401 and are not processed.
* Slack messages redact common secret-bearing argument names such as `password`, `token`, `secret`, `api_key`, `authorization`, and `credential`. Tools should still never accept raw credentials as arguments.

## What AutoSRE does not use Slack for

AutoSRE:

* does not read channel history;
* does not listen for slash commands;
* does not post routine status updates;
* does not use Slack as the audit trail;
* does not use user OAuth tokens.

Both Slack and the web UI eventually call the same:

```text
POST /incidents/{id}/approve
```

Slack is therefore an additional UI surface, not a separate approval system.

## References

* Bot and app-level tokens: https://docs.slack.dev/authentication/tokens/
* Token types: https://api.slack.com/authentication/token-types
* Socket Mode: https://docs.slack.dev/apis/events-api/using-socket-mode/
* Python Socket Mode client: https://docs.slack.dev/tools/python-slack-sdk/socket-mode/
* Interactivity: https://docs.slack.dev/interactivity/handling-user-interaction/
* `chat:write`: https://docs.slack.dev/reference/scopes/chat.write/
* `chat.update`: https://docs.slack.dev/reference/methods/chat.update/
* `connections:write`: https://docs.slack.dev/reference/scopes/connections.write/

## See also

* `agents/src/autosre/slack/` — Slack client, handler, listener, and Socket Mode transport.
* `agents/src/autosre/api/main.py` — lifecycle wiring for Slack components.
* `infra/terraform/README.md` — alert flow into the agent and eventual Slack approval.
