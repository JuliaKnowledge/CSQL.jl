# CSQL.jl

A Julia implementation of the **Csql** causal database framework ([arXiv:2601.08109](https://arxiv.org/abs/2601.08109)).

CSQL.jl builds SQL-queryable causal databases from extracted causal claims (triples), supporting backbone extraction, hub detection, causal path queries, outgoing-edge interventions, feedback loop detection, atlas merging, provenance tracking, and controversy detection.

## Features

- **Backbone extraction** — highest-scoring causal relationships
- **Hub detection** — most influential causal concepts
- **Causal path queries** — multi-hop causal chains (A->B->C)
- **Counterfactual reasoning** — outgoing-edge do-cut interventions
- **Feedback loop detection** — strongly connected component summaries
- **Atlas merging** — combine causal databases from multiple sources
- **Provenance tracking** — link edges to source documents and LCMs
- **Controversy detection** — edges with mixed directional evidence

Uses [DBInterface.jl](https://github.com/JuliaDatabases/DBInterface.jl) with supported [SQLite.jl](https://github.com/JuliaDatabases/SQLite.jl) (default) and [DuckDB.jl](https://github.com/duckdb/duckdb-julia) backends.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaKnowledge/CSQL.jl")
```

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
effects_of(csql, "vaccination"; exact=true)

# Counterfactual: what happens if transmission can no longer affect downstream concepts?
do_cut(csql, "transmission")
```

`build!(builder, db)` rewrites the atlas tables in `db`, so rerunning it with a
new builder state replaces stale support and SCC metadata as well.

## Schema

CSQL creates four tables:

| Table | Description |
|-------|-------------|
| `atlas_nodes` | Canonical causal concepts with degree stats |
| `atlas_edges` | Aggregated causal relations with support/score/polarity |
| `atlas_edge_support` | Provenance: links edges to documents and LCMs |
| `atlas_scc` | Strongly connected components (feedback loops) |
