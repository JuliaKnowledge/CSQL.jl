# Tutorial

This tutorial walks through the core workflow of CSQL.jl: creating causal triples, building a causal database, querying it, running counterfactual interventions, and merging multiple atlases.

## Creating Causal Triples

A *causal triple* represents a single claim: **subject** *relation* **object**. For example, "Vaccination *reduces* Susceptibility".

```julia
using CSQL

builder = AtlasBuilder()

add_triple!(builder, "Vaccination", "reduces", "Susceptibility";
            doc_id="smith2023", score=0.92)
add_triple!(builder, "Vaccination", "increases", "Population immunity";
            doc_id="smith2023", score=0.88)
add_triple!(builder, "Contact rate", "increases", "Transmission";
            doc_id="jones2024", score=0.85)
add_triple!(builder, "Transmission", "increases", "Outbreak severity";
            doc_id="jones2024", score=0.95)
```

Triples are automatically canonicalized: concept labels are lowercased and normalized, and free-form relation strings are mapped to a fixed [`RelationType`](@ref) enum with an associated [`Polarity`](@ref).

## Using Local Causal Models

You can also add triples via a [`LocalCausalModel`](@ref), which groups triples from a single document:

```julia
lcm = LocalCausalModel(
    doc_id = "jones2024",
    triples = [
        CausalTriple("Contact rate", "increases", "Transmission"),
        CausalTriple("Transmission", "increases", "Outbreak severity"),
    ]
)
add_lcm!(builder, lcm)
```

## Building the Database

Connect to a database backend and build:

```julia
csql = connect_csql()           # in-memory SQLite (default)
build!(builder, csql.db)
```

For DuckDB:

```julia
csql = connect_csql(backend=:duckdb)
build!(builder, csql.db)
```

## Querying

### Backbone and Hubs

```julia
backbone(csql)           # highest-scoring edges
causal_hubs(csql)         # most connected concepts
```

### Causal Effects

```julia
effects_of(csql, "vaccination")   # downstream effects
causes_of(csql, "transmission")   # upstream causes
```

### Multi-hop Paths

```julia
causal_paths(csql; depth=2)       # 2-hop causal chains
causal_paths(csql; depth=3)       # 3-hop causal chains
```

### Feedback Loops and Controversy

```julia
feedback_loops(csql)                        # 2-cycles
controversial_claims(csql; threshold=0.1)   # mixed evidence
```

### Summary Statistics

```julia
statistics(csql)    # node/edge counts, score distribution, relation breakdown
```

### Custom SQL

```julia
custom_query(csql, "SELECT * FROM atlas_edges WHERE mean_score > 0.9")
```

## Counterfactual Reasoning

CSQL.jl implements Pearl's do-operator for causal interventions:

### Hard Intervention (do-cut)

Remove all outgoing edges from a concept:

```julia
do_cut(csql, "transmission")
```

### Soft Intervention

Attenuate outgoing edge scores:

```julia
soft_do(csql, "transmission"; attenuation=0.2)
```

### Counterfactual Comparison

Compare baseline vs. intervention:

```julia
baseline, counterfactual, removed = do_cut_diff(csql, "transmission")
```

## Merging Atlases

Combine causal databases from multiple sources:

```julia
target = connect_csql()
source1 = connect_csql()
source2 = connect_csql()

# ... build source1 and source2 ...

merge_atlases!(target, [source1, source2])
```
