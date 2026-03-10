# Getting Started with CSQL.jl


- [Introduction](#introduction)
- [Setup](#setup)
- [Creating Causal Triples](#creating-causal-triples)
- [Building the Database](#building-the-database)
- [Basic Queries](#basic-queries)
  - [Atlas Statistics](#atlas-statistics)
  - [Causal Backbone](#causal-backbone)
  - [Causal Hubs](#causal-hubs)
  - [Downstream Effects](#downstream-effects)
  - [Upstream Causes](#upstream-causes)
- [Custom SQL Queries](#custom-sql-queries)
- [Summary](#summary)

## Introduction

**CSQL.jl** implements the *Csql* causal database framework
([arXiv:2601.08109](https://arxiv.org/abs/2601.08109)) in Julia. It
builds SQL-queryable causal databases from extracted causal claims —
triples of the form *(subject, relation, object)* — and provides tools
for querying, intervention analysis, and multi-source merging.

This vignette walks through the basics: creating a builder, adding
causal triples, building the database, and running your first queries.

## Setup

``` julia
using CSQL
```

## Creating Causal Triples

A *causal triple* represents a single claim: **A** *relation* **B**. For
example, “Vaccination *reduces* Susceptibility”.

CSQL.jl uses an `AtlasBuilder` to accumulate triples before writing them
to a database.

``` julia
builder = AtlasBuilder()

# Add epidemiological causal claims
add_triple!(builder, "Pathogen transmissibility", "increases", "Transmission rate";
            doc_id="smith2023", score=0.92)

add_triple!(builder, "Contact rate", "increases", "Transmission rate";
            doc_id="jones2024", score=0.87)

add_triple!(builder, "Vaccination coverage", "reduces", "Host susceptibility";
            doc_id="chen2023", score=0.85)

add_triple!(builder, "Vaccination coverage", "increases", "Population immunity";
            doc_id="chen2023", score=0.91)

add_triple!(builder, "Host susceptibility", "increases", "Transmission rate";
            doc_id="smith2023", score=0.80)

add_triple!(builder, "Transmission rate", "increases", "Outbreak severity";
            doc_id="smith2023", score=0.95)
```

Each triple is automatically:

- **Canonicalized** — labels are lowercased and normalized
- **Relation-typed** — free-text relations like “increases” are mapped
  to standard types (`INCREASES`, `REDUCES`, etc.)
- **Scored** — each claim carries a confidence score (0–1)

## Building the Database

Connect to an in-memory SQLite database and build the atlas:

``` julia
csql = connect_csql()
build!(builder, csql.db)
```

    SQLite.DB(":memory:")

The `build!` step:

1.  Computes stable hash IDs for each node and edge
2.  Aggregates duplicate edges (same source→target→relation) across
    documents
3.  Calculates degree statistics, polarity mass, and controversy scores
4.  Detects strongly connected components (feedback loops)
5.  Writes four tables: `atlas_nodes`, `atlas_edges`,
    `atlas_edge_support`, `atlas_scc`

## Basic Queries

### Atlas Statistics

``` julia
stats = statistics(csql)
println("Nodes: ", stats[:n_nodes])
println("Edges: ", stats[:n_edges])
println("Support records: ", stats[:n_support])
println("Score range: ", round(stats[:min_score]; digits=2), " – ", round(stats[:max_score]; digits=2))
```

    Nodes: 7
    Edges: 6
    Support records: 6
    Score range: 0.8 – 0.95

### Causal Backbone

The **backbone** returns the highest-scoring causal relationships:

``` julia
bb = backbone(csql; limit=10)
for row in bb
    println("  $(row.src) —[$(row.rel_type)]→ $(row.dst)  (score=$(round(row.score_sum; digits=2)))")
end
```

      transmission rate —[INCREASES]→ outbreak severity  (score=0.95)
      pathogen transmissibility —[INCREASES]→ transmission rate  (score=0.92)
      vaccination coverage —[INCREASES]→ population immunity  (score=0.91)
      contact rate —[INCREASES]→ transmission rate  (score=0.87)
      vaccination coverage —[REDUCES]→ host susceptibility  (score=0.85)
      host susceptibility —[INCREASES]→ transmission rate  (score=0.8)

### Causal Hubs

**Hubs** are the most influential concepts — nodes with the highest
outgoing score mass:

``` julia
hubs = causal_hubs(csql; limit=5)
for h in hubs
    println("  $(h.concept): out_mass=$(round(h.out_mass; digits=2)), edges=$(h.n_edges)")
end
```

      vaccination coverage: out_mass=1.76, edges=2
      transmission rate: out_mass=0.95, edges=1
      pathogen transmissibility: out_mass=0.92, edges=1
      contact rate: out_mass=0.87, edges=1
      host susceptibility: out_mass=0.8, edges=1

### Downstream Effects

What does a concept *cause*?

``` julia
effects = effects_of(csql, "vaccination")
for e in effects
    println("  vaccination coverage —[$(e.rel_type)]→ $(e.dst)  (score=$(round(e.score_sum; digits=2)))")
end
```

      vaccination coverage —[INCREASES]→ population immunity  (score=0.91)
      vaccination coverage —[REDUCES]→ host susceptibility  (score=0.85)

### Upstream Causes

What *causes* a concept?

``` julia
causes = causes_of(csql, "transmission rate")
for c in causes
    println("  $(c.src) —[$(c.rel_type)]→ transmission rate  (score=$(round(c.score_sum; digits=2)))")
end
```

      pathogen transmissibility —[INCREASES]→ transmission rate  (score=0.92)
      contact rate —[INCREASES]→ transmission rate  (score=0.87)
      host susceptibility —[INCREASES]→ transmission rate  (score=0.8)

## Custom SQL Queries

You can run arbitrary SQL against the underlying tables:

``` julia
rows = custom_query(csql, """
    SELECT n.label_canon, n.deg_out, n.deg_in
    FROM atlas_nodes n
    ORDER BY n.deg_out + n.deg_in DESC
""")
for r in rows
    println("  $(r.label_canon): out=$(r.deg_out), in=$(r.deg_in)")
end
```

      transmission rate: out=1, in=3
      vaccination coverage: out=2, in=0
      host susceptibility: out=1, in=1
      pathogen transmissibility: out=1, in=0
      contact rate: out=1, in=0
      population immunity: out=0, in=1
      outbreak severity: out=0, in=1

## Summary

In this vignette you learned how to:

- Create an `AtlasBuilder` and add causal triples
- Build a CSQL database with `connect_csql()` and `build!()`
- Query the backbone, hubs, effects, and causes
- Run custom SQL queries

Next: [Querying in Depth](../02-querying/querying.html) covers the full
query API including multi-hop causal paths and feedback loop detection.
