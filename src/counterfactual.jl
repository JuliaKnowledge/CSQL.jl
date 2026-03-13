# ─── Counterfactual / intervention operations ────────────────────────────────

"""
    do_cut(csql, concept; limit=20)

Hard intervention: remove all outgoing edges from a concept.
Returns the backbone of the atlas *after* the intervention.
This implements Pearl's do-operator as a SQL view rewrite.
"""
function do_cut(csql::CSQLDatabase, concept::AbstractString; limit::Int=20)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS src, e.rel_type, n2.label_canon AS dst,
               e.support_lcms, e.score_sum, e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        WHERE LOWER(n1.label_canon) NOT LIKE ?
        ORDER BY e.score_sum DESC
        LIMIT ?
    """, ("%" * lowercase(concept) * "%", limit)))
end

"""
    soft_do(csql, concept; attenuation=0.2, limit=20)

Soft intervention: attenuate (reduce) outgoing score mass from a concept.
Returns the backbone with adjusted scores.
"""
function soft_do(csql::CSQLDatabase, concept::AbstractString;
                 attenuation::Float64=0.2, limit::Int=20)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS src, e.rel_type, n2.label_canon AS dst,
               e.support_lcms,
               CASE WHEN LOWER(n1.label_canon) LIKE ?
                    THEN e.score_sum * ?
                    ELSE e.score_sum
               END AS score_sum_adj,
               e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        ORDER BY score_sum_adj DESC
        LIMIT ?
    """, ("%" * lowercase(concept) * "%", attenuation, limit)))
end

"""
    do_cut_diff(csql, concept; limit=20)

Compare the backbone before and after a hard do-cut intervention.
Returns (baseline, counterfactual, removed) — the edges that vanish.
"""
function do_cut_diff(csql::CSQLDatabase, concept::AbstractString; limit::Int=20)
    base = backbone(csql; limit=limit)
    cf = do_cut(csql, concept; limit=limit)

    # Edges that appear in baseline but not counterfactual
    cf_set = Set((r.src, r.dst, r.rel_type) for r in cf)
    removed = CausalResult([r for r in base if !((r.src, r.dst, r.rel_type) in cf_set)])

    (baseline=base, counterfactual=cf, removed=removed)
end
