module PlotMGA
    include("plot_mga_data.jl")
    export get_spine_parameter
    export ProfileType
    export plot_all_mga_profiles
    export plot_technology_interactions
    export plot_technology_effects
    export EnergyUnit, MWh, GWh
    export process_spine_data
end
