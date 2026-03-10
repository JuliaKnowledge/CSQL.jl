# ─── Strongly Connected Components ───────────────────────────────────────────
# Pure-Julia implementation using Tarjan's algorithm (no external graph library)

"""
    compute_sccs(edges, nodes) -> Vector{SCCRecord}

Compute strongly connected components of the causal graph using Tarjan's algorithm.
Returns only SCCs with ≥2 nodes (true feedback loops).
"""
function compute_sccs(edges::Dict{Int64,EdgeRecord}, nodes::Dict{Int64,NodeRecord})
    # Build adjacency list
    adj = Dict{Int64, Vector{Int64}}()
    all_nodes = Set{Int64}()
    for e in values(edges)
        push!(get!(Vector{Int64}, adj, e.src_id), e.dst_id)
        push!(all_nodes, e.src_id)
        push!(all_nodes, e.dst_id)
    end

    # Tarjan's algorithm
    index_counter = Ref(0)
    stack = Int64[]
    on_stack = Set{Int64}()
    indices = Dict{Int64,Int}()
    lowlinks = Dict{Int64,Int}()
    sccs_raw = Vector{Vector{Int64}}()

    function strongconnect(v)
        indices[v] = index_counter[]
        lowlinks[v] = index_counter[]
        index_counter[] += 1
        push!(stack, v)
        push!(on_stack, v)

        for w in get(adj, v, Int64[])
            if !haskey(indices, w)
                strongconnect(w)
                lowlinks[v] = min(lowlinks[v], lowlinks[w])
            elseif w in on_stack
                lowlinks[v] = min(lowlinks[v], indices[w])
            end
        end

        if lowlinks[v] == indices[v]
            scc = Int64[]
            while true
                w = pop!(stack)
                delete!(on_stack, w)
                push!(scc, w)
                w == v && break
            end
            if length(scc) >= 2
                push!(sccs_raw, scc)
            end
        end
    end

    for v in all_nodes
        if !haskey(indices, v)
            strongconnect(v)
        end
    end

    # Convert to SCCRecords
    sccs = SCCRecord[]
    edge_set = Dict{Tuple{Int64,Int64}, Bool}()
    for e in values(edges)
        edge_set[(e.src_id, e.dst_id)] = true
    end

    for (i, scc_nodes) in enumerate(sccs_raw)
        node_set = Set(scc_nodes)
        n_edges = count(((s,d),) -> s in node_set && d in node_set, keys(edge_set))

        # Top nodes by degree
        node_degrees = [(nid, length(get(adj, nid, Int64[]))) for nid in scc_nodes]
        sort!(node_degrees, by=x->x[2], rev=true)
        top = [get(nodes, nid, nothing) for (nid,_) in first(node_degrees, 3)]
        top_labels = [n === nothing ? "?" : n.label_canon for n in top]

        push!(sccs, SCCRecord(i, length(scc_nodes), n_edges, 0, top_labels, scc_nodes))
    end

    sccs
end
