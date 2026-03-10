# Merging Causal Atlases


- [Introduction](#introduction)
- [Building Domain-Specific Atlases](#building-domain-specific-atlases)
  - [Epidemiological Atlas](#epidemiological-atlas)
  - [Genomic Atlas](#genomic-atlas)
- [Merging Atlases](#merging-atlases)
- [Examining the Merged Atlas](#examining-the-merged-atlas)
  - [Backbone](#backbone)
  - [Aggregated Overlapping Edges](#aggregated-overlapping-edges)
  - [Provenance Tracking](#provenance-tracking)
- [Cross-Domain Analysis](#cross-domain-analysis)
  - [Hubs in the Merged Atlas](#hubs-in-the-merged-atlas)
- [Counterfactual on Merged Atlas](#counterfactual-on-merged-atlas)
- [Summary](#summary)

## Introduction

Scientific knowledge is distributed across research communities. An
epidemiologist’s causal model of disease transmission may overlap with a
genomicist’s model of host-pathogen interactions. **Atlas merging**
combines these separate causal databases while:

- **Re-aggregating** shared edges (same cause→effect across sources)
- **Preserving provenance** (tracking which atlas contributed each
  claim)
- **Recomputing statistics** (degree, polarity, controversy)

This vignette builds two domain-specific atlases and merges them.

## Building Domain-Specific Atlases

### Epidemiological Atlas

``` julia
using CSQL

epi_builder = AtlasBuilder()
add_triple!(epi_builder, "Pathogen transmissibility", "increases", "Transmission rate";
            doc_id="smith2023", score=0.92)
add_triple!(epi_builder, "Contact rate", "increases", "Transmission rate";
            doc_id="jones2024", score=0.87)
add_triple!(epi_builder, "Vaccination", "reduces", "Susceptibility";
            doc_id="chen2023", score=0.85)
add_triple!(epi_builder, "Transmission rate", "increases", "Outbreak severity";
            doc_id="smith2023", score=0.95)
add_triple!(epi_builder, "Susceptibility", "increases", "Transmission rate";
            doc_id="smith2023", score=0.80)

epi_csql = connect_csql()
build!(epi_builder, epi_csql.db)

epi_stats = statistics(epi_csql)
println("Epidemiological atlas: $(epi_stats[:n_nodes]) nodes, $(epi_stats[:n_edges]) edges")
```

    Epidemiological atlas: 6 nodes, 5 edges

### Genomic Atlas

``` julia
gen_builder = AtlasBuilder()
add_triple!(gen_builder, "Pathogen mutation rate", "increases", "Pathogen transmissibility";
            doc_id="garcia2024", score=0.88)
add_triple!(gen_builder, "Immune evasion", "increases", "Pathogen transmissibility";
            doc_id="garcia2024", score=0.82)
add_triple!(gen_builder, "Host genetics", "influences", "Susceptibility";
            doc_id="kim2024", score=0.75)
# Overlapping claim with epi atlas
add_triple!(gen_builder, "Pathogen transmissibility", "increases", "Transmission rate";
            doc_id="garcia2024", score=0.90)
add_triple!(gen_builder, "Pathogen mutation rate", "increases", "Immune evasion";
            doc_id="garcia2024", score=0.71)

gen_csql = connect_csql()
build!(gen_builder, gen_csql.db)

gen_stats = statistics(gen_csql)
println("Genomic atlas: $(gen_stats[:n_nodes]) nodes, $(gen_stats[:n_edges]) edges")
```

    Genomic atlas: 6 nodes, 5 edges

## Merging Atlases

``` julia
merged = connect_csql()
merge_atlases!(merged, [epi_csql, gen_csql]; atlas_ids=["epi", "genomic"])

merged_stats = statistics(merged)
println("Merged atlas: $(merged_stats[:n_nodes]) nodes, $(merged_stats[:n_edges]) edges, $(merged_stats[:n_support]) support records")
```

    Merged atlas: 9 nodes, 9 edges, 10 support records

## Examining the Merged Atlas

### Backbone

``` julia
bb = backbone(merged; limit=15)
println("Merged backbone:")
for r in bb
    println("  $(r.src) —[$(r.rel_type)]→ $(r.dst)  score=$(round(r.score_sum; digits=2))")
end
```

    Merged backbone:
      pathogen transmissibility —[INCREASES]→ transmission rate  score=1.82
      transmission rate —[INCREASES]→ outbreak severity  score=0.95
      pathogen mutation rate —[INCREASES]→ pathogen transmissibility  score=0.88
      contact rate —[INCREASES]→ transmission rate  score=0.87
      vaccination —[REDUCES]→ susceptibility  score=0.85
      immune evasion —[INCREASES]→ pathogen transmissibility  score=0.82
      susceptibility —[INCREASES]→ transmission rate  score=0.8
      host genetics —[INFLUENCES]→ susceptibility  score=0.75
      pathogen mutation rate —[INCREASES]→ immune evasion  score=0.71

### Aggregated Overlapping Edges

The “pathogen transmissibility → transmission rate” edge appears in both
atlases:

``` julia
overlaps = custom_query(merged, """
    SELECT e.rel_type, n1.label_canon AS src, n2.label_canon AS dst,
           e.support_lcms, e.support_docs, e.score_sum, e.score_mean
    FROM atlas_edges e
    JOIN atlas_nodes n1 ON e.src_id = n1.node_id
    JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
    WHERE e.support_lcms > 1
    ORDER BY e.score_sum DESC
""")
println("\nAggregated edges (multi-source):")
for o in overlaps
    println("  $(o.src) → $(o.dst)")
    println("    lcms=$(o.support_lcms), docs=$(o.support_docs), sum=$(round(o.score_sum; digits=2)), mean=$(round(o.score_mean; digits=2))")
end
```


    Aggregated edges (multi-source):
      pathogen transmissibility → transmission rate
        lcms=2, docs=2, sum=1.82, mean=0.91

### Provenance Tracking

``` julia
prov = custom_query(merged, """
    SELECT es.atlas_id, es.doc_id, es.lcm_instance_id,
           n1.label_canon AS src, n2.label_canon AS dst, es.score
    FROM atlas_edge_support es
    JOIN atlas_edges e ON es.edge_id = e.edge_id
    JOIN atlas_nodes n1 ON e.src_id = n1.node_id
    JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
    ORDER BY es.atlas_id, es.doc_id
""")
println("\nProvenance trace:")
for p in prov
    println("  [$(p.atlas_id)] $(p.doc_id): $(p.src) → $(p.dst)  score=$(round(p.score; digits=2))")
end
```


    Provenance trace:
      [epi] chen2023: vaccination → susceptibility  score=0.85
      [epi] jones2024: contact rate → transmission rate  score=0.87
      [epi] smith2023: pathogen transmissibility → transmission rate  score=0.92
      [epi] smith2023: transmission rate → outbreak severity  score=0.95
      [epi] smith2023: susceptibility → transmission rate  score=0.8
      [genomic] garcia2024: pathogen mutation rate → pathogen transmissibility  score=0.88
      [genomic] garcia2024: immune evasion → pathogen transmissibility  score=0.82
      [genomic] garcia2024: pathogen transmissibility → transmission rate  score=0.9
      [genomic] garcia2024: pathogen mutation rate → immune evasion  score=0.71
      [genomic] kim2024: host genetics → susceptibility  score=0.75

## Cross-Domain Analysis

With the merged atlas, we can now trace causal paths that span domains:

``` julia
paths = causal_paths(merged; depth=2, limit=10)
println("\nCross-domain 2-hop paths:")
for p in paths
    println("  $(p.a) → $(p.b) → $(p.c)  (path_score=$(round(p.path_score; digits=2)))")
end
```


    Cross-domain 2-hop paths:
      pathogen transmissibility → transmission rate → outbreak severity  (path_score=2.77)
      pathogen mutation rate → pathogen transmissibility → transmission rate  (path_score=2.7)
      immune evasion → pathogen transmissibility → transmission rate  (path_score=2.64)
      contact rate → transmission rate → outbreak severity  (path_score=1.82)
      susceptibility → transmission rate → outbreak severity  (path_score=1.75)
      vaccination → susceptibility → transmission rate  (path_score=1.65)
      host genetics → susceptibility → transmission rate  (path_score=1.55)
      pathogen mutation rate → immune evasion → pathogen transmissibility  (path_score=1.53)

### Hubs in the Merged Atlas

``` julia
hubs = causal_hubs(merged; limit=5)
println("\nMerged hubs:")
for h in hubs
    println("  $(h.concept): out_mass=$(round(h.out_mass; digits=2)), edges=$(h.n_edges)")
end
```


    Merged hubs:
      pathogen transmissibility: out_mass=1.82, edges=1
      pathogen mutation rate: out_mass=1.59, edges=2
      transmission rate: out_mass=0.95, edges=1
      contact rate: out_mass=0.87, edges=1
      vaccination: out_mass=0.85, edges=1

## Counterfactual on Merged Atlas

What happens if we remove pathogen transmissibility — the concept that
bridges both domains?

``` julia
diff = do_cut_diff(merged, "pathogen transmissibility"; limit=20)
println("\ndo(¬pathogen transmissibility):")
println("  Edges removed: $(length(diff.removed))")
for r in diff.removed
    println("    $(r.src) → $(r.dst)  score=$(round(r.score_sum; digits=2))")
end
```


    do(¬pathogen transmissibility):
      Edges removed: 1
        pathogen transmissibility → transmission rate  score=1.82

## Summary

This vignette demonstrated:

- Building **domain-specific atlases** independently
- **`merge_atlases!`** — combining atlases with provenance tracking
- **Score re-aggregation** — overlapping edges accumulate evidence
- **Atlas ID tagging** — tracking which source contributed each claim
- **Cross-domain analysis** — discovering causal paths that span
  research areas

Next: [DuckDB Backend](../06-duckdb-backend/duckdb-backend.html) shows
how to use DuckDB as an alternative database engine.
