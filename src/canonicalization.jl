# ─── Label canonicalization ──────────────────────────────────────────────────

"""Canonicalize a concept label: lowercase, normalize whitespace/punctuation."""
function canonicalize_label(text::AbstractString)::String
    s = lowercase(strip(text))
    s = replace(s, r"\s+" => " ")
    s = replace(s, r"[–—]" => "-")
    s = replace(s, r"[\u2018\u2019\u0060]" => "'")
    s = replace(s, r"[\u201C\u201D]" => "\"")
    s = replace(s, r"[^\w\s\-'/\"]" => "")
    strip(s)
end

"""Compute a stable 64-bit node ID from a canonical label."""
function compute_node_id(canonical_label::String)::Int64
    h = hash(canonical_label)
    # Ensure signed 64-bit range
    reinterpret(Int64, h % UInt64)
end

"""Compute a stable edge ID from (src_id, rel_type, dst_id)."""
function compute_edge_id(src_id::Int64, rel_type::RelationType, dst_id::Int64)::Int64
    key = "$(src_id)||$(rel_type)||$(dst_id)"
    reinterpret(Int64, hash(key) % UInt64)
end

# ─── Relation normalization ─────────────────────────────────────────────────

# Pattern → (RelationType, Polarity)
const RELATION_PATTERNS = [
    # Direct causation
    (r"(?i)\bcauses?\b"                    , CAUSES,     UNKNOWN_POL),
    (r"(?i)\btriggers?\b"                  , CAUSES,     INCREASE),
    (r"(?i)\bproduces?\b"                  , CAUSES,     INCREASE),
    (r"(?i)\bgenerates?\b"                 , CAUSES,     INCREASE),
    (r"(?i)\bcreates?\b"                   , CAUSES,     INCREASE),
    (r"(?i)\bresults?\s+in\b"              , CAUSES,     UNKNOWN_POL),
    # Increases
    (r"(?i)\bincreases?\b"                 , INCREASES,  INCREASE),
    (r"(?i)\braises?\b"                    , INCREASES,  INCREASE),
    (r"(?i)\bboosts?\b"                    , INCREASES,  INCREASE),
    (r"(?i)\benhances?\b"                  , INCREASES,  INCREASE),
    (r"(?i)\bupregulates?\b"              , INCREASES,  INCREASE),
    (r"(?i)\bpromotes?\b"                  , INCREASES,  INCREASE),
    (r"(?i)\bstimulates?\b"               , INCREASES,  INCREASE),
    (r"(?i)\bamplif(?:y|ies)\b"            , INCREASES,  INCREASE),
    (r"(?i)\bexacerbates?\b"              , INCREASES,  INCREASE),
    # Decreases
    (r"(?i)\bdecreases?\b"                 , REDUCES,    DECREASE),
    (r"(?i)\breduces?\b"                   , REDUCES,    DECREASE),
    (r"(?i)\blowers?\b"                    , REDUCES,    DECREASE),
    (r"(?i)\bdiminishes?\b"               , REDUCES,    DECREASE),
    (r"(?i)\bdownregulates?\b"            , REDUCES,    DECREASE),
    (r"(?i)\bsuppresses?\b"              , REDUCES,    DECREASE),
    (r"(?i)\battenuates?\b"              , REDUCES,    DECREASE),
    (r"(?i)\bmitigates?\b"               , REDUCES,    DECREASE),
    # Prevention
    (r"(?i)\bprevents?\b"                  , PREVENTS,   DECREASE),
    # Enabling
    (r"(?i)\benables?\b"                   , ENABLES,    INCREASE),
    (r"(?i)\ballows?\b"                    , ENABLES,    INCREASE),
    (r"(?i)\bfacilitates?\b"              , ENABLES,    INCREASE),
    # Influence (generic)
    (r"(?i)\binfluences?\b"                , INFLUENCES, UNKNOWN_POL),
    (r"(?i)\baffects?\b"                   , AFFECTS,    UNKNOWN_POL),
    (r"(?i)\bimpacts?\b"                   , AFFECTS,    UNKNOWN_POL),
    (r"(?i)\bleads?\s+to\b"               , LEADS_TO,   UNKNOWN_POL),
    (r"(?i)\bcontributes?\s+to\b"          , LEADS_TO,   INCREASE),
    # Interventions
    (r"(?i)\btreats?\b"                    , TREATS,     DECREASE),
    (r"(?i)\btargets?\b"                   , TARGETS,    UNKNOWN_POL),
    (r"(?i)\binhibits?\b"                  , INHIBITS,   DECREASE),
    (r"(?i)\bactivates?\b"                , ACTIVATES,  INCREASE),
    (r"(?i)\bremoves?\b"                   , REMOVES,    DECREASE),
    (r"(?i)\bmodulates?\b"                , MODULATES,  UNKNOWN_POL),
    (r"(?i)\bblocks?\b"                    , BLOCKS,     DECREASE),
    # Symmetric
    (r"(?i)\bbinds?\b"                     , BINDS,          UNKNOWN_POL),
    (r"(?i)\binteracts?\s+with\b"          , INTERACTS_WITH, UNKNOWN_POL),
    (r"(?i)\bassociated?\s+with\b"         , ASSOCIATED_WITH,UNKNOWN_POL),
    (r"(?i)\bco-?occurs?\s+with\b"         , COOCCURS_WITH,  UNKNOWN_POL),
]

# BioLink predicate mapping (subset)
const BIOLINK_MAP = Dict{String,Tuple{RelationType,Polarity}}(
    "biolink:causes"                  => (CAUSES,     UNKNOWN_POL),
    "biolink:contributes_to"          => (LEADS_TO,   INCREASE),
    "biolink:positively_regulates"    => (INCREASES,  INCREASE),
    "biolink:negatively_regulates"    => (REDUCES,    DECREASE),
    "biolink:affects"                 => (AFFECTS,     UNKNOWN_POL),
    "biolink:treats"                  => (TREATS,      DECREASE),
    "biolink:prevents"                => (PREVENTS,    DECREASE),
    "biolink:predisposes"             => (INCREASES,   INCREASE),
    "biolink:related_to"              => (ASSOCIATED_WITH, UNKNOWN_POL),
    "biolink:interacts_with"          => (INTERACTS_WITH,  UNKNOWN_POL),
    "biolink:physically_interacts_with" => (BINDS,     UNKNOWN_POL),
    "biolink:correlated_with"         => (ASSOCIATED_WITH, UNKNOWN_POL),
    "biolink:has_phenotype"           => (CAUSES,     UNKNOWN_POL),
    "biolink:ameliorates"             => (REDUCES,    DECREASE),
    "biolink:exacerbates"             => (INCREASES,  INCREASE),
)

"""
    normalize_relation(relation::String) -> (RelationType, Polarity)

Normalize a free-form relation string to a canonical (RelationType, Polarity) pair.
Tries BioLink predicates first, then regex patterns, then defaults to INFLUENCES/UNKNOWN.
"""
function normalize_relation(relation::AbstractString)::Tuple{RelationType,Polarity}
    rel = strip(relation)

    # BioLink predicates
    rel_lower = lowercase(rel)
    haskey(BIOLINK_MAP, rel_lower) && return BIOLINK_MAP[rel_lower]

    # Regex patterns
    for (pat, rt, pol) in RELATION_PATTERNS
        if occursin(pat, rel)
            return (rt, pol)
        end
    end

    # Default
    (INFLUENCES, UNKNOWN_POL)
end

"""Extract polarity from free text by counting increase/decrease keywords."""
function extract_polarity_from_text(text::AbstractString)::Polarity
    inc = length(collect(eachmatch(r"(?i)\b(increase|raise|boost|enhance|promote|stimulat)\w*\b", text)))
    dec = length(collect(eachmatch(r"(?i)\b(decrease|reduce|lower|diminish|suppress|inhibit|prevent)\w*\b", text)))
    inc > dec ? INCREASE : dec > inc ? DECREASE : UNKNOWN_POL
end
