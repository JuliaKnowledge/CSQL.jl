# CSQL.jl — Causal SQL Databases for Julia

A Julia implementation of the **Csql** causal database framework ([arXiv:2601.08109](https://arxiv.org/abs/2601.08109)).

CSQL.jl builds SQL-queryable causal databases from extracted causal claims (triples), supporting:

- **Backbone extraction** — highest-scoring causal relationships
- **Hub detection** — most influential causal concepts
- **Causal path queries** — multi-hop causal chains (A→B→C)
- **Counterfactual reasoning** — hard/soft do-cut interventions
- **Feedback loop detection** — cycles via Tarjan's SCC algorithm
- **Atlas merging** — combine causal databases from multiple sources
- **Provenance tracking** — link edges to source documents and LCMs
- **Controversy detection** — edges with mixed directional evidence

Uses [DBInterface.jl](https://github.com/JuliaDatabases/DBInterface.jl) for generic database backends (default: [SQLite.jl](https://github.com/JuliaDatabases/SQLite.jl)).

## Quick Start

```julia
using CSQL

# Create a builder and add causal triples
builder = AtlasBuilder()

add_triple!(builder, "Vaccination", "reduces", "Susceptibility";
            doc_id="smith2023", score=0.92)
add_triple!(builder, "Vaccination", "increases", "Population immunity";
            doc_id="smith2023", score=0.88)
add_triple!(builder, "Contact rate", "increases", "Transmission";
            doc_id="jones2024", score=0.85)
add_triple!(builder, "Transmission", "increases", "Outbreak severity";
            doc_id="jones2024", score=0.95)

# Build the database (in-memory SQLite)
csql = connect_csql()
build!(builder, csql.db)

# Query the causal backbone
backbone(csql)

# Find effects of vaccination
effects_of(csql, "vaccination")

# Detect causal hubs
causal_hubs(csql)

# Multi-hop causal paths
causal_paths(csql; depth=2)

# Counterfactual: what happens without transmission?
do_cut(csql, "transmission")
```

## Schema

CSQL creates four tables:

| Table | Description |
|-------|-------------|
| `atlas_nodes` | Canonical causal concepts with degree stats |
| `atlas_edges` | Aggregated causal relations with support/score/polarity |
| `atlas_edge_support` | Provenance: links edges to documents and LCMs |
| `atlas_scc` | Strongly connected components (feedback loops) |

## API Reference

### Building

- `AtlasBuilder(; min_edges, rel_whitelist, rel_blacklist)` — create builder
- `add_triple!(builder, subject, relation, object; doc_id, score, ...)` — add claim
- `add_lcm!(builder, lcm)` — add a `LocalCausalModel`
- `build!(builder, db)` — finalize and write to database

### Querying

- `backbone(csql; limit)` — strongest causal claims
- `causal_hubs(csql; limit)` — most influential concepts
- `effects_of(csql, concept)` — downstream effects
- `causes_of(csql, concept)` — upstream causes
- `causal_paths(csql; depth, limit)` — multi-hop chains
- `feedback_loops(csql)` — 2-cycles
- `controversial_claims(csql; threshold)` — mixed evidence
- `statistics(csql)` — atlas summary
- `custom_query(csql, sql)` — arbitrary SQL

### Counterfactual

- `do_cut(csql, concept)` — hard intervention (remove outgoing edges)
- `soft_do(csql, concept; attenuation)` — attenuate outgoing scores
- `do_cut_diff(csql, concept)` — compare baseline vs intervention

### Merging

- `merge_atlases!(target, [source1, source2]; atlas_ids)` — combine atlases

## Vignettes

| # | Vignette | Description |
|---|----------|-------------|
| 1 | [Getting Started](vignettes/01-getting-started/getting-started.md) | Building your first causal database |
| 2 | [Querying Causal Databases](vignettes/02-querying/querying.md) | Multi-hop paths, feedback loops, and controversy detection |
| 3 | [Counterfactual Reasoning](vignettes/03-counterfactual/counterfactual.md) | Do-cut interventions and causal inference |
| 4 | [Provenance and Local Causal Models](vignettes/04-provenance/provenance.md) | Tracking evidence sources behind causal claims |
| 5 | [Merging Causal Atlases](vignettes/05-merging/merging.md) | Combining causal databases from multiple sources |
| 6 | [DuckDB Backend](vignettes/06-duckdb-backend/duckdb-backend.md) | Using DuckDB for analytical queries on causal databases |

## Testing

```bash
julia --project=CSQL.jl CSQL.jl/test/runtests.jl
```

## References

- Csql paper: [arXiv:2601.08109](https://arxiv.org/abs/2601.08109) — *Csql: Mapping Documents into Causal Databases*
- Built with [DBInterface.jl](https://github.com/JuliaDatabases/DBInterface.jl) and [SQLite.jl](https://github.com/JuliaDatabases/SQLite.jl)
