push!(LOAD_PATH, "../src/")
using Documenter
using PlotMGA

makedocs(
    sitename = "PlotMGA",
    format = Documenter.HTML(),
    modules = [PlotMGA],

    )

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo = "github.com/EnergySystemAnalysis-ETH/PlotMGA.jl"
)
