module PlotMGA
    include("plot_mga_data.jl")
    export get_param
    export ProfileType
    export plot_all_mga_profiles
    export plot_technology_interactions
    export plot_technology_effects
    export EnergyUnit, MWh, GWh
end
