using SSCWeb
using Dates
using Test
using Aqua

@testset "Aqua" begin
    Aqua.test_all(SSCWeb)
end

ENV["SSCWEB_DIR"] = mktempdir()
const t0, t1 = "2020-01-01", "2020-01-01T02"

@testset "catalogs" begin
    mms1 = only(filter(o -> o.id == "mms1", observatories()))
    @test mms1.start < DateTime(2016) < mms1.stop
    @test any(g -> g.id == "SPA" && g.lat < -89, ground_stations())
end

@testset "locations" begin
    coords = (:geo, :gm, :gse, :gsm, :sm, :geitod, :geij2000)
    l = locations("themisa", t0, t1, coords..., :r, :bmag, :b_gse, :region, :foot_south, :foot_north, :len_north)
    @test keys(l) == (:time, coords..., :r, :bmag, :b_gse, :region, :foot_south, :foot_north, :len_north)
    @test vec(sqrt.(sum(abs2, l.b_gse; dims = 2))) ≈ l.bmag rtol = 1.0e-6
    @test l.time[1] == DateTime(t0) && issorted(l.time)
    for cs in coords
        @test vec(sqrt.(sum(abs2, l[cs]; dims = 2))) ≈ l.r rtol = 1.0e-6
    end
    @test l.gsm[:, 1] ≈ l.gse[:, 1]
    @test l.region[1] == :DAYSIDE_MAGNETOSPHERE
    @test all(>(0), l.foot_north[:, 1]) && all(<(0), l.foot_south[:, 1])
    @test all(>(0), l.len_north)

    gse = locations("themisa", t0, t1).gse
    @test locations("themisa", t0, t1; resolution_factor = 10).gse == gse[1:10:end, :]
end

@testset "empty results" begin
    @test isempty(locations("mms1", "2010-01-01", "2010-01-02", :gse, :region).region)
    l = locations("ace", "2020-01-01T00:01", "2020-01-01T00:10", :gse; cache = false)
    @test isempty(l.time) && size(l.gse) == (0, 3)
end

@testset "fill values" begin
    l = locations("ace", t0, t1, :foot_north)
    @test all(isnan, l.foot_north)
end

@testset "cache" begin
    t0c, t1c = DateTime("2020-03-01T06"), DateTime("2020-03-03T12")
    a = locations("mms1", t0c, t1c, :gsm)
    b = locations("mms1", t0c, t1c, :gsm, :region)
    c = locations("mms1", t0c, t1c, :gsm, :region; cache = false)
    @test a.time == b.time == c.time
    @test a.gsm == b.gsm == c.gsm
    @test b.region == c.region
    d = locations("mms1", t0c, t1c, :region, :gsm)
    @test d.region == c.region && d.gsm == c.gsm
    @test all(d -> isfile(SSCWeb.day_path("mms1", 1, d)), Date(t0c):Day(1):Date(t1c))
end

@testset "errors" begin
    @test_throws ErrorException locations("notacraft", t0, t1)
    @test_throws ArgumentError locations("ace", t0, t1, :xyz)
end
