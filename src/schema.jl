# ─── Database schema ─────────────────────────────────────────────────────────

# Backend-specific type mappings
_int_type(::Type{<:SQLite.DB}) = "INTEGER"
_int_type(::Any) = "BIGINT"

_real_type(::Type{<:SQLite.DB}) = "REAL"
_real_type(::Any) = "DOUBLE"

_autoincrement_col(::Type{<:SQLite.DB}) = "id INTEGER PRIMARY KEY AUTOINCREMENT"
_autoincrement_col(::Any) = "id BIGINT PRIMARY KEY"

function _schema_sql(db)
    IT = _int_type(typeof(db))
    RT = _real_type(typeof(db))
    id_col = _autoincrement_col(typeof(db))
    [
"""CREATE TABLE IF NOT EXISTS atlas_nodes (
    node_id   $IT PRIMARY KEY,
    label_canon TEXT NOT NULL,
    label_examples TEXT DEFAULT '',
    deg_in    INTEGER DEFAULT 0,
    deg_out   INTEGER DEFAULT 0
)""",

"""CREATE TABLE IF NOT EXISTS atlas_edges (
    edge_id       $IT PRIMARY KEY,
    src_id        $IT NOT NULL,
    dst_id        $IT NOT NULL,
    rel_type      TEXT NOT NULL,
    polarity      TEXT NOT NULL,
    support_lcms  INTEGER DEFAULT 0,
    support_docs  INTEGER DEFAULT 0,
    score_sum     $RT DEFAULT 0.0,
    score_mean    $RT DEFAULT 0.0,
    score_max     $RT DEFAULT 0.0,
    pol_mass_inc  $RT DEFAULT 0.0,
    pol_mass_dec  $RT DEFAULT 0.0,
    pol_mass_unk  $RT DEFAULT 0.0,
    controversy   $RT DEFAULT 0.0,
    stage         TEXT DEFAULT 'original',
    confidence    $RT DEFAULT 1.0,
    grounded      TEXT DEFAULT 'not_evaluated',
    source_model  TEXT DEFAULT 'unknown',
    specificity   $RT DEFAULT 0.0,
    is_symmetric  INTEGER DEFAULT 0
)""",

"""CREATE TABLE IF NOT EXISTS atlas_edge_support (
    $id_col,
    edge_id         $IT NOT NULL,
    doc_id          TEXT NOT NULL,
    atlas_id        TEXT DEFAULT '',
    lcm_instance_id TEXT NOT NULL,
    domain          TEXT DEFAULT '',
    source_text     TEXT DEFAULT '',
    score           $RT DEFAULT 1.0,
    score_raw       $RT DEFAULT 1.0,
    coupling        $RT DEFAULT 1.0
)""",

"""CREATE TABLE IF NOT EXISTS atlas_scc (
    scc_id      INTEGER PRIMARY KEY,
    n_nodes     INTEGER DEFAULT 0,
    n_edges     INTEGER DEFAULT 0,
    support_docs INTEGER DEFAULT 0,
    top_nodes   TEXT DEFAULT '',
    node_ids    TEXT DEFAULT ''
)""",
    ]
end

const INDEX_SQL = [
    "CREATE INDEX IF NOT EXISTS idx_edges_src ON atlas_edges(src_id)",
    "CREATE INDEX IF NOT EXISTS idx_edges_dst ON atlas_edges(dst_id)",
    "CREATE INDEX IF NOT EXISTS idx_edges_rel ON atlas_edges(rel_type)",
    "CREATE INDEX IF NOT EXISTS idx_edges_score ON atlas_edges(score_sum)",
    "CREATE INDEX IF NOT EXISTS idx_edges_src_score ON atlas_edges(src_id, score_sum DESC)",
    "CREATE INDEX IF NOT EXISTS idx_edges_dst_score ON atlas_edges(dst_id, score_sum DESC)",
    "CREATE INDEX IF NOT EXISTS idx_edges_src_dst ON atlas_edges(src_id, dst_id)",
    "CREATE INDEX IF NOT EXISTS idx_support_edge ON atlas_edge_support(edge_id)",
    "CREATE INDEX IF NOT EXISTS idx_support_doc ON atlas_edge_support(doc_id)",
    "CREATE INDEX IF NOT EXISTS idx_support_edge_doc_lcm ON atlas_edge_support(edge_id, doc_id, lcm_instance_id)",
    "CREATE INDEX IF NOT EXISTS idx_nodes_label ON atlas_nodes(label_canon)",
]

const TABLE_CLEAR_ORDER = [
    "atlas_edge_support",
    "atlas_scc",
    "atlas_edges",
    "atlas_nodes",
]

"""
    create_schema!(db)

Create the CSQL tables and indices in a database connection.
"""
function create_schema!(db)
    for sql in _schema_sql(db)
        DBInterface.execute(db, sql)
    end
    for sql in INDEX_SQL
        DBInterface.execute(db, sql)
    end
    db
end

function _clear_atlas_tables!(db)
    for table in TABLE_CLEAR_ORDER
        DBInterface.execute(db, "DELETE FROM $table")
    end
    db
end
