# Building

```@docs
AtlasBuilder
add_triple!
add_lcm!
build!
```

`build!` overwrites the atlas tables in the target database so a rebuild does
not leave stale support rows or SCC summaries behind.
