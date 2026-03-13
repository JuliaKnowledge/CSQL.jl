# Tutorial

This tutorial walks through the core workflow of CSQL.jl: creating causal triples, building a causal database, querying it, running counterfactual interventions, and merging multiple atlases.

## Creating Causal Triples

A *causal triple* represents a single claim: **subject** *relation* **object**. For example, "Vaccination *reduces* Susceptibility".

```@example tutorial
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
nothing # hide
```

Triples are automatically canonicalized: concept labels are lowercased and normalized, and free-form relation strings are mapped to a fixed [`RelationType`](@ref) enum with an associated [`Polarity`](@ref).

## Using Local Causal Models

You can also add triples via a [`LocalCausalModel`](@ref), which groups triples from a single document:

```@example tutorial
lcm = LocalCausalModel(
    "lcm1",           # lcm_id
    "jones2024",      # doc_id
    [                  # triples
        CausalTriple("Contact rate", "increases", "Transmission"),
        CausalTriple("Transmission", "increases", "Outbreak severity"),
    ]
)
add_lcm!(builder, lcm)
nothing # hide
```

## Building the Database

Connect to a database backend and build:

```@example tutorial
csql = connect_csql()           # in-memory SQLite (default)
build!(builder, csql.db)
nothing # hide
```

## Querying

### Backbone

The backbone extracts the highest-scoring edges in the atlas:

```@example tutorial
backbone(csql)
```

### Causal Hubs

Identify the most influential causal concepts:

```@example tutorial
causal_hubs(csql)
```

### Causal Effects

Find downstream effects of a concept:

```@example tutorial
effects_of(csql, "vaccination")
```

Find upstream causes:

```@example tutorial
causes_of(csql, "transmission")
```

### Multi-hop Paths

Find 2-hop causal chains (A→B→C):

```@example tutorial
causal_paths(csql; depth=2)
```

### Feedback Loops

Detect 2-cycles (mutual influence):

```@example tutorial
feedback_loops(csql)
```

### Summary Statistics

```@example tutorial
statistics(csql)
```

### Custom SQL

```@example tutorial
custom_query(csql, "SELECT * FROM atlas_edges WHERE score_sum > 0.9")
```

## Counterfactual Reasoning

CSQL.jl implements Pearl's do-operator for causal interventions.

### Hard Intervention (do-cut)

Remove all outgoing edges from a concept:

```@example tutorial
do_cut(csql, "transmission")
```

### Soft Intervention

Attenuate outgoing edge scores:

```@example tutorial
soft_do(csql, "transmission"; attenuation=0.2)
```

### Counterfactual Comparison

Compare baseline vs. intervention:

```@example tutorial
baseline, counterfactual, removed = do_cut_diff(csql, "transmission")
```

Baseline backbone:

```@example tutorial
baseline
```

After intervention:

```@example tutorial
counterfactual
```

Removed edges:

```@example tutorial
removed
```

## Merging Atlases

Combine causal databases from multiple sources:

```@example merging
using CSQL

# Build first atlas
builder1 = AtlasBuilder()
add_triple!(builder1, "Smoking", "causes", "Lung cancer";
            doc_id="who2024", score=0.95)
add_triple!(builder1, "Smoking", "increases", "Heart disease";
            doc_id="who2024", score=0.88)
source1 = connect_csql()
build!(builder1, source1.db)

# Build second atlas
builder2 = AtlasBuilder()
add_triple!(builder2, "Exercise", "reduces", "Heart disease";
            doc_id="nhs2024", score=0.82)
add_triple!(builder2, "Smoking", "causes", "Lung cancer";
            doc_id="nhs2024", score=0.91)
source2 = connect_csql()
build!(builder2, source2.db)

# Merge into target
target = connect_csql()
merge_atlases!(target, [source1, source2])

backbone(target)
```
