using Documenter
using CSQL

makedocs(;
    sitename = "CSQL.jl",
    authors = "Simon Frost",
    modules = [CSQL],
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://JuliaKnowledge.github.io/CSQL.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Tutorial" => "tutorial.md",
        "API Reference" => [
            "Types" => "api/types.md",
            "Building" => "api/building.md",
            "Querying" => "api/querying.md",
            "Counterfactual" => "api/counterfactual.md",
            "Merging" => "api/merging.md",
            "Internals" => "api/internals.md",
        ],
    ],
)

deploydocs(;
    repo = "github.com/JuliaKnowledge/CSQL.jl.git",
    devbranch = "main",
)
