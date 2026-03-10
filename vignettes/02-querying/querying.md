# Querying Causal Databases


- [Introduction](#introduction)
- [Building a Richer Atlas](#building-a-richer-atlas)
- [Multi-hop Causal Paths](#multi-hop-causal-paths)
- [3-hop Causal Chains](#3-hop-causal-chains)
- [Feedback Loops](#feedback-loops)
- [Controversial Claims](#controversial-claims)
- [Relation Distribution](#relation-distribution)
- [Combining Queries with Custom
  SQL](#combining-queries-with-custom-sql)
- [Summary](#summary)

## Introduction

CSQL.jl provides a rich query API over causal databases. Beyond simple
backbone and hub queries (covered in [Getting
Started](../01-getting-started/getting-started.html)), this vignette
demonstrates:

- **Multi-hop causal paths** — chains like A → B → C
- **Feedback loops** — mutual influence (2-cycles)
- **Controversial claims** — edges with mixed directional evidence
- **Relation distribution** — what kinds of causal relationships
  dominate?

## Building a Richer Atlas

We’ll build a larger epidemiological causal atlas with feedback loops
and conflicting evidence:

``` julia
using CSQL

builder = AtlasBuilder()

# Core transmission chain
add_triple!(builder, "Pathogen transmissibility", "increases", "Transmission rate";
            doc_id="smith2023", score=0.92)
add_triple!(builder, "Contact rate", "increases", "Transmission rate";
            doc_id="jones2024", score=0.87)
add_triple!(builder, "Transmission rate", "increases", "Outbreak severity";
            doc_id="smith2023", score=0.95)
add_triple!(builder, "Outbreak severity", "increases", "Case fatality rate";
            doc_id="smith2023", score=0.73)

# Immunity feedback
add_triple!(builder, "Vaccination coverage", "reduces", "Host susceptibility";
            doc_id="chen2023", score=0.85)
add_triple!(builder, "Vaccination coverage", "increases", "Population immunity";
            doc_id="chen2023", score=0.91)
add_triple!(builder, "Population immunity", "reduces", "Host susceptibility";
            doc_id="patel2024", score=0.77)
add_triple!(builder, "Host susceptibility", "increases", "Transmission rate";
            doc_id="smith2023", score=0.80)

# Feedback loop: severity ↔ public health response
add_triple!(builder, "Outbreak severity", "increases", "Public health response";
            doc_id="who2024", score=0.88)
add_triple!(builder, "Public health response", "reduces", "Outbreak severity";
            doc_id="who2024", score=0.82)

# Healthcare
add_triple!(builder, "Healthcare capacity", "reduces", "Case fatality rate";
            doc_id="patel2024", score=0.88)
add_triple!(builder, "Outbreak severity", "reduces", "Healthcare capacity";
            doc_id="who2024", score=0.65)

# Controversial claim: does quarantine reduce transmission?
add_triple!(builder, "Quarantine", "reduces", "Transmission rate";
            doc_id="brown2023", score=0.78)
# Opposing evidence
add_triple!(builder, "Quarantine", "increases", "Transmission rate";
            doc_id="lee2024", score=0.45)

csql = connect_csql()
build!(builder, csql.db)
stats = statistics(csql)
println("Atlas: $(stats[:n_nodes]) nodes, $(stats[:n_edges]) edges, $(stats[:n_support]) support records")
```

    Atlas: 11 nodes, 14 edges, 14 support records

## Multi-hop Causal Paths

Find 2-hop causal chains (A → B → C):

``` julia
paths = causal_paths(csql; depth=2, limit=10)
println("Found $(length(paths)) 2-hop paths:")
for p in paths
    println("  $(p.a) —[$(p.r1)]→ $(p.b) —[$(p.r2)]→ $(p.c)  (path_score=$(round(p.path_score; digits=2)))")
end
```

    Found 10 2-hop paths:
      pathogen transmissibility —[INCREASES]→ transmission rate —[INCREASES]→ outbreak severity  (path_score=1.87)
      transmission rate —[INCREASES]→ outbreak severity —[INCREASES]→ public health response  (path_score=1.83)
      contact rate —[INCREASES]→ transmission rate —[INCREASES]→ outbreak severity  (path_score=1.82)
      host susceptibility —[INCREASES]→ transmission rate —[INCREASES]→ outbreak severity  (path_score=1.75)
      quarantine —[REDUCES]→ transmission rate —[INCREASES]→ outbreak severity  (path_score=1.73)
      public health response —[REDUCES]→ outbreak severity —[INCREASES]→ public health response  (path_score=1.7)
      outbreak severity —[INCREASES]→ public health response —[REDUCES]→ outbreak severity  (path_score=1.7)
      vaccination coverage —[INCREASES]→ population immunity —[REDUCES]→ host susceptibility  (path_score=1.68)
      transmission rate —[INCREASES]→ outbreak severity —[INCREASES]→ case fatality rate  (path_score=1.68)
      vaccination coverage —[REDUCES]→ host susceptibility —[INCREASES]→ transmission rate  (path_score=1.65)

These multi-hop paths reveal indirect causal mechanisms — e.g., how
pathogen transmissibility ultimately drives outbreak severity through
transmission rate.

## 3-hop Causal Chains

For deeper analysis, find 3-hop chains (A → B → C → D):

``` julia
paths3 = causal_paths(csql; depth=3, limit=5)
println("Found $(length(paths3)) 3-hop paths:")
for p in paths3
    println("  $(p.a) —[$(p.r1)]→ $(p.b) —[$(p.r2)]→ $(p.c) —[$(p.r3)]→ $(p.d)")
    println("    path_score=$(round(p.path_score; digits=2))")
end
```

    Found 5 3-hop paths:
      pathogen transmissibility —[INCREASES]→ transmission rate —[INCREASES]→ outbreak severity —[INCREASES]→ public health response
        path_score=2.75
      contact rate —[INCREASES]→ transmission rate —[INCREASES]→ outbreak severity —[INCREASES]→ public health response
        path_score=2.7
      transmission rate —[INCREASES]→ outbreak severity —[INCREASES]→ public health response —[REDUCES]→ outbreak severity
        path_score=2.65
      host susceptibility —[INCREASES]→ transmission rate —[INCREASES]→ outbreak severity —[INCREASES]→ public health response
        path_score=2.63
      quarantine —[REDUCES]→ transmission rate —[INCREASES]→ outbreak severity —[INCREASES]→ public health response
        path_score=2.61

## Feedback Loops

Detect 2-cycles — pairs of concepts that mutually influence each other:

``` julia
loops = feedback_loops(csql)
println("Found $(length(loops)) feedback loops:")
for l in loops
    println("  $(l.a) ⇄ $(l.b)")
    println("    $(l.a) —[$(l.r1)]→ $(l.b)")
    println("    $(l.b) —[$(l.r2)]→ $(l.a)")
    println("    loop_score=$(round(l.loop_score; digits=2))")
end
```

    Found 1 feedback loops:
      public health response ⇄ outbreak severity
        public health response —[REDUCES]→ outbreak severity
        outbreak severity —[INCREASES]→ public health response
        loop_score=1.7

Feedback loops are epidemiologically significant — they represent
reinforcing or balancing dynamics in disease systems.

## Controversial Claims

Find edges where evidence is mixed (some sources say “increases”, others
say “reduces”):

``` julia
controv = controversial_claims(csql; threshold=0.1)
println("Found $(length(controv)) controversial claims:")
for c in controv
    println("  $(c.src) —[$(c.rel_type)]→ $(c.dst)")
    println("    controversy=$(round(c.controversy; digits=3)), inc=$(round(c.pol_mass_inc; digits=2)), dec=$(round(c.pol_mass_dec; digits=2))")
end
```

    Found 0 controversial claims:

A controversy score near 0.5 means evidence is evenly split between
increase and decrease.

## Relation Distribution

Understand what types of causal relationships dominate the atlas:

``` julia
rel_dist = stats[:relation_distribution]
for r in rel_dist
    println("  $(r.rel_type): $(r.n) edges, total_mass=$(round(r.total_mass; digits=2))")
end
```

      INCREASES: 8 edges, total_mass=6.51
      REDUCES: 6 edges, total_mass=4.75

## Combining Queries with Custom SQL

Find concepts that are both causes and effects (intermediate nodes in
causal chains):

``` julia
intermediates = custom_query(csql, """
    SELECT n.label_canon,
           n.deg_in AS incoming,
           n.deg_out AS outgoing,
           n.deg_in + n.deg_out AS total_degree
    FROM atlas_nodes n
    WHERE n.deg_in > 0 AND n.deg_out > 0
    ORDER BY total_degree DESC
""")
println("Intermediate concepts (both cause and effect):")
for row in intermediates
    println("  $(row.label_canon): in=$(row.incoming), out=$(row.outgoing)")
end
```

    Intermediate concepts (both cause and effect):
      transmission rate: in=5, out=1
      outbreak severity: in=2, out=3
      host susceptibility: in=2, out=1
      public health response: in=1, out=1
      population immunity: in=1, out=1
      healthcare capacity: in=1, out=1

## Summary

This vignette demonstrated:

- **Multi-hop paths** (`causal_paths`) for discovering indirect causal
  chains
- **Feedback loops** (`feedback_loops`) for detecting
  reinforcing/balancing dynamics
- **Controversial claims** (`controversial_claims`) for finding
  contested evidence
- **Custom SQL** for flexible ad-hoc analysis

Next: [Counterfactual
Reasoning](../03-counterfactual/counterfactual.html) covers do-cut
interventions and causal inference.
