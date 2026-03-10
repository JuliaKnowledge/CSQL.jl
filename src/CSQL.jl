"""
    CSQL — Causal SQL Database for Julia

A Julia implementation of the Csql causal database framework (arXiv:2601.08109).
Builds SQL-queryable causal databases from extracted causal claims, supporting
backbone extraction, hub detection, causal path queries, counterfactual reasoning
(do-cut), and multi-atlas merging.

Uses DBInterface.jl for generic database backends (default: SQLite).
"""
module CSQL

using DBInterface
using SQLite
using DuckDB
using Tables

include("models.jl")
include("canonicalization.jl")
include("schema.jl")
include("builder.jl")
include("queries.jl")
include("counterfactual.jl")
include("merger.jl")
include("scc.jl")

export RelationType, Polarity, CausalTriple, LocalCausalModel,
       NodeRecord, EdgeRecord, EdgeSupportRecord, SCCRecord,
       CAUSES, INFLUENCES, INCREASES, REDUCES, AFFECTS, LEADS_TO,
       PREVENTS, ENABLES, TREATS, TARGETS, INHIBITS, ACTIVATES,
       REMOVES, MODULATES, BLOCKS, BINDS, INTERACTS_WITH,
       ASSOCIATED_WITH, COOCCURS_WITH, UNKNOWN_REL,
       INCREASE, DECREASE, UNKNOWN_POL,
       AtlasBuilder, add_triple!, add_lcm!, build!,
       CSQLDatabase, connect_csql, backbone, causal_hubs,
       effects_of, causes_of, causal_paths, feedback_loops,
       controversial_claims, do_cut, soft_do, do_cut_diff, statistics,
       custom_query, merge_atlases!

end # module
