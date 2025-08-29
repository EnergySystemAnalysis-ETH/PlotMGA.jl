using SQLite
using DataFrames
using JSON
using StatsPlots
import Base: Fix1, Fix2
import Base.Iterators: product

function get_parameter_value(db, param_name)
    params = DBInterface.execute(db, """
        SELECT alternative.name AS alternative, value, entity.name AS details 
        FROM parameter_value 
        JOIN entity ON parameter_value.entity_id = entity.id 
        JOIN alternative ON alternative.id = parameter_value.alternative_id 
        WHERE parameter_definition_id = (SELECT id FROM parameter_definition WHERE name="$param_name");
    """) |> DataFrame
    params.value = params.value .|> String .|> JSON.parse .|> (v -> v["data"])
    params.details = split.(params.details, "__")
    params
end

function process_timeseries(params::DataFrame)
    total_value = params.value .|> values .|> sum
    insertcols(params, :total_value=>total_value)
end

function process_mga_iteration(params::DataFrame)
    mga_iteration = params.details .|> last .|> Fix2(split, "_") .|> last .|> Fix1(parse, Int64)
    insertcols(params, :mga_iteration=>mga_iteration)
end

function process_technology(params::DataFrame)
    tech_data = get.(params.details, 2, nothing)
    installation = tech_data .|> x -> match(r"(B|D)-LVL.*", x).match
    technology = replace.(tech_data, r"_\w-LVL.*" => "")
    insertcols(params, :installation=> installation, :technology=>technology)
end

function process_flows(params::DataFrame)
    params = filter(:details=>x->"to_node" in x, params)
    destination = get.(params.details, 3, nothing)
    insertcols(params, :destination=>destination)
end

process(x) = process_mga_iteration ∘ process_timeseries
process(::Val{:storages_invested}) = process_mga_iteration ∘ process_timeseries ∘ process_technology
process(::Val{:units_invested}) = process_mga_iteration ∘ process_timeseries ∘ process_technology
process(::Val{:unit_flow}) = process_mga_iteration ∘ process_timeseries ∘ process_technology ∘ process_flows

sort_by_cols(df::DataFrame) = sort(df, names(df))

get_param(db, param_name::Symbol) = get_parameter_value(db, param_name) |> process(Val(param_name))
get_param(db, param_name::Symbol, col_order) = get_param(db, param_name) |> Fix2(select, col_order) |> sort_by_cols

@enum EnergyUnit MWh=1 GWh=1000

squash_groups(df, kept_cols) = combine(groupby(df, kept_cols), first)
squash_groups(df, kept_cols, combine_col) = combine(groupby(df, kept_cols), combine_col=>sum=>combine_col)
process_units(df, unit::EnergyUnit, column::Symbol) = transform(df, column=>ByRow(x->x/Int(unit))=>column)
mga_x_axis(no_iterations) = (0:no_iterations, ["Optim."; 1:no_iterations])

by_pairs(df, group_cols) = pairs(groupby(df, group_cols))

function plot_mga_profile(
        df, unit::EnergyUnit, 
        iteration_col::Symbol=:mga_iteration, value_col::Symbol=:total_value, stackby::Symbol=:technology
    )
    df = squash_groups(df, [iteration_col, stackby], value_col)
    df = process_units(df, unit, value_col)
    no_iterations = maximum(df[!, iteration_col])
    groupedbar(
        df[!, iteration_col], 
        df[!, value_col], 
        group=df[!, stackby],
        bar_position=:stack,
        xlabel="MGA Iteration",
        ylabel="Output [$unit]",
        xticks=mga_x_axis(no_iterations),
        legend=:bottomright
    )
end

struct ProfileType
    name::String
    df_predicate::Pair
end

combine_profiles(profile_types::AbstractArray{ProfileType}...) = (
    (getfield.(types, :df_predicate), getfield.(types, :name))
    for types in product(profile_types...)
)

annotate_df_by_profiles(df, combined_profiles) = vcat(
        (
            subset(df, combined_predicates...) |> Fix2(insertcols, :type=>combined_names)
            for (combined_predicates, combined_names) in combined_profiles
        )...
) 

function plot_mga_alternative_profiles(
        df, unit::EnergyUnit; 
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )
    plots = Dict(
            alternative => plot_mga_profile(subdf, unit)
            for ((;alternative), subdf) in by_pairs(df, :alternative)
        )
    max_y = (plots |> values .|> ylims .|> x -> x[2]) |> maximum
    for (alt, p) in plots
        plot!(p, ylim=(0, max_y))
        save_plot && savefig("$(fig_prefix)$alt.png")
        display_plot && display(p)
    end
end

function plot_all_mga_profiles(
        df, unit::EnergyUnit, profile_types::AbstractArray{ProfileType}...;
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

function annotate_optimal_solutions(df)
    nonoptimal = filter(:mga_iteration=> !=(0), df)
    optimal = filter(:mga_iteration=> ==(0), df)
    optimal.alternative .= "Optimal"
    vcat(nonoptimal, optimal)
end

function connect_technology_with_costs(df, effects_df)
    df = squash_groups(df, [:mga_iteration, :alternative, :technology], :total_value)
    df = innerjoin(df, effects_df, on=[:mga_iteration, :alternative], renamecols=""=>"_effects")
    df = annotate_optimal_solutions(df)
    df
end

function obtain_technology_interactions(df, effects_df)
    df = connect_technology_with_costs(df, effects_df)
    df = outerjoin(df, df, on=[:mga_iteration, :alternative, :total_value_effects], renamecols= "_1st" => "_2nd")
    df
end

function plot_technology_interactions_by_alternative(df, plot, alternative_markers)
    for ((;alternative), subdf) in by_pairs(df, :alternative)
        scatter!(
            plot,
            subdf.total_value_1st,
            subdf.total_value_2nd, 
            zcolor=subdf.total_value_effects,
            seriestype=:scatter,
            marker=alternative_markers[alternative],
            label=alternative
        )
    end
end

#TODO: tech multiplication by capacities
#TODO: tech different units (Wh vs W)
function plot_technology_interactions(
        tech_df, effects_df, alternative_markers::AbstractDict;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )
    df = obtain_technology_interactions(tech_df, effects_df)
    for ((;technology_1st, technology_2nd), subdf) in by_pairs(df, [:technology_1st, :technology_2nd])
        p = plot(xlabel=technology_1st, ylabel=technology_2nd)
        plot_technology_interactions_by_alternative(subdf, p, alternative_markers)
        display_plot && display(p)
        save_plot && savefig("$(fig_prefix)$(technology_1st)_$(technology_2nd).png")
    end
end

function plot_technology_effects_by_alternative(df, plot)
    for ((;alternative), subdf) in by_pairs(df, :alternative)
        scatter!(
            plot,
            subdf.total_value,
            subdf.total_value_effects,
            label=alternative
        )
    end 
end

function plot_technology_effects(
        tech_df, costs_df;
        fig_prefix::String="", display_plot::Bool=true, save_plot::Bool=true
    )
    df = connect_technology_with_costs(tech_df, costs_df)
    for ((;technology), subdf) in by_pairs(df, :technology)
        p = plot(xlabel="Installation", ylabel="Total system costs [\$]")
        plot_technology_effects_by_alternative(subdf, p)
        display_plot && display(p)
        save_plot && savefig("$(fig_prefix)$technology.png")
    end
end