# Querying

## Connection

```@docs
connect_csql
```

## Standard Queries

```@docs
backbone
causal_hubs
effects_of
causes_of
causal_paths
feedback_loops
controversial_claims
statistics
custom_query
```

`effects_of` and `causes_of` default to fuzzy substring matching against the
canonicalized label. Pass `exact=true` for an exact canonical-label match.
