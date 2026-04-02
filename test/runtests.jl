using Test
using CSQL

@testset "CSQL.jl" begin

    @testset "Canonicalization" begin
        @test CSQL.canonicalize_label("  Bipedalism  ") == "bipedalism"
        @test CSQL.canonicalize_label("Energy Efficiency") == "energy efficiency"
        @test CSQL.canonicalize_label("A–B") == "a-b"
        @test CSQL.compute_node_id("alpha") == -3136148774901449766
        @test CSQL.compute_edge_id(CSQL.compute_node_id("a"), CAUSES, CSQL.compute_node_id("b")) == -3604023202922358384

        @test CSQL.normalize_relation("causes")[1] == CAUSES
        @test CSQL.normalize_relation("increases")[1] == INCREASES
        @test CSQL.normalize_relation("reduces")[1] == REDUCES
        @test CSQL.normalize_relation("influences")[1] == INFLUENCES
        @test CSQL.normalize_relation("prevents")[1] == PREVENTS
        @test CSQL.normalize_relation("treats")[1] == TREATS
        @test CSQL.normalize_relation("binds")[1] == BINDS
        @test CSQL.normalize_relation("unknown_xyz")[1] == INFLUENCES  # default

        # Polarity
        @test CSQL.normalize_relation("increases")[2] == INCREASE
        @test CSQL.normalize_relation("reduces")[2] == DECREASE
        @test CSQL.normalize_relation("influences")[2] == UNKNOWN_POL

        # BioLink
        @test CSQL.normalize_relation("biolink:causes") == (CAUSES, UNKNOWN_POL)
        @test CSQL.normalize_relation("biolink:positively_regulates") == (INCREASES, INCREASE)
    end

    @testset "Builder + Queries" begin
        builder = AtlasBuilder()

        # Add epidemiological causal triples
        add_triple!(builder, "Pathogen transmissibility", "increases", "Transmission rate";
                    doc_id="smith2023", lcm_id="lcm_001", score=0.92)
        add_triple!(builder, "Pathogen transmissibility", "increases", "Transmission rate";
                    doc_id="jones2024", lcm_id="lcm_002", score=0.88)
        add_triple!(builder, "Vaccination coverage", "reduces", "Host susceptibility";
                    doc_id="chen2023", lcm_id="lcm_003", score=0.85)
        add_triple!(builder, "Vaccination coverage", "increases", "Population immunity";
                    doc_id="chen2023", lcm_id="lcm_003", score=0.91)
        add_triple!(builder, "Contact rate", "increases", "Transmission rate";
                    doc_id="jones2024", lcm_id="lcm_004", score=0.87)
        add_triple!(builder, "Transmission rate", "increases", "Outbreak severity";
                    doc_id="smith2023", lcm_id="lcm_001", score=0.95)
        add_triple!(builder, "Host susceptibility", "increases", "Transmission rate";
                    doc_id="smith2023", lcm_id="lcm_001", score=0.80)
        add_triple!(builder, "Population immunity", "reduces", "Host susceptibility";
                    doc_id="patel2024", lcm_id="lcm_005", score=0.77)
        add_triple!(builder, "Pathogen transmissibility", "increases", "Case fatality rate";
                    doc_id="smith2023", lcm_id="lcm_002", score=0.68)
        add_triple!(builder, "Healthcare capacity", "reduces", "Case fatality rate";
                    doc_id="patel2024", lcm_id="lcm_005", score=0.88)

        # Build database
        csql = connect_csql()
        build!(builder, csql.db)

        # Statistics
        stats = statistics(csql)
        @test stats[:n_nodes] >= 7
        @test stats[:n_edges] >= 8
        @test stats[:n_support] == 10

        # Backbone
        bb = backbone(csql; limit=5)
        @test length(bb) >= 1
        @test bb[1].score_sum >= bb[end].score_sum  # ordered by score

        # Causal hubs
        hubs = causal_hubs(csql; limit=3)
        @test length(hubs) >= 1
        # Pathogen transmissibility should be the top hub (3 outgoing)
        @test hubs[1].concept == "pathogen transmissibility"

        # Effects of
        effects = effects_of(csql, "vaccination")
        @test length(effects) >= 2  # reduces susceptibility, increases immunity

        # Causes of
        causes = causes_of(csql, "transmission rate")
        @test length(causes) >= 3  # pathogen, contact rate, host susceptibility

        # Causal paths (2-hop)
        paths = causal_paths(csql; limit=10)
        @test length(paths) >= 1
        # Should find: pathogen → transmission rate → outbreak severity
        found_path = any(p -> occursin("pathogen", p.a) && occursin("outbreak", p.c), paths)
        @test found_path

        # Feedback loops
        loops = feedback_loops(csql)
        # Our data has host_susceptibility → transmission_rate and
        # via population_immunity → host_susceptibility but these are not direct 2-cycles
        @test loops isa CausalResult

        # Controversial claims
        controv = controversial_claims(csql; threshold=0.0)
        @test controv isa CausalResult
    end

    @testset "Counterfactual (do-cut)" begin
        builder = AtlasBuilder()
        add_triple!(builder, "A", "increases", "B"; score=1.0)
        add_triple!(builder, "A", "increases", "C"; score=0.8)
        add_triple!(builder, "B", "increases", "D"; score=0.9)
        add_triple!(builder, "C", "increases", "D"; score=0.7)

        csql = connect_csql()
        build!(builder, csql.db)

        # Baseline
        base = backbone(csql; limit=10)
        @test length(base) == 4

        # Do-cut on A
        cf = do_cut(csql, "a"; limit=10)
        @test length(cf) == 2  # only B→D and C→D survive

        # Soft do
        soft = soft_do(csql, "a"; attenuation=0.5, limit=10)
        @test length(soft) == 4  # all edges, but A's scores halved

        # Diff
        diff = do_cut_diff(csql, "a"; limit=10)
        @test length(diff.removed) == 2  # A→B and A→C removed
    end

    @testset "Counterfactual diff uses full atlas" begin
        builder = AtlasBuilder()
        for i in 1:15
            add_triple!(builder, "A", "increases", "B$i"; score=16.0 - i)
        end

        csql = connect_csql()
        build!(builder, csql.db)

        diff = do_cut_diff(csql, "a"; limit=10)
        @test length(diff.baseline) == 10
        @test length(diff.counterfactual) == 0
        @test length(diff.removed) == 10
        @test length(do_cut_diff(csql, "a"; limit=30).removed) == 15
    end

    @testset "LCM Builder" begin
        lcm = LocalCausalModel("lcm_001", "doc_001",
            [CausalTriple("X", "causes", "Y"),
             CausalTriple("Y", "increases", "Z")];
            score=0.9)

        builder = AtlasBuilder()
        add_lcm!(builder, lcm)

        csql = connect_csql()
        build!(builder, csql.db)

        stats = statistics(csql)
        @test stats[:n_nodes] == 3
        @test stats[:n_edges] == 2
    end

    @testset "Atlas Merging" begin
        # Build two separate atlases
        b1 = AtlasBuilder()
        add_triple!(b1, "A", "increases", "B"; doc_id="doc1", score=1.0)
        add_triple!(b1, "B", "increases", "C"; doc_id="doc1", score=0.9)
        csql1 = connect_csql()
        build!(b1, csql1.db)

        b2 = AtlasBuilder()
        add_triple!(b2, "A", "increases", "B"; doc_id="doc2", score=0.8)
        add_triple!(b2, "C", "reduces", "D"; doc_id="doc2", score=0.7)
        csql2 = connect_csql()
        build!(b2, csql2.db)

        # Merge
        merged = connect_csql()
        merge_atlases!(merged, [csql1, csql2]; atlas_ids=["epi", "genomic"])

        stats = statistics(merged)
        @test stats[:n_nodes] == 4  # A, B, C, D
        @test stats[:n_edges] == 3  # A→B (merged), B→C, C→D

        # A→B should have aggregated score
        ab = effects_of(merged, "a")
        @test length(ab) == 1
        @test ab[1].score_sum ≈ 1.8  # 1.0 + 0.8
    end

    @testset "Atlas Merging preserves support semantics" begin
        b1 = AtlasBuilder()
        add_triple!(b1, "A", "increases", "B"; doc_id="shared", lcm_id="l1", score=1.0)
        add_triple!(b1, "A", "increases", "B"; doc_id="doc1", lcm_id="l2", score=0.5)
        csql1 = connect_csql()
        build!(b1, csql1.db)

        b2 = AtlasBuilder()
        add_triple!(b2, "A", "increases", "B"; doc_id="shared", lcm_id="l3", score=0.8)
        csql2 = connect_csql()
        build!(b2, csql2.db)

        merged = connect_csql()
        merge_atlases!(merged, [csql1, csql2])

        edge = only(custom_query(merged, "SELECT support_lcms, support_docs, score_sum, score_mean FROM atlas_edges"))
        @test edge.support_lcms == 3
        @test edge.support_docs == 2
        @test edge.score_sum ≈ 2.3
        @test edge.score_mean ≈ (2.3 / 3)
    end

    @testset "SCC Detection" begin
        builder = AtlasBuilder()
        # Create a feedback loop: A→B→C→A
        add_triple!(builder, "A", "increases", "B"; score=1.0)
        add_triple!(builder, "B", "increases", "C"; score=0.9)
        add_triple!(builder, "C", "increases", "A"; score=0.8)
        # Plus a non-loop edge
        add_triple!(builder, "A", "influences", "D"; score=0.5)

        csql = connect_csql()
        build!(builder, csql.db)

        # Check SCC table has the A-B-C cycle
        sccs = custom_query(csql, "SELECT * FROM atlas_scc")
        @test length(sccs) >= 1
        @test sccs[1].n_nodes == 3
    end

    @testset "SCC support docs and merge rebuild" begin
        builder = AtlasBuilder()
        add_triple!(builder, "A", "increases", "B"; doc_id="doc1", score=1.0)
        add_triple!(builder, "B", "increases", "C"; doc_id="doc2", score=0.9)
        add_triple!(builder, "C", "increases", "A"; doc_id="doc3", score=0.8)
        csql = connect_csql()
        build!(builder, csql.db)

        scc = only(custom_query(csql, "SELECT support_docs FROM atlas_scc"))
        @test scc.support_docs == 3

        b1 = AtlasBuilder()
        add_triple!(b1, "A", "increases", "B"; doc_id="doc1", score=1.0)
        add_triple!(b1, "B", "increases", "C"; doc_id="doc2", score=0.9)
        csql1 = connect_csql()
        build!(b1, csql1.db)

        b2 = AtlasBuilder()
        add_triple!(b2, "C", "increases", "A"; doc_id="doc3", score=0.8)
        csql2 = connect_csql()
        build!(b2, csql2.db)

        merged = connect_csql()
        merge_atlases!(merged, [csql1, csql2])

        merged_scc = only(custom_query(merged, "SELECT n_nodes, support_docs FROM atlas_scc"))
        @test merged_scc.n_nodes == 3
        @test merged_scc.support_docs == 3
    end

    @testset "Custom Query" begin
        builder = AtlasBuilder()
        add_triple!(builder, "X", "causes", "Y"; score=1.5)
        csql = connect_csql()
        build!(builder, csql.db)

        rows = custom_query(csql, """
            SELECT n1.label_canon AS src, n2.label_canon AS dst, e.score_sum
            FROM atlas_edges e
            JOIN atlas_nodes n1 ON e.src_id = n1.node_id
            JOIN atlas_nodes n2 ON e.dst_id = n2.node_id
        """)
        @test length(rows) == 1
        @test rows[1].src == "x"
        @test rows[1].dst == "y"
        @test rows[1].score_sum ≈ 1.5
    end

    @testset "Exact query matching and empty statistics" begin
        builder = AtlasBuilder()
        add_triple!(builder, "Heart rate", "increases", "Blood pressure"; score=1.0)
        add_triple!(builder, "Transmission rate", "increases", "Outbreak severity"; score=0.9)
        csql = connect_csql()
        build!(builder, csql.db)

        @test length(effects_of(csql, "rate")) == 2
        @test isempty(effects_of(csql, "rate"; exact=true))

        exact = effects_of(csql, "heart rate"; exact=true)
        @test length(exact) == 1
        @test exact[1].dst == "blood pressure"

        empty_stats = statistics(connect_csql())
        @test empty_stats[:min_score] == 0.0
        @test empty_stats[:max_score] == 0.0
        @test empty_stats[:avg_score] == 0.0
    end

    @testset "Symmetric Relations" begin
        builder = AtlasBuilder()
        # "A binds B" and "B binds A" should map to the same canonical edge
        add_triple!(builder, "protein A", "binds", "protein B"; score=0.9)
        add_triple!(builder, "protein B", "binds", "protein A"; score=0.8)

        csql = connect_csql()
        build!(builder, csql.db)

        stats = statistics(csql)
        @test stats[:n_edges] == 1  # deduplicated
        bb = backbone(csql)
        @test bb[1].score_sum ≈ 1.7  # 0.9 + 0.8 aggregated
    end

    @testset "Provenance (EdgeSupport)" begin
        builder = AtlasBuilder()
        add_triple!(builder, "A", "causes", "B"; doc_id="paper1", lcm_id="lcm1", score=0.9)
        add_triple!(builder, "A", "causes", "B"; doc_id="paper2", lcm_id="lcm2", score=0.8)
        add_triple!(builder, "A", "causes", "B"; doc_id="paper2", lcm_id="lcm3", score=0.7)

        csql = connect_csql()
        build!(builder, csql.db)

        # 3 support rows for 1 edge
        support = custom_query(csql, "SELECT * FROM atlas_edge_support")
        @test length(support) == 3

        # Edge aggregates correctly
        edges = custom_query(csql, "SELECT * FROM atlas_edges")
        @test length(edges) == 1
        @test edges[1].support_lcms == 3
        @test edges[1].support_docs == 2  # paper1, paper2
        @test edges[1].score_sum ≈ 2.4
    end

    @testset "DuckDB Backend" begin
        # Basic builder + query
        builder = AtlasBuilder()
        add_triple!(builder, "Pathogen", "increases", "Transmission";
                    doc_id="doc1", score=0.9)
        add_triple!(builder, "Vaccination", "reduces", "Susceptibility";
                    doc_id="doc2", score=0.85)
        add_triple!(builder, "Susceptibility", "increases", "Transmission";
                    doc_id="doc1", score=0.8)

        csql = connect_csql(; backend=:duckdb)
        build!(builder, csql.db)

        stats = statistics(csql)
        @test stats[:n_nodes] == 4
        @test stats[:n_edges] == 3

        # Backbone
        bb = backbone(csql; limit=5)
        @test length(bb) == 3

        # Effects / causes
        eff = effects_of(csql, "pathogen")
        @test length(eff) >= 1

        cau = causes_of(csql, "transmission")
        @test length(cau) >= 2

        # Causal paths
        paths = causal_paths(csql; limit=10)
        @test length(paths) >= 1

        # Hubs
        hubs = causal_hubs(csql; limit=5)
        @test length(hubs) >= 1

        # Counterfactual
        cf = do_cut(csql, "pathogen"; limit=10)
        @test length(cf) == 2  # only susceptibility→transmission and vaccination→susceptibility

        # Custom query
        rows = custom_query(csql, "SELECT COUNT(*) AS n FROM atlas_nodes")
        @test rows[1].n == 4
    end

    @testset "Rebuild overwrites atlas tables" begin
        builder = AtlasBuilder()
        add_triple!(builder, "A", "causes", "B"; doc_id="doc1", lcm_id="l1", score=1.0)
        csql = connect_csql()
        build!(builder, csql.db)

        CSQL.reset!(builder)
        add_triple!(builder, "X", "causes", "Y"; doc_id="doc2", lcm_id="l2", score=2.0)
        build!(builder, csql.db)

        stats = statistics(csql)
        @test stats[:n_nodes] == 2
        @test stats[:n_edges] == 1
        @test stats[:n_support] == 1

        edge = only(custom_query(csql, "SELECT score_sum FROM atlas_edges"))
        @test edge.score_sum ≈ 2.0
    end

    @testset "Deep causal_paths keeps valid aliases" begin
        builder = AtlasBuilder()
        for i in 1:26
            add_triple!(builder, "N$i", "increases", "N$(i + 1)"; score=1.0)
        end
        csql = connect_csql()
        build!(builder, csql.db)

        paths = causal_paths(csql; depth=26, limit=1)
        @test length(paths) == 1
        @test hasproperty(paths[1], :n27)
        @test getproperty(paths[1], :n27) == "n27"
    end

    @testset "CausalResult behaves like a collection" begin
        result = CausalResult([(x=1,), (x=2,)], "numbers")
        @test collect(result) == [(x=1,), (x=2,)]
        @test map(r -> r.x, result) == [1, 2]

        filtered = filter(r -> r.x == 2, result)
        @test filtered isa CausalResult
        @test length(filtered) == 1
        @test filtered[1].x == 2
    end

end
