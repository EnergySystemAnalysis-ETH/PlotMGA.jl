# Manual

This page serves as a guide for running and customizing PlotMGA.jl. For a ready-made example see `example/`.

## Installation

PlotMGA.jl comes as a Julia Package, and can be installed using standard Pkg:
```julia
using Pkg
Pkg.add(url="https://github.com/EnergySystemAnalysis-ETH/PlotMGA.jl")
```

## Input data

PlotMGA.jl expects a database with result outputs produced by a SpineOpt's MGA run. It is preferrable if the Spine inputs were produced by the MORPHE2US pipeline.

## Comparing MGA algorithms

PlotMGA.jl has an inbuilt functionality for comparing different MGA algorithms/parameters with plots. Simply store multiple algorithms' results in a single database, but with a different `Alternative` value (e.g., name of the algorithm).

## Obtaining values to plot
We have to first select the values that we want to plot, e.g., the technological installations and energy flows.

### Processing our results (Optional)
You might skip this paragraph if you are only interested in the SpineOpt's parameters from this list:
- units installed
- unit flows
- total costs
- storages_invested

As SpineOpt's offers a great deal of flexibility for modeling, we might run into many different formats for our data. To solve this issue we give the user the option to model their preprocessing pipeline ad-hoc, with the help of DataFrames. The SpineDB keeps the data (after joining) in a format:
- entity.name - entry details delimited with "__"
- alternative
- value (BSON encoded timeseries)

We process those parameters and obtain a DataFrame with columns: 
- details - list
- alternative
- value - timeseries dict


In order to setup processing of some new parameter type, simply use:
```julia
function process_fn1(df)
    ...
    df
end
function process_fn2(df)
    ...
    df
end
process_spine_data(::Val{:new_type}) = process_fn1 ∘ process_fn2
```
### Getting the data

To obtain the data DataFrames, we can use the  `get_spine_parameter` function:
```julia
db = # Open DB handler
df1 = get_spine_parameter(db, :param_type) 
df2 = get_spine_parameter(db, :param_type2, [col1, col2]) # leaves only the specified columns and sorts on them
```
Examples:
```julia
unit_flows = get_spine_parameter(db, :unit_flow, 
    [:mga_iteration, :alternative, :technology, :installation, :destination, :total_value])
```

## Plotting

### Plotting Profiles
We can plot how the commodity flow profiles change in every MGA iteration. However, there are many profiles we might be interested in. In PlotMGA, we group the profiles, e.g., according to the commodity of the flow.  The group can be defined as:
```julia
group1 = [
    ProfileType(profile_name_1, df_filter_predicate_1),
    ProfileType(profile_name_2, df_filter_predicate_2),
    ...
]
```
If we define many groups, the plotting will be done over all of the possible combinations of group entries.

Then we run:
```julia
plot_all_mga_profiles(
    energy_flows_df, energy_unit, group1, group2, ...,
    fig_prefix="mga_profiles_"
)
```
Example:
```julia
unit_flows = get_spine_parameter(db, :unit_flow, 
    [:mga_iteration, :alternative, :technology, :installation, :destination, :total_value])
commodity_types = [
    ProfileType("Electricity", :destination=>ByRow(contains("Electricity"))),
    ProfileType("Heat", :destination=>ByRow(contains("Space_Heating")))
]
plot_all_mga_profiles(
    unit_flows, PlotMGA.GWh, commodity_types,
    fig_prefix="mga_profiles_"
)
```
### Plotting Technology Effects
We might be interest how our technology in MGA's iteration affect some total system parameters, e.g. CO2 production, costs:
```julia
plot_technology_effects(technology_df, effects_df, fig_prefix="effects_")
```
Example:
```julia
total_costs = get_spine_parameter(db, :total_costs, 
    [:mga_iteration, :alternative, :total_value])
units_invested = get_spine_parameter(db, :units_invested, 
    [:mga_iteration, :alternative, :technology, :installation, :total_value])
plot_technology_effects(
    units_invested, total_costs, 
    fig_prefix="technology_effects_on_cost_"
)
```


### Plotting Technology Interactions
We can plot how the capacity of installed technology reacts with different technological installations, and thus on total system's parameters.

As the plotting is done over every alternative in database (e.g., used algorithm) we have to define markers to differentiate between them. We have to also define the marker for the optimal solution:
```julia
markers = Dict(
    "alg1" => :x,
    "alg2" => :rect,
    "Optimal" => :diamond
)
```

Then we can run:
```julia
plot_technology_interactions(
    technology_df, effects, markers, 
    fig_prefix="technology_interactions_"
)
```
Example
```julia
total_costs = get_spine_parameter(db, :total_costs, 
    [:mga_iteration, :alternative, :total_value])
units_invested = get_spine_parameter(db, :units_invested, 
    [:mga_iteration, :alternative, :technology, :installation, :total_value])
markers = #define markers
plot_technology_interactions(
    units_invested, total_costs, markers, 
    fig_prefix="technology_interactions_", display_plot=false
)
```
