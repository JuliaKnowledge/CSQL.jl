# ─── CausalResult: typed wrapper for query results ───────────────────────────

"""
    CausalResult

Wrapper for query results that enables tabular display.
Behaves like a `Vector{NamedTuple}` — supports indexing, iteration, and `length`.
"""
struct CausalResult
    rows::Vector{<:NamedTuple}
    label::String
end
CausalResult(rows) = CausalResult(rows, "")

Base.length(r::CausalResult) = length(r.rows)
Base.iterate(r::CausalResult) = iterate(r.rows)
Base.iterate(r::CausalResult, state) = iterate(r.rows, state)
Base.getindex(r::CausalResult, i) = r.rows[i]
Base.firstindex(r::CausalResult) = firstindex(r.rows)
Base.lastindex(r::CausalResult) = lastindex(r.rows)
Base.eltype(::Type{CausalResult}) = NamedTuple
Base.isempty(r::CausalResult) = isempty(r.rows)
