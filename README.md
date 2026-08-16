# Steelyard

Multi-user tool for reconciling a Hack Club Clearinghouse-style HCB organization: pair incoming
donations with the outgoing transactions that account for them, and see what's still unmatched.
Reads organizations and ledgers live from the [HCB v4 API](https://github.com/hackclub/hcb)
(read-only, OAuth2); matches and their audit trail live in this app's Postgres.

Favicon made by [Candy](https://github.com/codingkatty)!

## Local setup

1. Ruby 3.4.9 (see `.ruby-version`), Postgres running locally.
2. `bundle install`
3. `bin/rails db:create db:migrate`
4. Register an OAuth application at <https://hcb.hackclub.com/api/v4/oauth/applications> with
   redirect URI `http://localhost:3000/auth/hcb/callback`.
5. `cp .env.example .env` and fill in `HCB_OAUTH_CLIENT_ID` / `HCB_OAUTH_CLIENT_SECRET`.
6. `bin/dev`, then open <http://localhost:3000> and log in with HCB.

## Secrets

All the secrets should be theoretically stored in `.env` (I think). An example should be in `.env.example` (theoretically). To run with production credentials, use `.env.production`.

## Tests

```
bin/rails test
```

## Change history

Every change to a match, its legs, its adjustments, and an organization's cutoff is written to the
`versions` table by PaperTrail.

Open a match ("View" on any match row, or the ⓘ on a matched transaction in the ledger) and you get
it back as a popup: both sides as full transactions, who matched them and when, who last touched it
since, and a **Change history** dropdown listing every action behind it. One action reads as one
entry — `Matches::Update` replaces every leg, so a single edit writes half a dozen versions, and
`Matches::History` regroups them by the request that wrote them. That popup has its own link
(`/organizations/<org>/matches/<id>`, the "Copy link" button), which opens the matcher with the
match already open over it.

For anything the popup doesn't answer, read the table from the console:

```ruby
match.versions.map { |v| [ v.created_at, v.event, v.actor_name, v.object_changes ] }

# Everything one request changed -- e.g. a cutoff move and the matches it
# cascade-undid, which is otherwise indistinguishable from unrelated undos.
AuditVersion.for_request(version.request_id)

# An organization's history, newest first.
AuditVersion.for_organization("org_...").order(created_at: :desc)
```

`actor_name` is the person responsible, or the process where no person is: `resync` for a
discrepancy re-derived after HCB restated a transaction (see `Matches::Resync`), `legacy_import`
for records brought over from the pre-Rails app.

This is a record, not a mechanism — nothing reads it to decide behaviour (the popup above only
displays it), and undoing a match is still `undone_at`/`undone_by_user_id` on the match itself.

## API and MCP

Programs get in with a personal API token, minted at `/api_tokens` (linked from the organization
list). A token acts as the person who created it: it reaches exactly the organizations they belong
to, with the role they have there, and matches it makes are recorded under their name. Only the
token's digest is stored, so it's shown once at creation and can be revoked from the same page.

### MCP

Steelyard is an MCP server over streamable HTTP at `POST /mcp` — an assistant can look up what's
unmatched, hunt for the counterpart of a transaction, and confirm matches. In Claude Code:

```
claude mcp add --transport http steelyard https://<host>/mcp \
  --header "Authorization: Bearer <token>"
```

On claude.ai, add `https://<host>/mcp` as a **custom connector** — no token to paste. Steelyard is
its own OAuth 2.1 authorization server, so the connector sends each person through HCB login and a
consent screen, and acts as them afterwards. That means per-person roles and per-person attribution
on matches, which a shared credential can't give you. The connection then shows up on `/api_tokens`
as a "connected app" and is revoked from the same button as everything else.

The OAuth surface: `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server`
for discovery, `POST /oauth/register` (RFC 7591 dynamic client registration), `GET|POST /oauth/authorize`
(consent, S256 PKCE required), and `POST /oauth/token` (authorization code + refresh, rotating refresh
tokens). Note claude.ai reaches the server from Anthropic's egress range, so a connector needs a
publicly reachable HTTPS host — `localhost` works with Claude Code only.

Tools: `list_organizations`, `get_reconciliation_summary`, `list_transactions`, `get_transaction`,
`list_matches`, `get_match`, `create_match`, `update_match`, `undo_match`. The last three need the
member or manager role, and `undo_match` reverses anything `create_match` did. `update_match` edits
a match in place -- partial, so a note can be added without restating the legs -- which is what to
use on a match that's merely incomplete, since undoing and re-creating loses the thread of its
history. `get_match` is the one to reach for
before undoing somebody else's work: it carries the same change history the detail popup shows, so
a match two people have already edited reads as a disagreement rather than a mistake.

### REST

| Method   | Path                                                 |                                                          |
| -------- | ---------------------------------------------------- | -------------------------------------------------------- |
| `GET`    | `/api/v1/me`                                          | Who the token belongs to                                  |
| `GET`    | `/api/v1/organizations`                               | Organizations this token can reach                        |
| `GET`    | `/api/v1/organizations/:id`                           | Cutoff, unmatched totals, balanced/unbalanced match counts |
| `GET`    | `/api/v1/organizations/:id/transactions`              | `status`, `direction`, `query`, `after`, `before`, `min_amount`, `max_amount`, `include_before_cutoff`, `limit`, `offset` |
| `GET`    | `/api/v1/organizations/:id/transactions/:txn_id`      | One transaction, with the match it belongs to             |
| `GET`    | `/api/v1/organizations/:id/matches`                   | `status=all\|balanced\|unbalanced`                        |
| `GET`    | `/api/v1/organizations/:id/matches/:match_id`         | One match with its change history; answers for undone ones |
| `POST`   | `/api/v1/organizations/:id/matches`                   | `incoming_ids`, `outgoing_ids`, `note`                    |
| `PATCH`  | `/api/v1/organizations/:id/matches/:match_id`         | `incoming_ids`, `outgoing_ids`, `note` -- partial; anything you leave out stays as it is |
| `DELETE` | `/api/v1/organizations/:id/matches/:match_id`         | Undo a match                                              |

```
curl -H "Authorization: Bearer <token>" https://<host>/api/v1/organizations
```

Both surfaces are the same operations (`PublicApi::Operations`), and both are separate from the
`/organizations/:id/api/...` routes, which serve this app's own frontend off its session cookie.

## Importing legacy matches

One-off import of the pre-Rails app's `matches.json` / `manual_transactions.json` / `ledger.json`
(dry run by default; see the task's `desc` for details):

```
bin/rails "migrate:legacy_matches[/path/to/legacy_source,<hcb_organization_id>,<local_user_id>]"
```
