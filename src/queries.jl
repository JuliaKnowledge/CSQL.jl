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

# ─── Backbone ────────────────────────────────────────────────────────────────

"""
    backbone(csql; limit=20)

Extract the causal backbone: highest-scoring edges in the atlas.
"""
function backbone(csql::CSQLDatabase; limit::Int=20)
    _query(csql, """
        SELECT e.rel_type, n1.label_canon AS src, n2.label_canon AS dst,
               e.support_lcms, e.score_sum, e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        ORDER BY e.score_sum DESC
        LIMIT ?
    """, (limit,))
end

# ─── Causal Hubs ─────────────────────────────────────────────────────────────

"""
    causal_hubs(csql; limit=10)

Identify the most influential causal concepts by outgoing score mass.
"""
function causal_hubs(csql::CSQLDatabase; limit::Int=10)
    _query(csql, """
        SELECT n.label_canon AS concept,
               SUM(e.score_sum) AS out_mass,
               COUNT(*) AS n_edges,
               n.deg_out, n.deg_in
        FROM atlas_edges e
        JOIN atlas_nodes n ON e.src_id = n.node_id
        GROUP BY n.node_id, n.label_canon, n.deg_out, n.deg_in
        ORDER BY out_mass DESC
        LIMIT ?
    """, (limit,))
end

# ─── Effects Of ──────────────────────────────────────────────────────────────

"""
    effects_of(csql, concept; limit=20)

Find downstream effects of a concept (outgoing edges from concept).
"""
function effects_of(csql::CSQLDatabase, concept::AbstractString; limit::Int=20)
    _query(csql, """
        SELECT e.rel_type, n1.label_canon AS src, n2.label_canon AS dst,
               e.support_lcms, e.score_sum, e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        WHERE LOWER(n1.label_canon) LIKE ?
        ORDER BY e.score_sum DESC
        LIMIT ?
    """, ("%" * lowercase(concept) * "%", limit))
end

# ─── Causes Of ───────────────────────────────────────────────────────────────

"""
    causes_of(csql, concept; limit=20)

Find upstream causes of a concept (incoming edges to concept).
"""
function causes_of(csql::CSQLDatabase, concept::AbstractString; limit::Int=20)
    _query(csql, """
        SELECT e.rel_type, n1.label_canon AS src, n2.label_canon AS dst,
               e.support_lcms, e.score_sum, e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        WHERE LOWER(n2.label_canon) LIKE ?
        ORDER BY e.score_sum DESC
        LIMIT ?
    """, ("%" * lowercase(concept) * "%", limit))
end

# ─── Multi-hop Causal Paths ──────────────────────────────────────────────────

"""
    causal_paths(csql; depth=2, min_score=0.0, limit=20)

Find multi-hop causal chains via self-join. Currently supports depth=2 (A→B→C).
"""
function causal_paths(csql::CSQLDatabase; depth::Int=2, min_score::Float64=0.0, limit::Int=20)
    if depth == 2
        _query(csql, """
            SELECT n1.label_canon AS a, e1.rel_type AS r1,
                   n2.label_canon AS b, e2.rel_type AS r2,
                   n3.label_canon AS c,
                   (e1.score_sum + e2.score_sum) AS path_score
            FROM atlas_edges e1
            JOIN atlas_edges e2 ON e1.dst_id = e2.src_id
            JOIN atlas_nodes n1 ON e1.src_id = n1.node_id
            JOIN atlas_nodes n2 ON e1.dst_id = n2.node_id
            JOIN atlas_nodes n3 ON e2.dst_id = n3.node_id
            WHERE e1.score_sum >= ? AND e2.score_sum >= ?
            ORDER BY path_score DESC
            LIMIT ?
        """, (min_score, min_score, limit))
    elseif depth == 3
        _query(csql, """
            SELECT n1.label_canon AS a, e1.rel_type AS r1,
                   n2.label_canon AS b, e2.rel_type AS r2,
                   n3.label_canon AS c, e3.rel_type AS r3,
                   n4.label_canon AS d,
                   (e1.score_sum + e2.score_sum + e3.score_sum) AS path_score
            FROM atlas_edges e1
            JOIN atlas_edges e2 ON e1.dst_id = e2.src_id
            JOIN atlas_edges e3 ON e2.dst_id = e3.src_id
            JOIN atlas_nodes n1 ON e1.src_id = n1.node_id
            JOIN atlas_nodes n2 ON e1.dst_id = n2.node_id
            JOIN atlas_nodes n3 ON e2.dst_id = n3.node_id
            JOIN atlas_nodes n4 ON e3.dst_id = n4.node_id
            WHERE e1.score_sum >= ? AND e2.score_sum >= ? AND e3.score_sum >= ?
            ORDER BY path_score DESC
            LIMIT ?
        """, (min_score, min_score, min_score, limit))
    else
        error("causal_paths: depth must be 2 or 3 (got $depth)")
    end
end

# ─── Feedback Loops ──────────────────────────────────────────────────────────

"""
    feedback_loops(csql)

Detect 2-cycles (mutual influence) in the causal atlas.
"""
function feedback_loops(csql::CSQLDatabase)
    _query(csql, """
        SELECT n1.label_canon AS a, e1.rel_type AS r1,
               n2.label_canon AS b, e2.rel_type AS r2,
               (e1.score_sum + e2.score_sum) AS loop_score
        FROM atlas_edges e1
        JOIN atlas_edges e2 ON e1.src_id = e2.dst_id AND e1.dst_id = e2.src_id
        JOIN atlas_nodes n1 ON e1.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e1.dst_id = n2.node_id
        WHERE e1.src_id < e1.dst_id
        ORDER BY loop_score DESC
    """)
end

# ─── Controversial Claims ───────────────────────────────────────────────────

"""
    controversial_claims(csql; threshold=0.1, limit=20)

Find edges with mixed directional evidence (high controversy score).
"""
function controversial_claims(csql::CSQLDatabase; threshold::Float64=0.1, limit::Int=20)
    _query(csql, """
        SELECT e.rel_type, n1.label_canon AS src, n2.label_canon AS dst,
               e.controversy, e.pol_mass_inc, e.pol_mass_dec,
               e.support_lcms, e.score_sum
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        WHERE e.controversy > ?
        ORDER BY e.controversy DESC
        LIMIT ?
    """, (threshold, limit))
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
        :min_score => score_stats.min_score,
        :max_score => score_stats.max_score,
        :avg_score => score_stats.avg_score,
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
    _query(csql, sql, params)
end
