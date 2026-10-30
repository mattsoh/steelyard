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

## Importing legacy matches

One-off import of the pre-Rails app's `matches.json` / `manual_transactions.json` / `ledger.json`
(dry run by default; see the task's `desc` for details):

```
bin/rails "migrate:legacy_matches[/path/to/legacy_source,<hcb_organization_id>,<local_user_id>]"
```
