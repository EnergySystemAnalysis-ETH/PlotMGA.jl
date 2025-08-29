using SQLite
using DataFrames
using JSON
using StatsPlots
import Base: Fix1, Fix2
import Base.Iterators: product

"""
    get_parameter_value(db, param_name)

Get parameter value from a `db` in a SpineDB format.

Returns a df with columns:
- `alternative` - SpineDB alternative (e.g., used method)
- `value` - parameter value
- `details` - list of fields from the Spine's entity name (e.g., parameter name, mga iteration, technology)
"""
function get_parameter_value(db, param_name)
    params = DBInterface.execute(db, """
        SELECT alternative.name AS alternative, value, entity.name AS details 
        FROM parameter_value 
        JOIN entity ON parameter_value.entity_id = entity.id 
        JOIN alternative ON alternative.id = parameter_value.alternative_id 
        WHERE parameter_definition_id = (SELECT id FROM parameter_definition WHERE name="$param_name");
    """) |> DataFrame
    # parameter values in SpineDB are kept in a Dict("data"=>value, ...) encoded as a BSON
    params.value = params.value .|> String .|> JSON.parse .|> (v -> v["data"])
    # entity names are made up of fields delimited by "__"
    params.details = split.(params.details, "__")
    params
end

"""
    sum_timeseries(params::DataFrame)

Adds `total_value` with sum of values to a df with `value`.

Each of the values should be a Dict with datetime as keys and floats as values.
"""
function sum_timeseries(params::DataFrame)
    total_value = params.value .|> values .|> sum
    insertcols(params, :total_value=>total_value)
end

"""
    add_mga_iteration(params::DataFrame)

Adds `mga_iteration` with the MGA iteration number to a df with `details` of a SpineOpt's entity.

The SpineOpt's MGA data should always the last entry in `details`, with a format "mga_it_NUMBER".
"""
function add_mga_iteration(params::DataFrame)
    # processes (...,"mga_it_NUMBER") entries to simply NUMBER
    mga_iteration = params.details .|> last .|> Fix2(split, "_") .|> last .|> Fix1(parse, Int64)
    insertcols(params, :mga_iteration=>mga_iteration)
end

"""
    process_technology(params::DataFrame)

Adds `technology` and `installation` to a df with the `details` of a SpineOpt's entity.

The MORPHE2US technology data should always comes as a second in `details`, with a format
"`TECHNOLOGY_NAME`_(B|D)_LVL_`INSTALLATION_SITE`".
"""
function process_technology(params::DataFrame)
    # MORPHE2US + Spine details are be in form (entry1,"TECHNOLOGY_NAME_(B|D)_LVL_INSTALLATION_SITE", ...)
    tech_data = get.(params.details, 2, nothing)
    installation = tech_data .|> x -> match(r"(B|D)-LVL.*", x).match 
    technology = replace.(tech_data, r"_\w-LVL.*" => "")
    insertcols(params, :installation=>installation, :technology=>technology)
end

"""
    process_flows(params::DataFrame)

    Adds `destination` to a df with the `details` of a SpineOpt's entity, and keeps only inflows.

    The MORPHE2US destination data should always comes as a third in `details`.
"""
function process_flows(params::DataFrame)
    # Spine details for nodes contain fields to_node (inflows) or from_node (outflow)
    # Actual amount of commodity that is supplied is denoted by inflows
    params = filter(:details=>x->"to_node" in x, params)
    # MORPHE2US + Spine details for flows are in the form (entry1, entry2, destination)
    destination = get.(params.details, 3, nothing)
    insertcols(params, :destination=>destination)
end

"""
    process(::Val{DB_ENTRY}) where {DB_ENTRY}

    Returns processing pipeline for the database entry.
"""
process(x) =                            add_mga_iteration ∘ sum_timeseries
process(::Val{:storages_invested}) =    add_mga_iteration ∘ sum_timeseries ∘ process_technology
process(::Val{:units_invested}) =       add_mga_iteration ∘ sum_timeseries ∘ process_technology
process(::Val{:unit_flow}) =            add_mga_iteration ∘ sum_timeseries ∘ process_technology ∘ process_flows

sort_by_cols(df::DataFrame) = sort(df, names(df))

"""
    get_param(db, param_name::Symbol[, col_order])
    
Grabs the parameter from a SpineOpt's database and processess it according to the parameter name.

The option parameter col_order specifies the only columns that should be in the output and their order.
Those columns should be sortable.
"""
get_param(db, param_name::Symbol) = get_parameter_value(db, param_name) |> process(Val(param_name))
get_param(db, param_name::Symbol, col_order) = get_param(db, param_name) |> Fix2(select, col_order) |> sort_by_cols

"""
    EnergyUnit MWh=1 GWh=1000

The multiplicities of SpineOpt's native flow unit - MWh
"""
@enum EnergyUnit MWh=1 GWh=1000

"""
    squash_groups(df, kept_cols[, combine_col])

Keep only columns with unique values of kept_cols, and squash the rest.

If `combine_cols` is passed, the column values are summed. If not, only the first entry is retained.
"""
squash_groups(df, kept_cols) = combine(groupby(df, kept_cols), first)
squash_groups(df, kept_cols, combine_col) = combine(groupby(df, kept_cols), combine_col=>sum=>combine_col)

"""
    change_col_units(df, unit::EnergyUnit, column::Symbol)

Changes the colums energy units to those passed.
"""
change_col_units(df, unit::EnergyUnit, column::Symbol) = transform(df, column=>ByRow(x->x/Int(unit))=>column)

"""
    by_pairs(df, group_cols)

Groups df and create the iterator in the form `group_column_values, subdf`
"""
by_pairs(df, group_cols) = pairs(groupby(df, group_cols))

"""
    plot_mga_profile(
        df, unit::EnergyUnit;
        iteration_col::Symbol=:mga_iteration, value_col::Symbol=:total_value, stackby::Symbol=:technology
    )

Plots stacked flow profiles for a df describing a single MGA run.
"""
function plot_mga_profile(
        df, unit::EnergyUnit; 
        iteration_col::Symbol=:mga_iteration, value_col::Symbol=:total_value, stackby::Symbol=:technology
    )
    df = squash_groups(df, [iteration_col, stackby], value_col) 
    df = change_col_units(df, unit, value_col)
    no_iterations = maximum(df[!, iteration_col])
    mga_x_axis = (0:no_iterations, ["Optim."; 1:no_iterations]) # We want a special marker on optimal (iter=0)
    groupedbar(
        df[!, iteration_col], 
        df[!, value_col], 
        group=df[!, stackby],
        bar_position=:stack,
        xlabel="MGA Iteration",
        ylabel="Output [$unit]",
        xticks=mga_x_axis,
        legend=:bottomright
    )
end

"""
    struct ProfileType
        name::String # profile name
        df_predicate::Pair # df filter predicate
    end

Describes a single flow profile. The predicate greps all of the flows from a master flow df.

# Example

type1 = ProfileType("Electricity", :destination=>ByRow(contains("Electricity")))

type2 = ProfileType("Heat", :destination=>ByRow(contains("Space_Heating")))

df_electricity = subset(master_df, type1.df_predicate)

df_heat = subset(master_df, type2.df_predicate)
"""
struct ProfileType
    name::String
    df_predicate::Pair
end

struct CombinedProfileTypes
    names::Vector{String}
    df_predicates::Vector{Pair}

    CombinedProfileTypes(types::Vector{ProfileType}) = new(
        getfield.(types, :df_predicate), getfield.(types, :name)
    )
end

"""
    combine_profiles(profile_types::Vector{ProfileType}...)

Produces all combinations of flow profile types from multiple lists.
"""
combine_profiles(profile_types::Vector{ProfileType}...) = map(CombinedProfileTypes, product(profile_types...))

"""
    annotate_df_by_profiles(df, combined_profiles::Vector{CombinedProfileTypes})

Adds a column `type` based on fulfilling the combined profile predicates.

The entries not fulfilling any predicates will be discarded. 

Entries fulfilling multiple combinations will be multiplied.
"""
annotate_df_by_profiles(df, combined_profiles::Vector{CombinedProfileTypes}) = vcat(
        (
            subset(df, profile.df_predicates...) |> Fix2(insertcols, :type=>profile.names)
            for profile in combined_profiles
        )...
) 

"""
    plot_mga_alternative_profiles(
        df, unit::EnergyUnit;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )

Plots flow profiles of a single type across all of the alternatives present in df field `alternative`. 
Every alternative produces a single figure.

If the figures are to be saved `fig_prefix` is added to the filename.
"""
function plot_mga_alternative_profiles(
        df, unit::EnergyUnit; 
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )
    plots = Dict(
            alternative => plot_mga_profile(subdf, unit)
            for ((;alternative), subdf) in by_pairs(df, :alternative)
        )
    # We have to make sure that plots for every alternative are of the same height
    max_y = (plots |> values .|> ylims .|> x -> x[2]) |> maximum
    for (alt, p) in plots
        plot!(p, ylim=(0, max_y))
        save_plot && savefig("$(fig_prefix)$alt.png")
        display_plot && display(p)
    end
end

"""
    plot_all_mga_profiles(
        df, unit::EnergyUnit, profile_types::Vector{ProfileType}...;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )

Plots all profiles for every flow type combination and every alternative from the df column `alternative`.
"""
function plot_all_mga_profiles(
        df, unit::EnergyUnit, profile_types::Vector{ProfileType}...;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )
    combined_profiles = combine_profiles(profile_types...)
    annotated_df = annotate_df_by_profiles(df, combined_profiles)
    for ((;type), subdf) in by_pairs(annotated_df, :type)
        combined_type_name = join(type, " ")
        plot_mga_alternative_profiles(
            subdf, unit,
            fig_prefix="$(fig_prefix)$(combined_type_name)_", display_plot=display_plot, save_plot=save_plot
        )  
    end
end

"""
    annotate_optimal_solutions(df)

Changes the `alternative` field for optimal solutions from the MGA process.
"""
function annotate_optimal_solutions(df)
    # Optimal solution is obtained by MGA in the 0th iteration
    nonoptimal = filter(:mga_iteration=> !=(0), df)
    optimal = filter(:mga_iteration=> ==(0), df)
    optimal.alternative .= "Optimal"
    vcat(nonoptimal, optimal)
end

"""
    connect_technology_with_effects(df, effects_df)

Assigns total system effects to iterations from appropriate alternatives. 

For example, connects technology installation with total system costs.
"""
function connect_technology_with_effects(df, effects_df)
    df = squash_groups(df, [:mga_iteration, :alternative, :technology], :total_value)
    df = innerjoin(df, effects_df, on=[:mga_iteration, :alternative], renamecols=""=>"_effects")
    df = annotate_optimal_solutions(df)
    df
end

"""
    obtain_technology_interactions(df, effects_df)

Produces a df describing a matrix of interactions between different technology installations
and their effects (e.g., total system costs).
"""
function obtain_technology_interactions(df, effects_df)
    df = connect_technology_with_effects(df, effects_df)
    df = outerjoin(df, df, on=[:mga_iteration, :alternative, :total_value_effects], renamecols= "_1st" => "_2nd")
    df
end

"""
    plot_technology_interactions_by_alternative(
        df, plot, alternative_markers::AbstractDict;
        x_technology_col::Symbol=:total_value_1st, y_technology_col::Symbol=:total_value_2nd, effect_col::Symbol=:total_value_effects
    )

Modifies the passed plot by adding point corresponding to the technology interactions per every alternative.
The points are colored according to the `effect_col` from df.

To tell apart values from different alternatives (e.g., used algorithm) we have to pass dict of markers with an entry for each alternative.
"""
function plot_technology_interactions_by_alternative(
        df, plot, alternative_markers::AbstractDict;
        x_technology_col::Symbol=:total_value_1st, y_technology_col::Symbol=:total_value_2nd, effect_col::Symbol=:total_value_effects
    )
    for ((;alternative), subdf) in by_pairs(df, :alternative)
        scatter!(
            plot,
            subdf[!, x_technology_col],
            subdf[!, y_technology_col],
            zcolor=subdf[!, effect_col],
            seriestype=:scatter,
            marker=alternative_markers[alternative],
            label=alternative
        )
    end
end

#TODO: tech multiplication by capacities
#TODO: tech different units (Wh vs W)
"""
    plot_technology_interactions(
        tech_df, effects_df, alternative_markers::AbstractDict;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )

Creates a plot for every pair of the technologies, showing interactions between their installed capacities 
and effects (e.g., total system costs). Every plot has entries from all of the alternatives from df.

To tell apart the alternatives, we have to pass Dict of markers.

If the figures are to be saved `fig_prefix` is added to the filename.
"""
function plot_technology_interactions(
        tech_df, effects_df, alternative_markers::AbstractDict;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )
    df = obtain_technology_interactions(tech_df, effects_df)
    for ((;technology_1st, technology_2nd), subdf) in by_pairs(df, [:technology_1st, :technology_2nd])
        p = plot(xlabel=technology_1st, ylabel=technology_2nd) #empty plot with technology names
        plot_technology_interactions_by_alternative(subdf, p, alternative_markers)
        display_plot && display(p)
        save_plot && savefig("$(fig_prefix)$(technology_1st)_$(technology_2nd).png")
    end
end

"""
    plot_technology_effects_by_alternative(
        df, plot;
        technology_col::Symbol=:total_value, effect_col::Symbol=:total_value_effects
    )

Modifies the passed plot by adding point corresponding to the technology and its effects in every alternative.
"""
function plot_technology_effects_by_alternative(
        df, plot;
        technology_col::Symbol=:total_value, effect_col::Symbol=:total_value_effects
    )
    for ((;alternative), subdf) in by_pairs(df, :alternative)
        scatter!(
            plot,
            subdf[!, technology_col],
            subdf[!, effect_col],
            label=alternative
        )
    end 
end

"""
    plot_technology_effects(
        tech_df, effects_df;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )

Creates a plot for every technology and show effects of its installation on the total system state (e.g., total system_costs)
    
If the figures are to be saved `fig_prefix` is added to the filename.
"""
function plot_technology_effects(
        tech_df, effects_df;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )
    df = connect_technology_with_effects(tech_df, effects_df)
    for ((;technology), subdf) in by_pairs(df, :technology)
        p = plot(xlabel="Installation", ylabel="Total system costs [\$]") # empty plot
        plot_technology_effects_by_alternative(subdf, p)
        display_plot && display(p)
        save_plot && savefig("$(fig_prefix)$technology.png")
    end
end