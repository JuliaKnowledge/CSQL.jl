# ─── Enums ───────────────────────────────────────────────────────────────────

"""Normalized causal relation types."""
@enum RelationType begin
    CAUSES
    INFLUENCES
    INCREASES
    REDUCES
    AFFECTS
    LEADS_TO
    PREVENTS
    ENABLES
    TREATS
    TARGETS
    INHIBITS
    ACTIVATES
    REMOVES
    MODULATES
    BLOCKS
    BINDS
    INTERACTS_WITH
    ASSOCIATED_WITH
    COOCCURS_WITH
    UNKNOWN_REL
end

"""Causal polarity: direction of effect."""
@enum Polarity begin
    INCREASE    # positive / inc
    DECREASE    # negative / dec
    UNKNOWN_POL # unknown / unk
end

const SYMMETRIC_RELATIONS = Set([BINDS, INTERACTS_WITH, ASSOCIATED_WITH, COOCCURS_WITH])
is_symmetric(rt::RelationType) = rt in SYMMETRIC_RELATIONS

function polarity_str(p::Polarity)
    p == INCREASE ? "inc" : p == DECREASE ? "dec" : "unk"
end

function reltype_str(rt::RelationType)
    string(rt)
end

# ─── Data records ────────────────────────────────────────────────────────────

"""A single causal claim extracted from text."""
struct CausalTriple
    subject::String
    relation::String
    object::String
    domain::String
    source_text::String
end
CausalTriple(s, r, o; domain="", source_text="") = CausalTriple(s, r, o, domain, source_text)

"""A local causal model: a set of causal triples from one document/hypothesis."""
struct LocalCausalModel
    lcm_id::String
    doc_id::String
    focus::String
    triples::Vector{CausalTriple}
    score::Float64
    metadata::Dict{String,Any}
end
function LocalCausalModel(lcm_id, doc_id, triples;
                          focus="", score=1.0, metadata=Dict{String,Any}())
    LocalCausalModel(lcm_id, doc_id, focus, triples, score, metadata)
end

"""A canonical causal concept node."""
mutable struct NodeRecord
    node_id::Int64
    label_canon::String
    label_examples::Vector{String}
    deg_in::Int
    deg_out::Int
end

"""An aggregated causal edge."""
mutable struct EdgeRecord
    edge_id::Int64
    src_id::Int64
    dst_id::Int64
    rel_type::RelationType
    polarity::Polarity
    support_lcms::Int
    support_docs::Int
    score_sum::Float64
    score_mean::Float64
    score_max::Float64
    pol_mass_inc::Float64
    pol_mass_dec::Float64
    pol_mass_unk::Float64
    controversy::Float64
    stage::String
    confidence::Float64
    grounded::String
    source_model::String
    specificity::Float64
    is_symmetric::Bool
end

"""Provenance record linking an edge to a specific LCM and document."""
struct EdgeSupportRecord
    edge_id::Int64
    doc_id::String
    atlas_id::String
    lcm_instance_id::String
    score::Float64
    score_raw::Float64
    coupling::Float64
end

"""Strongly connected component summary."""
struct SCCRecord
    scc_id::Int
    n_nodes::Int
    n_edges::Int
    support_docs::Int
    top_nodes::Vector{String}
    node_ids::Vector{Int64}
end
