# Steelyard

Multi-user tool for reconciling a Hack Club Clearinghouse-style HCB organization: pair incoming
donations with the outgoing transactions that account for them, and see what's still unmatched.
Reads organizations and ledgers live from the [HCB v4 API](https://github.com/hackclub/hcb)
(read-only, OAuth2); matches and their audit trail live in this app's Postgres.

Favicon made by [Candy][https://github.com/codingkatty]!

## Local setup

1. Ruby 3.4.9 (see `.ruby-version`), Postgres running locally.
2. `bundle install`
3. `bin/rails db:create db:migrate`
4. Register an OAuth application at <https://hcb.hackclub.com/api/v4/oauth/applications> with
   redirect URI `http://localhost:3000/auth/hcb/callback`.
5. `cp .env.example .env` and fill in `HCB_OAUTH_CLIENT_ID` / `HCB_OAUTH_CLIENT_SECRET`.
6. `bin/dev`, then open <http://localhost:3000> and log in with HCB.

## Secrets: where each thing lives

| Secret | Development | Production (Kamal) |
|---|---|---|
| HCB OAuth client id/secret | `.env` (gitignored; loaded by dotenv-rails) | `.kamal/secrets` → `env.secret` in `config/deploy.yml` |
| Active Record encryption keys | `config/credentials.yml.enc` (via `config/master.key`, gitignored) | same file, unlocked by `RAILS_MASTER_KEY` from `.kamal/secrets` |
| Database password | not needed (local socket auth) | `STEELYARD_DATABASE_PASSWORD`, exported in the deploying shell |

`.env` is never used in production — Kamal 2 injects env vars into the container from
`.kamal/secrets`, which is committed but only ever holds *references* (shell vars, `$(cat ...)`,
password-manager lookups), never raw values. The OAuth id/secret references in it read from your
local `.env` at deploy time, so there's exactly one place to put them.

Before first deploy: set real values for `image:`, `servers:`, `proxy.host:`, and
`HCB_OAUTH_REDIRECT_URI` in `config/deploy.yml` (the redirect URI must also be registered on the
HCB OAuth app), and export `KAMAL_REGISTRY_PASSWORD` / `STEELYARD_DATABASE_PASSWORD`.

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
