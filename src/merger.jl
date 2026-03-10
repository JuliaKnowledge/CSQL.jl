# ─── Atlas Merging ───────────────────────────────────────────────────────────

"""
    merge_atlases!(target::CSQLDatabase, sources::Vector{CSQLDatabase};
                   atlas_ids=nothing)

Merge multiple CSQL databases into a target database.
Edges are re-aggregated by edge_id. Provenance is preserved via atlas_id prefixing.
"""
function merge_atlases!(target::CSQLDatabase, sources::Vector{<:CSQLDatabase};
                        atlas_ids::Union{Nothing,Vector{String}}=nothing)
    create_schema!(target.db)

    # Collect all support rows, nodes, and edges from sources
    all_support = NamedTuple[]
    all_nodes = Dict{Int64,NamedTuple}()  # node_id → merged record
    all_edge_aggs = Dict{Int64,Dict{Symbol,Any}}()  # edge_id → aggregated fields

    for (i, src) in enumerate(sources)
        aid = atlas_ids !== nothing ? atlas_ids[i] : "atlas_$i"

        # Collect support rows
        support_rows = _query(src, "SELECT * FROM atlas_edge_support")
        for row in support_rows
            push!(all_support, merge(row, (atlas_id=aid,)))
        end

        # Collect nodes (merge label_examples)
        node_rows = _query(src, "SELECT * FROM atlas_nodes")
        for row in node_rows
            nid = row.node_id
            if haskey(all_nodes, nid)
                # Merge examples
                existing = all_nodes[nid]
                existing_examples = split(string(existing.label_examples), "; ")
                new_examples = split(string(row.label_examples), "; ")
                merged = unique(vcat(existing_examples, new_examples))
                all_nodes[nid] = merge(row, (label_examples=join(first(merged, 5), "; "),))
            else
                all_nodes[nid] = row
            end
        end

        # Collect and aggregate edges
        edge_rows = _query(src, "SELECT * FROM atlas_edges")
        for row in edge_rows
            eid = row.edge_id
            if haskey(all_edge_aggs, eid)
                agg = all_edge_aggs[eid]
                agg[:support_lcms] += row.support_lcms
                agg[:support_docs] += row.support_docs
                agg[:score_sum] += row.score_sum
                scores = agg[:_scores]
                push!(scores, row.score_sum)
                agg[:score_max] = max(agg[:score_max], row.score_max)
                agg[:pol_mass_inc] += row.pol_mass_inc
                agg[:pol_mass_dec] += row.pol_mass_dec
                agg[:pol_mass_unk] += row.pol_mass_unk
            else
                all_edge_aggs[eid] = Dict{Symbol,Any}(
                    :edge_id => row.edge_id,
                    :src_id => row.src_id,
                    :dst_id => row.dst_id,
                    :rel_type => row.rel_type,
                    :polarity => row.polarity,
                    :support_lcms => row.support_lcms,
                    :support_docs => row.support_docs,
                    :score_sum => row.score_sum,
                    :score_max => row.score_max,
                    :pol_mass_inc => row.pol_mass_inc,
                    :pol_mass_dec => row.pol_mass_dec,
                    :pol_mass_unk => row.pol_mass_unk,
                    :stage => row.stage,
                    :confidence => row.confidence,
                    :grounded => row.grounded,
                    :source_model => row.source_model,
                    :specificity => row.specificity,
                    :is_symmetric => row.is_symmetric,
                    :_scores => [row.score_sum],
                )
            end
        end
    end

    # Write merged data
    DBInterface.execute(target.db, "BEGIN TRANSACTION")
    try
        # Write nodes
        for node in values(all_nodes)
            DBInterface.execute(target.db,
                "INSERT OR REPLACE INTO atlas_nodes (node_id, label_canon, label_examples, deg_in, deg_out) VALUES (?,?,?,?,?)",
                (node.node_id, node.label_canon, node.label_examples, 0, 0))
        end

        # Write edges with re-aggregated fields
        for agg in values(all_edge_aggs)
            scores = agg[:_scores]
            score_mean = agg[:score_sum] / length(scores)
            total_pol = agg[:pol_mass_inc] + agg[:pol_mass_dec]
            controversy = total_pol > 0 ? min(agg[:pol_mass_inc], agg[:pol_mass_dec]) / (total_pol + 1e-9) : 0.0

            DBInterface.execute(target.db,
                """INSERT OR REPLACE INTO atlas_edges
                   (edge_id, src_id, dst_id, rel_type, polarity,
                    support_lcms, support_docs, score_sum, score_mean, score_max,
                    pol_mass_inc, pol_mass_dec, pol_mass_unk, controversy,
                    stage, confidence, grounded, source_model, specificity, is_symmetric)
                   VALUES (?,?,?,?,?, ?,?,?,?,?, ?,?,?,?, ?,?,?,?,?,?)""",
                (agg[:edge_id], agg[:src_id], agg[:dst_id], agg[:rel_type], agg[:polarity],
                 agg[:support_lcms], agg[:support_docs], agg[:score_sum], score_mean, agg[:score_max],
                 agg[:pol_mass_inc], agg[:pol_mass_dec], agg[:pol_mass_unk], controversy,
                 agg[:stage], agg[:confidence], agg[:grounded], agg[:source_model],
                 agg[:specificity], agg[:is_symmetric]))
        end

        # Write support rows
        for (i, row) in enumerate(all_support)
            DBInterface.execute(target.db,
                """INSERT INTO atlas_edge_support
                   (id, edge_id, doc_id, atlas_id, lcm_instance_id, score, score_raw, coupling)
                   VALUES (?,?,?,?,?,?,?,?)""",
                (i, row.edge_id, row.doc_id, row.atlas_id, row.lcm_instance_id,
                 row.score, row.score_raw, row.coupling))
        end

        # Recompute node degrees from merged edges
        DBInterface.execute(target.db, """
            UPDATE atlas_nodes SET deg_out = (
                SELECT COUNT(*) FROM atlas_edges WHERE src_id = atlas_nodes.node_id
            )
        """)
        DBInterface.execute(target.db, """
            UPDATE atlas_nodes SET deg_in = (
                SELECT COUNT(*) FROM atlas_edges WHERE dst_id = atlas_nodes.node_id
            )
        """)

        DBInterface.execute(target.db, "COMMIT")
    catch
        DBInterface.execute(target.db, "ROLLBACK")
        rethrow()
    end

    target
end
