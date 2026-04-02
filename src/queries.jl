# ─── CSQLDatabase wrapper + standard queries ────────────────────────────────

"""
    CSQLDatabase(db)

Wrapper around a DBInterface connection that provides causal query methods.
"""
struct CSQLDatabase{T}
    db::T
end

"""
    connect_csql(; backend=:sqlite, path="") -> CSQLDatabase

Connect to a CSQL database. Supported backends: `:sqlite` (default), `:duckdb`.
If path is empty, creates an in-memory database.
"""
function connect_csql(; backend::Symbol=:sqlite, path::String="")
    if backend == :sqlite
        db = isempty(path) ? SQLite.DB() : SQLite.DB(path)
    elseif backend == :duckdb
        db = isempty(path) ? DBInterface.connect(DuckDB.DB) : DBInterface.connect(DuckDB.DB, path)
    else
        error("Unsupported backend: $backend. Use :sqlite or :duckdb.")
    end
    create_schema!(db)
    CSQLDatabase(db)
end

# Legacy positional argument method
function connect_csql(path::String)
    connect_csql(; backend=:sqlite, path=path)
end

"""Execute a SQL query and return results as a vector of named tuples."""
function _query(csql::CSQLDatabase, sql::String, params=())
    result = DBInterface.execute(csql.db, sql, params)
    Tables.rowtable(result)
end

function _canonical_match(column::AbstractString, concept::AbstractString; exact::Bool=false)
    canon = canonicalize_label(concept)
    if exact
        return "$column = ?", canon
    end
    return "$column LIKE ?", "%" * canon * "%"
end

_real_or_zero(value) = value === nothing || ismissing(value) ? 0.0 : Float64(value)

# ─── Backbone ────────────────────────────────────────────────────────────────

"""
    backbone(csql; limit=20)

Extract the causal backbone: highest-scoring edges in the atlas.
"""
function backbone(csql::CSQLDatabase; limit::Int=20)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS src, e.rel_type, n2.label_canon AS dst,
               e.support_lcms, e.score_sum, e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        ORDER BY e.score_sum DESC
        LIMIT ?
    """, (limit,)))
end

# ─── Causal Hubs ─────────────────────────────────────────────────────────────

"""
    causal_hubs(csql; limit=10)

Identify the most influential causal concepts by outgoing score mass.
"""
function causal_hubs(csql::CSQLDatabase; limit::Int=10)
    CausalResult(_query(csql, """
        SELECT n.label_canon AS concept,
               SUM(e.score_sum) AS out_mass,
               COUNT(*) AS n_edges,
               n.deg_out, n.deg_in
        FROM atlas_edges e
        JOIN atlas_nodes n ON e.src_id = n.node_id
        GROUP BY n.node_id, n.label_canon, n.deg_out, n.deg_in
        ORDER BY out_mass DESC
        LIMIT ?
    """, (limit,)))
end

# ─── Effects Of ──────────────────────────────────────────────────────────────

"""
    effects_of(csql, concept; limit=20, exact=false)

Find downstream effects of a concept (outgoing edges from concept).
Use `exact=true` to match only the canonical concept label.
"""
function effects_of(csql::CSQLDatabase, concept::AbstractString; limit::Int=20, exact::Bool=false)
    predicate, param = _canonical_match("n1.label_canon", concept; exact=exact)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS src, e.rel_type, n2.label_canon AS dst,
               e.support_lcms, e.score_sum, e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        WHERE $predicate
        ORDER BY e.score_sum DESC
        LIMIT ?
    """, (param, limit)))
end

# ─── Causes Of ───────────────────────────────────────────────────────────────

"""
    causes_of(csql, concept; limit=20, exact=false)

Find upstream causes of a concept (incoming edges to concept).
Use `exact=true` to match only the canonical concept label.
"""
function causes_of(csql::CSQLDatabase, concept::AbstractString; limit::Int=20, exact::Bool=false)
    predicate, param = _canonical_match("n2.label_canon", concept; exact=exact)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS src, e.rel_type, n2.label_canon AS dst,
               e.support_lcms, e.score_sum, e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        WHERE $predicate
        ORDER BY e.score_sum DESC
        LIMIT ?
    """, (param, limit)))
end

# ─── Multi-hop Causal Paths ──────────────────────────────────────────────────

"""
    causal_paths(csql; depth=2, min_score=0.0, limit=20)

Find multi-hop causal chains of length `depth` via self-join.
For depth=2, returns paths A→B→C; for depth=3, A→B→C→D; and so on
for any positive integer depth ≥ 2.

Result columns use letter aliases for nodes (`a`, `b`, `c`, ...) and
numbered aliases for relations (`r1`, `r2`, ...), plus a `path_score`.

Results are ordered by `path_score` (sum of edge scores along the path)
and filtered so that every edge meets `min_score`.
"""
function causal_paths(csql::CSQLDatabase; depth::Int=2, min_score::Float64=0.0, limit::Int=20)
    depth >= 2 || error("causal_paths: depth must be ≥ 2 (got $depth)")

    # Preserve legacy a/b/c aliases for shallow paths and switch to valid
    # n27/n28/... aliases for deeper ones.
    node_alias(i) = i <= 26 ? string(Char('a' + i - 1)) : "n$i"

    select_parts = String[]
    for i in 1:depth
        push!(select_parts, "n$i.label_canon AS $(node_alias(i))")
        push!(select_parts, "e$i.rel_type AS r$i")
    end
    push!(select_parts, "n$(depth+1).label_canon AS $(node_alias(depth+1))")

    # Sum of edge scores
    score_expr = join(["e$i.score_sum" for i in 1:depth], " + ")
    push!(select_parts, "($score_expr) AS path_score")

    # Edge joins: e1, e2, ..., e_depth chained by dst_id = src_id
    edge_joins = ["atlas_edges e1"]
    for i in 2:depth
        push!(edge_joins, "JOIN atlas_edges e$i ON e$(i-1).dst_id = e$i.src_id")
    end

    # Node joins: n1 on e1.src_id, n2 on e1.dst_id, n3 on e2.dst_id, ...
    node_joins = [
        "JOIN atlas_nodes n1 ON e1.src_id = n1.node_id",
        "JOIN atlas_nodes n2 ON e1.dst_id = n2.node_id",
    ]
    for i in 2:depth
        push!(node_joins, "JOIN atlas_nodes n$(i+1) ON e$i.dst_id = n$(i+1).node_id")
    end

    # WHERE clause: each edge must meet min_score
    where_parts = ["e$i.score_sum >= ?" for i in 1:depth]

    sql = string(
        "SELECT ", join(select_parts, ", "), "\n",
        "FROM ", join(edge_joins, "\n"), "\n",
        join(node_joins, "\n"), "\n",
        "WHERE ", join(where_parts, " AND "), "\n",
        "ORDER BY path_score DESC\n",
        "LIMIT ?",
    )

    params = tuple(fill(min_score, depth)..., limit)
    CausalResult(_query(csql, sql, params))
end

# ─── Feedback Loops ──────────────────────────────────────────────────────────

"""
    feedback_loops(csql)

Detect 2-cycles (mutual influence) in the causal atlas.
"""
function feedback_loops(csql::CSQLDatabase)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS a, e1.rel_type AS r1,
               n2.label_canon AS b, e2.rel_type AS r2,
               (e1.score_sum + e2.score_sum) AS loop_score
        FROM atlas_edges e1
        JOIN atlas_edges e2 ON e1.src_id = e2.dst_id AND e1.dst_id = e2.src_id
        JOIN atlas_nodes n1 ON e1.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e1.dst_id = n2.node_id
        WHERE e1.src_id < e1.dst_id
        ORDER BY loop_score DESC
    """))
end

# ─── Controversial Claims ───────────────────────────────────────────────────

"""
    controversial_claims(csql; threshold=0.1, limit=20)

Find edges with mixed directional evidence (high controversy score).
"""
function controversial_claims(csql::CSQLDatabase; threshold::Float64=0.1, limit::Int=20)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS src, e.rel_type, n2.label_canon AS dst,
               e.controversy, e.pol_mass_inc, e.pol_mass_dec,
               e.support_lcms, e.score_sum
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        WHERE e.controversy > ?
        ORDER BY e.controversy DESC
        LIMIT ?
    """, (threshold, limit)))
end

# ─── Statistics ──────────────────────────────────────────────────────────────

"""
    statistics(csql) -> Dict

Return summary statistics of the causal atlas.
"""
function statistics(csql::CSQLDatabase)
    n_nodes = only(_query(csql, "SELECT COUNT(*) AS n FROM atlas_nodes")).n
    n_edges = only(_query(csql, "SELECT COUNT(*) AS n FROM atlas_edges")).n
    n_support = only(_query(csql, "SELECT COUNT(*) AS n FROM atlas_edge_support")).n

    score_stats = first(_query(csql, """
        SELECT MIN(score_sum) AS min_score, MAX(score_sum) AS max_score,
               AVG(score_sum) AS avg_score
        FROM atlas_edges
    """))

    rel_dist = _query(csql, """
        SELECT rel_type, COUNT(*) AS n, SUM(score_sum) AS total_mass
        FROM atlas_edges
        GROUP BY rel_type
        ORDER BY total_mass DESC
    """)

    Dict(
        :n_nodes => n_nodes,
        :n_edges => n_edges,
        :n_support => n_support,
        :min_score => _real_or_zero(score_stats.min_score),
        :max_score => _real_or_zero(score_stats.max_score),
        :avg_score => _real_or_zero(score_stats.avg_score),
        :relation_distribution => rel_dist,
    )
end

# ─── Custom Query ────────────────────────────────────────────────────────────

"""
    custom_query(csql, sql; params=())

Execute a custom SQL query against the CSQL database.
Use table names directly: atlas_nodes, atlas_edges, atlas_edge_support, atlas_scc.
"""
function custom_query(csql::CSQLDatabase, sql::AbstractString; params=())
    CausalResult(_query(csql, sql, params))
end
