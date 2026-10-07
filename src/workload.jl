using PrecompileTools: @setup_workload, @compile_workload

# Offline: a canned Jackson-typed response and a pre-written cache day stand in for the server.
@setup_workload begin
    tag(x) = ["java.util.ArrayList", x]
    obj(x) = ["gov.nasa.gsfc.sscweb.schema.Object", x]
    floats2 = tag([1.0, -1.0e31])
    xyz(k) = Dict(k * "X" => floats2, k * "Y" => floats2, k * "Z" => floats2)
    sat = Dict{String, Any}(
        "Id" => "sc",
        "Time" => tag([["javax.xml.datatype.XMLGregorianCalendar", "2020-01-01T00:0$(i):00.000+00:00"] for i in 0:1]),
        "Coordinates" => tag([obj(merge(xyz(""), Dict("CoordinateSystem" => uppercase(c)))) for c in values(COORDS)]),
        "BtraceData" => tag([obj(Dict("Hemisphere" => uppercase(h), "Latitude" => floats2, "Longitude" => floats2, "ArcLength" => floats2)) for h in ("North", "South")]),
        xyz("Bgse")...,
    )
    for (v, (_, _, field)) in pairs(SCALARS)
        sat[field] = startswith(String(v), "region") ? tag(["NOT_APPLICABLE", "LOW_LATITUDE"]) : floats2
    end
    response = obj(Dict("Result" => obj(Dict("StatusCode" => "SUCCESS", "Data" => tag([obj(sat)])))))
    json = JSON.json(response)
    dir = mktempdir()
    @compile_workload begin
        vars = collect(VARS)
        data_request("sc", DateTime(2020), DateTime(2020, 1, 2), vars)
        result = untag(JSON.parse(json))["Result"]
        check_status(result)
        data = satellite_data(only(result["Data"]), vars)
        withenv("SSCWEB_DIR" => dir) do
            foreach(d -> write_day(day_path("sc", 1, d), data), (Date(2020, 1, 1), Date(2020, 1, 2)))
            locations("sc", "2020-01-01", "2020-01-02T12", :gse)
            locations("sc", DateTime(2020), DateTime(2020, 1, 2, 12), :gsm, :region, :foot_north, :L)
        end
    end
    rm(dir; recursive = true)
end

# Workload calls get inlined into the closure; REPL calls dispatch to these standalone instances.
for T in (String, DateTime, Date), n in 1:4
    precompile(locations, (String, T, T, ntuple(_ -> Symbol, n)...))
end
