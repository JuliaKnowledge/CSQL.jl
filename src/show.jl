# ─── Pretty-printing for CSQL types ─────────────────────────────────────────

import Base: show

# ─── Helper: print a vector of NamedTuples as a table ────────────────────────

_fmt(x::AbstractFloat) = string(round(x; digits=4))
_fmt(x) = string(x)

"""Print a vector of NamedTuples as an aligned text table."""
function _show_table(io::IO, rows::Vector{<:NamedTuple})
    isempty(rows) && return print(io, "(empty)")
    cols = keys(first(rows))
    # Build string matrix: header + data
    header = [string(c) for c in cols]
    data = [[_fmt(getfield(r, c)) for c in cols] for r in rows]
    # Column widths
    widths = [max(length(header[j]), maximum(length(data[i][j]) for i in eachindex(data))) for j in eachindex(cols)]
    # Print header
    for (j, h) in enumerate(header)
        j > 1 && print(io, "  ")
        print(io, rpad(h, widths[j]))
    end
    println(io)
    # Separator
    for (j, _) in enumerate(cols)
        j > 1 && print(io, "  ")
        print(io, "─"^widths[j])
    end
    println(io)
    # Data rows
    for (i, row) in enumerate(data)
        for (j, s) in enumerate(row)
            j > 1 && print(io, "  ")
            print(io, rpad(s, widths[j]))
        end
        i < length(data) && println(io)
    end
end

# ─── CausalTriple ────────────────────────────────────────────────────────────

function show(io::IO, t::CausalTriple)
    print(io, "CausalTriple(\"", t.subject, "\" —[", t.relation, "]→ \"", t.object, "\")")
end

# ─── LocalCausalModel ────────────────────────────────────────────────────────

function show(io::IO, lcm::LocalCausalModel)
    n = length(lcm.triples)
    print(io, "LocalCausalModel(\"", lcm.lcm_id, "\", doc=\"", lcm.doc_id,
          "\", ", n, " triple", n == 1 ? "" : "s", ")")
end

function show(io::IO, ::MIME"text/plain", lcm::LocalCausalModel)
    n = length(lcm.triples)
    println(io, "LocalCausalModel")
    println(io, "  lcm_id: ", lcm.lcm_id)
    println(io, "  doc_id: ", lcm.doc_id)
    lcm.focus != "" && println(io, "  focus:  ", lcm.focus)
    println(io, "  score:  ", lcm.score)
    print(io, "  triples (", n, "):")
    for t in lcm.triples
        print(io, "\n    ", t.subject, " —[", t.relation, "]→ ", t.object)
    end
end

# ─── CSQLDatabase ─────────────────────────────────────────────────────────────

function show(io::IO, db::CSQLDatabase)
    backend = nameof(typeof(db.db))
    print(io, "CSQLDatabase(", backend, ")")
end

function show(io::IO, ::MIME"text/plain", db::CSQLDatabase)
    backend = nameof(typeof(db.db))
    print(io, "CSQLDatabase using ", backend)
    try
        n_nodes = only(_query(db, "SELECT COUNT(*) AS n FROM atlas_nodes")).n
        n_edges = only(_query(db, "SELECT COUNT(*) AS n FROM atlas_edges")).n
        print(io, " — ", n_nodes, " nodes, ", n_edges, " edges")
    catch
        # Tables might not exist yet
    end
end

# ─── AtlasBuilder ─────────────────────────────────────────────────────────────

function show(io::IO, b::AtlasBuilder)
    n = length(b.nodes)
    e = length(b.edges)
    print(io, "AtlasBuilder(", n, " nodes, ", e, " edges)")
end

function show(io::IO, ::MIME"text/plain", b::AtlasBuilder)
    n = length(b.nodes)
    e = length(b.edges)
    s = length(b.support_rows)
    println(io, "AtlasBuilder")
    println(io, "  nodes:   ", n)
    println(io, "  edges:   ", e)
    print(io,   "  support: ", s, " records")
end

# ─── NodeRecord ───────────────────────────────────────────────────────────────

function show(io::IO, n::NodeRecord)
    print(io, "NodeRecord(\"", n.label_canon, "\", in=", n.deg_in, ", out=", n.deg_out, ")")
end

# ─── EdgeRecord ───────────────────────────────────────────────────────────────

function show(io::IO, e::EdgeRecord)
    print(io, "EdgeRecord(", e.rel_type, ", score=", round(e.score_sum; digits=4),
          ", support=", e.support_lcms, ")")
end

# ─── EdgeSupportRecord ────────────────────────────────────────────────────────

function show(io::IO, s::EdgeSupportRecord)
    print(io, "EdgeSupportRecord(doc=\"", s.doc_id, "\", score=", round(s.score; digits=4), ")")
end

# ─── SCCRecord ────────────────────────────────────────────────────────────────

function show(io::IO, s::SCCRecord)
    print(io, "SCCRecord(", s.n_nodes, " nodes: ", join(s.top_nodes, ", "), ")")
end

# ─── CausalResult ────────────────────────────────────────────────────────────

function show(io::IO, ::MIME"text/plain", r::CausalResult)
    n = length(r.rows)
    if !isempty(r.label)
        println(io, r.label, " (", n, " row", n == 1 ? "" : "s", "):")
    else
        println(io, n, " row", n == 1 ? "" : "s", ":")
    end
    _show_table(io, r.rows)
end

function show(io::IO, r::CausalResult)
    _show_table(io, r.rows)
end
