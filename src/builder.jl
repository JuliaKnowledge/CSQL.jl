# ─── Atlas Builder ───────────────────────────────────────────────────────────

"""
    AtlasBuilder(; min_edges=1, rel_whitelist=nothing, rel_blacklist=nothing)

Accumulates local causal models (LCMs) and builds a CSQL database.
"""
mutable struct AtlasBuilder
    min_edges::Int
    rel_whitelist::Union{Nothing, Set{RelationType}}
    rel_blacklist::Union{Nothing, Set{RelationType}}

    # Internal accumulators
    nodes::Dict{Int64, NodeRecord}
    edges::Dict{Int64, EdgeRecord}
    support_rows::Vector{EdgeSupportRecord}
    doc_tracker::Dict{Int64, Set{String}}  # edge_id → set of doc_ids
    score_tracker::Dict{Int64, Vector{Float64}}  # edge_id → scores

    function AtlasBuilder(; min_edges=1, rel_whitelist=nothing, rel_blacklist=nothing)
        new(
            min_edges,
            rel_whitelist === nothing ? nothing : Set{RelationType}(rel_whitelist),
            rel_blacklist === nothing ? nothing : Set{RelationType}(rel_blacklist),
            Dict{Int64,NodeRecord}(),
            Dict{Int64,EdgeRecord}(),
            EdgeSupportRecord[],
            Dict{Int64,Set{String}}(),
            Dict{Int64,Vector{Float64}}(),
        )
    end
end

"""Reset the builder, clearing all accumulated data."""
function reset!(builder::AtlasBuilder)
    empty!(builder.nodes)
    empty!(builder.edges)
    empty!(builder.support_rows)
    empty!(builder.doc_tracker)
    empty!(builder.score_tracker)
    builder
end

function _finalize_edge_metrics!(edges::Dict{Int64,EdgeRecord},
                                 doc_tracker::AbstractDict{Int64,<:AbstractSet{String}},
                                 score_tracker::AbstractDict{Int64,<:AbstractVector{<:Real}})
    for (eid, edge) in edges
        docs = get(doc_tracker, eid, nothing)
        scores = get(score_tracker, eid, nothing)

        edge.support_docs = docs === nothing ? 0 : length(docs)
        if scores !== nothing && !isempty(scores)
            edge.support_lcms = length(scores)
            edge.score_sum = sum(scores)
            edge.score_mean = edge.score_sum / length(scores)
            edge.score_max = maximum(scores)
        else
            edge.support_lcms = 0
            edge.score_sum = 0.0
            edge.score_mean = 0.0
            edge.score_max = 0.0
        end

        total_pol = edge.pol_mass_inc + edge.pol_mass_dec
        edge.controversy = total_pol > 0 ? min(edge.pol_mass_inc, edge.pol_mass_dec) / (total_pol + 1e-9) : 0.0
    end
end

function _recompute_node_degrees!(nodes::Dict{Int64,NodeRecord}, edges::Dict{Int64,EdgeRecord})
    for node in values(nodes)
        node.deg_in = 0
        node.deg_out = 0
    end
    for edge in values(edges)
        if haskey(nodes, edge.src_id)
            nodes[edge.src_id].deg_out += 1
        end
        if haskey(nodes, edge.dst_id)
            nodes[edge.dst_id].deg_in += 1
        end
    end
end

"""
    add_triple!(builder, subject, relation, object;
                doc_id="default", lcm_id="default", score=1.0,
                stage="original", confidence=1.0, grounded="not_evaluated",
                source_model="unknown", specificity=0.0, coupling=1.0)

Add a single causal triple to the builder.
"""
function add_triple!(builder::AtlasBuilder, subject::AbstractString,
                     relation::AbstractString, object::AbstractString;
                     doc_id::String="default", lcm_id::String="default",
                     score::Float64=1.0, score_raw::Float64=score,
                     stage::String="original", confidence::Float64=1.0,
                     grounded::String="not_evaluated",
                     source_model::String="unknown",
                     specificity::Float64=0.0, coupling::Float64=1.0)
    # Canonicalize
    src_canon = canonicalize_label(subject)
    dst_canon = canonicalize_label(object)
    isempty(src_canon) && return
    isempty(dst_canon) && return
    src_canon == dst_canon && return  # skip self-loops

    src_id = compute_node_id(src_canon)
    dst_id = compute_node_id(dst_canon)
    rel_type, polarity = normalize_relation(relation)

    # Apply filters
    if builder.rel_whitelist !== nothing && !(rel_type in builder.rel_whitelist)
        return
    end
    if builder.rel_blacklist !== nothing && rel_type in builder.rel_blacklist
        return
    end

    # For symmetric relations, use canonical direction
    if is_symmetric(rel_type) && dst_id < src_id
        src_id, dst_id = dst_id, src_id
        src_canon, dst_canon = dst_canon, src_canon
    end

    edge_id = compute_edge_id(src_id, rel_type, dst_id)

    # Update node
    _update_node!(builder, src_id, src_canon, subject)
    _update_node!(builder, dst_id, dst_canon, object)

    # Update edge
    _update_edge!(builder, edge_id, src_id, dst_id, rel_type, polarity,
                  score, stage, confidence, grounded, source_model, specificity)

    # Track doc
    doc_set = get!(Set{String}, builder.doc_tracker, edge_id)
    push!(doc_set, doc_id)

    # Track scores
    scores = get!(Vector{Float64}, builder.score_tracker, edge_id)
    push!(scores, score)

    # Add support record
    push!(builder.support_rows, EdgeSupportRecord(
        edge_id, doc_id, "", lcm_id, score, score_raw, coupling
    ))

    nothing
end

"""
    add_lcm!(builder, lcm::LocalCausalModel)

Add all triples from a local causal model to the builder.
"""
function add_lcm!(builder::AtlasBuilder, lcm::LocalCausalModel)
    length(lcm.triples) < builder.min_edges && return
    for triple in lcm.triples
        add_triple!(builder, triple.subject, triple.relation, triple.object;
                    doc_id=lcm.doc_id, lcm_id=lcm.lcm_id, score=lcm.score,
                    stage=get(lcm.metadata, "stage", "original"),
                    confidence=get(lcm.metadata, "confidence", 1.0),
                    grounded=get(lcm.metadata, "grounded", "not_evaluated"),
                    source_model=get(lcm.metadata, "source_model", "unknown"),
                    specificity=get(lcm.metadata, "specificity", 0.0))
    end
    nothing
end

function _update_node!(builder::AtlasBuilder, node_id::Int64,
                       canon::String, original::AbstractString)
    if haskey(builder.nodes, node_id)
        node = builder.nodes[node_id]
        if length(node.label_examples) < 5 && !(original in node.label_examples)
            push!(node.label_examples, string(original))
        end
    else
        builder.nodes[node_id] = NodeRecord(node_id, canon, [string(original)], 0, 0)
    end
end

function _update_edge!(builder::AtlasBuilder, edge_id::Int64,
                       src_id::Int64, dst_id::Int64,
                       rel_type::RelationType, polarity::Polarity,
                       score::Float64, stage::String, confidence::Float64,
                       grounded::String, source_model::String, specificity::Float64)
    if haskey(builder.edges, edge_id)
        e = builder.edges[edge_id]
        e.support_lcms += 1
        e.score_sum += score
        if polarity == INCREASE
            e.pol_mass_inc += score
        elseif polarity == DECREASE
            e.pol_mass_dec += score
        else
            e.pol_mass_unk += score
        end
    else
        builder.edges[edge_id] = EdgeRecord(
            edge_id, src_id, dst_id, rel_type, polarity,
            1, 0,                    # support_lcms, support_docs (computed at build)
            score, 0.0, score,       # score_sum, score_mean, score_max
            polarity == INCREASE ? score : 0.0,
            polarity == DECREASE ? score : 0.0,
            polarity == UNKNOWN_POL ? score : 0.0,
            0.0,                     # controversy (computed at build)
            stage, confidence, grounded, source_model, specificity,
            is_symmetric(rel_type),
        )
    end
end

"""
    build!(builder, db) -> db

Finalize the atlas and overwrite the target atlas tables in `db`.
"""
function build!(builder::AtlasBuilder, db)
    create_schema!(db)

    _finalize_edge_metrics!(builder.edges, builder.doc_tracker, builder.score_tracker)
    _recompute_node_degrees!(builder.nodes, builder.edges)

    # Write to database inside a transaction
    DBInterface.execute(db, "BEGIN TRANSACTION")
    try
        _clear_atlas_tables!(db)
        _write_nodes!(db, builder.nodes)
        _write_edges!(db, builder.edges)
        _write_support!(db, builder.support_rows)
        _write_sccs!(db, builder.edges, builder.nodes, builder.doc_tracker)
        DBInterface.execute(db, "COMMIT")
    catch
        DBInterface.execute(db, "ROLLBACK")
        rethrow()
    end

    db
end

function _write_nodes!(db, nodes::Dict{Int64,NodeRecord})
    stmt = DBInterface.prepare(db,
        "INSERT OR REPLACE INTO atlas_nodes (node_id, label_canon, label_examples, deg_in, deg_out) VALUES (?, ?, ?, ?, ?)")
    for node in values(nodes)
        DBInterface.execute(stmt, (
            node.node_id, node.label_canon,
            join(node.label_examples, "; "),
            node.deg_in, node.deg_out
        ))
    end
    DBInterface.close!(stmt)
end

function _write_edges!(db, edges::Dict{Int64,EdgeRecord})
    stmt = DBInterface.prepare(db,
        """INSERT OR REPLACE INTO atlas_edges
           (edge_id, src_id, dst_id, rel_type, polarity,
            support_lcms, support_docs, score_sum, score_mean, score_max,
            pol_mass_inc, pol_mass_dec, pol_mass_unk, controversy,
            stage, confidence, grounded, source_model, specificity, is_symmetric)
           VALUES (?,?,?,?,?, ?,?,?,?,?, ?,?,?,?, ?,?,?,?,?,?)""")
    for e in values(edges)
        DBInterface.execute(stmt, (
            e.edge_id, e.src_id, e.dst_id, reltype_str(e.rel_type), polarity_str(e.polarity),
            e.support_lcms, e.support_docs, e.score_sum, e.score_mean, e.score_max,
            e.pol_mass_inc, e.pol_mass_dec, e.pol_mass_unk, e.controversy,
            e.stage, e.confidence, e.grounded, e.source_model, e.specificity,
            e.is_symmetric ? 1 : 0,
        ))
    end
    DBInterface.close!(stmt)
end

function _write_support!(db, rows::Vector{EdgeSupportRecord})
    stmt = DBInterface.prepare(db,
        """INSERT INTO atlas_edge_support
           (id, edge_id, doc_id, atlas_id, lcm_instance_id, score, score_raw, coupling)
           VALUES (?,?,?,?,?,?,?,?)""")
    for (i, r) in enumerate(rows)
        DBInterface.execute(stmt, (
            i, r.edge_id, r.doc_id, r.atlas_id, r.lcm_instance_id,
            r.score, r.score_raw, r.coupling
        ))
    end
    DBInterface.close!(stmt)
end

function _write_sccs!(db, edges::Dict{Int64,EdgeRecord}, nodes::Dict{Int64,NodeRecord},
                      edge_doc_ids::AbstractDict{Int64,<:AbstractSet{String}}=Dict{Int64,Set{String}}())
    sccs = compute_sccs(edges, nodes, edge_doc_ids)
    isempty(sccs) && return
    stmt = DBInterface.prepare(db,
        "INSERT OR REPLACE INTO atlas_scc (scc_id, n_nodes, n_edges, support_docs, top_nodes, node_ids) VALUES (?,?,?,?,?,?)")
    for scc in sccs
        DBInterface.execute(stmt, (
            scc.scc_id, scc.n_nodes, scc.n_edges, scc.support_docs,
            join(scc.top_nodes, "; "),
            join(string.(scc.node_ids), ","),
        ))
    end
    DBInterface.close!(stmt)
end
