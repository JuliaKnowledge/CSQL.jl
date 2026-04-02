# ─── Strongly Connected Components ───────────────────────────────────────────
# Pure-Julia iterative SCC implementation (no external graph library)

"""
    compute_sccs(edges, nodes) -> Vector{SCCRecord}

Compute strongly connected components of the causal graph without recursion.
Returns only SCCs with ≥2 nodes (true feedback loops).
"""
function compute_sccs(edges::Dict{Int64,EdgeRecord}, nodes::Dict{Int64,NodeRecord},
                      edge_doc_ids::AbstractDict{Int64,<:AbstractSet{String}}=Dict{Int64,Set{String}}())
    adj = Dict{Int64, Vector{Int64}}()
    rev_adj = Dict{Int64, Vector{Int64}}()
    all_nodes = Set{Int64}()
    for e in values(edges)
        push!(get!(Vector{Int64}, adj, e.src_id), e.dst_id)
        push!(get!(Vector{Int64}, rev_adj, e.dst_id), e.src_id)
        push!(all_nodes, e.src_id)
        push!(all_nodes, e.dst_id)
    end

    # First pass: iterative DFS to compute finishing order.
    visited = Set{Int64}()
    finish_order = Int64[]
    dfs_stack = Tuple{Int64,Bool}[]
    for v in all_nodes
        v in visited && continue
        push!(dfs_stack, (v, false))
        while !isempty(dfs_stack)
            current, expanded = pop!(dfs_stack)
            if expanded
                push!(finish_order, current)
                continue
            end
            current in visited && continue
            push!(visited, current)
            push!(dfs_stack, (current, true))
            for neighbor in Iterators.reverse(get(adj, current, Int64[]))
                neighbor in visited || push!(dfs_stack, (neighbor, false))
            end
        end
    end

    # Second pass on the reversed graph.
    assigned = Set{Int64}()
    sccs_raw = Vector{Vector{Int64}}()
    for v in Iterators.reverse(finish_order)
        v in assigned && continue
        component = Int64[]
        stack = [v]
        push!(assigned, v)
        while !isempty(stack)
            current = pop!(stack)
            push!(component, current)
            for neighbor in get(rev_adj, current, Int64[])
                if !(neighbor in assigned)
                    push!(assigned, neighbor)
                    push!(stack, neighbor)
                end
            end
        end
        length(component) >= 2 && push!(sccs_raw, component)
    end

    sccs = SCCRecord[]
    for (i, scc_nodes) in enumerate(sccs_raw)
        node_set = Set(scc_nodes)
        n_edges = count(e -> e.src_id in node_set && e.dst_id in node_set, values(edges))

        support_doc_ids = Set{String}()
        for e in values(edges)
            if e.src_id in node_set && e.dst_id in node_set
                union!(support_doc_ids, get(edge_doc_ids, e.edge_id, Set{String}()))
            end
        end

        node_degrees = [(nid, length(get(adj, nid, Int64[]))) for nid in scc_nodes]
        sort!(node_degrees, by=x -> x[2], rev=true)
        top = [get(nodes, nid, nothing) for (nid, _) in first(node_degrees, 3)]
        top_labels = [n === nothing ? "?" : n.label_canon for n in top]

        push!(sccs, SCCRecord(
            i,
            length(scc_nodes),
            n_edges,
            length(support_doc_ids),
            top_labels,
            scc_nodes,
        ))
    end

    sccs
end
