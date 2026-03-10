# Counterfactual Reasoning


- [Introduction](#introduction)
- [Building the Atlas](#building-the-atlas)
- [Baseline: The Causal Backbone](#baseline-the-causal-backbone)
- [Hard Do-Cut: Removing Vaccination](#hard-do-cut-removing-vaccination)
- [Do-Cut Diff: What Changes?](#do-cut-diff-what-changes)
- [Soft Do: Attenuated Intervention](#soft-do-attenuated-intervention)
- [Comparing Multiple Interventions](#comparing-multiple-interventions)
- [Interpreting Counterfactuals](#interpreting-counterfactuals)
- [Summary](#summary)

## Introduction

One of the most powerful features of causal databases is the ability to
reason about *interventions*. Pearl’s *do-calculus* formalizes the
question: “What would happen if we *forced* variable X to a particular
value?”

In CSQL.jl, interventions are implemented as SQL query rewrites that
simulate cutting or attenuating outgoing edges from a concept. This
vignette covers:

- **Hard do-cut** — completely remove a concept’s influence
- **Soft do** — attenuate (reduce) a concept’s influence
- **Do-cut diff** — compare baseline vs intervention

## Building the Atlas

We’ll use a classic epidemiological causal model:

``` julia
using CSQL

builder = AtlasBuilder()

# Disease transmission chain
add_triple!(builder, "Pathogen", "increases", "Transmission";
            doc_id="doc1", score=0.95)
add_triple!(builder, "Contact rate", "increases", "Transmission";
            doc_id="doc1", score=0.87)
add_triple!(builder, "Transmission", "increases", "Infection prevalence";
            doc_id="doc1", score=0.92)
add_triple!(builder, "Infection prevalence", "increases", "Mortality";
            doc_id="doc2", score=0.78)

# Intervention: vaccination
add_triple!(builder, "Vaccination", "reduces", "Susceptibility";
            doc_id="doc2", score=0.88)
add_triple!(builder, "Vaccination", "increases", "Herd immunity";
            doc_id="doc2", score=0.91)
add_triple!(builder, "Susceptibility", "increases", "Transmission";
            doc_id="doc1", score=0.83)
add_triple!(builder, "Herd immunity", "reduces", "Transmission";
            doc_id="doc2", score=0.79)

# Healthcare
add_triple!(builder, "Healthcare", "reduces", "Mortality";
            doc_id="doc3", score=0.90)

csql = connect_csql()
build!(builder, csql.db)
```

    SQLite.DB(":memory:")

## Baseline: The Causal Backbone

First, let’s see the full causal backbone:

``` julia
println("=== Baseline Backbone ===")
base = backbone(csql; limit=20)
for r in base
    println("  $(r.src) —[$(r.rel_type)]→ $(r.dst)  score=$(round(r.score_sum; digits=2))")
end
println("\nTotal edges: $(length(base))")
```

    === Baseline Backbone ===
      pathogen —[INCREASES]→ transmission  score=0.95
      transmission —[INCREASES]→ infection prevalence  score=0.92
      vaccination —[INCREASES]→ herd immunity  score=0.91
      healthcare —[REDUCES]→ mortality  score=0.9
      vaccination —[REDUCES]→ susceptibility  score=0.88
      contact rate —[INCREASES]→ transmission  score=0.87
      susceptibility —[INCREASES]→ transmission  score=0.83
      herd immunity —[REDUCES]→ transmission  score=0.79
      infection prevalence —[INCREASES]→ mortality  score=0.78

    Total edges: 9

## Hard Do-Cut: Removing Vaccination

The `do_cut` function removes all outgoing edges from a concept,
simulating the question: *“What would the causal landscape look like
without vaccination?”*

``` julia
println("=== Do-Cut: Remove Vaccination ===")
cf = do_cut(csql, "vaccination"; limit=20)
for r in cf
    println("  $(r.src) —[$(r.rel_type)]→ $(r.dst)  score=$(round(r.score_sum; digits=2))")
end
println("\nEdges after intervention: $(length(cf))")
```

    === Do-Cut: Remove Vaccination ===
      pathogen —[INCREASES]→ transmission  score=0.95
      transmission —[INCREASES]→ infection prevalence  score=0.92
      healthcare —[REDUCES]→ mortality  score=0.9
      contact rate —[INCREASES]→ transmission  score=0.87
      susceptibility —[INCREASES]→ transmission  score=0.83
      herd immunity —[REDUCES]→ transmission  score=0.79
      infection prevalence —[INCREASES]→ mortality  score=0.78

    Edges after intervention: 7

Notice that vaccination’s effects (reducing susceptibility, increasing
herd immunity) are gone — but the downstream concepts still exist via
other causal pathways.

## Do-Cut Diff: What Changes?

`do_cut_diff` compares baseline and counterfactual, identifying which
edges are lost:

``` julia
diff = do_cut_diff(csql, "vaccination"; limit=20)
println("=== Edges Removed by do(¬vaccination) ===")
for r in diff.removed
    println("  $(r.src) —[$(r.rel_type)]→ $(r.dst)  score=$(round(r.score_sum; digits=2))")
end
println("\nBaseline: $(length(diff.baseline)) edges")
println("Counterfactual: $(length(diff.counterfactual)) edges")
println("Removed: $(length(diff.removed)) edges")
```

    === Edges Removed by do(¬vaccination) ===
      vaccination —[INCREASES]→ herd immunity  score=0.91
      vaccination —[REDUCES]→ susceptibility  score=0.88

    Baseline: 9 edges
    Counterfactual: 7 edges
    Removed: 2 edges

## Soft Do: Attenuated Intervention

Sometimes we don’t want to completely remove a variable’s influence —
just reduce it. `soft_do` attenuates outgoing scores by a factor:

``` julia
println("=== Soft Do: Reduce Pathogen influence by 80% ===")
soft = soft_do(csql, "pathogen"; attenuation=0.2, limit=20)
for r in soft
    score_str = round(r.score_sum_adj; digits=2)
    println("  $(r.src) —[$(r.rel_type)]→ $(r.dst)  adj_score=$(score_str)")
end
```

    === Soft Do: Reduce Pathogen influence by 80% ===
      transmission —[INCREASES]→ infection prevalence  adj_score=0.92
      vaccination —[INCREASES]→ herd immunity  adj_score=0.91
      healthcare —[REDUCES]→ mortality  adj_score=0.9
      vaccination —[REDUCES]→ susceptibility  adj_score=0.88
      contact rate —[INCREASES]→ transmission  adj_score=0.87
      susceptibility —[INCREASES]→ transmission  adj_score=0.83
      herd immunity —[REDUCES]→ transmission  adj_score=0.79
      infection prevalence —[INCREASES]→ mortality  adj_score=0.78
      pathogen —[INCREASES]→ transmission  adj_score=0.19

Compare with baseline — pathogen’s outgoing edge score is reduced to 20%
of original, while all other edges retain full scores.

## Comparing Multiple Interventions

Let’s compare the impact of different interventions:

``` julia
println("=== Intervention Comparison ===\n")

interventions = ["vaccination", "healthcare", "pathogen"]
for concept in interventions
    diff = do_cut_diff(csql, concept; limit=20)
    println("do(¬$(concept)):")
    println("  Edges removed: $(length(diff.removed))")
    if !isempty(diff.removed)
        total_lost = sum(r.score_sum for r in diff.removed)
        println("  Total score mass lost: $(round(total_lost; digits=2))")
    end
    println()
end
```

    === Intervention Comparison ===

    do(¬vaccination):
      Edges removed: 2
      Total score mass lost: 1.79

    do(¬healthcare):
      Edges removed: 1
      Total score mass lost: 0.9

    do(¬pathogen):
      Edges removed: 1
      Total score mass lost: 0.95

This reveals which concepts have the most causal influence: removing
them disrupts the most edges and score mass.

## Interpreting Counterfactuals

The do-cut analysis answers practical questions:

| Question | CSQL Operation |
|----|----|
| “What if there were no vaccination?” | `do_cut(csql, "vaccination")` |
| “What if the pathogen were less transmissible?” | `soft_do(csql, "pathogen"; attenuation=0.3)` |
| “Which intervention matters most?” | Compare `do_cut_diff` across interventions |
| “What causal paths survive without X?” | `do_cut` + `causal_paths` on result |

## Summary

This vignette demonstrated:

- **`do_cut`** — hard intervention removing all outgoing edges
- **`soft_do`** — partial attenuation of outgoing influence
- **`do_cut_diff`** — comparison of baseline vs intervention
- **Multi-intervention comparison** — ranking concepts by causal
  importance

Next: [Provenance and LCMs](../04-provenance/provenance.html) covers
tracking the source documents behind causal claims.
