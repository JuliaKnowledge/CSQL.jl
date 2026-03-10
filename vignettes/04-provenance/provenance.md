# Provenance and Local Causal Models


- [Introduction](#introduction)
- [Local Causal Models](#local-causal-models)
- [Building from Multiple LCMs](#building-from-multiple-lcms)
- [Querying Provenance](#querying-provenance)
  - [All Support Records](#all-support-records)
  - [Edges Supported by Multiple
    Documents](#edges-supported-by-multiple-documents)
  - [Provenance by Document](#provenance-by-document)
- [Overlapping Claims](#overlapping-claims)
- [Edge Metadata](#edge-metadata)
- [Summary](#summary)

## Introduction

A key feature of Csql is **provenance tracking**: every causal claim is
linked back to its source document and local causal model (LCM). This
enables:

- Auditing which papers support a claim
- Weighting evidence by document quality
- Detecting when claims come from a single vs. multiple sources
- Understanding evidence aggregation

This vignette covers the `LocalCausalModel` type, the
`atlas_edge_support` table, and provenance queries.

## Local Causal Models

A *Local Causal Model* (LCM) is a set of causal triples extracted from a
single document or hypothesis. Instead of adding triples one by one, you
can package them as an LCM:

``` julia
using CSQL

# LCM from a transmission dynamics paper
lcm1 = LocalCausalModel("lcm_trans_001", "smith2023",
    [
        CausalTriple("Pathogen virulence", "increases", "Disease severity"),
        CausalTriple("Pathogen transmissibility", "increases", "Basic reproduction number"),
        CausalTriple("Basic reproduction number", "increases", "Epidemic potential"),
        CausalTriple("Disease severity", "increases", "Case fatality rate"),
    ];
    focus="transmission dynamics",
    score=0.92,
    metadata=Dict{String,Any}("stage" => "validated", "source_model" => "GPT-4")
)
println("LCM: $(lcm1.lcm_id) from $(lcm1.doc_id)")
println("  Focus: $(lcm1.focus)")
println("  Triples: $(length(lcm1.triples))")
println("  Score: $(lcm1.score)")
```

    LCM: lcm_trans_001 from smith2023
      Focus: transmission dynamics
      Triples: 4
      Score: 0.92

## Building from Multiple LCMs

Let’s build an atlas from multiple LCMs representing different papers:

``` julia
# LCM from an immunity paper
lcm2 = LocalCausalModel("lcm_immun_001", "chen2023",
    [
        CausalTriple("Vaccination", "increases", "Antibody levels"),
        CausalTriple("Antibody levels", "reduces", "Susceptibility"),
        CausalTriple("Natural infection", "increases", "Antibody levels"),
        CausalTriple("Susceptibility", "increases", "Basic reproduction number"),
    ];
    focus="immunity",
    score=0.88,
    metadata=Dict{String,Any}("stage" => "original", "source_model" => "Claude")
)

# LCM from an intervention paper — overlaps with lcm1
lcm3 = LocalCausalModel("lcm_interv_001", "patel2024",
    [
        CausalTriple("Healthcare capacity", "reduces", "Case fatality rate"),
        CausalTriple("Disease severity", "increases", "Case fatality rate"),
        CausalTriple("Quarantine", "reduces", "Basic reproduction number"),
    ];
    focus="interventions",
    score=0.85,
    metadata=Dict{String,Any}("stage" => "original", "source_model" => "GPT-4")
)

# Build atlas from all three LCMs
builder = AtlasBuilder()
add_lcm!(builder, lcm1)
add_lcm!(builder, lcm2)
add_lcm!(builder, lcm3)

csql = connect_csql()
build!(builder, csql.db)

stats = statistics(csql)
println("Atlas: $(stats[:n_nodes]) nodes, $(stats[:n_edges]) edges, $(stats[:n_support]) support records")
```

    Atlas: 12 nodes, 10 edges, 11 support records

## Querying Provenance

The `atlas_edge_support` table tracks which documents and LCMs support
each edge.

### All Support Records

``` julia
support = custom_query(csql, """
    SELECT es.doc_id, es.lcm_instance_id, es.score,
           n1.label_canon AS src, n2.label_canon AS dst
    FROM atlas_edge_support es
    JOIN atlas_edges e ON es.edge_id = e.edge_id
    JOIN atlas_nodes n1 ON e.src_id = n1.node_id
    JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
    ORDER BY es.doc_id, es.lcm_instance_id
""")
println("Total support records: $(length(support))")
for s in support
    println("  [$(s.doc_id)/$(s.lcm_instance_id)] $(s.src) → $(s.dst)  score=$(round(s.score; digits=2))")
end
```

    Total support records: 11
      [chen2023/lcm_immun_001] vaccination → antibody levels  score=0.88
      [chen2023/lcm_immun_001] antibody levels → susceptibility  score=0.88
      [chen2023/lcm_immun_001] natural infection → antibody levels  score=0.88
      [chen2023/lcm_immun_001] susceptibility → basic reproduction number  score=0.88
      [patel2024/lcm_interv_001] healthcare capacity → case fatality rate  score=0.85
      [patel2024/lcm_interv_001] disease severity → case fatality rate  score=0.85
      [patel2024/lcm_interv_001] quarantine → basic reproduction number  score=0.85
      [smith2023/lcm_trans_001] pathogen virulence → disease severity  score=0.92
      [smith2023/lcm_trans_001] pathogen transmissibility → basic reproduction number  score=0.92
      [smith2023/lcm_trans_001] basic reproduction number → epidemic potential  score=0.92
      [smith2023/lcm_trans_001] disease severity → case fatality rate  score=0.92

### Edges Supported by Multiple Documents

Claims supported by multiple independent sources are more credible:

``` julia
multi_doc = custom_query(csql, """
    SELECT e.rel_type, n1.label_canon AS src, n2.label_canon AS dst,
           e.support_docs, e.support_lcms, e.score_sum
    FROM atlas_edges e
    JOIN atlas_nodes n1 ON e.src_id = n1.node_id
    JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
    WHERE e.support_docs > 1
    ORDER BY e.support_docs DESC
""")
println("Edges with multi-document support:")
for m in multi_doc
    println("  $(m.src) —[$(m.rel_type)]→ $(m.dst)")
    println("    docs=$(m.support_docs), lcms=$(m.support_lcms), total_score=$(round(m.score_sum; digits=2))")
end
if isempty(multi_doc)
    println("  (none — each edge comes from a single document in this example)")
end
```

    Edges with multi-document support:
      disease severity —[INCREASES]→ case fatality rate
        docs=2, lcms=2, total_score=1.77

### Provenance by Document

Which claims does each document contribute?

``` julia
by_doc = custom_query(csql, """
    SELECT es.doc_id,
           COUNT(DISTINCT es.edge_id) AS n_edges,
           COUNT(*) AS n_records,
           SUM(es.score) AS total_score
    FROM atlas_edge_support es
    GROUP BY es.doc_id
    ORDER BY total_score DESC
""")
println("Provenance by document:")
for d in by_doc
    println("  $(d.doc_id): $(d.n_edges) edges, $(d.n_records) support records, score=$(round(d.total_score; digits=2))")
end
```

    Provenance by document:
      smith2023: 4 edges, 4 support records, score=3.68
      chen2023: 4 edges, 4 support records, score=3.52
      patel2024: 3 edges, 3 support records, score=2.55

## Overlapping Claims

When multiple LCMs assert the same causal relationship, CSQL.jl
aggregates them. Let’s find these overlaps:

``` julia
overlaps = custom_query(csql, """
    SELECT e.rel_type, n1.label_canon AS src, n2.label_canon AS dst,
           e.support_lcms, e.score_sum, e.score_mean, e.score_max
    FROM atlas_edges e
    JOIN atlas_nodes n1 ON e.src_id = n1.node_id
    JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
    WHERE e.support_lcms > 1
    ORDER BY e.support_lcms DESC
""")
println("Aggregated edges (multiple LCM support):")
for o in overlaps
    println("  $(o.src) —[$(o.rel_type)]→ $(o.dst)")
    println("    lcms=$(o.support_lcms), sum=$(round(o.score_sum; digits=2)), mean=$(round(o.score_mean; digits=2)), max=$(round(o.score_max; digits=2))")
end
```

    Aggregated edges (multiple LCM support):
      disease severity —[INCREASES]→ case fatality rate
        lcms=2, sum=1.77, mean=0.88, max=0.92

## Edge Metadata

The `atlas_edges` table stores rich metadata about each causal claim:

``` julia
edges = custom_query(csql, """
    SELECT e.rel_type, n1.label_canon AS src, n2.label_canon AS dst,
           e.stage, e.confidence, e.grounded, e.source_model
    FROM atlas_edges e
    JOIN atlas_nodes n1 ON e.src_id = n1.node_id
    JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
    ORDER BY e.score_sum DESC
    LIMIT 5
""")
println("Top 5 edges with metadata:")
for e in edges
    println("  $(e.src) → $(e.dst)")
    println("    stage=$(e.stage), confidence=$(e.confidence), grounded=$(e.grounded), model=$(e.source_model)")
end
```

    Top 5 edges with metadata:
      disease severity → case fatality rate
        stage=validated, confidence=1.0, grounded=not_evaluated, model=GPT-4
      pathogen transmissibility → basic reproduction number
        stage=validated, confidence=1.0, grounded=not_evaluated, model=GPT-4
      pathogen virulence → disease severity
        stage=validated, confidence=1.0, grounded=not_evaluated, model=GPT-4
      basic reproduction number → epidemic potential
        stage=validated, confidence=1.0, grounded=not_evaluated, model=GPT-4
      susceptibility → basic reproduction number
        stage=original, confidence=1.0, grounded=not_evaluated, model=Claude

## Summary

This vignette demonstrated:

- **`LocalCausalModel`** — packaging triples from a single source
- **`add_lcm!`** — batch ingestion of causal models
- **`atlas_edge_support`** — provenance table linking edges to documents
- **Multi-document evidence** — aggregation across independent sources
- **Edge metadata** — stage, confidence, grounding status, source model

Next: [Atlas Merging](../05-merging/merging.html) covers combining
causal databases from different research domains.
