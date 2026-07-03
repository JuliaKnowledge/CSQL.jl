# ─── Atlas Merging ───────────────────────────────────────────────────────────

"""
    merge_atlases!(target::CSQLDatabase, sources::Vector{CSQLDatabase};
                   atlas_ids=nothing)

Merge multiple CSQL databases into a target database. Edges are re-aggregated
by `edge_id`, target atlas tables are overwritten, and provenance is preserved
via `atlas_id`.
"""
function merge_atlases!(target::CSQLDatabase, sources::Vector{<:CSQLDatabase};
                        atlas_ids::Union{Nothing,Vector{String}}=nothing)
    create_schema!(target.db)

    all_support = EdgeSupportRecord[]
    all_nodes = Dict{Int64,NamedTuple}()
    all_edge_aggs = Dict{Int64,Dict{Symbol,Any}}()
    doc_tracker = Dict{Int64,Set{String}}()
    lcm_tracker = Dict{Int64,Set{Tuple{String,String}}}()
    score_tracker = Dict{Int64,Vector{Float64}}()

    for (i, src) in enumerate(sources)
        aid = atlas_ids !== nothing ? atlas_ids[i] : "atlas_$i"

        support_rows = _query(src, "SELECT * FROM atlas_edge_support")
        for row in support_rows
            push!(all_support, EdgeSupportRecord(
                row.edge_id, row.doc_id, aid, row.lcm_instance_id,
                hasproperty(row, :domain) ? string(row.domain) : "",
                hasproperty(row, :source_text) ? string(row.source_text) : "",
                Float64(row.score), Float64(row.score_raw), Float64(row.coupling),
            ))
            push!(get!(Set{String}, doc_tracker, row.edge_id), row.doc_id)
            push!(get!(Set{Tuple{String,String}}, lcm_tracker, row.edge_id), (aid, string(row.lcm_instance_id)))
            push!(get!(Vector{Float64}, score_tracker, row.edge_id), Float64(row.score))
        end

        node_rows = _query(src, "SELECT * FROM atlas_nodes")
        for row in node_rows
            nid = row.node_id
            if haskey(all_nodes, nid)
                existing = all_nodes[nid]
                existing_examples = _split_examples(existing.label_examples)
                new_examples = _split_examples(row.label_examples)
                merged = unique(vcat(existing_examples, new_examples))
                all_nodes[nid] = merge(row, (label_examples=join(first(merged, min(length(merged), 5)), "; "),))
            else
                all_nodes[nid] = row
            end
        end

        edge_rows = _query(src, "SELECT * FROM atlas_edges")
        for row in edge_rows
            eid = row.edge_id
            if haskey(all_edge_aggs, eid)
                agg = all_edge_aggs[eid]
                agg[:pol_mass_inc] += Float64(row.pol_mass_inc)
                agg[:pol_mass_dec] += Float64(row.pol_mass_dec)
                agg[:pol_mass_unk] += Float64(row.pol_mass_unk)
                agg[:confidence] = max(agg[:confidence], Float64(row.confidence))
                agg[:specificity] = max(agg[:specificity], Float64(row.specificity))
            else
                all_edge_aggs[eid] = Dict{Symbol,Any}(
                    :edge_id => row.edge_id,
                    :src_id => row.src_id,
                    :dst_id => row.dst_id,
                    :rel_type => row.rel_type,
                    :polarity => row.polarity,
                    :pol_mass_inc => Float64(row.pol_mass_inc),
                    :pol_mass_dec => Float64(row.pol_mass_dec),
                    :pol_mass_unk => Float64(row.pol_mass_unk),
                    :stage => row.stage,
                    :confidence => Float64(row.confidence),
                    :grounded => row.grounded,
                    :source_model => row.source_model,
                    :specificity => Float64(row.specificity),
                    :is_symmetric => row.is_symmetric,
                )
            end
        end
    end

    merged_nodes = Dict{Int64,NodeRecord}()
    for node in values(all_nodes)
        merged_nodes[node.node_id] = NodeRecord(
            node.node_id,
            node.label_canon,
            _split_examples(node.label_examples),
            0,
            0,
        )
    end

    merged_edges = Dict{Int64,EdgeRecord}()
    for agg in values(all_edge_aggs)
        eid = agg[:edge_id]
        scores = get(score_tracker, eid, Float64[])
        score_sum = sum(scores)
        score_mean = isempty(scores) ? 0.0 : score_sum / length(scores)
        score_max = isempty(scores) ? 0.0 : maximum(scores)
        total_pol = agg[:pol_mass_inc] + agg[:pol_mass_dec]
        controversy = total_pol > 0 ? min(agg[:pol_mass_inc], agg[:pol_mass_dec]) / (total_pol + 1e-9) : 0.0

        merged_edges[eid] = EdgeRecord(
            agg[:edge_id],
            agg[:src_id],
            agg[:dst_id],
            _as_relation_type(agg[:rel_type]),
            dominant_polarity(agg[:pol_mass_inc], agg[:pol_mass_dec], agg[:pol_mass_unk]),
            length(get(lcm_tracker, eid, Set{Tuple{String,String}}())),
            length(get(doc_tracker, eid, Set{String}())),
            score_sum,
            score_mean,
            score_max,
            agg[:pol_mass_inc],
            agg[:pol_mass_dec],
            agg[:pol_mass_unk],
            controversy,
            agg[:stage],
            agg[:confidence],
            agg[:grounded],
            agg[:source_model],
            agg[:specificity],
            Bool(agg[:is_symmetric]),
        )
    end

    _recompute_node_degrees!(merged_nodes, merged_edges)

    DBInterface.execute(target.db, "BEGIN TRANSACTION")
    try
        _clear_atlas_tables!(target.db)
        _write_nodes!(target.db, merged_nodes)
        _write_edges!(target.db, merged_edges)
        _write_support!(target.db, all_support)
        _write_sccs!(target.db, merged_edges, merged_nodes, doc_tracker)
        DBInterface.execute(target.db, "COMMIT")
    catch
        DBInterface.execute(target.db, "ROLLBACK")
        rethrow()
    end

    target
end

_split_examples(value) = isempty(string(value)) ? String[] : filter(!isempty, split(string(value), "; "))
_as_relation_type(value::RelationType) = value
_as_relation_type(value) = getfield(@__MODULE__, Symbol(value))
_as_polarity(value::Polarity) = value
_as_polarity(value) = value == "inc" ? INCREASE : value == "dec" ? DECREASE : UNKNOWN_POL
