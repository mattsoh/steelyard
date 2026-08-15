module Mcp
  # What an MCP client can do with a Steelyard token. Each tool is a thin
  # binding over PublicApi::Operations -- the same operations the v1 REST API
  # exposes, so a tool can't quietly answer differently from the endpoint
  # beside it.
  #
  # Descriptions say *when* to reach for a tool, not just what it does: that is
  # what a model reads to decide, and vague descriptions are the usual reason a
  # tool goes unused (or gets used for the wrong thing).
  module Tools
    Tool = Struct.new(:name, :title, :description, :input_schema, :handler, keyword_init: true)

    ORGANIZATION_ID = {
      type: "string",
      description: "HCB organization id or slug, e.g. \"org_1a2b\" or \"hq-clearinghouse\". Get one from list_organizations."
    }.freeze

    ALL = [
      Tool.new(
        name: "list_organizations",
        title: "List organizations",
        description: "List the HCB organizations this token's owner belongs to, with their ids and slugs. " \
                     "Call this first when you don't already have an organization id for the other tools.",
        input_schema: { type: "object", properties: {}, additionalProperties: false },
        handler: ->(ops, _args) { { organizations: ops.organizations } }
      ),

      Tool.new(
        name: "get_reconciliation_summary",
        title: "Reconciliation summary",
        description: "Where one organization's reconciliation stands: the zero-balance cutoff date, how many " \
                     "transactions are still unmatched on each side and for how much, and how many confirmed " \
                     "matches balance versus don't. Call this before listing anything — it's one request and it " \
                     "tells you whether there is work to do at all.",
        input_schema: {
          type: "object",
          properties: { organization_id: ORGANIZATION_ID },
          required: [ "organization_id" ],
          additionalProperties: false
        },
        handler: ->(ops, args) { ops.summary(args["organization_id"]) }
      ),

      Tool.new(
        name: "list_transactions",
        title: "List transactions",
        description: "Search an organization's transactions. Defaults to the working set (everything after the " \
                     "zero-balance cutoff) since that's what the reconciliation is about. Use status=\"unmatched\" " \
                     "to find work to do, and the amount and date filters to hunt for the counterpart of a " \
                     "specific transaction — an incoming transfer is usually matched by one or more outgoing ones " \
                     "of the same total, close in time.",
        input_schema: {
          type: "object",
          properties: {
            organization_id: ORGANIZATION_ID,
            status: { type: "string", enum: %w[all unmatched matched], description: "Filter by whether the transaction is already part of a match. Default \"all\"." },
            direction: { type: "string", enum: %w[in out], description: "\"in\" for money received, \"out\" for money sent." },
            query: { type: "string", description: "Case-insensitive substring of the memo or the HCB code." },
            after: { type: "string", description: "Only transactions on or after this date (YYYY-MM-DD)." },
            before: { type: "string", description: "Only transactions on or before this date (YYYY-MM-DD)." },
            min_amount: { type: "number", description: "Minimum absolute amount in dollars — sign is ignored, so 250 matches both a $250 donation and a -$250 grant." },
            max_amount: { type: "number", description: "Maximum absolute amount in dollars." },
            include_before_cutoff: { type: "boolean", description: "Include settled history from before the cutoff. Default false." },
            limit: { type: "integer", description: "Maximum rows to return (default 50, max 500)." },
            offset: { type: "integer", description: "Rows to skip, for paging through `total`." }
          },
          required: [ "organization_id" ],
          additionalProperties: false
        },
        handler: ->(ops, args) {
          ops.transactions(
            args["organization_id"],
            status: args["status"] || "all",
            direction: args["direction"],
            query: args["query"],
            after: args["after"],
            before: args["before"],
            min_amount: args["min_amount"],
            max_amount: args["max_amount"],
            include_before_cutoff: args["include_before_cutoff"],
            limit: args["limit"],
            offset: args["offset"].to_i
          )
        }
      ),

      Tool.new(
        name: "get_transaction",
        title: "Get transaction",
        description: "Everything known about one transaction: amount, dates, memo, the reason the sender gave, " \
                     "who sent or received it, its category and status, and the match it belongs to if any. " \
                     "Call this when a row from list_transactions looks like a candidate and you need the detail " \
                     "to be sure.",
        input_schema: {
          type: "object",
          properties: {
            organization_id: ORGANIZATION_ID,
            transaction_id: { type: "string", description: "HCB transaction id, e.g. \"txn_1a2b\"." }
          },
          required: [ "organization_id", "transaction_id" ],
          additionalProperties: false
        },
        handler: ->(ops, args) { ops.transaction(args["organization_id"], args["transaction_id"]) }
      ),

      Tool.new(
        name: "list_matches",
        title: "List matches",
        description: "The confirmed matches, each with its legs spelled out and its current discrepancy. " \
                     "Use status=\"unbalanced\" to review the ones that don't add up — those are the matches " \
                     "someone needs to look at, either because a leg is missing or because HCB changed an " \
                     "amount after the match was made.",
        input_schema: {
          type: "object",
          properties: {
            organization_id: ORGANIZATION_ID,
            status: { type: "string", enum: %w[all balanced unbalanced], description: "Default \"all\"." },
            limit: { type: "integer", description: "Maximum matches to return (default 50, max 500)." },
            offset: { type: "integer", description: "Matches to skip, for paging through `total`." }
          },
          required: [ "organization_id" ],
          additionalProperties: false
        },
        handler: ->(ops, args) {
          ops.matches(args["organization_id"], status: args["status"] || "all", limit: args["limit"], offset: args["offset"].to_i)
        }
      ),

      Tool.new(
        name: "get_match",
        title: "Get match",
        description: "One match in full, with its change history: who made it, who has edited it since, what each " \
                     "of those edits did to the legs and the discrepancy, and which changes the app made on its own " \
                     "because HCB restated a transaction. Call this before undoing or re-doing somebody else's " \
                     "match — an unbalanced match that someone has already edited twice is usually a disagreement " \
                     "to read, not a mistake to correct. Works on undone matches too, which is how you find out what " \
                     "one used to pair.",
        input_schema: {
          type: "object",
          properties: {
            organization_id: ORGANIZATION_ID,
            match_id: { type: "integer", description: "Steelyard match id, from list_matches, create_match, or a transaction's match_id." }
          },
          required: [ "organization_id", "match_id" ],
          additionalProperties: false
        },
        handler: ->(ops, args) { ops.match(args["organization_id"], args["match_id"]) }
      ),

      Tool.new(
        name: "create_match",
        title: "Create match",
        description: "Record that these incoming transactions account for these outgoing ones — the same action " \
                     "as confirming a match in the Steelyard UI, attributed to this token's owner and visible to " \
                     "everyone else working on the organization. A match whose sides don't sum to zero is saved " \
                     "as a discrepancy rather than rejected, so check the totals before calling unless you mean " \
                     "to flag one. Requires the member or manager role; it can be reversed with undo_match.",
        input_schema: {
          type: "object",
          properties: {
            organization_id: ORGANIZATION_ID,
            incoming_ids: { type: "array", items: { type: "string" }, description: "Ids of the money-in transactions. May be empty, but not together with outgoing_ids." },
            outgoing_ids: { type: "array", items: { type: "string" }, description: "Ids of the money-out transactions." },
            note: { type: "string", description: "Optional note explaining the match, shown alongside it in the UI." }
          },
          required: [ "organization_id" ],
          additionalProperties: false
        },
        handler: ->(ops, args) {
          ops.create_match(
            args["organization_id"],
            incoming_ids: args["incoming_ids"],
            outgoing_ids: args["outgoing_ids"],
            note: args["note"]
          )
        }
      ),

      Tool.new(
        name: "undo_match",
        title: "Undo match",
        description: "Undo a match, freeing its transactions to be matched again. Use it to correct a match — " \
                     "including one somebody else made — by undoing it and creating the right one. Requires the " \
                     "member or manager role.",
        input_schema: {
          type: "object",
          properties: {
            organization_id: ORGANIZATION_ID,
            match_id: { type: "integer", description: "Steelyard match id, from list_matches or create_match." }
          },
          required: [ "organization_id", "match_id" ],
          additionalProperties: false
        },
        handler: ->(ops, args) { ops.undo_match(args["organization_id"], args["match_id"]) }
      )
    ].freeze

    BY_NAME = ALL.index_by(&:name).freeze

    # The wire shape of tools/list. `title` is a display name for clients that
    # show one; `name` stays the identifier a call is dispatched on.
    def self.definitions
      ALL.map do |tool|
        { name: tool.name, title: tool.title, description: tool.description, inputSchema: tool.input_schema }
      end
    end

    def self.find(name) = BY_NAME[name.to_s]
  end
end
