# ─── Counterfactual / intervention operations ────────────────────────────────

"""
    do_cut(csql, concept; limit=20, exact=false)

Outgoing-edge intervention: remove all outgoing edges from a concept's
canonical label match. Use `exact=true` to match only the canonical label.
Returns the backbone of the atlas *after* the
intervention. This is not Pearl's parent-cutting `do(X=x)` operation.
"""
function do_cut(csql::CSQLDatabase, concept::AbstractString; limit::Int=20, exact::Bool=false)
    predicate, param = _canonical_match("n1.label_canon", concept; exact=exact)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS src, e.rel_type, n2.label_canon AS dst,
               e.support_lcms, e.score_sum, e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        WHERE NOT ($predicate)
        ORDER BY e.score_sum DESC
        LIMIT ?
    """, (param, limit)))
end

"""
    soft_do(csql, concept; attenuation=0.2, limit=20, exact=false)

Soft intervention: attenuate (reduce) outgoing score mass from a concept.
Use `exact=true` to match only the canonical label. Returns the backbone
with adjusted scores.
"""
function soft_do(csql::CSQLDatabase, concept::AbstractString;
                 attenuation::Float64=0.2, limit::Int=20, exact::Bool=false)
    predicate, param = _canonical_match("n1.label_canon", concept; exact=exact)
    CausalResult(_query(csql, """
        SELECT n1.label_canon AS src, e.rel_type, n2.label_canon AS dst,
               e.support_lcms,
               CASE WHEN $predicate
                    THEN e.score_sum * ?
                    ELSE e.score_sum
               END AS score_sum_adj,
               e.polarity
        FROM atlas_edges e
        JOIN atlas_nodes n1 ON e.src_id = n1.node_id
        JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        ORDER BY score_sum_adj DESC
        LIMIT ?
    """, (param, attenuation, limit)))
end

"""
    do_cut_diff(csql, concept; limit=20, exact=false)

Compare the backbone before and after a hard do-cut intervention.
Returns (baseline, counterfactual, removed) — the edges that vanish. The
comparison is computed against the full atlas before results are truncated.
"""
function do_cut_diff(csql::CSQLDatabase, concept::AbstractString; limit::Int=20, exact::Bool=false)
    full_limit = typemax(Int)
    base = backbone(csql; limit=full_limit)
    cf = do_cut(csql, concept; limit=full_limit, exact=exact)

    # Edges that appear in baseline but not counterfactual
    cf_set = Set((r.src, r.dst, r.rel_type) for r in cf)
    removed = CausalResult(filter(r -> !((r.src, r.dst, r.rel_type) in cf_set), base.rows))

    truncate(rows) = rows[1:min(length(rows), limit)]
    (
        baseline=CausalResult(truncate(base.rows), base.label),
        counterfactual=CausalResult(truncate(cf.rows), cf.label),
        removed=CausalResult(truncate(removed.rows), removed.label),
    )
end
