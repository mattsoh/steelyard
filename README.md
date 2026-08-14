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

Tools: `list_organizations`, `get_reconciliation_summary`, `list_transactions`, `get_transaction`,
`list_matches`, `create_match`, `undo_match`. The last two need the member or manager role, and
`undo_match` reverses anything `create_match` did.

### REST

| Method   | Path                                                 |                                                          |
| -------- | ---------------------------------------------------- | -------------------------------------------------------- |
| `GET`    | `/api/v1/me`                                          | Who the token belongs to                                  |
| `GET`    | `/api/v1/organizations`                               | Organizations this token can reach                        |
| `GET`    | `/api/v1/organizations/:id`                           | Cutoff, unmatched totals, balanced/unbalanced match counts |
| `GET`    | `/api/v1/organizations/:id/transactions`              | `status`, `direction`, `query`, `after`, `before`, `min_amount`, `max_amount`, `include_before_cutoff`, `limit`, `offset` |
| `GET`    | `/api/v1/organizations/:id/transactions/:txn_id`      | One transaction, with the match it belongs to             |
| `GET`    | `/api/v1/organizations/:id/matches`                   | `status=all\|balanced\|unbalanced`                        |
| `POST`   | `/api/v1/organizations/:id/matches`                   | `incoming_ids`, `outgoing_ids`, `note`                    |
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
