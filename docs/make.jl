push!(LOAD_PATH, "../src/")
using Documenter
using PlotMGA

makedocs(
    sitename = "PlotMGA",
    format = Documenter.HTML(),
    modules = [PlotMGA],

    )