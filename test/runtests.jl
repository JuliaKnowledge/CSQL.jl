using Test
using CSQL

@testset "CSQL.jl" begin

    @testset "Canonicalization" begin
        @test CSQL.canonicalize_label("  Bipedalism  ") == "bipedalism"
        @test CSQL.canonicalize_label("Energy Efficiency") == "energy efficiency"
        @test CSQL.canonicalize_label("A–B") == "a-b"

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
        @test loops isa Vector

        # Controversial claims
        controv = controversial_claims(csql; threshold=0.0)
        @test controv isa Vector
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

end
